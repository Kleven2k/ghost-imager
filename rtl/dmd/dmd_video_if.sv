`timescale 1ns/1ps
`default_nettype none

// dmd_video_if: parallel video timing generator for the DLPC2607
// (PCLK/HSYNC/VSYNC/DATAEN + Data[23:0] RGB888), driving the current
// 64-bit pattern as an 8x8 logical grid blown up to fill the 640x360 nHD
// active area (each logical pixel -> an H_ACTIVE/8 x V_ACTIVE/8 block of
// physical pixels). Bit=1 -> white (0xFFFFFF), bit=0 -> black (0x000000).
//
// TIMING IS PLACEHOLDER. The DLPC2607 programmer's guide (DLPU013) gives
// register-level resolution selection but not raw electrical timing
// (PCLK frequency, porch widths) — that lives in the ASIC datasheet
// (DLPS030), which hasn't been reviewed yet. PCLK_HZ/H_*/V_* below are
// reasonable placeholder values scaled from generic small-panel timing,
// not numbers taken from a DLPC2607-specific source. Swap them for real
// values once the datasheet timing table is in hand — the parameter list
// is designed so that's a parameter change, not a re-architecture.
//
// PCLK is derived from clk via a simple divider (same pattern as
// i2c_master's SCL_HZ divider): raster counters advance only on the
// pclk_en strobe, so the whole module stays clocked off the single
// system clk per project convention, while producing a slower pixel rate.
module dmd_video_if #(
    parameter int CLK_HZ  = 100_000_000,
    parameter int PCLK_HZ = 25_000_000,  // PLACEHOLDER — real DLPC2607 PCLK unknown

    parameter int H_ACTIVE      = 640,
    parameter int H_FRONT_PORCH = 16,    // PLACEHOLDER
    parameter int H_SYNC_WIDTH  = 96,    // PLACEHOLDER
    parameter int H_BACK_PORCH  = 48,    // PLACEHOLDER

    parameter int V_ACTIVE      = 360,
    parameter int V_FRONT_PORCH = 10,    // PLACEHOLDER
    parameter int V_SYNC_WIDTH  = 2,     // PLACEHOLDER
    parameter int V_BACK_PORCH  = 33,    // PLACEHOLDER

    // DLPC2607 parallel bus polarity control (I2C: 0xAF) reset defaults:
    // HSYNC/VSYNC active-low, DATEN active-high.
    parameter bit HSYNC_ACTIVE_HIGH = 1'b0,
    parameter bit VSYNC_ACTIVE_HIGH = 1'b0
)(
    input  wire logic clk,
    input  wire logic rst_n,

    input  wire logic [63:0] pattern_in,  // current pattern, MSB = logical pixel (0,0)

    output logic       pclk_out,
    output logic        hsync,
    output logic        vsync,
    output logic        dataen,
    output logic [23:0] data
);

    localparam int H_TOTAL = H_ACTIVE + H_FRONT_PORCH + H_SYNC_WIDTH + H_BACK_PORCH;
    localparam int V_TOTAL = V_ACTIVE + V_FRONT_PORCH + V_SYNC_WIDTH + V_BACK_PORCH;

    localparam int H_SYNC_START = H_ACTIVE + H_FRONT_PORCH;
    localparam int H_SYNC_END   = H_SYNC_START + H_SYNC_WIDTH;
    localparam int V_SYNC_START = V_ACTIVE + V_FRONT_PORCH;
    localparam int V_SYNC_END   = V_SYNC_START + V_SYNC_WIDTH;

    localparam int BLOCK_W = H_ACTIVE / 8;
    localparam int BLOCK_H = V_ACTIVE / 8;

    // -- PCLK divider: pclk_en strobes once per PCLK period ---------------
    localparam int DIV = (CLK_HZ + PCLK_HZ - 1) / PCLK_HZ;  // clk cycles per PCLK period, rounded up
    localparam int DIV_CNTR_WIDTH = $clog2(DIV);

    logic [DIV_CNTR_WIDTH-1:0] div_cntr;
    logic                      pclk_en;
    logic                      pclk_reg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            div_cntr <= '0;
            pclk_reg <= 1'b0;
            pclk_en  <= 1'b0;
        end
        else begin
            pclk_en <= 1'b0;
            if (div_cntr == DIV_CNTR_WIDTH'(DIV - 1)) begin
                div_cntr <= '0;
                pclk_reg <= !pclk_reg;
                pclk_en  <= 1'b1;
            end
            else begin
                div_cntr <= div_cntr + DIV_CNTR_WIDTH'(1);
            end
        end
    end

    assign pclk_out = pclk_reg;

    // -- Raster counters, advancing once per pclk_en -----------------------
    // h_count/v_count and all outputs derived from them (dataen, data,
    // hsync, vsync) must describe the SAME pixel on the same clock edge.
    // Since both the counters and the outputs update on the pclk_en edge
    // in non-blocking always_ff blocks, computing "active region" etc. from
    // the counters' *current* value would make the outputs describe the
    // pixel that just ended, one pixel behind h_count/v_count's new value.
    // Instead, h_count_next/v_count_next (what the counters are ABOUT to
    // become) drive the active-region/sync/pattern logic below, so outputs
    // and counters land in lockstep on the same edge.
    localparam int H_CNTR_WIDTH = $clog2(H_TOTAL);
    localparam int V_CNTR_WIDTH = $clog2(V_TOTAL);

    logic [H_CNTR_WIDTH-1:0] h_count, h_count_next;
    logic [V_CNTR_WIDTH-1:0] v_count, v_count_next;

    assign h_count_next = (h_count == H_CNTR_WIDTH'(H_TOTAL - 1)) ? H_CNTR_WIDTH'(0) : (h_count + H_CNTR_WIDTH'(1));
    assign v_count_next = (h_count == H_CNTR_WIDTH'(H_TOTAL - 1))
                           ? ((v_count == V_CNTR_WIDTH'(V_TOTAL - 1)) ? V_CNTR_WIDTH'(0) : (v_count + V_CNTR_WIDTH'(1)))
                           : v_count;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            h_count <= '0;
            v_count <= '0;
        end
        else if (pclk_en) begin
            h_count <= h_count_next;
            v_count <= v_count_next;
        end
    end

    // -- Sync/blanking outputs, computed from the *next* counter values ----
    logic h_active, v_active, h_sync_raw, v_sync_raw;

    assign h_active   = (h_count_next < H_CNTR_WIDTH'(H_ACTIVE));
    assign v_active   = (v_count_next < V_CNTR_WIDTH'(V_ACTIVE));
    assign h_sync_raw = (h_count_next >= H_CNTR_WIDTH'(H_SYNC_START)) && (h_count_next < H_CNTR_WIDTH'(H_SYNC_END));
    assign v_sync_raw = (v_count_next >= V_CNTR_WIDTH'(V_SYNC_START)) && (v_count_next < V_CNTR_WIDTH'(V_SYNC_END));

    // -- Pattern-bit lookup for the current pixel ---------------------------
    // 8x8 logical grid: each logical pixel covers a BLOCK_W x BLOCK_H block
    // of physical pixels. Only meaningful while h_active && v_active; the
    // divides are cheap here since BLOCK_W/BLOCK_H are constant powers of
    // two for the current 640x360 parameters (not enforced for other sizes).
    localparam int BLOCK_X_WIDTH = $clog2(H_ACTIVE);
    localparam int BLOCK_Y_WIDTH = $clog2(V_ACTIVE);

    logic [BLOCK_X_WIDTH-1:0] block_x;
    logic [BLOCK_Y_WIDTH-1:0] block_y;
    logic [5:0]               bit_idx;
    logic                     cur_bit;

    assign block_x = h_count_next / H_CNTR_WIDTH'(BLOCK_W);
    assign block_y = v_count_next / V_CNTR_WIDTH'(BLOCK_H);
    // block_y*8 is a left-shift by 3, not a real multiply — avoids sizing
    // a multiply-constant that itself doesn't fit in 3 bits (8 needs 4).
    assign bit_idx = {block_y[2:0], 3'b000} + {3'b000, block_x[2:0]};
    assign cur_bit = pattern_in[6'd63 - bit_idx];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // h_count/v_count reset to 0,0, which is always inside the
            // active region (H_ACTIVE/V_ACTIVE > 0) and never inside a sync
            // pulse (H_SYNC_START/V_SYNC_START > 0) for any real config —
            // so these reset values describe pixel (0,0) directly, rather
            // than a blanking placeholder that would otherwise leave
            // outputs one pixel behind h_count/v_count until the first
            // pclk_en pulse catches up.
            hsync  <= HSYNC_ACTIVE_HIGH ? 1'b0 : 1'b1;  // idle (not asserted)
            vsync  <= VSYNC_ACTIVE_HIGH ? 1'b0 : 1'b1;  // idle (not asserted)
            dataen <= 1'b1;
            data   <= pattern_in[63] ? 24'hFFFFFF : 24'h000000;  // block (0,0)
        end
        else if (pclk_en) begin
            hsync  <= HSYNC_ACTIVE_HIGH ? h_sync_raw : !h_sync_raw;
            vsync  <= VSYNC_ACTIVE_HIGH ? v_sync_raw : !v_sync_raw;
            dataen <= h_active && v_active;

            if (h_active && v_active) begin
                data <= cur_bit ? 24'hFFFFFF : 24'h000000;
            end
            else begin
                data <= 24'h000000;
            end
        end
    end

endmodule
