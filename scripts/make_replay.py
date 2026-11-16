#!/usr/bin/env python3
"""Pack Max's CZT waveforms into replay files for the PL's replay buffer -- runs ON THE PC.

    python3 scripts/make_replay.py                      # default input and output below
    python3 scripts/make_replay.py path/to/waveforms_doi_4min.h5 --out replay

Input: pulse_data_Austin_v2_175/waveforms_doi_4min.h5 (see its README): int16,
baseline-subtracted, axes (depth, event, sample), 1601 samples at 50 MS/s, the
pulse edge at sample ~640 in every record.

Every event is kept whole (all 1601 samples), and events are concatenated. A
depth's events do not fit the 131072-word buffer in one go (100 x 1601 =
160100 words), so each depth is split into parts of whole events, as equal as
possible, each part one buffer load:
    replay/photopeak/d00_0.bin, d00_1.bin .. d25_1.bin   anode + cathode_primary, 2 x 50 events
    replay/random/d00_0.bin .. d25_2.bin                 random_anode + random_cathode_primary,
                                                         3 parts of 59/58/58 events
`daq.py replay --per-file` plays all parts of a depth into one run.

One little-endian uint32 per sample:
    [11:0]  anode   + ANODE_OFFSET           -> replay lane A (ch0)
    [27:16] cathode + CATHODE_OFFSET         -> replay lane B (ch1)
both clipped to 0..4095 like a 12-bit ADC. The cathode stays negative-going,
as a real ADC would see it: the FPGA flips it (POLARITY bit 1). After that flip
its baseline is 4095 - 3895 = 200 = the anode's, so one BASELINE register
(200) serves both lanes.

Needs h5py and numpy on the host (nothing on the board does).
"""
import argparse
import glob
import os

import h5py
import numpy as np

ANODE_OFFSET = 200
CATHODE_OFFSET = 4095 - ANODE_OFFSET        # 3895: baseline 200 after inversion
BUFFER_WORDS = 1 << 17                      # replay buffer depth in the PL

SETS = {"photopeak": ("anode", "cathode_primary"),
        "random": ("random_anode", "random_cathode_primary")}


def pack(anode, cathode):
    """(events, samples) int16 arrays -> uint32 words, and the clipped-sample count."""
    a = anode.astype(np.int32) + ANODE_OFFSET
    c = cathode.astype(np.int32) + CATHODE_OFFSET
    clipped = int(((a < 0) | (a > 4095)).sum() + ((c < 0) | (c > 4095)).sum())
    a, c = np.clip(a, 0, 4095), np.clip(c, 0, 4095)
    words = (a.astype(np.uint32) | (c.astype(np.uint32) << 16)).ravel()
    return words.astype("<u4"), clipped


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("h5", nargs="?", default="pulse_data_Austin_v2_175/waveforms_doi_4min.h5")
    ap.add_argument("--out", default="replay")
    a = ap.parse_args()

    with h5py.File(a.h5, "r") as f:
        for name, (an_key, ca_key) in SETS.items():
            anode, cathode = f[an_key][:], f[ca_key][:]
            depths, events, samples = anode.shape
            parts = -(-events * samples // BUFFER_WORDS)          # ceiling division
            outdir = os.path.join(a.out, name)
            os.makedirs(outdir, exist_ok=True)
            for old in glob.glob(os.path.join(outdir, "*.bin")):  # no stale files for d*.bin
                os.remove(old)
            total_clipped = 0
            for depth in range(depths):
                for p, idx in enumerate(np.array_split(np.arange(events), parts)):
                    words, clipped = pack(anode[depth, idx], cathode[depth, idx])
                    assert len(words) <= BUFFER_WORDS, "part does not fit the replay buffer"
                    words.tofile(os.path.join(outdir, "d%02d_%d.bin" % (depth, p)))
                    total_clipped += clipped
            print("%s: %d depths x %d parts of %s events x %d samples, %d samples clipped in all"
                  % (outdir, depths, parts, "/".join(str(len(i)) for i in np.array_split(range(events), parts)),
                     samples, total_clipped))


if __name__ == "__main__":
    main()
