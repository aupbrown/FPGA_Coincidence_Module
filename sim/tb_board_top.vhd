-- tb_board_top.vhd
--
-- Exercises the whole board-level design: four pulse generators, the trigger
-- filters and coincidence comparator inside detector_top, the debouncer, the
-- pattern menu, and the LED stretcher.
--
-- The time constants are scaled down via generics so the interesting behaviour
-- happens in tens of microseconds instead of seconds. In particular
-- STRETCH_CYCLES is deliberately set SHORTER than the 120-clock pulse period,
-- so led(0) produces distinct pulses instead of sitting solid the way it will
-- on hardware.
--
-- Run from the repository root:
--       nvc -a src/debouncer.vhd src/pulse_gen.vhd src/trigger.vhd src/coincidence.vhd \
--              src/detector_top.vhd src/board_top.vhd sim/tb_board_top.vhd
--       nvc -e tb_board_top
--       nvc -r tb_board_top --wave=tb_board_top.fst
--       surfer tb_board_top.fst

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_board_top is
end tb_board_top;

architecture sim of tb_board_top is

    constant CLK_PERIOD : time := 30 ns;      -- 33.333 MHz

    -- Scaled-down timing for simulation
    constant TB_STRETCH_CYCLES  : integer := 30;   -- < 120 so pulses stay distinct
    constant TB_EXT_WIDTH       : integer := 6;    -- 2**6 = 64 > 30
    constant TB_DEBOUNCE_CYCLES : integer := 10;
    constant TB_DEBOUNCE_WIDTH  : integer := 5;    -- 2**5 = 32 > 10
    constant TB_HB_WIDTH        : integer := 6;
    constant TB_HB_BIT          : integer := 5;    -- toggles every 32 clocks

    constant PULSE_PERIOD     : integer := 120;    -- idle 50 + up 20 + hold 10 + down 40
    constant PERIODS_PER_MODE : integer := 5;      -- dwell per mode
    constant DWELL            : integer := PULSE_PERIOD * PERIODS_PER_MODE;

    signal clk : std_logic := '0';
    signal btn : std_logic := '0';
    signal led : std_logic_vector(3 downto 0);

    signal sim_done : boolean := false;

    -- Running total of clocks with led(0) high. Driven ONLY by the scorer
    -- process; the stimulus reads it and takes differences. Two processes
    -- driving one integer signal would be a multiple-driver error, since
    -- integer is not a resolved type.
    signal led0_high_total : integer := 0;

    component board_top is
        Generic (
            STRETCH_CYCLES  : integer;
            EXT_WIDTH       : integer;
            DEBOUNCE_CYCLES : integer;
            DEBOUNCE_WIDTH  : integer;
            HB_WIDTH        : integer;
            HB_BIT          : integer
            );
        Port(
            clk : in  std_logic;
            btn : in  std_logic;
            led : out std_logic_vector(3 downto 0)
            );
    end component;

begin

    -- -----------------------------------------------------------------------
    -- Clock
    -- -----------------------------------------------------------------------
    clock_driver : process
    begin
        while not sim_done loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    -- -----------------------------------------------------------------------
    -- Unit under test
    -- -----------------------------------------------------------------------
    uut : board_top
        generic map (
            STRETCH_CYCLES  => TB_STRETCH_CYCLES,
            EXT_WIDTH       => TB_EXT_WIDTH,
            DEBOUNCE_CYCLES => TB_DEBOUNCE_CYCLES,
            DEBOUNCE_WIDTH  => TB_DEBOUNCE_WIDTH,
            HB_WIDTH        => TB_HB_WIDTH,
            HB_BIT          => TB_HB_BIT
            )
        port map (
            clk => clk,
            btn => btn,
            led => led
            );

    -- -----------------------------------------------------------------------
    -- Score keeper. Single driver, always accumulating.
    -- -----------------------------------------------------------------------
    scorer : process (clk)
    begin
        if rising_edge(clk) then
            if led(0) = '1' then
                led0_high_total <= led0_high_total + 1;
            end if;
        end if;
    end process;

    -- -----------------------------------------------------------------------
    -- Stimulus
    -- -----------------------------------------------------------------------
    stimulus : process

        procedure wait_clocks (n : integer) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        -- A clean press: hold well past the debounce window, release, and leave
        -- enough slack that any stretch still running from the previous mode
        -- has expired before the next observation starts.
        procedure press_clean is
        begin
            btn <= '1';
            wait_clocks(TB_DEBOUNCE_CYCLES + 40);
            btn <= '0';
            wait_clocks(TB_DEBOUNCE_CYCLES + 40);
        end procedure;

        -- A bouncing press: contacts chatter before settling. The mode must
        -- advance EXACTLY ONCE. This is the whole reason the debouncer exists.
        procedure press_bouncy is
        begin
            for i in 1 to 6 loop
                btn <= '1';
                wait_clocks(2);
                btn <= '0';
                wait_clocks(1);
            end loop;
            btn <= '1';                      -- contacts settle closed
            wait_clocks(TB_DEBOUNCE_CYCLES + 40);
            btn <= '0';
            wait_clocks(TB_DEBOUNCE_CYCLES + 40);
        end procedure;

        -- Dwell in the current mode and score how many clocks led(0) was high.
        procedure observe (name : string; expect_fires : boolean) is
            variable before_v, after_v, seen, idx : integer;
        begin
            wait until rising_edge(clk);
            before_v := led0_high_total;
            idx      := to_integer(unsigned(led(2 downto 1)));

            wait_clocks(DWELL);

            wait until rising_edge(clk);
            after_v := led0_high_total;
            seen    := after_v - before_v;

            report "mode " & name
                 & ":  index on led(2:1) = " & integer'image(idx)
                 & ",  led(0) high for " & integer'image(seen)
                 & " of " & integer'image(DWELL) & " clocks"
                 severity note;

            if expect_fires then
                assert seen > 0
                    report "FAIL: mode " & name
                         & " should fire, but led(0) never went high"
                    severity error;
            else
                assert seen = 0
                    report "FAIL: mode " & name
                         & " is the control pattern and must NEVER fire, but "
                         & "led(0) was high for " & integer'image(seen) & " clocks"
                    severity error;
            end if;
        end procedure;

    begin
        report "=== tb_board_top start ===" severity note;

        -- Let the pipeline fill: the filter delay line is 10 deep, and the
        -- generators need a full period to reach steady state.
        wait_clocks(PULSE_PERIOD * 3);

        -- Mode 0 at power-up: pattern "0011", channels 0 and 1.
        observe("0 (0011)", true);

        press_clean;
        observe("1 (1100)", true);

        press_clean;
        observe("2 (1111)", true);

        -- Mode 3 is the control. "0001" cannot match any trig_bus value this
        -- design can produce, so led(0) must stay low for the whole dwell.
        press_clean;
        observe("3 (0001) CONTROL", false);

        -- Wrap back to mode 0 with a BOUNCING press, so the debouncer is
        -- actually under test. If it advances more than once we land somewhere
        -- other than mode 0, and the reported index will say so.
        press_bouncy;
        observe("0 again, after a bouncy press", true);

        report "=== tb_board_top done ===" severity note;
        sim_done <= true;
        wait;
    end process;

end sim;