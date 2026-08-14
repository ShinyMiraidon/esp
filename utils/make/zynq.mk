# Copyright (c) 2011-2026 Columbia University, System Level Design Group
# SPDX-License-Identifier: Apache-2.0

### ZYNQ Targets

ZYNQ = $(ESP_ROOT)/utils/zynq
ZYNQ_BOARD = $(shell echo $(BOARD) | cut -d "-" -f 2)
ZYNQ_DTS = $(DESIGN_PATH)/zynq/$(ZYNQ_BOARD)/sdk/dt/system.dts.tmp
ZYNQ_DTB = $(DESIGN_PATH)/zynq/$(ZYNQ_BOARD)/sdk/dt/system.dtb
ZYNQ_BITSTREAM = $(DESIGN_PATH)/vivado/$(DESIGN).runs/impl_1/$(TOP).bit
ZYNQ_HWDEF = $(DESIGN_PATH)/vivado/$(DESIGN).runs/impl_1/$(TOP).hwdef
ZYNQ_HWDEF_BUILD = $(DESIGN_PATH)/zynq/$(ZYNQ_BOARD)/hwdef
ZYNQ_HWDEF_SCRIPT = $(ESP_ROOT)/constraints/$(BOARD)/zynq_hwdef.tcl
ZYNQ_BD_SCRIPT = $(ESP_ROOT)/constraints/$(BOARD)/zynq.tcl
ZYNQ_PS_TEMPLATE_BOARDS = zcu102 zcu106

ZYNQ_SDK_PREREQUISITES = check-bitstream
ifneq ($(filter $(ZYNQ_BOARD),$(ZYNQ_PS_TEMPLATE_BOARDS)),)
ZYNQ_SDK_PREREQUISITES += zynq-hwdef
endif

check-bitstream:
	@if ! test -e $(ZYNQ_BITSTREAM); then \
		echo $(SPACES)"ERROR: bistream not found; run 'make vivado-syn'"; \
		exit 1; \
	fi;

$(ZYNQ_HWDEF): $(ZYNQ_BITSTREAM) $(ZYNQ_HWDEF_SCRIPT) $(ZYNQ_BD_SCRIPT)
	@case "$(XILINX_VIVADO)" in \
		*2019.2*) ;; \
		*) echo $(SPACES)"ERROR: $(ZYNQ_BOARD) PS hardware handoff requires Vivado 2019.2"; exit 1;; \
	esac
	@case "$(ARCH_BITS)" in \
		32|64) ;; \
		*) echo $(SPACES)"ERROR: invalid $(ZYNQ_BOARD) AXI data width '$(ARCH_BITS)' (expected 32 or 64)"; exit 1;; \
	esac
	$(QUIET_INFO)echo "generating Vivado 2019.2 $(ZYNQ_BOARD) PS hardware handoff"
	@mkdir -p "$(ZYNQ_HWDEF_BUILD)" "$(dir $(ZYNQ_HWDEF))"
	@$(RM) "$(ZYNQ_HWDEF)"
	@vivado -mode batch -quiet -notrace -source "$(ZYNQ_HWDEF_SCRIPT)" \
		-tclargs "$(ZYNQ_HWDEF_BUILD)" "$(ZYNQ_HWDEF)" "$(ZYNQ_BD_SCRIPT)" "$(ARCH_BITS)" \
		| tee "$(ZYNQ_HWDEF_BUILD)/vivado_hwdef.log"
	@if ! test -r "$(ZYNQ_HWDEF)"; then \
		echo $(SPACES)"ERROR: Vivado did not generate $(ZYNQ_HWDEF)"; \
		exit 1; \
	fi

zynq-hwdef: check-bitstream $(ZYNQ_HWDEF)

zynq-sdk: $(ZYNQ_SDK_PREREQUISITES)
	unset LD_LIBRARY_PATH; \
	ZYNQ_ROOT=$(ZYNQ) BOARD=$(ZYNQ_BOARD) TOP=$(TOP) DESIGN=$(DESIGN) OUT=$(DESIGN_PATH)/zynq VIVADO_BUILD=$(DESIGN_PATH)/vivado $(MAKE) -C $(ZYNQ) sdk

zynq-u-boot:
	unset LD_LIBRARY_PATH; \
	ZYNQ_ROOT=$(ZYNQ) BOARD=$(ZYNQ_BOARD) TOP=$(TOP) DESIGN=$(DESIGN) OUT=$(DESIGN_PATH)/zynq VIVADO_BUILD=$(DESIGN_PATH)/vivado $(MAKE) -C $(ZYNQ) u-boot

zynq-linux:
	unset LD_LIBRARY_PATH; \
	ZYNQ_ROOT=$(ZYNQ) BOARD=$(ZYNQ_BOARD) TOP=$(TOP) DESIGN=$(DESIGN) OUT=$(DESIGN_PATH)/zynq VIVADO_BUILD=$(DESIGN_PATH)/vivado $(MAKE) -C $(ZYNQ) linux

zynq: $(ZYNQ_SDK_PREREQUISITES)
	unset LD_LIBRARY_PATH; \
	ZYNQ_ROOT=$(ZYNQ) BOARD=$(ZYNQ_BOARD) TOP=$(TOP) DESIGN=$(DESIGN) OUT=$(DESIGN_PATH)/zynq VIVADO_BUILD=$(DESIGN_PATH)/vivado $(MAKE) -C $(ZYNQ) sdk
	@if test -n "$(filter $(ZYNQ_BOARD),$(ZYNQ_PS_TEMPLATE_BOARDS))" && test -f $(ZYNQ_DTS) && ! grep -q 'esp_reserved' $(ZYNQ_DTS); then \
		echo $(SPACES)"INFO reserving $(ZYNQ_BOARD) PS DDR window for ESP"; \
		printf '\n/ {\n\treserved-memory {\n\t\t#address-cells = <2>;\n\t\t#size-cells = <2>;\n\t\tranges;\n\n\t\tesp_reserved: buffer@20000000 {\n\t\t\tcompatible = "shared-dma-pool";\n\t\t\tno-map;\n\t\t\treg = <0x0 0x20000000 0x0 0x40000000>;\n\t\t};\n\t};\n};\n' >> $(ZYNQ_DTS); \
		dtc -I dts -O dtb -o $(ZYNQ_DTB) $(ZYNQ_DTS); \
	fi
	unset LD_LIBRARY_PATH; \
	ZYNQ_ROOT=$(ZYNQ) BOARD=$(ZYNQ_BOARD) TOP=$(TOP) DESIGN=$(DESIGN) OUT=$(DESIGN_PATH)/zynq VIVADO_BUILD=$(DESIGN_PATH)/vivado $(MAKE) -C $(ZYNQ) sd-card


zynq-jtag-boot: check-bitstream
	$(QUIET_RUN)
	@xsct $(ZYNQ)/scripts/xsct_jtagboot_zynqmp.tcl $(FPGA_HOST) $(XIL_HW_SERVER_PORT) $(DESIGN_PATH)/zynq/$(ZYNQ_BOARD)/images $(DESIGN_PATH)/zynq/$(ZYNQ_BOARD)/sdk vivado/$(DESIGN).runs/impl_1/$(TOP).bit

zynq-clean:


zynq-distclean: zynq-clean
	$(QUIET_CLEAN) $(RM) zynq



.PHONY: check-bitstream zynq-hwdef zynq-clean zynq-distclean zynq-sdk zynq-u-boot zynq-linux zynq zynq-jtag-boot
