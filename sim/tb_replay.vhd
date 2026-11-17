-- tb_replay.vhd
--
-- System test of the replay path, through the AXI4-Lite port, playing the
-- part of `daq_board.py replay`:
--   1. SOURCE = 1, POLARITY = 0010 (ch1 inverted), TRAP_M = 13, BASELINE = 200,
--      thresholds 250 -- the settings for Max's CZT data -- and BLR_ENABLE =
--      0011 (baseline restorer on ch0/ch1), then clear
--   2. for each of sim/vectors/replay_a.txt and replay_b.txt (synthetic
--      CZT-like events written by `python3 -m model.expected --vectors`):
--      load the buffer, read it back, set REPLAY_LEN, run until STATUS.done,
--      stop. Histograms accumulate over both files.
--   3. read every register and histogram bin and write them, with
--      replay_files.txt, to build/sim_out/run_replay in the board's format
-- Then `python3 -m model.compare build/sim_out/run_replay` checks it bin for
-- bin against model/replay.py. scripts/run_sims.sh runs it all.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_replay is
end tb_replay;

architecture sim of tb_replay is

    constant clk_period : time    := 30 ns;
    constant OUT_DIR    : string  := "build/sim_out/run_replay";
    constant REPLAY_BUF : integer := 16#80000#;

    signal clk     : std_logic := '0';
    signal done    : boolean := false;
    signal aresetn : std_logic := '0';

    signal awaddr, araddr : std_logic_vector(19 downto 0) := (others => '0');
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

        procedure axi_write(addr : integer; data : integer) is
        begin
            awaddr  <= std_logic_vector(to_unsigned(addr, 20));
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

        procedure axi_read(addr : integer; data : out std_logic_vector(31 downto 0)) is
        begin
            araddr  <= std_logic_vector(to_unsigned(addr, 20));
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
            dump_reg(cfg, "source",       16#02C#, false);
            dump_reg(cfg, "polarity",     16#080#, false);
            dump_reg(cfg, "trap_m",       16#084#, false);
            dump_reg(cfg, "blr_enable",   16#08C#, false);
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

        -- Load one vector file into the buffer, check it, play it once.
        procedure play_file(name : string) is
            file vec : text;
            variable ln     : line;
            variable w, n   : integer := 0;
            variable first  : integer;
            variable last   : integer;
            variable d      : std_logic_vector(31 downto 0);
        begin
            file_open(vec, name, read_mode);
            while not endfile(vec) loop
                readline(vec, ln);
                read(ln, w);
                if n = 0 then
                    first := w;
                end if;
                last := w;
                axi_write(REPLAY_BUF + 4 * n, w);
                n := n + 1;
            end loop;
            file_close(vec);
            axi_read(REPLAY_BUF, d);
            assert to_integer(unsigned(d)) = first report "replay word 0 readback" severity failure;
            axi_read(REPLAY_BUF + 4 * (n - 1), d);
            assert to_integer(unsigned(d)) = last report "replay last word readback" severity failure;

            axi_write(16#088#, n);                 -- REPLAY_LEN
            wait_clocks(300);                      -- idle: let everything settle
            axi_write(16#008#, 1);                 -- run: plays the buffer once
            axi_read(16#00C#, d);
            assert d(2) = '1' or d(3) = '1' report "replay did not start" severity failure;
            loop
                axi_read(16#00C#, d);
                exit when d(3) = '1';
            end loop;
            wait_clocks(300);
            axi_write(16#008#, 0);                 -- stop
            report "played " & name & ": " & integer'image(n) & " words";
        end procedure;

        variable d : std_logic_vector(31 downto 0);
        file lst : text;
        variable ln : line;

    begin
        wait_clocks(10);
        aresetn <= '1';
        wait_clocks(5);

        axi_read(16#000#, d);
        assert d = x"454E0003" report "bad ID 0x" & to_hstring(d) severity failure;

        axi_write(16#02C#, 1);                     -- SOURCE = replay
        axi_write(16#080#, 2);                     -- POLARITY: invert ch1 (cathode)
        axi_write(16#084#, 13);                    -- TRAP_M
        axi_write(16#08C#, 3);                     -- BLR_ENABLE: ch0 and ch1
        axi_write(16#028#, 200);                   -- BASELINE
        for ch in 0 to 3 loop
            axi_write(16#030# + 4*ch, 250);        -- THRESHOLD_ch
        end loop;
        axi_read(16#004#, d);
        assert d = x"0D382002" report "bad CONFIG 0x" & to_hstring(d) severity failure;

        axi_write(16#008#, 2);                     -- clear
        loop
            axi_read(16#00C#, d);
            exit when d(1) = '0';
        end loop;

        play_file("sim/vectors/replay_a.txt");
        play_file("sim/vectors/replay_b.txt");

        dump_run(OUT_DIR);
        file_open(lst, OUT_DIR & "/replay_files.txt", write_mode);
        write(ln, string'("sim/vectors/replay_a.txt"));  writeline(lst, ln);
        write(ln, string'("sim/vectors/replay_b.txt"));  writeline(lst, ln);
        file_close(lst);

        report "tb_replay finished: now run python3 -m model.compare " & OUT_DIR;
        done <= true;
        wait;
    end process;

end sim;
