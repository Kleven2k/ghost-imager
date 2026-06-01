`timescale 1ns/1ps
`default_nettype none

// Stage-1 integration top. Wires together:
//   - pattern_sequencer    (the acquisition FSM)
//   - correlator           (per-pixel accumulator, with bram_dp inside)
//   - bram_dp              (pattern memory, holds the N patterns)
//
// CSR-style configuration registers (ctrl_reg, n_patterns_reg, etc.) are
// exposed as direct input ports. In the full system these come from
// csr_handler; this top stays UART-free so the integration test isolates
// the sequencer ↔ correlator datapath.
//
// DMD and bucket detector interfaces are also exposed as ports — the
// testbench stubs them in cocotb (same pattern as test_pattern_sequencer).

module top #(
    parameter int PATTERN_WIDTH  = 64,
    parameter int N_PATTERNS_MAX = 4096,
    parameter int BUCKET_WIDTH   = 16,
    parameter int ACC_WIDTH      = 32,
    parameter int COUNTER_WIDTH  = 20
)(
    input  wire logic clk,
    input  wire logic rst_n,

    // CSR inputs (would be driven by csr_handler in the full system)
    input  wire logic [31:0] ctrl_reg,
    input  wire logic [31:0] n_patterns_reg,
    input  wire logic [31:0] t_settle_reg,
    input  wire logic [31:0] t_sample_reg,
    input  wire logic [31:0] mode_reg,
    output logic [31:0]      status_out,

    // DMD subsystem (stub)
    output logic                     pat_req,
    output logic [PATTERN_WIDTH-1:0] pat_bits,
    input  wire logic                dmd_ack,

    // Bucket detector (stub)
    output logic                         smp_gate,
    input  wire logic [BUCKET_WIDTH-1:0] b_i,
    input  wire logic                    smp_valid,

    // Correlator readout (port B of the accumulator BRAM)
    input  wire logic [$clog2(PATTERN_WIDTH)-1:0] rd_addr,
    output logic      [ACC_WIDTH-1:0]             rd_data,
    output logic                                  overflow
);

    // -- Internal wires (sequencer ↔ correlator) ----------------------------
    logic                     acc_we;
    logic [PATTERN_WIDTH-1:0] acc_pat;
    logic [BUCKET_WIDTH-1:0]  acc_b;
    logic                     acc_done;

    // -- Internal wires (sequencer ↔ pattern BRAM) --------------------------
    logic [$clog2(N_PATTERNS_MAX)-1:0] pat_bram_addr;
    logic [PATTERN_WIDTH-1:0]          pat_bram_data;

    // -- Pattern sequencer --------------------------------------------------
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
        .status_out    (status_out),

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

        // Port A: sequencer reads from here
        .en_a  (1'b1),
        .we_a  (1'b0),
        .addr_a(pat_bram_addr),
        .din_a ({PATTERN_WIDTH{1'b0}}),
        .dout_a(pat_bram_data),

        // Port B: unused in production. Exposed in the wrapper via a
        // hierarchical backdoor for testbench preload.
        .en_b  (1'b0),
        .we_b  (1'b0),
        .addr_b({$clog2(N_PATTERNS_MAX){1'b0}}),
        .din_b ({PATTERN_WIDTH{1'b0}}),
        .dout_b()
    );

    // -- Correlator (accumulator BRAM is inside) ---------------------------
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
        .overflow(overflow),

        .rd_addr(rd_addr),
        .rd_data(rd_data)
    );

endmodule
