# FPGA coincidence detector and energy spectrometer

A four-channel radiation-detector front end for the PicoZed 7030. Each channel:

1. **triggers** on a pulse (triangular filter + trigger FSM),
2. measures the pulse's **energy** with a **trapezoidal filter** and a peak detector,
3. adds one count to that energy's bin in its own 4096-bin **histogram**.

A coincidence comparator also counts when the set of triggered channels matches a pattern.
There are no LEDs or buttons. The PS (Linux) controls everything and reads the results over
the AXI bus, writes them to files, and a host PC drives it all over the USB serial cable.
The results are checked against a bit-exact Python model of the design.

There is no ADC on the carrier board. Two stand-ins feed the channels instead:

- **pulse_gen** (default): four pulse generators inside the FPGA play the part of a
  detector + preamp, with fast rise, exponential decay, and a programmable sequence of charges.
- **replay** (`SOURCE = 1`): real CZT waveforms (Max's Cs-137 depth scan,
  `pulse_data_Austin_v2_175/`) loaded into a 128K-word block RAM by the PS and played into
  ch0 (anode) and ch1 (cathode) at one sample per clock. See *Replaying recorded waveforms*.

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
PS7 ─FCLK_CLK0, reset─▶ │ pulse_gen ─┬▶ polarity ─adc─▶ trigger ─trig─┬─▶ coincidence ─▶ COINC_COUNT
                        │ replay ────┘   (x4)     │       (x4)        │      ▲ user_pattern
                        │ (ch0, ch1)              │                   │
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
| `src/replay_source.vhd` | Replay buffer: 128K × 32-bit block RAM the PS loads, played once per run at one word per clock |
| `src/trigger.vhd`, `src/coincidence.vhd`, `src/detector_top.vhd` | Trigger and coincidence (unchanged, except `detector_top` now outputs the trigger bus) |
| `src/trap_filter.vhd` | Trapezoidal filter with pole-zero correction and baseline subtraction |
| `src/energy_capture.vhd` | Peak of the trap output in a window after each trigger; pile-up detection |
| `src/histogram.vhd` | Block-RAM histogram: read-modify-write per event, clear, PS read port |
| `src/axi_lite_slave.vhd` | AXI4-Lite protocol → simple register bus |
| `constraints/board_top.xdc` | Clock constraint only |
| `build.tcl` | Vivado batch build: block design, synthesis, implementation, bitstream, `.bit.bin` |
| `model/` | Python golden model: `dsp.py` (bit-exact modules), `expected.py` (predictions), `replay.py` (exact predictions for replay runs), `compare.py` (checks a run) |
| `sim/` | Testbenches; `sim/ps7_stub_wrapper_sim.vhd` stands in for the PS7 |
| `scripts/run_sims.sh` | Every hardware-free check in one command |
| `scripts/serial_load.py` | PC: send the bitstream over the serial console and load it |
| `scripts/load_board_top.sh` | Board: release the PL, set the clock, load, check the AXI path and ID |
| `scripts/daq.py` | PC: `status`, `set`, `run`, `sweep-threshold`, `upload`, `replay` over the serial console |
| `scripts/make_replay.py` | PC: Max's `.h5` waveforms → `replay/{photopeak,random}/dNN_P.bin` (needs h5py, numpy) |
| `scripts/board/daq_board.py` | Board: register access via `/dev/mem`, writes the result files |
| `docs/learning/` | How and why everything works |
| `docs/BRINGUP_CHECKLIST.md` | Step-by-step hardware session with predicted results |

## Register map

Base `0x43C0_0000`. All 32-bit. Defaults are the reset values. `core_top.vhd` has the same
table.

| Offset | Name | | Meaning |
|---|---|---|---|
| 0x000 | ID | RO | `0x454E0002` (v1 had no POLARITY/TRAP_M/replay) |
| 0x004 | CONFIG | RO | [7:0] pulse set, [15:8] K, [23:16] L, [31:24] TRAP_M register |
| 0x008 | CONTROL | RW | bit 0 run; bit 1 clear (histograms, counters, trap filters; self-clearing) |
| 0x00C | STATUS | RO | bit 0 run, bit 1 clear in progress, bit 2 replay playing, bit 3 replay done |
| 0x010 | UPTIME | RO | clocks since reset |
| 0x014 | RUN_CLOCKS | RO | clocks with run = 1 since clear (wraps at 128.8 s) |
| 0x018 | CONV_GAIN | RW | bin = energy >> CONV_GAIN. Default 5 |
| 0x01C | USER_PATTERN | RW | coincidence pattern. Default `0011` |
| 0x020 | TRIG_WIDTH | RW | trigger window Δt, clocks. Default 50 |
| 0x024 | COINC_COUNT | RO | coincidences while running |
| 0x028 | BASELINE | RW | ADC baseline subtracted before the trap. Default 100. Clear after changing |
| 0x02C | SOURCE | RW | bit 0: 1 = ch0/ch1 take replay lanes A/B, ch2/ch3 a constant BASELINE. Default 0 (pulse_gen) |
| 0x030 + 4·ch | THRESHOLD_ch | RW | signed 16-bit trigger threshold. Default 1250 |
| 0x040 + 16·ch | TRIG / EVENT / OVER / PILEUP counts | RO | +0, +4, +8, +C |
| 0x080 | POLARITY | RW | [3:0] bit ch = 1 inverts ch's samples (4095 − x), for negative pulses. Default 0 |
| 0x084 | TRAP_M | RW | trap pole-zero shift M (τ ≈ 2^M clocks), 0–13. Default 5 (pulse_gen). Clear after changing |
| 0x088 | REPLAY_LEN | RW | words to play, 1–131072 |
| 0x1_0000 + 0x4000·ch + 4·bin | HIST | RO | histogram ch, bins 0..4095 |
| 0x8_0000 + 4·i | REPLAY_BUF | RW | replay word i: [11:0] lane A (ch0), [27:16] lane B (ch1) |

