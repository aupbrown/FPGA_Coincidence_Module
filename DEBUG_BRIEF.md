# Debug brief: board_top.vhd simulation failure

## Project context

FPGA coincidence-detection design for radiation instrumentation. Target is a
Zynq-7000 XC7Z030 on a PicoZed SOM with an Avnet FMC Carrier V2. Vivado 2022.2
for synthesis; NVC for simulation; Surfer for waveforms. The PL is configured
from PetaLinux on the PS via PCAP (`cat file.bit.bin > /dev/xdevcfg`), not JTAG.

### Source files

| File | Status |
|---|---|
| `pulse_gen.vhd` | Synthesizable trapezoidal pulse generator. **VERIFIED — do not change.** |
| `trigger.vhd` | Per-channel triangular filter + FSM. **VERIFIED — do not change.** |
| `coincidence.vhd` | Exact-match pattern comparator. **VERIFIED — do not change.** |
| `detector_top.vhd` | 4× trigger + 1× coincidence. **VERIFIED — do not change.** |
| `debouncer.vhd` | New. Button synchronizer + debounce + edge detect. |
| `board_top.vhd` | New. **This is what is broken.** |
| `tb_board_top.vhd` | Testbench. |

## What is ALREADY VERIFIED — do not re-investigate

Confirmed by reading the waveform of the current failing run:

- `trig_bus` cycles `0011 → 1111 → 1100` and repeats with a ~122-clock period
  against a predicted 120. This matches an independent Python model of the
  filter exactly.
- `coinc_out` pulses cleanly, and each pulse starts and ends precisely with a
  `0011` interval on `trig_bus` while `user_pattern` is `0011`.
- Therefore the pulse generators, the triangular filters, the trigger FSMs and
  the coincidence comparator are all behaving correctly. **The bug is in
  `board_top.vhd` or `debouncer.vhd` only.**

## The failure

Running `tb_board_top`:

```
mode 0 (0011):              index on led(2:1) = 0,  led(0) high for 601 of 600 clocks
mode 1 (1100):              index on led(2:1) = 0,  led(0) high for 601 of 600 clocks
mode 2 (1111):              index on led(2:1) = 0,  led(0) high for 601 of 600 clocks
mode 3 (0001) CONTROL:      index on led(2:1) = 0,  led(0) high for 601 of 600 clocks
** Error: FAIL: mode 3 (0001) CONTROL is the control pattern and must NEVER fire
mode 0 again, after a bouncy press: index on led(2:1) = 0, led(0) high for 601 of 600
```

Three symptoms:

1. `led(0)` goes high at the first coincidence (~clock 56) and **never returns
   low** for the entire 113 µs run.
2. `led(3)` (the heartbeat) **never toggles**, when `HB_BIT => 5` should make it
   flip every 32 clocks.
3. `led(2 downto 1)` reads `0` in every mode — the pattern menu never advances.

Note: `601 of 600` is a known off-by-one in the testbench's `observe` procedure
(it does an extra `wait until rising_edge(clk)` before the snapshot). It is
cosmetic and affects no pass/fail logic. **Do not spend time on it.**

## Primary hypothesis for symptoms 1 and 2

`tb_board_top` passes scaled-down timing through generics:

```vhdl
STRETCH_CYCLES  => 30,   EXT_WIDTH      => 6,
DEBOUNCE_CYCLES => 10,   DEBOUNCE_WIDTH => 5,
HB_WIDTH        => 6,    HB_BIT         => 5
```

If `board_top`'s **architecture** also declares constants with these names — or
uses differently-named internal constants such as `count_down_cycles` or
`ext_width` in the comparison and signal declarations — then the architecture's
declarations shadow or bypass the generics, and the hardware values are used
instead: an 8,333,250-clock (250 ms) stretch and a 25-bit heartbeat.

That single cause explains both symptoms. The simulation is only ~3,800 clocks
long, so a 250 ms stretch never completes and bit 24 of a 25-bit counter never
toggles. VHDL permits an architecture declaration to hide a generic of the same
name, so this produces **no error and no warning**.

## Tasks

1. Read `board_top.vhd`. Report whether any architecture constant collides with
   an entity generic name, and whether `count_down_done` and `hb_count` are
   derived from the generics or from architecture constants.
2. Fix so every timing parameter comes from the generic. Remove shadowing
   declarations rather than renaming the generics.
3. Separately diagnose symptom 3. Walk the signal path and report the FIRST
   signal that misbehaves:
   `btn(0)` → `pattern_button/sync_0` → `sync_1` → `count` → `level` →
   `level_d` → `rise_out` → `pat_advance` → `mode` → `led(2 downto 1)`
4. Re-run and report results.

## Constraints

- **Every file except `tb_board_top.vhd` must be VHDL-93.** Vivado 2022.2
  defaults to '93 and has already rejected each of the following in this
  project: `process(all)`; a bare `std_logic` as an `if` condition (write
  `= '1'`); a generic default expression that references another generic; a
  function call or expression as the actual in a port map. The testbench may use
  whatever NVC accepts.
- **Do not modify** `pulse_gen.vhd`, `trigger.vhd`, `coincidence.vhd`, or
  `detector_top.vhd`. Their behaviour is verified against an independent model.
- **Do not change the design intent:** threshold 1250, `trig_width` 50,
  `START_DELAY` of 0 / 0 / 40 / 40 for channels 0–3, and
  `PATTERNS = ("0011", "1100", "1111", "0001")`.
- **Do not weaken, remove, or relax any assertion in the testbench to make it
  pass.** The mode-3 control assertion in particular is the point of the test.
  If you believe the testbench itself is wrong, say so and explain why; do not
  silently edit it.

## Commands

```sh
nvc -a debouncer.vhd pulse_gen.vhd trigger.vhd coincidence.vhd \
       detector_top.vhd board_top.vhd tb_board_top.vhd
nvc -e tb_board_top
nvc -r tb_board_top --wave=tb_board_top.fst --dump-arrays
```

## Success criteria

The run must produce, with no assertion failures:

| mode | index on led(2:1) | led(0) high, of 600 |
|---|---|---|
| 0 `0011` | 0 | nonzero, roughly 300 |
| 1 `1100` | 1 | similar to mode 0 |
| 2 `1111` | 2 | nonzero, roughly half of mode 0 |
| 3 `0001` | 3 | **exactly 0** |
| 0 again | 0 | nonzero, roughly 300 |

The index sequence 0, 1, 2, 3, 0 proves the debouncer and pattern menu work,
including the final bouncy press which must advance the mode exactly once.

Report what you changed and why. Change nothing beyond what is needed to meet
these criteria.
