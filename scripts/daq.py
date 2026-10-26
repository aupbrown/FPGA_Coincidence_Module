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
    python3 scripts/daq.py run --seconds 10            # acquire, fetch, compare
    python3 scripts/daq.py sweep-threshold 3 100 300 500 700 900 --seconds 1

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
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
from serial_load import Console          # noqa: E402  (same directory)
from model import compare, expected      # noqa: E402

BOARD_SCRIPT = "/tmp/daq_board.py"
BOARD_RUN_DIR = "/tmp/daq_run"
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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default="/dev/ttyUSB0")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    p = sub.add_parser("set")
    p.add_argument("name", choices=["threshold", "trig_width", "pattern", "gain", "baseline"])
    p.add_argument("value")
    p.add_argument("--ch", type=int, choices=range(4))
    p = sub.add_parser("run")
    p.add_argument("--seconds", type=float, default=10)
    p = sub.add_parser("sweep-threshold")
    p.add_argument("ch", type=int, choices=range(4))
    p.add_argument("values", type=int, nargs="+")
    p.add_argument("--seconds", type=float, default=1)
    a = ap.parse_args()

    board = Board(a.port)
    {"status": cmd_status, "set": cmd_set, "run": cmd_run,
     "sweep-threshold": cmd_sweep_threshold}[a.cmd](board, a)


if __name__ == "__main__":
    main()
