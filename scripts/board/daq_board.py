#!/usr/bin/env python3
"""Control core_top and save its results to files -- runs ON THE BOARD.

Written for Avnet's PetaLinux 2017.4 image (Python 3.5: no f-strings).
The host's scripts/daq.py copies this file to /tmp and drives it over the
serial console, but it also works by hand:

    python3 daq_board.py status
    python3 daq_board.py set threshold 1500 [CH]    # CH omitted = all four
    python3 daq_board.py set trig_width 60          # also: pattern, gain, baseline
    python3 daq_board.py run SECONDS OUTDIR         # clear, run, stop, dump
    python3 daq_board.py dump OUTDIR
    python3 daq_board.py start | stop | clear

How it reaches the FPGA: core_top's registers sit in the PS's physical
address space at 0x43C0_0000 (AXI GP0). mmap() of /dev/mem maps that range
into this process, and each 32-bit read or write of the mapping becomes one
AXI4-Lite transaction. No kernel driver is needed.

Files written by run/dump (the format model/compare.py reads):
    config.csv     name,value  -- ID, CONFIG and the run-time settings
    counters.csv   name,value  -- run_clocks and every counter
    hist_ch0..3.csv  bin,count -- 4096 bins each
"""
import os
import sys
import time

try:
    import mmap
except ImportError:          # Avnet's image ships python3 without the mmap module
    mmap = None
    import ctypes

BASE = 0x43C00000
SIZE = 0x20000
ID_VALUE = 0x454E0001
CLOCK_HZ = 33333333
MAX_SECONDS = 120          # RUN_CLOCKS is 32 bits: wraps after 128.8 s

REG = {
    "id": 0x000, "config": 0x004, "control": 0x008, "status": 0x00C,
    "uptime": 0x010, "run_clocks": 0x014, "conv_gain": 0x018,
    "user_pattern": 0x01C, "trig_width": 0x020, "coinc_count": 0x024,
    "baseline": 0x028,
}
for _ch in range(4):
    REG["threshold_%d" % _ch] = 0x030 + 4 * _ch
    REG["trig_count_%d" % _ch] = 0x040 + 16 * _ch
    REG["event_count_%d" % _ch] = 0x044 + 16 * _ch
    REG["over_count_%d" % _ch] = 0x048 + 16 * _ch
    REG["pileup_count_%d" % _ch] = 0x04C + 16 * _ch

# Short names accepted by "set"
SETTABLE = {"threshold": "threshold_%d", "trig_width": "trig_width",
            "pattern": "user_pattern", "gain": "conv_gain", "baseline": "baseline"}
CONFIG_NAMES = (["conv_gain", "user_pattern", "trig_width", "baseline"] +
                ["threshold_%d" % ch for ch in range(4)])
COUNTER_NAMES = ["run_clocks", "coinc_count"] + [
    "%s_%d" % (n, ch) for ch in range(4)
    for n in ("trig_count", "event_count", "over_count", "pileup_count")]

HIST_BASE = 0x10000
HIST_STRIDE = 0x4000
BINS = 4096

CONTROL_RUN = 0x1
CONTROL_CLEAR = 0x2
STATUS_CLEARING = 0x2


def fail(msg):
    sys.exit("ERROR: " + msg)


