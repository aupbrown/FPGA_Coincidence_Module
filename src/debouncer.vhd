-- Synchronizes an asynchronous mechanical button to `clock`, rejects contact
-- bounce, and emits a one-cycle pulse on each press.
--
-- A mechanical switch's contacts chatter for several milliseconds when pressed,
-- so a raw button reads as a burst of presses. This accepts a new level only
-- after it has held steady for `stable_cycles` consecutive clocks.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity debouncer is
    Generic (
        stable_cycles : integer := 33333;  -- ~1 ms at 33.333 MHz
        counter_width : integer := 16      -- Literal, NOT ceil(log2(stable_cycles)):
                                           -- Vivado rejects a generic default that
                                           -- references another generic. Must satisfy
                                           -- 2**counter_width > stable_cycles.
                                           -- 2**16 = 65536 > 33333. OK.
    );
    Port (
        clock     : in  std_logic;
        button_in : in  std_logic;   -- raw pin, asynchronous
        level_out : out std_logic;   -- debounced level
        rise_out  : out std_logic    -- one clock high on each press
    );
end debouncer;

architecture behavior of debouncer is

    signal sync_0, sync_1 : std_logic := '0';
    signal level          : std_logic := '0';
    signal level_d        : std_logic := '0';
    signal count          : unsigned(counter_width-1 downto 0) := (others => '0');

begin

    -- Two-flop synchronizer. The button is asynchronous to clock, so sampling it
    -- directly risks metastability propagating into the debounce logic.
    synchronizer : process (clock)
    begin
        if rising_edge(clock) then
            sync_0 <= button_in;
            sync_1 <= sync_0;
        end if;
    end process;

    -- Accept a new level only once it has disagreed with the current level for
    -- stable_cycles consecutive clocks. Any flicker back resets the count.
    debounce : process (clock)
    begin
        if rising_edge(clock) then
            if sync_1 = level then
                count <= (others => '0');
            elsif count >= to_unsigned(stable_cycles - 1, counter_width) then
                level <= sync_1;
                count <= (others => '0');
            else
                count <= count + 1;
            end if;
        end if;
    end process;

    -- Delay the debounced level by one clock so the edge can be detected.
    edge_detect : process (clock)
    begin
        if rising_edge(clock) then
            level_d <= level;
        end if;
    end process;

    level_out <= level;
    rise_out  <= level and not level_d;   -- high for exactly one clock per press

end behavior;