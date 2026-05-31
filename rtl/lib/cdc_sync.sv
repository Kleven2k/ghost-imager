`timescale 1ns/1ps
`default_nettype none

// Multi-stage clock-domain-crossing synchronizer.
//
// Use for: 1-bit handshake/control signals, async resets, or multi-bit values
//          that are GUARANTEED STABLE across the crossing window (e.g. config
//          registers that change only at reset).
//
// Do NOT use for: arbitrary multi-bit data that toggles freely — that needs
//                 a FIFO or req/ack-gated bus, otherwise different bits will
//                 sample on different cycles and you'll see garbage values.

module cdc_sync #(
    parameter int WIDTH  = 1,
    parameter int STAGES = 2
)(
    input  wire logic             clk,
    input  wire logic [WIDTH-1:0] i_sig,
    output logic      [WIDTH-1:0] o_sig_sync
);

    (* ASYNC_REG = "TRUE" *)
    logic [WIDTH-1:0] sync_ff [STAGES-1:0];

    always_ff @(posedge clk) begin
        sync_ff[0] <= i_sig;
        for (int s = 1; s < STAGES; s++)
            sync_ff[s] <= sync_ff[s-1];
    end

    assign o_sig_sync = sync_ff[STAGES-1];

endmodule
