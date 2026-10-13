library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Trapezoidal pulse generator: idles at BASE (baseline/pedestal),
-- ramps up, holds, ramps back down to the baseline, repeats.
-- adc_out = BASE + pulse_level, saturated at full scale.
entity pulse_gen is
    generic (
        -- do not know if these are meaningful values. Need to derive meaningful values properly in the future.
        BASE : integer := 100; -- signal baseline
        data_width : integer := 12;
        increment : integer := 100;
        decrement : integer := 50;
        idle_cycles : integer := 200;
        up_cycles : integer := 20;
        hold_cycles : integer := 10;
        down_cycles : integer := 40;
        START_DELAY : integer := 0
        );

    port (
        clock : in  std_logic;
        reset : in  std_logic;
        adc_out : out std_logic_vector(data_width-1 downto 0)
        );
end pulse_gen;

architecture behavior of pulse_gen is
    type state_t is (WAIT_START_S, IDLE_S, RAMP_UP_S, RAMP_DOWN_S, HOLD_S);
    signal state, next_state : state_t := WAIT_START_S;

    signal count_int : unsigned(11 downto 0) := (others => '0');
    signal count_en, count_reset : std_logic := '0';
    signal wait_start_done, idle_count_done, up_count_done, hold_count_done, down_count_done : std_logic := '0';

    -- pulse height above the baseline (registered)
    signal level : unsigned(data_width-1 downto 0) := (others => '0');
    -- one extra bit to detect overflow when adding BASE
    signal sum   : unsigned(data_width downto 0);
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
    comb: process (state, wait_start_done, idle_count_done, up_count_done, hold_count_done, down_count_done)
    begin
        next_state  <= state;
        count_en    <= '0';
        count_reset <= '0';

        case state is
            when WAIT_START_S =>
                count_en <= '1';
                if wait_start_done = '1' then
                    count_reset <= '1';
                    next_state <= IDLE_S;
                end if;
            when IDLE_S =>
                count_en <= '1';
                if idle_count_done = '1' then
                    count_reset <= '1';
                    next_state  <= RAMP_UP_S;
                else
                    next_state <= IDLE_S;
                end if;

            when RAMP_UP_S =>
                count_en <= '1';
                if up_count_done = '1' then
                    count_reset <= '1';
                    next_state  <= HOLD_S;
                else
                    next_state <= RAMP_UP_S;
                end if;

            when HOLD_S =>
                count_en <= '1';
                if hold_count_done = '1' then
                    count_reset <= '1';
                    next_state  <= RAMP_DOWN_S;
                else
                    next_state <= HOLD_S;
                end if;

            when RAMP_DOWN_S =>
                count_en <= '1';
                if down_count_done = '1' then
                    count_reset <= '1';
                    next_state  <= IDLE_S;
                else
                    next_state <= RAMP_DOWN_S;
                end if;

            when others =>
                next_state <= IDLE_S;
        end case;
    end process;

    -- Pulse amplitude register (relative to baseline)
    amp: process (clock)
    begin
        if rising_edge(clock) then
            if reset = '1' then
                level <= (others => '0');
            else
                case state is
                    when WAIT_START_S =>
                        level <= (others => '0');

                    when IDLE_S =>
                        level <= (others => '0');

                    when RAMP_UP_S =>
                    -- 2^(data_width bits) - 1 = max value data register can hold. If we are about to go over, we need to clamp instead of overflowing
                        if level < to_unsigned(2**data_width - 1 - increment, data_width) then
                            level <= level + to_unsigned(increment, data_width);
                        else
                            level <= (others => '1');
                        end if;

                    when RAMP_DOWN_S =>
                        if level > to_unsigned(decrement, data_width) then
                            level <= level - to_unsigned(decrement, data_width);
                        else
                            level <= (others => '0');
                        end if;

                    when others =>
                        null;
                end case;
            end if;
        end if;
    end process;

    counter: process (clock)
    begin
        if rising_edge(clock) then
            if count_reset = '1' then
                count_int <= (others => '0');
            elsif count_en = '1' then
                count_int <= count_int + 1;
            end if;
        end if;
    end process;

    wait_start_done <= '1' when count_int >= START_DELAY else '0';
    up_count_done <= '1' when count_int >= up_cycles - 1  else '0';
    hold_count_done <= '1' when count_int >= hold_cycles - 1 else '0';
    down_count_done <= '1' when count_int >= down_cycles - 1 else '0';
    idle_count_done <= '1' when count_int >= idle_cycles - 1 else '0';

    -- Output = baseline + pulse, saturated at full scale
    sum <= resize(level, data_width+1) + to_unsigned(BASE, data_width+1); -- extra bit is for detecting overflow
    adc_out <= (others => '1') when sum(data_width) = '1' else std_logic_vector(sum(data_width-1 downto 0));

end behavior;