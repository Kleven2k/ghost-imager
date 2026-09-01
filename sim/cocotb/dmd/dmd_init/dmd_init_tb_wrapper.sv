`timescale 1ns/1ps

module dmd_init_tb_wrapper (
    input  logic clk,
    input  logic rst_n,

    input  logic gpio4_intf,

    // I2C lines, exposed so the testbench can act as the slave
    output logic scl_oe,
    output logic scl_out,
    input  logic scl_in,
    output logic sda_oe,
    output logic sda_out,
    input  logic sda_in,

    output logic init_done,
    output logic init_error
);

    // i2c_master <-> dmd_init internal wiring
    logic [7:0]  i_addr_w_rw;
    logic [15:0] i_sub_addr;
    logic        i_sub_len;
    logic [23:0] i_byte_len;
    logic        req_trans;
    logic [7:0]  i_data_write;
    logic [7:0]  data_out;
    logic        valid_out;
    logic        req_data_chunk;
    logic        busy;
    logic        nack;

    dmd_init dut (
        .clk(clk),
        .rst_n(rst_n),

        .gpio4_intf(gpio4_intf),

        .i_addr_w_rw(i_addr_w_rw),
        .i_sub_addr(i_sub_addr),
        .i_sub_len(i_sub_len),
        .i_byte_len(i_byte_len),
        .req_trans(req_trans),
        .i_data_write(i_data_write),

        .req_data_chunk(req_data_chunk),
        .busy(busy),
        .nack(nack),

        .init_done(init_done),
        .init_error(init_error)
    );

    // Sim-only timing: same ratio as i2c_master's own testbench.
    i2c_master #(
        .CLK_HZ          (1_000_000),
        .SCL_HZ          (40_000),
        .START_IND_SETUP (8'd7),
        .START_IND_HOLD  (8'd6),
        .DATA_SETUP_TIME (8'd2),
        .DATA_HOLD_TIME  (8'd3),
        .STOP_IND_SETUP  (8'd6)
    ) i2c (
        .clk(clk),
        .rst_n(rst_n),

        .i_addr_w_rw(i_addr_w_rw),
        .i_sub_addr(i_sub_addr),
        .i_sub_len(i_sub_len),
        .i_byte_len(i_byte_len),
        .req_trans(req_trans),
        .i_data_write(i_data_write),

        .data_out(data_out),
        .valid_out(valid_out),

        .scl_oe(scl_oe),
        .scl_out(scl_out),
        .scl_in(scl_in),
        .sda_oe(sda_oe),
        .sda_out(sda_out),
        .sda_in(sda_in),

        .req_data_chunk(req_data_chunk),
        .busy(busy),
        .nack(nack)
    );

    initial begin
        $dumpfile("sim_build_dmd_init/dump.vcd");
        $dumpvars(0, dmd_init_tb_wrapper);
    end

endmodule
