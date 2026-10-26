library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Energy histogram (multichannel analyser, MCA) for one channel: 2**ADDR_WIDTH
-- bins of COUNT_WIDTH-bit counts in one dual-port block RAM.
--
--   Port A, read-modify-write, run by the FSM below:
--     IDLE_S  -- energy_valid: bin = energy >> conv_gain. Over range -> count it
--                and drop it. Otherwise put bin on the address.
--     READ_S  -- the RAM reads the bin's old count (one clock of latency)
--     WRITE_S -- write old count + 1 back
--     CLEAR_S -- write 0 to every bin, one per clock (4096 clocks), on clear
--   Port B: read-only, for the PS (rd_addr -> rd_data, one clock of latency).
--
-- An event takes 3 clocks. energy_capture produces at most one per WINDOW + 2
-- clocks, so the FSM is always back in IDLE_S in time.
--
-- Events are only binned while enable = '1' (the run bit). clear also zeroes
-- the event and over-range counters.
entity histogram is
    Generic (ADDR_WIDTH   : integer := 12;
             COUNT_WIDTH  : integer := 32;
             ENERGY_WIDTH : integer := 32);
    Port (clock        : in  std_logic;
          reset        : in  std_logic;
          enable       : in  std_logic;
          clear        : in  std_logic;
          conv_gain    : in  std_logic_vector(3 downto 0);
          energy       : in  unsigned(ENERGY_WIDTH-1 downto 0);
          energy_valid : in  std_logic;
          rd_addr      : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
          rd_data      : out std_logic_vector(COUNT_WIDTH-1 downto 0);
          clearing     : out std_logic;
          event_count  : out unsigned(31 downto 0);
          over_count   : out unsigned(31 downto 0));
end histogram;

architecture behavior of histogram is

type ram_t is array (0 to 2**ADDR_WIDTH-1) of std_logic_vector(COUNT_WIDTH-1 downto 0);
signal ram : ram_t := (others => (others => '0'));   -- empty after configuration

type state_t is (IDLE_S, READ_S, WRITE_S, CLEAR_S);
signal state : state_t := IDLE_S;

signal addr  : unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
signal we    : std_logic;
signal din   : std_logic_vector(COUNT_WIDTH-1 downto 0);
signal douta : std_logic_vector(COUNT_WIDTH-1 downto 0) := (others => '0');
signal bin   : unsigned(ENERGY_WIDTH-1 downto 0);

signal events, overs : unsigned(31 downto 0) := (others => '0');

begin

    bin <= shift_right(energy, to_integer(unsigned(conv_gain)));

    fsm: process (clock)
    begin
        if rising_edge(clock) then
            if reset = '1' then
                state  <= IDLE_S;
                events <= (others => '0');
                overs  <= (others => '0');
            else
                case state is
                    when IDLE_S =>
                        if clear = '1' then
                            addr   <= (others => '0');
                            events <= (others => '0');
                            overs  <= (others => '0');
                            state  <= CLEAR_S;
                        elsif energy_valid = '1' and enable = '1' then
                            if bin > to_unsigned(2**ADDR_WIDTH - 1, ENERGY_WIDTH) then
                                overs <= overs + 1;
                            else
                                addr  <= bin(ADDR_WIDTH-1 downto 0);
                                state <= READ_S;
                            end if;
                        end if;

                    when READ_S =>
                        state <= WRITE_S;

                    when WRITE_S =>
                        events <= events + 1;
                        state  <= IDLE_S;

                    when CLEAR_S =>
                        if addr = 2**ADDR_WIDTH - 1 then
                            state <= IDLE_S;
                        else
                            addr <= addr + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;

    we  <= '1' when state = WRITE_S or state = CLEAR_S else '0';
    din <= std_logic_vector(unsigned(douta) + 1) when state = WRITE_S else (others => '0');

    -- Block RAM, written in the shape Vivado's synthesis guide gives for a
    -- dual-port RAM: port A reads and writes, port B only reads.
    port_a: process (clock)
    begin
        if rising_edge(clock) then
            if we = '1' then
                ram(to_integer(addr)) <= din;
            end if;
            douta <= ram(to_integer(addr));
        end if;
    end process;

    port_b: process (clock)
    begin
        if rising_edge(clock) then
            rd_data <= ram(to_integer(unsigned(rd_addr)));
        end if;
    end process;

    clearing    <= '1' when state = CLEAR_S else '0';
    event_count <= events;
    over_count  <= overs;

end behavior;
