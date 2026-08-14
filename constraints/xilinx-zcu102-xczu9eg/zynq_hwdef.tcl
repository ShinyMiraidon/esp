# Copyright (c) 2011-2026 Columbia University, System Level Design Group
# SPDX-License-Identifier: Apache-2.0

set arg_count [llength $argv]
if {$arg_count < 4} {
    set usage "Usage: zynq_hwdef.tcl <project_dir> <output_hwdef> <zynq_bd_tcl> <axi_data_width>"
    set received [join $argv "\n  "]
    error "$usage\nReceived $arg_count arguments:\n  $received"
}
if {$arg_count > 4} {
    # Some Vivado 2019.2 launchers append JVM workarounds (for example the
    # AR72614 -patch-module option) to Tcl's argv after user -tclargs.
    puts "INFO: ignoring [expr {$arg_count - 4}] trailing Vivado launcher arguments"
}

set hwdef_args [lrange $argv 0 3]
set project_dir [file normalize [lindex $hwdef_args 0]]
set output_hwdef [file normalize [lindex $hwdef_args 1]]
set zynq_bd_tcl [file normalize [lindex $hwdef_args 2]]
set axi_data_width [lindex $hwdef_args 3]

if {![file isfile $zynq_bd_tcl] || ![file readable $zynq_bd_tcl]} {
    error "Zynq block-design script is not readable: $zynq_bd_tcl"
}
if {[lsearch -exact {32 64} $axi_data_width] < 0} {
    error "Unsupported AXI data width '$axi_data_width' (expected 32 or 64)"
}

proc latest_board_part {pattern} {
    set board_parts [get_board_parts -quiet $pattern]
    if {[llength $board_parts] == 0} {
        error "No Vivado board part found matching $pattern"
    }
    return [lindex [lsort -dictionary $board_parts] end]
}

file mkdir $project_dir
file mkdir [file dirname $output_hwdef]

create_project zcu102_ps_handoff $project_dir \
    -part xczu9eg-ffvb1156-2-e -force
set board_part [latest_board_part {xilinx.com:zcu102:part0:*}]
puts "INFO: using board part $board_part"
set_property board_part $board_part [current_project]

# The board script expects the ESP AXI data width in argv.
set argv [list $axi_data_width]
set argc [llength $argv]
source $zynq_bd_tcl

set bd_file [get_files -quiet */zynqmpsoc.bd]
if {[llength $bd_file] != 1} {
    error "Expected one zynqmpsoc block design, found [llength $bd_file]"
}

generate_target all $bd_file
write_hwdef -force -file $output_hwdef
close_project
