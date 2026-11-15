"""Bit-exact prediction for replay runs: recorded waveforms played into ch0/ch1.

A replay file (scripts/make_replay.py) holds one 32-bit word per sample:
[11:0] goes to ch0 (lane A), [27:16] to ch1 (lane B). ch2 and ch3 see a
constant BASELINE while SOURCE = 1. For each file the hardware (see
src/replay_source.vhd and core_top) does:

    idle   -- run = 0 while the PS loads the buffer, then the first clock of
              run = 1. The player outputs word 0; trap filters held in reset.
    play   -- one word per clock, words 0 .. N-1, trap filters running.
    after  -- back to word 0, trap filters in reset, until the PS stops the run.

Histograms and counters accumulate over all the files in a run. The idle time
between files is long and unknown, but it does not matter: with the traps in
reset and a constant input, every other register settles to the same state
in fewer than SETTLE clocks. The model runs SETTLE idle clocks before and
counting clocks after each file. With the input fixed, the prediction is
exact: compare a run bin for bin, with no tolerance (except run_clocks, set
by how long the PS takes to stop the run).

    python3 -m model.replay replay/photopeak/d12.bin               # print a summary
    python3 -m model.replay replay/random/d*.bin --out results/model_random
    python3 -m model.replay FILE --threshold 0 300 --trap-m 13     # other settings

--out writes the board's file format, so scripts/plot_hist.py can plot it.
"""
import argparse
import array
import math
import os
import sys

from . import config as C
from .dsp import EnergyCapture, TrapFilter, Trigger

BUFFER_WORDS = 1 << 17
ANODE_OFFSET = 200      # as in scripts/make_replay.py
CATHODE_OFFSET = 3895

# Settings for Max's CZT data, as packed by scripts/make_replay.py.
# trap_m 13: the preamp decays with tau ~ 8300 samples (2**13 = 8192).
# polarity 0b0010: invert ch1, the negative-going cathode. baseline 200: both
# lanes' offset. threshold 250: the trigger filter peaks at ~2.7 x the pulse
# amplitude and its noise is sigma ~ 37 on this data. A scan of 5 random-set
# depths gave noise triggers in ch0 of 25 / 11 / 3 / 1 at 200 / 220 / 240 / 260.
# The default 1250 would cut everything below ~460 ADU (most of the Compton
# continuum).
REPLAY_REGS = dict(C.DEFAULT_REGS, trap_m=13, polarity=0b0010, baseline=200,
                   threshold=[250, 250, 250, 250])


def read_words(path):
    """A replay file: .bin (little-endian uint32) or .txt (one integer per line)."""
    if path.endswith(".txt"):
        with open(path) as f:
            return [int(s, 0) for s in f.read().split()]
    words = array.array("I")
    with open(path, "rb") as f:
        words.frombytes(f.read())
    if sys.byteorder == "big":
        words.byteswap()
    return list(words)


def synthetic_events(events, seed=1):
    """Replay words for CZT-like events, standard library only (for the testbench).

    events: list of (anode, cathode, pileup) amplitudes in ADU, where pileup is
    None or (delay, anode, cathode) for a second pulse on top of the first.
    Each event is 512 samples like scripts/make_replay.py's: 160 baseline
    samples, then the edge. Anode positive (rise 10), cathode negative (rise
    30), tau 8300 samples, approximately Gaussian noise of sigma ~ 18.
    """
    x = seed

    def noise():
        nonlocal x
        total = 0
        for _ in range(4):
            x = (1103515245 * x + 12345) % 2 ** 31
            total += x
        return (total >> 26) - 64

    def pulse(n, amp, rise):
        if n < 0:
            return 0.0
        return amp * min(n / rise, 1.0) * math.exp(-n / 8300.0)

    words = []
    for anode, cathode, pile in events:
        for n in range(512):
            a = pulse(n - 160, anode, 10)
            c = pulse(n - 160, cathode, 30)
            if pile:
                a += pulse(n - 160 - pile[0], pile[1], 10)
                c += pulse(n - 160 - pile[0], pile[2], 30)
            la = min(max(round(a) + noise() + ANODE_OFFSET, 0), 4095)
            lb = min(max(-round(c) + noise() + CATHODE_OFFSET, 0), 4095)
            words.append(la | lb << 16)
    return words


# Two "files" for sim/tb_replay.vhd: photopeak-, Compton- and noise-like events,
# one pile-up, and one anode-only event.
VECTOR_FILES = {
    "replay_a.txt": [(900, 300, None), (450, 800, None), (1500, 120, None),
                     (0, 0, None), (700, 500, (40, 300, 200)), (150, 0, None)],
    "replay_b.txt": [(880, 650, None), (300, 250, None), (1617, 860, None), (950, 330, None)],
}


def write_vectors(outdir="sim/vectors"):
    os.makedirs(outdir, exist_ok=True)
    for i, (name, events) in enumerate(sorted(VECTOR_FILES.items())):
        with open(os.path.join(outdir, name), "w") as f:
            f.write("".join("%d\n" % w for w in synthetic_events(events, seed=i + 1)))
    print("wrote %s/%s" % (outdir, " and ".join(sorted(VECTOR_FILES))))


def settle_clocks(regs):
    return regs["trig_width"] + C.WINDOW + 2 * C.TRIG_FILTER_WIDTH + 16


