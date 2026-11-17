library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pulse_config_pkg.all;

-- Everything in the PL except the PS7 block: four pulse channels, the trigger
-- and coincidence logic, the energy chain and histograms, and the AXI4-Lite
-- register map through which the PS controls and reads it all.
--
--   pulse_gen x4 ---+
--                   +--> source mux --> polarity --adc--> detector_top (trigger x4 + coincidence) --coinc--> counter
--   replay_source --+                         |                     | trig(ch)
--   (ch0, ch1)                                +--> trap_filter --> energy_capture --> histogram (one per channel)
--
-- Register map (byte offsets from the AXI base, 0x43C0_0000 on the board).
-- RO = read only, RW = read/write. Defaults are the reset values.
--   0x000 ID           RO  0x454E_0003 ("EN", version 3)
--   0x004 CONFIG       RO  [7:0] PULSE_SET, [15:8] K, [23:16] L, [31:24] TRAP_M register
--   0x008 CONTROL      RW  bit 0 run. bit 1 clear: write 1 to zero the histograms
--                          and every counter and reset the trap filters
--                          (self-clearing, reads 0)
--   0x00C STATUS       RO  bit 0 run, bit 1 clear in progress,
--                          bit 2 replay playing, bit 3 replay done
--   0x010 UPTIME       RO  clocks since reset (wraps every 86 s)
--   0x014 RUN_CLOCKS   RO  clocks spent with run = 1 since the last clear
--   0x018 CONV_GAIN    RW  [3:0] bin = energy >> CONV_GAIN.            Default 5
--   0x01C USER_PATTERN RW  [3:0] coincidence pattern.                 Default 0011
--   0x020 TRIG_WIDTH   RW  [15:0] trigger window (delta t), clocks.    Default 50
--   0x024 COINC_COUNT  RO  coincidences (rising edges) while running
--   0x028 BASELINE     RW  [11:0] ADC baseline subtracted before the trap
--                          filters. Default 100. Clear after changing it.
--   0x02C SOURCE       RW  bit 0 = 1: ch0/ch1 take replay lanes A/B, ch2/ch3
--                          a constant BASELINE (silent). Default 0 = pulse_gen
--   0x030 + 4*ch THRESHOLD_ch RW [15:0] signed trigger threshold.     Default 1250
--   0x040 + 16*ch      RO  +0 TRIG_COUNT, +4 EVENT_COUNT (binned),
--                          +8 OVER_COUNT (over range), +C PILEUP_COUNT
--   0x080 POLARITY     RW  [3:0] bit ch = 1: invert channel ch's ADC samples
--                          (4095 - x) before trigger and trap, for
--                          negative-going pulses (CZT cathode). Default 0
--   0x084 TRAP_M       RW  [3:0] trap pole-zero shift M: alpha = 1 - 2**-M,
--                          tau ~ 2**M clocks. Default TRAP_M generic (5, which
--                          matches pulse_gen). Clear after changing it.
--   0x088 REPLAY_LEN   RW  [17:0] words to play, 1 .. 131072
--   0x08C BLR_ENABLE   RW  [3:0] bit ch = 1: subtract channel ch's baseline
--                          restorer output from each energy. Default 0
--   0x0C0 + 4*ch BLR_ch RO signed baseline restorer output: the mean trap
--                          output over the last 256 quiet clocks (~0 when
--                          BASELINE and TRAP_M are right)
--   0x1_0000 + 0x4000*ch + 4*bin  RO  histogram ch, bins 0..4095
--   0x8_0000 + 4*i     RW  replay buffer word i, 0 .. 131071
--                          ([11:0] lane A, [27:16] lane B)
--
-- Replay (SOURCE = 1): the PS loads the buffer and REPLAY_LEN while stopped,
-- then sets run. On run's rising edge the buffer plays once, one word per
-- clock; then STATUS.done is set and the player outputs word 0. While SOURCE
-- = 1 and nothing is playing, the trap filters are held in reset, so every
-- play starts from the same state however long the PS took in between.
entity core_top is
    Generic (PULSE_SET : integer := 2;
             K         : integer := 32;
             L         : integer := 56;
             TRAP_M    : integer := 5);
    Port (aclk          : in  std_logic;
          aresetn       : in  std_logic;
          s_axi_awaddr  : in  std_logic_vector(19 downto 0);
          s_axi_awvalid : in  std_logic;
          s_axi_awready : out std_logic;
          s_axi_wdata   : in  std_logic_vector(31 downto 0);
          s_axi_wstrb   : in  std_logic_vector(3 downto 0);
          s_axi_wvalid  : in  std_logic;
          s_axi_wready  : out std_logic;
          s_axi_bresp   : out std_logic_vector(1 downto 0);
          s_axi_bvalid  : out std_logic;
          s_axi_bready  : in  std_logic;
          s_axi_araddr  : in  std_logic_vector(19 downto 0);
          s_axi_arvalid : in  std_logic;
          s_axi_arready : out std_logic;
          s_axi_rdata   : out std_logic_vector(31 downto 0);
          s_axi_rresp   : out std_logic_vector(1 downto 0);
          s_axi_rvalid  : out std_logic;
          s_axi_rready  : in  std_logic);
