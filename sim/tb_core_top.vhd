-- tb_core_top.vhd
--
-- System test of everything in the PL, through the same AXI4-Lite port the
-- PS uses. The testbench plays the part of scripts/board/daq_board.py:
--   1. check the ID and CONFIG registers
--   2. run "default": reset-value registers, clear, run 4 super-periods, stop
--   3. run "custom":  threshold_3 = 600, trig_width = 60, pattern = 0111,
--                     conv_gain = 4 -- the run-time inputs the host can set
--   4. after each run, read every register and all 4 x 4096 histogram bins
--      over AXI and write them to build/sim_out/run_<name>/ in exactly the
--      board's file format
-- Then `python3 -m model.compare build/sim_out/run_default build/sim_out/run_custom`
-- checks the files against the model, just as it checks a hardware run.
-- scripts/run_sims.sh creates the output directories and runs it all.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_core_top is
end tb_core_top;

architecture sim of tb_core_top is

    constant clk_period   : time    := 30 ns;
    constant SUPER_PERIOD : integer := 2048;   -- pulse set 2: lcm(512 x amps)

    signal clk     : std_logic := '0';
    signal done    : boolean := false;
    signal aresetn : std_logic := '0';

    signal awaddr, araddr : std_logic_vector(16 downto 0) := (others => '0');
    signal awvalid, wvalid, bready, arvalid, rready : std_logic := '0';
    signal awready, wready, bvalid, arready, rvalid : std_logic;
    signal wdata, rdata : std_logic_vector(31 downto 0) := (others => '0');
    signal wstrb        : std_logic_vector(3 downto 0) := "1111";
    signal bresp, rresp : std_logic_vector(1 downto 0);

