#!/bin/bash
# Loopback testbench for the I/O link over Aurora: initiator (ahbslv2iolink)
# -> PHY -> channel model -> PHY -> target (iolink2ahbm) -> AHB memory.
# Uses xsim only (no license needed, runs under the strict sandbox).
#
# Needs a generated vivado/srcs.tcl for the board (run the Vivado setup once).
#   ./run.sh /path/to/esp/socs/xilinx-vc707-xc7vx485t [workdir]
#
# EXPECTED RESULT: "mismatches : 0", 64/64 writes and reads, no overflow or
# sync error. If phase 1 completes and phase 2 ends in WATCHDOG, iolink2ahbm's
# credit counter came out of reset at 0 and the target can never send a read
# reply: its reset must be asynchronous, because on the board user_clk is
# stopped for as long as the SoC is held in reset.
# Knobs at the top of tb_iolink_loopback.vhd: HWDATA_EARLY selects the master's
# write-data style (false = AHB-compliant like noc2ahbmst, true = GRLIB DMA like
# the FPGA proxy's masters), XFER_GAP the idle cycles between transfers, and
# USER_CLK_IN_RESET whether user_clk runs during reset (false = as on the board).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
BOARD=${1:?usage: $0 <board-dir> [workdir]}
W=${2:-${TMPDIR:-/tmp}/iolink_loopback}
mkdir -p "$W" && cd "$W"
grep '^read_vhdl' "$BOARD/vivado/srcs.tcl" | sed 's/^read_vhdl //' | grep -v NV_NVDLA > files.f
echo "$HERE/aurora_channel_model.vhd" >> files.f
echo "$HERE/tb_iolink_loopback.vhd"   >> files.f
xvhdl -f files.f && xelab work.tb_iolink_loopback -s lb && xsim lb -runall
