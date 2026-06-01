`timescale 1ns/1ps

// Stage-1 testbench wrapper. Uses small PATTERN_WIDTH for fast sim;
// RTL behavior is identical.

module correlator_tb_wrapper #(
    parameter int PATTERN_WIDTH = 8,    // small for fast sim
    parameter int BUCKET_WIDTH  = 16,
    parameter int ACC_WIDTH     = 32
)(
    input  logic clk,
    input  logic rst_n,

    // From pattern_sequencer
    input  logic [PATTERN_WIDTH-1:0] acc_pat,
    input  logic [BUCKET_WIDTH-1:0]  acc_b,
    input  logic                     acc_we,
    output logic                     acc_done,
    output logic                     overflow,

    // Read port
    input  logic [$clog2(PATTERN_WIDTH)-1:0] rd_addr,
    output logic [ACC_WIDTH-1:0]             rd_data,

    // Debug taps
    output logic [2:0]                       dbg_state,
    output logic [$clog2(PATTERN_WIDTH)-1:0] dbg_pixel_idx
);

    correlator #(
        .PATTERN_WIDTH(PATTERN_WIDTH),
        .BUCKET_WIDTH (BUCKET_WIDTH),
        .ACC_WIDTH    (ACC_WIDTH)
    ) dut (
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

    assign dbg_state     = dut.state;
    assign dbg_pixel_idx = dut.pixel_idx;

    initial begin
        $dumpfile("sim_build_correlator/dump.vcd");
        $dumpvars(0, correlator_tb_wrapper);
    end

endmodule
