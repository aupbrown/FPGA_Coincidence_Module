#!/usr/bin/env python3
"""Host-side control of the detector over the USB serial console -- runs ON THE PC.

The board must be booted, logged in as root on the console, with board_top
loaded (python3 scripts/serial_load.py). No other program (screen, minicom)
may hold the port. Run from the repository root:

    python3 scripts/daq.py status
    python3 scripts/daq.py set threshold 1500          # all four channels
    python3 scripts/daq.py set threshold 600 --ch 3    # one channel
    python3 scripts/daq.py set trig_width 60           # delta-t window, clocks
    python3 scripts/daq.py set pattern 0b0111          # coincidence pattern
    python3 scripts/daq.py set gain 4                  # conversion gain
    python3 scripts/daq.py set baseline 100
    python3 scripts/daq.py set polarity 0b0010         # invert ch1 (negative pulses)
    python3 scripts/daq.py set trap_m 13               # trap pole-zero: tau ~ 2**13 clocks
    python3 scripts/daq.py run --seconds 10            # acquire, fetch, compare
    python3 scripts/daq.py sweep-threshold 3 100 300 500 700 900 --seconds 1

Replaying Max's CZT waveforms (files from scripts/make_replay.py):
    python3 scripts/daq.py upload replay/photopeak/d12.bin     # to /tmp/replay on the board
    python3 scripts/daq.py replay replay/photopeak/d12.bin     # upload if needed, play, compare
    python3 scripts/daq.py replay replay/photopeak/d*.bin --per-file   # one run per depth
    python3 scripts/daq.py replay replay/random/d*.bin                 # one pooled run
replay sets SOURCE = 1 and the settings this data needs (model/replay.py's
REPLAY_REGS: TRAP_M 13, POLARITY 0010, BASELINE 200, thresholds 250; override
with --trap-m, --threshold ...). Each run is compared with model/replay.py
bin for bin. Uploads go at ~5 KB/s: ~45 s per photopeak file, ~75 s per
random file, skipped when the board already has the file (md5). /tmp is
emptied at reboot.

How it works: this script types commands into the board's root shell over the
serial line (the Console class from serial_load.py). On the board,
scripts/board/daq_board.py (copied to /tmp) reads and writes core_top's
registers and writes the result files. "run" then copies those files back
here (gzip + base64 over the console), saves them under results/, and checks
them with model/compare.py.
"""
import argparse
import base64
import gzip
import hashlib
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
from serial_load import Console          # noqa: E402  (same directory)
from model import compare, expected, replay   # noqa: E402

BOARD_SCRIPT = "/tmp/daq_board.py"
BOARD_RUN_DIR = "/tmp/daq_run"
BOARD_REPLAY_DIR = "/tmp/replay"
FILES = ["config.csv", "counters.csv"] + ["hist_ch%d.csv" % ch for ch in range(4)]


class Board:
    def __init__(self, port):
        self.con = Console(port)
        prompt = self.con.run("", timeout=3)
        if "login:" in prompt or not re.search(r"# $", prompt):
            sys.exit("No root shell on the console. Log in first (screen %s 115200), "
                     "then quit screen and rerun." % port)
        # Always send the current copy: it is small, and /tmp empties at reboot.
        with open(os.path.join(HERE, "board", "daq_board.py"), "rb") as f:
            self.con.send_file(f.read(), BOARD_SCRIPT)

    def sh(self, cmd, timeout=10):
        """Run a shell command on the board; return its output without the echo."""
        out = self.con.run(cmd, timeout=timeout)
        body = out.split("\n", 1)[-1]               # drop the echoed command
        return re.sub(r"\n?[^\n]*[#$] $", "", body).rstrip()

    def daq(self, args, timeout=20):
        out = self.sh("python3 %s %s" % (BOARD_SCRIPT, args), timeout=timeout)
        if "ERROR" in out or "Traceback" in out:
            sys.exit("board: " + out)
        return out

    def fetch(self, remote, local):
        """Copy a file from the board: gzip | base64 between two markers."""
        # The quotes split the markers in the echoed command line, so only
        # the board's real output contains them unbroken.
        out = self.con.run('echo "__BEG""IN__"; gzip -c \'%s\' | base64; echo "__EN""D__"' % remote,
                           until=r"__END__\n", timeout=60)
        m = re.search(r"__BEGIN__\n(.*)\n__END__", out, re.S)
        if not m:
            sys.exit("could not fetch %s:\n%s" % (remote, out))
        data = gzip.decompress(base64.b64decode("".join(m.group(1).split())))
        with open(local, "wb") as f:
            f.write(data)


def cmd_status(board, a):
    print(board.daq("status"))


def cmd_set(board, a):
    ch = "" if a.ch is None else " %d" % a.ch
    print(board.daq("set %s %s%s" % (a.name, a.value, ch)))


def acquire(board, seconds, tag):
    print(board.daq("run %s %s" % (seconds, BOARD_RUN_DIR), timeout=seconds + 60))
    local = os.path.join(ROOT, "results", time.strftime("run_%Y%m%d_%H%M%S") + tag)
    os.makedirs(local)
    for name in FILES:
        board.fetch("%s/%s" % (BOARD_RUN_DIR, name), os.path.join(local, name))
    print("saved %s" % os.path.relpath(local, ROOT))
    return local


def cmd_run(board, a):
    local = acquire(board, a.seconds, "")
    ok = compare.compare(local)
    sys.exit(0 if ok else 1)


