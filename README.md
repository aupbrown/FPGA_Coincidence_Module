# FPGA coincidence detector and energy spectrometer

A four-channel radiation-detector front end for the PicoZed 7030. Each channel:

1. **triggers** on a pulse (triangular filter + trigger FSM),
2. measures the pulse's **energy** with a **trapezoidal filter** and a peak detector,
3. adds one count to that energy's bin in its own 4096-bin **histogram**.

A coincidence comparator also counts when the set of triggered channels matches a pattern.
There are no LEDs or buttons. The PS (Linux) controls everything and reads the results over
the AXI bus, writes them to files, and a host PC drives it all over the USB serial cable.
The results are checked against a bit-exact Python model of the design.

There is no ADC on the carrier board. Four pulse generators inside the FPGA stand in for
a detector + preamp: fast rise, exponential decay, a programmable sequence of charges.

New to the design? Start with `docs/learning/` (the trap filter math, then each module).
At the board: follow `docs/BRINGUP_CHECKLIST.md`.

## Hardware and tools

| | |
|---|---|
| FPGA | Zynq-7000 XC7Z030 on a PicoZed SOM |
| Carrier | Avnet FMC Carrier V2 |
| OS on the PS | Avnet's PetaLinux 2017.4 out-of-box image (SD card) |
| Clock | 33.333 MHz (30 ns) `FCLK_CLK0` from the PS, set by Linux. The carrier has no working PL clock on Y18 |
| PS ↔ PL | AXI GP0 → AXI4-Lite registers at `0x43C0_0000` (128 KB) |
| Host ↔ PS | USB-UART console, 115200 baud (`/dev/ttyUSB0`) |
| Synthesis | Vivado 2022.2 (VHDL-93) |
| Simulation | NVC (tested with 1.22.1) |
| Model / scripts | Python ≥ 3.9 on the host (standard library only); Python 3.5 on the board |

## Signal chain

```
                        ┌──────────────── core_top (PL) ────────────────────────────────────┐
PS7 ─FCLK_CLK0, reset─▶ │ pulse_gen ─adc─▶ trigger ─trig─┬─▶ coincidence ─▶ COINC_COUNT     │
                        │   (x4)     │       (x4)        │      ▲ user_pattern              │
                        │            │                   ▼                                   │
                        │            └─▶ trap_filter ─▶ energy_capture ─▶ histogram (x4)     │
                        │                  ▲ baseline       (peak in window)  ▲ conv_gain   │
PS7 M_AXI_GP0 ─AXI3─▶ protocol ─AXI4-Lite─▶ axi_lite_slave ─▶ registers + histogram readout │
                  converter              └───────────────────────────────────────────────────┘
```

### Files

| Path | Contents |
|---|---|
| `src/board_top.vhd` | Synthesis top: the PS7 block design + `core_top`. No package pins |
| `src/core_top.vhd` | The four channels, coincidence, counters and the **register map** |
| `src/pulse_config_pkg.vhd` | Pulse-generator constants: set 1 (original) and set 2 (changed) |
| `src/pulse_gen.vhd` | Preamp-like pulses: charge injected over `rise` clocks, decay by 1/32 per clock |
| `src/trigger.vhd`, `src/coincidence.vhd`, `src/detector_top.vhd` | Trigger and coincidence (unchanged, except `detector_top` now outputs the trigger bus) |
| `src/trap_filter.vhd` | Trapezoidal filter with pole-zero correction and baseline subtraction |
| `src/energy_capture.vhd` | Peak of the trap output in a window after each trigger; pile-up detection |
| `src/histogram.vhd` | Block-RAM histogram: read-modify-write per event, clear, PS read port |
| `src/axi_lite_slave.vhd` | AXI4-Lite protocol → simple register bus |
| `constraints/board_top.xdc` | Clock constraint only |
| `build.tcl` | Vivado batch build: block design, synthesis, implementation, bitstream, `.bit.bin` |
| `model/` | Python golden model: `dsp.py` (bit-exact modules), `expected.py` (predictions), `compare.py` (checks a run) |
| `sim/` | Testbenches; `sim/ps7_stub_wrapper_sim.vhd` stands in for the PS7 |
| `scripts/run_sims.sh` | Every hardware-free check in one command |
| `scripts/serial_load.py` | PC: send the bitstream over the serial console and load it |
| `scripts/load_board_top.sh` | Board: release the PL, set the clock, load, check the AXI path and ID |
| `scripts/daq.py` | PC: `status`, `set`, `run`, `sweep-threshold` over the serial console |
| `scripts/board/daq_board.py` | Board: register access via `/dev/mem`, writes the result files |
| `docs/learning/` | How and why everything works |
| `docs/BRINGUP_CHECKLIST.md` | Step-by-step hardware session with predicted results |

## Register map

Base `0x43C0_0000`. All 32-bit. Defaults are the reset values. `core_top.vhd` has the same
table.

