library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_trigger is
end tb_trigger;

architecture sim of tb_trigger is

component trigger is
    Generic (data_width : integer := 12;
        filter_width : integer := 10;
        acc_width : integer := data_width + integer(ceil(log2(real(filter_width)))));
        
    Port (adc_in : in std_logic_vector(data_width-1 downto 0);
        threshold : in std_logic_vector(acc_width-1 downto 0);
        reset : in std_logic;
        clock : in std_logic;
        trig_width : in std_logic_vector(15 downto 0);
        trig_out : out std_logic);
end component;

constant DW : integer := 12;
constant FW : integer := 10;
constant AW : integer := DW + integer(ceil(log2(real(FW))));
signal sig_adc       : std_logic_vector(DW-1 downto 0) := (others => '0');
signal sig_threshold : std_logic_vector(AW-1 downto 0) := (others => '0');
signal sig_tw        : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(20, 16));

Signal sig_clock, sig_reset: std_logic := '0';
Signal sig_trig : std_logic;

Constant clk_period : time := 10 ns;
constant BASELINE : integer := 100;
constant PEAK     : integer := 2000;

begin
uut: trigger
    generic map ( data_width   => DW,
        filter_width => FW,
        acc_width    => AW )
    port map ( adc_in => sig_adc,
        threshold => sig_threshold,
        reset => sig_reset,
        clock => sig_clock,
        trig_width => sig_tw,
        trig_out => sig_trig);

clk_gen: process
    begin
        sig_clock <= '0';
        wait for clk_period/2;
        sig_clock <= '1';
        wait for clk_period/2;
    end process;

stimuli: process
    begin
        wait for clk_period/4;

        sig_threshold <= std_logic_vector(to_signed(3000, AW));
        sig_adc       <= std_logic_vector(to_unsigned(BASELINE, DW));
        sig_reset     <= '1';

        wait for clk_period*5;
        sig_reset     <= '0';

        for p in 1 to 2 loop                -- two pulses

            for i in 1 to 20 loop           -- quiet baseline
                sig_adc <= std_logic_vector(to_unsigned(BASELINE, DW));
                wait for clk_period;
            end loop;

            for i in 1 to 5 loop            -- rising edge
                sig_adc <= std_logic_vector(
                    to_unsigned(BASELINE + i*(PEAK-BASELINE)/5, DW));
                wait for clk_period;
            end loop;

            for i in 0 to 29 loop           -- decay back to baseline
                sig_adc <= std_logic_vector(
                    to_unsigned(PEAK - i*(PEAK-BASELINE)/30, DW));
                wait for clk_period;
            end loop;

        end loop;

        sig_adc <= std_logic_vector(to_unsigned(BASELINE, DW));
        wait for clk_period*20;
        wait;
    end process;


end sim;