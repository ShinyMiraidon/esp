-- Copyright (c) 2011-2026 Columbia University, System Level Design Group
-- SPDX-License-Identifier: Apache-2.0

-------------------------------------------------------------------------------
-- iolink_phy_aurora
--
-- Physical layer for the ESP I/O link over an Aurora 64B/66B serial channel,
-- replacing the source-synchronous parallel pads used for the chip-to-FPGA
-- cable. It presents the far end of the cable to iolink2ahbm / ahbslv2iolink,
-- which are unchanged.
--
-- The existing link is a good fit for this: it is credit-based, so latency
-- insensitive; its clock-domain crossing is already handled by async FIFOs in
-- the bridges; and the link side is already clocked by an externally supplied
-- clock (iolink2ahbm.vhd does io_clk_out_int <= io_clk_in). Driving io_clk_in
-- from Aurora's user_clk therefore needs no change inside the bridges.
--
-------------------------------------------------------------------------------
-- WHY THE CREDIT BUDGET MATTERS HERE
--
-- Aurora's streaming interface has s_axi_tx_tready but NO m_axi_rx_tready:
-- the receiver cannot backpressure the channel. The I/O link's credit scheme
-- is therefore the only flow control on this path, not merely an optimisation.
-- Size CONFIG_IOLINK_CREDITS to at least the round-trip latency in link words
-- (Aurora is 54-55 user_clk cycles each way, so ~256 with margin) or the link
-- throttles badly; the default of 8 yields roughly 3% utilisation.
--
-------------------------------------------------------------------------------
-- WHY THERE IS A TX FIFO
--
-- iolink2ahbm and ahbslv2iolink have no "PHY busy" input. Their send FSMs gate
-- only on credits and their own FIFO occupancy, so they will present a word
-- whether or not the PHY can take it that cycle. Aurora deasserts
-- s_axi_tx_tready periodically while it inserts clock-compensation sequences.
-- Without elasticity here those words would be dropped silently. The FIFO
-- absorbs the gap; it is small because CC sequences are short and infrequent.
--
-- tx_overflow is exposed rather than hidden: if it ever asserts, the FIFO is
-- undersized for the configured line rate and the link is corrupting data.
-- Treat it as a hard failure, not a statistic.
--
-------------------------------------------------------------------------------
-- WIRE FORMAT
--
-- One 64-bit Aurora beat per link event. Streaming mode preserves word order
-- and inserts no framing of its own, so a fixed layout is sufficient:
--
--   [63:56] SYNC   constant tag, so a framing slip shows up immediately
--   [55]    VALID  the DATA field carries a link word
--   [54]    CREDIT a credit is being returned
--   [53:16] unused, transmitted as zero
--   [15:0]  DATA   the link word, zero-extended from io_bitwidth
--
-- A beat is sent only when VALID or CREDIT is set, so an idle link sends
-- nothing and Aurora fills with its own idle blocks. Credits piggyback on data
-- beats when both happen in the same cycle, which is the common case.
--
-- io_bitwidth is capped at 16 by this layout. Widening it means widening DATA
-- into the unused field and bumping SYNC to a shorter tag; the assertion below
-- will catch an over-wide configuration at elaboration.
--
-------------------------------------------------------------------------------
-- NOT DONE HERE
--
-- The Aurora core itself is not instantiated: it is generated IP, pulled in by
-- the aurora block in utils/make/vivado.mk, and its port list depends on the
-- SupportLevel setting. In particular, whether user_clk is an input or an
-- output of the core differs between SupportLevel 0 and 1, so the top level
-- must wire it -- see constraints/<board>/aurora.tcl.
--
-- Elaborated, simulated and synthesised out-of-context against Vivado 2023.2
-- (xc7vx485tffg1761-2). It analysed, elaborated and synthesised clean on the
-- first attempt -- the compiler found nothing. Two functional bugs did show up
-- under simulation, both now fixed and both commented at the point of the fix:
--
--   * the TX FIFO lost track of its pointers when a push and a pop coincided
--     on a full FIFO, after which it transmitted stale entries under a valid
--     SYNC tag rather than stalling or reporting;
--   * hard_err was part of the link-up term, so a one-cycle status pulse
--     silently dropped a word.
--
-- Run on hardware between two VC707 boards over an SFP+ cable, initiator to
-- target, with a 3 x 64K-word read and write-back test passing clean. Note
-- that user_rstn's crossing into the user_clk domain is the top level's
-- problem: it is used as a synchronous reset below and is not synchronised
-- inside this module.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;


