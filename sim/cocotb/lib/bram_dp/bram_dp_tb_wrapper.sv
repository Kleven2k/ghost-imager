`timescale 1ns/1ps

module bram_dp_tb_wrapper #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 12
)(  
    input  logic clk,

    // Port A
    input  logic                  en_a,
    input  logic                  we_a,
    input  logic [ADDR_WIDTH-1:0] addr_a,
    input  logic [DATA_WIDTH-1:0] din_a,
    output logic [DATA_WIDTH-1:0] dout_a,

    // Port B
    input  logic                  en_b,
    input  logic                  we_b,
    input  logic [ADDR_WIDTH-1:0] addr_b,
    input  logic [DATA_WIDTH-1:0] din_b,
    output logic [DATA_WIDTH-1:0] dout_b
);

    bram_dp #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk(clk),

        .en_a(en_a),
        .we_a(we_a),
        .addr_a(addr_a),
        .din_a(din_a),
        .dout_a(dout_a),

        .en_b(en_b),
        .we_b(we_b),
        .addr_b(addr_b),
        .din_b(din_b),
        .dout_b(dout_b)
    );

    initial begin
        $dumpfile("sim_build_bram_dp/dump.vcd");
        $dumpvars(0, bram_dp_tb_wrapper);
    end 

endmodule