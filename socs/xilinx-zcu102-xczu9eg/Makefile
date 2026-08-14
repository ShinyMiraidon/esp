# Copyright (c) 2011-2026 Columbia University, System Level Design Group
# SPDX-License-Identifier: Apache-2.0
##########################
### ESP Local Makefile ###
##########################

all: help

### Global design variables ###
DESIGN_PATH = $(PWD)
ESP_ROOT = $(realpath ../../)
TECHLIB  = virtexup
BOARD    = xilinx-zcu102-xczu9eg
DESIGN   = esp-$(BOARD)
SMP = 0
BASE_FREQ_MHZ ?= 75
LEON3_STACK ?= 0x5bfffff0
USE_OPENSBI ?= 1

### Design top level and testbench ###

## The ZYNQ wrapper should instantiate the ESP top module (top.vhd) and forward DDR4 and UART to the FPGA pins.
## In addition, the wrapper will instantiate the ZYNQ MP SoC processing system and connect it to ESP.
## This wrapper cannot be simulated, because it would require a model of the ZYNQ
TOP    = zynqmp_top_wrapper

## Simulation is not available for ZYNQ, but use `make sim` to elaborate and check connectivity of the ESP top module
SIMTOP = testbench


### Modelsim Simulation Options ###

# Compile flags
# VHDL-93 is required by some GRLIB source files
VCOMOPT += -93
VLOGOPT +=

XCOMOPT +=
XLOGOPT +=

VSIMOPT +=


### Additional design files ###
TOP_VHDL_RTL_PKGS +=
TOP_VHDL_RTL_SRCS += $(DESIGN_PATH)/top.vhd
TOP_VLOG_RTL_SRCS +=
TOP_VHDL_SIM_PKGS +=
TOP_VHDL_SIM_SRCS +=
TOP_VLOG_SIM_SRCS +=

### Xilinx Vivado hw_server ###
FPGA_HOST ?= localhost
XIL_HW_SERVER_PORT ?= 3121


# IP address or host name of the host connected to the FPGA
UART_IP ?=
UART_PORT ?=

# SSH IP address or host name of the ESP Linux instance or gateway
SSH_IP ?=
SSH_PORT ?= 22

# ESPLink IP address or gateway (DO NOT USE HOST NAME)
ESPLINK_IP ?=
ESPLINK_PORT ?= 46392

# ZCU102 PS Linux host used by the Zynq PS fpga-run backend.
# ZYNQ_PS_HOST may include a user, for example root@zcu102-ps.
# If no user is included, root is used by default.
ZYNQ_PS_HOST ?=
ZYNQ_PS_USER ?= root
ZYNQ_PS_SSH_PORT ?= $(SSH_PORT)
ZYNQ_PS_RUN_DIR ?= .
ZYNQ_PS_SSH_RUN_OPTS ?= -tt
ZYNQ_PS_SUDO ?=
ZYNQ_PS_PEEK ?= ./esp_peek
ZYNQ_PS_LOADER ?= ./esp_load_bootrom_zynq
ZYNQ_PS_LOADER_CPU ?= $(CPU_ARCH)
ZYNQ_PS_DRAM_PATH ?= esp
ZYNQ_PS_LOADER_OPTS ?= --cpu $(ZYNQ_PS_LOADER_CPU) $(ZYNQ_PS_DRAM_PATH_OPTS)
ZYNQ_PS_WAKE_ADDR_ariane ?= 0x0460090384
ZYNQ_PS_WAKE_ADDR_ibex ?= 0x0460090384
ZYNQ_PS_WAKE_ADDR_leon3 ?= 0x0480090384
ZYNQ_PS_WAKE_ADDR_AUTO = $(ZYNQ_PS_WAKE_ADDR_$(ZYNQ_PS_LOADER_CPU))
ZYNQ_PS_WAKE_ADDR ?= $(if $(strip $(ZYNQ_PS_WAKE_ADDR_AUTO)),$(ZYNQ_PS_WAKE_ADDR_AUTO),0x0460090384)

# MAC address for Linux if using IP address reservation (e.g. 00aabb33cc77)
# LINUX_MAC ?=


### Include global Makefile ###
include $(ESP_ROOT)/utils/Makefile
