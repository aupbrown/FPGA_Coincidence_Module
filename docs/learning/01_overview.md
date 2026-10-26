# Overview: what was built and how it is verified

## The four goals, and where each one lives

| Your goal | Done by |
|---|---|
| Energy + histogram projects from the 2018 workshop, working on this hardware | `trap_filter.vhd`, `energy_capture.vhd`, `histogram.vhd`, wired per channel in `core_top.vhd` |
| No LEDs; test by having the PS write files and comparing with expected behaviour | `axi_lite_slave.vhd` + register map, `scripts/board/daq_board.py`, `model/compare.py` |
| Change the pulse constants and work out the new expected behaviour | `pulse_config_pkg.vhd` set 1 → set 2, predicted by `model/expected.py` |
| Threshold and Δt window as inputs set from a Python program on the host | THRESHOLD_ch and TRIG_WIDTH registers, `scripts/daq.py set ...` |

## Why not just port the workshop VHDL?

The workshop code instantiates Xilinx ISE cores (`hist_BRAM`, `Moving_filter`, `adc_delay`,
`timer`, `bram_a`, `trap_sub`, `trap_acc_out`) whose sources aren't in the folder and don't exist
for Vivado/Zynq. It also uses the non-standard `STD_LOGIC_UNSIGNED` package, a different
trigger interface, and negative-going pulses. So each block was rewritten from the workshop's
slides and code into plain VHDL-93 that matches this repository's style:

| Workshop | Here | Changes |
|---|---|---|
| Trap_exp `trap_exp.vhd` | `trap_filter.vhd` | Same math. Shift registers instead of BRAM buffers, exact integer pole-zero, baseline subtraction |
| Peak_Detector `peak_detector.vhd` | `energy_capture.vhd` | Same "keep the max" idea, gated by a window after each trigger, plus pile-up detection |
| Histogram `histogram.vhd` | `histogram.vhd` | Same read-modify-write FSM and conversion-gain shift; energy now comes from the trap, not charge integration; inferred BRAM; no timers/gating (not needed here) |
| RayCodeW USB interface | AXI4-Lite + Linux + serial console | The PicoZed has a PS running Linux, so the "host interface" is the PS |

## The verification idea: a golden model

"Expected behaviour" should be a **file you can diff**, not an eyeball judgement. So:

1. `model/dsp.py` is a Python copy of every VHDL module, **bit-exact and clock-exact**: same widths,
   same rounding, same register timing.
2. Unit testbenches compare the VHDL with the model **every clock**
   (`tb_pulse_gen`, `tb_trap_filter`: 3000 samples each, all equal).
3. Because the pulse trains are periodic, the model predicts the exact histogram per "super-period"
   (`model/expected.py`). A run of R clocks expects R / super-period times that.
4. The system testbench (`tb_core_top`) and the real board both produce the **same files**
   (`config.csv`, `counters.csv`, `hist_ch*.csv`), and `model/compare.py` checks either one.

So the simulation and the hardware are judged by the same file and the same rule. When
something differs, the compare output names exactly what differed.

The model already caught one real design bug before any hardware: the baseline offset
(`02_trap_filter.md`, section 5).

## Reading order

1. `02_trap_filter.md`: the math (the most important one)
2. `03_energy_and_histogram.md`: from the trapezoid to a histogram bin
3. `04_ps_pl_interface.md`: AXI, the block design, `/dev/mem`, the serial console scripts
4. `../BRINGUP_CHECKLIST.md`: the hardware session, with every predicted number
