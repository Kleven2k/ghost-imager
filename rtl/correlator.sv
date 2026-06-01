`timescale 1ns/1ps
`default_nettype none

// Correlator: per-pixel running sum acc[p] += b_i * H_i[p].
//
// Binary patterns mean H_i[p] ∈ {0,1}, so the multiply degenerates to a
// conditional add: if acc_pat[p] == 1, add acc_b; else skip.
//
// Storage: one bram_dp (PATTERN_WIDTH entries × ACC_WIDTH bits).
//   Port A: read-modify-write driven by this FSM.
//   Port B: read-only, exposed via rd_addr/rd_data for the UART streamer.
//
// FSM (naive, one pixel per pass):
//   IDLE  -- wait for acc_we
//   READ  -- present pixel_idx on port A; BRAM data appears next cycle
//   ADD   -- compute new_val = (acc_pat[pixel_idx] ? old + acc_b : old)
//   WRITE -- write new_val back; advance pixel_idx or finish
//
// Throughput: ~3 cycles per pixel × PATTERN_WIDTH pixels per pattern.
// architecture.md §6 lists this as the Stage-1 baseline.

module correlator #(
    parameter int PATTERN_WIDTH = 64,
    parameter int BUCKET_WIDTH  = 16,
    parameter int ACC_WIDTH     = 32    // signed accumulator
)(
    input  wire logic clk,
    input  wire logic rst_n,

    // From pattern_sequencer
    input  wire logic [PATTERN_WIDTH-1:0] acc_pat,
    input  wire logic [BUCKET_WIDTH-1:0]  acc_b,
    input  wire logic                     acc_we,
    output logic                          acc_done,
    output logic                          overflow,     // sticky bit

    // Read port (exposed to UART streamer for partial dumps)
    input  wire logic [$clog2(PATTERN_WIDTH)-1:0] rd_addr,
    output logic      [ACC_WIDTH-1:0]             rd_data
);

    localparam int PIXEL_IDX_WIDTH = $clog2(PATTERN_WIDTH);

    // -- FSM states ----------------------------------------------------------
    typedef enum logic [2:0] {
        IDLE,
        READ,         // BRAM is reading mem[bram_addr_a] (registered)
        ADD,          // bram_dout_a valid; compute new_val
        WRITE,        // assert we_a; addr and din held from earlier
        ADVANCE       // increment pixel_idx, present next addr, or finish
    } state_t;

    state_t state;

    // -- Internal registers --------------------------------------------------
    logic [PIXEL_IDX_WIDTH-1:0]    pixel_idx;
    logic [PATTERN_WIDTH-1:0]      pat_latched;     // captured on acc_we
    logic [BUCKET_WIDTH-1:0]       b_latched;       // captured on acc_we
    logic [ACC_WIDTH-1:0]          new_val;         // candidate for write-back

    // -- BRAM signals --------------------------------------------------------
    logic                       bram_we_a;
    logic [PIXEL_IDX_WIDTH-1:0] bram_addr_a;
    logic [ACC_WIDTH-1:0]       bram_din_a;
    logic [ACC_WIDTH-1:0]       bram_dout_a;

    bram_dp #(
        .DATA_WIDTH(ACC_WIDTH),
        .ADDR_WIDTH(PIXEL_IDX_WIDTH)
    ) acc_mem (
        .clk(clk),

        // Port A: FSM-driven RMW
        .en_a  (1'b1),
        .we_a  (bram_we_a),
        .addr_a(bram_addr_a),
        .din_a (bram_din_a),
        .dout_a(bram_dout_a),

        // Port B: external read-only (din_b unused but must be sized correctly)
        .en_b  (1'b1),
        .we_b  (1'b0),
        .addr_b(rd_addr),
        .din_b ({ACC_WIDTH{1'b0}}),
        .dout_b(rd_data)
    );

    // -- FSM -----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state       <= IDLE;
            pixel_idx   <= '0;
            pat_latched <= '0;
            b_latched   <= '0;
            new_val     <= '0;
            acc_done    <= 1'b0;
            overflow    <= 1'b0;
            bram_we_a   <= 1'b0;
            bram_addr_a <= '0;
            bram_din_a  <= '0;
        end else begin
            // Defaults: pulses deassert each cycle; BRAM write disabled.
            acc_done  <= 1'b0;
            bram_we_a <= 1'b0;

            case (state)

                IDLE: begin
                    if (acc_we) begin
                        pat_latched <= acc_pat;
                        b_latched   <= acc_b;
                        pixel_idx   <= '0;
                        // Present first pixel address to port A; BRAM will produce
                        // data on bram_dout_a after the next rising edge.
                        bram_addr_a <= '0;
                        state       <= READ;
                    end
                end

                // Wait state — bram_dp registers dout, so on entry to READ the
                // BRAM is still latching the address; bram_dout_a becomes valid
                // on entry to ADD.
                READ: begin
                    state <= ADD;
                end

                // bram_dout_a is now valid. Compute new value.
                ADD: begin
                    if (pat_latched[pixel_idx]) begin
                        new_val <= bram_dout_a + {{(ACC_WIDTH-BUCKET_WIDTH){1'b0}}, b_latched};

                        // Overflow: detect carry out of the ACC_WIDTH-bit add.
                        if ({1'b0, bram_dout_a} + {1'b0, {{(ACC_WIDTH-BUCKET_WIDTH){1'b0}}, b_latched}}
                                >= (1 << ACC_WIDTH))
                            overflow <= 1'b1;
                    end else begin
                        new_val <= bram_dout_a;
                    end
                    state <= WRITE;
                end

                // Assert we_a with bram_addr_a still = pixel_idx, bram_din_a = new_val.
                // We do NOT change bram_addr_a in this state — the write must land
                // at pixel_idx, not pixel_idx+1.
                WRITE: begin
                    bram_we_a  <= 1'b1;
                    bram_din_a <= new_val;
                    state      <= ADVANCE;
                end

                // Write has landed. Now advance: either finish or set up the
                // address for the next pixel's read.
                ADVANCE: begin
                    if (pixel_idx == PATTERN_WIDTH - 1) begin
                        acc_done <= 1'b1;
                        state    <= IDLE;
                    end else begin
                        pixel_idx   <= pixel_idx + 1;
                        bram_addr_a <= pixel_idx + 1;
                        state       <= READ;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
