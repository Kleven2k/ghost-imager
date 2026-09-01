`timescale 1ns/1ps

module dmd_video_if_tb_wrapper (
    input  logic clk,
    input  logic rst_n,

    input  logic [63:0] pattern_in,

    output logic pclk_out,
    output logic hsync,
    output logic vsync,
    output logic dataen,
    output logic [23:0] data
);

    // Sim-only timing: real DLPC2607 numbers are unknown (see dmd_video_if.sv
    // header) and even the placeholder VESA-scale porches would make a full
    // frame slow to simulate at 640x360. Shrink resolution to a tiny frame
    // that keeps the 8x8 logical grid meaningful (H_ACTIVE/V_ACTIVE must
    // stay multiples of 8) plus tiny porches, and run PCLK close to clk so
    // cocotb doesn't have to step through a large clock-division ratio.
    dmd_video_if #(
        .CLK_HZ         (1_000_000),
        .PCLK_HZ        (500_000),
        .H_ACTIVE       (16),
        .H_FRONT_PORCH  (2),
        .H_SYNC_WIDTH   (2),
        .H_BACK_PORCH   (2),
        .V_ACTIVE       (16),
        .V_FRONT_PORCH  (1),
        .V_SYNC_WIDTH   (1),
        .V_BACK_PORCH   (1)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .pattern_in(pattern_in),

        .pclk_out(pclk_out),
        .hsync(hsync),
        .vsync(vsync),
        .dataen(dataen),
        .data(data)
    );

    initial begin
        $dumpfile("sim_build_dmd_video_if/dump.vcd");
        $dumpvars(0, dmd_video_if_tb_wrapper);
    end

endmodule