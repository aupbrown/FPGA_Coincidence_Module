#!/bin/sh
# ----------------------------------------------------------------------------
# Load board_top into the PL from PetaLinux -- runs ON THE BOARD.
#
# Written for Avnet's PicoZed 7030 FMC Carrier V2 out-of-box image (PetaLinux
# 2017.4, BusyBox). Usage:
#   sh load_board_top.sh [BITSTREAM]       default: /mnt/board_top.bit.bin
#
# Steps, each of which was needed to get a working load:
#   1. Stop Avnet's web demo and unbind the Linux drivers for the PL
#      peripherals in Avnet's design. Reconfiguring the PL under a driver that
#      is still using it hangs the AXI bus and freezes Linux.
#   2. Set FCLK_CLK0, board_top's clock, to 33.333 MHz and enable it. The rate
#      and enable live in the PS, not in the bitstream, and reset at reboot.
#   3. Write the bitstream to /dev/xdevcfg and check that DONE went high.
#   4. Make sure the PS-PL AXI path is open (level shifters on, PL reset
#      released), then read core_top's ID register at 0x43C0_0000.
#
# Avnet's design reloads from BOOT.BIN at every boot, so run this after each
# reboot.
# ----------------------------------------------------------------------------

BIT=${1:-/mnt/board_top.bit.bin}
DEVCFG=/sys/devices/soc0/amba/f8007000.devcfg
FCLK=/sys/class/fclk/fclk0
RATE=33333333                     # IO PLL 1000 MHz / 30

fail() { echo "ERROR: $*"; exit 1; }

[ -f "$BIT" ] || fail "$BIT not found (is the SD card mounted? mount /dev/mmcblk0p1 /mnt)"

# --- 1. Release the PL -------------------------------------------------------
killall python3 httpd 2>/dev/null

for entry in 41200000.gpio:xilinx-gpio 41210000.gpio:xilinx-gpio 41600000.i2c:xiic-i2c; do
    dev=${entry%%:*}
    drv=${entry##*:}
    if [ -e /sys/bus/platform/devices/$dev/driver ]; then
        echo "unbinding $dev ($drv)"
        echo "$dev" > /sys/bus/platform/drivers/$drv/unbind
    fi
done

# PL peripherals sit at 0x4000_0000-0xBFFF_FFFF: device names with an 8-digit
# address starting 4-b. (Short names like 700.pinctrl are offsets inside the
# PS.) Refuse to load if any still has a driver, e.g. on a different image.
for d in /sys/bus/platform/devices/[4-9ab][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].*; do
    [ -e "$d/driver" ] && fail "$(basename "$d") still has a driver; unbind it first"
done

# --- 2. Clock ----------------------------------------------------------------
[ -d $FCLK ] || echo fclk0 > $DEVCFG/fclk_export
echo $RATE > $FCLK/set_rate
echo 1 > $FCLK/enable
[ "$(cat $FCLK/set_rate)" = "$RATE" ] || fail "FCLK_CLK0 is $(cat $FCLK/set_rate) Hz, not $RATE"
echo "FCLK_CLK0 = $RATE Hz, enabled"

# --- 3. Load -----------------------------------------------------------------
rm -f /tmp/board_top.loaded               # stale marker from an earlier load
echo 0 > $DEVCFG/is_partial_bitstream
cat "$BIT" > /dev/xdevcfg || fail "write to /dev/xdevcfg failed"
[ "$(cat $DEVCFG/prog_done)" = "1" ] || fail "DONE did not go high"
echo "loaded $BIT: DONE = 1"

# --- 4. PS-PL AXI path -------------------------------------------------------
# An AXI read from the PS waits forever for a reply. If the PL cannot answer
# (level shifters off, or the PL held in reset), Linux freezes. So check both
# before the first read. SLCR registers (Zynq TRM, ug585):
#   0xF8000008 SLCR_UNLOCK   write 0xDF0D to allow SLCR writes
#   0xF8000240 FPGA_RST_CTRL bit 0 = FCLK_RESET0 asserted: must be 0
#   0xF8000900 LVL_SHFTR_EN  0xF = all PS<->PL level shifters enabled
command -v devmem >/dev/null || fail "no devmem on this image; cannot check the AXI path"
SLCR_UNLOCK=0xF8000008
FPGA_RST_CTRL=0xF8000240
LVL_SHFTR_EN=0xF8000900
CORE_ID=0x43C00000
ID_VALUE=0x454E0001

lvl=$(devmem $LVL_SHFTR_EN)
rstc=$(devmem $FPGA_RST_CTRL)
echo "LVL_SHFTR_EN = $lvl, FPGA_RST_CTRL = $rstc"
if [ $((lvl & 0xF)) -ne 15 ] || [ $((rstc & 0xF)) -ne 0 ]; then
    echo "enabling level shifters and releasing PL resets"
    devmem $SLCR_UNLOCK 32 0xDF0D
    devmem $LVL_SHFTR_EN 32 0xF
    devmem $FPGA_RST_CTRL 32 0
fi

id=$(devmem $CORE_ID)
[ $((id)) -eq $((ID_VALUE)) ] || fail "core_top ID is $id, expected $ID_VALUE"
echo "core_top ID = $id"
md5sum "$BIT" > /tmp/board_top.loaded    # daq_board.py checks this before touching the bus
