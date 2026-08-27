`timescale 1ns/1ps
`default_nettype none

// Synthesizable top. Wires the full Stage-1+ datapath plus the host interface:
//   - uart_interface     (RS232 byte/packet transport to the PC)
//   - csr_handler        (decodes CSR writes/reads → config registers)
//   - pattern_sequencer  (acquisition FSM, driven by the CSR registers)
//   - bram_dp            (pattern memory, holds the N patterns)
//   - correlator         (per-pixel accumulator, with bram_dp inside)
//   - uart_streamer      (streams the accumulator out as a 0x01 dump packet)
//
// Two modules want to transmit on the single uart_interface TX: csr_handler
// (ACK / read responses) and uart_streamer (the dump). A small priority arbiter
// (§ "TX arbiter" below) grants the bus to one at a time. CSR has priority; the
// streamer only sends when the bus is free, and a CSR send arriving mid-dump is
// latched (pending_csr) and serviced when the dump completes.
//
// A dump is launched on receipt of a TYPE 0x12 (dump request) packet.
//
// DMD and bucket detector remain external ports (real board pins / TB stubs).

module top #(
    parameter int PATTERN_WIDTH  = 64,
    parameter int N_PATTERNS_MAX = 4096,
    parameter int BUCKET_WIDTH   = 16,
    parameter int ACC_WIDTH      = 32,
    parameter int COUNTER_WIDTH  = 20,
    parameter int CLK_HZ         = 100_000_000,
    parameter int BAUD           = 115_200
)(
    input  wire logic clk,
    input  wire logic rst_n,

    // Host UART (to PC)
    input  wire logic uart_rx,
    output wire logic uart_tx,

    // DMD subsystem
    output logic                     pat_req,
    output logic [PATTERN_WIDTH-1:0] pat_bits,
    input  wire logic                dmd_ack,

    // Bucket detector
    output logic                         smp_gate,
    input  wire logic [BUCKET_WIDTH-1:0] b_i,
    input  wire logic                    smp_valid
);

    localparam logic [7:0] TYPE_DUMP_REQ = 8'h12;
    localparam int         PIXEL_IDX_WIDTH = $clog2(PATTERN_WIDTH);

    // -- uart_interface RX/TX nets ------------------------------------------
    logic [7:0]  rx_msg_type;
    logic [15:0] rx_msg_len;
    logic [7:0]  rx_payload_byte;
    logic        rx_payload_valid;
    logic        rx_msg_done;
    logic        rx_crc_ok;

    logic [7:0]  i_tx_type;
    logic [15:0] i_tx_len;
    logic [7:0]  i_tx_byte;
    logic        i_tx_send;
    logic        i_tx_req;     // tx_payload_req out of interface
    logic        i_tx_busy;

    uart_interface #(
        .CLK_HZ(CLK_HZ),
        .BAUD  (BAUD)
    ) u_iface (
        .clk  (clk),
        .rst_n(rst_n),
        .rx_pin(uart_rx),
        .tx_pin(uart_tx),

        .rx_msg_type     (rx_msg_type),
        .rx_msg_len      (rx_msg_len),
        .rx_payload_byte (rx_payload_byte),
        .rx_payload_valid(rx_payload_valid),
        .rx_msg_done     (rx_msg_done),
        .rx_crc_ok       (rx_crc_ok),

        .tx_msg_type    (i_tx_type),
        .tx_msg_len     (i_tx_len),
        .tx_payload_byte(i_tx_byte),
        .tx_payload_req (i_tx_req),
        .tx_send        (i_tx_send),
        .tx_busy        (i_tx_busy)
    );

    // -- CSR handler --------------------------------------------------------
    logic [31:0] ctrl_reg, n_patterns_reg, t_settle_reg, t_sample_reg;
    logic [31:0] mode_reg, dump_period_reg, scratch_reg;
    logic [31:0] seq_status, status_in;
    logic        overflow_w;

    // Fold the correlator overflow into STATUS[2] (the sequencer leaves it 0).
    assign status_in = {seq_status[31:3], seq_status[2] | overflow_w, seq_status[1:0]};

    logic [7:0]  csr_tx_type;
    logic [15:0] csr_tx_len;
    logic [7:0]  csr_tx_byte;
    logic        csr_tx_send;
    logic        csr_tx_req;   // routed from arbiter
    logic        csr_tx_busy;  // routed from arbiter

    csr_handler u_csr (
        .clk  (clk),
        .rst_n(rst_n),

        .rx_msg_type     (rx_msg_type),
        .rx_msg_len      (rx_msg_len),
        .rx_payload_byte (rx_payload_byte),
        .rx_payload_valid(rx_payload_valid),
        .rx_msg_done     (rx_msg_done),
        .rx_crc_ok       (rx_crc_ok),

        .tx_msg_type    (csr_tx_type),
        .tx_msg_len     (csr_tx_len),
        .tx_payload_byte(csr_tx_byte),
        .tx_payload_req (csr_tx_req),
        .tx_send        (csr_tx_send),
        .tx_busy        (csr_tx_busy),

        .ctrl_reg       (ctrl_reg),
        .status_in      (status_in),
        .n_patterns_reg (n_patterns_reg),
        .t_settle_reg   (t_settle_reg),
        .t_sample_reg   (t_sample_reg),
        .mode_reg       (mode_reg),
        .dump_period_reg(dump_period_reg),
        .scratch_reg    (scratch_reg)
    );

    // -- Pattern sequencer --------------------------------------------------
    logic                     acc_we;
    logic [PATTERN_WIDTH-1:0] acc_pat;
    logic [BUCKET_WIDTH-1:0]  acc_b;
    logic                     acc_done;

    logic [$clog2(N_PATTERNS_MAX)-1:0] pat_bram_addr;
    logic [PATTERN_WIDTH-1:0]          pat_bram_data;

    pattern_sequencer #(
        .PATTERN_WIDTH (PATTERN_WIDTH),
        .N_PATTERNS_MAX(N_PATTERNS_MAX),
        .BUCKET_WIDTH  (BUCKET_WIDTH),
        .COUNTER_WIDTH (COUNTER_WIDTH)
    ) u_seq (
        .clk(clk),
        .rst_n(rst_n),

        .ctrl_reg      (ctrl_reg),
        .n_patterns_reg(n_patterns_reg),
        .t_settle_reg  (t_settle_reg),
        .t_sample_reg  (t_sample_reg),
        .mode_reg      (mode_reg),
        .status_out    (seq_status),

        .pat_req(pat_req),
        .pat_bits(pat_bits),
        .dmd_ack(dmd_ack),

        .smp_gate(smp_gate),
        .b_i(b_i),
        .smp_valid(smp_valid),

        .acc_we(acc_we),
        .acc_pat(acc_pat),
        .acc_b(acc_b),
        .acc_done(acc_done),

        .pat_bram_addr(pat_bram_addr),
        .pat_bram_data(pat_bram_data)
    );

    // -- Pattern BRAM (port A read-only by sequencer, port B unused) --------
    bram_dp #(
        .DATA_WIDTH(PATTERN_WIDTH),
        .ADDR_WIDTH($clog2(N_PATTERNS_MAX))
    ) u_pat_bram (
        .clk(clk),
        .en_a  (1'b1),
        .we_a  (1'b0),
        .addr_a(pat_bram_addr),
        .din_a ({PATTERN_WIDTH{1'b0}}),
        .dout_a(pat_bram_data),
        .en_b  (1'b0),
        .we_b  (1'b0),
        .addr_b({$clog2(N_PATTERNS_MAX){1'b0}}),
        .din_b ({PATTERN_WIDTH{1'b0}}),
        .dout_b()
    );

    // -- Correlator (accumulator BRAM is inside) ---------------------------
    logic [PIXEL_IDX_WIDTH-1:0] rd_addr;
    logic [ACC_WIDTH-1:0]       rd_data;

    correlator #(
        .PATTERN_WIDTH(PATTERN_WIDTH),
        .BUCKET_WIDTH (BUCKET_WIDTH),
        .ACC_WIDTH    (ACC_WIDTH)
    ) u_corr (
        .clk(clk),
        .rst_n(rst_n),

        .acc_pat(acc_pat),
        .acc_b(acc_b),
        .acc_we(acc_we),
        .acc_done(acc_done),
        .overflow(overflow_w),

        .rd_addr(rd_addr),
        .rd_data(rd_data)
    );

    // -- UART streamer ------------------------------------------------------
    // Launch a dump when a TYPE 0x12 request packet arrives (validated CRC).
    logic stream_start;
    assign stream_start = rx_msg_done && rx_crc_ok && (rx_msg_type == TYPE_DUMP_REQ);

    logic [7:0]  str_tx_type;
    logic [15:0] str_tx_len;
    logic [7:0]  str_tx_byte;
    logic        str_tx_send;
    logic        str_tx_req;   // routed from arbiter
    logic        str_tx_busy;  // routed from arbiter

    uart_streamer #(
        .PATTERN_WIDTH(PATTERN_WIDTH),
        .ACC_WIDTH    (ACC_WIDTH)
    ) u_streamer (
        .clk        (clk),
        .rst_n      (rst_n),
        .stream_start(stream_start),
        .n_pixels   (16'(PATTERN_WIDTH)),   // accumulator depth = PATTERN_WIDTH (Stage-1)
        .stream_busy(),
        .stream_done(),
        .rd_addr    (rd_addr),
        .rd_data    (rd_data),
        .tx_msg_type    (str_tx_type),
        .tx_msg_len     (str_tx_len),
        .tx_payload_byte(str_tx_byte),
        .tx_send        (str_tx_send),
        .tx_payload_req (str_tx_req),
        .tx_busy        (str_tx_busy)
    );

    // -- TX arbiter: csr_handler vs uart_streamer onto u_iface TX -----------
    typedef enum logic [1:0] { GNT_NONE, GNT_CSR, GNT_STR } grant_t;
    grant_t grant;
    logic   pending_csr;     // CSR send request awaiting the bus
    logic   arb_busy_seen;   // interface tx_busy has risen during this grant

    logic grant_str_now, grant_csr_now;
    assign grant_str_now = (grant == GNT_NONE) && str_tx_send;
    assign grant_csr_now = (grant == GNT_NONE) && !str_tx_send && (csr_tx_send || pending_csr);

    // Field mux + feedback routing.
    always_comb begin
        i_tx_type = 8'h00;
        i_tx_len  = 16'd0;
        i_tx_byte = 8'h00;
        case (grant)
            GNT_CSR: begin i_tx_type = csr_tx_type; i_tx_len = csr_tx_len; i_tx_byte = csr_tx_byte; end
            GNT_STR: begin i_tx_type = str_tx_type; i_tx_len = str_tx_len; i_tx_byte = str_tx_byte; end
            default: ;
        endcase

        csr_tx_req  = (grant == GNT_CSR) ? i_tx_req  : 1'b0;
        csr_tx_busy = (grant == GNT_CSR) ? i_tx_busy : 1'b0;
        str_tx_req  = (grant == GNT_STR) ? i_tx_req  : 1'b0;

        // The streamer only fires tx_send when it sees the bus free. Keep it
        // "busy" unless the bus is genuinely available to it (no CSR claiming it).
        if (grant == GNT_STR)
            str_tx_busy = i_tx_busy;
        else if (grant == GNT_NONE && !pending_csr && !csr_tx_send)
            str_tx_busy = 1'b0;
        else
            str_tx_busy = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            grant         <= GNT_NONE;
            pending_csr   <= 1'b0;
            arb_busy_seen <= 1'b0;
            i_tx_send     <= 1'b0;
        end else begin
            i_tx_send <= 1'b0;   // default: one-cycle pulse

            // Remember a CSR send that can't be serviced this cycle.
            if (grant_csr_now)      pending_csr <= 1'b0;
            else if (csr_tx_send)   pending_csr <= 1'b1;

            if (grant_str_now) begin
                grant         <= GNT_STR;
                i_tx_send     <= 1'b1;
                arb_busy_seen <= 1'b0;
            end else if (grant_csr_now) begin
                grant         <= GNT_CSR;
                i_tx_send     <= 1'b1;
                arb_busy_seen <= 1'b0;
            end else if (grant != GNT_NONE) begin
                if (i_tx_busy)                     arb_busy_seen <= 1'b1;
                if (arb_busy_seen && !i_tx_busy) begin
                    grant         <= GNT_NONE;
                    arb_busy_seen <= 1'b0;
                end
            end
        end
    end

endmodule
