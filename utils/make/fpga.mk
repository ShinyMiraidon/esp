# Copyright (c) 2011-2026 Columbia University, System Level Design Group
# SPDX-License-Identifier: Apache-2.0

ZYNQ_PS_FPGA_BOARDS = xilinx-zcu102-xczu9eg xilinx-zcu106-xczu7ev

ifneq ($(findstring profpga, $(BOARD)),)
fpga-program: profpga-prog-fpga
	$(QUIET_INFO) echo "Waiting for DDR calibration..."
	@sleep 5

fpga-program-emu: profpga-prog-fpga-emu
	$(QUIET_INFO) echo "Waiting for DDR calibration..."
	@sleep 5
else ifneq ($(filter $(BOARD),$(ZYNQ_PS_FPGA_BOARDS)),)
fpga-program: zynq-jtag-boot
else
fpga-program: vivado-prog-fpga
	$(QUIET_INFO) echo "Waiting for DDR calibration..."
	@sleep 5
endif


ifneq ($(filter $(BOARD),$(ZYNQ_PS_FPGA_BOARDS)),)

ZYNQ_PS_HOST ?=
ifeq ($(strip $(ZYNQ_PS_HOST)),)
ZYNQ_PS_HOST := $(if $(strip $(SSH_IP)),$(SSH_IP),$(PS_HOST))
endif
ZYNQ_PS_USER ?= root
ZYNQ_PS_SSH_PORT ?= $(if $(strip $(SSH_PORT)),$(SSH_PORT),22)
ZYNQ_PS_RUN_DIR ?= .
ZYNQ_PS_SSH_OPTS ?= -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
ZYNQ_PS_SSH_RUN_OPTS ?= -tt
ZYNQ_PS_SSH_TARGET = $(if $(strip $(ZYNQ_PS_HOST)),$(if $(findstring @,$(ZYNQ_PS_HOST)),$(ZYNQ_PS_HOST),$(if $(strip $(ZYNQ_PS_USER)),$(ZYNQ_PS_USER)@$(ZYNQ_PS_HOST),$(ZYNQ_PS_HOST))))
ZYNQ_PS_SSH = ssh -q $(ZYNQ_PS_SSH_OPTS) -p $(ZYNQ_PS_SSH_PORT) $(ZYNQ_PS_SSH_TARGET)
ZYNQ_PS_SSH_RUN = ssh -q $(ZYNQ_PS_SSH_OPTS) $(ZYNQ_PS_SSH_RUN_OPTS) -p $(ZYNQ_PS_SSH_PORT) $(ZYNQ_PS_SSH_TARGET)
ZYNQ_PS_SCP = scp -q $(ZYNQ_PS_SSH_OPTS) -P $(ZYNQ_PS_SSH_PORT)
ZYNQ_PS_SUDO ?=
ZYNQ_PS_PEEK ?= ./esp_peek
ZYNQ_PS_LOADER ?= ./esp_load_bootrom_zynq
ZYNQ_PS_LOADER_CPU ?= $(CPU_ARCH)
ZYNQ_PS_DRAM_PATH ?= esp
ZYNQ_PS_DRAM_PATH_OPTS_ps-ddr = --dram-via-ps-ddr
ZYNQ_PS_DRAM_PATH_OPTS_esp = --dram-via-esp
ZYNQ_PS_DRAM_PATH_OPTS = $(ZYNQ_PS_DRAM_PATH_OPTS_$(ZYNQ_PS_DRAM_PATH))
ZYNQ_PS_LOADER_OPTS ?= --cpu $(ZYNQ_PS_LOADER_CPU) $(ZYNQ_PS_DRAM_PATH_OPTS)
ZYNQ_PS_WAKE_ADDR_ariane ?= 0x0460090384
ZYNQ_PS_WAKE_ADDR_ibex ?= 0x0460090384
ZYNQ_PS_WAKE_ADDR_leon3 ?= 0x0480090384
ZYNQ_PS_WAKE_ADDR_AUTO = $(ZYNQ_PS_WAKE_ADDR_$(ZYNQ_PS_LOADER_CPU))
ZYNQ_PS_WAKE_ADDR ?= $(if $(strip $(ZYNQ_PS_WAKE_ADDR_AUTO)),$(ZYNQ_PS_WAKE_ADDR_AUTO),0x0460090384)

