`timescale 1ns/1ps

// Testbench wrapper for uart_streamer.
// Uses PATTERN_WIDTH=4 so sim runs in microseconds rather than milliseconds.
// The BRAM and uart_interface are both stubbed by cocotb coroutines.

module uart_streamer_tb_wrapper #(
    parameter int PATTERN_WIDTH = 4,
    parameter int ACC_WIDTH     = 32
)(
    input  logic clk,
    input  logic rst_n,

    // Control
    input  logic        stream_start,
    input  logic [15:0] n_pixels,
    output logic        stream_busy,
    output logic        stream_done,

    // Correlator BRAM port B stub (cocotb drives rd_data)
    output logic [1:0]            rd_addr,    // $clog2(4) = 2
    input  logic [ACC_WIDTH-1:0]  rd_data,

    // uart_interface TX stub (cocotb drives tx_payload_req, tx_busy)
    output logic [7:0]  tx_msg_type,
    output logic [15:0] tx_msg_len,
    output logic [7:0]  tx_payload_byte,
    output logic        tx_send,
    input  logic        tx_payload_req,
    input  logic        tx_busy,

    // Debug taps
    output logic [2:0] dbg_state,
    output logic [1:0] dbg_tx_byte_idx
);

    uart_streamer #(
        .PATTERN_WIDTH(PATTERN_WIDTH),
        .ACC_WIDTH    (ACC_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .stream_start(stream_start),
        .n_pixels    (n_pixels),
        .stream_busy (stream_busy),
        .stream_done (stream_done),

        .rd_addr(rd_addr),
        .rd_data(rd_data),

        .tx_msg_type    (tx_msg_type),
        .tx_msg_len     (tx_msg_len),
        .tx_payload_byte(tx_payload_byte),
        .tx_send        (tx_send),
        .tx_payload_req (tx_payload_req),
        .tx_busy        (tx_busy)
    );

    assign dbg_state       = dut.state;
    assign dbg_tx_byte_idx = dut.byte_idx;

    initial begin
        $dumpfile("sim_build_uart_streamer/dump.vcd");
        $dumpvars(0, uart_streamer_tb_wrapper);
    end

endmodule
