library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity tb_and_gate is
end tb_and_gate;                       -- testbench has no ports

architecture sim of tb_and_gate is
    component and_gate
        port ( in_1     : in  STD_LOGIC;
               in_2     : in  STD_LOGIC;
               gate_out : out STD_LOGIC);
    end component;

    signal a, b, y : std_logic := '0';
begin
    uut: and_gate port map (in_1 => a, in_2 => b, gate_out => y);

    stimulus: process
    begin
        a <= '0'; b <= '0'; wait for 10 ns;
        a <= '0'; b <= '1'; wait for 10 ns;
        a <= '1'; b <= '0'; wait for 10 ns;
        a <= '1'; b <= '1'; wait for 10 ns;
        wait;
    end process;
end sim;
