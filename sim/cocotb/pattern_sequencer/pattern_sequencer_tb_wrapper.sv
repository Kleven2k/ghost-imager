`timescale 1ns/1ps

// Stage-1 testbench wrapper. Every interface of pattern_sequencer is exposed
// as wrapper ports — cocotb pretends to be the CSR, DMD, bucket detector,
// correlator, and pattern BRAM. No real modules are instantiated besides
// the DUT itself.

module pattern_sequencer_tb_wrapper #(
    parameter int PATTERN_WIDTH  = 64,
    parameter int N_PATTERNS_MAX = 4096,
    parameter int BUCKET_WIDTH   = 16,
    parameter int COUNTER_WIDTH  = 20
)(
    input  logic clk,
    input  logic rst_n,

    // CSR inputs
    input  logic [31:0] ctrl_reg,
    input  logic [31:0] n_patterns_reg,
    input  logic [31:0] t_settle_reg,
    input  logic [31:0] t_sample_reg,
    input  logic [31:0] mode_reg,

    // Status
    output logic [31:0] status_out,

    // DMD interface
    output logic                     pat_req,
    output logic [PATTERN_WIDTH-1:0] pat_bits,
    input  logic                     dmd_ack,

    // Bucket detector
    output logic                         smp_gate,
    input  logic [BUCKET_WIDTH-1:0]      b_i,
    input  logic                         smp_valid,

    // Correlator
    output logic                     acc_we,
    output logic [PATTERN_WIDTH-1:0] acc_pat,
    output logic [BUCKET_WIDTH-1:0]  acc_b,
    input  logic                     acc_done,

    // Pattern BRAM
    output logic [$clog2(N_PATTERNS_MAX)-1:0] pat_bram_addr,
    input  logic [PATTERN_WIDTH-1:0]          pat_bram_data,

    // Debug taps into DUT internals
    output logic [2:0] dbg_state,
    output logic [$clog2(N_PATTERNS_MAX)-1:0] dbg_idx,
    output logic [COUNTER_WIDTH-1:0]          dbg_counter
);

    pattern_sequencer #(
        .PATTERN_WIDTH (PATTERN_WIDTH),
        .N_PATTERNS_MAX(N_PATTERNS_MAX),
        .BUCKET_WIDTH  (BUCKET_WIDTH),
        .COUNTER_WIDTH (COUNTER_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .ctrl_reg(ctrl_reg),
        .n_patterns_reg(n_patterns_reg),
        .t_settle_reg(t_settle_reg),
        .t_sample_reg(t_sample_reg),
        .mode_reg(mode_reg),

        .status_out(status_out),

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

    assign dbg_state   = dut.state;
    assign dbg_idx     = dut.idx;
    assign dbg_counter = dut.counter;

    initial begin
        $dumpfile("sim_build_pattern_sequencer/dump.vcd");
        $dumpvars(0, pattern_sequencer_tb_wrapper);
    end

endmodule
