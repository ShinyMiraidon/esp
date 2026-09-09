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
-- This module has not been simulated or synthesised. It was written without a
-- toolchain available; review the reset sequencing and the channel_up gating
-- against a real elaboration before trusting it.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;


entity iolink_phy_aurora is
  generic (
    io_bitwidth : integer range 1 to 16 := 16;
    -- Elasticity for Aurora clock-compensation gaps. 32 is generous for a
    -- single lane; raise it if tx_overflow is ever observed.
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
    io_valid_out : out std_ulogic;
    io_credit_out : out std_ulogic;
    io_data_out  : out std_logic_vector(io_bitwidth - 1 downto 0);
    io_valid_in  : in  std_ulogic;
    io_credit_in : in  std_ulogic;
    io_data_in   : in  std_logic_vector(io_bitwidth - 1 downto 0);
    -- Diagnostics. link_ready gates the bridge; the error bits are sticky.
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

  type fifo_array is array (0 to tx_fifo_depth - 1) of std_logic_vector(ENTRY_WIDTH - 1 downto 0);

  signal fifo      : fifo_array;
  signal wr_ptr    : integer range 0 to tx_fifo_depth - 1;
  signal rd_ptr    : integer range 0 to tx_fifo_depth - 1;
  signal count     : integer range 0 to tx_fifo_depth;
  signal fifo_push : std_ulogic;
  signal fifo_pop  : std_ulogic;
  signal head      : std_logic_vector(ENTRY_WIDTH - 1 downto 0);

  signal overflow_q : std_ulogic;
  signal sync_err_q : std_ulogic;
  signal ready_int  : std_ulogic;

begin

  -- The bridge is clocked by the Aurora user clock; see the note above about
  -- iolink2ahbm looping io_clk_in straight back out.
  io_clk_out <= user_clk;

  ready_int  <= channel_up and lane_up and (not hard_err);
  link_ready <= ready_int;

  tx_overflow <= overflow_q;
  rx_sync_err <= sync_err_q;

  -----------------------------------------------------------------------------
  -- TX: link event -> elastic FIFO -> Aurora
  -----------------------------------------------------------------------------
  fifo_push <= (io_valid_in or io_credit_in) and ready_int;
  fifo_pop  <= '1' when (count /= 0 and tx_tready = '1') else '0';
  head      <= fifo(rd_ptr);

  tx_tvalid <= '1' when count /= 0 else '0';

  tx_data_map : process (head) is
  begin
    tx_tdata <= (others => '0');
    tx_tdata(63 downto 56)            <= SYNC_TAG;
    tx_tdata(BIT_VALID)               <= head(ENTRY_WIDTH - 1);
    tx_tdata(BIT_CREDIT)              <= head(ENTRY_WIDTH - 2);
    tx_tdata(io_bitwidth - 1 downto 0) <= head(io_bitwidth - 1 downto 0);
  end process tx_data_map;

  tx_fifo : process (user_clk) is
  begin
    if rising_edge(user_clk) then
      if user_rstn = '0' then
        wr_ptr     <= 0;
        rd_ptr     <= 0;
        count      <= 0;
        overflow_q <= '0';
      else
        if fifo_push = '1' and count /= tx_fifo_depth then
          fifo(wr_ptr) <= io_valid_in & io_credit_in & io_data_in;
          if wr_ptr = tx_fifo_depth - 1 then wr_ptr <= 0; else wr_ptr <= wr_ptr + 1; end if;
        end if;

        if fifo_pop = '1' then
          if rd_ptr = tx_fifo_depth - 1 then rd_ptr <= 0; else rd_ptr <= rd_ptr + 1; end if;
        end if;

        if fifo_push = '1' and fifo_pop = '0' and count /= tx_fifo_depth then
          count <= count + 1;
        elsif fifo_push = '0' and fifo_pop = '1' then
          count <= count - 1;
        end if;

        -- Sticky: the bridges cannot be told to retry, so a drop is data loss.
        if fifo_push = '1' and count = tx_fifo_depth then
          overflow_q <= '1';
        end if;
      end if;
    end if;
  end process tx_fifo;

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
  -- pragma translate_on

end architecture rtl;
