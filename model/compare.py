"""Compare a run's result files with the model's prediction.

A run directory holds the files written by either the board
(scripts/board/daq_board.py) or the simulation (sim/tb_core_top.vhd):
    config.csv     register settings during the run (name,value)
    counters.csv   run_clocks and all counters (name,value)
    hist_ch0..3.csv  bin,count

Checks:
  * ID and CONFIG registers match this model (same build, same pulse set)
  * every histogram has counts in exactly the predicted bins, and nowhere else
  * each bin's count, and every counter, equals prediction x (run_clocks /
    super-period), within the per-super-period count + 1 (the run can start
    and stop part-way through a super-period)

    python3 -m model.compare build/sim_out/run_default
    python3 -m model.compare results/run_20261026_120000
Exit status 0 = PASS, 1 = FAIL.
"""
import csv
import os
import sys

from . import config as C
from .expected import predict


def read_kv(path):
    with open(path) as f:
        return {row[0]: int(row[1], 0) for row in csv.reader(f) if row and row[0] != "name"}


def read_hist(path):
    with open(path) as f:
        rows = list(csv.reader(f))
    return {int(b): int(n) for b, n in rows[1:] if int(n)}


def regs_from_config(cfg):
    return dict(conv_gain=cfg["conv_gain"], user_pattern=cfg["user_pattern"],
                trig_width=cfg["trig_width"], baseline=cfg["baseline"],
                threshold=[cfg[f"threshold_{ch}"] for ch in range(4)])


def compare(run_dir, out=print):
    cfg = read_kv(os.path.join(run_dir, "config.csv"))
    cnt = read_kv(os.path.join(run_dir, "counters.csv"))
    hists = [read_hist(os.path.join(run_dir, f"hist_ch{ch}.csv")) for ch in range(4)]

    failures = []

    def check(ok, msg):
        out(("  ok    " if ok else "  FAIL  ") + msg)
        if not ok:
            failures.append(msg)

    pulse_set = cfg["config"] & 0xFF
    check(cfg["id"] == C.ID_VALUE, f"ID 0x{cfg['id']:08X} (expect 0x{C.ID_VALUE:08X})")
    check(pulse_set in C.PULSE_SETS and cfg["config"] == C.config_word(pulse_set),
          f"CONFIG 0x{cfg['config']:08X}: pulse set {pulse_set}, K {cfg['config'] >> 8 & 0xFF}, "
          f"L {cfg['config'] >> 16 & 0xFF}, M {cfg['config'] >> 24} "
          f"(model: K {C.K}, L {C.L}, M {C.TRAP_M})")
    if failures:
        return False

    regs = regs_from_config(cfg)
    pred = predict(pulse_set, regs)
    sp = pred["super_period"]
    periods = cnt["run_clocks"] / sp
    out(f"run: {cnt['run_clocks']} clocks = {cnt['run_clocks'] / C.CLOCK_HZ:.4f} s "
        f"= {periods:.2f} super-periods of {sp} clocks")
    out(f"registers: {regs}")

    def near(name, got, per_sp):
        expect = per_sp * periods
        check(abs(got - expect) <= per_sp + 1,
              f"{name}: {got} (expect {expect:.1f} +/- {per_sp + 1})")

    for ch in range(4):
        out(f"channel {ch}")
        want = pred["hist"][ch]
        check(set(hists[ch]) == set(want),
              f"nonzero bins {sorted(hists[ch])[:12]}{' ...' if len(hists[ch]) > 12 else ''} "
              f"(expect {sorted(want)})")
        for b, per_sp in sorted(want.items()):
            near(f"bin {b}", hists[ch].get(b, 0), per_sp)
        for key in ("trig_count", "event_count", "over_count", "pileup_count"):
            near(key, cnt[f"{key}_{ch}"], pred[key][ch])
        check(sum(hists[ch].values()) == cnt[f"event_count_{ch}"],
              f"histogram total {sum(hists[ch].values())} = event_count {cnt[f'event_count_{ch}']}")
    out("coincidence")
    near(f"coinc_count (pattern {regs['user_pattern']:04b})", cnt["coinc_count"], pred["coinc_count"])

    out(f"{'PASS' if not failures else 'FAIL'}: {run_dir}")
    return not failures


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    ok = all([compare(d) for d in sys.argv[1:]])
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
