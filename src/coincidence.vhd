library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity coincidence is
    Generic (n_channels : integer := 4);

    Port (clock : in std_logic;
        trig_ins : in std_logic_vector(n_channels-1 downto 0);
        user_pattern : in std_logic_vector(n_channels-1 downto 0);
        reset : in std_logic;
        coinc_out : out std_logic);

end coincidence;

architecture behavior of coincidence is

begin
    process (clock)
    begin
        if rising_edge(clock) then
            if reset = '1' then
                coinc_out <= '0';
            elsif trig_ins = user_pattern then
                coinc_out <= '1';
            else
                coinc_out <= '0';
            end if;
        end if;
    end process;

end behavior;