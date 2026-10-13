#!/usr/bin/env python3
"""Load a bitstream onto the board over the USB serial console -- runs ON THE PC.

usage: python3 scripts/serial_load.py [BITSTREAM] [--port /dev/ttyUSB0]
       default BITSTREAM: build/board_top.bit.bin

Sends the bitstream (gzipped; mostly zeros, so ~6 MB shrinks to ~20 KB) and
scripts/load_board_top.sh to /tmp on the board as base64 text, checks the
bitstream's md5 on the board, then runs the load script and prints its output.

Needs a root shell already logged in on the console, and no other program
(screen, minicom) holding the port. Standard library only: no pyserial.
"""
import argparse, base64, gzip, hashlib, os, re, select, sys, termios, time, tty

HERE = os.path.dirname(os.path.abspath(__file__))


class Console:
    def __init__(self, port):
        self.fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        tty.setraw(self.fd)
        attrs = termios.tcgetattr(self.fd)
        attrs[4] = attrs[5] = termios.B115200
        attrs[2] |= termios.CLOCAL | termios.CREAD
        termios.tcsetattr(self.fd, termios.TCSANOW, attrs)

    def read_for(self, seconds):
        out, end = b"", time.time() + seconds
        while time.time() < end:
            if select.select([self.fd], [], [], 0.05)[0]:
                try:
                    out += os.read(self.fd, 65536)
                except BlockingIOError:
                    pass
        return out.decode(errors="replace").replace("\r", "")

    def run(self, line, until=r"[#$] $", timeout=10):
        """Send a line, return output up to the next shell prompt."""
        self.read_for(0.2)
        os.write(self.fd, (line + "\r").encode())
        out, end = "", time.time() + timeout
        while time.time() < end:
            out += self.read_for(0.2)
            if re.search(until, out):
                break
        return out

    def send_file(self, data, remote):
        """Write bytes to a file on the board, as base64 through cat."""
        self.run("stty -echo")
        os.write(self.fd, f"cat > {remote}.b64\r".encode())
        self.read_for(0.3)
        for line in base64.encodebytes(data).decode().splitlines():
            os.write(self.fd, (line + "\r").encode())
            self.read_for(0.012)          # pace it: the tty buffer is small
        os.write(self.fd, b"\x04")        # Ctrl-D ends cat
        self.read_for(0.3)
        self.run(f"stty echo; base64 -d {remote}.b64 > {remote}; rm {remote}.b64")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bitstream", nargs="?", default="build/board_top.bit.bin")
    ap.add_argument("--port", default="/dev/ttyUSB0")
    a = ap.parse_args()

    bit = open(a.bitstream, "rb").read()
    md5 = hashlib.md5(bit).hexdigest()
    con = Console(a.port)

    prompt = con.run("", timeout=3)
    if "login:" in prompt or not re.search(r"# $", prompt):
        sys.exit("No root shell on the console. Log in first (screen /dev/ttyUSB0 "
                 "115200), then quit screen and rerun.")

    print(f"sending {a.bitstream} ({len(bit)} bytes, md5 {md5})")
    con.send_file(gzip.compress(bit, 9), "/tmp/board_top.bit.bin.gz")
    con.send_file(open(os.path.join(HERE, "load_board_top.sh"), "rb").read(),
                  "/tmp/load_board_top.sh")
    out = con.run("gunzip -f /tmp/board_top.bit.bin.gz && md5sum /tmp/board_top.bit.bin")
    if md5 not in out:
        sys.exit("md5 mismatch on the board:\n" + out)
    print("md5 matches on the board")

    out = con.run("sh /tmp/load_board_top.sh /tmp/board_top.bit.bin", timeout=30)
    print(out.split("\n", 1)[-1].rstrip())   # drop the echoed command
    if "DONE = 1" not in out:
        sys.exit(1)


if __name__ == "__main__":
    main()
