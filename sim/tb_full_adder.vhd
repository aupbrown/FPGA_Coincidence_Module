library IEEE;
use IEEE.STD_LOGIC_1164.all;

entity tb_FullAdder is
end tb_FullAdder;

architecture tb of tb_FullAdder is
    component FullAdder is
        Port( a : in STD_LOGIC;
            b : in STD_LOGIC;
            c_in : in STD_LOGIC;
            s : out STD_LOGIC;
            c_out : out STD_LOGIC);
    end component;

    signal sig_a, sig_b, sig_cin : STD_LOGIC := '0';
    signal sig_s, sig_cout : STD_LOGIC;
begin
    
    uut: FullAdder port map (a => sig_a, b => sig_b, c_in => sig_cin, s => sig_s, c_out => sig_cout);

    stimulus: process

    begin

        sig_a <= '0';
        sig_b <= '0';
        sig_cin <= '0';
        wait for 20 ns;

        sig_a <= '0';
        sig_b <= '0';
        sig_cin <= '1';
        wait for 20 ns;

        sig_a <= '0';
        sig_b <= '1';
        sig_cin <= '1';
        wait for 20 ns;

        sig_a <= '1';
        sig_b <= '1';
        sig_cin <= '1';
        wait for 20 ns;

        sig_a <= '1';
        sig_b <= '1';
        sig_cin <= '0';
        wait for 20 ns;

        sig_a <= '1';
        sig_b <= '0';
        sig_cin <= '0';
        wait for 20 ns;

        sig_a <= '0';
        sig_b <= '1';
        sig_cin <= '0';
        wait for 20 ns;

        sig_a <= '1';
        sig_b <= '0';
        sig_cin <= '1';
        wait for 20 ns;

        wait;
    end process;
end tb;