entity iolink_phy_aurora is
  generic (
    io_bitwidth : integer range 1 to 16 := 16;
    -- Elasticity for Aurora clock-compensation gaps. 32 is generous for a
    -- single lane; raise it if tx_overflow is ever observed. MUST be a power
    -- of 2: it sizes a gray-code async FIFO, whose clock-domain crossing is
    -- only safe when the pointer wraps at 2^n.
    tx_fifo_depth : integer range 4 to 256 := 32);
  port (
    -- Aurora user clock domain. user_clk also drives the link side of the
    -- bridge, via io_clk_in.
    user_clk     : in  std_ulogic;
    user_rstn    : in  std_ulogic;
    -- Aurora status
    channel_up   : in  std_ulogic;
    lane_up      : in  std_ulogic;
    hard_err     : in  std_ulogic;
    soft_err     : in  std_ulogic;
    -- Aurora TX AXI4-Stream (streaming mode: no tlast, no tkeep)
    tx_tdata     : out std_logic_vector(63 downto 0);
    tx_tvalid    : out std_ulogic;
    tx_tready    : in  std_ulogic;
    -- Aurora RX AXI4-Stream (streaming mode: valid only, no backpressure)
    rx_tdata     : in  std_logic_vector(63 downto 0);
    rx_tvalid    : in  std_ulogic;
    -- ESP I/O link, presented as the far end of the cable
    io_clk_out   : out std_ulogic;
    -- The bridge's TX clock -- connect the bridge's own io_clk_out here.
    -- io_valid_in / io_credit_in / io_data_in are launched on THIS clock, which
    -- is not necessarily user_clk. See "WHY THE TX FIFO IS ASYNCHRONOUS".
    io_clk_in    : in  std_ulogic;
    io_valid_out : out std_ulogic;
    io_credit_out : out std_ulogic;
    io_data_out  : out std_logic_vector(io_bitwidth - 1 downto 0);
    io_valid_in  : in  std_ulogic;
    io_credit_in : in  std_ulogic;
    io_data_in   : in  std_logic_vector(io_bitwidth - 1 downto 0);
    -- Diagnostics. link_ready is channel_up and lane_up, for status only: the
    -- PHY itself drops TX pushes and ignores RX beats while it is low. The
    -- error bits are sticky.
    link_ready   : out std_ulogic;
    tx_overflow  : out std_ulogic;
    rx_sync_err  : out std_ulogic);
end entity iolink_phy_aurora;

architecture rtl of iolink_phy_aurora is

  constant SYNC_TAG   : std_logic_vector(7 downto 0) := x"5A";
  constant BIT_VALID  : integer := 55;
  constant BIT_CREDIT : integer := 54;

  -- One FIFO entry is a whole link event, so data and its credit bit cannot
  -- be separated by the elastic buffer.
  constant ENTRY_WIDTH : integer := io_bitwidth + 2;

  signal fifo_push   : std_ulogic;
  signal fifo_accept : std_ulogic;
  signal fifo_pop    : std_ulogic;
  signal fifo_full   : std_logic;
  signal fifo_empty  : std_logic;
  signal fifo_din    : std_logic_vector(ENTRY_WIDTH - 1 downto 0);
  signal head        : std_logic_vector(ENTRY_WIDTH - 1 downto 0);

  signal sync_err_q : std_ulogic;
  signal ready_int  : std_ulogic;

  -- io_clk_in (write) domain copies of user_clk-domain state
  signal wr_rstn_meta, wr_rstn : std_ulogic := '0';
  signal ready_meta, ready_wr  : std_ulogic := '0';
  -- Sticky overflow lives in the write domain, where the drop happens; it is
  -- synchronised back to user_clk for the output port.
  signal overflow_wr                : std_ulogic := '0';
  signal overflow_meta, overflow_q  : std_ulogic := '0';

