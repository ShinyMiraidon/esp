/* Copyright (c) 2011-2026 Columbia University, System Level Design Group */
/* SPDX-License-Identifier: Apache-2.0 */

#ifndef __IOLINK_RW_TEST_H__
#define __IOLINK_RW_TEST_H__

#include <stdint.h>

/* Base of the test window in main memory.
 *
 * DDR_HADDR for the RISC-V cores is 0x800, so DRAM starts at 0x80000000;
 * LEON3 maps it at 0x40000000 instead. 0x88000000 / 0x48000000 is 128 MiB in,
 * which clears the loaded payload comfortably. Adjust if your DRAM window
 * differs or the payload grows.
 */
#ifdef __riscv
    #define IOLINK_TEST_BASE 0x88000000
#else
    #define IOLINK_TEST_BASE 0x48000000
#endif

/* Mailbox lives in the first cache lines; data follows at +4 KiB so the two
 * never share a line. The far side only needs these offsets, nothing else.
 */
#define IOLINK_MBOX_OFFSET 0x0000
#define IOLINK_DATA_OFFSET 0x1000

#define IOLINK_MBOX_READY  0 /* word 0: CPU -> far side, pattern is written  */
#define IOLINK_MBOX_DONE   1 /* word 1: far side -> CPU, transform is back   */
#define IOLINK_MBOX_NWORDS 2 /* word 2: CPU -> far side, words per region    */
#define IOLINK_MBOX_ORDER  3 /* word 3: CPU -> far side, byte-order marker   */
#define IOLINK_MBOX_STATUS 4 /* word 4: CPU -> far side, final error count   */
#define IOLINK_MBOX_MODE   5 /* word 5: CPU -> far side, 1 = ESP caches on   */

#define IOLINK_MAGIC_READY 0x5EEDFACEu
#define IOLINK_MAGIC_DONE  0xFEEDBEEFu

/* Byte-order marker. If the far side reads 0x04030201 the link (or the
 * ahbslv2iolink little_end generic) is swapping bytes.
 */
#define IOLINK_ORDER_MARKER 0x01020304u

#define IOLINK_NREGIONS 3

/* Words per pattern region, chosen at run time from the SoC configuration.
 *
 * With ESP caches built (CONFIG_CACHE_EN), esp_flush() can push the CPU's
 * writes out and invalidate before the readback, so the regions only need to
 * be big enough to be interesting.
 *
 * Without them, esp_flush() probes an empty device list and does nothing, so
 * the only lever left is capacity: sizing each region well past L1 forces a
 * walk to evict the lines it wrote earlier, which makes both directions work
 * in practice. That is a mitigation, not a fix -- see the header comment in
 * iolink_rw_test.c.
 */
#define IOLINK_REGION_WORDS_COH   (8 * 1024)  /* 32 KiB  */
#define IOLINK_REGION_WORDS_NOCOH (64 * 1024) /* 256 KiB */

/* Force the large regions even when caches are present. Worth setting while
 * the Ariane L1 question below is still open, at the cost of a slower test.
 */
/* #define IOLINK_PARANOID */

/* Bounded wait so a dead link reports instead of hanging forever. Units are
 * poll iterations, not cycles; tune on hardware.
 */
#define IOLINK_POLL_LIMIT 200000000u

#endif /* __IOLINK_RW_TEST_H__ */
