library IEEE;
use IEEE.STD_LOGIC_1164.all;

entity FullAdder is
    Port( a : in STD_LOGIC;
        b : in STD_LOGIC;
        c_in : in STD_LOGIC;
        s : out STD_LOGIC;
        c_out : out STD_LOGIC);
end FullAdder;

architecture Equations of FullAdder is

begin

s <= (a xor b) xor c_in;
c_out <= (a and b) or ((a xor b) and c_in);

end Equations;