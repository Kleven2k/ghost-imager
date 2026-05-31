`timescale 1ns/1ps

module uart_interface_tb_wrapper (
    input  logic        clk,
    input  logic        rst_n,

    // Physical UART pins - cocotb drives/samples these directly
    input  logic        rx_pin,
    output logic        tx_pin,

    // RX application outputs 
    output logic [7:0]  rx_msg_type,
    output logic [15:0] rx_msg_len,
    output logic [7:0]  rx_payload_byte,
    output logic        rx_payload_valid,
    output logic        rx_msg_done,
    output logic        rx_crc_ok,

    // TX application inputs
    input  logic [7:0]  tx_msg_type,
    input  logic [15:0] tx_msg_len,
    input  logic [7:0]  tx_payload_byte,
    output logic        tx_payload_req,
    input  logic        tx_send,
    output logic        tx_busy
);

    uart_interface #(
        .CLK_HZ(1_000_000),   // sim-only: 1 MHz pretend clock → CYCLES_PER_BIT = 8
        .BAUD  (115_200)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .rx_pin          (rx_pin),
        .tx_pin          (tx_pin),
        .rx_msg_type     (rx_msg_type),
        .rx_msg_len      (rx_msg_len),
        .rx_payload_byte (rx_payload_byte),
        .rx_payload_valid(rx_payload_valid),
        .rx_msg_done     (rx_msg_done),
        .rx_crc_ok       (rx_crc_ok),
        .tx_msg_type     (tx_msg_type),
        .tx_msg_len      (tx_msg_len),
        .tx_payload_byte (tx_payload_byte),
        .tx_payload_req  (tx_payload_req),
        .tx_send         (tx_send),
        .tx_busy         (tx_busy)
    );

    initial begin
        $dumpfile("sim_build_uart_interface/dump.vcd");
        $dumpvars(0, uart_interface_tb_wrapper);
    end

endmodule