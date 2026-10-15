/* Copyright (c) 2011-2026 Columbia University, System Level Design Group */
/* SPDX-License-Identifier: Apache-2.0 */

/* I/O link read/write test -- initiator half.
 *
 * Runs on an SoC built with CONFIG_IOLINK_ROLE = 1, whose I/O tile
 * instantiates ahbslv2iolink. Every access this program makes to the window
 * at IOLINK_WINDOW_BASE leaves the SoC over the I/O link and is performed by
 * the far SoC's iolink2ahbm on its DRAM, at IOLINK_TARGET_BASE + offset. The
 * far SoC runs iolink_rw_test, which owns the protocol: see the table at the
 * top of iolink_rw_test.c. This program is steps 4-7 and 11 of it.
 *
 * Division of labour: this side checks the READ path, comparing what it reads
 * with the pattern the target wrote, and the target checks the WRITE path. So
 * the words written back are ~pattern, not ~(what was read), so that a read
 * error cannot reappear as a write error on the other board.
 *
 * WHAT A DEAD LINK LOOKS LIKE
 *
 * The timeouts below only help while the link answers. ahbslv2iolink holds
 * the AHB bus (hready low) until a read's reply comes back, and stops taking
 * writes once its queue is full, so if the link or the far side is dead the
 * access never completes and the core stalls: no timeout can fire and nothing
 * more is printed. Each phase therefore prints before it first touches the
 * window, and the last line on the console names the access that hung.
 */

#include <stdint.h>
#include <stdio.h>

#include "../iolink_rw_test/iolink_rw_test.h"

#ifndef __riscv
    #error "the I/O link window is only routed for Ariane; see IOLINK_WINDOW_HADDR in rtl/sockets/proxy/tile.vhd"
#endif

/* The whole test must fit in the window. Past its end an access decodes
 * outside it and fails on the local bus instead of crossing the link.
 */
typedef char iolink_test_fits_window[(IOLINK_TEST_BYTES <= IOLINK_WINDOW_SIZE) ? 1 : -1];

/* Target address -> this SoC's address for it. */
#define WIN(target_addr) (IOLINK_WINDOW_BASE + ((target_addr) - IOLINK_TARGET_BASE))

static volatile uint32_t *const mbox = (volatile uint32_t *)WIN(IOLINK_TEST_BASE + IOLINK_MBOX_OFFSET);
static volatile uint32_t *const data = (volatile uint32_t *)WIN(IOLINK_TEST_BASE + IOLINK_DATA_OFFSET);

/* Makes every earlier store leave this core before any later one. The window
 * is uncached, so there are no lines to flush; the point is that DONE must
 * not reach the target ahead of the data it announces.
 */
static inline void order_writes(void) { __asm__ volatile("fence" ::: "memory"); }

/* Poll a mailbox word over the link until it holds `want`, for at most
 * IOLINK_TIMEOUT_CYCLES. Returns 0 on success, or 1 with the last value read
 * in *last.
 */
/* The target's own account of where it is (mailbox word 7), read over the
 * link. It is what makes this console enough on its own: with one UART open at
 * a time, the target's is usually not the one being watched.
 */
static void print_target_state(void)
{
    uint32_t s = mbox[IOLINK_MBOX_TSTATE];
    printf("    target state: %s (0x%08x)\n", iolink_tstate_name(s), (unsigned)s);
}

/* Poll a mailbox word over the link until it holds `want`, for at most
 * IOLINK_TIMEOUT_CYCLES, reporting progress every 30 s. Returns 0 on success,
 * or 1 with the last value read in *last.
 */
static int wait_for(int word, uint32_t want, uint32_t *last)
{
    const uint64_t progress = 30ull * IOLINK_CPU_HZ;
    uint64_t start = iolink_cycles();
    uint64_t next  = progress;
    uint32_t v;

    while ((v = mbox[word]) != want) {
        uint64_t elapsed = iolink_cycles() - start;
        if (elapsed >= IOLINK_TIMEOUT_CYCLES) {
            *last = v;
            return 1;
        }
        if (elapsed >= next) {
            printf("    still waiting after %u s (read 0x%08x)\n", (unsigned)(elapsed / IOLINK_CPU_HZ),
                   (unsigned)v);
            print_target_state();
            next += progress;
        }
    }
    *last = v;
    return 0;
}

/* Rate for n words moved in `cycles` CPU cycles. */
static void print_rate(const char *what, uint32_t n, uint64_t cycles)
{
    if (cycles == 0) cycles = 1;
    printf("    %s: %u words in %lu cycles, %lu cycles/word, %lu KiB/s\n", what, (unsigned)n,
           (unsigned long)cycles, (unsigned long)(cycles / n),
           (unsigned long)((uint64_t)n * 4 * IOLINK_CPU_HZ / cycles / 1024));
}

