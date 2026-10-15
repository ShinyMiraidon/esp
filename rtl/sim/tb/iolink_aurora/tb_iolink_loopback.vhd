-- Copyright (c) 2011-2026 Columbia University, System Level Design Group
-- SPDX-License-Identifier: Apache-2.0
--
-- Loopback testbench for the ESP I/O link carried over Aurora 64B/66B.
--
--   AHB master BFM -> ahbslv2iolink -> PHY -> channel -> PHY -> iolink2ahbm
--                                                              -> AHB memory
--
-- Both bridges and both PHYs are the real RTL; only the AHB endpoints and the
-- Aurora channel are modelled. The generics are taken from esp_global, so this
-- exercises the board's ACTUAL configuration -- CFG_IOLINK_BITS and, above all,
-- CFG_IOLINK_CREDITS.
--
-- What this is for: Aurora streaming has no m_axi_rx_tready, so the credit
-- scheme is the only flow control on this path. If the sender can overshoot
-- its budget, the receiver silently overruns -- corruption, not a stall. That
-- property cannot be checked by synthesis and is expensive to debug on
-- hardware, so it is checked here, over a realistic ~110 cycle round trip.
--
-- KNOWN BLIND SPOT: both PHYs share one user_clk and the channel maps bit i to
-- bit i, so a bit- or byte-ordering error at the Aurora interface would cancel
-- out and pass. Only real Aurora, or two boards on fibre, covers that. This
-- tests the protocol, not the serdes.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

use work.amba.all;
use work.stdlib.all;
use work.devices.all;
use work.esp_global.all;

entity tb_iolink_loopback is
end entity tb_iolink_loopback;

architecture sim of tb_iolink_loopback is

  constant BW       : integer := CFG_IOLINK_BITS;
  constant CREDITS  : integer := CFG_IOLINK_CREDITS;
  constant LATENCY  : integer := 55;         -- per direction, user_clk cycles
  constant N_WORDS  : integer := 64;         -- transactions per phase
  constant MEM_WORDS: integer := 1024;
  -- Idle cycles the BFM inserts between transfers. 0 = back-to-back.
  -- Master write-data style. false = AHB-compliant (hwdata valid only in the
  -- data phase), which is how ESP's noc2ahbmst behaves. true = GRLIB DMA
  -- style (hwdata valid from the address phase and held), which is how the
  -- FPGA proxy's masters behave -- the bridge's pre-existing user.
  constant HWDATA_EARLY : boolean := false;
  constant XFER_GAP : integer := 0;
  -- Whether user_clk runs while the SoC is in reset. On the board it does NOT:
  -- top.vhd holds Aurora's pma_init for as long as rstn is low, which keeps
  -- the transceiver -- and so user_clk -- stopped. Any register on user_clk
  -- with a SYNCHRONOUS reset is then never reset and starts from its power-up
  -- INIT instead. false models the board; true is the idealised clock this
  -- testbench originally assumed, which hid exactly that class of bug.
  constant USER_CLK_IN_RESET : boolean := false;

  -- Contents are irrelevant here: the BFM drives hsel directly rather than
  -- relying on plug-and-play address decoding.
  constant IOLINK_HCONFIG : ahb_config_type := (others => zero32);

  constant FAR_HINDEX  : integer := 2;
  constant NEAR_HINDEX : integer := 0;

  signal clk       : std_ulogic := '0';      -- bridge core clock
  signal user_clk  : std_ulogic := '0';      -- Aurora user clock
  signal rstn      : std_ulogic := '0';
  signal user_rstn : std_ulogic := '0';
  signal done      : boolean := false;

  -- Far side (AHB slave -> link)
  signal f_ahbsi : ahb_slv_in_type;
  signal f_ahbso : ahb_slv_out_type;
  signal f_io_clk_in, f_io_clk_out       : std_logic;
  signal f_io_valid_in, f_io_valid_out   : std_ulogic;
  signal f_io_credit_in, f_io_credit_out : std_logic;
  signal f_io_data_in, f_io_data_out     : std_logic_vector(BW - 1 downto 0);

  -- Near side (link -> AHB master)
  signal n_ahbmi : ahb_mst_in_type;
  signal n_ahbmo : ahb_mst_out_type;
  signal n_io_clk_in, n_io_clk_out       : std_logic;
  signal n_io_valid_in, n_io_valid_out   : std_ulogic;
  signal n_io_credit_in, n_io_credit_out : std_logic;
  signal n_io_data_in, n_io_data_out     : std_logic_vector(BW - 1 downto 0);

  -- PHY <-> channel
  signal fa_tx_tdata, fa_rx_tdata : std_logic_vector(63 downto 0);
  signal fa_tx_tvalid, fa_tx_tready, fa_rx_tvalid : std_ulogic;
  signal na_tx_tdata, na_rx_tdata : std_logic_vector(63 downto 0);
  signal na_tx_tvalid, na_tx_tready, na_rx_tvalid : std_ulogic;

  signal chan_up : std_ulogic := '0';

  signal f_ready, f_ovf, f_syncerr : std_ulogic;
  signal n_ready, n_ovf, n_syncerr : std_ulogic;
  signal beats_f2n, beats_n2f : integer;

  -- Memory model storage
  type mem_t is array (0 to MEM_WORDS - 1) of std_logic_vector(AHBDW - 1 downto 0);
  signal mem : mem_t := (others => (others => '0'));

  signal n_ahb_writes : integer := 0;
  signal mem_addr     : integer range 0 to MEM_WORDS - 1 := 0;
  signal mem_write    : boolean := false;
  signal mem_live     : boolean := false;
  signal n_ahb_reads  : integer := 0;

  function pattern(i : integer) return std_logic_vector is
    variable v : unsigned(63 downto 0);
  begin
    -- Multiplicative hash: neighbouring words differ in many bits, so a
    -- misaligned beat or a stuck bit shows up immediately. Done in unsigned
    -- because the multiplier exceeds VHDL's 32-bit signed integer range.
    v := to_unsigned(i, 32) * unsigned'(x"9E3779B1");
    return std_logic_vector(v(31 downto 0));
  end function;

