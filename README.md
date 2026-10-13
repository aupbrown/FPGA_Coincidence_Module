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
| Clock | 33.333 MHz (30 ns) `FCLK_CLK0` from the PS, set by Linux. The carrier has no working PL clock on Y18 |
| Synthesis | Vivado 2022.2 (VHDL-93) |
| Simulation | NVC (tested with 1.22.1); Vivado's xsim also works |
| Waveforms | Surfer |
| Configuration | From PetaLinux (Avnet's 2017.4 out-of-box image) on the PS via PCAP, `/dev/xdevcfg` |

## Signal chain

```
PS7 ──FCLK_CLK0 (33.333 MHz)──▶ clk for everything below
pulse_gen x4 ──adc_0..3──▶ detector_top ──coinc_out──▶ pulse stretcher ──▶ led(0)
                            ├─ trigger x4 (filter + FSM) ─trig_bus─┐
                            └─ coincidence (exact match) ◀─────────┘◀── user_pattern
btn ─────▶ debouncer ──rise_out──▶ pattern menu (mode 0..3) ──▶ user_pattern, led(2:1)
free-running counter ──▶ led(3) heartbeat
```

### Files

`src/` holds the design, `sim/` the testbenches, `constraints/` the Vivado XDC,
`scripts/` the loading scripts. Run every command below from the repository root.

| File | Contents |
|---|---|
| `src/board_top.vhd` | Top level: idle PS7 block (clock source), pulse generators, detector, debouncer, pattern menu, LED stretcher, heartbeat |
| `src/detector_top.vhd` | 4 × `trigger` + 1 × `coincidence` |
| `src/trigger.vhd` | Per-channel triangular filter and trigger FSM |
| `src/coincidence.vhd` | Registered exact-match comparator, `trig_ins = user_pattern` |
| `src/pulse_gen.vhd` | Synthesizable trapezoidal pulse generator (ADC stand-in) |
| `src/debouncer.vhd` | Two-flop synchronizer, debounce, rising-edge detect |
| `constraints/board_top.xdc` | Pin, I/O voltage and clock constraints for `board_top` |
| `build.tcl` | Vivado batch build: PS7 block, synthesis, implementation, bitstream, `.bit.bin` |
| `sim/tb_*.vhd` | Testbenches (see below) |
| `sim/ps7_stub_wrapper_sim.vhd` | Simulation stand-in for the PS7 block: generates the 33.333 MHz clock |
| `scripts/load_board_top.sh` | Runs on the board: releases the PL, sets the clock, loads the bitstream |
| `scripts/serial_load.py` | Runs on the PC: sends the bitstream and load script over the USB serial console and runs it |

### Board behaviour

| Port | Board | Pin | Meaning |
|---|---|---|---|
| `led(0)` | PL_LED2 | AA19 | Coincidence, stretched to 250 ms so it is visible (non-retriggerable) |
| `led(1)` | PL_LED3 | AA20 | Pattern index, bit 0 |
| `led(2)` | PL_LED1 | G3 | Pattern index, bit 1. In the 1.8 V bank, so may look dimmer |
| `led(3)` | PL_LED4 | AB21 | Heartbeat, ~1 s period. Proves the clock is running and the bitstream loaded |
| `btn` | PL_PB2 | T16 | Pattern select |

`clk` is internal: `FCLK_CLK0` from the PS7 block, 1000 MHz IO PLL / 30.
Verified on hardware: the heartbeat blinks at ~1 s.

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

A coincidence arrives every 120 clocks (3.6 µs), far sooner than the 250 ms
stretch ends, so `led(0)` looks solid for patterns 0–2. Verified on hardware.

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
- The PS7 block is required, not optional. `board_top` barely uses the PS, but a
  Zynq bitstream without the PS7 cell leaves the PS-PL interface signals
  untied (Vivado DRC `ZPS7-1`), and loading one froze Linux.

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
nvc --std=1993 -a src/debouncer.vhd src/pulse_gen.vhd src/trigger.vhd \
       src/coincidence.vhd src/detector_top.vhd src/board_top.vhd
```

## Build

```sh
source ~/Xilinx/Vivado/2022.2/settings64.sh
vivado -mode batch -source build.tcl
```

This writes `build/board_top.bit`, `build/board_top.bit.bin` (header stripped
and byte-swapped by `bootgen` for the PCAP) and reports: check
`build/timing_summary.rpt` for positive WNS/WHS and `build/drc.rpt` for no
violations.

## Loading onto the board

The PS boots Avnet's PetaLinux image from the SD card, which also loads Avnet's
own PL design. `scripts/load_board_top.sh` replaces it with `board_top`:

1. Stops Avnet's web demo and unbinds the drivers for its PL peripherals
   (`41200000.gpio`, `41210000.gpio`, `41600000.i2c`). Reconfiguring the PL
   while a driver is still using it hangs the AXI bus and freezes Linux.
2. Sets `FCLK_CLK0` to 33.333 MHz and enables it. These live in the PS, not
   the bitstream, and reset at every reboot.
3. Writes the bitstream to `/dev/xdevcfg` and checks that DONE went high.

Avnet's design comes back at every reboot, so load again after each one.

**Over the USB serial cable (no SD card needed).** Log in once as root
(`screen /dev/ttyUSB0 115200`), quit `screen` (Ctrl-A K Y), then:

```sh
python3 scripts/serial_load.py
```

The bitstream is gzipped for the trip (6 MB → ~20 KB, it is mostly zeros), so
this takes a few seconds. The port needs read/write access: add yourself to
`dialout`, or `sudo chmod 666 /dev/ttyUSB0` until the next replug.

**From the SD card.** Copy `build/board_top.bit.bin` and
`scripts/load_board_top.sh` to the card's boot partition, then on the board:

```sh
mount /dev/mmcblk0p1 /mnt
sh /mnt/load_board_top.sh
```

Run `umount /mnt` before `poweroff`, or the card is left marked dirty.

## Simulation

Full board design. `board_top`'s clock comes from the PS7 block, so the
simulation stand-in `sim/ps7_stub_wrapper_sim.vhd` is analyzed first:

```sh
nvc -a sim/ps7_stub_wrapper_sim.vhd src/debouncer.vhd src/pulse_gen.vhd \
       src/trigger.vhd src/coincidence.vhd src/detector_top.vhd \
       src/board_top.vhd sim/tb_board_top.vhd
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
| `sim/tb_board_top.vhd` | see above | `tb_board_top` | Yes (assertions) |
| `sim/tb_detector_top.vhd` | `src/trigger.vhd src/coincidence.vhd src/detector_top.vhd` | `tb_detector_top` | No: expect `coinc_out` in cases 1, 4, 6 only |
| `sim/tb_trigger.vhd` | `src/trigger.vhd` | `tb_trigger` | No: expect two 22-clock `trig_out` pulses |
| `sim/tb_pulse_generator.vhd` | `src/pulse_gen.vhd` | `tb_pulse_gen` | No: inspect waveform |

```sh
nvc -a src/trigger.vhd sim/tb_trigger.vhd && nvc -e tb_trigger
nvc -r tb_trigger --stop-time=2us --wave=tb_trigger.fst
```

## Known issues and open items

- **VADJ must be 1.8 V.** Confirm on the carrier before powering up (see above).
- **No PL clock on Y18.** Avnet's master XDC lists PL_CLK on Y18 (JX3.73), but
  a bring-up bitstream saw no clock there. Hence `FCLK_CLK0`. Worth checking
  the carrier schematic if a PL-only clock is ever needed.
- **Loading depends on Avnet's image.** The driver list and sysfs paths in
  `load_board_top.sh` are for the 2017.4 out-of-box image. On another image,
  list `/sys/bus/platform/devices/` for PL devices (8-digit addresses
  `4xxxxxxx`–`bxxxxxxx`) and unbind those instead; the script refuses to load
  while any still has a driver.
- **ADC format is an assumption** (unsigned). Confirm against the real ADC.
- **`pulse_gen` reset does not clear its delay counter.** `START_DELAY` keeps
  counting during reset, so in `tb_pulse_generator` channel B starts 55 clocks
  after A instead of 60. No effect in `board_top`, which ties reset low.
- **Each trigger window is `trig_width` + 2 clocks** (FSM entry and exit), so the
  `1111` overlap is 12 clocks per period, not the 10 predicted in a
  `board_top.vhd` comment.
- Only `tb_board_top` checks its own results; the others need waveform
  inspection.
