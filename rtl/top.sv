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

    // Bucket detector
    output logic                         smp_gate,
    input  wire logic [BUCKET_WIDTH-1:0] b_i,
    input  wire logic                    smp_valid,

    // DLPC2607 I2C control — true open-drain pins; tristate driven inside
    // this module (see i2c_master.sv's header for the oe/out/in rationale)
    inout  wire  logic scl,
    inout  wire  logic sda,
    input  wire  logic gpio4_intf,  // DLPC2607 auto-init-busy pin, active high

    // DLPC2607 parallel video
    output logic        dmd_pclk,
    output logic        dmd_hsync,
    output logic        dmd_vsync,
    output logic        dmd_dataen,
    output logic [23:0] dmd_data
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

    // pat_req/pat_bits/dmd_ack are internal now: the DMD is driven by
    // dmd_video_if's continuous video, not a request/ack handshake. See
    // dmd_ack's tie-off below, near dmd_video_if's instantiation.
    logic                     pat_req;
    logic [PATTERN_WIDTH-1:0] pat_bits;
    logic                     dmd_ack;

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

    // -- DMD: I2C init (power-up register writes) --------------------------
    logic [7:0]  i2c_addr_w_rw;
    logic [15:0] i2c_sub_addr;
    logic        i2c_sub_len;
    logic [23:0] i2c_byte_len;
    logic        i2c_req_trans;
    logic [7:0]  i2c_data_write;
    logic        i2c_req_data_chunk;
    logic        i2c_busy;
    logic        i2c_nack;
    logic        dmd_init_done;
    logic        dmd_init_error;

    dmd_init u_dmd_init (
        .clk  (clk),
        .rst_n(rst_n),

        .gpio4_intf(gpio4_intf),

        .i_addr_w_rw (i2c_addr_w_rw),
        .i_sub_addr  (i2c_sub_addr),
        .i_sub_len   (i2c_sub_len),
        .i_byte_len  (i2c_byte_len),
        .req_trans   (i2c_req_trans),
        .i_data_write(i2c_data_write),

        .req_data_chunk(i2c_req_data_chunk),
        .busy          (i2c_busy),
        .nack          (i2c_nack),

        .init_done (dmd_init_done),
        .init_error(dmd_init_error)
    );

    // dmd_init is currently the only thing on this I2C bus, so no arbiter
    // is needed here (unlike the UART TX arbiter above) — revisit if a
    // second I2C consumer shows up.
    logic scl_oe, scl_out_w;
    logic sda_oe, sda_out_w;
    logic scl_in_w, sda_in_w;

    i2c_master u_i2c (
        .clk  (clk),
        .rst_n(rst_n),

        .i_addr_w_rw (i2c_addr_w_rw),
        .i_sub_addr  (i2c_sub_addr),
        .i_sub_len   (i2c_sub_len),
        .i_byte_len  (i2c_byte_len),
        .req_trans   (i2c_req_trans),
        .i_data_write(i2c_data_write),

        .data_out (),
        .valid_out(),

        .scl_oe(scl_oe), .scl_out(scl_out_w), .scl_in(scl_in_w),
        .sda_oe(sda_oe), .sda_out(sda_out_w), .sda_in(sda_in_w),

        .req_data_chunk(i2c_req_data_chunk),
        .busy          (i2c_busy),
        .nack          (i2c_nack)
    );

    assign scl     = scl_oe ? scl_out_w : 1'bz;
    assign sda     = sda_oe ? sda_out_w : 1'bz;
    assign scl_in_w = scl;
    assign sda_in_w = sda;

    // -- DMD: parallel video ------------------------------------------------
    // No handshake with the video interface — pattern_sequencer's own
    // t_settle_reg/t_sample_reg timers pace acquisition, so dmd_ack (its
    // wait-for-DMD signal) is tied permanently high.
    assign dmd_ack = 1'b1;

    // dmd_video_if.pattern_in is hardcoded [63:0]; this only lines up with
    // pat_bits when PATTERN_WIDTH==64 (the current default / Stage-1 design
    // point). Revisit if PATTERN_WIDTH is ever changed at instantiation.
    dmd_video_if u_dmd_video (
        .clk  (clk),
        .rst_n(rst_n),

        .pattern_in(pat_bits),

        .pclk_out(dmd_pclk),
        .hsync   (dmd_hsync),
        .vsync   (dmd_vsync),
        .dataen  (dmd_dataen),
        .data    (dmd_data)
    );

endmodule
