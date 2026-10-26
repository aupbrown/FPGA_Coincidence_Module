# ----------------------------------------------------------------------------
# board_top constraints -- PicoZed 7030 + FMC Carrier V2
#
# The design has no package pins: the LEDs and push button are gone, and all
# control and readout goes through the PS's AXI GP0 port. That leaves only the
# clock.
#
# There is no PL clock pin. Avnet's master XDC lists a PL_CLK on Y18 (JX3.73),
# but a bring-up bitstream showed no clock there on this carrier, so the
# design runs on the PS's FCLK_CLK0 instead (see src/board_top.vhd).
# ----------------------------------------------------------------------------

# --- Clock -------------------------------------------------------------------
# FCLK_CLK0 from the PS7 block, set by Linux to 33.333 MHz (IO PLL 1000 MHz
# / 30) -> 30 ns period. The PS7 IP's own XDC (which would define this clock)
# is disabled in build.tcl.
create_clock -period 30.000 -name clk_fpga_0 [get_pins -hierarchical {*PS7_i/FCLKCLK[0]}];