| Offset | Name | | Meaning |
|---|---|---|---|
| 0x000 | ID | RO | `0x454E0001` |
| 0x004 | CONFIG | RO | [7:0] pulse set, [15:8] K, [23:16] L, [31:24] M |
| 0x008 | CONTROL | RW | bit 0 run; bit 1 clear (histograms, counters, trap filters; self-clearing) |
| 0x00C | STATUS | RO | bit 0 run, bit 1 clear in progress |
| 0x010 | UPTIME | RO | clocks since reset |
| 0x014 | RUN_CLOCKS | RO | clocks with run = 1 since clear (wraps at 128.8 s) |
| 0x018 | CONV_GAIN | RW | bin = energy >> CONV_GAIN. Default 5 |
| 0x01C | USER_PATTERN | RW | coincidence pattern. Default `0011` |
| 0x020 | TRIG_WIDTH | RW | trigger window Δt, clocks. Default 50 |
| 0x024 | COINC_COUNT | RO | coincidences while running |
| 0x028 | BASELINE | RW | ADC baseline subtracted before the trap. Default 100. Clear after changing |
| 0x030 + 4·ch | THRESHOLD_ch | RW | signed 16-bit trigger threshold. Default 1250 |
| 0x040 + 16·ch | TRIG / EVENT / OVER / PILEUP counts | RO | +0, +4, +8, +C |
| 0x1_0000 + 0x4000·ch + 4·bin | HIST | RO | histogram ch, bins 0..4095 |

## Key parameters

- Trap filter K = 32 (peaking, 0.96 µs), L = 56 (flat top 24 clocks), M = 5 (pulse τ = 32 clocks).
  Energy ≈ K × charge, so at conversion gain 5 a pulse of charge A lands in bin ≈ A − 1.
- Energy window = L + 16 = 72 clocks after the trigger.
- Pulse period 512 clocks (65,104 pulses/s per channel). Channels 2–3 start 40 clocks after 0–1.
- Trigger: threshold 1250, window 50 clocks, triangular filter width 10 (unchanged).
- ADC samples are unsigned 12-bit with baseline 100.

## Checking without hardware

```sh
sh scripts/run_sims.sh
```
1. VHDL-93 analysis of every design file (Vivado 2022.2 rejects some newer constructs; see below)
2. `python3 -m model.expected --vectors` writes `sim/vectors/*.txt`
3. `tb_pulse_gen`, `tb_trap_filter`: every output sample equals the model's; `tb_histogram`: unit checks
4. `tb_core_top`: two complete runs through the AXI port, written to `build/sim_out/run_*` in the board's file format
5. `python3 -m model.compare` on both: must print PASS

Predictions for any settings: `python3 -m model.expected [--set 1] [--threshold CH V] [--trig-width N] [--pattern 0bXXXX] [--gain G] [--baseline B]`.

## Build and run on the board

```sh
source ~/Xilinx/Vivado/2022.2/settings64.sh
vivado -mode batch -source build.tcl            # -tclargs 1 for pulse set 1
python3 scripts/serial_load.py                  # board logged in as root; port free
python3 scripts/daq.py run --seconds 10         # acquire, save to results/, compare
```
Check `build/timing_summary.rpt` (WNS/WHS ≥ 0) and `build/drc.rpt`. Details, expected output
and troubleshooting: `docs/BRINGUP_CHECKLIST.md`.

`load_board_top.sh` (sent by `serial_load.py`) unbinds Avnet's PL drivers, sets `FCLK_CLK0`, loads the
bitstream, then makes sure the PS→PL level shifters are on and the PL reset is released
before it reads the ID register. An AXI read that nothing answers hangs the bus and
freezes Linux, which is also why `daq_board.py` refuses to run until the load script has
left `/tmp/board_top.loaded`. Avnet's design comes back at every reboot, so load again after
each one.

## VHDL-93 rules

Vivado 2022.2 defaults to VHDL-93, and has rejected each of these in this project. All
design files (not testbenches) must avoid them:

- `process(all)`
- A bare `std_logic` as an `if` condition. Write `if x = '1'`.
- A generic default that references another generic. Use a literal and document the constraint.
- A function call or expression as an actual in a port map. Use an initialized signal.

## Known issues and open items

- **Untested on hardware:** the block design Tcl, the AXI path, and the board scripts on Python 3.5.
  The bring-up checklist lists the likely failure points.
- **The ADC format is an assumption** (unsigned). Confirm against the real ADC.
- **Baseline must be exact.** An error of 1 count shifts every energy by K·L/2^M = 56 (≈ 2 bins at gain 5).
  A real detector needs a baseline-restoration stage; here the baseline is a register.
- **RUN_CLOCKS wraps** after 128.8 s, so `daq_board.py` limits runs to 120 s.
- **Each trigger window is `trig_width` + 2 clocks** (FSM entry and exit).
- The heartbeat LED is replaced by the UPTIME register; `daq.py status` twice shows it counting.
