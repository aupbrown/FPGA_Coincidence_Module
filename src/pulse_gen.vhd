library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Detector pulse generator: a stand-in for a charge-sensitive preamp + ADC.
--
-- Each pulse injects a charge AMP_i over RISE_CYCLES clocks, and the output
-- decays exponentially the whole time, like an RC circuit:
--
--     level <= level - ceil(level / 2**DECAY_SHIFT) + (INC_i while rising)
--
-- so the tail falls by a factor alpha = 1 - 2**-DECAY_SHIFT per clock
-- (tau ~ 2**DECAY_SHIFT clocks). Because charge leaks away during the rise too,
-- the peak is a little below AMP_i -- but the trap filter measures the injected
-- charge, so its flat top is K * AMP_i.
--
-- level is fixed point with FRAC fraction bits, so the decay is smooth even at
-- small levels. Rounding the decay UP (ceil) means the level always reaches
-- exactly 0 before the next pulse: every pulse of the same amplitude is then
-- bit-identical, which makes the expected histogram exact.
--
-- The generator cycles through AMP_0 .. AMP_(NUM_AMPS-1), one per pulse.
-- adc_out = BASE + integer part of level, saturated at full scale.
entity pulse_gen is
    generic (
        BASE        : integer := 100;  -- signal baseline
        data_width  : integer := 12;
        NUM_AMPS    : integer := 1;    -- 1 to 4
        AMP_0       : integer := 2000; -- charge of each pulse, in ADC counts
        AMP_1       : integer := 0;
        AMP_2       : integer := 0;
        AMP_3       : integer := 0;
        RISE_CYCLES : integer := 20;
        DECAY_SHIFT : integer := 5;    -- alpha = 1 - 2**-5 = 31/32
        PERIOD      : integer := 512;  -- clocks from one pulse start to the next
        START_DELAY : integer := 0
        );

    port (
        clock : in  std_logic;
        reset : in  std_logic;
        adc_out : out std_logic_vector(data_width-1 downto 0)
        );
end pulse_gen;

architecture behavior of pulse_gen is
    constant FRAC : integer := 8;                  -- fraction bits of level
    constant LW   : integer := data_width + 1 + FRAC;  -- one spare integer bit for pile-up

    -- Charge added per rising clock, in fixed point. Integer division here is
    -- done once, at elaboration; it costs no hardware.
    type inc_array is array (0 to 3) of integer;
    constant INC : inc_array := ((AMP_0 * 2**FRAC) / RISE_CYCLES,
                                 (AMP_1 * 2**FRAC) / RISE_CYCLES,
                                 (AMP_2 * 2**FRAC) / RISE_CYCLES,
                                 (AMP_3 * 2**FRAC) / RISE_CYCLES);

    type state_t is (WAIT_START_S, RISE_S, DECAY_S);
    signal state, next_state : state_t := WAIT_START_S;

    signal count_int : unsigned(15 downto 0) := (others => '0');
    signal count_en, count_reset : std_logic := '0';
    signal wait_start_done, rise_done, decay_done : std_logic := '0';

    signal amp_index : integer range 0 to 3 := 0;
    signal level     : unsigned(LW-1 downto 0) := (others => '0');
    signal decay     : unsigned(LW-1 downto 0);
    signal sum       : unsigned(data_width+1 downto 0);
begin

    -- State register
    sync: process (clock)
    begin
        if rising_edge(clock) then
            if reset = '1' then
                state <= WAIT_START_S;
            else
                state <= next_state;
            end if;
        end if;
    end process;

    -- Next-state / control logic (purely combinational)
    comb: process (state, wait_start_done, rise_done, decay_done)
    begin
        next_state  <= state;
        count_en    <= '1';
        count_reset <= '0';

        case state is
            when WAIT_START_S =>
                if wait_start_done = '1' then
                    count_reset <= '1';
                    next_state  <= RISE_S;
                end if;

            when RISE_S =>
                if rise_done = '1' then
                    count_reset <= '1';
                    next_state  <= DECAY_S;
                end if;

            when DECAY_S =>
                if decay_done = '1' then
                    count_reset <= '1';
                    next_state  <= RISE_S;
                end if;
        end case;
    end process;

    -- ceil(level / 2**DECAY_SHIFT): add 2**DECAY_SHIFT - 1 before shifting.
    decay <= shift_right(level + to_unsigned(2**DECAY_SHIFT - 1, LW), DECAY_SHIFT);

    -- Pulse level (relative to baseline) and which amplitude comes next
    amp: process (clock)
    begin
        if rising_edge(clock) then
            if reset = '1' then
                level     <= (others => '0');
                amp_index <= 0;
            else
                case state is
                    when WAIT_START_S =>
                        level <= (others => '0');

                    when RISE_S =>
                        level <= level - decay + to_unsigned(INC(amp_index), LW);
                        if rise_done = '1' then
                            if amp_index = NUM_AMPS - 1 then
                                amp_index <= 0;
                            else
                                amp_index <= amp_index + 1;
                            end if;
                        end if;

                    when DECAY_S =>
                        level <= level - decay;
                end case;
            end if;
        end if;
    end process;

    counter: process (clock)
    begin
        if rising_edge(clock) then
            if count_reset = '1' or reset = '1' then
                count_int <= (others => '0');
            elsif count_en = '1' then
                count_int <= count_int + 1;
            end if;
        end if;
    end process;

    wait_start_done <= '1' when count_int >= START_DELAY else '0';
    rise_done       <= '1' when count_int >= RISE_CYCLES - 1 else '0';
    decay_done      <= '1' when count_int >= PERIOD - RISE_CYCLES - 1 else '0';

    -- Output = baseline + integer part of the level, saturated at full scale
    sum <= resize(level(LW-1 downto FRAC), data_width+2) + to_unsigned(BASE, data_width+2);
    adc_out <= (others => '1') when sum > to_unsigned(2**data_width - 1, data_width+2)
               else std_logic_vector(sum(data_width-1 downto 0));

end behavior;
