-- ps7_stub_wrapper_sim.vhd
--
-- Simulation stand-in for the PS7 block that build.tcl generates for Vivado.
-- board_top takes its clock from the PS's FCLK_CLK0; here that clock is made
-- by this model instead. The testbench reads the same clock through
-- ps7_sim_pkg.fclk, and stops it by setting ps7_sim_pkg.sim_done.
--
-- fclk and FCLK_CLK0 are driven by the same process so they change in the same
-- delta cycle: the testbench sees exactly the edges board_top sees.

library ieee;
use ieee.std_logic_1164.all;

package ps7_sim_pkg is
    constant FCLK_PERIOD : time := 30 ns;      -- 33.333 MHz, as on hardware
    signal fclk     : std_logic := '0';
    signal sim_done : boolean   := false;
end package;

library ieee;
use ieee.std_logic_1164.all;
use work.ps7_sim_pkg.all;

entity ps7_stub_wrapper is
    port ( FCLK_CLK0 : out std_logic );
end ps7_stub_wrapper;

architecture sim of ps7_stub_wrapper is
begin
    clock_driver : process
    begin
        while not sim_done loop
            fclk      <= '0';
            FCLK_CLK0 <= '0';
            wait for FCLK_PERIOD / 2;
            fclk      <= '1';
            FCLK_CLK0 <= '1';
            wait for FCLK_PERIOD / 2;
        end loop;
        wait;
    end process;
end sim;
