# Copyright (c) 2011-2026 Columbia University, System Level Design Group
# SPDX-License-Identifier: Apache-2.0
# Configure ZYNQ MP SoC block with native AXI memory and AXI-to-AHB-L host access

set AXIDW [lindex $argv 0]

proc latest_ip_vlnv {pattern} {
	set ipdefs [get_ipdefs -all $pattern]
	if {[llength $ipdefs] == 0} {
		error "No Vivado IP found matching $pattern"
	}
	return [lindex [lsort -dictionary $ipdefs] end]
}

# Create block design
create_bd_design "zynqmpsoc"

# ZYNQ MP SoC PS
set zynqmp_vlnv [latest_ip_vlnv {xilinx.com:ip:zynq_ultra_ps_e:*}]
puts "INFO: using $zynqmp_vlnv"
create_bd_cell -type ip -vlnv $zynqmp_vlnv zynq_ultra_ps_e_0
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1" }  [get_bd_cells zynq_ultra_ps_e_0]
set_property -dict [list \
				CONFIG.PSU__PSS_REF_CLK__FREQMHZ {33.333333} \
				CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
				CONFIG.PSU__USE__S_AXI_GP0 {1} \
				CONFIG.PSU__SAXIGP0__DATA_WIDTH $AXIDW \
				CONFIG.PSU__USE__M_AXI_GP1 {0} \
				CONFIG.PSU__USE__IRQ0 {0} \
				CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {75} \
		       ] [get_bd_cells zynq_ultra_ps_e_0]

# AXI-to-AHB-L
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahblite_bridge_0
connect_bd_intf_net [get_bd_intf_pins axi_ahblite_bridge_0/AXI4] [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD]
set_property -dict [list \
			CONFIG.C_S_AXI_SUPPORTS_NARROW_BURST {1} \
		       ] [get_bd_cells axi_ahblite_bridge_0]
make_bd_intf_pins_external  [get_bd_intf_pins axi_ahblite_bridge_0/M_AHB]

# Native AXI memory interface from ESP to PS-side DDR.
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 DDR_AXI
set_property -dict [list \
				CONFIG.PROTOCOL {AXI4} \
				CONFIG.ADDR_WIDTH {49} \
				CONFIG.DATA_WIDTH $AXIDW \
				CONFIG.FREQ_HZ {75000000} \
				CONFIG.HAS_BURST {1} \
				CONFIG.HAS_LOCK {1} \
				CONFIG.HAS_CACHE {1} \
				CONFIG.HAS_PROT {1} \
				CONFIG.HAS_QOS {1} \
				CONFIG.HAS_REGION {0} \
				CONFIG.HAS_WSTRB {1} \
				CONFIG.HAS_BRESP {1} \
				CONFIG.HAS_RRESP {1} \
			       ] [get_bd_intf_ports DDR_AXI]
connect_bd_intf_net [get_bd_intf_ports DDR_AXI] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HPC0_FPD]

# Connect clock and reset
apply_bd_automation -rule xilinx.com:bd_rule:clkrst -config { Clk {/zynq_ultra_ps_e_0/pl_clk0 (75 MHz)} Freq {75} Ref_Clk0 {} Ref_Clk1 {} Ref_Clk2 {}}  [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk]
apply_bd_automation -rule xilinx.com:bd_rule:clkrst -config { Clk {/zynq_ultra_ps_e_0/pl_clk0 (75 MHz)} Freq {75} Ref_Clk0 {} Ref_Clk1 {} Ref_Clk2 {}}  [get_bd_pins zynq_ultra_ps_e_0/saxihpc0_fpd_aclk]
make_bd_pins_external  [get_bd_pins rst_ps8_0_75M/peripheral_reset]
create_bd_port -dir O -type clk pl_clk0
connect_bd_net [get_bd_pins /zynq_ultra_ps_e_0/pl_clk0] [get_bd_ports pl_clk0]
set_property CONFIG.ASSOCIATED_BUSIF {DDR_AXI} [get_bd_ports pl_clk0]

# Map address space A53 Master, ESP slave (4GB)
assign_bd_address [get_bd_addr_segs {M_AHB_0/Reg }]
set_property offset 0x0400000000 [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_M_AHB_0_Reg}]
set_property range 4G [get_bd_addr_segs {zynq_ultra_ps_e_0/Data/SEG_M_AHB_0_Reg}]

# Map address space ESP Master, PS-side DDR4 Slave (1GB)
exclude_bd_addr_seg [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP0/HPC0_DDR_HIGH] -target_address_space [get_bd_addr_spaces DDR_AXI]
exclude_bd_addr_seg [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP0/HPC0_LPS_OCM] -target_address_space [get_bd_addr_spaces DDR_AXI]
exclude_bd_addr_seg [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP0/HPC0_PCIE_LOW] -target_address_space [get_bd_addr_spaces DDR_AXI]
exclude_bd_addr_seg [get_bd_addr_segs zynq_ultra_ps_e_0/SAXIGP0/HPC0_QSPI] -target_address_space [get_bd_addr_spaces DDR_AXI]
assign_bd_address [get_bd_addr_segs {zynq_ultra_ps_e_0/SAXIGP0/HPC0_DDR_LOW }]
set_property offset 0x00000000 [get_bd_addr_segs {DDR_AXI/SEG_zynq_ultra_ps_e_0_HPC0_DDR_LOW}]
set_property range 2G [get_bd_addr_segs {DDR_AXI/SEG_zynq_ultra_ps_e_0_HPC0_DDR_LOW}]

# Dummy GPIO device connected to dip switches (workaroud for bug in generating device tree)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0
apply_bd_automation -rule xilinx.com:bd_rule:board -config { Board_Interface {dip_switches_8bits ( DIP switches ) } Manual_Source {Auto}}  [get_bd_intf_pins axi_gpio_0/GPIO]
set_property location {3 681 -15} [get_bd_cells axi_gpio_0]
set_property -dict [list CONFIG.PSU__USE__M_AXI_GP1 {1} CONFIG.PSU__MAXIGP1__DATA_WIDTH {32}] [get_bd_cells zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/zynq_ultra_ps_e_0/M_AXI_HPM1_FPD} Slave {/axi_gpio_0/S_AXI} ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}}  [get_bd_intf_pins axi_gpio_0/S_AXI]


# Save
save_bd_design
close_bd_design [get_bd_designs zynqmpsoc]
