# FPGA coincidence detector

A four-channel coincidence-detection design for radiation instrumentation.
Each channel runs its ADC samples through a triangular (shaping) filter and a
trigger state machine; a comparator fires when the set of triggered channels
exactly matches a user-selected pattern. On the board, the result is shown on
LEDs and the pattern is chosen with a push button.

There is no ADC on the carrier board. Four trapezoidal pulse generators inside
the FPGA stand in for a real detector, so the full chain can be exercised
without a detector setup.

## Hardware and tools

| | |
|---|---|
| FPGA | Zynq-7000 XC7Z030 on a PicoZed SOM |
| Carrier | Avnet FMC Carrier V2 |
| Clock | 33.333 MHz PL oscillator on pin Y18 (30 ns), **not yet verified on hardware** |
| Synthesis | Vivado 2022.2 (VHDL-93) |
| Simulation | NVC (tested with 1.22.1) |
| Waveforms | Surfer |
| Configuration | From PetaLinux on the PS via PCAP: `cat file.bit.bin > /dev/xdevcfg` |

## Signal chain

```
pulse_gen x4 ──adc_0..3──▶ detector_top ──coinc_out──▶ pulse stretcher ──▶ led(0)
                            ├─ trigger x4 (filter + FSM) ─trig_bus─┐
                            └─ coincidence (exact match) ◀─────────┘◀── user_pattern
btn ─────▶ debouncer ──rise_out──▶ pattern menu (mode 0..3) ──▶ user_pattern, led(2:1)
free-running counter ──▶ led(3) heartbeat
```

### Files

| File | Contents |
|---|---|
| `board_top.vhd` | Top level: pulse generators, detector, debouncer, pattern menu, LED stretcher, heartbeat |
| `detector_top.vhd` | 4 × `trigger` + 1 × `coincidence` |
| `trigger.vhd` | Per-channel triangular filter and trigger FSM |
| `coincidence.vhd` | Registered exact-match comparator, `trig_ins = user_pattern` |
| `pulse_gen.vhd` | Synthesizable trapezoidal pulse generator (ADC stand-in) |
| `debouncer.vhd` | Two-flop synchronizer, debounce, rising-edge detect |
| `board_top.xdc` | Pin, I/O voltage and clock constraints for `board_top` |
| `and_gate.vhd`, `full_adder.vhd`, `counter.vhd` | Early practice designs |
| `tb_*.vhd` | Testbenches (see below) |

### Board behaviour

| Port | Board | Pin | Meaning |
|---|---|---|---|
| `led(0)` | PL_LED2 | AA19 | Coincidence, stretched to 250 ms so it is visible (non-retriggerable) |
| `led(1)` | PL_LED3 | AA20 | Pattern index, bit 0 |
| `led(2)` | PL_LED1 | G3 | Pattern index, bit 1. In the 1.8 V bank, so may look dimmer |
| `led(3)` | PL_LED4 | AB21 | Heartbeat, ~1 s period. Proves the clock is running and the bitstream loaded |
| `btn` | PL_PB2 | T16 | Pattern select |
| `clk` | PL_CLK | Y18 | 33.333 MHz oscillator |

**Before powering up:** `led(2)` is in Bank 35, which on the 7030 must run at
1.8 V from the carrier's VADJ supply. Bank 35 is powered whether or not the
design uses it, so confirm VADJ is set to 1.8 V regardless.

Pressing `btn` steps through the patterns, wrapping 3 → 0:

| Index | Pattern | Expected |
|---|---|---|
| 0 | `0011` | Fires (channels 0 + 1) |
| 1 | `1100` | Fires (channels 2 + 3) |
| 2 | `1111` | Fires where the two pairs' trigger windows overlap |
| 3 | `0001` | **Never fires.** Control: no state of the design can produce it |

### Key parameters

- Threshold 1250, trigger width 50 clocks, 12-bit ADC data, 16-bit filter accumulator.
- Pulse generators: baseline 100, +100/clock for 20 clocks, hold 10, −50/clock for
  40, idle 50 → 120-clock period. Channels 2–3 start 40 clocks after channels 0–1.
- ADC samples are treated as **unsigned**, matching what we believe the lab's
  detector ADC produces. If it turns out to be two's complement, `trigger.vhd`'s
  filter input must change back.
