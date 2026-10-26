# From trapezoid to histogram bin

## The per-channel chain

```
pulse_gen ──adc──┬──▶ trigger (unchanged) ──trig──┐
                 │                                ▼
                 └──▶ trap_filter ──trap──▶ energy_capture ──energy, valid──▶ histogram
```

The **trigger** answers "is there a pulse?": a fast, short filter (width 10) compared with a
threshold. The **trap** answers "how big was it?": a slow, long filter (K = 32, L = 56). Fast
for timing, slow for energy: the standard split in pulse processing.

## energy_capture: a peak detector inside a window

On each rising edge of `trig`:
1. open a window of WINDOW = L + 16 = 72 clocks,
2. keep the largest `trap` value seen (the workshop's `peak_detector`),
3. when the window closes, output that maximum with a one-clock `energy_valid`.

Timing for one pulse, from its start: the trigger fires a few clocks in; the trap is 5 clocks behind
the input, reaches its top about K + rise clocks in, and stays there until about L + 5. A window
from the trigger to trigger + 72 covers the whole flat top, and the next pulse (512 clocks later)
is far away.

**Pile-up:** a second trigger while a window is open means two pulses overlapping. Their energies
add on the trap and can't be separated, so the second trigger is counted in PILEUP_COUNT
and not measured. With the 512-clock period it never happens. Try a short period in
`model/config.py` to see it.

## histogram: read-modify-write in a block RAM

4096 bins × 32-bit counts in one dual-port block RAM per channel.
- **bin = energy >> conv_gain.** With K = 32 and conv_gain = 5, bin ≈ (32·A) / 32 = A.
  conv_gain = 4 doubles every bin number (finer bins, smaller range): charge 3000 → 6000 > 4095 is
  **over range**, counted in OVER_COUNT and not binned.
- **Port A** belongs to the FSM. A RAM read takes a clock, so adding one to a bin takes three states:
  `IDLE` (put the bin on the address) → `READ` (RAM reads the old count) → `WRITE` (write count + 1).
- **CLEAR** walks all 4096 addresses writing 0: 4096 clocks = 123 µs.
- **Port B** is read-only, for the PS. Two ports on the same RAM let the PS read while the FSM writes.

## Why the bins are A − 1, not A

The flat top for charge 2000 is 63,973, not 64,000 (`tb_trap_filter` prints it), and
63,973 >> 5 = 1999. Two small effects, both from `pulse_gen` being integer hardware:
- its decay rounds **up** (`ceil(level/32)`), so its real α is a hair below 31/32 and the filter's
  pole-zero correction is slightly off;
- its output is the integer part of a fixed-point level.

The error is 0.04%, the same for every pulse of a given charge, and exactly predicted by the model.
Rounding up is still the right choice: it makes the level reach exactly 0 before the next pulse,
so every pulse is bit-identical and the histogram is one sharp bin per charge.

## Pulse set 1 vs set 2 (the "change the constants" step)

| | set 1 (original) | set 2 (changed) |
|---|---|---|
| rise | 20 clocks (like the old +100/clock ramp) | 4 clocks |
| charges | 2000 on all channels | ch0 500/1000/1500/2000, ch1 3000, ch2 800/2400, ch3 200 |
| histogram | one peak at 1999 per channel | ch0 4 peaks, ch1 1, ch2 2, ch3 empty |
| control | — | ch3 is below the trigger threshold: zero triggers, empty histogram |

Different charges per channel also change the **coincidence** behaviour. A small pulse crosses the
trigger threshold later than a big one, so channels' windows no longer line up exactly, and
pattern 0001 can now fire for short windows. Predictions: `../BRINGUP_CHECKLIST.md`, step 6.

## Check yourself

1. Predict ch2's bins at conv_gain 6, then check with `python3 -m model.expected --gain 6`.
2. Why does ch3 stop triggering between thresholds 700 and 800? (Its pulses have charge 200 and a
   4-clock rise; work out the trigger filter's peak for that pulse.)
3. What would happen if the histogram FSM took 100 clocks per event?
