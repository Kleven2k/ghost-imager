`timescale 1ns/1ps
`default_nettype none

module csr_handler (
    input  wire logic clk,
    input  wire logic rst_n,

    // RX side (from uart_interface)
    input  wire logic [7:0]  rx_msg_type,
    input  wire logic [15:0] rx_msg_len,
    input  wire logic [7:0]  rx_payload_byte,
    input  wire logic        rx_payload_valid,
    input  wire logic        rx_msg_done,
    input  wire logic        rx_crc_ok,

    // TX side (to uart_interface)
    output logic      [7:0]  tx_msg_type,
    output logic      [15:0] tx_msg_len,
    output logic      [7:0]  tx_payload_byte,
    input  wire logic        tx_payload_req,
    output logic             tx_send,
    input  wire logic        tx_busy,

    // CSR consumers (driven out to the rest of the design)
    output logic      [31:0] ctrl_reg,
    input  wire logic [31:0] status_in,       // driven by sequencer/correlator
    output logic      [31:0] n_patterns_reg,
    output logic      [31:0] t_settle_reg,
    output logic      [31:0] t_sample_reg,
    output logic      [31:0] mode_reg,
    output logic      [31:0] dump_period_reg,
    output logic      [31:0] scratch_reg
);

    // -- Packet TYPE codes (architecture.md §7) ------------------------------
    localparam logic [7:0] TYPE_CSR_WRITE      = 8'h10;
    localparam logic [7:0] TYPE_CSR_READ       = 8'h11;
    localparam logic [7:0] TYPE_CSR_ACK        = 8'h03;
    localparam logic [7:0] TYPE_CSR_READ_RESP  = 8'h13;

    // -- CSR addresses (architecture.md §8) ---------------------------------
    localparam logic [7:0] ADDR_STATUS = 8'h01;

    // -- Register file -------------------------------------------------------
    // 8 registers, 32-bit, address space 0x00..0x07.
    // STATUS (0x01) is read-only — driven by status_in, not stored here.
    logic [31:0] csr [0:7];

    assign ctrl_reg        = csr[0];
    assign n_patterns_reg  = csr[2];
    assign t_settle_reg    = csr[3];
    assign t_sample_reg    = csr[4];
    assign mode_reg        = csr[5];
    assign dump_period_reg = csr[6];
    assign scratch_reg     = csr[7];

    // Read-data mux: STATUS comes from status_in, everything else from csr[].
    logic [7:0]  read_addr;
    logic [31:0] csr_read_value;
    assign csr_read_value = (read_addr == ADDR_STATUS) ? status_in
                                                       : csr[read_addr[2:0]];

    // -- RX side: capture streaming payload bytes ---------------------------
    // The buffer holds at most 5 bytes (CSR write: addr + 4-byte value LE).
    logic [7:0] payload_buf [0:4];
    logic [2:0] payload_idx;

    // Pulses to the TX FSM (kept as one-cycle strobes)
    logic       send_ack;
    logic       send_read_resp;
    logic [7:0] ack_addr;       // address to echo in the ACK

    // -- RX-CSR FSM ----------------------------------------------------------
    typedef enum logic {
        RX_IDLE
    } csr_rx_state_t;

    csr_rx_state_t csr_rx_state;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            csr_rx_state   <= RX_IDLE;
            payload_idx    <= '0;
            send_ack       <= 1'b0;
            send_read_resp <= 1'b0;
            ack_addr       <= 8'd0;
            read_addr      <= 8'd0;
            for (int i = 0; i < 8; i++) csr[i] <= 32'd0;
        end else begin
            // Default: pulses deassert each cycle.
            send_ack       <= 1'b0;
            send_read_resp <= 1'b0;

            case (csr_rx_state)

                RX_IDLE: begin
                    // Stream payload bytes into the buffer as they arrive.
                    if (rx_payload_valid && payload_idx < 3'd5) begin
                        payload_buf[payload_idx] <= rx_payload_byte;
                        payload_idx              <= payload_idx + 1;
                    end

                    // On end-of-packet with good CRC, dispatch by TYPE.
                    if (rx_msg_done && rx_crc_ok) begin
                        case (rx_msg_type)

                            TYPE_CSR_WRITE: begin
                                // Payload layout: [addr, val[7:0], val[15:8], val[23:16], val[31:24]]
                                // STATUS is read-only — silently ignore writes to it.
                                if (payload_buf[0] != ADDR_STATUS) begin
                                    csr[payload_buf[0][2:0]] <= {payload_buf[4],
                                                                 payload_buf[3],
                                                                 payload_buf[2],
                                                                 payload_buf[1]};
                                end
                                ack_addr <= payload_buf[0];
                                send_ack <= 1'b1;
                            end

                            TYPE_CSR_READ: begin
                                // Payload layout: [addr]
                                read_addr      <= payload_buf[0];
                                send_read_resp <= 1'b1;
                            end

                            default: ;  // unknown TYPE — ignore
                        endcase
                    end

                    // Reset payload index at end-of-packet so the next packet starts clean.
                    if (rx_msg_done) payload_idx <= '0;
                end

            endcase
        end
    end

    // -- TX-CSR FSM ----------------------------------------------------------
    typedef enum logic {
        TX_IDLE,
        TX_SENDING
    } csr_tx_state_t;

    csr_tx_state_t csr_tx_state;
    logic [2:0]    tx_byte_idx;        // which payload byte we're emitting
    logic          resp_is_read;       // 0 = ACK (1 byte), 1 = READ_RESP (5 bytes)
    logic          tx_started;         // set on entering TX_SENDING, cleared on tx_busy fall

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            csr_tx_state    <= TX_IDLE;
            tx_msg_type     <= 8'd0;
            tx_msg_len      <= 16'd0;
            tx_payload_byte <= 8'd0;
            tx_send         <= 1'b0;
            tx_byte_idx     <= '0;
            resp_is_read    <= 1'b0;
            tx_started      <= 1'b0;
        end else begin
            tx_send <= 1'b0;   // default: tx_send is a one-cycle pulse

            case (csr_tx_state)

                TX_IDLE: begin
                    if (send_ack) begin
                        tx_msg_type     <= TYPE_CSR_ACK;
                        tx_msg_len      <= 16'd1;
                        tx_payload_byte <= ack_addr;       // byte 0 = addr
                        tx_send         <= 1'b1;
                        resp_is_read    <= 1'b0;
                        tx_byte_idx     <= '0;
                        tx_started      <= 1'b0;   // becomes 1 once tx_busy rises
                        csr_tx_state    <= TX_SENDING;
                    end else if (send_read_resp) begin
                        tx_msg_type     <= TYPE_CSR_READ_RESP;
                        tx_msg_len      <= 16'd5;
                        tx_payload_byte <= read_addr;      // byte 0 = addr
                        tx_send         <= 1'b1;
                        resp_is_read    <= 1'b1;
                        tx_byte_idx     <= '0;
                        tx_started      <= 1'b0;   // becomes 1 once tx_busy rises
                        csr_tx_state    <= TX_SENDING;
                    end
                end

                TX_SENDING: begin
                    // On each req from uart_interface, advance to the next payload byte.
                    // For an ACK (1-byte payload) no req fires — we just wait for tx_busy
                    // to rise and then fall, then return to IDLE.
                    if (tx_payload_req) begin
                        tx_byte_idx <= tx_byte_idx + 1;
                        if (resp_is_read) begin
                            // bytes 1..4 = value LSB -> MSB
                            case (tx_byte_idx)
                                3'd0: tx_payload_byte <= csr_read_value[7:0];
                                3'd1: tx_payload_byte <= csr_read_value[15:8];
                                3'd2: tx_payload_byte <= csr_read_value[23:16];
                                3'd3: tx_payload_byte <= csr_read_value[31:24];
                                default: ;
                            endcase
                        end
                    end

                    // Latch tx_started only once tx_busy has actually risen — protects
                    // against the race where TX_SENDING is entered before uart_interface
                    // has had a chance to assert tx_busy in response to our tx_send pulse.
                    if (tx_busy) tx_started <= 1'b1;

                    // Packet fully drained when uart_interface drops tx_busy.
                    if (tx_started && !tx_busy) begin
                        tx_started   <= 1'b0;
                        csr_tx_state <= TX_IDLE;
                    end
                end

            endcase
        end
    end

endmodule
