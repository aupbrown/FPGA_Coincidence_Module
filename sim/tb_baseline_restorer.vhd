-- tb_baseline_restorer.vhd
--
-- Self-checking: drives baseline_restorer with the model's sequence from
-- sim/vectors/baseline_restorer.txt (written by `python3 -m model.expected
-- --vectors`): a trap output with a stepping and drifting offset, noise, and
-- pulses with their trigger, some landing mid-way through an averaging block,
-- and a negative swing with no trigger (rejected by LIMIT).
-- Row i = trig_in and trap_in at rising edge i, then the expected blr_out
-- after that edge. Every clock is compared.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_baseline_restorer is
end tb_baseline_restorer;

architecture sim of tb_baseline_restorer is

    constant clk_period : time := 30 ns;

    signal clk     : std_logic := '0';
    signal done    : boolean := false;
    signal trig    : std_logic := '0';
    signal trap    : signed(31 downto 0) := (others => '0');
    signal blr_out : signed(31 downto 0);

begin

    uut: entity work.baseline_restorer
        generic map (ACC_WIDTH => 32, NSHIFT => 8, HOLD => 176, LIMIT => 1024)
        port map (clock => clk, reset => '0', trig_in => trig, trap_in => trap, blr_out => blr_out);

    clk <= not clk after clk_period / 2 when not done;

    check: process
        file vec : text open read_mode is "sim/vectors/baseline_restorer.txt";
        variable ln            : line;
        variable t, x, want, i : integer := 0;
        variable errors        : integer := 0;
    begin
        while not endfile(vec) loop
            readline(vec, ln);
            read(ln, t);
            read(ln, x);
            read(ln, want);
            if t = 1 then trig <= '1'; else trig <= '0'; end if;
            trap <= to_signed(x, 32);
            wait until rising_edge(clk);
            wait for 1 ns;
            if to_integer(blr_out) /= want then
                if errors < 10 then
                    report "row " & integer'image(i) & ": blr_out " & integer'image(to_integer(blr_out))
                         & ", model " & integer'image(want) severity error;
                end if;
                errors := errors + 1;
            end if;
            i := i + 1;
        end loop;
        assert errors = 0 report integer'image(errors) & " mismatches" severity failure;
        report "tb_baseline_restorer: " & integer'image(i) & " clocks match the model";
        done <= true;
        wait;
    end process;

end sim;
