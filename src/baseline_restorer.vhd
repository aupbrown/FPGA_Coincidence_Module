library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Baseline restorer (BLR) for one channel: a running average of the trap
-- filter's output, taken only while there is no pulse.
--
-- Between pulses the trap output should be 0: the trap subtracts the samples
-- before the edge, and the pole-zero correction removes the tails of earlier
-- pulses. Whatever it reads instead (an ADC offset left over after BASELINE, a
-- slow drift, a pole-zero mismatch) is an offset on every energy.
-- energy_capture subtracts blr_out from each energy it measures.
--
-- Gating: the channel is busy while trig_in = 1 or |trap_in| > LIMIT, and for
-- HOLD clocks after both end (the trap output takes K + L clocks to return to
-- 0). LIMIT catches what the trigger can't see: negative swings (a bipolar
-- induced signal, or in replay the drop where two recorded events are joined)
-- and anything else far from 0. It also bounds the correction: the BLR only
-- learns offsets within +-LIMIT (1024 = ~7 x the trap noise on Max's data,
-- ~32 bins at gain 5); a larger offset means BASELINE or TRAP_M is wrong.
--
-- Outside busy time, each clock's trap_in is added to a sum; after 2**NSHIFT
-- such samples, blr_out becomes their mean (sum >> NSHIFT, rounded towards
-- -inf) and a new sum starts. Busy time pauses the sum; it resumes after the
-- hold. So blr_out never changes during a pulse, and it is the mean of the
-- most recent complete block of quiet samples.
--
-- Not done on the ADC input: the preamp tail lasts thousands of samples, so a
-- gated average of the input follows the tail, and subtracting that before the
-- pole-zero correction makes pulses on a tail read low.
entity baseline_restorer is
    Generic (ACC_WIDTH : integer := 32;
             NSHIFT    : integer := 8;      -- average of 2**NSHIFT samples
             HOLD      : integer := 176;    -- quiet clocks needed after busy
             LIMIT     : integer := 1024);  -- |trap_in| above this counts as busy
    Port (clock   : in  std_logic;
          reset   : in  std_logic;
          trig_in : in  std_logic;
          trap_in : in  signed(ACC_WIDTH-1 downto 0);
          blr_out : out signed(ACC_WIDTH-1 downto 0));
end baseline_restorer;

architecture behavior of baseline_restorer is

signal quiet : integer range 0 to HOLD := 0;
signal n     : unsigned(NSHIFT-1 downto 0) := (others => '0');
signal sum   : signed(ACC_WIDTH+NSHIFT-1 downto 0) := (others => '0');
signal blr   : signed(ACC_WIDTH-1 downto 0) := (others => '0');
signal busy  : std_logic;

begin

    busy <= '1' when trig_in = '1' or trap_in > LIMIT or trap_in < -LIMIT else '0';

    process (clock)
        variable total : signed(ACC_WIDTH+NSHIFT-1 downto 0);
    begin
        if rising_edge(clock) then
            if reset = '1' then
                quiet <= 0;
                n     <= (others => '0');
                sum   <= (others => '0');
                blr   <= (others => '0');
            else
                if busy = '1' then
                    quiet <= 0;
                elsif quiet < HOLD then
                    quiet <= quiet + 1;
                end if;

                if busy = '0' and quiet = HOLD then
                    total := sum + resize(trap_in, ACC_WIDTH+NSHIFT);
                    if n = 2**NSHIFT - 1 then
                        blr <= resize(shift_right(total, NSHIFT), ACC_WIDTH);
                        sum <= (others => '0');
                        n   <= (others => '0');
                    else
                        sum <= total;
                        n   <= n + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    blr_out <= blr;

end behavior;
