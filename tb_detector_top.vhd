library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_detector_top is
end tb_detector_top;

architecture sim of tb_detector_top is

    component detector_top is
        Port ( clock        : in  std_logic;
               reset        : in  std_logic;
               adc_0        : in  std_logic_vector(11 downto 0);
               adc_1        : in  std_logic_vector(11 downto 0);
               adc_2        : in  std_logic_vector(11 downto 0);
               adc_3        : in  std_logic_vector(11 downto 0);
               threshold_0  : in  std_logic_vector(15 downto 0);
               threshold_1  : in  std_logic_vector(15 downto 0);
               threshold_2  : in  std_logic_vector(15 downto 0);
               threshold_3  : in  std_logic_vector(15 downto 0);
               trig_width   : in  std_logic_vector(15 downto 0);
               user_pattern : in  std_logic_vector(3 downto 0);
               coinc_out    : out std_logic );
    end component;

    constant DW         : integer := 12;
    constant clk_period : time    := 10 ns;
    constant BASELINE   : integer := 100;
    constant PEAK       : integer := 2000;

    type adc_array    is array (0 to 3) of std_logic_vector(DW-1 downto 0);
    type thresh_array is array (0 to 3) of std_logic_vector(15 downto 0);

    signal adc        : adc_array    := (others => (others => '0'));
    signal thresh     : thresh_array := (others => (others => '0'));
    signal start_ch   : std_logic_vector(3 downto 0) := (others => '0');
    signal sig_clock  : std_logic := '0';
    signal sig_reset  : std_logic := '0';
    signal sig_tw     : std_logic_vector(15 downto 0) := (others => '0');
    signal sig_pattern: std_logic_vector(3 downto 0)  := (others => '0');
    signal sig_coinc  : std_logic;

begin

    uut: detector_top
        port map ( clock        => sig_clock,
                   reset        => sig_reset,
                   adc_0        => adc(0),
                   adc_1        => adc(1),
                   adc_2        => adc(2),
                   adc_3        => adc(3),
                   threshold_0  => thresh(0),
                   threshold_1  => thresh(1),
                   threshold_2  => thresh(2),
                   threshold_3  => thresh(3),
                   trig_width   => sig_tw,
                   user_pattern => sig_pattern,
                   coinc_out    => sig_coinc );

    clk_gen: process
    begin
        sig_clock <= '0'; wait for clk_period/2;
        sig_clock <= '1'; wait for clk_period/2;
    end process;

    gen_channels: for i in 0 to 3 generate
        pulse_gen: process
        begin
            adc(i) <= std_logic_vector(to_unsigned(BASELINE, DW));
            wait until start_ch(i) = '1';

            for k in 1 to 5 loop                       -- rising edge
                adc(i) <= std_logic_vector(
                    to_unsigned(BASELINE + k*(PEAK-BASELINE)/5, DW));
                wait for clk_period;
            end loop;

            for k in 0 to 29 loop                      -- decay
                adc(i) <= std_logic_vector(
                    to_unsigned(PEAK - k*(PEAK-BASELINE)/30, DW));
                wait for clk_period;
            end loop;
        end process;
    end generate;

    stimulus: process
    begin
        thresh(0) <= std_logic_vector(to_signed(3000, 16));
        thresh(1) <= std_logic_vector(to_signed(3000, 16));
        thresh(2) <= std_logic_vector(to_signed(3000, 16));
        thresh(3) <= std_logic_vector(to_signed(3000, 16));
        sig_tw      <= std_logic_vector(to_unsigned(20, 16));
        sig_pattern <= "0011";

        sig_reset <= '1';
        wait for clk_period*10;
        sig_reset <= '0';
        wait for clk_period*10;

        -- CASE 1: channels 0 and 1 together -> coincidence
        start_ch <= "0011"; wait for clk_period; start_ch <= "0000";
        wait for clk_period*100;

        -- CASE 2: channel 0 alone -> none
        start_ch <= "0001"; wait for clk_period; start_ch <= "0000";
        wait for clk_period*100;

        -- CASE 3: channels 0, 1, 2 -> none (triple rejected)
        start_ch <= "0111"; wait for clk_period; start_ch <= "0000";
        wait for clk_period*100;

        -- CASE 4: 0 and 1 offset 5 cycles, inside window -> coincidence
        start_ch <= "0001"; wait for clk_period; start_ch <= "0000";
        wait for clk_period*4;
        start_ch <= "0010"; wait for clk_period; start_ch <= "0000";
        wait for clk_period*100;

        -- CASE 5: 0 and 1 offset 40 cycles, outside window -> none
        start_ch <= "0001"; wait for clk_period; start_ch <= "0000";
        wait for clk_period*39;
        start_ch <= "0010"; wait for clk_period; start_ch <= "0000";
        wait for clk_period*100;

        -- CASE 6: channel 2 raised above its pulse amplitude, 0/1/2 fire
        --         -> channel 2 suppressed, pattern is 0011 -> coincidence
        thresh(2) <= std_logic_vector(to_signed(30000, 16));
        wait for clk_period*5;
        start_ch <= "0111"; wait for clk_period; start_ch <= "0000";
        wait for clk_period*100;

        wait;
    end process;

end sim;