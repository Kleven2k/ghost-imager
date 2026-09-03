`timescale 1ns/1ps
`default_nettype none

// Acquisition FSM. For each of N_PATTERNS:
//   1. Read pattern from pat_bram[idx].
//   2. Hand to DMD, wait for ack.
//   3. Wait T_SETTLE cycles for micromirrors to settle.
//   4. Open bucket integration window for T_SAMPLE cycles, latch result.
//   5. Hand (pattern, bucket) to correlator, wait for ack.
//   6. Advance idx; loop until idx == N_PATTERNS.
//
// Start: rising edge of ctrl_reg[0]. Status published on status_out.

module pattern_sequencer #(
    parameter int IMG_PIXELS     = 4096,    // 64x64 image (currently unused; for future use)
    parameter int PATTERN_WIDTH  = 64,      // BRAM row width
    parameter int N_PATTERNS_MAX = 4096,    // max patterns the BRAM can hold
    parameter int BUCKET_WIDTH   = 12,      // matches xadc_interface's sample width (do_out[15:4])
    parameter int COUNTER_WIDTH  = 20       // wide enough for T_SETTLE / T_SAMPLE max values
)(
    input  wire logic clk,
    input  wire logic rst_n,

    // CSR inputs (driven by csr_handler)
    input  wire logic [31:0] ctrl_reg,           // bit 0 = start
    input  wire logic [31:0] n_patterns_reg,     // how many patterns to step through
    input  wire logic [31:0] t_settle_reg,       // settle delay in clk cycles
    input  wire logic [31:0] t_sample_reg,       // sample window in clk cycles
    input  wire logic [31:0] mode_reg,           // [0]: 0=comparator, 1=ADC

    // To CSR (status reporting)
    output logic [31:0] status_out,              // {idx[15:0], 12'd0, mode, overflow, done, busy}

    // To DMD subsystem (stub for Stage 1)
    output logic                     pat_req,    // "go project this pattern"
    output logic [PATTERN_WIDTH-1:0] pat_bits,   // the pattern itself
    input  wire logic                dmd_ack,    // "done projecting"

    // To bucket detector (stub for Stage 1)
    output logic                         smp_gate,   // open the integration window
    input  wire logic [BUCKET_WIDTH-1:0] b_i,        // bucket reading
    input  wire logic                    smp_valid,  // bucket reading ready

    // To correlator
    output logic                     acc_we,     // tell correlator to accumulate
    output logic [PATTERN_WIDTH-1:0] acc_pat,    // the pattern row
    output logic [BUCKET_WIDTH-1:0]  acc_b,      // the bucket value
    input  wire logic                acc_done,   // correlator finished with this sample

    // Pattern BRAM read port
    output logic [$clog2(N_PATTERNS_MAX)-1:0] pat_bram_addr,
    input  wire logic [PATTERN_WIDTH-1:0]     pat_bram_data
);

    // -- FSM states ----------------------------------------------------------
    typedef enum logic [2:0] {
        IDLE,
        LOAD_PATTERN,   // present pat_bram_addr; BRAM data arrives next cycle
        ASSERT_DMD,     // latch pattern, pat_req=1, wait for dmd_ack
        SETTLE_WAIT,    // countdown t_settle_reg cycles
        SAMPLE,         // smp_gate=1 for t_sample_reg cycles, latch b_i
        ACCUMULATE,     // acc_we=1, wait for acc_done
        NEXT            // advance idx; loop or finish
    } state_t;

    state_t state;

    // -- Internal registers --------------------------------------------------
    logic [$clog2(N_PATTERNS_MAX)-1:0] idx;
    logic [COUNTER_WIDTH-1:0]          counter;       // countdown for SETTLE_WAIT / SAMPLE
    logic [BUCKET_WIDTH-1:0]           b_latched;     // captured bucket sample

    logic busy_q;
    logic done_q;
    logic overflow_q;
    logic acc_we_pulsed;       // tracks that we've already issued the one-cycle acc_we
    logic ctrl_start_d;        // ctrl_reg[0] delayed by 1 cycle, for rising-edge detection
    logic start_edge;
    assign start_edge = ctrl_reg[0] & ~ctrl_start_d;

    // -- Status word (matches architecture.md §8) ----------------------------
    // idx is $clog2(N_PATTERNS_MAX) bits wide; zero-extend to 16 for the status field.
    logic [15:0] idx_padded;
    assign idx_padded = {{(16-$clog2(N_PATTERNS_MAX)){1'b0}}, idx};
    assign status_out = {
        idx_padded,        // [31:16] current pattern index
        12'd0,             // [15:4]  reserved
        mode_reg[0],       // [3]
        overflow_q,        // [2]
        done_q,            // [1]
        busy_q             // [0]
    };

    // BRAM address is just the current pattern index.
    assign pat_bram_addr = idx;

    // -- FSM -----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state        <= IDLE;
            idx          <= '0;
            counter      <= '0;
            b_latched    <= '0;
            pat_bits     <= '0;
            pat_req      <= 1'b0;
            smp_gate     <= 1'b0;
            acc_we       <= 1'b0;
            acc_pat      <= '0;
            acc_b        <= '0;
            busy_q        <= 1'b0;
            done_q        <= 1'b0;
            overflow_q    <= 1'b0;
            acc_we_pulsed <= 1'b0;
            ctrl_start_d  <= 1'b0;
        end else begin
            // Edge-detect helper: register ctrl_reg[0] every cycle.
            ctrl_start_d <= ctrl_reg[0];

            // Default: pulse-style outputs deassert each cycle unless held by an FSM state.
            pat_req  <= 1'b0;
            smp_gate <= 1'b0;
            acc_we   <= 1'b0;

            case (state)

                IDLE: begin
                    busy_q <= 1'b0;
                    if (start_edge) begin
                        idx        <= '0;
                        done_q     <= 1'b0;
                        overflow_q <= 1'b0;
                        busy_q     <= 1'b1;
                        state      <= LOAD_PATTERN;
                    end
                end

                // Present pat_bram_addr; data appears on pat_bram_data next cycle.
                LOAD_PATTERN: begin
                    state <= ASSERT_DMD;
                end

                // BRAM read latency has elapsed — latch the pattern and request the DMD.
                ASSERT_DMD: begin
                    pat_bits <= pat_bram_data;
                    pat_req  <= 1'b1;
                    if (dmd_ack) begin
                        counter <= t_settle_reg[COUNTER_WIDTH-1:0];
                        state   <= SETTLE_WAIT;
                    end
                end

                // Wait for the DMD micromirrors to physically settle.
                SETTLE_WAIT: begin
                    if (counter == '0) begin
                        counter  <= t_sample_reg[COUNTER_WIDTH-1:0];
                        smp_gate <= 1'b1;
                        state    <= SAMPLE;
                    end else begin
                        counter <= counter - 1;
                    end
                end

                // Hold the sample gate open for the integration window.
                // Latch b_i on the cycle smp_valid pulses.
                SAMPLE: begin
                    smp_gate <= 1'b1;
                    if (smp_valid)
                        b_latched <= b_i;

                    if (counter == '0) begin
                        smp_gate <= 1'b0;
                        state    <= ACCUMULATE;
                    end else begin
                        counter <= counter - 1;
                    end
                end

                // Hand the (pattern, bucket) pair to the correlator.
                // acc_we is pulsed for exactly one cycle (the cycle we enter ACCUMULATE);
                // we then wait in this state for acc_done without re-pulsing.
                ACCUMULATE: begin
                    acc_pat <= pat_bits;
                    acc_b   <= b_latched;
                    // acc_we is held by the default-deassert at top, except on entry —
                    // detect entry via dbg_state below. Simpler: latch a "have_pulsed" flag.
                    if (!acc_we_pulsed) begin
                        acc_we         <= 1'b1;
                        acc_we_pulsed  <= 1'b1;
                    end
                    if (acc_done) begin
                        acc_we_pulsed <= 1'b0;
                        state         <= NEXT;
                    end
                end

                // Advance index; finish if we've done all patterns, otherwise loop.
                NEXT: begin
                    if (idx == n_patterns_reg[$clog2(N_PATTERNS_MAX)-1:0] - 1) begin
                        busy_q <= 1'b0;
                        done_q <= 1'b1;
                        state  <= IDLE;
                    end else begin
                        idx   <= idx + 1;
                        state <= LOAD_PATTERN;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