int main(int argc, char **argv)
{
    uint32_t nwords, order, mode, status, v, i;
    int region, errors, tot_errors = 0;
    uint64_t t0, t_read, t_write;

    printf("I/O link read/write test -- initiator\n");
    printf("  window   : 0x%08x -> target 0x%08x, %u MiB\n", (unsigned)IOLINK_WINDOW_BASE,
           (unsigned)IOLINK_TARGET_BASE, (unsigned)(IOLINK_WINDOW_SIZE >> 20));
    printf("  timeouts : %u s each\n", (unsigned)IOLINK_TIMEOUT_S);
    printf("  If output stops right after a line below, the access it names never\n");
    printf("  completed: the link, or the target's end of it, is not answering.\n");

    /* Phase 1: first contact. A reply of any value proves the link carries a
     * read both ways; READY is what proves the target program is running.
     */
    printf("\n[1] first read through the window: READY at 0x%08x\n",
           (unsigned)WIN(IOLINK_TEST_BASE + IOLINK_MBOX_OFFSET + 4 * IOLINK_MBOX_READY));
    v = mbox[IOLINK_MBOX_READY];
    printf("    link answered, READY = 0x%08x\n", (unsigned)v);
    print_target_state();
    if (v != IOLINK_MAGIC_READY) {
        printf("    waiting for the target (iolink_rw_test) to signal READY\n");
        if (wait_for(IOLINK_MBOX_READY, IOLINK_MAGIC_READY, &v)) {
            printf("    TIMEOUT: READY never arrived (last read 0x%08x)\n", (unsigned)v);
            print_target_state();
            printf("    (re)start iolink_rw_test on the target board, then this program\n");
            return 1;
        }
    }
    printf("    READY\n");

    /* Phase 2: the parameters the target published before READY. */
    nwords = mbox[IOLINK_MBOX_NWORDS];
    order  = mbox[IOLINK_MBOX_ORDER];
    mode   = mbox[IOLINK_MBOX_MODE];
    printf("\n[2] mailbox: NWORDS = %u, ORDER = 0x%08x, MODE = %u (target ESP caches %s)\n", (unsigned)nwords,
           (unsigned)order, (unsigned)mode, mode ? "on" : "off");

    /* A wrong marker would corrupt every region the same way, so name the
     * failure here rather than report it as noise across all of them. The
     * link carries a 32-bit word as two 16-bit beats (CFG_IOLINK_BITS), so a
     * halfword swap is its own case.
     */
    if (order != IOLINK_ORDER_MARKER) {
        if (order == 0x04030201u)
            printf("    FAILED: bytes are swapped (the ahbslv2iolink little_end generic?)\n");
        else if (order == 0x03040102u)
            printf("    FAILED: 16-bit halves are swapped (beat order on the link)\n");
        else
            printf("    FAILED: expected 0x%08x -- the data path is corrupting words\n", (unsigned)IOLINK_ORDER_MARKER);
        printf("    stopping without writing DONE; the target will time out\n");
        return 1;
    }
    if (nwords != IOLINK_REGION_WORDS_COH && nwords != IOLINK_REGION_WORDS_NOCOH) {
        printf("    FAILED: NWORDS is neither %u nor %u, the only sizes the target publishes\n",
               (unsigned)IOLINK_REGION_WORDS_COH, (unsigned)IOLINK_REGION_WORDS_NOCOH);
        printf("    stopping without writing DONE; the target will time out\n");
        return 1;
    }
    printf("    ok\n");

    /* Phase 3: read path. Print the first few bad words of each region; the
     * address and both values usually say which bit or beat went wrong.
     */
    printf("\n[3] reading and verifying %d regions over the link\n", IOLINK_NREGIONS);
    t0 = iolink_cycles();
    for (region = 0; region < IOLINK_NREGIONS; region++) {
        volatile uint32_t *p = data + (uint32_t)region * nwords;
        errors               = 0;
        for (i = 0; i < nwords; i++) {
            v = p[i];
            if (v != pattern(region, i)) {
                if (errors < 4)
                    printf("      word %u (target 0x%08x): expected 0x%08x got 0x%08x\n", (unsigned)i,
                           (unsigned)(IOLINK_TEST_BASE + IOLINK_DATA_OFFSET + 4 * (region * nwords + i)),
                           (unsigned)pattern(region, i), (unsigned)v);
                errors++;
            }
        }
        tot_errors += errors;
        if (errors)
            printf("    region %d (%-12s) %d read errors\n", region, region_name(region), errors);
        else
            printf("    region %d (%-12s) ok\n", region, region_name(region));
    }
    t_read = iolink_cycles() - t0;

    /* Phase 4: write path. The target verifies these, not us. */
    printf("\n[4] writing back the inverted patterns\n");
    t0 = iolink_cycles();
    for (region = 0; region < IOLINK_NREGIONS; region++) {
        volatile uint32_t *p = data + (uint32_t)region * nwords;
        for (i = 0; i < nwords; i++)
            p[i] = ~pattern(region, i);
    }
    order_writes();
    t_write = iolink_cycles() - t0;
    mbox[IOLINK_MBOX_DONE] = IOLINK_MAGIC_DONE;
    order_writes();
    printf("    written, DONE sent\n");

    /* Phase 5: the target's verdict on the write path. */
    printf("\n[5] waiting for the target's verdict\n");
    if (wait_for(IOLINK_MBOX_RESULT, IOLINK_MAGIC_RESULT, &v)) {
        printf("    TIMEOUT: no RESULT from the target (last read 0x%08x)\n", (unsigned)v);
        print_target_state();
        return 1;
    }
    status = mbox[IOLINK_MBOX_STATUS];
    printf("    target counted %u write errors\n", (unsigned)status);

    printf("\n[6] summary\n");
    print_rate("read ", IOLINK_NREGIONS * nwords, t_read);
    print_rate("write", IOLINK_NREGIONS * nwords, t_write);
    printf("    read errors (here) %d, write errors (target) %u\n", tot_errors, (unsigned)status);

    if (tot_errors || status) {
        printf("\nFAILED\n");
        return 1;
    }
    printf("\nPASSED\n");
    return 0;
}
