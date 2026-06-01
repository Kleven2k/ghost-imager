`timescale 1ns/1ps

// Wrapper around top.sv for the Stage-1 integration test.
// Small parameters for fast sim: 8 pixels per pattern, up to 16 patterns,
// 16-bit bucket, 32-bit accumulator.

module top_tb_wrapper #(
    parameter int PATTERN_WIDTH  = 8,
    parameter int N_PATTERNS_MAX = 16,
    parameter int BUCKET_WIDTH   = 16,
    parameter int ACC_WIDTH      = 32,
    parameter int COUNTER_WIDTH  = 16
)(
    input  logic clk,
    input  logic rst_n,

    // CSR inputs
    input  logic [31:0] ctrl_reg,
    input  logic [31:0] n_patterns_reg,
    input  logic [31:0] t_settle_reg,
    input  logic [31:0] t_sample_reg,
    input  logic [31:0] mode_reg,
    output logic [31:0] status_out,

    // DMD stub
    output logic                     pat_req,
    output logic [PATTERN_WIDTH-1:0] pat_bits,
    input  logic                     dmd_ack,

    // Bucket stub
    output logic                         smp_gate,
    input  logic [BUCKET_WIDTH-1:0]      b_i,
    input  logic                         smp_valid,

    // Correlator readout
    input  logic [$clog2(PATTERN_WIDTH)-1:0] rd_addr,
    output logic [ACC_WIDTH-1:0]             rd_data,
    output logic                             overflow,

    // Debug taps
    output logic [2:0] dbg_seq_state,
    output logic [$clog2(N_PATTERNS_MAX)-1:0] dbg_seq_idx,
    output logic [2:0] dbg_corr_state,
    output logic [$clog2(PATTERN_WIDTH)-1:0]  dbg_corr_pixel_idx
);

    top #(
        .PATTERN_WIDTH (PATTERN_WIDTH),
        .N_PATTERNS_MAX(N_PATTERNS_MAX),
        .BUCKET_WIDTH  (BUCKET_WIDTH),
        .ACC_WIDTH     (ACC_WIDTH),
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

        .rd_addr(rd_addr),
        .rd_data(rd_data),
        .overflow(overflow)
    );

    assign dbg_seq_state      = dut.u_seq.state;
    assign dbg_seq_idx        = dut.u_seq.idx;
    assign dbg_corr_state     = dut.u_corr.state;
    assign dbg_corr_pixel_idx = dut.u_corr.pixel_idx;

    initial begin
        $dumpfile("sim_build_top/dump.vcd");
        $dumpvars(0, top_tb_wrapper);
    end

endmodule
