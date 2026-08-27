`timescale 1ns/1ps
`default_nettype none

// uart_streamer: reads the correlator accumulator BRAM (port B) sequentially
// and sends the whole partial-sum dump as a SINGLE UART packet.
//
// Protocol (matches architecture.md §7, TYPE 0x01 = partial-sum dump):
//   one packet, TYPE = 0x01, LEN = n_pixels * (ACC_WIDTH/8) bytes,
//   payload = accumulator words back-to-back, each word big-endian (MSB first).
//
// TX handshake (matches uart_interface contract):
//   - pre-stage byte 0 and assert tx_send for one cycle
//   - update tx_payload_byte on each tx_payload_req (bytes 1 .. LEN-1)
//   - wait for tx_busy to rise then fall to confirm the packet is fully sent
//
// BRAM port B has 1-cycle registered read latency: present rd_addr, data is
// valid the next cycle. Because UART byte transmission takes CYCLES_PER_BIT*10
// cycles, the NEXT accumulator word is prefetched while the current word's four
// bytes are still being serialized — it is always settled before a word boundary.

module uart_streamer #(
    parameter int PATTERN_WIDTH = 64,
    parameter int ACC_WIDTH     = 32    // must be 32 (4-byte words); see TX_SENDING
)(
    input  wire logic clk,
    input  wire logic rst_n,

    // Control
    input  wire logic        stream_start,  // one-cycle pulse to begin
    input  wire logic [15:0] n_pixels,      // number of accumulator entries to send
    output logic             stream_busy,
    output logic             stream_done,   // one-cycle pulse after the packet is sent

    // Correlator BRAM port B
    output logic [$clog2(PATTERN_WIDTH)-1:0] rd_addr,
    input  wire logic [ACC_WIDTH-1:0]        rd_data,

    // uart_interface TX
    output logic [7:0]  tx_msg_type,
    output logic [15:0] tx_msg_len,
    output logic [7:0]  tx_payload_byte,
    output logic        tx_send,
    input  wire logic   tx_payload_req,
    input  wire logic   tx_busy
);

    localparam logic [7:0] MSG_DUMP      = 8'h01;
    localparam int         BYTES_PER_WORD = ACC_WIDTH / 8;   // 4 for ACC_WIDTH=32
    localparam int         PIXEL_IDX_WIDTH = $clog2(PATTERN_WIDTH);

    // FSM states
    typedef enum logic [2:0] {
        IDLE,
        BRAM_ADDR,    // rd_addr stable; BRAM latches it this cycle
        BRAM_DATA,    // rd_data (word 0) valid; stage byte 0 and TX header fields
        TX_WAIT,      // wait for !tx_busy, then fire tx_send
        TX_SENDING,   // serve payload bytes on tx_payload_req; wait for done
        DONE          // assert stream_done
    } state_t;

    state_t state;

    logic [15:0]          pixel_idx;    // index of the word currently being sent
    logic [15:0]          n_pixels_reg; // latched copy of n_pixels
    logic [ACC_WIDTH-1:0] data_latched; // word currently being serialized
    logic [1:0]           byte_idx;     // byte within the current word (0 = MSB)
    logic                 tx_started;   // set once tx_busy rises after tx_send

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state           <= IDLE;
            stream_busy     <= 1'b0;
            stream_done     <= 1'b0;
            tx_send         <= 1'b0;
            tx_msg_type     <= 8'h00;
            tx_msg_len      <= 16'd0;
            tx_payload_byte <= 8'h00;
            byte_idx        <= 2'd0;
            tx_started      <= 1'b0;
            rd_addr         <= '0;
            pixel_idx       <= 16'd0;
            n_pixels_reg    <= 16'd0;
            data_latched    <= '0;
        end else begin
            // Pulses deassert each cycle by default.
            stream_done <= 1'b0;
            tx_send     <= 1'b0;

            case (state)

                IDLE: begin
                    stream_busy <= 1'b0;
                    if (stream_start && n_pixels != 16'd0) begin
                        n_pixels_reg <= n_pixels;
                        pixel_idx    <= 16'd0;
                        rd_addr      <= '0;
                        stream_busy  <= 1'b1;
                        state        <= BRAM_ADDR;
                    end
                end

                // rd_addr is stable. BRAM registers it this cycle; rd_data
                // (word 0) is valid on entry to BRAM_DATA.
                BRAM_ADDR: begin
                    state <= BRAM_DATA;
                end

                // rd_data = word 0. Stage byte 0 and the TX header fields, and
                // prefetch word 1 so it is ready before the first word boundary.
                BRAM_DATA: begin
                    data_latched    <= rd_data;
                    tx_msg_type     <= MSG_DUMP;
                    tx_msg_len      <= n_pixels_reg * BYTES_PER_WORD[15:0];
                    tx_payload_byte <= rd_data[ACC_WIDTH-1 -: 8];   // byte 0 (MSB)
                    byte_idx        <= 2'd0;
                    if (n_pixels_reg > 16'd1)
                        rd_addr <= rd_addr + 1'b1;                  // prefetch word 1
                    state <= TX_WAIT;
                end

                // Wait until uart_interface is free, then fire the one-cycle tx_send.
                TX_WAIT: begin
                    if (!tx_busy) begin
                        tx_send    <= 1'b1;
                        tx_started <= 1'b0;
                        state      <= TX_SENDING;
                    end
                end

                // uart_interface fires tx_payload_req for bytes 1 .. LEN-1.
                // Within a word: stage the next byte from data_latched.
                // At a word boundary (byte_idx == 3): the next word is already
                // in rd_data (prefetched); latch it, stage its MSB, and prefetch
                // the following word.
                TX_SENDING: begin
                    if (tx_payload_req) begin
                        if (byte_idx != 2'd3) begin
                            byte_idx        <= byte_idx + 2'd1;
                            tx_payload_byte <= data_latched[ACC_WIDTH-1 - 8*(byte_idx + 2'd1) -: 8];
                        end else begin
                            pixel_idx       <= pixel_idx + 16'd1;
                            data_latched    <= rd_data;
                            tx_payload_byte <= rd_data[ACC_WIDTH-1 -: 8];   // next word, byte 0
                            byte_idx        <= 2'd0;
                            // Prefetch the word after the one we just moved to,
                            // if it exists (current word becomes pixel_idx+1).
                            if (pixel_idx + 16'd2 < n_pixels_reg)
                                rd_addr <= rd_addr + 1'b1;
                        end
                    end

                    // Track tx_busy rising after tx_send, then falling when done.
                    if (tx_busy)               tx_started <= 1'b1;
                    if (tx_started && !tx_busy) state     <= DONE;
                end

                DONE: begin
                    stream_done <= 1'b1;
                    stream_busy <= 1'b0;
                    state       <= IDLE;
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule
