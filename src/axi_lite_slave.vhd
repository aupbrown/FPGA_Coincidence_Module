library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- AXI4-Lite slave: turns the PS's bus transactions into a simple register bus.
--
-- AXI4-Lite has five channels, each with its own VALID/READY handshake. A
-- transfer happens on a clock edge where both VALID and READY are high:
--   AW  write address   (master -> slave)
--   W   write data      (master -> slave)
--   B   write response  (slave -> master)
--   AR  read address    (master -> slave)
--   R   read data       (slave -> master)
-- A master may not drop VALID until it sees READY, so the slave can wait.
--
-- Writes: wait until AW and W are both valid, accept both together (one
-- clock of AWREADY/WREADY), pulse wr_en with the address, data and strobes,
-- then hold BVALID until the master takes the response.
--
-- Reads: accept AR (one clock of ARREADY) and pulse rd_en with the address.
-- The register bus has READ_LATENCY clocks of latency: rd_data is valid
-- READ_LATENCY clocks after the rd_en clock. Then hold RVALID with the data
-- until the master takes it.
--
-- One transaction at a time; the response is always OKAY ("00").
entity axi_lite_slave is
    Generic (ADDR_WIDTH   : integer := 17;
             READ_LATENCY : integer := 2);
    Port (aclk    : in  std_logic;
          aresetn : in  std_logic;
          -- AXI4-Lite
          awaddr  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
          awvalid : in  std_logic;
          awready : out std_logic;
          wdata   : in  std_logic_vector(31 downto 0);
          wstrb   : in  std_logic_vector(3 downto 0);
          wvalid  : in  std_logic;
          wready  : out std_logic;
          bresp   : out std_logic_vector(1 downto 0);
          bvalid  : out std_logic;
          bready  : in  std_logic;
          araddr  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
          arvalid : in  std_logic;
          arready : out std_logic;
          rdata   : out std_logic_vector(31 downto 0);
          rresp   : out std_logic_vector(1 downto 0);
          rvalid  : out std_logic;
          rready  : in  std_logic;
          -- Register bus
          wr_en   : out std_logic;
          wr_addr : out std_logic_vector(ADDR_WIDTH-1 downto 0);
          wr_data : out std_logic_vector(31 downto 0);
          wr_strb : out std_logic_vector(3 downto 0);
          rd_en   : out std_logic;
          rd_addr : out std_logic_vector(ADDR_WIDTH-1 downto 0);
          rd_data : in  std_logic_vector(31 downto 0));
end axi_lite_slave;

architecture behavior of axi_lite_slave is

signal aw_accept, b_valid : std_logic := '0';
signal ar_accept, r_valid : std_logic := '0';
signal rd_busy            : std_logic := '0';
signal rd_pipe            : std_logic_vector(READ_LATENCY downto 1) := (others => '0');

begin

    write_channel: process (aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                aw_accept <= '0';
                b_valid   <= '0';
            else
                if aw_accept = '0' and b_valid = '0' and awvalid = '1' and wvalid = '1' then
                    aw_accept <= '1';           -- AWREADY = WREADY = 1 for this clock
                    wr_addr   <= awaddr;
                    wr_data   <= wdata;
                    wr_strb   <= wstrb;
                else
                    aw_accept <= '0';
                end if;

                if aw_accept = '1' then
                    b_valid <= '1';             -- AW and W were taken: respond
                elsif b_valid = '1' and bready = '1' then
                    b_valid <= '0';
                end if;
            end if;
        end if;
    end process;

    read_channel: process (aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                ar_accept <= '0';
                r_valid   <= '0';
                rd_busy   <= '0';
                rd_pipe   <= (others => '0');
            else
                if ar_accept = '0' and rd_busy = '0' and arvalid = '1' then
                    ar_accept <= '1';           -- ARREADY = 1 for this clock
                    rd_busy   <= '1';
                    rd_addr   <= araddr;
                else
                    ar_accept <= '0';
                end if;

                -- rd_pipe(i) = '1' means the read issued i clocks ago
                rd_pipe <= rd_pipe(READ_LATENCY-1 downto 1) & ar_accept;

                if rd_pipe(READ_LATENCY) = '1' then
                    rdata   <= rd_data;
                    r_valid <= '1';
                elsif r_valid = '1' and rready = '1' then
                    r_valid <= '0';
                    rd_busy <= '0';
                end if;
            end if;
        end if;
    end process;

    awready <= aw_accept;
    wready  <= aw_accept;
    wr_en   <= aw_accept;
    bvalid  <= b_valid;
    bresp   <= "00";

    arready <= ar_accept;
    rd_en   <= ar_accept;
    rvalid  <= r_valid;
    rresp   <= "00";

end behavior;