def cmd_sweep_threshold(board, a):
    """Trigger rate vs threshold on one channel, measured and predicted."""
    rows = []
    for th in a.values:
        board.daq("set threshold %d %d" % (th, a.ch))
        local = acquire(board, a.seconds, "_th%d" % th)
        cfg = compare.read_kv(os.path.join(local, "config.csv"))
        cnt = compare.read_kv(os.path.join(local, "counters.csv"))
        pred = expected.predict(cfg["config"] & 0xFF, compare.regs_from_config(cfg))
        want = pred["trig_count"][a.ch] * cnt["run_clocks"] / pred["super_period"]
        rows.append((th, cnt["trig_count_%d" % a.ch], want))
    print("\nthreshold  triggers  predicted")
    for th, got, want in rows:
        flag = "" if abs(got - want) <= 5 else "   <-- differs"
        print("%9d  %8d  %9.0f%s" % (th, got, want, flag))


def board_path(local):
    """replay/photopeak/d12.bin -> /tmp/replay/photopeak/d12.bin"""
    parent = os.path.basename(os.path.dirname(os.path.abspath(local)))
    return "%s/%s/%s" % (BOARD_REPLAY_DIR, parent, os.path.basename(local))


def upload(board, files):
    for local in files:
        data = open(local, "rb").read()
        md5 = hashlib.md5(data).hexdigest()
        remote = board_path(local)
        if md5 in board.sh("md5sum %s 2>/dev/null" % remote):
            print("%s: already on the board" % remote)
            continue
        t = time.time()
        board.sh("mkdir -p %s" % os.path.dirname(remote))
        board.con.send_file(gzip.compress(data, 9), remote + ".gz")
        out = board.sh("gunzip -f %s.gz && md5sum %s" % (remote, remote), timeout=30)
        if md5 not in out:
            sys.exit("md5 mismatch on the board for %s:\n%s" % (remote, out))
        print("%s: sent %d bytes in %.0f s, md5 ok" % (remote, len(data), time.time() - t))


def cmd_upload(board, a):
    upload(board, a.files)


def replay_run(board, files, tag):
    out = board.daq("replay %s %s" % (BOARD_RUN_DIR, " ".join(board_path(f) for f in files)),
                    timeout=60 + 15 * len(files))
    print(out)
    local = os.path.join(ROOT, "results", time.strftime("replay_%Y%m%d_%H%M%S") + tag)
    os.makedirs(local)
    for name in FILES:
        board.fetch("%s/%s" % (BOARD_RUN_DIR, name), os.path.join(local, name))
    # The local copies of the played files, for model.compare
    with open(os.path.join(local, "replay_files.txt"), "w") as f:
        f.write("".join(os.path.relpath(os.path.abspath(p), ROOT) + "\n" for p in files))
    print("saved %s" % os.path.relpath(local, ROOT))
    return compare.compare(local)


def cmd_replay(board, a):
    upload(board, a.files)
    regs = replay.REPLAY_REGS
    settings = [("trap_m", a.trap_m), ("polarity", a.polarity), ("baseline", a.baseline)]
    for name, value in settings:
        board.daq("set %s %s" % (name, value))
    for ch, th in enumerate(a.threshold or regs["threshold"][:2]):
        board.daq("set threshold %d %d" % (th, ch))
    board.daq("set threshold %d 2" % regs["threshold"][2])
    board.daq("set threshold %d 3" % regs["threshold"][3])
    if a.per_file:
        results = [replay_run(board, [f], "_" + os.path.splitext(os.path.basename(f))[0])
                   for f in a.files]
        print("\n%d of %d runs PASS" % (sum(results), len(results)))
        ok = all(results)
    else:
        ok = replay_run(board, a.files, "")
    sys.exit(0 if ok else 1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default="/dev/ttyUSB0")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    p = sub.add_parser("set")
    p.add_argument("name", choices=["threshold", "trig_width", "pattern", "gain", "baseline",
                                    "polarity", "trap_m", "source"])
    p.add_argument("value")
    p.add_argument("--ch", type=int, choices=range(4))
    p = sub.add_parser("run")
    p.add_argument("--seconds", type=float, default=10)
    p = sub.add_parser("sweep-threshold")
    p.add_argument("ch", type=int, choices=range(4))
    p.add_argument("values", type=int, nargs="+")
    p.add_argument("--seconds", type=float, default=1)
    p = sub.add_parser("upload")
    p.add_argument("files", nargs="+")
    p = sub.add_parser("replay")
    p.add_argument("files", nargs="+")
    p.add_argument("--per-file", action="store_true", help="one run (and result folder) per file")
    p.add_argument("--trap-m", type=int, default=replay.REPLAY_REGS["trap_m"])
    p.add_argument("--polarity", default=bin(replay.REPLAY_REGS["polarity"]))
    p.add_argument("--baseline", type=int, default=replay.REPLAY_REGS["baseline"])
    p.add_argument("--threshold", type=int, nargs=2, metavar=("CH0", "CH1"),
                   help="trigger thresholds for ch0 (anode) and ch1 (cathode); default 250 250")
    a = ap.parse_args()

    board = Board(a.port)
    {"status": cmd_status, "set": cmd_set, "run": cmd_run,
     "sweep-threshold": cmd_sweep_threshold, "upload": cmd_upload,
     "replay": cmd_replay}[a.cmd](board, a)


if __name__ == "__main__":
    main()
