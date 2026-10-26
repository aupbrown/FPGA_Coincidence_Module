-- tb_histogram.vhd
--
-- Self-checking unit test of histogram.vhd:
--   1. Events with known energies land in bin = energy >> conv_gain.
--   2. Several events in one bin add up (the read-modify-write works).
--   3. An over-range energy is counted, not binned.
--   4. Events while enable = '0' are ignored.
--   5. clear zeroes every bin and both counters.
-- Bins are read back through port B, as the PS does.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_histogram is
end tb_histogram;

architecture sim of tb_histogram is

    constant clk_period : time := 30 ns;

    signal clk          : std_logic := '0';
    signal done         : boolean := false;
    signal enable       : std_logic := '1';
    signal clear        : std_logic := '0';
    signal conv_gain    : std_logic_vector(3 downto 0) := "0101";   -- 5
    signal energy       : unsigned(31 downto 0) := (others => '0');
    signal energy_valid : std_logic := '0';
    signal rd_addr      : std_logic_vector(11 downto 0) := (others => '0');
    signal rd_data      : std_logic_vector(31 downto 0);
    signal clearing     : std_logic;
    signal event_count, over_count : unsigned(31 downto 0);

begin

    uut: entity work.histogram
        generic map (ADDR_WIDTH => 12, COUNT_WIDTH => 32, ENERGY_WIDTH => 32)
        port map (clock => clk, reset => '0', enable => enable, clear => clear,
                  conv_gain => conv_gain, energy => energy, energy_valid => energy_valid,
                  rd_addr => rd_addr, rd_data => rd_data, clearing => clearing,
                  event_count => event_count, over_count => over_count);

    clk <= not clk after clk_period / 2 when not done;

    stim: process

        procedure send(e : integer) is
        begin
            wait until falling_edge(clk);
            energy       <= to_unsigned(e, 32);
            energy_valid <= '1';
            wait until falling_edge(clk);
            energy_valid <= '0';
            for i in 1 to 4 loop                 -- let the 3-clock update finish
                wait until falling_edge(clk);
            end loop;
        end procedure;

        procedure expect_bin(b, n : integer) is
        begin
            wait until falling_edge(clk);
            rd_addr <= std_logic_vector(to_unsigned(b, 12));
            wait until falling_edge(clk);        -- one clock of read latency
            assert to_integer(unsigned(rd_data)) = n
                report "bin " & integer'image(b) & " = " & integer'image(to_integer(unsigned(rd_data))) &
                       ", expected " & integer'image(n) severity failure;
        end procedure;

    begin
        -- conv_gain 5: energies 64000 and 64031 both fall in bin 2000
        send(64000); send(64031); send(64000);
        send(32);                                -- bin 1
        send(31);                                -- bin 0
        send(200000);                            -- 6250 > 4095: over range
        enable <= '0';
        send(64000);                             -- ignored
        enable <= '1';

        expect_bin(2000, 3);
        expect_bin(1, 1);
        expect_bin(0, 1);
        expect_bin(1999, 0);
        expect_bin(2001, 0);
        assert event_count = 5 report "event_count " & integer'image(to_integer(event_count)) severity failure;
        assert over_count = 1 report "over_count " & integer'image(to_integer(over_count)) severity failure;

        -- conv_gain 0: energy = bin
        conv_gain <= "0000";
        send(4095);
        expect_bin(4095, 1);

        -- clear
        wait until falling_edge(clk);
        clear <= '1';
        wait until falling_edge(clk);
        clear <= '0';
        wait until falling_edge(clk);
        assert clearing = '1' report "clear did not start" severity failure;
        wait until clearing = '0';
        expect_bin(2000, 0);
        expect_bin(4095, 0);
        assert event_count = 0 and over_count = 0 report "counters not cleared" severity failure;

        report "tb_histogram PASSED";
        done <= true;
        wait;
    end process;

end sim;
