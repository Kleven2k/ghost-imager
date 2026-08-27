`timescale 1ns/1ps

// Wrapper around top.sv for the end-to-end integration test.
// Small parameters for fast sim: 8 pixels per pattern, up to 16 patterns,
// 16-bit bucket, 32-bit accumulator. CLK_HZ/BAUD give CYCLES_PER_BIT=8.
//
// The host (PC) side is bit-banged by cocotb on uart_rx / uart_tx.
// DMD and bucket are stubbed by cocotb coroutines.

module top_tb_wrapper #(
    parameter int PATTERN_WIDTH  = 8,
    parameter int N_PATTERNS_MAX = 16,
    parameter int BUCKET_WIDTH   = 16,
    parameter int ACC_WIDTH      = 32,
    parameter int COUNTER_WIDTH  = 16,
    parameter int CLK_HZ         = 1_000_000,
    parameter int BAUD           = 125_000
)(
    input  logic clk,
    input  logic rst_n,

    // Host UART
    input  logic uart_rx,
    output logic uart_tx,

    // DMD stub
    output logic                     pat_req,
    output logic [PATTERN_WIDTH-1:0] pat_bits,
    input  logic                     dmd_ack,

    // Bucket stub
    output logic                         smp_gate,
    input  logic [BUCKET_WIDTH-1:0]      b_i,
    input  logic                         smp_valid,

    // Debug taps
    output logic [31:0] dbg_status,
    output logic [2:0]  dbg_seq_state,
    output logic [$clog2(N_PATTERNS_MAX)-1:0] dbg_seq_idx,
    output logic [2:0]  dbg_corr_state,
    output logic [$clog2(PATTERN_WIDTH)-1:0]  dbg_corr_pixel_idx,
    output logic [1:0]  dbg_grant
);

    top #(
        .PATTERN_WIDTH (PATTERN_WIDTH),
        .N_PATTERNS_MAX(N_PATTERNS_MAX),
        .BUCKET_WIDTH  (BUCKET_WIDTH),
        .ACC_WIDTH     (ACC_WIDTH),
        .COUNTER_WIDTH (COUNTER_WIDTH),
        .CLK_HZ        (CLK_HZ),
        .BAUD          (BAUD)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .uart_rx(uart_rx),
        .uart_tx(uart_tx),

        .pat_req(pat_req),
        .pat_bits(pat_bits),
        .dmd_ack(dmd_ack),

        .smp_gate(smp_gate),
        .b_i(b_i),
        .smp_valid(smp_valid)
    );

    assign dbg_status         = dut.status_in;
    assign dbg_seq_state      = dut.u_seq.state;
    assign dbg_seq_idx        = dut.u_seq.idx;
    assign dbg_corr_state     = dut.u_corr.state;
    assign dbg_corr_pixel_idx = dut.u_corr.pixel_idx;
    assign dbg_grant          = dut.grant;

    initial begin
        $dumpfile("sim_build_top/dump.vcd");
        $dumpvars(0, top_tb_wrapper);
    end

endmodule
