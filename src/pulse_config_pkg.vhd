library ieee;
use ieee.std_logic_1164.all;

-- Pulse generator settings for the four channels, grouped into numbered sets.
-- core_top's PULSE_SET generic picks one. model/config.py holds a copy of these
-- numbers for the Python golden model: change both together. The CONFIG
-- register reports PULSE_SET so the compare script can check it is using the
-- matching copy.
--
--   amps     : charge of each pulse, in ADC counts. With trap gain K and
--              conversion gain G, a pulse of charge A lands near bin K*A / 2**G.
--              The generator cycles through amps(0 .. num_amps-1), one per pulse.
--   rise     : clocks over which the charge is injected (the pulse's rise time)
--   period   : clocks from one pulse start to the next
--   delay    : clocks before the first pulse
--
-- All sets use base = 100 and a decay shift of TRAP_M (core_top), so the pulse
-- tail decays by 1/32 per clock (tau = 32 clocks = 0.96 us) and the trap's
-- pole-zero correction matches it.
package pulse_config_pkg is

    type amp_array is array (0 to 3) of integer;

    type pulse_cfg_t is record
        num_amps : integer;
        amps     : amp_array;
        rise     : integer;
        period   : integer;
        delay    : integer;
    end record;

    type chan_cfg_t is array (0 to 3) of pulse_cfg_t;
    type cfg_set_t  is array (1 to 2) of chan_cfg_t;

    constant PULSE_SETS : cfg_set_t := (
        -- Set 1: the original pulse train, reshaped for the trap filter. One
        -- amplitude, 20-clock rise like the old +100/clock ramp, channels 2-3
        -- 40 clocks behind 0-1. Every histogram is a single peak at bin 2000.
        1 => (
            0 => (1, (2000, 0, 0, 0), 20, 512, 0),
            1 => (1, (2000, 0, 0, 0), 20, 512, 0),
            2 => (1, (2000, 0, 0, 0), 20, 512, 40),
            3 => (1, (2000, 0, 0, 0), 20, 512, 40)),
        -- Set 2: changed constants. Fast 4-clock rise and a different amplitude
        -- pattern per channel:
        --   ch0  four peaks (500, 1000, 1500, 2000), one pulse of each in turn
        --   ch1  one peak at 3000 (over range if the conversion gain drops to 4)
        --   ch2  two peaks (800, 2400)
        --   ch3  200: below the default trigger threshold, so it never triggers
        --        and its histogram stays empty -- the control channel.
        2 => (
            0 => (4, (500, 1000, 1500, 2000), 4, 512, 0),
            1 => (1, (3000, 0, 0, 0),          4, 512, 0),
            2 => (2, (800, 2400, 0, 0),        4, 512, 40),
            3 => (1, (200, 0, 0, 0),           4, 512, 40))
        );

end package;
