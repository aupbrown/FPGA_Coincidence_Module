library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Replay buffer: stands in for an ADC by playing recorded samples, one word
-- per clock.
--
-- The PS fills the buffer over AXI while the run is stopped (slow: about a
-- microsecond per word from Linux), then starts the run. From then on the
-- PL plays the words at the full clock rate, which software could never
-- stream. Each word carries two 12-bit samples, one per lane:
--   [11:0]  lane A (ch0)      [27:16] lane B (ch1)
--
--   Port A: the PS. wr_en writes wr_data at wr_addr; otherwise it reads
--           rd_addr -> rd_data, one clock of latency (so a load can be read
--           back and checked). One address for both, as a block RAM port
--           has: a write wins, and that clock's read is skipped. The PS's
--           uncached /dev/mem accesses never overlap a write and a read.
--   Port B: the player.
--
-- Player, as seen at the sample output (registered):
--   idle    sample = word 0, playing = 0
--   start   (one clock, ignored if len = 0): from the next clock, sample =
--           word 0, 1, ..., len-1 with playing = 1, one per clock
--   end     after word len-1: back to word 0, playing = 0, done = 1. done
--           stays 1 until the next start.
-- playing is aligned with sample: it is 1 exactly for the clocks in which
-- sample holds a played word.
entity replay_source is
    Generic (ADDR_WIDTH : integer := 17);   -- 2**17 = 131072 words
    Port (clock    : in  std_logic;
          reset    : in  std_logic;
          wr_en    : in  std_logic;
          wr_addr  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
          wr_data  : in  std_logic_vector(31 downto 0);
          rd_addr  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
          rd_data  : out std_logic_vector(31 downto 0);
          start    : in  std_logic;
          len      : in  unsigned(ADDR_WIDTH downto 0);   -- 0 .. 2**ADDR_WIDTH
          sample   : out std_logic_vector(31 downto 0);
          playing  : out std_logic;
          done     : out std_logic);
end replay_source;

architecture behavior of replay_source is

type ram_t is array (0 to 2**ADDR_WIDTH-1) of std_logic_vector(31 downto 0);
signal ram : ram_t := (others => (others => '0'));

signal idx       : unsigned(ADDR_WIDTH downto 0) := (others => '0');  -- word on sample
signal play_addr : unsigned(ADDR_WIDTH downto 0);
signal play, fin : std_logic := '0';
signal last      : std_logic;
signal addr_a    : std_logic_vector(ADDR_WIDTH-1 downto 0);

begin

    last <= '1' when idx = len - 1 else '0';

    -- Address of the word sample will hold after this clock
    play_addr <= idx + 1 when play = '1' and start = '0' and last = '0'
                 else (others => '0');

    player: process (clock)
    begin
        if rising_edge(clock) then
            if reset = '1' then
                play <= '0';
                fin  <= '0';
                idx  <= (others => '0');
            elsif start = '1' and len /= 0 then
                play <= '1';
                fin  <= '0';
                idx  <= (others => '0');
            elsif play = '1' then
                if last = '1' then
                    play <= '0';
                    fin  <= '1';
                    idx  <= (others => '0');
                else
                    idx <= idx + 1;
                end if;
            end if;
        end if;
    end process;

    -- Block RAM, written in the shape Vivado's synthesis guide gives for a
    -- dual-port RAM: port A reads and writes, port B only reads.
    addr_a <= wr_addr when wr_en = '1' else rd_addr;

    port_a: process (clock)
    begin
        if rising_edge(clock) then
            if wr_en = '1' then
                ram(to_integer(unsigned(addr_a))) <= wr_data;
            else
                rd_data <= ram(to_integer(unsigned(addr_a)));
            end if;
        end if;
    end process;

    port_b: process (clock)
    begin
        if rising_edge(clock) then
            sample <= ram(to_integer(play_addr(ADDR_WIDTH-1 downto 0)));
        end if;
    end process;

    playing <= play;
    done    <= fin;

end behavior;
