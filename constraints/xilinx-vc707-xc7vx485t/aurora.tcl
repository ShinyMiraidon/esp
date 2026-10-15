# Copyright (c) 2011-2026 Columbia University, System Level Design Group
# SPDX-License-Identifier: Apache-2.0
#
# Aurora 64B/66B core carrying the ESP I/O link over the VC707 SFP+ cage (P3).
#
# Imported by vivado/setup.tcl the same way sgmii.tcl is; see the aurora block
# in utils/make/vivado.mk. That block does "generate_target all [get_ips
# aurora]", so the module_name below must stay "aurora" and this file must not
# call generate_target itself.
#
# ---------------------------------------------------------------------------
# STATUS: VERIFIED against Vivado 2023.2 / aurora_64b66b v12.0
# ---------------------------------------------------------------------------
# The parameter dict below was produced by configuring the IP and exporting it
# with write_ip_tcl, so the names and values are the installed tool's own. Two
# corrections to the earlier hand-written version are worth calling out:
#
#   C_REFCLK_FREQUENCY must be the exact enum string {125.000}. The value {125}
#   is REJECTED outright -- "Value '125' is out of the range for parameter
#   C_REFCLK_FREQUENCY. Valid values are - 625.000, 520.833, 416.666, 390.625,
#   312.500, 260.416, 250.000, 208.333, 195.312, 156.250, 125.000".
#
#   Order matters inside the dict. Setting C_LINE_RATE resets C_REFCLK_FREQUENCY
#   to that rate's default (156.250), so the line rate must be set BEFORE the
#   reference frequency or the 125 MHz choice is silently reverted. The order
#   below is correct; do not alphabetise it.
#
# Confirmed legal: 6.25 Gb/s off a 125.000 MHz reference. Also legal from this
# reference are 1.25, 2.5, 3.125, 4.0, 5.0, 8.0 and 10.0 Gb/s; 6.5, 7.5 and
# 10.3125 are NOT (they force a different reference). Note the IP clamps this
# part at 10.3125 Gb/s, not the 12.5 quoted from the GTX datasheet.
#
# ---------------------------------------------------------------------------
# DESIGN INTENT
# ---------------------------------------------------------------------------
# Lanes            1. One SFP+ cage on this board, so one lane.
#
# Interface mode   Streaming, NOT framing. The I/O link is a continuous word
#                  stream with its own credit flow control; Aurora framing
#                  would add tlast/NFC semantics we do not need and cost
#                  latency. Streaming gives a plain AXI4-Stream.
#
# Line rate        6.25 Gb/s to start. Aurora is a proprietary link, so the
#                  rate is ours to choose. Raise it later if needed.
#
# Reference clock  125 MHz, shared with SGMII. See SHARED REFERENCE below.
#
# Init clock       50 MHz, matching BASE_FREQ_MHZ for this board.
#
# SupportLevel 1   Shared logic (MMCM, BUFGs, GT common/QPLL) lives in the core
#                  so ESP does not instantiate it. This makes user_clk an
#                  OUTPUT -- see CLOCKING below.
#
# SINGLEEND_*      Both set true, and this is what makes the core fit ESP:
#
#                  SINGLEEND_GTREFCLK swaps the gt_refclk1_p/n differential
#                  pair for a single refclk1_in. With the default (false) the
#                  core instantiates its OWN IBUFDS_GTE2 on the refclk pins --
#                  which would collide with the IBUFDS_GTE2 ESP already has on
#                  AH8/AH7 for SGMII. Feeding the buffered clock in instead
#                  lets one buffer serve both.
#
#                  SINGLEEND_INITCLK swaps init_clk_p/n for a single init_clk,
#                  because ESP's 50 MHz is an internal single-ended clock, not
#                  a differential pin pair.
#
# drp_mode Native  Exposes drpaddr_in/drpdi_in/drpen_in/drpwe_in/drpdo_out/
#                  drprdy_out rather than a full AXI4-Lite slave. We do no
#                  dynamic reconfiguration, so this is the smaller thing to
#                  tie off.
#
# ---------------------------------------------------------------------------
# CLOCKING -- user_clk is an OUTPUT
# ---------------------------------------------------------------------------
# At SupportLevel 1 the core owns the MMCM, so it SOURCES the user clock and
# the port is named user_clk_out (not user_clk). The top level takes it from
# the core and drives iolink_phy_aurora's user_clk input with it, which in turn
# drives the bridge's io_clk_in.
#
# For contrast, at SupportLevel 0 the port list has user_clk and sync_clk as
# INPUTS plus mmcm_not_locked and gt_qpllclk_quad1_in/gt_qpllrefclk_quad1_in,
# and the top level would have to build the MMCM and GT common itself.
#
# Reset outputs the top level should use rather than inventing its own:
#   sys_reset_out   user_clk-domain reset, active HIGH
#   gt_reset_out    init_clk-domain GT reset, active HIGH
#   link_reset_out  asserted when the link drops
# iolink_phy_aurora takes an active-LOW user_rstn, so invert sys_reset_out.
#
# ---------------------------------------------------------------------------
# PINS -- taken from the VC707 board file, not guessed
# ---------------------------------------------------------------------------
# The board file DOES expose an SFP interface, so board automation is possible,
# but these are the pins it resolves to (xilinx.com:vc707:part0:1.4):
#
#   sfp    RX  AL6 (p) / AL5 (n)        <- board pins sfp_rxp / sfp_rxn
#          TX  AM4 (p) / AM3 (n)        <- board pins sfp_sgmii_txp / _txn
#   refclk     AH8 (p) / AH7 (n)        <- board interface sgmii_mgt_clk
#
# No conflict with ESP's Ethernet: ESP's SGMII goes to the RJ45 Marvell PHY on
# AN2/AN1 (TX) and AM8/AM7 (RX) -- a different GTX channel. Only the 125 MHz
# reference at AH8/AH7 is shared, which is why SINGLEEND_GTREFCLK matters.
#
# GT placement (C_START_QUAD / C_GT_LOC_1 / C_COLUMN_USED) is deliberately left
# at the IP default here. The top-level sfp_* ports are constrained to the pins
# above in xilinx-vc707-xc7vx485t-sfp-pins.xdc and the placer resolves the
# channel from them, which has been confirmed on hardware.
#
# ---------------------------------------------------------------------------
# PORT LIST (aurora_64b66b v12.0, this configuration)
# ---------------------------------------------------------------------------
#   serial      rxp/rxn/txp/txn : STD_LOGIC_VECTOR(0 DOWNTO 0)
#   clocks in   refclk1_in, init_clk, drp_clk_in
#   clocks out  user_clk_out, sync_clk_out, tx_out_clk
#   control in  reset_pb, power_down, pma_init, loopback(2 DOWNTO 0),
#               gt_rxcdrovrden_in
#   status out  channel_up, lane_up(0 DOWNTO 0), hard_err, soft_err,
#               gt_pll_lock, mmcm_not_locked_out, link_reset_out,
#               sys_reset_out, gt_reset_out
#   TX stream   s_axi_tx_tdata(0 TO 63), s_axi_tx_tvalid, s_axi_tx_tready
#   RX stream   m_axi_rx_tdata(0 TO 63), m_axi_rx_tvalid   [no tready]
#   DRP         drpaddr_in(8:0), drpdi_in(15:0), drpen_in, drpwe_in,
#               drpdo_out(15:0), drprdy_out
#   QPLL out    gt_qpllclk_quad1_out, gt_qpllrefclk_quad1_out
#
# NOTE the AXI-Stream data ports are ASCENDING, (0 TO 63), while
# iolink_phy_aurora declares its tx_tdata/rx_tdata as (63 downto 0). A direct
# port map is CORRECT: VHDL associates leftmost-to-leftmost, so the PHY's bit
# 63 (the top of the SYNC tag) lands on Aurora's bit 0, which is the first bit
# on the wire. Both conventions put the most significant bit on the left. Do
# not "fix" this with an explicit reversal -- that would break it.
# ---------------------------------------------------------------------------

create_ip -name aurora_64b66b -vendor xilinx.com -library ip -version 12.0 -module_name aurora

set_property -dict [list \
                        CONFIG.C_AURORA_LANES {1} \
                        CONFIG.C_LINE_RATE {6.25} \
                        CONFIG.C_REFCLK_FREQUENCY {125.000} \
                        CONFIG.C_INIT_CLK {50} \
                        CONFIG.interface_mode {Streaming} \
                        CONFIG.dataflow_config {Duplex} \
                        CONFIG.SupportLevel {1} \
                        CONFIG.SINGLEEND_GTREFCLK {true} \
                        CONFIG.SINGLEEND_INITCLK {true} \
                        CONFIG.drp_mode {Native} \
                        CONFIG.C_USE_BYTESWAP {false} \
                       ] [get_ips aurora]
