`timescale 1ns/1ps
`default_nettype none

// True dual-port single-clock block RAM wrapper.
//
// Both ports can independently read OR write each cycle, at independent
// addresses. Read latency: 1 cycle (data appears on the cycle after addr).
//
// Read-during-write mode: NO_CHANGE. If a port writes on cycle N, that port's
// data_o on cycle N+1 holds whatever it last *read* (not the just-written
// value). The OTHER port reading the same address on cycle N+1 will see the
// new value (sequenced through the shared array). For read-modify-write on a
// single port, separate read and write into distinct cycles.
//
// Inference: this coding pattern inferring a Xilinx BRAM_36 (or BRAM_18 for
// small DEPTH) — confirmed in Vivado synthesis log under "BRAM_TDP_MACRO".
// No vendor primitive instantiation; portable across Xilinx 7-series.

module bram_dp #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 12         // depth = 2**ADDR_WIDTH (BRAMs are always 2^N)
)(
    input  wire logic                  clk,

    // Port A
    input  wire logic                  en_a,
    input  wire logic                  we_a,
    input  wire logic [ADDR_WIDTH-1:0] addr_a,
    input  wire logic [DATA_WIDTH-1:0] din_a,
    output logic      [DATA_WIDTH-1:0] dout_a,

    // Port B
    input  wire logic                  en_b,
    input  wire logic                  we_b,
    input  wire logic [ADDR_WIDTH-1:0] addr_b,
    input  wire logic [DATA_WIDTH-1:0] din_b,
    output logic      [DATA_WIDTH-1:0] dout_b
);

    localparam int DEPTH = 2**ADDR_WIDTH;

    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Port A
    always_ff @(posedge clk) begin
        if (en_a) begin
            if (we_a) mem[addr_a] <= din_a;
            else      dout_a      <= mem[addr_a];
        end
    end

    // Port B
    always_ff @(posedge clk) begin
        if (en_b) begin
            if (we_b) mem[addr_b] <= din_b;
            else      dout_b      <= mem[addr_b];
        end
    end

endmodule
