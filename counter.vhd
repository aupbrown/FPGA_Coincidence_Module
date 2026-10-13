library ieee;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity Counter is
    Port ( enable : in std_logic;
    clock : in std_logic;
    reset : in std_logic;
    count : out std_logic_vector(7 downto 0) );
end Counter;

architecture Behavior of Counter is

Signal count_int : unsigned(7 downto 0) := (others => '0');

begin

    process (clock)
    begin
        if clock'event and clock = '1' then
            if reset = '1' then
                count_int <= (others => '0');
            elsif enable = '1' then
                count_int <= count_int + 1;
            end if;
        end if; 
    end process;

    count <= std_logic_vector(count_int);

end Behavior;