The AXI window is 1 MB (20 address bits).

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

## Replaying recorded waveforms

Software can't stream samples at 33 MHz (Linux reaches about 10⁶ AXI writes per second at best), so loading
and playing are split. The PS loads a file into the replay buffer while the run is stopped.
Then the PL plays it once, one word per clock, exactly as an ADC would deliver samples.

```sh
python3 scripts/make_replay.py                                  # once: .h5 -> replay/*/dNN_P.bin
python3 -m model.replay replay/photopeak/d12_*.bin              # prediction, no board needed
python3 scripts/daq.py replay replay/photopeak/d12_*.bin        # upload, play, fetch, compare
python3 scripts/daq.py replay replay/photopeak/d*.bin --per-file   # one run per depth
python3 scripts/daq.py replay replay/random/d*.bin              # one pooled spectrum
```

- **Packing:** events are kept whole (1601 samples, the edge at ~640) and concatenated. A
  depth doesn't fit the 131,072-word buffer in one load, so it is split into parts of whole
  events, one load each: photopeak `dNN_0/1.bin` (50 + 50 events), random `dNN_0/1/2.bin`
  (59 + 58 + 58). The parts of a run play one after another into the same histograms;
  `--per-file` makes one run per depth. Where two records meet, the signal drops from the
  tail back to baseline; the trap sees that as a negative pulse and is back at 0 long
  before the next edge, and the trigger only fires on rising signals. Anode + 200 goes
  in lane A. Cathode + 3895 goes in lane B, still negative-going; `POLARITY` bit 1 flips it in the FPGA
  to a baseline of 200. One `BASELINE` (200) then serves both.
- **Settings** (`daq.py replay` sets them; see `model/replay.py`'s `REPLAY_REGS`):
  `TRAP_M 13`, because the CZT preamp decays with τ ≈ 8,300 samples (2¹³ = 8192). With
  `TRAP_M 5` the trap never returns to 0. Thresholds 250 (ch0, anode) and 270 (ch1,
  cathode): the trigger filter peaks at ~2.6 × amplitude, with noise σ ≈ 38 (anode) and
  47 (cathode); 1250 would cut most of the Compton continuum.
- **Exact check:** the trap filters are held in reset between plays. With that, the result
  doesn't depend on Linux's timing, and `model.compare` checks replay runs bin for bin.
- **Rate:** within a file the data flows at one sample per clock. At 33.3 MHz that is 1.5×
  slower than the 50 MS/s recording. The filters count samples, so results are the same.
- Expected results per test stage: `docs/BRINGUP_CHECKLIST.md`, section 7.

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

- **Verified on hardware** (2026-10-26): both pulse sets, run-time settings and sweeps, 37 runs, all
  PASS against the model. Runs and settings: `results/README.md`. Avnet's Python 3.5.2 has no
  `mmap` module; `daq_board.py` falls back to libc `mmap()` through `ctypes`.
- **The ADC format is an assumption** (unsigned). Confirm against the real ADC.
- **Replay is simulated, not yet built or run on hardware.** The 128K-word buffer uses about 128
  of the XC7Z030's 265 BRAM36. Check `utilization_impl.rpt` and timing after the first build.
- **One BASELINE for all channels.** It works for the replay data thanks to the chosen
  offsets. A real anode + cathode ADC will need per-channel baselines.
- **Cathode ballistic deficit:** cathode rise times (24–47 samples) exceed the trap's flat
  top (L − K = 24), so shallow-depth cathode energies read low. Worth trying a longer L.
- **Baseline must be exact.** An error of 1 count shifts every energy by K·L/2^M = 56 (≈ 2 bins at gain 5).
  A real detector needs a baseline-restoration stage; here the baseline is a register.
- **RUN_CLOCKS wraps** after 128.8 s, so `daq_board.py` limits runs to 120 s.
- **Each trigger window is `trig_width` + 2 clocks** (FSM entry and exit).
- The heartbeat LED is replaced by the UPTIME register; `daq.py status` twice shows it counting.