begin

  -- The bridge's RECEIVE side is clocked by the Aurora user clock. Its
  -- transmit side is a different question; see the TX FIFO below.
  io_clk_out <= user_clk;

  -- hard_err is deliberately NOT part of this term. Aurora drives hard_err as
  -- a status *pulse*, and the core resets the channel itself on a real hard
  -- error, so channel_up already falls. Including it here meant a one-cycle
  -- pulse gated the datapath for that cycle and silently dropped whatever word
  -- the bridge happened to be presenting -- confirmed in simulation: 4 words
  -- in, 3 transmitted, no error flag raised. hard_err and soft_err are left
  -- for the top level to surface to software as status.
  ready_int  <= channel_up and lane_up;
  link_ready <= ready_int;

  tx_overflow <= overflow_q;
  rx_sync_err <= sync_err_q;

  -----------------------------------------------------------------------------
  -- TX: link event -> elastic FIFO -> Aurora
  --
  -- WHY THE TX FIFO IS ASYNCHRONOUS
  --
  -- The two bridges do not transmit in the same clock domain, and this PHY
  -- originally assumed they did:
  --
  --   iolink2ahbm   crosses its TX data into io_clk_in internally and loops
  --                 io_clk_in back out, so what it presents here is already in
  --                 user_clk. The original premise holds for this bridge.
  --
  --   ahbslv2iolink drives its TX straight from its core clock and FORWARDS
  --                 that clock as io_clk_out -- the source-synchronous
  --                 convention of the parallel cable. What it presents here is
  --                 in tile_clk, not user_clk.
  --
  -- Sampling ahbslv2iolink's outputs on user_clk is a clock-domain-crossing
  -- violation. It went unnoticed because this PHY had only ever been paired
  -- with iolink2ahbm; the initiator role is the first to put ahbslv2iolink on
  -- it. The loopback testbench caught it: beats duplicated and dropped between
  -- what the initiator bridge emitted and what the target bridge received.
  --
  -- So the FIFO is written on io_clk_in -- the bridge's forwarded TX clock --
  -- and read on user_clk. For the target role io_clk_in IS user_clk and the
  -- crossing degenerates harmlessly; for the initiator it crosses tile_clk to
  -- user_clk properly.
  --
  -- This also replaces the hand-rolled single-clock FIFO whose pointer/count
  -- desync on a simultaneous push and pop at full was found and fixed earlier.
  -- The gray-code FIFO does its own accounting. The one consequence is that
  -- wr_full_o is computed from a synchronised read pointer and so is
  -- pessimistic by a couple of read-clock cycles, which at depth 32 on a
  -- mostly-idle link costs nothing.
  -----------------------------------------------------------------------------

  -- Write-domain reset: asserted asynchronously with user_rstn, released
  -- synchronously to io_clk_in, so the write pointer never leaves reset on a
  -- metastable edge.
  wr_rst_sync : process (io_clk_in, user_rstn) is
  begin
    if user_rstn = '0' then
      wr_rstn_meta <= '0';
      wr_rstn      <= '0';
    elsif rising_edge(io_clk_in) then
      wr_rstn_meta <= '1';
      wr_rstn      <= wr_rstn_meta;
    end if;
  end process wr_rst_sync;

  -- channel_up/lane_up live in user_clk but the accept decision is made in
  -- io_clk_in. A two-flop synchroniser suffices for a level that only changes
  -- when the link comes up or goes down.
  ready_sync : process (io_clk_in) is
  begin
    if rising_edge(io_clk_in) then
      ready_meta <= ready_int;
      ready_wr   <= ready_meta;
    end if;
  end process ready_sync;

  -- A push is anything the bridge presents; accepting it is a separate
  -- question. Splitting the two is what makes every dropped word visible:
  -- fifo_push and not fifo_accept is exactly "a word was lost", whether the
  -- FIFO was full or the link was down.
  fifo_push   <= io_valid_in or io_credit_in;
  fifo_accept <= fifo_push and ready_wr and (not fifo_full);
  -- One entry is a whole link event, so data and its credit bit cannot be
  -- separated by the elastic buffer.
  fifo_din    <= io_valid_in & io_credit_in & io_data_in;

  tx_async_fifo : entity work.inferred_async_fifo
    generic map (
      g_data_width => ENTRY_WIDTH,
      g_size       => tx_fifo_depth)
    port map (
      rst_wr_n_i => wr_rstn,
      clk_wr_i   => io_clk_in,
      we_i       => fifo_accept,
      d_i        => fifo_din,
      wr_full_o  => fifo_full,
      rst_rd_n_i => user_rstn,
      clk_rd_i   => user_clk,
      rd_i       => fifo_pop,
      q_o        => head,             -- first-word fall-through
      rd_empty_o => fifo_empty);

  -- tvalid depends only on FIFO state, never on tready, as AXI4-Stream requires.
  tx_tvalid <= not fifo_empty;
  fifo_pop  <= (not fifo_empty) and tx_tready;

  tx_data_map : process (head) is
  begin
    tx_tdata <= (others => '0');
    tx_tdata(63 downto 56)            <= SYNC_TAG;
    tx_tdata(BIT_VALID)               <= head(ENTRY_WIDTH - 1);
    tx_tdata(BIT_CREDIT)              <= head(ENTRY_WIDTH - 2);
    tx_tdata(io_bitwidth - 1 downto 0) <= head(io_bitwidth - 1 downto 0);
  end process tx_data_map;

  -- Sticky: the bridges cannot be told to retry, so a drop is data loss. It is
  -- recorded where the drop happens, in the write domain.
  overflow_proc : process (io_clk_in) is
  begin
    if rising_edge(io_clk_in) then
      if wr_rstn = '0' then
        overflow_wr <= '0';
      elsif fifo_push = '1' and fifo_accept = '0' then
        overflow_wr <= '1';
      end if;
    end if;
  end process overflow_proc;

  -- ...and brought into user_clk for the output. Safe with a plain two-flop
  -- synchroniser because a sticky bit only ever moves 0 -> 1.
  overflow_sync : process (user_clk) is
  begin
    if rising_edge(user_clk) then
      if user_rstn = '0' then
        overflow_meta <= '0';
        overflow_q    <= '0';
      else
        overflow_meta <= overflow_wr;
        overflow_q    <= overflow_meta;
      end if;
    end if;
  end process overflow_sync;

  -----------------------------------------------------------------------------
  -- RX: Aurora -> link event, straight through
  --
  -- No FIFO and no backpressure: streaming mode gives no m_axi_rx_tready, so
  -- every beat must be consumed the cycle it arrives. The bridge's own FIFOs
  -- absorb it, and the credit budget is what stops the far side overrunning
  -- them.
  -----------------------------------------------------------------------------
  rx_path : process (user_clk) is
  begin
    if rising_edge(user_clk) then
      if user_rstn = '0' then
        io_valid_out  <= '0';
        io_credit_out <= '0';
        io_data_out   <= (others => '0');
        sync_err_q    <= '0';
      else
        io_valid_out  <= '0';
        io_credit_out <= '0';

        if rx_tvalid = '1' and ready_int = '1' then
          if rx_tdata(63 downto 56) = SYNC_TAG then
            io_valid_out  <= rx_tdata(BIT_VALID);
            io_credit_out <= rx_tdata(BIT_CREDIT);
            io_data_out   <= rx_tdata(io_bitwidth - 1 downto 0);
          else
            -- Framing slip or a corrupt beat. Dropping is the only option --
            -- there is nowhere to push back to -- so record it instead.
            sync_err_q <= '1';
          end if;
        end if;
      end if;
    end if;
  end process rx_path;

  -- pragma translate_off
  assert io_bitwidth <= 16
    report "iolink_phy_aurora: io_bitwidth > 16 does not fit the wire format; widen DATA into the unused field"
    severity failure;
  assert 2 ** integer(ceil(log2(real(tx_fifo_depth)))) = tx_fifo_depth
    report "iolink_phy_aurora: tx_fifo_depth must be a power of 2 (it sizes a gray-code async FIFO)"
    severity failure;
  -- pragma translate_on

end architecture rtl;
