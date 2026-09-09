# Copyright (c) 2011-2026 Columbia University, System Level Design Group
# SPDX-License-Identifier: Apache-2.0
#
# Aurora 64B/66B core carrying the ESP I/O link over the VC707 SFP+ cage (P3).
#
# Imported by vivado/setup.tcl the same way sgmii.tcl is; see the aurora block
# in utils/make/vivado.mk.
#
# ---------------------------------------------------------------------------
# BEFORE FIRST USE
# ---------------------------------------------------------------------------
# This file has NOT been run through Vivado. Aurora has a large parameter set
# whose names drift between IP versions, so treat the dict below as a starting
# point, not as verified. The robust workflow is:
#
#   1. Open the ESP Vivado project for this board (make vivado-syn once, or
#      vivado -mode gui on socs/xilinx-vc707-xc7vx485t/vivado/).
#   2. Customize "Aurora 64B66B" in the IP catalog to match the intent below.
#   3. Export it and replace this file:
#        write_ip_tcl -force [get_ips aurora] aurora.tcl
#
# That guarantees the parameter names match the installed Vivado, and keeps
# this file as the single source of truth afterwards.
#
# ---------------------------------------------------------------------------
# DESIGN INTENT (the part that is decided, not guessed)
# ---------------------------------------------------------------------------
# Lanes            1. One SFP+ cage on this board, so one lane. The VC707 has
#                  exactly one GTX wired to P3 (of 27 total: 8 PCIe, 8 FMC1,
#                  8 FMC2, 1 SMA, 1 SFP, 1 SGMII -- see UG885).
#
# Interface mode   Streaming, NOT framing. The I/O link is a continuous word
#                  stream with its own credit flow control; Aurora framing
#                  would add tlast/NFC semantics we do not need and cost
#                  latency. Streaming gives a plain AXI4-Stream.
#
# Line rate        6.25 Gb/s to start. Aurora is a proprietary link, so the
#                  rate is ours to choose -- it does not have to be a standard
#                  10GBASE-R rate. 6.25 falls cleanly out of the 125 MHz
#                  reference clock already present in this design and keeps
#                  first bring-up conservative. Raise it once the link is up;
#                  GTX on the -2 part goes to 12.5 Gb/s.
#
# Reference clock  125 MHz, shared with SGMII, no cross-quad routing needed.
#                  Per UG885, GTX Quad 113 holds three used channels -- one
#                  each to the SMA pair, to SGMII, and to the SFP+ cage -- plus
#                  one unused. So Aurora and SGMII sit in the SAME quad, and
#                  ESP's existing reference at gtrefclk_p/n (AH8/AH7, bank 113,
#                  see the eth-pins XDC and sgmii.xci) already reaches the SFP
#                  channel directly. A GTX quad has one QPLL plus a CPLL per
#                  channel, so SGMII at 1.25 Gb/s and Aurora at 6.25 Gb/s run
#                  on separate PLLs off that one reference. No Si5324 I2C
#                  bring-up is required. Fallback references, if ever needed:
#                  the SMA input (AK8/AK7, also quad 113) or the Si5324 output
#                  (AD8/AD7, quad 114, reachable via +/-1 quad routing).
#
#                  Note the quad also has one spare GTX channel, which is where
#                  a second Aurora lane would go if this ever needs more than
#                  one -- though the board has only the one SFP cage, so a
#                  second lane would have to leave via SMA or FMC.
#
# Init clock       50 MHz, matching BASE_FREQ_MHZ for this board.
#
# DRP / SupportLevel  No dynamic reconfiguration; include the shared logic in
#                  the core so ESP does not have to instantiate the GT common
#                  block itself.
#
# ---------------------------------------------------------------------------
# NOT SET HERE, ON PURPOSE
# ---------------------------------------------------------------------------
# GT placement and the SFP pin constraints are left to board automation. The
# project sets board_part from PROTOBOARD (xilinx.com:vc707:part0:1.4) in
# vivado/setup.tcl, so the SFP interface can be selected from the board
# definition rather than pinned by hand. That matters because the VC707 master
# XDC is the only authoritative source for the P3 TX/RX package pins, and
# guessing them would be worse than letting the board file resolve it. If
# board automation turns out not to expose the SFP interface on this board
# file version, add an explicit sfp-pins XDC with pins taken from the AMD
# VC707 master XDC (UG885 appendix C) -- do not infer them.

create_ip -name aurora_64b66b -vendor xilinx.com -library ip -module_name aurora

set_property -dict [list \
                        CONFIG.C_AURORA_LANES {1} \
                        CONFIG.C_LINE_RATE {6.25} \
                        CONFIG.C_REFCLK_FREQUENCY {125} \
                        CONFIG.C_INIT_CLK {50} \
                        CONFIG.interface_mode {Streaming} \
                        CONFIG.dataflow_config {Duplex} \
                        CONFIG.SupportLevel {1} \
                        CONFIG.drp_mode {Native} \
                        CONFIG.C_USE_BYTESWAP {false} \
                       ] [get_ips aurora]
