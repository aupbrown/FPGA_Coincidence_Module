"""Design constants, mirrored from the VHDL. Change both together.

PULSE_SETS mirrors src/pulse_config_pkg.vhd; K, L, TRAP_M mirror board_top's
generic map into core_top; DEFAULT_REGS mirrors core_top's register reset values.
"""

BASE = 100
DATA_WIDTH = 12
FRAC = 8            # pulse_gen fraction bits

K = 32              # trap peaking time, clocks
L = 56              # trap K + flat top, clocks
TRAP_M = 5          # reset value of the TRAP_M register (and pulse_gen's decay): alpha = 1 - 2**-5
WINDOW = L + 16     # energy_capture window
TRIG_FILTER_WIDTH = 10

CLOCK_HZ = 50_000_000
ID_VALUE = 0x454E0003
ID_V2 = 0x454E0002  # before the baseline restorer (BLR_ENABLE)
ID_V1 = 0x454E0001  # before POLARITY/TRAP_M: results/ runs up to 2026-10-26
REG_BASE = 0x43C00000

# One dict per channel: num_amps, amps, rise, period, delay
PULSE_SETS = {
    1: [
        dict(num_amps=1, amps=[2000, 0, 0, 0], rise=20, period=512, delay=0),
        dict(num_amps=1, amps=[2000, 0, 0, 0], rise=20, period=512, delay=0),
        dict(num_amps=1, amps=[2000, 0, 0, 0], rise=20, period=512, delay=40),
        dict(num_amps=1, amps=[2000, 0, 0, 0], rise=20, period=512, delay=40),
    ],
    2: [
        dict(num_amps=4, amps=[500, 1000, 1500, 2000], rise=4, period=512, delay=0),
        dict(num_amps=1, amps=[3000, 0, 0, 0], rise=4, period=512, delay=0),
        dict(num_amps=2, amps=[800, 2400, 0, 0], rise=4, period=512, delay=40),
        dict(num_amps=1, amps=[200, 0, 0, 0], rise=4, period=512, delay=40),
    ],
}

DEFAULT_REGS = dict(
    conv_gain=5,
    user_pattern=0b0011,
    trig_width=50,
    threshold=[1250, 1250, 1250, 1250],
    baseline=100,
    polarity=0b0000,
    trap_m=TRAP_M,
    blr_enable=0b0000,
)

BLR_NSHIFT = 8          # baseline_restorer: mean of 2**8 quiet samples
BLR_HOLD = 2 * (K + L)  # quiet clocks needed after busy (trigger or |trap| > BLR_LIMIT)
BLR_LIMIT = 1024        # trap units


def config_word(pulse_set, trap_m=TRAP_M):
    """Value of the CONFIG register for this build and TRAP_M register value."""
    return pulse_set | (K << 8) | (L << 16) | (trap_m << 24)
