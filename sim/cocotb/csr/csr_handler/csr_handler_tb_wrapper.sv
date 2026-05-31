`timescale 1ns/1ps

module csr_handler_tb_wrapper (
    input  logic clk,
    input  logic rst_n,

    input  logic [7:0]  rx_msg_type,
    input  logic [15:0] rx_msg_len,
    input  logic [7:0]  rx_payload_byte,
    input  logic        rx_payload_valid,
    input  logic        rx_msg_done,
    input  logic        rx_crc_ok,

    output logic [7:0]  tx_msg_type,
    output logic [15:0] tx_msg_len,
    output logic [7:0]  tx_payload_byte,
    input  logic        tx_payload_req,
    output logic        tx_send,
    input  logic        tx_busy,

    output logic [31:0] ctrl_reg,
    input  logic [31:0] status_in,
    output logic [31:0] n_patterns_reg,
    output logic [31:0] t_settle_reg,
    output logic [31:0] t_sample_reg,
    output logic [31:0] mode_reg,
    output logic [31:0] dump_period_reg,
    output logic [31:0] scratch_reg,

    // Debug taps into the DUT internals
    output logic        dbg_csr_tx_state,
    output logic [2:0]  dbg_tx_byte_idx,
    output logic        dbg_resp_is_read,
    output logic [7:0]  dbg_read_addr,
    output logic [31:0] dbg_csr_read_value
);

    csr_handler dut (
        .clk(clk),
        .rst_n(rst_n),
        
        .rx_msg_type(rx_msg_type),
        .rx_msg_len(rx_msg_len),
        .rx_payload_byte(rx_payload_byte),
        .rx_payload_valid(rx_payload_valid),
        .rx_msg_done(rx_msg_done),
        .rx_crc_ok(rx_crc_ok),

        .tx_msg_type(tx_msg_type),
        .tx_msg_len(tx_msg_len),
        .tx_payload_byte(tx_payload_byte),
        .tx_payload_req(tx_payload_req),
        .tx_send(tx_send),
        .tx_busy(tx_busy),

        .ctrl_reg(ctrl_reg),
        .status_in(status_in),
        .n_patterns_reg(n_patterns_reg),
        .t_settle_reg(t_settle_reg),
        .t_sample_reg(t_sample_reg),
        .mode_reg(mode_reg),
        .dump_period_reg(dump_period_reg),
        .scratch_reg(scratch_reg)
    );

    // Internal probes
    assign dbg_csr_tx_state   = dut.csr_tx_state;
    assign dbg_tx_byte_idx    = dut.tx_byte_idx;
    assign dbg_resp_is_read   = dut.resp_is_read;
    assign dbg_read_addr      = dut.read_addr;
    assign dbg_csr_read_value = dut.csr_read_value;

    initial begin
        $dumpfile("sim_build_csr_handler/dump.vcd");
        $dumpvars(0, csr_handler_tb_wrapper);
    end

endmodule