end core_top;

architecture behavior of core_top is

constant ID_VALUE : std_logic_vector(31 downto 0) := x"454E0003";
constant WINDOW   : integer := L + 16;   -- energy window, see energy_capture.vhd

constant CFG : chan_cfg_t := PULSE_SETS(PULSE_SET);

-- ---------------------------------------------------------------------------
-- Per-channel signals
-- ---------------------------------------------------------------------------
type adc_array    is array (0 to 3) of std_logic_vector(11 downto 0);
type trap_array   is array (0 to 3) of signed(31 downto 0);
type energy_array is array (0 to 3) of unsigned(31 downto 0);
type word_array   is array (0 to 3) of std_logic_vector(31 downto 0);
type count_array  is array (0 to 3) of unsigned(31 downto 0);
type thresh_array is array (0 to 3) of std_logic_vector(15 downto 0);

signal rst : std_logic;

signal gen_adc      : adc_array;    -- pulse_gen outputs
signal src_adc      : adc_array;    -- after the source mux
signal adc          : adc_array;    -- after the polarity stage
signal trap         : trap_array;
signal blr, blr_in  : trap_array;
signal energy       : energy_array;
signal energy_valid : std_logic_vector(3 downto 0);
signal pileup       : std_logic_vector(3 downto 0);
signal clearing     : std_logic_vector(3 downto 0);
signal hist_rd_data : word_array;
signal event_count, over_count : count_array;

signal trig, trig_d  : std_logic_vector(3 downto 0) := (others => '0');
signal coinc, coinc_d : std_logic := '0';

-- ---------------------------------------------------------------------------
-- Registers
-- ---------------------------------------------------------------------------
signal run          : std_logic := '0';
signal clear_pulse  : std_logic := '0';
signal conv_gain    : std_logic_vector(3 downto 0)  := std_logic_vector(to_unsigned(5, 4));
signal user_pattern : std_logic_vector(3 downto 0)  := "0011";
signal trig_width   : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(50, 16));
signal threshold    : thresh_array := (others => std_logic_vector(to_signed(1250, 16)));
signal baseline     : std_logic_vector(11 downto 0) := std_logic_vector(to_unsigned(100, 12));
signal polarity     : std_logic_vector(3 downto 0)  := "0000";
signal trap_m_reg   : std_logic_vector(3 downto 0)  := std_logic_vector(to_unsigned(TRAP_M, 4));
signal source       : std_logic := '0';
signal replay_len   : unsigned(17 downto 0) := (others => '0');
signal blr_enable   : std_logic_vector(3 downto 0)  := "0000";
signal trap_reset   : std_logic;

-- Replay
signal run_d          : std_logic := '0';
signal replay_start   : std_logic;
signal replay_wr      : std_logic;
signal replay_sample  : std_logic_vector(31 downto 0);
signal replay_rd_data : std_logic_vector(31 downto 0);
signal replay_playing, replay_done : std_logic;

signal uptime, run_clocks, coinc_count : unsigned(31 downto 0) := (others => '0');
signal trig_count, pileup_count        : count_array := (others => (others => '0'));

-- Register bus from the AXI slave
signal wr_en : std_logic;
signal wr_addr, rd_addr : std_logic_vector(19 downto 0);
signal wr_data, rd_data : std_logic_vector(31 downto 0);
signal wr_strb : std_logic_vector(3 downto 0);

signal reg_rd   : std_logic_vector(31 downto 0) := (others => '0');
signal hist_sel : std_logic := '0';
signal rep_sel  : std_logic := '0';
signal hist_ch  : integer range 0 to 3 := 0;

-- Byte-wise write: keep the bytes of old whose strobe bit is 0.
function apply_strb(old, new_data : std_logic_vector(31 downto 0);
                    strb : std_logic_vector(3 downto 0)) return std_logic_vector is
    variable r : std_logic_vector(31 downto 0) := old;
