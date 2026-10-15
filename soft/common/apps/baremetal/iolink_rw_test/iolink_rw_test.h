/* Copyright (c) 2011-2026 Columbia University, System Level Design Group */
/* SPDX-License-Identifier: Apache-2.0 */

#ifndef __IOLINK_RW_TEST_H__
#define __IOLINK_RW_TEST_H__

#include <stdint.h>

/* Base of the test region in the TARGET's main memory.
 *
 * On RISC-V this is where the initiator's window lands: the I/O link maps
 * window base + offset onto IOLINK_TARGET_BASE + offset in the far SoC, and
 * the mailbox sits at offset 0. Keep IOLINK_TARGET_BASE equal to the constant
 * of the same name in rtl/sockets/proxy/tile.vhd, which explains the choice:
 * 512 MiB into DRAM, clear of the loaded payload at 0x80000000, and beyond
 * the range Ariane caches when ESP caches are off.
 *
 * LEON3 maps DRAM at 0x40000000 and is not an I/O link endpoint in this
 * scheme; its base is kept only so the program still builds there.
 */
#ifdef __riscv
    #define IOLINK_TARGET_BASE 0xA0000000u
    #define IOLINK_TEST_BASE   IOLINK_TARGET_BASE
#else
    #define IOLINK_TEST_BASE 0x48000000
#endif

/* The initiator's side of the same mapping: IOLINK_WINDOW_HADDR and
 * IOLINK_WINDOW_LOG2 in rtl/sockets/proxy/tile.vhd (0x030 << 20, 2^24 bytes).
 * Every access in this range on an initiator SoC travels over the link.
 */
#define IOLINK_WINDOW_BASE 0x03000000u
#define IOLINK_WINDOW_SIZE 0x01000000u

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

/* Word 6: CPU -> far side. Set to IOLINK_MAGIC_RESULT once STATUS holds the
 * final error count, so the far side can tell "0 errors" from "not finished".
 */
#define IOLINK_MBOX_RESULT 6
#define IOLINK_MAGIC_RESULT 0xC0DEC0DEu

/* Word 7: CPU -> far side. Where the target program is, so the far side -- or
 * anyone with esplink -- can tell "not started" from "gave up waiting" without
 * the target's UART. Magic values, so stale DRAM is not mistaken for a state.
 */
#define IOLINK_MBOX_TSTATE    7
#define IOLINK_TSTATE_SETUP   0x7A570001u /* writing patterns, READY not set  */
#define IOLINK_TSTATE_WAITING 0x7A570002u /* READY set, waiting for DONE      */
#define IOLINK_TSTATE_TIMEOUT 0x7A570003u /* gave up waiting; READY cleared   */
#define IOLINK_TSTATE_FINISHED 0x7A570004u /* verified; STATUS and RESULT set */

static inline const char *iolink_tstate_name(uint32_t s)
{
    switch (s) {
        case IOLINK_TSTATE_SETUP: return "setting up";
        case IOLINK_TSTATE_WAITING: return "waiting for DONE";
        case IOLINK_TSTATE_TIMEOUT: return "timed out waiting for DONE";
        case IOLINK_TSTATE_FINISHED: return "finished";
        default: return "unknown -- target program not running?";
    }
}

/* The test's footprint past IOLINK_TEST_BASE, largest region size. */
#define IOLINK_TEST_BYTES (IOLINK_DATA_OFFSET + IOLINK_NREGIONS * IOLINK_REGION_WORDS_NOCOH * 4)

/* Bounded waits, so a dead link reports instead of hanging forever. Measured
 * in CPU cycles rather than poll iterations, because the cost of one poll
 * depends on the path (an uncached read across the NoC, a round trip over the
 * link, a fence). 10 minutes at the VC707's 50 MHz CPU clock: loading the
 * second board by hand, switching UART consoles on the way, easily took longer
 * than the 120 s first used here, and the target then gave up before the
 * initiator's first read.
 */
#define IOLINK_CPU_HZ         50000000ull
#define IOLINK_TIMEOUT_S      600ull
#define IOLINK_TIMEOUT_CYCLES (IOLINK_TIMEOUT_S * IOLINK_CPU_HZ)

#ifdef __riscv
static inline uint64_t iolink_cycles(void)
{
    uint64_t c;
    __asm__ volatile("csrr %0, mcycle" : "=r"(c));
    return c;
}
#else
/* No cycle counter used on LEON3: count calls instead, so the limit becomes a
 * poll count there.
 */
static inline uint64_t iolink_cycles(void)
{
    static uint64_t n;
    return n++;
}
#endif

/* Deterministic and trivially reproducible on the far side, in C or a script.
 * Shared by both halves of the test (iolink_rw_test, iolink_rw_initiator), so
 * they cannot disagree about what a region holds.
 */
static inline uint32_t pattern(int region, uint32_t i)
{
    switch (region) {
        case 0: return i; /* counter: address aliasing            */
        case 1: return 1u << (i & 31); /* walking ones: stuck data bits        */
        default: return i * 2654435761u; /* Knuth hash: burst/ordering errors    */
    }
}

static inline const char *region_name(int region)
{
    switch (region) {
        case 0: return "counter";
        case 1: return "walking-ones";
        default: return "hash";
    }
}

#endif /* __IOLINK_RW_TEST_H__ */
