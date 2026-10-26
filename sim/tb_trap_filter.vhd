-- tb_trap_filter.vhd
--
-- Self-checking: feeds trap_filter the model's pulse train (pulse set 2,
-- channel 0: charges 500, 1000, 1500, 2000) and compares every output sample
-- with the Python model, from sim/vectors/trap_filter.txt (written by
-- `python3 -m model.expected --vectors`). Row i = input sample i, and the
-- expected trap output after the rising edge that samples it.
--
-- Also writes build/sim_out/trap_filter.csv (input, output) for plotting.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_trap_filter is
end tb_trap_filter;

architecture sim of tb_trap_filter is

    constant clk_period : time := 30 ns;

    signal clk      : std_logic := '0';
    signal done     : boolean := false;
    signal adc      : std_logic_vector(11 downto 0) := std_logic_vector(to_unsigned(100, 12));
    signal trap_out : signed(31 downto 0);

begin

    uut: entity work.trap_filter
        generic map (data_width => 12, K => 32, L => 56, DECAY_SHIFT => 5, ACC_WIDTH => 32)
        port map (clock => clk, reset => '0', adc_in => adc,
                  baseline => std_logic_vector(to_unsigned(100, 12)), trap_out => trap_out);

    clk <= not clk after clk_period / 2 when not done;

    check: process
        file vec : text open read_mode is "sim/vectors/trap_filter.txt";
        file csv : text open write_mode is "build/sim_out/trap_filter.csv";
        variable ln, lo : line;
        variable x, expected, row, errors, top : integer := 0;
    begin
        write(lo, string'("adc,trap"));
        writeline(csv, lo);
        while not endfile(vec) loop
            readline(vec, ln);
            read(ln, x);
            read(ln, expected);
            wait until falling_edge(clk);
            adc <= std_logic_vector(to_unsigned(x, 12));
            wait until rising_edge(clk);
            wait for 1 ns;
            if to_integer(trap_out) /= expected then
                errors := errors + 1;
                report "row " & integer'image(row) & ": got " & integer'image(to_integer(trap_out)) &
                       ", expected " & integer'image(expected) severity error;
            end if;
            if to_integer(trap_out) > top then
                top := to_integer(trap_out);
            end if;
            write(lo, x);
            write(lo, string'(","));
            write(lo, to_integer(trap_out));
            writeline(csv, lo);
            row := row + 1;
        end loop;
        assert errors = 0 report "tb_trap_filter FAILED" severity failure;
        report "tb_trap_filter PASSED: " & integer'image(row) &
               " samples match the model; highest flat top " & integer'image(top) &
               " (K * 2000 = 64000)";
        done <= true;
        wait;
    end process;

end sim;
