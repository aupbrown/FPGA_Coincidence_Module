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
echo 0 > $DEVCFG/is_partial_bitstream
cat "$BIT" > /dev/xdevcfg || fail "write to /dev/xdevcfg failed"
[ "$(cat $DEVCFG/prog_done)" = "1" ] || fail "DONE did not go high"
echo "loaded $BIT: DONE = 1"