class Replay:
    """core_top with SOURCE = 1, at the same clock-by-clock level as dsp.Core."""

    def __init__(self, regs=None):
        r = dict(REPLAY_REGS)
        r.update(regs or {})
        self.regs = r
        self.trigs = [Trigger() for _ in range(4)]
        self.traps = [TrapFilter(m=r["trap_m"]) for _ in range(4)]
        self.caps = [EnergyCapture() for _ in range(4)]
        self.coinc = False
        self.hist = [dict() for _ in range(4)]
        self.trig_count = [0] * 4
        self.event_count = [0] * 4
        self.over_count = [0] * 4
        self.pileup_count = [0] * 4
        self.coinc_count = 0
        self.samples = 0
        self._trig_d = [False] * 4
        self._coinc_d = False

    def adc(self, word):
        r = self.regs
        raw = [word & 0xFFF, (word >> 16) & 0xFFF, r["baseline"], r["baseline"]]
        return [x ^ 0xFFF if r["polarity"] >> ch & 1 else x for ch, x in enumerate(raw)]

    def clock(self, adc, playing, counting):
        """One clock: outputs, then the rising edge. Mirrors dsp.Core.step."""
        r = self.regs
        trig = [t.trig_out for t in self.trigs]
        trap = [f.out() for f in self.traps]
        if counting:
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

        bus = sum(int(t) << ch for ch, t in enumerate(trig))
        self.coinc = bus == r["user_pattern"]
        for ch in range(4):
            self.caps[ch].step(trig[ch], trap[ch])
            if playing:
                self.traps[ch].step(adc[ch], r["baseline"])
            else:
                self.traps[ch] = TrapFilter(m=r["trap_m"])     # synchronous reset
            self.trigs[ch].step(adc[ch], r["threshold"][ch], r["trig_width"])

    def play(self, words):
        if not 0 < len(words) <= BUFFER_WORDS:
            raise ValueError("a replay file holds 1 to %d words" % BUFFER_WORDS)
        idle = self.adc(words[0])
        n = settle_clocks(self.regs)
        for _ in range(n):
            self.clock(idle, False, False)
        for w in words:
            self.clock(self.adc(w), True, True)
        for _ in range(n):
            self.clock(idle, False, True)
        self.samples += len(words)

    def snapshot(self):
        return dict(hist=[dict(h) for h in self.hist],
                    trig_count=list(self.trig_count),
                    event_count=list(self.event_count),
                    over_count=list(self.over_count),
                    pileup_count=list(self.pileup_count),
                    coinc_count=self.coinc_count,
                    samples=self.samples,
                    regs=self.regs)


def predict(paths, regs=None):
    """Exact histograms and counters after playing the files in order, in one run."""
    rep = Replay(regs)
    for p in paths:
        rep.play(read_words(p))
    return rep.snapshot()


def write_run(pred, outdir):
    """The prediction in the board's file format (config/counters/hist csv)."""
    r = pred["regs"]
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "config.csv"), "w") as f:
        f.write("name,value\n")
        for n in ("conv_gain", "user_pattern", "trig_width", "baseline", "trap_m", "polarity"):
            f.write("%s,%d\n" % (n, r[n]))
        for ch in range(4):
            f.write("threshold_%d,%d\n" % (ch, r["threshold"][ch]))
    with open(os.path.join(outdir, "counters.csv"), "w") as f:
        f.write("name,value\n")
        f.write("run_clocks,%d\n" % pred["samples"])
        f.write("coinc_count,%d\n" % pred["coinc_count"])
        for ch in range(4):
            for key in ("trig_count", "event_count", "over_count", "pileup_count"):
                f.write("%s_%d,%d\n" % (key, ch, pred[key][ch]))
    for ch in range(4):
        with open(os.path.join(outdir, "hist_ch%d.csv" % ch), "w") as f:
            f.write("bin,count\n")
            for b in range(4096):
                f.write("%d,%d\n" % (b, pred["hist"][ch].get(b, 0)))


def describe(pred):
    lines = ["%d samples, registers: %s" % (pred["samples"], pred["regs"])]
    for ch in range(4):
        h = pred["hist"][ch]
        line = ("ch%d: triggers %d, events %d, over range %d, pile-up %d"
                % (ch, pred["trig_count"][ch], pred["event_count"][ch],
                   pred["over_count"][ch], pred["pileup_count"][ch]))
        if h:
            cum, total, pct = 0, sum(h.values()), {}
            for b in sorted(h):
                cum += h[b]
                for q in (5, 50, 95):
                    if q not in pct and cum >= total * q / 100:
                        pct[q] = b
            line += "  |  bins %d..%d, 5/50/95 %% at %d/%d/%d" % (
                min(h), max(h), pct[5], pct[50], pct[95])
        lines.append(line)
    lines.append("coincidences (pattern %s): %d"
                 % (format(pred["regs"]["user_pattern"], "04b"), pred["coinc_count"]))
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--gain", type=int)
    ap.add_argument("--pattern", type=lambda s: int(s, 0))
    ap.add_argument("--trig-width", type=int)
    ap.add_argument("--threshold", nargs=2, type=int, action="append", metavar=("CH", "VALUE"))
    ap.add_argument("--baseline", type=int)
    ap.add_argument("--trap-m", type=int)
    ap.add_argument("--polarity", type=lambda s: int(s, 0))
    ap.add_argument("--out", help="also write the prediction as a run directory")
    a = ap.parse_args()
    regs = dict(REPLAY_REGS, threshold=list(REPLAY_REGS["threshold"]))
    for key, val in (("conv_gain", a.gain), ("user_pattern", a.pattern), ("trig_width", a.trig_width),
                     ("baseline", a.baseline), ("trap_m", a.trap_m), ("polarity", a.polarity)):
        if val is not None:
            regs[key] = val
    for ch, v in a.threshold or []:
        regs["threshold"][ch] = v
    pred = predict(a.files, regs)
    print(describe(pred))
    if a.out:
        write_run(pred, a.out)
        print("wrote " + a.out)


if __name__ == "__main__":
    main()
