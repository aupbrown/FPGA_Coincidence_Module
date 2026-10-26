library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity detector_top is
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
        trig_out : out std_logic_vector(3 downto 0);  -- each channel's trigger, for energy capture
        coinc_out : out std_logic );
end detector_top;

architecture behavior of detector_top is

component trigger is
    Generic (data_width : integer := 12;
        filter_width : integer := 10;
        acc_width : integer := 16);
    Port (adc_in : in std_logic_vector(data_width-1 downto 0);
        threshold : in std_logic_vector(acc_width-1 downto 0);
        reset : in std_logic;
        clock : in std_logic;
        trig_width : in std_logic_vector(15 downto 0);
        trig_out: out std_logic);
end component;

component coincidence is
    Generic (n_channels : integer := 4);
    Port (clock : in std_logic;
        trig_ins : in std_logic_vector(n_channels-1 downto 0);
        user_pattern : in  std_logic_vector(n_channels-1 downto 0);
        reset : in std_logic;
        coinc_out : out std_logic);
end component;

signal trig_bus : std_logic_vector(3 downto 0) := (others => '0');

begin

    trig0: trigger
    generic map (data_width => 12, filter_width => 10, acc_width => 16)
    port map (adc_in => adc_0,
        threshold  => threshold_0,
        reset => reset,
        clock => clock,
        trig_width => trig_width,
        trig_out   => trig_bus(0));
    
    trig1: trigger
    generic map (data_width => 12, filter_width => 10, acc_width => 16)
    port map (adc_in => adc_1,
        threshold  => threshold_1,
        reset => reset,
        clock => clock,
        trig_width => trig_width,
        trig_out   => trig_bus(1));
    
    trig2: trigger
    generic map (data_width => 12, filter_width => 10, acc_width => 16)
    port map (adc_in => adc_2,
        threshold  => threshold_2,
        reset => reset,
        clock => clock,
        trig_width => trig_width,
        trig_out   => trig_bus(2));
    
    trig3: trigger
    generic map (data_width => 12, filter_width => 10, acc_width => 16)
    port map (adc_in => adc_3,
        threshold  => threshold_3,
        reset => reset,
        clock => clock,
        trig_width => trig_width,
        trig_out   => trig_bus(3));

    coinc: coincidence
    generic map (n_channels => 4)
    port map (clock => clock,
        user_pattern => user_pattern,
        coinc_out => coinc_out,
        reset => reset,
        trig_ins => trig_bus);

    trig_out <= trig_bus;

end behavior;