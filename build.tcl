# ----------------------------------------------------------------------------
# Non-project Vivado build for board_top -- PicoZed 7030 + FMC Carrier V2
#
# Run from the repository root, after sourcing Vivado's settings64.sh:
#   vivado -mode batch -source build.tcl
#
# Outputs go to build/: board_top.bit, board_top.bit.bin (for /dev/xdevcfg)
# and a report after each stage.
# ----------------------------------------------------------------------------

set part   xc7z030sbg485-1
set top    board_top
set outdir build

file mkdir $outdir
create_project -in_memory -part $part

# --- Idle PS7 block ----------------------------------------------------------
# A Zynq bitstream needs the PS7 cell so the PS-PL interface is tied off safely
# (see src/board_top.vhd). Everything that crosses into the PL is disabled
# except FCLK_CLK0, board_top's clock. Its rate is set at run time by Linux;
# the 33.333 MHz here only has to match the XDC.
create_bd_design -dir $outdir/bd ps7_stub
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0             0 \
    CONFIG.PCW_EN_CLK0_PORT              1 \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ  33.333333 \
    CONFIG.PCW_EN_RST0_PORT              0 \
] $ps7
create_bd_port -dir O -type clk FCLK_CLK0
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_ports FCLK_CLK0]
validate_bd_design
save_bd_design
set bd_file [get_files ps7_stub.bd]
generate_target all $bd_file
# The IP's XDC pins out DDR and MIO, which this stub leaves unconnected: those
# PS pins are set up by the FSBL at boot, not by the bitstream. Skip it; the
# FCLK_CLK0 clock it would also define is in constraints/board_top.xdc.
set_property is_enabled false [get_files ps7_stub_ps7_0.xdc]
add_files [make_wrapper -files $bd_file -top]

# --- Sources -----------------------------------------------------------------
read_vhdl {
    src/debouncer.vhd
    src/pulse_gen.vhd
    src/trigger.vhd
    src/coincidence.vhd
    src/detector_top.vhd
    src/board_top.vhd
}
read_xdc constraints/board_top.xdc

# --- Synthesis ---------------------------------------------------------------
synth_design -top $top -part $part
write_checkpoint -force $outdir/post_synth.dcp
report_utilization -file $outdir/utilization_synth.rpt

# --- Implementation ----------------------------------------------------------
opt_design
place_design
route_design
write_checkpoint -force $outdir/post_route.dcp

report_timing_summary -file $outdir/timing_summary.rpt
report_utilization    -file $outdir/utilization_impl.rpt
report_io             -file $outdir/io.rpt
report_drc            -file $outdir/drc.rpt

# --- Bitstream ---------------------------------------------------------------
write_bitstream -force $outdir/$top.bit

# Strip the .bit header and byte-swap for the PCAP (/dev/xdevcfg). bootgen
# resolves paths from the working directory, so the .bif uses an absolute one.
set bif [open $outdir/$top.bif w]
puts $bif "all:\n{\n  [file normalize $outdir/$top.bit]\n}"
close $bif
exec bootgen -image $outdir/$top.bif -arch zynq -process_bitstream bin -w