- `board_top` timing is set by generics whose defaults are the hardware values
  (`STRETCH_CYCLES`, `EXT_WIDTH`, `DEBOUNCE_CYCLES`, `DEBOUNCE_WIDTH`, `HB_WIDTH`,
  `HB_BIT`). They assume a 33.333 MHz clock; if the clock is different, these
  defaults change. The testbench overrides them with small values.

## VHDL-93 rules

Vivado 2022.2 defaults to VHDL-93, and has rejected each of these in this
project. All design files (not testbenches) must avoid them:

- `process(all)`
- A bare `std_logic` as an `if` condition. Write `if x = '1'`.
- A generic default that references another generic. Use a literal and
  document the constraint in a comment.
- A function call or expression as an actual in a port map. Use an
  initialized signal.

Check with:

```sh
nvc --std=1993 -a debouncer.vhd pulse_gen.vhd trigger.vhd coincidence.vhd \
       detector_top.vhd board_top.vhd
```

## Simulation

Full board design:

```sh
nvc -a debouncer.vhd pulse_gen.vhd trigger.vhd coincidence.vhd \
       detector_top.vhd board_top.vhd tb_board_top.vhd
nvc -e tb_board_top
nvc -r tb_board_top --wave=tb_board_top.fst --dump-arrays
surfer tb_board_top.fst
```

Expected output, with no assertion failures:

```
mode 0 (0011):              index on led(2:1) = 0,  led(0) high for 301 of 600 clocks
mode 1 (1100):              index on led(2:1) = 1,  led(0) high for 300 of 600 clocks
mode 2 (1111):              index on led(2:1) = 2,  led(0) high for 150 of 600 clocks
mode 3 (0001) CONTROL:      index on led(2:1) = 3,  led(0) high for 0 of 600 clocks
mode 0 again, after a bouncy press: index on led(2:1) = 0, led(0) high for 301 of 600 clocks
```

(`301 of 600` is a known, harmless off-by-one in the testbench's `observe` procedure.)

The other testbenches have free-running clocks, so give them a stop time:

| Testbench | Analyze | Top | Self-checking? |
|---|---|---|---|
| `tb_board_top.vhd` | see above | `tb_board_top` | Yes (assertions) |
| `tb_detector_top.vhd` | `trigger.vhd coincidence.vhd detector_top.vhd` | `tb_detector_top` | No: expect `coinc_out` in cases 1, 4, 6 only |
| `tb_trigger.vhd` | `trigger.vhd` | `tb_trigger` | No: expect two 22-clock `trig_out` pulses |
| `tb_pulse_generator.vhd` | `pulse_gen.vhd` | `tb_pulse_gen` | No: inspect waveform |
| `tb_counter.vhd` | `counter.vhd` | `tb_counter` | No |
| `tb_full_adder.vhd` | `full_adder.vhd` | `tb_FullAdder` | No |
| `tb_and_gate.vhd` | `and_gate.vhd` | `tb_and_gate` | No |

```sh
nvc -a trigger.vhd tb_trigger.vhd && nvc -e tb_trigger
nvc -r tb_trigger --stop-time=2us --wave=tb_trigger.fst
```

## Known issues and open items

- **Not yet synthesized.** Neither the VHDL-93 check above (NVC's, not
  Vivado's) nor `board_top.xdc` has been through Vivado yet.
- **VADJ must be 1.8 V.** Confirm on the carrier before powering up (see above).
- **Clock frequency unverified.** Confirm 33.333 MHz with a blink test before
  trusting the stretch and heartbeat timing.
- **ADC format is an assumption** (unsigned). Confirm against the real ADC.
- **`pulse_gen` reset does not clear its delay counter.** `START_DELAY` keeps
  counting during reset, so in `tb_pulse_generator` channel B starts 55 clocks
  after A instead of 60. No effect in `board_top`, which ties reset low.
- **Each trigger window is `trig_width` + 2 clocks** (FSM entry and exit), so the
  `1111` overlap is 12 clocks per period, not the 10 predicted in a
  `board_top.vhd` comment.
- Only `tb_board_top` checks its own results; the others need waveform
  inspection.
