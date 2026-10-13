library IEEE;                          -- 1. what vocabulary you're using
use IEEE.STD_LOGIC_1164.ALL;

entity and_gate is                     -- 2. the interface: pins on the chip
    Port ( in_1     : in  STD_LOGIC;
           in_2     : in  STD_LOGIC;
           gate_out : out STD_LOGIC);
end and_gate;

architecture Behavioral of and_gate is -- 3. what's inside
begin
    gate_out <= in_1 and in_2;
end Behavioral;
