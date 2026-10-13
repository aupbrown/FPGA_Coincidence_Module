library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity trigger is
    Generic (data_width : integer := 12;
        filter_width : integer := 10;
        acc_width : integer := 16);  -- Literal, NOT data_width + ceil(log2(filter_width)):
                                     -- Vivado rejects a generic default that
                                     -- references another generic. Must satisfy
                                     -- acc_width >= data_width + ceil(log2(filter_width)).
                                     -- 12 + ceil(log2(10)) = 12 + 4 = 16. OK.
        
    Port (adc_in : in std_logic_vector(data_width-1 downto 0);
        threshold : in std_logic_vector(acc_width-1 downto 0);
        reset : in std_logic;
        clock : in std_logic;
        trig_width : in std_logic_vector(15 downto 0);
        trig_out : out std_logic);
end trigger;

architecture behavior of trigger is

type state_t is (OFF_S, RESET_S, WAIT_S, ON_S, WAITOFF_S);
signal state, next_state : state_t := OFF_S;

signal comp_out, en_counter, reset_counter, counter_done : std_logic := '0';
signal dt_count : unsigned(15 downto 0) := (others => '0');

-- ADC samples are unsigned. They are zero-extended to acc_width before the
-- filter arithmetic, which stays signed because the filter output swings negative.
type delay_array is array (1 to filter_width) of unsigned(data_width-1 downto 0);

Signal delay_line : delay_array := (others => (others => '0'));

Signal acc: signed(acc_width-1 downto 0) := (others => '0');


begin
    assert (filter_width mod 2) = 0
        report "filter_width must be even" severity failure;


    sync: process (clock)
    begin
        if rising_edge(clock) then
            if reset = '1' then
                state <= OFF_S;
            else
                state <= next_state;
            end if;
        end if;
    end process;

    comb: process (state, comp_out, counter_done)
    begin
        next_state <= state;
        trig_out <= '0';
        en_counter <= '0';
        reset_counter <= '0';

        case state is
            when OFF_S => 
                if comp_out = '1' then
                    next_state <= RESET_S;
                else
                    next_state <= OFF_S;
                end if;

            when RESET_S =>
                next_state <= WAIT_S;
                reset_counter <= '1';
                trig_out <= '1';

            when WAITOFF_S =>
                if comp_out = '1' then
                    next_state <= WAITOFF_S;
                else
                    next_state <= OFF_S;
                end if;

            when WAIT_S =>
                trig_out <= '1';
                en_counter <= '1';
                if comp_out = '1' and counter_done = '0' then
                    next_state <= WAIT_S;
                elsif counter_done = '1' then
                    next_state <= WAITOFF_S;
                else
                    next_state <= ON_S;
                end if;

            when ON_S =>
                trig_out <= '1';
                en_counter <= '1';
                if comp_out = '1' then
                    next_state <= RESET_S;
                elsif counter_done = '1' then
                    next_state <= OFF_S;
                else
                    next_state <= ON_S;
                end if;
            
            when others =>
            -- protects against corruption from radiation-induced states caused by bit-flips. Important in PET environment.
                next_state <= OFF_S;
        end case;
    end process;

    dt_counter: process (clock)
    begin
        if rising_edge(clock) then
            if reset_counter = '1' or reset = '1' then
                dt_count <= (others => '0');
            elsif en_counter = '1' then
                dt_count <= dt_count + 1;
            end if;
        end if;
    end process;


    filter: process (clock)
    begin
        if rising_edge(clock) then

            if reset = '1' then
                for i in 1 to filter_width loop
                delay_line(i) <= (others => '0');
                end loop;
                acc <= (others => '0');
            else

                delay_line(1) <= unsigned(adc_in);
                for i in 2 to filter_width loop
                    delay_line(i) <= delay_line(i-1);
                end loop;

                acc <= ((signed(resize(unsigned(adc_in),acc_width)) + acc) - shift_left(signed(resize(delay_line(filter_width/2), acc_width)), 1)) + signed(resize(delay_line(filter_width),acc_width));

            end if;
        end if;
    end process;

counter_done <= '1' when dt_count >= unsigned(trig_width) else '0';
comp_out <= '1' when acc > signed(threshold) else '0';

end behavior;