class Core(object):
    def __init__(self):
        # A read of an address nothing answers hangs the bus and freezes
        # Linux, so only touch it once load_board_top.sh has loaded board_top
        # and checked the ID (it leaves this file behind).
        if not os.path.exists("/tmp/board_top.loaded"):
            fail("board_top is not loaded (no /tmp/board_top.loaded). Run load_board_top.sh first.")
        fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        # Either way, indexing self.words does one aligned 32-bit access, i.e.
        # exactly one AXI transaction per register.
        if mmap is not None:
            self.mm = mmap.mmap(fd, SIZE, mmap.MAP_SHARED,
                                mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)
            self.words = memoryview(self.mm).cast("I")
        else:
            self.words = self._libc_mmap(fd)
        os.close(fd)
        ident = self.rd(REG["id"])
        if ident != ID_VALUE:
            fail("ID register is 0x%08X, expected 0x%08X" % (ident, ID_VALUE))

    @staticmethod
    def _libc_mmap(fd):
        """mmap() from libc through ctypes; returns a ctypes array over the mapping."""
        PROT_READ, PROT_WRITE, MAP_SHARED = 1, 2, 1
        libc = ctypes.CDLL(None, use_errno=True)
        libc.mmap.restype = ctypes.c_void_p
        libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                              ctypes.c_int, ctypes.c_int, ctypes.c_long]
        addr = libc.mmap(None, SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, BASE)
        if addr is None or addr == ctypes.c_void_p(-1).value:
            fail("mmap of /dev/mem failed: " + os.strerror(ctypes.get_errno()))
        return (ctypes.c_uint32 * (SIZE // 4)).from_address(addr)

    def rd(self, offset):
        return self.words[offset >> 2]

    def wr(self, offset, value):
        self.words[offset >> 2] = value & 0xFFFFFFFF

    def get(self, name):
        v = self.rd(REG[name])
        if name.startswith("threshold") and v >= 0x80000000:
            v -= 1 << 32                          # thresholds are signed
        return v

    def clear(self):
        self.wr(REG["control"], CONTROL_CLEAR)    # also stops the run
        deadline = time.time() + 1.0
        while self.rd(REG["status"]) & STATUS_CLEARING:
            if time.time() > deadline:
                fail("clear did not finish")
        time.sleep(0.001)                         # filters settle after their reset

    def start(self):
        self.wr(REG["control"], CONTROL_RUN)

    def stop(self):
        self.wr(REG["control"], 0)

    def histogram(self, ch):
        first = (HIST_BASE + HIST_STRIDE * ch) >> 2
        return [self.words[first + b] for b in range(BINS)]

    def dump(self, outdir):
        if not os.path.isdir(outdir):
            os.makedirs(outdir)
        with open(os.path.join(outdir, "config.csv"), "w") as f:
            f.write("name,value\n")
            f.write("id,0x%08X\n" % self.get("id"))
            f.write("config,0x%08X\n" % self.get("config"))
            for n in CONFIG_NAMES:
                f.write("%s,%d\n" % (n, self.get(n)))
        with open(os.path.join(outdir, "counters.csv"), "w") as f:
            f.write("name,value\n")
            for n in COUNTER_NAMES:
                f.write("%s,%d\n" % (n, self.get(n)))
        for ch in range(4):
            with open(os.path.join(outdir, "hist_ch%d.csv" % ch), "w") as f:
                f.write("bin,count\n")
                for b, n in enumerate(self.histogram(ch)):
                    f.write("%d,%d\n" % (b, n))
        print("wrote %s: config.csv counters.csv hist_ch0..3.csv" % outdir)

    def status(self):
        for n in ["id", "config", "control", "status", "uptime"]:
            print("%-16s 0x%08X" % (n, self.get(n)))
        for n in CONFIG_NAMES + COUNTER_NAMES:
            print("%-16s %d" % (n, self.get(n)))


def parse_int(s):
    return int(s, 0)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd, args = argv[1], argv[2:]
    core = Core()

    if cmd == "status":
        core.status()
    elif cmd == "set":
        if len(args) < 2 or args[0] not in SETTABLE:
            fail("usage: set {%s} VALUE [CH]" % "|".join(sorted(SETTABLE)))
        name, value = args[0], parse_int(args[1])
        if name == "threshold":
            if not -32768 <= value <= 32767:
                fail("threshold is a signed 16-bit value")
            chans = [int(args[2])] if len(args) > 2 else range(4)
            for ch in chans:
                core.wr(REG["threshold_%d" % ch], value)
        else:
            core.wr(REG[SETTABLE[name]], value)
        print("ok")
    elif cmd == "run":
        if len(args) != 2:
            fail("usage: run SECONDS OUTDIR")
        seconds = float(args[0])
        if not 0 < seconds <= MAX_SECONDS:
            fail("run length must be 0-%d s (RUN_CLOCKS wraps at 128.8 s)" % MAX_SECONDS)
        core.clear()
        core.start()
        time.sleep(seconds)
        core.stop()
        print("ran %.3f s (%d clocks)" % (core.get("run_clocks") / float(CLOCK_HZ),
                                          core.get("run_clocks")))
        core.dump(args[1])
    elif cmd == "dump":
        core.dump(args[0])
    elif cmd == "start":
        core.start()
    elif cmd == "stop":
        core.stop()
    elif cmd == "clear":
        core.clear()
    else:
        fail("unknown command " + cmd)


if __name__ == "__main__":
    main(sys.argv)