begin
    for b in 0 to 3 loop
        if strb(b) = '1' then
            r(8*b+7 downto 8*b) := new_data(8*b+7 downto 8*b);
        end if;
    end loop;
    return r;
end function;

begin

    rst <= not aresetn;
    trap_reset <= rst or clear_pulse or (source and not replay_playing);

    -- -----------------------------------------------------------------------
    -- Signal chain
    -- -----------------------------------------------------------------------
    detector: entity work.detector_top
        port map (clock        => aclk,
                  reset        => rst,
                  adc_0        => adc(0),
                  adc_1        => adc(1),
                  adc_2        => adc(2),
                  adc_3        => adc(3),
                  threshold_0  => threshold(0),
                  threshold_1  => threshold(1),
                  threshold_2  => threshold(2),
                  threshold_3  => threshold(3),
                  trig_width   => trig_width,
                  user_pattern => user_pattern,
                  trig_out     => trig,
                  coinc_out    => coinc);

    -- -----------------------------------------------------------------------
    -- Replay buffer: the PS writes it at 0x8_0000, it plays on run's rising edge
    -- -----------------------------------------------------------------------
    replay_start <= run and not run_d and source;
    replay_wr    <= wr_en and wr_addr(19);

    replay: entity work.replay_source
        generic map (ADDR_WIDTH => 17)
        port map (clock   => aclk,
                  reset   => rst,
                  wr_en   => replay_wr,
                  wr_addr => wr_addr(18 downto 2),
                  wr_data => wr_data,
                  rd_addr => rd_addr(18 downto 2),
                  rd_data => replay_rd_data,
                  start   => replay_start,
                  len     => replay_len,
                  sample  => replay_sample,
                  playing => replay_playing,
                  done    => replay_done);

    src_adc(0) <= replay_sample(11 downto 0)  when source = '1' else gen_adc(0);
    src_adc(1) <= replay_sample(27 downto 16) when source = '1' else gen_adc(1);
    src_adc(2) <= baseline                    when source = '1' else gen_adc(2);
    src_adc(3) <= baseline                    when source = '1' else gen_adc(3);

    channels: for ch in 0 to 3 generate

        pulse_i: entity work.pulse_gen
            generic map (BASE => 100, data_width => 12,
                         NUM_AMPS    => CFG(ch).num_amps,
                         AMP_0       => CFG(ch).amps(0),
                         AMP_1       => CFG(ch).amps(1),
                         AMP_2       => CFG(ch).amps(2),
                         AMP_3       => CFG(ch).amps(3),
                         RISE_CYCLES => CFG(ch).rise,
                         DECAY_SHIFT => TRAP_M,
                         PERIOD      => CFG(ch).period,
                         START_DELAY => CFG(ch).delay)
            port map (clock => aclk, reset => rst, adc_out => gen_adc(ch));

        -- 4095 - x is the bitwise complement of a 12-bit sample
        adc(ch) <= not src_adc(ch) when polarity(ch) = '1' else src_adc(ch);

        trap_i: entity work.trap_filter
            generic map (data_width => 12, K => K, L => L, ACC_WIDTH => 32)
            port map (clock => aclk, reset => trap_reset,
                      adc_in => adc(ch), baseline => baseline,
                      decay_shift => trap_m_reg, trap_out => trap(ch));

        -- Mean trap output while there is no pulse (see baseline_restorer.vhd)
        blr_i: entity work.baseline_restorer
            generic map (ACC_WIDTH => 32, NSHIFT => 8, HOLD => 2 * (K + L), LIMIT => 1024)
            port map (clock => aclk, reset => trap_reset,
                      trig_in => trig(ch), trap_in => trap(ch), blr_out => blr(ch));

        blr_in(ch) <= blr(ch) when blr_enable(ch) = '1' else (others => '0');

        capture_i: entity work.energy_capture
            generic map (ACC_WIDTH => 32, WINDOW => WINDOW)
            port map (clock        => aclk,
                      reset        => rst,
                      trig_in      => trig(ch),
                      trap_in      => trap(ch),
                      blr          => blr_in(ch),
                      energy       => energy(ch),
                      energy_valid => energy_valid(ch),
                      pileup       => pileup(ch));

        hist_i: entity work.histogram
            generic map (ADDR_WIDTH => 12, COUNT_WIDTH => 32, ENERGY_WIDTH => 32)
            port map (clock        => aclk,
                      reset        => rst,
                      enable       => run,
                      clear        => clear_pulse,
                      conv_gain    => conv_gain,
                      energy       => energy(ch),
                      energy_valid => energy_valid(ch),
                      rd_addr      => rd_addr(13 downto 2),
                      rd_data      => hist_rd_data(ch),
                      clearing     => clearing(ch),
                      event_count  => event_count(ch),
                      over_count   => over_count(ch));

    end generate;

    -- -----------------------------------------------------------------------
    -- Counters. Edge counters count rising edges, so one long trigger
    -- window or coincidence counts once.
    -- -----------------------------------------------------------------------
    counters: process (aclk)
    begin
        if rising_edge(aclk) then
            trig_d  <= trig;
            coinc_d <= coinc;
            run_d   <= run;
            if rst = '1' then
                uptime <= (others => '0');
            else
                uptime <= uptime + 1;
            end if;

            if rst = '1' or clear_pulse = '1' then
                run_clocks   <= (others => '0');
                coinc_count  <= (others => '0');
                trig_count   <= (others => (others => '0'));
                pileup_count <= (others => (others => '0'));
            elsif run = '1' then
                run_clocks <= run_clocks + 1;
                if coinc = '1' and coinc_d = '0' then
                    coinc_count <= coinc_count + 1;
                end if;
                for ch in 0 to 3 loop
                    if trig(ch) = '1' and trig_d(ch) = '0' then
                        trig_count(ch) <= trig_count(ch) + 1;
                    end if;
                    if pileup(ch) = '1' then
                        pileup_count(ch) <= pileup_count(ch) + 1;
                    end if;
                end loop;
            end if;
        end if;
    end process;

    -- -----------------------------------------------------------------------
    -- AXI4-Lite slave and register map
    -- -----------------------------------------------------------------------
    axi: entity work.axi_lite_slave
        generic map (ADDR_WIDTH => 20, READ_LATENCY => 2)
        port map (aclk    => aclk,          aresetn => aresetn,
                  awaddr  => s_axi_awaddr,  awvalid => s_axi_awvalid, awready => s_axi_awready,
                  wdata   => s_axi_wdata,   wstrb   => s_axi_wstrb,
                  wvalid  => s_axi_wvalid,  wready  => s_axi_wready,
                  bresp   => s_axi_bresp,   bvalid  => s_axi_bvalid,  bready  => s_axi_bready,
                  araddr  => s_axi_araddr,  arvalid => s_axi_arvalid, arready => s_axi_arready,
                  rdata   => s_axi_rdata,   rresp   => s_axi_rresp,
                  rvalid  => s_axi_rvalid,  rready  => s_axi_rready,
                  wr_en   => wr_en,   wr_addr => wr_addr, wr_data => wr_data, wr_strb => wr_strb,
                  rd_en   => open,    rd_addr => rd_addr, rd_data => rd_data);

    reg_write: process (aclk)
        variable word : integer;
        variable v    : std_logic_vector(31 downto 0);
    begin
        if rising_edge(aclk) then
            clear_pulse <= '0';
            if rst = '1' then
                run          <= '0';
                conv_gain    <= std_logic_vector(to_unsigned(5, 4));
                user_pattern <= "0011";
                trig_width   <= std_logic_vector(to_unsigned(50, 16));
                threshold    <= (others => std_logic_vector(to_signed(1250, 16)));
                baseline     <= std_logic_vector(to_unsigned(100, 12));
                polarity     <= "0000";
                trap_m_reg   <= std_logic_vector(to_unsigned(TRAP_M, 4));
                source       <= '0';
                replay_len   <= (others => '0');
                blr_enable   <= "0000";
            elsif wr_en = '1' and wr_addr(19 downto 16) = "0000" then
                word := to_integer(unsigned(wr_addr(15 downto 2)));
                case word is
                    when 16#008#/4 =>
                        v := apply_strb(x"0000000" & "000" & run, wr_data, wr_strb);
                        run         <= v(0);
                        clear_pulse <= v(1);
                    when 16#018#/4 =>
                        v := apply_strb(x"0000000" & conv_gain, wr_data, wr_strb);
                        conv_gain <= v(3 downto 0);
                    when 16#01C#/4 =>
                        v := apply_strb(x"0000000" & user_pattern, wr_data, wr_strb);
                        user_pattern <= v(3 downto 0);
                    when 16#020#/4 =>
                        v := apply_strb(x"0000" & trig_width, wr_data, wr_strb);
                        trig_width <= v(15 downto 0);
                    when 16#028#/4 =>
                        v := apply_strb(x"00000" & baseline, wr_data, wr_strb);
                        baseline <= v(11 downto 0);
                    when 16#02C#/4 =>
                        v := apply_strb(x"0000000" & "000" & source, wr_data, wr_strb);
                        source <= v(0);
                    when 16#030#/4 to 16#03C#/4 =>
                        v := apply_strb(x"0000" & threshold(word - 16#030#/4), wr_data, wr_strb);
                        threshold(word - 16#030#/4) <= v(15 downto 0);
                    when 16#080#/4 =>
                        v := apply_strb(x"0000000" & polarity, wr_data, wr_strb);
                        polarity <= v(3 downto 0);
                    when 16#084#/4 =>
                        v := apply_strb(x"0000000" & trap_m_reg, wr_data, wr_strb);
                        trap_m_reg <= v(3 downto 0);
                    when 16#088#/4 =>
                        v := apply_strb(std_logic_vector(resize(replay_len, 32)), wr_data, wr_strb);
                        replay_len <= unsigned(v(17 downto 0));
                    when 16#08C#/4 =>
                        v := apply_strb(x"0000000" & blr_enable, wr_data, wr_strb);
                        blr_enable <= v(3 downto 0);
                    when others =>
                        null;
                end case;
            end if;
        end if;
    end process;

    -- Reads take two clocks: stage 1 picks the register (and the histogram
    -- and replay RAMs read rd_addr), stage 2 picks register, histogram or
    -- replay buffer.
    reg_read: process (aclk)
        variable word, ch, field : integer;
    begin
        if rising_edge(aclk) then
            if rd_addr(19 downto 16) = "0001" then
                hist_sel <= '1';
            else
                hist_sel <= '0';
            end if;
            rep_sel  <= rd_addr(19);
            hist_ch  <= to_integer(unsigned(rd_addr(15 downto 14)));

            word   := to_integer(unsigned(rd_addr(15 downto 2)));
            reg_rd <= (others => '0');
            case word is
                when 16#000#/4 => reg_rd <= ID_VALUE;
                when 16#004#/4 => reg_rd <= "0000" & trap_m_reg &
                                            std_logic_vector(to_unsigned(L, 8)) &
                                            std_logic_vector(to_unsigned(K, 8)) &
                                            std_logic_vector(to_unsigned(PULSE_SET, 8));
                when 16#008#/4 => reg_rd(0) <= run;
                when 16#00C#/4 => reg_rd(0) <= run;
                                  if clearing /= "0000" then reg_rd(1) <= '1'; end if;
                                  reg_rd(2) <= replay_playing;
                                  reg_rd(3) <= replay_done;
                when 16#010#/4 => reg_rd <= std_logic_vector(uptime);
                when 16#014#/4 => reg_rd <= std_logic_vector(run_clocks);
                when 16#018#/4 => reg_rd(3 downto 0)  <= conv_gain;
                when 16#01C#/4 => reg_rd(3 downto 0)  <= user_pattern;
                when 16#020#/4 => reg_rd(15 downto 0) <= trig_width;
                when 16#024#/4 => reg_rd <= std_logic_vector(coinc_count);
                when 16#028#/4 => reg_rd(11 downto 0) <= baseline;
                when 16#02C#/4 => reg_rd(0) <= source;
                when 16#030#/4 to 16#03C#/4 =>
                    reg_rd <= std_logic_vector(resize(signed(threshold(word - 16#030#/4)), 32));
                when 16#040#/4 to 16#07C#/4 =>
                    ch    := (word - 16#040#/4) / 4;
                    field := (word - 16#040#/4) mod 4;
                    case field is
                        when 0      => reg_rd <= std_logic_vector(trig_count(ch));
                        when 1      => reg_rd <= std_logic_vector(event_count(ch));
                        when 2      => reg_rd <= std_logic_vector(over_count(ch));
                        when others => reg_rd <= std_logic_vector(pileup_count(ch));
                    end case;
                when 16#080#/4 => reg_rd(3 downto 0) <= polarity;
                when 16#084#/4 => reg_rd(3 downto 0) <= trap_m_reg;
                when 16#088#/4 => reg_rd(17 downto 0) <= std_logic_vector(replay_len);
                when 16#08C#/4 => reg_rd(3 downto 0) <= blr_enable;
                when 16#0C0#/4 to 16#0CC#/4 =>
                    reg_rd <= std_logic_vector(blr(word - 16#0C0#/4));
                when others => null;
            end case;

            if rep_sel = '1' then
                rd_data <= replay_rd_data;
            elsif hist_sel = '1' then
                rd_data <= hist_rd_data(hist_ch);
            else
                rd_data <= reg_rd;
            end if;
        end if;
    end process;

end behavior;
