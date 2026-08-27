`timescale 1ns/1ps
`default_nettype none

// Integration testbench: uart_streamer + REAL uart_interface + REAL bram_dp.
//
// This exercises the exact strobe timing between the streamer FSM and the
// uart_interface TX FSM (the contract the unit test only models), plus the
// real BRAM read latency and real UART serialization on tx_pin.
//
// PATTERN_WIDTH=4 (4-entry BRAM) and a low CLK_HZ/BAUD keep sim fast:
// CYCLES_PER_BIT = 1_000_000 / 125_000 = 8.
//
// Port A of the BRAM is exposed for cocotb to preload known accumulator words.

module streamer_dump_tb_wrapper #(
    parameter int PATTERN_WIDTH = 4,
    parameter int ACC_WIDTH     = 32,
    parameter int CLK_HZ        = 1_000_000,
    parameter int BAUD          = 125_000
)(
    input  logic clk,
    input  logic rst_n,

    // BRAM port A — cocotb preload
    input  logic                              pre_we,
    input  logic [$clog2(PATTERN_WIDTH)-1:0]  pre_addr,
    input  logic [ACC_WIDTH-1:0]              pre_din,

    // Streamer control
    input  logic        stream_start,
    input  logic [15:0] n_pixels,
    output logic        stream_busy,
    output logic        stream_done,

    // Serial line out (to PC)
    output logic        tx_pin,

    // Debug taps
    output logic [2:0]  dbg_state
);

    // -- BRAM port B <-> streamer ----------------------------------------
    logic [$clog2(PATTERN_WIDTH)-1:0] rd_addr;
    logic [ACC_WIDTH-1:0]             rd_data;

    bram_dp #(
        .DATA_WIDTH(ACC_WIDTH),
        .ADDR_WIDTH($clog2(PATTERN_WIDTH))
    ) acc_mem (
        .clk(clk),
        // Port A: cocotb preload
        .en_a  (1'b1),
        .we_a  (pre_we),
        .addr_a(pre_addr),
        .din_a (pre_din),
        .dout_a(),
        // Port B: streamer read
        .en_b  (1'b1),
        .we_b  (1'b0),
        .addr_b(rd_addr),
        .din_b ({ACC_WIDTH{1'b0}}),
        .dout_b(rd_data)
    );

    // -- streamer <-> uart_interface -------------------------------------
    logic [7:0]  tx_msg_type;
    logic [15:0] tx_msg_len;
    logic [7:0]  tx_payload_byte;
    logic        tx_send;
    logic        tx_payload_req;
    logic        tx_busy;

    uart_streamer #(
        .PATTERN_WIDTH(PATTERN_WIDTH),
        .ACC_WIDTH    (ACC_WIDTH)
    ) u_streamer (
        .clk        (clk),
        .rst_n      (rst_n),
        .stream_start(stream_start),
        .n_pixels   (n_pixels),
        .stream_busy(stream_busy),
        .stream_done(stream_done),
        .rd_addr    (rd_addr),
        .rd_data    (rd_data),
        .tx_msg_type    (tx_msg_type),
        .tx_msg_len     (tx_msg_len),
        .tx_payload_byte(tx_payload_byte),
        .tx_send        (tx_send),
        .tx_payload_req (tx_payload_req),
        .tx_busy        (tx_busy)
    );

    uart_interface #(
        .CLK_HZ(CLK_HZ),
        .BAUD  (BAUD)
    ) u_iface (
        .clk  (clk),
        .rst_n(rst_n),
        .rx_pin(1'b1),            // idle high; RX path unused here
        .tx_pin(tx_pin),
        // RX outputs unused
        .rx_msg_type     (),
        .rx_msg_len      (),
        .rx_payload_byte (),
        .rx_payload_valid(),
        .rx_msg_done     (),
        .rx_crc_ok       (),
        // TX from streamer
        .tx_msg_type    (tx_msg_type),
        .tx_msg_len     (tx_msg_len),
        .tx_payload_byte(tx_payload_byte),
        .tx_payload_req (tx_payload_req),
        .tx_send        (tx_send),
        .tx_busy        (tx_busy)
    );

    assign dbg_state = u_streamer.state;

    initial begin
        $dumpfile("sim_build_streamer_dump/dump.vcd");
        $dumpvars(0, streamer_dump_tb_wrapper);
    end

endmodule
