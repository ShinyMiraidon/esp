# Copyright (c) 2011-2026 Columbia University, System Level Design Group
# SPDX-License-Identifier: Apache-2.0

CC ?= gcc
CROSS_COMPILE ?= aarch64-linux-gnu-
CFLAGS ?= -O2 -Wall -Wextra -std=c11
CPPFLAGS ?= -D_FILE_OFFSET_BITS=64
LDFLAGS ?=

TOOLS = esp_load_bootrom_zynq esp_peek

all: $(TOOLS)

esp_load_bootrom_zynq: esp_load_bootrom_zynq.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $< -o $@ $(LDFLAGS)

esp_peek: esp_peek.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $< -o $@ $(LDFLAGS)

cross:
	$(MAKE) CC="$(CROSS_COMPILE)gcc" all

static:
	$(MAKE) LDFLAGS="-static" all

cross-static:
	$(MAKE) CC="$(CROSS_COMPILE)gcc" LDFLAGS="-static" all

clean:
	$(RM) $(TOOLS)

.PHONY: all clean cross static cross-static
