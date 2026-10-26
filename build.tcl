# ----------------------------------------------------------------------------
# Non-project Vivado build for board_top -- PicoZed 7030 + FMC Carrier V2
#
# Run from the repository root, after sourcing Vivado's settings64.sh:
#   vivado -mode batch -source build.tcl                 # pulse set 2 (default)
#   vivado -mode batch -source build.tcl -tclargs 1      # pulse set 1
#
# Outputs go to build/: board_top.bit, board_top.bit.bin (for /dev/xdevcfg)
# and a report after each stage.
# ----------------------------------------------------------------------------

set part      xc7z030sbg485-1
set top       board_top
set outdir    build
set pulse_set [expr {[llength $argv] > 0 ? [lindex $argv 0] : 2}]
puts "Building $top with PULSE_SET = $pulse_set"

file mkdir $outdir
create_project -in_memory -part $part

# --- PS7 block design ----------------------------------------------------------
# The PS supplies the PL's clock, its reset, and the AXI GP0 master port the
# PS uses to reach core_top's registers:
#
#   ps7 FCLK_CLK0 ----------------------------------------------> FCLK_CLK0 (33.333 MHz)
#   ps7 FCLK_RESET0_N --> proc_sys_reset --peripheral_aresetn---> PL_RESETN
#   ps7 M_AXI_GP0 (AXI3) --> axi_protocol_converter --AXI4-Lite--> M_AXI
#
# core_top's slave only speaks AXI4-Lite (single 32-bit transfers, no IDs or
# bursts); the converter turns the PS's AXI3 transactions into that. M_AXI is
# mapped at 0x43C0_0000, 128 KB. FCLK_CLK0's rate is set at run time by Linux;
# the 33.333 MHz here only has to match the XDC.
create_bd_design -dir $outdir/bd ps7_stub
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0             1 \
    CONFIG.PCW_EN_CLK0_PORT              1 \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ  33.333333 \
    CONFIG.PCW_EN_RST0_PORT              1 \
] $ps7
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK]

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]     [get_bd_pins rst/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst/ext_reset_in]

set conv [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 axi_conv]
# These normally propagate from the connections; set them explicitly when the
# IP allows it, so the intent is on record either way.
if {[catch {set_property -dict [list CONFIG.SI_PROTOCOL AXI3 CONFIG.MI_PROTOCOL AXI4LITE] $conv} err]} {
    puts "note: protocol converter settings left to propagation ($err)"
}
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi_conv/S_AXI]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]           [get_bd_pins axi_conv/aclk]
connect_bd_net [get_bd_pins rst/interconnect_aresetn] [get_bd_pins axi_conv/aresetn]

set fclk_hz [get_property CONFIG.FREQ_HZ [get_bd_pins ps7/FCLK_CLK0]]

create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI
set_property -dict [list \
    CONFIG.PROTOCOL   AXI4LITE \
    CONFIG.ADDR_WIDTH 32 \
    CONFIG.DATA_WIDTH 32 \
    CONFIG.FREQ_HZ    $fclk_hz \
] [get_bd_intf_ports M_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_conv/M_AXI] [get_bd_intf_ports M_AXI]

create_bd_port -dir O -type clk FCLK_CLK0
set_property -dict [list CONFIG.FREQ_HZ $fclk_hz CONFIG.ASSOCIATED_BUSIF M_AXI] [get_bd_ports FCLK_CLK0]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_ports FCLK_CLK0]

create_bd_port -dir O -from 0 -to 0 -type rst PL_RESETN
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_ports PL_RESETN]

assign_bd_address -target_address_space [get_bd_addr_spaces ps7/Data] \
    -offset 0x43C00000 -range 128K [get_bd_addr_segs M_AXI/Reg]

validate_bd_design
save_bd_design
set bd_file [get_files ps7_stub.bd]
generate_target all $bd_file
# The PS7 IP's XDC pins out DDR and MIO, which the block design leaves
# unconnected: those PS pins are set up by the FSBL at boot, not by the
# bitstream. Skip it; the FCLK_CLK0 clock it would also define is in
# constraints/board_top.xdc.
set_property is_enabled false [get_files ps7_stub_ps7_0.xdc]
add_files [make_wrapper -files $bd_file -top]

# --- Sources -----------------------------------------------------------------
read_vhdl {
    src/pulse_config_pkg.vhd
    src/pulse_gen.vhd
    src/trigger.vhd
    src/coincidence.vhd
    src/detector_top.vhd
    src/trap_filter.vhd
    src/energy_capture.vhd
    src/histogram.vhd
    src/axi_lite_slave.vhd
    src/core_top.vhd
    src/board_top.vhd
}
read_xdc constraints/board_top.xdc

# --- Synthesis ---------------------------------------------------------------
synth_design -top $top -part $part -generic PULSE_SET=$pulse_set
write_checkpoint -force $outdir/post_synth.dcp
report_utilization -file $outdir/utilization_synth.rpt

# --- Implementation ----------------------------------------------------------
opt_design
place_design
route_design
write_checkpoint -force $outdir/post_route.dcp

report_timing_summary -file $outdir/timing_summary.rpt
report_utilization    -file $outdir/utilization_impl.rpt
report_drc            -file $outdir/drc.rpt

# --- Bitstream ---------------------------------------------------------------
write_bitstream -force $outdir/$top.bit

# Strip the .bit header and byte-swap for the PCAP (/dev/xdevcfg). bootgen
# resolves paths from the working directory, so the .bif uses an absolute one.
set bif [open $outdir/$top.bif w]
puts $bif "all:\n{\n  [file normalize $outdir/$top.bit]\n}"
close $bif
exec bootgen -image $outdir/$top.bif -arch zynq -process_bitstream bin -w
