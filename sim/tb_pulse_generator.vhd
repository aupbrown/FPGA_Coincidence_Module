-- tb_pulse_generator.vhd
--
-- Self-checking: compares two pulse_gen instances, clock by clock, against
-- the Python model's prediction in sim/vectors/pulse_gen.txt (written by
-- `python3 -m model.expected --vectors`).
--   gen_a: pulse set 2, channel 0 -- four amplitudes, 4-clock rise
--   gen_b: pulse set 1, channel 2 -- one amplitude, 20-clock rise, start delay 40
-- Row i of the file holds both outputs after rising edge i + 1.
--
-- Run from the repository root (scripts/run_sims.sh does all of this).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_pulse_gen is
end tb_pulse_gen;

architecture sim of tb_pulse_gen is

    constant clk_period : time := 30 ns;      -- 33.333 MHz, matches the board

    signal clk   : std_logic := '0';
    signal done  : boolean := false;
    signal adc_a, adc_b : std_logic_vector(11 downto 0);

begin

    gen_a: entity work.pulse_gen
        generic map (BASE => 100, data_width => 12, NUM_AMPS => 4,
                     AMP_0 => 500, AMP_1 => 1000, AMP_2 => 1500, AMP_3 => 2000,
                     RISE_CYCLES => 4, DECAY_SHIFT => 5, PERIOD => 512, START_DELAY => 0)
        port map (clock => clk, reset => '0', adc_out => adc_a);

    gen_b: entity work.pulse_gen
        generic map (BASE => 100, data_width => 12, NUM_AMPS => 1,
                     AMP_0 => 2000, AMP_1 => 0, AMP_2 => 0, AMP_3 => 0,
                     RISE_CYCLES => 20, DECAY_SHIFT => 5, PERIOD => 512, START_DELAY => 40)
        port map (clock => clk, reset => '0', adc_out => adc_b);

    clk <= not clk after clk_period / 2 when not done;

    check: process
        file vec : text open read_mode is "sim/vectors/pulse_gen.txt";
        variable ln : line;
        variable exp_a, exp_b, row, errors : integer := 0;
    begin
        while not endfile(vec) loop
            readline(vec, ln);
            read(ln, exp_a);
            read(ln, exp_b);
            wait until rising_edge(clk);
            wait for 1 ns;
            if to_integer(unsigned(adc_a)) /= exp_a or to_integer(unsigned(adc_b)) /= exp_b then
                errors := errors + 1;
                report "row " & integer'image(row) & ": got " &
                       integer'image(to_integer(unsigned(adc_a))) & " " &
                       integer'image(to_integer(unsigned(adc_b))) & ", expected " &
                       integer'image(exp_a) & " " & integer'image(exp_b) severity error;
            end if;
            row := row + 1;
        end loop;
        assert errors = 0 report "tb_pulse_gen FAILED" severity failure;
        report "tb_pulse_gen PASSED: " & integer'image(row) & " samples match the model";
        done <= true;
        wait;
    end process;

end sim;
