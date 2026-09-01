# ============================================================
# build.tcl — Vivado non-project batch build for Ghost-imager
#
# Runs: synth → opt → place → phys_opt → route → phys_opt → bitstream
# Each invocation writes to a timestamped runs/build_YYYYMMDD_HHMMSS/
# directory so previous builds are never overwritten.
#
# Usage (from repo root):
#   vivado -mode batch -source scripts/build.tcl
# ============================================================

set PART        "xc7a200tsbg484-1"
set TOP         "top"

# ---- Timestamped output directory -------------------------------
set TS      [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set RUN_DIR "runs/build_$TS"
file mkdir $RUN_DIR

puts "============================================================"
puts " RAMSEY BUILD"
puts " Part:    $PART"
puts " Top:     $TOP"
puts " Out dir: $RUN_DIR"
puts "============================================================"

# --- Sources ------------------------------------------------------
# Sub-modules (order withing a group dosen't matter for non-project mode)
read_verilog -sv rtl/uart/uart_rx.sv
read_verilog -sv rtl/uart/uart_tx.sv
read_verilog -sv rtl/uart/uart_top.sv
read_verilog -sv rtl/uart/uart_interface.sv
read_verilog -sv rtl/uart_streamer.sv

read_verilog -sv rtl/csr/csr_handler.sv

read_verilog -sv rtl/lib/bram_dp.sv
read_verilog -sv rtl/lib/cdc_sync.sv

read_verilog -sv rtl/correlator.sv
read_verilog -sv rtl/pattern_sequencer.sv

read_verilog -sv rtl/i2c/i2c_master.sv
read_verilog -sv rtl/dmd/dmd_init.sv
read_verilog -sv rtl/dmd/dmd_video_if.sv

# Top level last
read_verilog -sv rtl/top.sv

# --- Constraints ----------------------------
read_xdc constraints/nexys_video.xdc

# --- Synthesis ------------------------------
puts "\n--- Synthesis ---"
synth_design -top $TOP -part $PART
write_checkpoint -force "$RUN_DIR/post_synth.dcp"
report_utilization    -file "$RUN_DIR/util_synth.rpt"
report_timing_summary -file "$RUN_DIR/timing_synth.rpt"

# --- Implementation -------------------------
puts "\n--- Optimize ---"
opt_design

puts "\n--- Place ---"
place_design
write_checkpoint -force "$RUN_DIR/post_place.dcp"
report_timing_summary -file "$RUN_DIR/timing_place.rpt"

puts "\n--- Physical optimization (post-place) ---"
phys_opt_design

puts "\n--- Route ---"
route_design
write_checkpoint -force "$RUN_DIR/post_route.dcp"

puts "\n--- Physical optimization (post-route) ---"
phys_opt_design

# --- Reports ----------------------------------------
puts "\n--- Reports ---"
report_timing_summary -file "$RUN_DIR/timing.rpt" -warn_on_violation
report_utilization    -file "$RUN_DIR/util.rpt"
report_power          -file "$RUN_DIR/power.rpt"
report_drc            -file "$RUN_DIR/drc.rpt"

# --- Bitstream ---------------------------------------------
puts "\n--- Bitstream ---"
# pat_bits[63:20] are intentionally unconstrained (see constraints/nexys_video.xdc
# header note) — the real DMD electrical interface isn't chosen yet, so those
# 44 bits have no pin/IOSTANDARD. Downgrade NSTD-1/UCIO-1 to warnings rather
# than fabricate placeholder pins for signals with no real hardware behind them.
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
write_bitstream -force "$RUN_DIR/ghost-imager.bit"

puts "\n============================================================"
puts " BUILD COMPLETE: $RUN_DIR/ghost-imager.bit"
puts "============================================================"
