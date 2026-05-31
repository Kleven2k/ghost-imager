`timescale 1ns/1ps
`default_nettype none

module uart_tx #(
    parameter int CLK_HZ = 100_000_000,
    parameter int BAUD   = 115_200
)(
    input  wire logic clk,
    input  wire logic rst_n,
    input  wire logic tx_valid,
    input  wire logic [7:0] tx_data,

    output logic tx,
    output logic tx_ready
);

    localparam int CYCLES_PER_BIT = CLK_HZ / BAUD;

    typedef enum logic [1:0] {
        IDLE,
        START,
        DATA,
        STOP
    } state_t;

    state_t state;

    logic [$clog2(CYCLES_PER_BIT)-1:0] clk_count;
    logic [2:0] bit_index;
    logic [7:0] tx_shift;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state     <= IDLE;
            tx        <= 1'b1;
            tx_ready  <= 1'b1;
            clk_count <= '0;
            bit_index <= '0;
            tx_shift  <= '0;
        end else begin
            case (state)

                IDLE: begin
                    tx        <= 1'b1;
                    tx_ready  <= 1'b1;
                    clk_count <= '0;
                    bit_index <= '0;

                    if (tx_valid) begin
                        tx_shift <= tx_data;
                        tx_ready <= 1'b0;
                        state    <= START;
                    end
                end

                START: begin
                    tx <= 1'b0;

                    if (clk_count == CYCLES_PER_BIT-1) begin
                        clk_count <= '0;
                        state     <= DATA;
                    end else begin
                        clk_count <= clk_count + 1;
                    end
                end

                DATA: begin
                    tx <= tx_shift[bit_index];

                    if (clk_count == CYCLES_PER_BIT-1) begin
                        clk_count <= '0;

                        if (bit_index == 3'd7) begin
                            bit_index <= '0;
                            state     <= STOP;
                        end else begin
                            bit_index <= bit_index + 1;
                        end
                    end else begin
                        clk_count <= clk_count + 1;
                    end
                end

                STOP: begin
                    tx <= 1'b1;

                    if (clk_count == CYCLES_PER_BIT-1) begin
                        clk_count <= '0;
                        state     <= IDLE;
                    end else begin
                        clk_count <= clk_count + 1;
                    end
                end

            endcase
        end
    end

endmodule
