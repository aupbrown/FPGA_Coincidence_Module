"""Predicted behaviour of the design, from the bit-exact model.

The pulse trains are periodic, so the whole design is: after a warm-up, every
"super-period" (the least common multiple of each channel's period x number
of amplitudes) produces exactly the same events. predict() measures one
super-period, checks the next ones are identical, and returns per-super-period
counts. A run of R clocks then expects R / super-period times as many.

Run from the repository root:
    python3 -m model.expected                 # print predictions, pulse set 2
    python3 -m model.expected --set 1
    python3 -m model.expected --threshold 3 600 --gain 4
    python3 -m model.expected --vectors       # write sim/vectors/*.txt for the testbenches
"""
import argparse
import math
import os

from . import config as C
from .dsp import Core, PulseGen, TrapFilter


def super_period(pulse_set):
    return math.lcm(*(c["period"] * c["num_amps"] for c in C.PULSE_SETS[pulse_set]))


def _diff(a, b):
    out = dict(a)
    for key in ("trig_count", "event_count", "over_count", "pileup_count"):
        out[key] = [x - y for x, y in zip(a[key], b[key])]
    out["coinc_count"] = a["coinc_count"] - b["coinc_count"]
    out["hist"] = [{k: v - hb.get(k, 0) for k, v in ha.items() if v - hb.get(k, 0)}
                   for ha, hb in zip(a["hist"], b["hist"])]
    return out


def predict(pulse_set, regs=None, warm_periods=2, check_periods=2):
    """Counts produced in one super-period, in steady state."""
    sp = super_period(pulse_set)
    core = Core(pulse_set, regs)
    for _ in range(warm_periods * sp):
        core.step()
    per = []
    for _ in range(check_periods + 1):
        before = core.snapshot()
        for _ in range(sp):
            core.step()
        per.append(_diff(core.snapshot(), before))
    for p in per[1:]:
        if p != per[0]:
            raise RuntimeError("model is not periodic over one super-period")
    result = per[0]
    result["super_period"] = sp
    result["regs"] = core.regs
    return result


def describe(pred):
    sp = pred["super_period"]
    lines = [f"super-period: {sp} clocks ({sp / C.CLOCK_HZ * 1e6:.2f} us)",
             f"registers: {pred['regs']}"]
    for ch in range(4):
        bins = ", ".join(f"bin {b}: {n}" for b, n in sorted(pred["hist"][ch].items())) or "empty"
        lines.append(f"ch{ch}: triggers {pred['trig_count'][ch]}, events {pred['event_count'][ch]}, "
                     f"over range {pred['over_count'][ch]}, pile-up {pred['pileup_count'][ch]}  |  {bins}")
    lines.append(f"coincidences (pattern {pred['regs']['user_pattern']:04b}): {pred['coinc_count']}")
    lines.append("All counts are per super-period. Per second: multiply by "
                 f"{C.CLOCK_HZ / sp:.1f}.")
    return "\n".join(lines)


def write_vectors(outdir="sim/vectors", n=3000):
    """Sample-by-sample expected outputs for tb_pulse_generator and tb_trap_filter."""
    os.makedirs(outdir, exist_ok=True)
    # Pulse generator: set 2 ch0 (4 amplitudes, fast rise) and set 1 ch2
    # (slow rise, start delay). Row i = adc_out after rising edge i + 1.
    gens = [PulseGen(**C.PULSE_SETS[2][0]), PulseGen(**C.PULSE_SETS[1][2])]
    with open(os.path.join(outdir, "pulse_gen.txt"), "w") as f:
        for _ in range(n):
            for g in gens:
                g.step()
            f.write(f"{gens[0].out()} {gens[1].out()}\n")

    # Trap filter, fed set 2 ch0's pulses. Row i = input sample i, and the
    # trap output after the rising edge that samples it.
    gen, trap = PulseGen(**C.PULSE_SETS[2][0]), TrapFilter()
    with open(os.path.join(outdir, "trap_filter.txt"), "w") as f:
        for _ in range(n):
            x = gen.out()
            trap.step(x)
            gen.step()
            f.write(f"{x} {trap.out()}\n")
    print(f"wrote {outdir}/pulse_gen.txt and {outdir}/trap_filter.txt ({n} rows each)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--set", type=int, default=2, choices=sorted(C.PULSE_SETS))
    ap.add_argument("--gain", type=int)
    ap.add_argument("--pattern", type=lambda s: int(s, 0))
    ap.add_argument("--trig-width", type=int)
    ap.add_argument("--threshold", nargs=2, type=int, action="append", metavar=("CH", "VALUE"))
    ap.add_argument("--baseline", type=int)
    ap.add_argument("--vectors", action="store_true")
    a = ap.parse_args()
    if a.vectors:
        write_vectors()
        return
    regs = dict(C.DEFAULT_REGS, threshold=list(C.DEFAULT_REGS["threshold"]))
    if a.gain is not None:
        regs["conv_gain"] = a.gain
    if a.pattern is not None:
        regs["user_pattern"] = a.pattern
    if a.trig_width is not None:
        regs["trig_width"] = a.trig_width
    if a.baseline is not None:
        regs["baseline"] = a.baseline
    for ch, v in a.threshold or []:
        regs["threshold"][ch] = v
    print(describe(predict(a.set, regs)))


if __name__ == "__main__":
    main()
