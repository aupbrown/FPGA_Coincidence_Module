library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Trapezoidal shaping filter for exponentially decaying pulses (the 2018
-- workshop's trap_exp, rewritten without ISE cores).
--
-- For an input pulse that injects charge A and then decays by alpha per clock,
-- the output is a trapezoid: it ramps up over K clocks, holds a flat top of
-- height K * A for L - K clocks, and ramps back down to 0. The flat-top height
-- is the energy measurement. See docs/learning/02_trap_filter.md for the math.
--
-- Pipeline, one register per stage (alpha = 1 - 2**-M):
--   x[n]   = adc_in - baseline                    must be exactly 0 between pulses
--   d1[n]  = x[n]  - x[n-K]                       first difference, delay K
--   d2[n]  = d1[n] - d1[n-L]                      second difference, delay L
--   p[n]   = 2**M * d2[n] - (2**M - 1) * d2[n-1]  = 2**M * (d2[n] - alpha*d2[n-1])
--   acc1   = acc1 + p                             undoes the exponential decay
--   acc2   = acc2 + acc1                          makes the trapezoid
--   trap_out = acc2 / 2**M
--
-- Scaling p by 2**M keeps the pole-zero step exact in integers: no multiplier,
-- no rounding. The output appears 5 clocks after the input sample.
--
-- Accumulator overflow is harmless: two's-complement wrap-around cancels out as
-- long as the true output fits in ACC_WIDTH bits (K * 4095 * 2**M ~ 2**22 here).
-- Why subtract the baseline: the pole-zero step treats any lasting offset as
-- a pulse that never decays. An ADC baseline of B that appears at reset is a
-- step of B, which leaves a permanent offset of B * K * L / 2**M at the output
-- (5600 for B = 100). Subtracting the right baseline makes x exactly 0 between
-- pulses, so the output returns exactly to 0. An error of 1 count in baseline
-- moves every energy by K * L / 2**M = 56.
--
-- reset clears the delay lines as well as the accumulators, so after a reset
-- the filter starts from a clean, all-zero history.
entity trap_filter is
    Generic (data_width  : integer := 12;
             K           : integer := 32;   -- peaking time, clocks
             L           : integer := 56;   -- K + flat-top time, clocks. L > K.
             DECAY_SHIFT : integer := 5;    -- M: must match the pulse decay
             ACC_WIDTH   : integer := 32);
    Port (clock    : in  std_logic;
          reset    : in  std_logic;
          adc_in   : in  std_logic_vector(data_width-1 downto 0);
          baseline : in  std_logic_vector(data_width-1 downto 0);
          trap_out : out signed(ACC_WIDTH-1 downto 0));
end trap_filter;

architecture behavior of trap_filter is

-- Delay lines are plain shift registers. (The workshop used block-RAM
-- circular buffers, which matter for long delays; at K, L < 64 registers are
-- simpler.) x and d1 are one and two bits wider than the ADC, signed.
type x_delay_t  is array (1 to K) of signed(data_width downto 0);
type d1_delay_t is array (1 to L) of signed(data_width+1 downto 0);

signal x_delay  : x_delay_t  := (others => (others => '0'));
signal d1_delay : d1_delay_t := (others => (others => '0'));

signal x       : signed(data_width downto 0);                        -- 13 bits
signal d1      : signed(data_width+1 downto 0) := (others => '0');   -- 14 bits
signal d2      : signed(data_width+2 downto 0) := (others => '0');   -- 15 bits
signal d2_prev : signed(data_width+2 downto 0) := (others => '0');
signal p, acc1, acc2 : signed(ACC_WIDTH-1 downto 0) := (others => '0');

begin

    x <= signed(resize(unsigned(adc_in), data_width+1)) -
         signed(resize(unsigned(baseline), data_width+1));

    delays: process (clock)
    begin
        if rising_edge(clock) then
            if reset = '1' then
                x_delay  <= (others => (others => '0'));
                d1_delay <= (others => (others => '0'));
            else
                x_delay(1) <= x;
                for i in 2 to K loop
                    x_delay(i) <= x_delay(i-1);
                end loop;

                d1_delay(1) <= d1;
                for i in 2 to L loop
                    d1_delay(i) <= d1_delay(i-1);
                end loop;
            end if;
        end if;
    end process;

    filter: process (clock)
    begin
        if rising_edge(clock) then
            if reset = '1' then
                d1      <= (others => '0');
                d2      <= (others => '0');
                d2_prev <= (others => '0');
                p       <= (others => '0');
                acc1    <= (others => '0');
                acc2    <= (others => '0');
            else
                d1      <= resize(x, data_width+2) - resize(x_delay(K), data_width+2);
                d2      <= resize(d1, data_width+3) - resize(d1_delay(L), data_width+3);
                d2_prev <= d2;
                p       <= shift_left(resize(d2, ACC_WIDTH), DECAY_SHIFT)
                         - shift_left(resize(d2_prev, ACC_WIDTH), DECAY_SHIFT)
                         + resize(d2_prev, ACC_WIDTH);
                acc1    <= acc1 + p;
                acc2    <= acc2 + acc1;
            end if;
        end if;
    end process;

    trap_out <= shift_right(acc2, DECAY_SHIFT);

end behavior;
