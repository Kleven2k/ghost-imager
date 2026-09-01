`timescale 1ns/1ps
`default_nettype none

// dmd_init: drives the fixed I2C register-write sequence that brings the
// DLPC2607 (on the DLPDLCR2000EVM) into parallel-video, RGB888, nHD
// landscape, free-run mode after power-up. See docs — DLPC2607 Software
// Programmer's Guide (DLPU013), sections 2.2.1 (I2C write protocol) and
// 2.4.1 (register definitions).
//
// Waits for gpio4_intf (the DLPC2607's auto-init-busy pin) to fall before
// sending anything — I2C access before that point is not accepted by the
// device. Each register is a 32-bit write to device address 0x36 with an
// 8-bit sub-address (the register number). Talks to i2c_master as its I2C
// transport; does not touch the SCL/SDA lines directly.
//
// i2c_master's write contract: the first data byte must already be on
// i_data_write when req_trans is pulsed (it's latched once at transaction
// start); subsequent bytes are supplied reactively via req_data_chunk.
module dmd_init (
    input  wire logic clk,
    input  wire logic rst_n,

    input  wire logic gpio4_intf,  // DLPC2607 auto-init-busy pin, active high

    // i2c_master transaction request
    output logic [7:0]  i_addr_w_rw,
    output logic [15:0] i_sub_addr,
    output logic        i_sub_len,
    output logic [23:0] i_byte_len,
    output logic        req_trans,
    output logic [7:0]  i_data_write,

    // i2c_master status
    input  wire logic req_data_chunk,
    input  wire logic busy,
    input  wire logic nack,

    output logic init_done,   // stays high once all registers are written
    output logic init_error   // latches high if any write is NACKed
);

    localparam logic [7:0] DLPC2607_ADDR_W = 8'h36;  // device write address (LSB=0)
    localparam int N_REGS = 5;

    // Register ROM, indexed by reg_idx. Icarus 12.0 rejects localparam
    // array-literal ('{...}) syntax, so this is a case-based lookup instead
    // of an unpacked array. See file header for the source of these values.
    logic [7:0]  reg_addr_lut;
    logic [31:0] reg_data_lut;

    always_comb begin
        case (reg_idx)
            3'd0: begin reg_addr_lut = 8'h0B; reg_data_lut = 32'h0000_0000; end  // input source select: parallel I/F
            3'd1: begin reg_addr_lut = 8'h0C; reg_data_lut = 32'h0000_001B; end  // input resolution select: nHD landscape (27 decimal)
            3'd2: begin reg_addr_lut = 8'h0D; reg_data_lut = 32'h0000_0002; end  // pixel data format select: RGB888
            3'd3: begin reg_addr_lut = 8'h0E; reg_data_lut = 32'h0000_0000; end  // image rotation control: no rotation
            3'd4: begin reg_addr_lut = 8'h1E; reg_data_lut = 32'h0000_0000; end  // sequence sync mode: free-run
            default: begin reg_addr_lut = 8'd0; reg_data_lut = 32'd0; end
        endcase
    end

    typedef enum logic [2:0] {
        WAIT_READY,
        LOAD_ENTRY,
        START_WRITE,
        STREAM_BYTES,
        WAIT_DONE,
        DONE
    } state_t;

    state_t state;

    logic [2:0]  reg_idx;      // which ROM entry (0..N_REGS-1)
    logic [31:0] cur_value;    // current register's 32-bit value, shifting out MSB first
    logic [1:0]  byte_idx;     // which byte of cur_value byte_idx_disp currently selects (0..3, MSB first)
    logic [1:0]  byte_idx_disp;  // byte actually displayed on i_data_write this cycle
    logic        busy_seen;    // latches once busy has actually read 1 since req_trans

    // i_data_write must reflect the NEXT byte during the same cycle
    // req_data_chunk is asserted, not one cycle later: i2c_master's
    // GRAB_DATA state samples i_data_write into byte_sr while
    // req_data_chunk is still high (the cycle after it registers high,
    // before it falls) — not after req_data_chunk falls. A byte_idx that
    // only advances on the next clk edge after seeing req_data_chunk lands
    // one cycle too late for that sample, corrupting every write byte after
    // the first that isn't coincidentally 0x00 (found via cocotb: dmd_init's
    // own test suite, register 0x0C's data byte). byte_idx_disp looks ahead
    // by one whenever req_data_chunk is asserted so i_data_write is already
    // correct in time; byte_idx itself still advances on the next edge for
    // bookkeeping (e.g. LOAD_ENTRY resets it, nothing else depends on its
    // exact timing).
    assign byte_idx_disp = req_data_chunk ? (byte_idx + 2'd1) : byte_idx;

    always_comb begin
        case (byte_idx_disp)
            2'd0: i_data_write = cur_value[31:24];
            2'd1: i_data_write = cur_value[23:16];
            2'd2: i_data_write = cur_value[15:8];
            2'd3: i_data_write = cur_value[7:0];
            default: i_data_write = 8'd0;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state        <= WAIT_READY;
            reg_idx      <= 3'd0;
            cur_value    <= 32'd0;
            byte_idx     <= 2'd0;
            busy_seen    <= 1'b0;
            i_addr_w_rw  <= 8'd0;
            i_sub_addr   <= 16'd0;
            i_sub_len    <= 1'b0;
            i_byte_len   <= 24'd0;
            req_trans    <= 1'b0;
            init_done    <= 1'b0;
            init_error   <= 1'b0;
        end
        else begin
            req_trans <= 1'b0;  // default: one-cycle pulse

            case (state)

                WAIT_READY: begin
                    if (!gpio4_intf) begin
                        reg_idx <= 3'd0;
                        state   <= LOAD_ENTRY;
                    end
                end

                // Latch the ROM entry. byte_idx=0 makes the combinational
                // mux above present byte 0 (MSB) on i_data_write, which
                // i2c_master captures the same cycle req_trans fires.
                LOAD_ENTRY: begin
                    cur_value   <= reg_data_lut;
                    i_addr_w_rw <= DLPC2607_ADDR_W;
                    i_sub_addr  <= {8'd0, reg_addr_lut};
                    i_sub_len   <= 1'b0;      // 8-bit sub-address
                    i_byte_len  <= 24'd4;     // 32-bit value = 4 bytes
                    byte_idx    <= 2'd0;
                    state       <= START_WRITE;
                end

                START_WRITE: begin
                    req_trans <= 1'b1;
                    busy_seen <= 1'b0;
                    state     <= STREAM_BYTES;
                end

                // Serve bytes 1..3 as i2c_master's GRAB_DATA state requests
                // them. cur_value still holds the full value; byte_idx picks
                // which byte, MSB first, matching LOAD_ENTRY's byte 0.
                //
                // busy takes one clk cycle after req_trans to actually
                // register high in i2c_master, so !busy can't be trusted as
                // "transaction complete" until busy has been observed high
                // at least once — otherwise this races straight into
                // WAIT_DONE before i2c_master has even started.
                STREAM_BYTES: begin
                    // Advance byte_idx so the combinational mux presents the
                    // next byte; i2c_master samples it the same cycle it
                    // deasserts req_data_chunk (one cycle after seeing it).
                    if (req_data_chunk) begin
                        byte_idx <= byte_idx + 2'd1;
                    end

                    if (busy) begin
                        busy_seen <= 1'b1;
                    end

                    if (busy_seen && !busy) begin
                        // All 4 bytes shipped and the transaction finished
                        // (ACK/NACK resolved, STOP sent).
                        state <= WAIT_DONE;
                    end
                end

                WAIT_DONE: begin
                    if (nack) begin
                        // A NACK almost certainly means the DLPC2607 isn't
                        // responding at all — abort rather than burn through
                        // the remaining registers against a dead bus.
                        init_error <= 1'b1;
                        state      <= DONE;
                    end
                    else if (reg_idx == N_REGS-1) begin
                        state     <= DONE;
                        init_done <= 1'b1;
                    end
                    else begin
                        reg_idx <= reg_idx + 3'd1;
                        state   <= LOAD_ENTRY;
                    end
                end

                DONE: begin
                    // Stay here; init_done remains asserted.
                end

                default: state <= WAIT_READY;

            endcase
        end
    end

endmodule
