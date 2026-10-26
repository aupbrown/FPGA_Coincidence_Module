# Bring-up checklist: energy histograms on the PicoZed 7030

Work through this in order at the Vivado PC with the carrier's USB-UART connected.
Every step says what you should see. If you see something else, stop there: later steps
depend on earlier ones.

Already verified on the Mac, without hardware (`sh scripts/run_sims.sh`): VHDL-93
analysis, three unit testbenches that match the Python model sample for sample, and two
full-system runs through the AXI port, both PASS against the model. **Verified on
hardware 2026-10-26:** every step below passed (37 runs, all PASS; see `results/README.md`).

---

## 0. On the Vivado PC (about 2 minutes)

```sh
cd FPGA_Coincidence_Module      # the repository root (or wherever you cloned it); run every command from here
python3 --version               # host needs >= 3.9 (model uses math.lcm)
sh scripts/run_sims.sh          # optional if nvc is installed: everything should end in PASS
python3 -m model.expected --set 1   # write these predictions down before you build
python3 -m model.expected --set 2
```

## 1. Build both bitstreams (~10-20 min each)

The plan: **set 1** is the original pulse constants (reshaped for the trap filter); **set 2** is the
changed constants. Build set 1 first and keep a copy, then build set 2.

```sh
source ~/Xilinx/Vivado/2022.2/settings64.sh
vivado -mode batch -source build.tcl -tclargs 1
cp build/board_top.bit.bin build/board_top_set1.bit.bin
vivado -mode batch -source build.tcl -tclargs 2
cp build/board_top.bit.bin build/board_top_set2.bit.bin
```

Check after each build:
- `build/timing_summary.rpt`: **WNS and WHS ≥ 0** ("All user specified timing constraints are met").
- `build/drc.rpt`: no errors. Specifically **no ZPS7-1**.
- `build/utilization_impl.rpt`: about **16 RAMB36** (4 histograms × 4096 × 32 bit). If it's 0, the
  histograms were built from LUTs/FFs instead of block RAM: tell me.

**If the block-design step fails** (it's the only Tcl I couldn't run here):

| Error mentions | Fix |
|---|---|
| `M_AXI/Reg` not found in `assign_bd_address` | In the Tcl console after the failure: `get_bd_addr_segs` and use the name it lists for the external port's segment |
| `FREQ_HZ` mismatch | `build.tcl` copies `FCLK_CLK0`'s FREQ_HZ onto the ports. Check `get_property CONFIG.FREQ_HZ [get_bd_pins ps7/FCLK_CLK0]` |
| port `M_AXI_...` not found while elaborating `board_top` | Open `build/bd/ps7_stub/hdl/ps7_stub_wrapper.vhd` and make the `ps7_stub_wrapper` component in `src/board_top.vhd` match its port list exactly |
| `SI_PROTOCOL` / `MI_PROTOCOL` | Harmless; the `catch` prints a note and the converter takes them from its connections |

## 2. Board login and one-time checks

```sh
screen /dev/ttyUSB0 115200      # log in as root, then quit: Ctrl-A K Y
```
In that root shell (before quitting screen), check once:
```sh
ls -l /dev/mem                  # must exist
which devmem python3            # both must exist
python3 --version               # expect 3.5.x on Avnet's 2017.4 image (no mmap module: see below)
```
If `python3` is missing, the board-side readout needs rewriting as a shell script around
`devmem`: tell me. If `devmem` is missing, `load_board_top.sh` stops before touching the bus.

Avnet's 2017.4 image ships Python 3.5.2 **without the `mmap` module** (`import mmap` fails
with `ImportError: No module named 'mmap'`). `daq_board.py` handles this: when `mmap` is
missing it calls libc's `mmap()` through `ctypes` instead, which gives the same `/dev/mem`
mapping and still one 32-bit AXI access per register. Nothing to do here, but if
`daq.py status` ever shows that traceback, the board has an old copy of `daq_board.py`:
`daq.py` re-sends it on every call, so check you are on the current branch.

## 3. Load set 1

```sh
python3 scripts/serial_load.py build/board_top_set1.bit.bin
```
Expect, at the end:
```
FCLK_CLK0 = 33333333 Hz, enabled
loaded /tmp/board_top.bit.bin: DONE = 1
LVL_SHFTR_EN = 0x0000000F, FPGA_RST_CTRL = 0x00000000
core_top ID = 0x454E0001
```
- `LVL_SHFTR_EN` or `FPGA_RST_CTRL` showing other values is fine: the script prints
  "enabling level shifters and releasing PL resets" and fixes them.
