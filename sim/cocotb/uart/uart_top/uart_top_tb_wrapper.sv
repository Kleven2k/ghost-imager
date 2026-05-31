`timescale 1ns/1ps

module uart_top_tb_wrapper (
    input  logic clk,
    input  logic rst_n,

    input  logic rx,
    output logic tx,

    output logic [7:0] rx_data,
    output logic       rx_valid,

    input  logic [7:0] tx_data,
    input  logic       tx_start,
    output logic       tx_busy
);

    uart_top #(
        .CLK_HZ(1_000_000),   // sim-only: pretend the clock is 1 MHz instead of 100 MHz
        .BAUD    (115_200)      // same baud → CYCLES_PER_BIT = 8 instead of 868 → ~100x faster sim
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .rx(rx),
        .tx(tx),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .tx_data(tx_data),
        .tx_start(tx_start),
        .tx_busy(tx_busy)
    );

    initial begin
        $dumpfile("sim_build_uart_top/dump.vcd");
        $dumpvars(0, uart_top_tb_wrapper);
    end

endmodule