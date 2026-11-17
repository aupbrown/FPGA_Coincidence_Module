library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Turns a trigger plus the trap filter output into one energy value per pulse.
--
-- On each rising edge of trig_in, open a WINDOW-clock window and track the
-- largest trap_in seen (the workshop's peak detector). When the window closes,
-- emit that maximum on energy with a one-clock energy_valid pulse.
--
-- The window must cover the trap's flat top. Measured from the start of a
-- pulse, the trigger fires a few clocks in; the flat top ends at about
-- L + 5 clocks (filter latency). WINDOW = L + 16 covers it with margin.
--
-- A trigger that arrives while a window is already open is pile-up: a second
-- pulse on top of the first, whose energies cannot be separated. It is not
-- measured; pileup pulses for one clock so it can be counted.
--
-- Baseline: blr (from baseline_restorer, or 0 when the BLR is off) is latched
-- on the trigger's rising edge. After the window, one more clock (SUB_S)
-- registers energy = peak - blr, 0 if negative; energy_valid follows.
entity energy_capture is
    Generic (ACC_WIDTH : integer := 32;
             WINDOW    : integer := 72);
    Port (clock        : in  std_logic;
          reset        : in  std_logic;
          trig_in      : in  std_logic;
          trap_in      : in  signed(ACC_WIDTH-1 downto 0);
          blr          : in  signed(ACC_WIDTH-1 downto 0);
          energy       : out unsigned(ACC_WIDTH-1 downto 0);
          energy_valid : out std_logic;
          pileup       : out std_logic);
end energy_capture;

architecture behavior of energy_capture is

type state_t is (IDLE_S, CAPTURE_S, SUB_S, DONE_S);
signal state : state_t := IDLE_S;

signal trig_d    : std_logic := '0';
signal trig_rise : std_logic;
signal count     : integer range 0 to WINDOW := 0;
signal peak      : signed(ACC_WIDTH-1 downto 0) := (others => '0');
signal blr_l     : signed(ACC_WIDTH-1 downto 0) := (others => '0');
signal diff      : signed(ACC_WIDTH downto 0);
signal energy_r  : unsigned(ACC_WIDTH-1 downto 0) := (others => '0');

begin

    trig_rise <= trig_in and not trig_d;
    diff      <= resize(peak, ACC_WIDTH+1) - resize(blr_l, ACC_WIDTH+1);

    process (clock)
    begin
        if rising_edge(clock) then
            trig_d <= trig_in;
            if reset = '1' then
                state <= IDLE_S;
                count <= 0;
                peak  <= (others => '0');
                blr_l <= (others => '0');
                energy_r <= (others => '0');
            else
                case state is
                    when IDLE_S =>
                        if trig_rise = '1' then
                            state <= CAPTURE_S;
                            count <= 0;
                            peak  <= trap_in;
                            blr_l <= blr;
                        end if;

                    when CAPTURE_S =>
                        if trap_in > peak then
                            peak <= trap_in;
                        end if;
                        if count = WINDOW - 1 then
                            state <= SUB_S;
                        else
                            count <= count + 1;
                        end if;

                    when SUB_S =>
                        -- A negative result (no real pulse in the window) reads as 0.
                        if diff < 0 then
                            energy_r <= (others => '0');
                        else
                            energy_r <= unsigned(diff(ACC_WIDTH-1 downto 0));
                        end if;
                        state <= DONE_S;

                    when DONE_S =>
                        state <= IDLE_S;
                end case;
            end if;
        end if;
    end process;

    energy_valid <= '1' when state = DONE_S else '0';
    energy <= energy_r;
    pileup <= '1' when trig_rise = '1' and state /= IDLE_S else '0';

end behavior;
