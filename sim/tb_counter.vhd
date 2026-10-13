library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_counter is
end tb_counter;

architecture sim of tb_counter is
    component counter
        Port (enable : in std_logic; 
            clock : in std_logic;
            reset : in std_logic;
            count : out std_logic_vector(7 downto 0) );
    end component;

    Signal sig_enable, sig_clock, sig_reset : std_logic := '0';
    Signal sig_count : std_logic_vector(7 downto 0);

    Constant clk_period : time := 10 ns;

begin
    uut: counter port map (enable => sig_enable, clock => sig_clock, reset => sig_reset, count => sig_count);

    stimuli: process
    begin
        sig_reset <= '1';
        wait for clk_period * 5;

        sig_reset <= '0';
        sig_enable <= '1';
        wait for clk_period * 10;

        sig_enable <= '0';
        wait for clk_period * 5;

        sig_enable <= '1';
        wait for clk_period * 5;

        sig_reset <= '1';
        wait;
    end process;

    clk_gen: process
    begin
        sig_clock <= '0';
        wait for clk_period/2;
        sig_clock <= '1';
        wait for clk_period/2;
    end process;

end sim;