`timescale 1ns/1ps

module i2c_master_tb_wrapper (
    input  logic clk,
    input  logic rst_n,

    // Transaction request
    input  logic [7:0]  i_addr_w_rw,
    input  logic [15:0] i_sub_addr,
    input  logic        i_sub_len,
    input  logic [23:0] i_byte_len,
    input  logic        req_trans,
    input  logic [7:0]  i_data_write,

    // read data
    output logic [7:0]  data_out,
    output logic        valid_out,

    // I2C lines
    output logic        scl_oe,
    output logic        scl_out,
    input  logic        scl_in,
    output logic        sda_oe,
    output logic        sda_out,
    input  logic        sda_in,

    // Host-facing status
    output logic        req_data_chunk,
    output logic        busy,
    output logic        nack
);

    // Sim-only timing: same real fast-mode I2C ratio as production
    // (CLK_HZ/SCL_HZ = 100M/400k = 250), scaled down ~10x for fast sim,
    // with the setup/hold constants scaled to match.
    i2c_master #(
        .CLK_HZ          (1_000_000),
        .SCL_HZ          (40_000),
        .START_IND_SETUP (8'd7),
        .START_IND_HOLD  (8'd6),
        .DATA_SETUP_TIME (8'd2),
        .DATA_HOLD_TIME  (8'd3),
        .STOP_IND_SETUP  (8'd6)
    ) dut (
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
        $dumpfile("sim_build_i2c_master/dump.vcd");
        $dumpvars(0, i2c_master_tb_wrapper);
    end

endmodule