define zynq_ps_run_payload
	@if ! command -v ssh >/dev/null 2>&1; then \
		echo $(SPACES)"ERROR: ssh not found in PATH"; \
		false; \
	fi
	@if ! command -v scp >/dev/null 2>&1; then \
		echo $(SPACES)"ERROR: scp not found in PATH"; \
		false; \
	fi
	@test -n "$(ZYNQ_PS_HOST)" || { echo $(SPACES)"ERROR: set ZYNQ_PS_HOST, SSH_IP, or PS_HOST to the Zynq PS Linux host"; false; }
	@test -n "$(ZYNQ_PS_DRAM_PATH_OPTS)" || { echo $(SPACES)"ERROR: invalid ZYNQ_PS_DRAM_PATH='$(ZYNQ_PS_DRAM_PATH)' (expected ps-ddr or esp)"; false; }
	@test -r $(SOFT_BUILD)/prom.bin || { echo $(SPACES)"ERROR: bootrom not found: $(SOFT_BUILD)/prom.bin. Run 'make soft' first."; false; }
	@test -r $1 || { echo $(SPACES)"ERROR: payload not found: $1"; false; }
	@$(ZYNQ_PS_SSH) "mkdir -p $(ZYNQ_PS_RUN_DIR)"
	@$(ZYNQ_PS_SCP) $(SOFT_BUILD)/prom.bin $1 $(ZYNQ_PS_SSH_TARGET):$(ZYNQ_PS_RUN_DIR)/
	@$(ZYNQ_PS_SSH_RUN) "cd $(ZYNQ_PS_RUN_DIR) && $(ZYNQ_PS_SUDO) $(ZYNQ_PS_PEEK) $(ZYNQ_PS_WAKE_ADDR) >/dev/null && $(ZYNQ_PS_SUDO) $(ZYNQ_PS_PEEK) $(ZYNQ_PS_WAKE_ADDR) >/dev/null && $(ZYNQ_PS_SUDO) $(ZYNQ_PS_LOADER) prom.bin $(ZYNQ_PS_LOADER_OPTS) --dram-image $(notdir $1)"
endef

fpga-run: soft
	$(call zynq_ps_run_payload,$(SOFT_BUILD)/systest.bin)

fpga-run-linux: soft
	$(call zynq_ps_run_payload,$(SOFT_BUILD)/linux.bin)

fpga-run-proxy fpga-run-iolink fpga-run-linux-proxy fpga-run-linux-iolink fpga-run-jtag:
	@echo $(SPACES)"ERROR: $@ is not supported by the Zynq PS loader backend"
	@false

else

fpga-run: esplink soft
	@./$(ESP_CFG_BUILD)/esplink --reset
	@./$(ESP_CFG_BUILD)/esplink --brom -i $(SOFT_BUILD)/prom.bin
	@./$(ESP_CFG_BUILD)/esplink --dram -i $(SOFT_BUILD)/systest.bin
	@./$(ESP_CFG_BUILD)/esplink --reset

fpga-run-linux: esplink soft
	@./$(ESP_CFG_BUILD)/esplink --reset
	@./$(ESP_CFG_BUILD)/esplink --brom -i $(SOFT_BUILD)/prom.bin
	@./$(ESP_CFG_BUILD)/esplink --dram -i $(SOFT_BUILD)/linux.bin
	@./$(ESP_CFG_BUILD)/esplink --reset

fpga-run-proxy: esplink esplink-fpga-proxy soft
	@./$(ESP_CFG_BUILD)/esplink --reset
	@./$(ESP_CFG_BUILD)/esplink --brom -i $(SOFT_BUILD)/prom.bin
	@./$(ESP_CFG_BUILD)/esplink-fpga-proxy --dram -i $(SOFT_BUILD)/systest.bin
	@./$(ESP_CFG_BUILD)/esplink --reset

fpga-run-iolink: esplink esplink-fpga-proxy soft
	@./$(ESP_CFG_BUILD)/esplink-fpga-proxy --reset
	@./$(ESP_CFG_BUILD)/esplink-fpga-proxy --brom -i $(SOFT_BUILD)/prom.bin
	@./$(ESP_CFG_BUILD)/esplink-fpga-proxy --dram -i $(SOFT_BUILD)/systest.bin
	@./$(ESP_CFG_BUILD)/esplink-fpga-proxy --reset

fpga-run-linux-proxy: esplink esplink-fpga-proxy soft
	@./$(ESP_CFG_BUILD)/esplink --reset
	@./$(ESP_CFG_BUILD)/esplink --brom -i $(SOFT_BUILD)/prom.bin
	@./$(ESP_CFG_BUILD)/esplink-fpga-proxy --dram -i $(SOFT_BUILD)/linux.bin
	@./$(ESP_CFG_BUILD)/esplink --reset

fpga-run-linux-iolink: esplink esplink-fpga-proxy soft
	@./$(ESP_CFG_BUILD)/esplink-fpga-proxy --reset
	@./$(ESP_CFG_BUILD)/esplink-fpga-proxy --brom -i $(SOFT_BUILD)/prom.bin
	@./$(ESP_CFG_BUILD)/esplink-fpga-proxy --dram -i $(SOFT_BUILD)/linux.bin
	@./$(ESP_CFG_BUILD)/esplink-fpga-proxy --reset

fpga-run-jtag: esplink-fpga-proxy
	@python $(ESP_ROOT)/utils/scripts/jtag_test/jtag_esplink.py $(STIM_FILE)

endif

.PHONY: fpga-run fpga-run-linux fpga-program fpga-run-proxy fpga-run-linux-proxy
