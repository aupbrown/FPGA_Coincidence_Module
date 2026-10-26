"""Bit-exact, clock-by-clock Python copies of the VHDL modules.

Each class holds the module's registers. out()/properties give the values its
outputs have during the current clock (they depend only on registers, like
the VHDL's combinational outputs). step(inputs) applies one rising clock edge:
it computes every register's next value from the current registers and inputs,
then commits them all at once -- the same thing a clock edge does in hardware.

If a VHDL module changes, its class here must change the same way; the
self-checking testbenches compare the two sample by sample.
"""
from collections import deque

from . import config as C


def wrap(value, bits, signed=True):
    """Two's-complement / modular wrap to a register of the given width."""
    value &= (1 << bits) - 1
    if signed and value >= 1 << (bits - 1):
        value -= 1 << bits
    return value


class PulseGen:
    """src/pulse_gen.vhd"""
    WAIT, RISE, DECAY = range(3)

    def __init__(self, num_amps, amps, rise, period, delay,
                 base=C.BASE, decay_shift=C.TRAP_M):
        self.num_amps, self.rise, self.period, self.delay = num_amps, rise, period, delay
        self.base, self.m = base, decay_shift
        self.lw = C.DATA_WIDTH + 1 + C.FRAC
        self.inc = [(a * 2 ** C.FRAC) // rise for a in amps]
        self.state, self.count, self.level, self.idx = self.WAIT, 0, 0, 0

    def out(self):
        s = (self.level >> C.FRAC) + self.base
        return min(s, 2 ** C.DATA_WIDTH - 1)

    def step(self):
        st, cnt = self.state, self.count
        wait_done = cnt >= self.delay
        rise_done = cnt >= self.rise - 1
        decay_done = cnt >= self.period - self.rise - 1

        nst, creset = st, False
        if st == self.WAIT and wait_done:
            nst, creset = self.RISE, True
        elif st == self.RISE and rise_done:
            nst, creset = self.DECAY, True
        elif st == self.DECAY and decay_done:
            nst, creset = self.RISE, True

        mask = (1 << self.lw) - 1
        decay = ((self.level + 2 ** self.m - 1) & mask) >> self.m
        level, idx = self.level, self.idx
        if st == self.WAIT:
            level = 0
        elif st == self.RISE:
            level = (self.level - decay + self.inc[self.idx]) & mask
            if rise_done:
                idx = 0 if self.idx == self.num_amps - 1 else self.idx + 1
        else:
            level = (self.level - decay) & mask

        self.state, self.level, self.idx = nst, level, idx
        self.count = 0 if creset else (cnt + 1) & 0xFFFF


class Trigger:
    """src/trigger.vhd (filter_width = 10, acc_width = 16), unchanged design."""
    OFF, RESET, WAIT, ON, WAITOFF = range(5)

    def __init__(self, width=C.TRIG_FILTER_WIDTH):
        self.w = width
        self.delay = [0] * (width + 1)      # delay[1..width]
        self.acc = 0
        self.state = self.OFF
        self.dt = 0

    @property
    def trig_out(self):
        return self.state in (self.RESET, self.WAIT, self.ON)

    def step(self, adc, threshold, trig_width):
        comp = self.acc > threshold
        done = self.dt >= trig_width
        st = self.state
        nst, en, rst_cnt = st, False, False
        if st == self.OFF:
            nst = self.RESET if comp else self.OFF
        elif st == self.RESET:
            nst, rst_cnt = self.WAIT, True
        elif st == self.WAITOFF:
            nst = self.WAITOFF if comp else self.OFF
        elif st == self.WAIT:
            en = True
            if comp and not done:
                nst = self.WAIT
            elif done:
                nst = self.WAITOFF
            else:
                nst = self.ON
        elif st == self.ON:
            en = True
            if comp:
                nst = self.RESET
            elif done:
                nst = self.OFF

        acc = wrap(adc + self.acc - 2 * self.delay[self.w // 2] + self.delay[self.w], 16)
        self.delay = [0, adc] + self.delay[1:self.w]
        self.acc = acc
        self.dt = 0 if rst_cnt else ((self.dt + 1) & 0xFFFF if en else self.dt)
        self.state = nst


class TrapFilter:
    """src/trap_filter.vhd"""

    def __init__(self, k=C.K, l=C.L, m=C.TRAP_M, acc_width=32):
        self.k, self.l, self.m, self.aw = k, l, m, acc_width
        self.x_delay = deque([0] * k, maxlen=k)     # [0] = newest = x_delay(1)
        self.d1_delay = deque([0] * l, maxlen=l)
        self.d1 = self.d2 = self.d2_prev = 0
        self.p = self.acc1 = self.acc2 = 0

    def out(self):
        return self.acc2 >> self.m          # arithmetic shift, like shift_right(signed)

    def step(self, adc, baseline=C.BASE):
        aw = self.aw
        x = adc - baseline
        d1 = x - self.x_delay[-1]
        d2 = self.d1 - self.d1_delay[-1]
        p = wrap((self.d2 << self.m) - (self.d2_prev << self.m) + self.d2_prev, aw)
        acc1 = wrap(self.acc1 + self.p, aw)
        acc2 = wrap(self.acc2 + self.acc1, aw)
        self.x_delay.appendleft(x)
        self.d1_delay.appendleft(self.d1)
        self.d1, self.d2, self.d2_prev = d1, d2, self.d2
        self.p, self.acc1, self.acc2 = p, acc1, acc2


class EnergyCapture:
    """src/energy_capture.vhd"""
    IDLE, CAPTURE, DONE = range(3)

    def __init__(self, window=C.WINDOW):
        self.window = window
        self.state, self.trig_d, self.count, self.peak = self.IDLE, False, 0, 0

    def outputs(self, trig_in):
        """(energy, energy_valid, pileup) during this clock."""
        rise = trig_in and not self.trig_d
        energy = 0 if self.peak < 0 else self.peak
        return energy, self.state == self.DONE, rise and self.state != self.IDLE

    def step(self, trig_in, trap_in):
        rise = trig_in and not self.trig_d
        st = self.state
        if st == self.IDLE:
            if rise:
                self.state, self.count, self.peak = self.CAPTURE, 0, trap_in
        elif st == self.CAPTURE:
            if trap_in > self.peak:
                self.peak = trap_in
            if self.count == self.window - 1:
                self.state = self.DONE
            else:
                self.count += 1
        else:
            self.state = self.IDLE
        self.trig_d = trig_in


class Core:
    """src/core_top.vhd's signal chain, with run = 1 the whole time.

    The histogram FSM and the counters are modelled at event level (bin the
    energy when energy_valid is high): the FSM always finishes an event long
    before the next can arrive, so the counts are identical.
    """

    def __init__(self, pulse_set, regs=None):
        r = dict(C.DEFAULT_REGS)
        r.update(regs or {})
        self.regs = r
        self.pulses = [PulseGen(**cfg) for cfg in C.PULSE_SETS[pulse_set]]
        self.trigs = [Trigger() for _ in range(4)]
        self.traps = [TrapFilter() for _ in range(4)]
        self.caps = [EnergyCapture() for _ in range(4)]
        self.coinc = False
        self.reset_counts()

    def reset_counts(self):
        self.hist = [dict() for _ in range(4)]
        self.trig_count = [0] * 4
        self.event_count = [0] * 4
        self.over_count = [0] * 4
        self.pileup_count = [0] * 4
        self.coinc_count = 0
        self.clocks = 0
        self._trig_d = [False] * 4
        self._coinc_d = False

    def step(self):
        r = self.regs
        adc = [p.out() for p in self.pulses]
        trig = [t.trig_out for t in self.trigs]
        trap = [f.out() for f in self.traps]

        # Counters and histograms see this clock's values
        for ch in range(4):
            energy, valid, pileup = self.caps[ch].outputs(trig[ch])
            if trig[ch] and not self._trig_d[ch]:
                self.trig_count[ch] += 1
            if pileup:
                self.pileup_count[ch] += 1
            if valid:
                b = energy >> r["conv_gain"]
                if b > 4095:
                    self.over_count[ch] += 1
                else:
                    self.hist[ch][b] = self.hist[ch].get(b, 0) + 1
                    self.event_count[ch] += 1
        if self.coinc and not self._coinc_d:
            self.coinc_count += 1
        self._trig_d, self._coinc_d = trig, self.coinc
        self.clocks += 1

        # Clock edge
        bus = sum(int(t) << ch for ch, t in enumerate(trig))
        self.coinc = bus == r["user_pattern"]
        for ch in range(4):
            self.caps[ch].step(trig[ch], trap[ch])
            self.traps[ch].step(adc[ch], r["baseline"])
            self.trigs[ch].step(adc[ch], r["threshold"][ch], r["trig_width"])
            self.pulses[ch].step()

    def snapshot(self):
        return dict(hist=[dict(h) for h in self.hist],
                    trig_count=list(self.trig_count),
                    event_count=list(self.event_count),
                    over_count=list(self.over_count),
                    pileup_count=list(self.pileup_count),
                    coinc_count=self.coinc_count)