begin

    uut: entity work.core_top
        generic map (PULSE_SET => 2, K => 32, L => 56, TRAP_M => 5)
        port map (aclk => clk, aresetn => aresetn,
                  s_axi_awaddr => awaddr, s_axi_awvalid => awvalid, s_axi_awready => awready,
                  s_axi_wdata => wdata, s_axi_wstrb => wstrb, s_axi_wvalid => wvalid,
                  s_axi_wready => wready, s_axi_bresp => bresp, s_axi_bvalid => bvalid,
                  s_axi_bready => bready, s_axi_araddr => araddr, s_axi_arvalid => arvalid,
                  s_axi_arready => arready, s_axi_rdata => rdata, s_axi_rresp => rresp,
                  s_axi_rvalid => rvalid, s_axi_rready => rready);

    clk <= not clk after clk_period / 2 when not done;

    stim: process

        -- One AXI4-Lite write: present address and data, wait for the
        -- handshake, then take the write response.
        procedure axi_write(addr : integer; data : integer) is
        begin
            awaddr  <= std_logic_vector(to_unsigned(addr, 17));
            wdata   <= std_logic_vector(to_signed(data, 32));
            awvalid <= '1';
            wvalid  <= '1';
            wait until rising_edge(clk) and awready = '1';
            awvalid <= '0';
            wvalid  <= '0';
            bready  <= '1';
            wait until rising_edge(clk) and bvalid = '1';
            assert bresp = "00" report "write error response" severity failure;
            bready <= '0';
        end procedure;

        -- One AXI4-Lite read.
        procedure axi_read(addr : integer; data : out std_logic_vector(31 downto 0)) is
        begin
            araddr  <= std_logic_vector(to_unsigned(addr, 17));
            arvalid <= '1';
            wait until rising_edge(clk) and arready = '1';
            arvalid <= '0';
            rready  <= '1';
            wait until rising_edge(clk) and rvalid = '1';
            data   := rdata;
            rready <= '0';
        end procedure;

        procedure wait_clocks(n : integer) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        -- Append "name,value" to a CSV, value read from a register.
        procedure dump_reg(file f : text; name : string; addr : integer; signed_value : boolean) is
            variable d  : std_logic_vector(31 downto 0);
            variable ln : line;
        begin
            axi_read(addr, d);
            write(ln, name & ",");
            if signed_value then
                write(ln, to_integer(signed(d)));
            else
                write(ln, to_integer(unsigned(d)));
            end if;
            writeline(f, ln);
        end procedure;

        procedure dump_run(dir : string) is
            file cfg, cnt, hist : text;
            variable ln : line;
            variable d  : std_logic_vector(31 downto 0);
        begin
            file_open(cfg, dir & "/config.csv", write_mode);
            write(ln, string'("name,value"));                 writeline(cfg, ln);
            axi_read(16#000#, d);
            write(ln, "id,0x" & to_hstring(d));                writeline(cfg, ln);
            axi_read(16#004#, d);
            write(ln, "config,0x" & to_hstring(d));            writeline(cfg, ln);
            dump_reg(cfg, "conv_gain",    16#018#, false);
            dump_reg(cfg, "user_pattern", 16#01C#, false);
            dump_reg(cfg, "trig_width",   16#020#, false);
            dump_reg(cfg, "baseline",     16#028#, false);
            for ch in 0 to 3 loop
                dump_reg(cfg, "threshold_" & integer'image(ch), 16#030# + 4*ch, true);
            end loop;
            file_close(cfg);

            file_open(cnt, dir & "/counters.csv", write_mode);
            write(ln, string'("name,value"));                 writeline(cnt, ln);
            dump_reg(cnt, "run_clocks",  16#014#, false);
            dump_reg(cnt, "coinc_count", 16#024#, false);
            for ch in 0 to 3 loop
                dump_reg(cnt, "trig_count_"   & integer'image(ch), 16#040# + 16*ch,     false);
                dump_reg(cnt, "event_count_"  & integer'image(ch), 16#040# + 16*ch + 4, false);
                dump_reg(cnt, "over_count_"   & integer'image(ch), 16#040# + 16*ch + 8, false);
                dump_reg(cnt, "pileup_count_" & integer'image(ch), 16#040# + 16*ch + 12, false);
            end loop;
            file_close(cnt);

            for ch in 0 to 3 loop
                file_open(hist, dir & "/hist_ch" & integer'image(ch) & ".csv", write_mode);
                write(ln, string'("bin,count"));               writeline(hist, ln);
                for b in 0 to 4095 loop
                    axi_read(16#10000# + 16#4000# * ch + 4 * b, d);
                    write(ln, b);
                    write(ln, string'(","));
                    write(ln, to_integer(unsigned(d)));
                    writeline(hist, ln);
                end loop;
                file_close(hist);
            end loop;
            report "wrote " & dir;
        end procedure;

        -- Clear, run for n clocks, stop, then dump.
        procedure do_run(dir : string; n : integer) is
            variable d : std_logic_vector(31 downto 0);
        begin
            axi_write(16#008#, 2);                 -- clear
            loop                                   -- wait for the 4096-clock clear
                axi_read(16#00C#, d);
                exit when d(1) = '0';
            end loop;
            wait_clocks(200);                      -- let the filters settle after their reset
            axi_write(16#008#, 1);                 -- run
            wait_clocks(n);
            axi_write(16#008#, 0);                 -- stop
            dump_run(dir);
        end procedure;

        variable d : std_logic_vector(31 downto 0);

    begin
        wait_clocks(10);
        aresetn <= '1';
        wait_clocks(5);

        axi_read(16#000#, d);
        assert d = x"454E0001" report "bad ID 0x" & to_hstring(d) severity failure;
        axi_read(16#004#, d);
        assert d = x"05382002" report "bad CONFIG 0x" & to_hstring(d) severity failure;

        do_run("build/sim_out/run_default", 4 * SUPER_PERIOD);

        axi_write(16#03C#, 600);                   -- threshold_3
        axi_write(16#020#, 60);                    -- trig_width
        axi_write(16#01C#, 7);                     -- user_pattern 0111
        axi_write(16#018#, 4);                     -- conv_gain
        axi_read(16#03C#, d);
        assert to_integer(signed(d)) = 600 report "threshold_3 readback" severity failure;
        do_run("build/sim_out/run_custom", 4 * SUPER_PERIOD);

        report "tb_core_top finished: now run python3 -m model.compare on the two run directories";
        done <= true;
        wait;
    end process;

end sim;
