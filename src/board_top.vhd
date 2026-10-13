library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

Entity board_top is
    -- Defaults are the hardware values, written as literals because Vivado
    -- rejects a generic default that references another generic. They assume
    -- clk = 33_333_333 Hz. STILL UNVERIFIED: confirm against the blink-test
    -- measurement before trusting the stretch and heartbeat timing. If clk
    -- turns out to be the PS FCLK_CLK0 rather than the Y18 oscillator, these
    -- defaults change.
    Generic(
        -- LED pulse stretcher. A coincidence lasts tens of clocks at 30 ns; the
        -- eye needs ~100 ms. Non-retriggerable, so this is non-paralyzable dead time.
        STRETCH_CYCLES  : integer := 8_333_250;  -- 250 ms = (33_333_333 / 1000) * 250
        EXT_WIDTH       : integer := 23;         -- 2**23 = 8_388_608 > 8_333_250
        -- Debouncer: ~1 ms of required stability.
        DEBOUNCE_CYCLES : integer := 33_333;
        DEBOUNCE_WIDTH  : integer := 16;         -- 2**16 = 65536 > 33_333
        -- Heartbeat: bit 24 toggles every 2**24 clocks, ~0.5 s at 33.333 MHz,
        -- so the LED blinks with a ~1 s period.
        HB_WIDTH        : integer := 25;
        HB_BIT          : integer := 24
        );
    Port(
        clk : in  std_logic;
        btn : in  std_logic;                     -- advances the pattern
        led : out std_logic_vector(3 downto 0)
        );
end board_top;

architecture behavior of board_top is

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
constant DW : integer := 12;  -- 12 bits of data coming out of ADC. Design decision
                              -- for the current prototype.

-- Trigger parameters, from the filter model.
-- The triangular filter's output ceiling is 25 * increment = 2500 for
-- increment = 100, set by the RAMP SLOPE, not the pulse height. A threshold at
-- or above 2500 can never fire. 1250 sits at half scale.
constant THRESH_VALUE      : integer := 1250;
constant TRIG_WIDTH_CYCLES : integer := 50;    -- coincidence window, in clocks

-- ---------------------------------------------------------------------------
-- The user-pattern menu
-- ---------------------------------------------------------------------------
-- Predicted behaviour with the generics below (trig_width = 50, threshold = 1250):
--   index 0  "0011"  fires, 40 clocks per 120   (ch0+ch1 window alone)
--   index 1  "1100"  fires, 40 clocks per 120   (ch2+ch3 window alone)
--   index 2  "1111"  fires, 10 clocks per 120   (the two windows overlapping)
--   index 3  "0001"  NEVER fires -- the control. If this one lights, something
--                    is wrong with the comparator or the pattern mux.
type pattern_array is array (0 to 3) of std_logic_vector(3 downto 0);
constant PATTERNS : pattern_array := ("0011", "1100", "1111", "0001");

-- ---------------------------------------------------------------------------
-- Signals
-- ---------------------------------------------------------------------------
Signal pulse_out0, pulse_out1, pulse_out2, pulse_out3 : std_logic_vector(DW-1 downto 0) := (others => '0');

-- Constants into detector_top's ports. Held as initialized signals rather than
-- inline conversion expressions, which VHDL-93 is strict about in a port map.
-- Vivado folds these to constants during synthesis, so they cost nothing.
signal thresh     : std_logic_vector(15 downto 0) := std_logic_vector(to_signed(THRESH_VALUE, 16));
signal trig_width_sig : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(TRIG_WIDTH_CYCLES, 16));

Signal sig_coinc_out : std_logic := '0';

-- Pattern menu
signal pat_advance  : std_logic := '0';
signal mode         : unsigned(1 downto 0) := (others => '0');
signal user_pattern : std_logic_vector(3 downto 0) := PATTERNS(0);

-- Heartbeat
signal hb_count : unsigned(HB_WIDTH-1 downto 0) := (others => '0');

-- Pulse stretcher
Signal count_reset, count_en, count_down_done : std_logic := '0';
Signal count_int : unsigned(EXT_WIDTH-1 downto 0) := (others => '0');
signal led_coinc : std_logic := '0';

type state_t is (IDLE_S, COUNT_DOWN_S);
signal state, next_state : state_t := IDLE_S;

-- ---------------------------------------------------------------------------
-- Components
-- ---------------------------------------------------------------------------
component detector_top is
    Port ( clock : in std_logic;
        reset : in std_logic;
        adc_0 : in std_logic_vector(11 downto 0);
        adc_1 : in std_logic_vector(11 downto 0);
        adc_2 : in std_logic_vector(11 downto 0);
        adc_3 : in std_logic_vector(11 downto 0);
        threshold_0 : in std_logic_vector(15 downto 0);
        threshold_1 : in std_logic_vector(15 downto 0);
        threshold_2 : in std_logic_vector(15 downto 0);
        threshold_3 : in std_logic_vector(15 downto 0);
        trig_width : in  std_logic_vector(15 downto 0);
        user_pattern : in std_logic_vector(3 downto 0);
        coinc_out : out std_logic );
end component;

component pulse_gen is
    generic (
        BASE : integer; -- signal baseline
        data_width : integer;
        increment : integer;
        decrement : integer;
        idle_cycles : integer;
        up_cycles : integer;
        hold_cycles : integer;
        down_cycles : integer;
        START_DELAY : integer
        );

    port (
        clock : in  std_logic;
        reset : in  std_logic;
        adc_out : out std_logic_vector(data_width-1 downto 0)
        );
end component;

