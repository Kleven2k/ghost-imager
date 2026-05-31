`timescale 1ns/1ps

module uart_rx_tb_wrapper (
    input  logic clk,
    input  logic rst_n,
    input  logic rx,

    output logic [7:0] rx_data,
    output logic rx_valid
);

    uart_rx #(
        .CLK_HZ(1_000_000),    // sim-only: pretend the clock is 1 MHz instead of 100 MHz
        .BAUD  (115_200)       // same baud → CYCLES_PER_BIT = 8 instead of 868 → ~100x faster sim
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .rx(rx),
        .rx_data(rx_data),
        .rx_valid(rx_valid)
    );

    initial begin
        $dumpfile("sim_build_uart_rx/dump.vcd");
        $dumpvars(0, uart_rx_tb_wrapper);
    end

endmodule