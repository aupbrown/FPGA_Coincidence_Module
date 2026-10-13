# ----------------------------------------------------------------------------
# board_top constraints -- PicoZed 7030 + FMC Carrier V2
#
# Pin numbers come from Avnet's master XDC, PZ7030_7015_RevC_FMCV2_Rev1_v1.xdc.
# Each pin comment gives: <net name on the schematic>, <connector.pin>, <bank>.
#
# Two I/O banks are used:
#   Bank 13 -- fixed at 3.3 V by the carrier.
#   Bank 35 -- powered by the carrier's VADJ supply. On the 7030 this is a
#              High Performance bank that tolerates at most 1.8 V, so VADJ
#              MUST be set to 1.8 V. Check the carrier's VADJ setting before
#              powering up.
#
# The heartbeat is kept on a 3.3 V LED because it is the first thing to check
# at bring-up. The LED in Bank 35 carries a pattern bit and may look dimmer.
# ----------------------------------------------------------------------------

# --- Clock input -------------------------------------------------------------
set_property PACKAGE_PIN Y18  [get_ports {clk}];       # PL_CLK,  JX3.73, Bank 13
set_property IOSTANDARD LVCMOS33 [get_ports {clk}];

# 33.333 MHz on-board oscillator -> 30 ns period
create_clock -period 30.000 -name sys_clk [get_ports {clk}];

# --- Push button -------------------------------------------------------------
set_property PACKAGE_PIN T16  [get_ports {btn}];       # PL_PB2,  JX2.100, Bank 13
set_property IOSTANDARD LVCMOS33 [get_ports {btn}];

# --- LEDs --------------------------------------------------------------------
set_property PACKAGE_PIN AA19 [get_ports {led[0]}];    # PL_LED2, JX2.97, Bank 13 -- coincidence
set_property PACKAGE_PIN AA20 [get_ports {led[1]}];    # PL_LED3, JX2.99, Bank 13 -- pattern bit 0
set_property PACKAGE_PIN G3   [get_ports {led[2]}];    # PL_LED1, JX1.17, Bank 35 -- pattern bit 1
set_property PACKAGE_PIN AB21 [get_ports {led[3]}];    # PL_LED4, JX2.93, Bank 13 -- heartbeat

set_property IOSTANDARD LVCMOS33 [get_ports {led[0] led[1] led[3]}];
set_property IOSTANDARD LVCMOS18 [get_ports {led[2]}];

# --- Asynchronous I/O --------------------------------------------------------
# The button is pressed by a human and the LEDs are watched by one; neither has
# any timing relationship to sys_clk, so exclude them from timing analysis.
# The debouncer's two-flop synchronizer handles the button's asynchrony.
set_false_path -from [get_ports {btn}];
set_false_path -to   [get_ports {led[*]}];
