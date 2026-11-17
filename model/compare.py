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

Replay runs (config.csv has source = 1) are checked against model/replay.py
instead, exactly: every bin and counter (except run_clocks) must be equal.
The run directory's replay_files.txt lists the files played, in order, one
path per line, relative to the repository root.
"""
import csv
import os
import sys

from . import config as C
from . import replay
from .expected import predict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_kv(path):
    with open(path) as f:
        return {row[0]: int(row[1], 0) for row in csv.reader(f) if row and row[0] != "name"}


def read_hist(path):
    with open(path) as f:
        rows = list(csv.reader(f))
    return {int(b): int(n) for b, n in rows[1:] if int(n)}


def regs_from_config(cfg):
    # Fields missing from older runs (polarity, trap_m before ID v2, blr_enable
    # before v3) take their reset values.
    return dict(conv_gain=cfg["conv_gain"], user_pattern=cfg["user_pattern"],
                trig_width=cfg["trig_width"], baseline=cfg["baseline"],
                threshold=[cfg[f"threshold_{ch}"] for ch in range(4)],
                polarity=cfg.get("polarity", C.DEFAULT_REGS["polarity"]),
                trap_m=cfg.get("trap_m", C.DEFAULT_REGS["trap_m"]),
                blr_enable=cfg.get("blr_enable", C.DEFAULT_REGS["blr_enable"]))


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
    regs = regs_from_config(cfg)
    source = cfg.get("source", 0)
    check(cfg["id"] in (C.ID_VALUE, C.ID_V2, C.ID_V1), f"ID 0x{cfg['id']:08X} (expect 0x{C.ID_VALUE:08X})")
    check(pulse_set in C.PULSE_SETS and cfg["config"] == C.config_word(pulse_set, regs["trap_m"]),
          f"CONFIG 0x{cfg['config']:08X}: pulse set {pulse_set}, K {cfg['config'] >> 8 & 0xFF}, "
          f"L {cfg['config'] >> 16 & 0xFF}, M {cfg['config'] >> 24} "
          f"(model: K {C.K}, L {C.L}, M {regs['trap_m']})")
    if failures:
        return False
    if source:
        return compare_replay(run_dir, regs, cnt, hists, check, failures, out)

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


def compare_replay(run_dir, regs, cnt, hists, check, failures, out):
    with open(os.path.join(run_dir, "replay_files.txt")) as f:
        files = [ln.strip() for ln in f if ln.strip()]
    paths = [p if os.path.isabs(p) else os.path.join(ROOT, p) for p in files]
    out(f"replay of {len(files)} file(s): {files[0]}{' ...' if len(files) > 1 else ''}")
    out(f"registers: {regs}")
    pred = replay.predict(paths, regs)
    for ch in range(4):
        out(f"channel {ch}")
        want, got = pred["hist"][ch], hists[ch]
        diff = sorted(b for b in set(want) | set(got) if want.get(b, 0) != got.get(b, 0))
        check(not diff, f"histogram: {sum(got.values())} counts in {len(got)} bins, "
                        f"{len(diff)} bins differ from the model{' ' + str(diff[:8]) if diff else ''}")
        for key in ("trig_count", "event_count", "over_count", "pileup_count"):
            check(cnt[f"{key}_{ch}"] == pred[key][ch],
                  f"{key}: {cnt[f'{key}_{ch}']} (expect {pred[key][ch]})")
    out("coincidence")
    check(cnt["coinc_count"] == pred["coinc_count"],
          f"coinc_count (pattern {regs['user_pattern']:04b}): {cnt['coinc_count']} "
          f"(expect {pred['coinc_count']})")
    out(f"{'PASS' if not failures else 'FAIL'}: {run_dir}")
    return not failures


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    ok = all([compare(d) for d in sys.argv[1:]])
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
