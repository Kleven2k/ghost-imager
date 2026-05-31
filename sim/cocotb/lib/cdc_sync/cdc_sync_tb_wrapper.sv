`timescale 1ns/1ps

module cdc_sync_tb_wrapper #(
    parameter int WIDTH  = 1,
    parameter int STAGES = 2
)(
    input  logic             clk,
    input  logic [WIDTH-1:0] i_sig,
    output logic [WIDTH-1:0] o_sig_sync
);

    cdc_sync #(
        .WIDTH(WIDTH),
        .STAGES(STAGES)
    ) dut (
        .clk(clk),
        .i_sig(i_sig),
        .o_sig_sync(o_sig_sync)
    );

    initial begin
        $dumpfile("sim_build_cdc_sync/dump.vcd");
        $dumpvars(0, cdc_sync_tb_wrapper);
    end

endmodule