begin

  clk      <= not clk      after 5.0 ns when not done else '0';
  user_clk <= not user_clk after 3.2 ns
              when not done and (rstn = '1' or USER_CLK_IN_RESET) else '0';

  -----------------------------------------------------------------------------
  -- DUTs
  -----------------------------------------------------------------------------
  far_bridge : entity work.ahbslv2iolink
    generic map (
      hindex        => FAR_HINDEX,
      hconfig       => IOLINK_HCONFIG,
      io_bitwidth   => BW,
      word_bitwidth => 32,
      little_end    => 0,
      credit_depth  => CREDITS)
    port map (
      clk => clk, rstn => rstn,
      -- Root user_clk, not f_io_clk_in: the PHY forwards user_clk through a
      -- signal assignment, which in simulation lands its edge in the same
      -- delta as the PHY's RX registers update. Same net in hardware.
      io_clk_in     => user_clk,
      io_clk_out    => f_io_clk_out,
      io_valid_in   => f_io_valid_in,
      io_valid_out  => f_io_valid_out,
      io_credit_in  => f_io_credit_in,
      io_credit_out => f_io_credit_out,
      io_data_oen   => open,
      io_data_in    => f_io_data_in,
      io_data_out   => f_io_data_out,
      ahbsi => f_ahbsi, ahbso => f_ahbso);

  far_phy : entity work.iolink_phy_aurora
    generic map (io_bitwidth => BW, tx_fifo_depth => 32)
    port map (
      user_clk => user_clk, user_rstn => user_rstn,
      channel_up => chan_up, lane_up => chan_up,
      hard_err => '0', soft_err => '0',
      tx_tdata => fa_tx_tdata, tx_tvalid => fa_tx_tvalid, tx_tready => fa_tx_tready,
      rx_tdata => fa_rx_tdata, rx_tvalid => fa_rx_tvalid,
      io_clk_out    => f_io_clk_in,
      -- Physically this IS clk: ahbslv2iolink forwards its core clock. It is
      -- driven from clk directly rather than through f_io_clk_out because the
      -- bridge forwards it via two signal assignments, which in SIMULATION
      -- delays the edge by delta cycles relative to data launched on clk --
      -- enough for io_credit_out (a flop straight on clk) to arrive before the
      -- delayed edge and be sampled a cycle early. In hardware these are one
      -- net and the race does not exist.
      io_clk_in     => clk,
      io_valid_out  => f_io_valid_in,
      io_credit_out => f_io_credit_in,
      io_data_out   => f_io_data_in,
      io_valid_in   => f_io_valid_out,
      io_credit_in  => f_io_credit_out,
      io_data_in    => f_io_data_out,
      link_ready => f_ready, tx_overflow => f_ovf, rx_sync_err => f_syncerr);

  chan_f2n : entity work.aurora_channel_model
    generic map (LATENCY => LATENCY)
    port map (
      user_clk => user_clk, user_rstn => user_rstn,
      tx_tdata => fa_tx_tdata, tx_tvalid => fa_tx_tvalid, tx_tready => fa_tx_tready,
      rx_tdata => na_rx_tdata, rx_tvalid => na_rx_tvalid,
      beats_in => beats_f2n);

  chan_n2f : entity work.aurora_channel_model
    generic map (LATENCY => LATENCY)
    port map (
      user_clk => user_clk, user_rstn => user_rstn,
      tx_tdata => na_tx_tdata, tx_tvalid => na_tx_tvalid, tx_tready => na_tx_tready,
      rx_tdata => fa_rx_tdata, rx_tvalid => fa_rx_tvalid,
      beats_in => beats_n2f);

  near_phy : entity work.iolink_phy_aurora
    generic map (io_bitwidth => BW, tx_fifo_depth => 32)
    port map (
      user_clk => user_clk, user_rstn => user_rstn,
      channel_up => chan_up, lane_up => chan_up,
      hard_err => '0', soft_err => '0',
      tx_tdata => na_tx_tdata, tx_tvalid => na_tx_tvalid, tx_tready => na_tx_tready,
      rx_tdata => na_rx_tdata, rx_tvalid => na_rx_tvalid,
      io_clk_out    => n_io_clk_in,
      io_clk_in     => user_clk,         -- iolink2ahbm loops user_clk back; same net
      io_valid_out  => n_io_valid_in,
      io_credit_out => n_io_credit_in,
      io_data_out   => n_io_data_in,
      io_valid_in   => n_io_valid_out,
      io_credit_in  => n_io_credit_out,
      io_data_in    => n_io_data_out,
      link_ready => n_ready, tx_overflow => n_ovf, rx_sync_err => n_syncerr);

  near_bridge : entity work.iolink2ahbm
    generic map (
      hindex        => NEAR_HINDEX,
      io_bitwidth   => BW,
      word_bitwidth => 32,
      little_end    => 0,
      credit_depth  => CREDITS)
    port map (
      clk => clk, rstn => rstn,
      io_clk_in     => user_clk,     -- root clock; see the far bridge's note
      io_clk_out    => n_io_clk_out,
      io_valid_in   => n_io_valid_in,
      io_valid_out  => n_io_valid_out,
      io_credit_in  => n_io_credit_in,
      io_credit_out => n_io_credit_out,
      io_data_oen   => open,
      io_data_in    => n_io_data_in,
      io_data_out   => n_io_data_out,
      ahbmo => n_ahbmo, ahbmi => n_ahbmi);

  -----------------------------------------------------------------------------
  -- Near-side AHB memory: always granted, zero wait states.
  -----------------------------------------------------------------------------
  n_ahbmi.hgrant  <= (others => '1');
  n_ahbmi.hready  <= '1';
  n_ahbmi.hresp   <= HRESP_OKAY;
  n_ahbmi.hirq    <= (others => '0');
  n_ahbmi.testen  <= '0';
  n_ahbmi.testrst <= '1';
  n_ahbmi.scanen  <= '0';
  n_ahbmi.testoen <= '0';
  n_ahbmi.testin  <= (others => '0');

  -- AHB slave timing: the address phase is latched on an edge; the DATA phase
  -- is the following cycle. With hready tied high, the master samples read data
  -- at the end of that single data-phase cycle, so hrdata must be valid DURING
  -- it -- i.e. driven combinationally from the latched address. An earlier
  -- version registered hrdata on the edge after the address phase, which made
  -- it valid one cycle too late: the master always saw the previous read's
  -- data. Write data, by contrast, is sampled at the end of the data phase.
  memory : process (clk) is
  begin
    if rising_edge(clk) then
      if rstn = '0' then
        mem_live <= false;
      else
        if mem_live and mem_write then
          mem(mem_addr) <= n_ahbmo.hwdata;
          n_ahb_writes  <= n_ahb_writes + 1;
        elsif mem_live then
          n_ahb_reads   <= n_ahb_reads + 1;
        end if;
        if n_ahbmo.htrans = HTRANS_NONSEQ or n_ahbmo.htrans = HTRANS_SEQ then
          mem_addr  <= (to_integer(unsigned(n_ahbmo.haddr(31 downto 2)))) mod MEM_WORDS;
          mem_write <= (n_ahbmo.hwrite = '1');
          mem_live  <= true;
        else
          mem_live  <= false;
        end if;
      end if;
    end if;
  end process memory;

  n_ahbmi.hrdata <= mem(mem_addr);







  -----------------------------------------------------------------------------
  -- Far-side AHB master BFM. Single slave, so the global hready is its hready.
  -----------------------------------------------------------------------------
  f_ahbsi.hready    <= f_ahbso.hready;
  f_ahbsi.hirq      <= (others => '0');
  f_ahbsi.hmaster   <= (others => '0');
  f_ahbsi.hmastlock <= '0';
  f_ahbsi.hmbsel    <= (others => '0');
  f_ahbsi.hprot     <= (others => '0');
  f_ahbsi.testen    <= '0';
  f_ahbsi.testrst   <= '1';
  f_ahbsi.scanen    <= '0';
  f_ahbsi.testoen   <= '0';
  f_ahbsi.testin    <= (others => '0');

  -- A transfer that never completes must REPORT, not stall the run. The BFM
  -- waits on hready with no timeout of its own, so without this a broken
  -- bridge simply hangs the simulation. A clean run takes ~20 us.
  watchdog : process is
  begin
    wait until done for 200 us;
    assert done
      report "WATCHDOG: testbench hung -- an AHB transfer never completed"
      severity failure;
    wait;
  end process watchdog;

  stim : process is
    variable l        : line;
    variable rd       : std_logic_vector(31 downto 0);
    variable mism     : integer := 0;
    variable t0, t1   : time;

    procedure idle_bus is
    begin
      f_ahbsi.hsel   <= (others => '0');
      f_ahbsi.htrans <= HTRANS_IDLE;
      f_ahbsi.hwrite <= '0';
    end procedure;

    -- NOTE ON hwdata TIMING
    --
    -- ahbslv2iolink asserts sample_bus only in its recv_address state, and that
    -- is where it latches hwdata_reg. So it captures write data during the
    -- ADDRESS phase, not the data phase that standard AHB would use. This BFM
    -- therefore presents haddr and hwdata together. Driving hwdata a cycle
    -- later -- which is what AHB says to do -- makes the bridge send whatever
    -- was on the bus previously.
    procedure ahb_xfer(addr : integer; wr : boolean; wdata : std_logic_vector(31 downto 0);
                       rdata : out std_logic_vector(31 downto 0)) is
    begin
      -- Address phase, with write data presented at the same time.
      f_ahbsi.hsel            <= (others => '0');
      f_ahbsi.hsel(FAR_HINDEX)<= '1';
      f_ahbsi.haddr           <= std_logic_vector(to_unsigned(addr, GLOB_PHYS_ADDR_BITS));
      if wr then f_ahbsi.hwrite <= '1'; else f_ahbsi.hwrite <= '0'; end if;
      f_ahbsi.htrans          <= HTRANS_NONSEQ;
      f_ahbsi.hsize           <= "010";           -- word
      f_ahbsi.hburst          <= "000";           -- single, never "001"
      if HWDATA_EARLY then
        f_ahbsi.hwdata        <= ahbdrivedata(wdata);  -- GRLIB DMA style
      else
        f_ahbsi.hwdata        <= (others => '0');      -- compliant: not yet valid
      end if;
      loop
        wait until rising_edge(clk);
        exit when f_ahbso.hready = '1';
      end loop;
      -- Hold hsel through the data phase: ahbso.hready is only driven when
      -- hsel_reg(hindex) is set, so dropping select here would stall us.
      -- htrans must NOT be SEQ, or get_length switches to burst mode.
      f_ahbsi.htrans <= HTRANS_IDLE;
      f_ahbsi.hwdata <= ahbdrivedata(wdata);       -- COMPLIANT: data phase
      loop
        wait until rising_edge(clk);
        -- Sample read data at the edge that completes the data phase, which is
        -- when an AHB master is supposed to. Reading it after returning -- the
        -- earlier version of this BFM -- picks up whatever the bridge drives
        -- once it has moved on.
        if f_ahbso.hready = '1' then
          rdata := ahbreadword(f_ahbso.hrdata);
          exit;
        end if;
      end loop;
      idle_bus;
      for i in 1 to XFER_GAP loop wait until rising_edge(clk); end loop;
    end procedure;

  begin
    idle_bus;
    f_ahbsi.haddr  <= (others => '0');
    f_ahbsi.hwdata <= (others => '0');
    f_ahbsi.hsize  <= "010";
    f_ahbsi.hburst <= "000";

    rstn      <= '0';
    user_rstn <= '0';
    chan_up   <= '0';
    for i in 1 to 20 loop wait until rising_edge(clk); end loop;
    rstn      <= '1';
    -- Aurora's sys_reset_out, which drives the PHYs' user_rstn, deasserts only
    -- once user_clk is running, i.e. after rstn.
    for i in 1 to 10 loop wait until rising_edge(clk); end loop;
    user_rstn <= '1';
    for i in 1 to 20 loop wait until rising_edge(clk); end loop;
    chan_up   <= '1';
    for i in 1 to 200 loop wait until rising_edge(clk); end loop;

    write(l, string'("=== iolink over Aurora: loopback ==="));           writeline(output, l);
    write(l, string'("  CFG_IOLINK_BITS    = ")); write(l, BW);          writeline(output, l);
    write(l, string'("  CFG_IOLINK_CREDITS = ")); write(l, CREDITS);     writeline(output, l);
    write(l, string'("  one-way latency    = ")); write(l, LATENCY);
    write(l, string'(" user_clk cycles"));                               writeline(output, l);
    write(l, string'("  link_ready far/near= "));
    write(l, std_ulogic'image(f_ready)); write(l, std_ulogic'image(n_ready)); writeline(output, l);

    ---------------------------------------------------------------------
    write(l, string'("--- PHASE 1: ")); write(l, N_WORDS);
    write(l, string'(" writes far -> near"));                            writeline(output, l);
    ---------------------------------------------------------------------
    t0 := now;
    for i in 0 to N_WORDS - 1 loop
      ahb_xfer(16#1000# + i * 4, true, pattern(i), rd);
    end loop;
    for i in 1 to 400 loop wait until rising_edge(clk); end loop;
    t1 := now;
    write(l, string'("  AHB writes seen by memory : ")); write(l, n_ahb_writes); writeline(output, l);
    write(l, string'("  elapsed                   : ")); write(l, (t1 - t0));    writeline(output, l);

    ---------------------------------------------------------------------
    write(l, string'("--- PHASE 2: read back and verify"));              writeline(output, l);
    ---------------------------------------------------------------------
    for i in 0 to N_WORDS - 1 loop
      ahb_xfer(16#1000# + i * 4, false, (others => '0'), rd);
      if rd /= pattern(i) then
        mism := mism + 1;
        if mism <= 5 then
          write(l, string'("  MISMATCH at word ")); write(l, i);
          write(l, string'(" exp=")); write(l, to_integer(unsigned(pattern(i))));
          write(l, string'(" got=")); write(l, to_integer(unsigned(rd)));
          writeline(output, l);
        end if;
      end if;
    end loop;

    ---------------------------------------------------------------------
    write(l, string'("=== RESULT ==="));                                  writeline(output, l);
    write(l, string'("  mismatches        : ")); write(l, mism);          writeline(output, l);
    write(l, string'("  AHB writes / reads: ")); write(l, n_ahb_writes);
    write(l, string'(" / ")); write(l, n_ahb_reads);                      writeline(output, l);
    write(l, string'("  beats f2n / n2f   : ")); write(l, beats_f2n);
    write(l, string'(" / ")); write(l, beats_n2f);                        writeline(output, l);
    write(l, string'("  tx_overflow f/n   : "));
    write(l, std_ulogic'image(f_ovf)); write(l, std_ulogic'image(n_ovf)); writeline(output, l);
    write(l, string'("  rx_sync_err f/n   : "));
    write(l, std_ulogic'image(f_syncerr)); write(l, std_ulogic'image(n_syncerr)); writeline(output, l);

    assert mism = 0     report "DATA MISMATCH"        severity error;
    assert f_ovf = '0' and n_ovf = '0'
      report "tx_overflow asserted -- TX elastic FIFO undersized, data lost" severity error;
    assert f_syncerr = '0' and n_syncerr = '0'
      report "rx_sync_err asserted -- framing slip"   severity error;

    done <= true;
    wait;
  end process stim;

end architecture sim;