- **If the board freezes at the ID read** (console stops answering): power-cycle. The PS's
  AXI read got no response. Likely causes, in order: PL still in reset (`FPGA_RST_CTRL`), the
  AXI address isn't `0x43C0_0000` (check the address editor in `build/bd`), or the build's
  wrapper wiring. Note what the console printed last and tell me.
- `core_top ID is 0x...` mismatch: the bitstream isn't this design (wrong file?).

## 4. Status and the first run (set 1, the original constants)

```sh
python3 scripts/daq.py status
python3 scripts/daq.py run --seconds 10
```
`status` should show the defaults: `conv_gain 5`, `user_pattern 3`, `trig_width 50`,
`baseline 100`, `threshold_* 1250`, and `uptime` increasing between calls.

`run` makes the PS clear, run for 10 s, stop, and write `config.csv`, `counters.csv` and
`hist_ch0..3.csv` to `/tmp/daq_run/` on the board. It then copies them to
`results/run_<date>_<time>/` and checks them against the model. **Predicted for set 1:**
- every channel: one peak, **bin 1999**, about **651,000 counts** (65,104 pulses/s × 10 s)
- trig_count = event_count ≈ 651,000 per channel; over range 0; pile-up 0
- coincidences (pattern 0011): ≈ 651,000

Expect `PASS: results/run_...`. Every check prints, so a FAIL says exactly what differed.

## 5. Change the pulse constants: load set 2

```sh
python3 scripts/serial_load.py build/board_top_set2.bit.bin
python3 scripts/daq.py run --seconds 10
```
**Predicted for set 2** (super-period 2048 clocks = 61.44 µs, 16,276 per second):

| ch | charges | expected bins | counts in 10 s |
|---|---|---|---|
| 0 | 500, 1000, 1500, 2000 in turn | 499, 999, 1499, 1999 | ≈ 162,760 each |
| 1 | 3000 | 2999 | ≈ 651,000 |
| 2 | 800, 2400 alternating | 799, 2399 | ≈ 325,500 each |
| 3 | 200 (below threshold) | **empty**: no triggers at all | 0 |

Coincidence (pattern 0011): ≈ 651,000. Why each bin is A − 1 and not A: see
`docs/learning/03_energy_and_histogram.md`.

## 6. Run-time inputs from the host (threshold, Δt window, pattern, gain)

Each `set` takes effect immediately; `run` reports the settings it used in `config.csv`,
and the compare step predicts with *those* settings.

```sh
python3 scripts/daq.py set threshold 600 --ch 3     # ch3's 200-charge pulses now trigger
python3 scripts/daq.py run --seconds 5              # ch3: bin 199 appears
python3 scripts/daq.py set gain 4                   # bins double; ch1's 3000 -> 6000: over range
python3 scripts/daq.py run --seconds 5
python3 scripts/daq.py set gain 5
python3 scripts/daq.py set pattern 0b0111
python3 scripts/daq.py set trig_width 39            # see the table below
python3 scripts/daq.py run --seconds 5
python3 scripts/daq.py sweep-threshold 3 500 600 700 800 900 --seconds 1
```

Predicted (set 2), from `model.expected`:

Trigger threshold sweep (triggers per super-period):

| threshold | ch0 | ch1 | ch2 | ch3 |
|---|---|---|---|---|
| ≤ 700 | 4 | 4 | 4 | 4 |
| 800 – 1500 | 4 | 4 | 4 | **0** |
| 2000 – 2500 | 3 (500 drops out) | 4 | 4 | 0 |
| 3000 | 3 | 4 | 2 (800 drops out) | 0 |
| 4000 – 5000 | 2 | 4 | 2 | 0 |
| 6000 | 1 | 4 | 2 | 0 |

Coincidences per super-period vs pattern and Δt window (`trig_width`):

| pattern | 10 | 30 | 39 | 40 | 41 | 50 | 100 |
|---|---|---|---|---|---|---|---|
| 0011 | 4 | 4 | 4 | 4 | 4 | 4 | 4 |
| 0111 | 0 | 0 | 2 | 2 | 4 | 4 | 4 |
| 0001 | 3 | 3 | 2 | 0 | 0 | 0 | 0 |
| 1111 | 0 | 0 | 0 | 0 | 0 | 0 | 0 (ch3 never triggers) |

0111 needs ch0/ch1's windows to still be open when ch2 fires 40 clocks later, so it switches on
around `trig_width` ≈ 40. 0001 firing at short windows is new behaviour: ch1's large pulse
crosses threshold before ch0's small ones, so ch1's window closes first and briefly leaves
only ch0. With identical pulses (the old design) that couldn't happen.

You can check any of these by hand first: `python3 -m model.expected --pattern 0b0111 --trig-width 39`.

## When done

Results live in `results/`. Nothing is committed yet: review with `git status`, then commit when
you're happy.
