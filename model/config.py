"""Design constants, mirrored from the VHDL. Change both together.

PULSE_SETS mirrors src/pulse_config_pkg.vhd; K, L, TRAP_M mirror board_top's
generic map into core_top; DEFAULT_REGS mirrors core_top's register reset values.
"""

BASE = 100
DATA_WIDTH = 12
FRAC = 8            # pulse_gen fraction bits

K = 32              # trap peaking time, clocks
L = 56              # trap K + flat top, clocks
TRAP_M = 5          # decay shift: alpha = 1 - 2**-5
WINDOW = L + 16     # energy_capture window
TRIG_FILTER_WIDTH = 10

CLOCK_HZ = 33_333_333
ID_VALUE = 0x454E0001
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
)


def config_word(pulse_set):
    """Value of the CONFIG register for this build."""
    return pulse_set | (K << 8) | (L << 16) | (TRAP_M << 24)
