#!/usr/bin/env python3
"""Pack Max's CZT waveforms into replay files for the PL's replay buffer -- runs ON THE PC.

    python3 scripts/make_replay.py                      # default input and output below
    python3 scripts/make_replay.py path/to/waveforms_doi_4min.h5 --out replay

Input: pulse_data_Austin_v2_175/waveforms_doi_4min.h5 (see its README): int16,
baseline-subtracted, axes (depth, event, sample), 1601 samples at 50 MS/s, the
pulse edge at sample ~640 in every record.

Output, one file per depth and event set:
    replay/photopeak/d00.bin .. d25.bin   anode + cathode_primary (100 events each)
    replay/random/d00.bin    .. d25.bin   random_anode + random_cathode_primary (175 each)

Each event is cropped to samples [CROP_START, CROP_START + CROP_LEN): 160
baseline samples, the edge, then 352 samples of the plateau. Events are
concatenated. One little-endian uint32 per sample:
    [11:0]  anode   + ANODE_OFFSET           -> replay lane A (ch0)
    [27:16] cathode + CATHODE_OFFSET         -> replay lane B (ch1)
both clipped to 0..4095 like a 12-bit ADC. The cathode stays negative-going,
as a real ADC would see it: the FPGA flips it (POLARITY bit 1). After that flip
its baseline is 4095 - 3895 = 200 = the anode's, so one BASELINE register
(200) serves both lanes.

Needs h5py and numpy on the host (nothing on the board does).
"""
import argparse
import os

import h5py
import numpy as np

CROP_START = 480
CROP_LEN = 512
ANODE_OFFSET = 200
CATHODE_OFFSET = 4095 - ANODE_OFFSET        # 3895: baseline 200 after inversion
BUFFER_WORDS = 1 << 17                      # replay buffer depth in the PL

SETS = {"photopeak": ("anode", "cathode_primary"),
        "random": ("random_anode", "random_cathode_primary")}


def pack(anode, cathode):
    """(events, samples) int16 arrays -> uint32 words, and the clipped-sample count."""
    a = anode[:, CROP_START:CROP_START + CROP_LEN].astype(np.int32) + ANODE_OFFSET
    c = cathode[:, CROP_START:CROP_START + CROP_LEN].astype(np.int32) + CATHODE_OFFSET
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
            outdir = os.path.join(a.out, name)
            os.makedirs(outdir, exist_ok=True)
            total_clipped = 0
            for depth in range(anode.shape[0]):
                words, clipped = pack(anode[depth], cathode[depth])
                assert len(words) <= BUFFER_WORDS, "file does not fit the replay buffer"
                words.tofile(os.path.join(outdir, "d%02d.bin" % depth))
                total_clipped += clipped
            print("%s: %d files of %d events x %d samples = %d words (%d KB) each, "
                  "%d samples clipped in all" % (outdir, anode.shape[0], anode.shape[1], CROP_LEN,
                                                  len(words), len(words) * 4 // 1024, total_clipped))


if __name__ == "__main__":
    main()
