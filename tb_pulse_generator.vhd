library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_pulse_gen is
end tb_pulse_gen;

architecture sim of tb_pulse_gen is

    component pulse_gen is
        generic (
            BASE        : integer := 100;
            data_width  : integer := 12;
            increment   : integer := 100;
            decrement   : integer := 50;
            idle_cycles : integer := 50;
            hold_cycles : integer := 10;
            up_cycles   : integer := 20;
            down_cycles : integer := 40;
            START_DELAY : integer := 0
        );
        port (
            clock   : in  std_logic;
            reset   : in  std_logic;
            adc_out : out std_logic_vector(data_width-1 downto 0)
        );
    end component;

    constant DW         : integer := 12;
    constant clk_period : time    := 30 ns;      -- 33.333 MHz, matches the board

    signal sig_clock : std_logic := '0';
    signal sig_reset : std_logic := '0';
    signal adc_a     : std_logic_vector(DW-1 downto 0);
    signal adc_b     : std_logic_vector(DW-1 downto 0);

begin

    -- Channel A: fires immediately
    uut_a: pulse_gen
        generic map ( BASE        => 100,
                      data_width  => DW,
                      increment   => 100,
                      decrement   => 50,
                      idle_cycles => 50,
                      up_cycles   => 20,
                      hold_cycles => 10,
                      down_cycles => 40,
                      START_DELAY => 0 )
        port map ( clock => sig_clock, reset => sig_reset, adc_out => adc_a );

    -- Channel B: identical shape, delayed 60 clocks
    uut_b: pulse_gen
        generic map ( BASE        => 100,
                      data_width  => DW,
                      increment   => 100,
                      decrement   => 50,
                      idle_cycles => 50,
                      up_cycles   => 20,
                      hold_cycles => 10,
                      down_cycles => 40,
                      START_DELAY => 60 )
        port map ( clock => sig_clock, reset => sig_reset, adc_out => adc_b );

    clk_gen: process
    begin
        sig_clock <= '0'; wait for clk_period/2;
        sig_clock <= '1'; wait for clk_period/2;
    end process;

    stimulus: process
    begin
        sig_reset <= '1';
        wait for clk_period*5;
        sig_reset <= '0';
        wait;                          -- free-run
    end process;

end sim;