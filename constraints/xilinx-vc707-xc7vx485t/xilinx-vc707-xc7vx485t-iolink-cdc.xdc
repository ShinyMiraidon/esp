# Copyright (c) 2011-2026 Columbia University, System Level Design Group
# SPDX-License-Identifier: Apache-2.0
#
# Clock-domain crossings of the ESP I/O link over Aurora 64B/66B. Read when
# CONFIG_IOLINK_EN is set (see utils/make/vivado.mk).
#
# Aurora's user_clk (user_clk_i, 97.66 MHz, recovered from the transceiver) is
# unrelated to the SoC clocks it meets: the tile clock clk_nobuf (50 MHz) and
# clk_pll_i (100 MHz), which also clocks the SoC reset. Every path between them
# is built as a crossing:
#
#   - data and pointers go through gray-code async FIFOs (inferred_async_fifo),
#     whose memory is written before the pointer that exposes it is updated;
#   - single-bit status goes through two-flop synchronisers (ASYNC_REG);
#   - the SoC reset reaches link-clock logic only through reset synchronisers
#     in the bridges, which assert asynchronously and release on the link
#     clock.
#
# Without these constraints Vivado times the crossings as if the clocks were
# related, finds edges 0.08-0.16 ns apart, and reports hundreds of violations
# no route could meet; they also pull placement effort away from real paths.
#
# Bound each crossing's datapath instead of cutting it. 10 ns is under one
# user_clk period (10.24 ns), so the bits of a gray pointer cannot skew by a
# whole destination cycle, and FIFO data, written before its pointer moves,
# has settled long before that pointer clears the destination's two-flop
# synchroniser. -datapath_only removes clock skew from the check and does not
# time hold on these paths. It also covers recovery checks, i.e. the reset
# assertion paths into the reset synchronisers.

set_max_delay -datapath_only -from [get_clocks clk_nobuf]  -to [get_clocks user_clk_i] 10.000
set_max_delay -datapath_only -from [get_clocks user_clk_i] -to [get_clocks clk_nobuf]  10.000
set_max_delay -datapath_only -from [get_clocks clk_pll_i]  -to [get_clocks user_clk_i] 10.000
set_max_delay -datapath_only -from [get_clocks user_clk_i] -to [get_clocks clk_pll_i]  10.000
