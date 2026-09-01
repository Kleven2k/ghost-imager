`timescale 1ns/1ps

// xadc_wiz_0_stub: behavioral stand-in for the Xilinx-generated xadc_wiz_0
// IP (see ip/xadc_wiz_0/xadc_wiz_0.xci). The real IP wraps a hard macro that
// Icarus cannot simulate, so this stub reproduces just enough of its DRP
// timing for xadc_interface.sv's logic to be exercised in cocotb.
//
// With SEQUENCER_MODE=Continuous/channel_sequencer startup (our IP config),
// the real XADC's internal sequencer runs conversions autonomously -- it
// does NOT wait for den_in to start converting. den_in/drdy_out there is
// only the DRP *readout* handshake, layered on top of a conversion loop
// that's already free-running. So this stub self-triggers a fixed-latency
// "conversion" at reset release and after every completed one, independent
// of den_in, then pulses eoc_out/drdy_out with do_out carrying whatever
// value the testbench has poked into stub_sample (a backdoor not present
// on the real IP -- there is no way to simulate a real analog voltage
// here).
//
// Port list matches xadc_wiz_0.veo exactly, so it drops in for
// xadc_interface.sv's instantiation without any DUT source changes. The
// "analog reading" the stub returns is driven by the testbench through a
// hierarchical reference into stub_sample (there is no way to simulate a
// real analog voltage here, and the real IP has no such backdoor).
module xadc_wiz_0 #(
    parameter int CONV_LATENCY = 5   // clk cycles from den_in to eoc_out; arbitrary, not timed to real 26-ADCCLK spec
)(
    input  wire [15:0] di_in,
    input  wire [6:0]  daddr_in,
    input  wire        den_in,
    input  wire        dwe_in,
    output logic       drdy_out,
    output logic [15:0] do_out,
    input  wire        dclk_in,
    input  wire        reset_in,
    input  wire        vp_in,
    input  wire        vn_in,
    input  wire        vauxp0,
    input  wire        vauxn0,
    output logic       user_temp_alarm_out,
    output logic       vccint_alarm_out,
    output logic       vccaux_alarm_out,
    output logic       ot_out,
    output logic [4:0] channel_out,
    output logic       eoc_out,
    output logic       alarm_out,
    output logic       eos_out,
    output logic       busy_out
);

    // Testbench drives this via a hierarchical reference (see
    // xadc_interface_tb_wrapper.sv) to set the "analog reading" returned
    // on the next completed conversion.
    logic [11:0] stub_sample;

    assign user_temp_alarm_out = 1'b0;
    assign vccint_alarm_out    = 1'b0;
    assign vccaux_alarm_out    = 1'b0;
    assign ot_out              = 1'b0;
    assign channel_out         = 5'h10;
    assign alarm_out           = 1'b0;
    assign eos_out             = 1'b0;
    assign busy_out            = (state != IDLE);

    typedef enum logic [1:0] { IDLE, CONVERTING, EOC } state_t;
    state_t state;

    logic [$clog2(CONV_LATENCY+1)-1:0] cnt;

    always_ff @(posedge dclk_in) begin
        if (reset_in) begin
            state    <= IDLE;
            cnt      <= '0;
            eoc_out  <= 1'b0;
            drdy_out <= 1'b0;
            do_out   <= 16'h0000;
        end
        else begin
            eoc_out  <= 1'b0;
            drdy_out <= 1'b0;

            case (state)
                IDLE: begin
                    // Self-triggered: the real IP's continuous sequencer
                    // starts converting on its own, not in response to
                    // den_in (see header comment).
                    cnt   <= '0;
                    state <= CONVERTING;
                end

                CONVERTING: begin
                    if (cnt == CONV_LATENCY - 1) begin
                        eoc_out <= 1'b1;
                        state   <= EOC;
                    end
                    else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                EOC: begin
                    do_out   <= {stub_sample, 4'h0};
                    drdy_out <= 1'b1;
                    cnt      <= '0;
                    state    <= CONVERTING;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
