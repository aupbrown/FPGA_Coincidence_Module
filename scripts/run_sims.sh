#!/bin/sh
# ----------------------------------------------------------------------------
# Run every check that does not need hardware -- from the repository root:
#   sh scripts/run_sims.sh
#
#   1. VHDL-93 analysis of all design sources (what Vivado 2022.2 accepts)
#   2. Python model writes the expected sample files (sim/vectors/)
#   3. Self-checking testbenches: pulse_gen, trap_filter, histogram vs the model
#   4. tb_core_top: two full runs through the AXI port, results written to
#      build/sim_out/run_default and run_custom in the board's file format
#   5. model.compare checks those runs against the model's prediction
# Stops at the first failure.
# ----------------------------------------------------------------------------
set -e

SRC="src/pulse_config_pkg.vhd src/pulse_gen.vhd src/trigger.vhd src/coincidence.vhd
     src/detector_top.vhd src/trap_filter.vhd src/energy_capture.vhd src/histogram.vhd
     src/axi_lite_slave.vhd src/core_top.vhd"
W=build/nvc

echo "== 1. VHDL-93 check"
rm -rf $W && mkdir -p $W
nvc --std=1993 --work=$W/vhdl93 -a $SRC sim/ps7_stub_wrapper_sim.vhd src/board_top.vhd
nvc --std=1993 --work=$W/vhdl93 -e board_top
echo "ok"

echo "== 2. model vectors"
python3 -m model.expected --vectors

echo "== 3./4. testbenches"
mkdir -p build/sim_out/run_default build/sim_out/run_custom
nvc --work=$W/work -a $SRC sim/tb_pulse_generator.vhd sim/tb_trap_filter.vhd \
    sim/tb_histogram.vhd sim/tb_core_top.vhd
for tb in tb_pulse_gen tb_trap_filter tb_histogram tb_core_top; do
    nvc --work=$W/work -e $tb
    nvc --work=$W/work -r $tb --ieee-warnings=off
done

echo "== 5. compare simulation runs with the model"
python3 -m model.compare build/sim_out/run_default build/sim_out/run_custom
