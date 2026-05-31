`timescale 1ns/1ps
`default_nettype none

// Production UART wrapper. Instantiates uart_tx + uart_rx and exposes the
// pins as they would be wired on the board: tx goes to the PC, rx comes
// from the PC. Active-low reset throughout (Ghost Imager convention).
//
// External tx_start / tx_busy are convenience names: tx_start = tx_valid,
// tx_busy = !tx_ready.

module uart_top #(
    parameter int CLK_HZ = 100_000_000,
    parameter int BAUD     = 115_200
)(
    input  wire logic clk,
    input  wire logic rst_n,

    input  wire logic rx,
    output wire logic tx,

    output wire logic [7:0] rx_data,
    output wire logic       rx_valid,

    input  wire logic [7:0] tx_data,
    input  wire logic       tx_start,
    output wire logic       tx_busy
);

    logic tx_ready_int;
    assign tx_busy = ~tx_ready_int;

    uart_rx #(
        .CLK_HZ(CLK_HZ),
        .BAUD  (BAUD)
    ) u_rx (
        .clk     (clk),
        .rst_n   (rst_n),
        .rx      (rx),
        .rx_data (rx_data),
        .rx_valid(rx_valid)
    );

    uart_tx #(
        .CLK_HZ(CLK_HZ),
        .BAUD  (BAUD)
    ) u_tx (
        .clk     (clk),
        .rst_n   (rst_n),
        .tx_valid(tx_start),
        .tx_data (tx_data),
        .tx      (tx),
        .tx_ready(tx_ready_int)
    );

endmodule
