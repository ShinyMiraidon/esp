# Copyright (c) 2011-2026 Columbia University, System Level Design Group
# SPDX-License-Identifier: Apache-2.0

#-----------------------------------------------------------
#   SFP+ cage (P3) - ESP I/O link over Aurora 64B/66B       -
#-----------------------------------------------------------
# Pins taken from the VC707 board definition file
# (xilinx.com:vc707:part0:1.4), which is derived from the AMD VC707 master
# XDC -- not inferred. The board file exposes these as the "sfp" interface:
#
#   sfp_rxp / sfp_rxn               -> AL6 / AL5
#   sfp_sgmii_txp / sfp_sgmii_txn   -> AM4 / AM3
#
# The TX pins carry "sgmii" in their board-file names because the cage can
# alternatively be driven by an SGMII core; they are the SFP+ cage's TX pair.
# ESP's own SGMII goes to the RJ45 Marvell PHY on AN2/AN1 + AM8/AM7, so there
# is no conflict -- only the 125 MHz reference at AH8/AH7 is shared, and that
# buffer is shared in RTL out of sgmii_vc707.
#
# No IOSTANDARD: these are GTX serial pins, not I/O-bank pins.

set_property PACKAGE_PIN AM4 [get_ports sfp_txp]
set_property PACKAGE_PIN AM3 [get_ports sfp_txn]
set_property PACKAGE_PIN AL6 [get_ports sfp_rxp]
set_property PACKAGE_PIN AL5 [get_ports sfp_rxn]

#-----------------------------------------------------------
#   SFP+ module control (UG885 Table 1-15 / 1-16, App. C)   -
#-----------------------------------------------------------
# These are real FPGA pins, not board-only signals:
#
#   SFP_TX_DISABLE  AP33  out  active HIGH -- the module does NOT transmit
#                                unless this is driven low
#   SFP_LOS_LS      BB38  in   active HIGH -- no optical signal received
#
# Leaving TX_DISABLE unconstrained happened to work only because Vivado
# defaults unused pins to PULLDOWN; driving it explicitly removes that
# dependence on a tool default.
#
# Not under FPGA control, and all three must be right for the cage to work:
#   J6  "SFP Enable"  jumper OFF = SFP disabled, ON = SFP enabled
#   J38 (SFP_RS0)     pins 1-2 = full RX bandwidth, 2-3 = reduced
#   J39 (SFP_RS1)     pins 1-2 = full TX bandwidth, 2-3 = reduced

set_property PACKAGE_PIN AP33 [get_ports sfp_tx_disable]
set_property IOSTANDARD LVCMOS18 [get_ports sfp_tx_disable]
set_property PACKAGE_PIN BB38 [get_ports sfp_los]
set_property IOSTANDARD LVCMOS18 [get_ports sfp_los]