component debouncer is
    Generic (
        stable_cycles : integer;
        counter_width : integer
        );
    Port (
        clock     : in  std_logic;
        button_in : in  std_logic;
        level_out : out std_logic;
        rise_out  : out std_logic
        );
end component;

begin

    detector: detector_top
        port map(
                clock        => clk,
                reset        => '0',
                adc_0        => pulse_out0,
                adc_1        => pulse_out1,
                adc_2        => pulse_out2,
                adc_3        => pulse_out3,
                threshold_0  => thresh,
                threshold_1  => thresh,
                threshold_2  => thresh,
                threshold_3  => thresh,
                trig_width   => trig_width_sig,
                user_pattern => user_pattern,
                coinc_out    => sig_coinc_out
                );

    -- Channels 0 and 1 are a pair: identical shape, no start delay.
    -- Their trigger window opens at p = 55 within each 120-clock period.
    pulse_gen0: pulse_gen
        generic map ( BASE => 100, data_width => DW,
                      increment => 100, decrement => 50,
                      idle_cycles => 50, up_cycles => 20,
                      hold_cycles => 10, down_cycles => 40,
                      START_DELAY => 0 )
        port map ( clock => clk, reset => '0', adc_out => pulse_out0);

    pulse_gen1: pulse_gen
        generic map ( BASE => 100, data_width => DW,
                      increment => 100, decrement => 50,
                      idle_cycles => 50, up_cycles => 20,
                      hold_cycles => 10, down_cycles => 40,
                      START_DELAY => 0 )
        port map ( clock => clk, reset => '0', adc_out => pulse_out1);

    -- Channels 2 and 3 are the second pair, offset by 40 clocks.
    -- Their window opens at p = 95. Since 40 < trig_width = 50, the two pairs
    -- overlap for 10 clocks per period -- which is what makes "1111" reachable.
    pulse_gen2: pulse_gen
        generic map ( BASE => 100, data_width => DW,
                      increment => 100, decrement => 50,
                      idle_cycles => 50, up_cycles => 20,
                      hold_cycles => 10, down_cycles => 40,
                      START_DELAY => 40 )
        port map ( clock => clk, reset => '0', adc_out => pulse_out2);

    pulse_gen3: pulse_gen
        generic map ( BASE => 100, data_width => DW,
                      increment => 100, decrement => 50,
                      idle_cycles => 50, up_cycles => 20,
                      hold_cycles => 10, down_cycles => 40,
                      START_DELAY => 40 )
        port map ( clock => clk, reset => '0', adc_out => pulse_out3);

    -- Pattern-select button. The debouncer contains its own two-flop
    -- synchronizer, so the raw pin goes straight in.
    pattern_button: debouncer
        generic map ( stable_cycles => DEBOUNCE_CYCLES,
                      counter_width => DEBOUNCE_WIDTH )
        port map ( clock     => clk,
                   button_in => btn,
                   level_out => open,
                   rise_out  => pat_advance );

    -- One press advances the menu. unsigned wraps 3 -> 0 on its own.
    pattern_menu: process (clk)
        begin
            if rising_edge(clk) then
                if pat_advance = '1' then
                    mode <= mode + 1;
                end if;
            end if;
        end process;

    user_pattern <= PATTERNS(to_integer(mode));

    -- Heartbeat. Proves the clock arrives, the bitstream loaded, and the pin
    -- mapping works -- independently of everything else in the design.
    heartbeat: process (clk)
        begin
            if rising_edge(clk) then
                hb_count <= hb_count + 1;
            end if;
        end process;

    -- -----------------------------------------------------------------------
    -- Pulse extender. Two-state FSM.
    -- IDLE_S:       no stretch in progress, counter held clear, waiting.
    -- COUNT_DOWN_S: LED on, counter running. Further coincidences arriving
    --               during the count are ignored (non-retriggerable).
    -- -----------------------------------------------------------------------
    sync: process (clk)
        begin
            if rising_edge(clk) then
                state <= next_state;
            end if;
        end process;

    -- Every signal read in this process must appear in the sensitivity list.
    -- Synthesis infers the logic regardless, but simulation only re-evaluates on
    -- a listed signal -- omitting one gives a design that simulates wrong and
    -- synthesizes right, which is the worst possible failure mode.
    comb: process (state, sig_coinc_out, count_down_done)
        begin
            next_state  <= state;
            count_en    <= '0';
            count_reset <= '0';
            led_coinc   <= '0';

            case state is
                when IDLE_S =>
                    count_reset <= '1';
                    if sig_coinc_out = '1' then
                        next_state <= COUNT_DOWN_S;
                    else
                        next_state <= IDLE_S;
                    end if;

                when COUNT_DOWN_S =>
                    count_en  <= '1';
                    led_coinc <= '1';
                    if count_down_done = '1' then
                        next_state <= IDLE_S;
                    else
                        next_state <= COUNT_DOWN_S;
                    end if;
            end case;
        end process;

    counter: process (clk)
        begin
            if rising_edge(clk) then
                if count_reset = '1' then
                    count_int <= (others => '0');
                elsif count_en = '1' then
                    count_int <= count_int + 1;
                end if;
            end if;
        end process;
        
    count_down_done <= '1' when count_int >= to_unsigned(STRETCH_CYCLES - 1, EXT_WIDTH) else '0';

    -- -----------------------------------------------------------------------
    -- LED assignments. Every bit must be driven or synthesis strips the logic
    -- feeding it.
    -- -----------------------------------------------------------------------
    led(0)          <= led_coinc;                  -- stretched coincidence
    led(2 downto 1) <= std_logic_vector(mode);     -- which pattern is selected
    led(3)          <= hb_count(HB_BIT);           -- heartbeat, ~1 s period

end behavior;