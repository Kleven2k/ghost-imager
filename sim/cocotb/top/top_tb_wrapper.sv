`timescale 1ns/1ps

// Wrapper around top.sv for the end-to-end integration test.
// Small parameters for fast sim: 8 pixels per pattern, up to 16 patterns,
// 12-bit bucket (matches xadc_interface's real sample width), 32-bit
// accumulator. CLK_HZ/BAUD give CYCLES_PER_BIT=8.
//
// The host (PC) side is bit-banged by cocotb on uart_rx / uart_tx.
// DMD (I2C + parallel video) pins are left unmonitored -- this test
// exercises the UART/CSR/acquisition/correlation/streaming path, not the
// DMD or XADC transports themselves (those have their own module-level
// cocotb suites). The bucket detector's xadc_wiz_0 IP is replaced with the
// same behavioral stub xadc_interface's own testbench uses, since Icarus
// cannot simulate the real hard macro; cocotb drives its stub_sample
// backdoor via a hierarchical reference (see test_top.py).

module top_tb_wrapper #(
    parameter int PATTERN_WIDTH  = 8,
    parameter int N_PATTERNS_MAX = 16,
    parameter int BUCKET_WIDTH   = 12,
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

    // Bucket detector analog input -- driven statically low; the actual
    // "reading" comes from the xadc_wiz_0 stub's backdoor, not this pin.
    input  logic vauxp0,
    input  logic vauxn0,

    // DLPC2607 I2C -- left open (pulled up), unmonitored by this test.
    inout  wire logic scl,
    inout  wire logic sda,
    input  logic       gpio4_intf,

    // DLPC2607 parallel video -- outputs, unmonitored by this test.
    output logic        dmd_pclk,
    output logic        dmd_hsync,
    output logic        dmd_vsync,
    output logic        dmd_dataen,
    output logic [23:0] dmd_data,

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

        .vauxp0(vauxp0),
        .vauxn0(vauxn0),

        .scl(scl),
        .sda(sda),
        .gpio4_intf(gpio4_intf),

        .dmd_pclk  (dmd_pclk),
        .dmd_hsync (dmd_hsync),
        .dmd_vsync (dmd_vsync),
        .dmd_dataen(dmd_dataen),
        .dmd_data  (dmd_data)
    );

    // Weak pull-ups so the open-drain I2C lines read idle-high with nothing
    // driving them (matches the board's real pull-ups, see nexys_video.xdc).
    pullup(scl);
    pullup(sda);

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
