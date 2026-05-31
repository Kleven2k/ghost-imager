`timescale 1ns/1ps

module uart_tx_tb_wrapper (
    input  logic clk,
    input  logic rst_n,
    input  logic tx_valid,
    input  logic [7:0] tx_data,

    output logic tx,
    output logic tx_ready
);

    uart_tx #(
        .CLK_HZ(1_000_000),   // sim-only: pretend the clock is 1 MHz instead of 100 MHz
        .BAUD  (115_200)      // same baud → CYCLES_PER_BIT = 8 instead of 868 → ~100x faster sim
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .tx_valid(tx_valid),
        .tx_data(tx_data),
        .tx(tx),
        .tx_ready(tx_ready)
    );

    initial begin
        $dumpfile("sim_build_uart_tx/dump.vcd");
        $dumpvars(0, uart_tx_tb_wrapper);
    end

endmodule