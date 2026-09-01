`timescale 1ns/1ps

module xadc_interface_tb_wrapper (
    input  logic clk,
    input  logic rst_n,

    input  logic vauxp0,
    input  logic vauxn0,

    output logic [11:0] sample,
    output logic        sample_valid,

    // Backdoor for the testbench: sets the value the stub IP returns on its
    // next completed conversion. Not present on real hardware.
    input  logic [11:0] stub_sample_in
);

    xadc_interface dut (
        .clk(clk),
        .rst_n(rst_n),
        .vauxp0(vauxp0),
        .vauxn0(vauxn0),
        .sample(sample),
        .sample_valid(sample_valid)
    );

    // Debug probes, left in place per project convention (cheap for future
    // debugging).
    logic        dbg_drdy_out;
    logic [15:0] dbg_do_out;
    assign dbg_drdy_out = dut.drdy_out;
    assign dbg_do_out   = dut.do_out;

    // Drives the stub IP's backdoor sample register every cycle -- see
    // xadc_wiz_0_stub.sv. Hierarchical path follows dut -> u_xadc_wiz,
    // the instance name used inside xadc_interface.sv.
    assign dut.u_xadc_wiz.stub_sample = stub_sample_in;

    initial begin
        $dumpfile("sim_build_xadc_interface/dump.vcd");
        $dumpvars(0, xadc_interface_tb_wrapper);
    end

endmodule
