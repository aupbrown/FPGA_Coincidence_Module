# How the PS, the PL and the host PC talk

```
host PC                         Zynq PS (Linux)                        PL (FPGA)
scripts/daq.py ──USB serial──▶  root shell                                 
                                python3 /tmp/daq_board.py                  
                                  mmap(/dev/mem @ 0x43C0_0000)             
                                  32-bit load/store ─▶ AXI GP0 (AXI3) ─▶ protocol converter
                                                                          ─▶ AXI4-Lite ─▶ axi_lite_slave
                                                                                          ─▶ core_top registers
                                  writes /tmp/daq_run/*.csv                                  + histogram RAMs
scripts/daq.py ◀─gzip|base64──  cat files back
model/compare.py: PASS / FAIL
```

## AXI4-Lite in one page

Five channels, each a one-way bundle with **VALID** (sender has something) and **READY** (receiver can
take it). A transfer happens on a clock edge where both are 1. The sender must hold VALID until it sees
READY.

| channel | direction | carries |
|---|---|---|
| AW | PS → PL | write address |
| W | PS → PL | write data + byte strobes |
| B | PL → PS | write response (OKAY) |
| AR | PS → PL | read address |
| R | PL → PS | read data + response |

`axi_lite_slave.vhd`:
- **write:** waits until AW and W are both valid, raises AWREADY/WREADY for one clock (the handshake),
  and pulses `wr_en` to the register map in the same clock. Then it holds BVALID until BREADY.
- **read:** raises ARREADY for one clock and latches the address. The register map takes **2 clocks**
  (stage 1 selects the register and the histogram RAM reads its bin; stage 2 picks between them),
  then RVALID is held with the data until RREADY.

**Why AXI4-Lite and a converter?** The PS's GP0 port speaks full AXI3 (IDs, bursts). A Lite slave
is far simpler to write. The `axi_protocol_converter` in the block design splits whatever the PS does
into single 32-bit Lite transfers.

**Why the PS can freeze:** a read waits for RVALID forever. If nothing answers (PL not loaded, held in
reset, level shifters off), the CPU stalls and Linux hangs. `load_board_top.sh` checks all three before
the first read, and `daq_board.py` refuses to run until the load script has succeeded.

## The block design (build.tcl)

- `ps7`: GP0 enabled, FCLK_CLK0 at 33.333 MHz, FCLK_RESET0_N enabled.
- `proc_sys_reset`: turns the PS's reset into a clean reset synchronous to the clock → `PL_RESETN`.
- `axi_protocol_converter`: AXI3 → AXI4-Lite → external port `M_AXI`.
- `assign_bd_address`: `M_AXI` at **0x43C0_0000, 128 KB**. That's the window the PS's address decoder
  forwards to the PL. `core_top` gets the low 17 bits.

Everything runs on the one clock, FCLK_CLK0, so there are **no clock-domain crossings**.

## /dev/mem and mmap

Linux user programs normally can't touch physical addresses. `/dev/mem` is the exception: mapping it at
offset 0x43C0_0000 makes a Python `memoryview` whose element *i* **is** register 4·*i*. Each element
read or write is one aligned 32-bit access, so one AXI transaction. `O_SYNC` makes the mapping uncached,
so every access really goes to the bus. No kernel driver or device-tree change is needed, at the cost
of root access and no protection.

## The serial console as a transport

There's no network setup, only the USB-UART that already gives a root shell. `serial_load.py`'s
`Console` types commands and reads replies up to the `# ` prompt. Files go to the board as base64 text
fed to `cat`, and come back the same way (`gzip -c FILE | base64`, between `__BEGIN__`/`__END__`
markers). A 4096-bin histogram file compresses to a few KB, so it takes about a second at 115200 baud.

`daq.py` sends `daq_board.py` fresh every time (/tmp empties at reboot, and it is small).

## Run-time inputs (the last goal)

Threshold and Δt window were already ports of `detector_top`; before, `board_top` tied them to
constants. Now they come from registers (THRESHOLD_ch, TRIG_WIDTH), so `daq.py set threshold 600 --ch 3`
reaches the comparator in `trigger.vhd` within microseconds. Changing them mid-run is safe in
hardware but mixes two settings in one histogram, so `daq.py run` always clears first and the compare
step reads back the settings actually used.
