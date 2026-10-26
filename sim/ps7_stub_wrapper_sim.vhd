-- ps7_stub_wrapper_sim.vhd
--
-- Simulation stand-in for the PS7 block design that build.tcl generates for
-- Vivado. It makes the 33.333 MHz FCLK_CLK0, releases PL_RESETN after a few
-- clocks, and leaves the AXI master idle. Its job is to let board_top
-- elaborate in NVC as a wiring check; tb_core_top tests the design itself by
-- driving core_top's AXI port directly.
--
-- Testbenches read the same clock through ps7_sim_pkg.fclk and stop it by
-- setting ps7_sim_pkg.sim_done.

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
    port ( FCLK_CLK0     : out std_logic;
           PL_RESETN     : out std_logic_vector(0 downto 0);
           M_AXI_araddr  : out std_logic_vector(31 downto 0);
           M_AXI_arprot  : out std_logic_vector(2 downto 0);
           M_AXI_arready : in  std_logic;
           M_AXI_arvalid : out std_logic;
           M_AXI_awaddr  : out std_logic_vector(31 downto 0);
           M_AXI_awprot  : out std_logic_vector(2 downto 0);
           M_AXI_awready : in  std_logic;
           M_AXI_awvalid : out std_logic;
           M_AXI_bready  : out std_logic;
           M_AXI_bresp   : in  std_logic_vector(1 downto 0);
           M_AXI_bvalid  : in  std_logic;
           M_AXI_rdata   : in  std_logic_vector(31 downto 0);
           M_AXI_rready  : out std_logic;
           M_AXI_rresp   : in  std_logic_vector(1 downto 0);
           M_AXI_rvalid  : in  std_logic;
           M_AXI_wdata   : out std_logic_vector(31 downto 0);
           M_AXI_wready  : in  std_logic;
           M_AXI_wstrb   : out std_logic_vector(3 downto 0);
           M_AXI_wvalid  : out std_logic );
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

    PL_RESETN <= "0", "1" after 5 * FCLK_PERIOD;

    M_AXI_araddr  <= (others => '0');
    M_AXI_arprot  <= (others => '0');
    M_AXI_arvalid <= '0';
    M_AXI_awaddr  <= (others => '0');
    M_AXI_awprot  <= (others => '0');
    M_AXI_awvalid <= '0';
    M_AXI_bready  <= '1';
    M_AXI_rready  <= '1';
    M_AXI_wdata   <= (others => '0');
    M_AXI_wstrb   <= (others => '0');
    M_AXI_wvalid  <= '0';
end sim;
