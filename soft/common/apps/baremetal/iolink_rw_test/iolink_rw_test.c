/* Copyright (c) 2011-2026 Columbia University, System Level Design Group */
/* SPDX-License-Identifier: Apache-2.0 */

/* I/O link read/write test.
 *
 * Exercises the ESP I/O link as a data path, and gives the credit budget
 * (CONFIG_IOLINK_CREDITS) something to stress. The link is asymmetric: the
 * I/O tile instantiates iolink2ahbm, so the *far* side masters transactions
 * into this SoC. A program running here therefore cannot drive the link by
 * itself -- it plays the other half of a handshake.
 *
 * Protocol, all through a mailbox at IOLINK_TEST_BASE:
 *
 *   CPU (this program)                    far side (host over the I/O link,
 *                                         or a second board)
 *   ------------------------------------  ------------------------------------
 *   1. fill 3 pattern regions
 *   2. publish NWORDS, ORDER, MODE
 *   3. write READY magic            --->  4. poll READY
 *                                         5. read + verify the 3 regions
 *                                         6. write back each word inverted
 *   8. poll DONE                    <---  7. write DONE magic
 *   9. verify the inverted readback
 *  10. publish error count in STATUS
 *
 * Read NWORDS rather than assuming it: the region size depends on the SoC's
 * cache configuration, which this program discovers at run time (below).
 *
 * Three pattern kinds are used because they fail differently: a counter
 * catches address aliasing, walking-ones catches stuck or shorted data bits,
 * and a multiplicative hash catches burst/ordering errors that a smooth
 * pattern would hide. ORDER is a separate marker so a byte swap -- the
 * ahbslv2iolink little_end generic being wrong, say -- is obvious rather than
 * showing up as noise across every region.
 *
 * CACHE HANDLING
 *
 * The SoC may or may not build ESP's cache hierarchy: CONFIG_CACHE_EN is on in
 * the ASIC defconfigs and off in all the FPGA ones. Rather than split into two
 * programs, this probes for an L2 controller and adapts:
 *
 *   caches present  -> esp_flush() at both sync points, smaller regions
 *   caches absent   -> esp_flush() would probe an empty device list and do
 *                      nothing, so fall back to capacity: regions sized past
 *                      L1 so a walk evicts its own earlier lines
 *
 * OPEN QUESTION -- Ariane's L1.
 *
 * esp_flush() reaches ESP's L2/LLC. It has an explicit L1 flush only for SPARC
 * (ASI_LEON_DFLUSH); there is no RISC-V equivalent in probe.c, and the L2 path
 * only comments that it "waits for L1 to flush first". So on Ariane it is not
 * established that a flush makes an external master's writes visible, or that
 * the CPU's writes have landed in DRAM. Until that is settled on hardware,
 * define IOLINK_PARANOID to keep the large regions even when caches are
 * present. If results look flaky, resolve it properly -- map the window
 * non-cacheable, or add an L1 invalidate. Do not "fix" it by shrinking the
 * regions.
 */

#include <stdint.h>
#include <stdio.h>

#include <esp_accelerator.h>
#include <esp_probe.h>

#include "iolink_rw_test.h"

static volatile uint32_t *const mbox = (volatile uint32_t *)(IOLINK_TEST_BASE + IOLINK_MBOX_OFFSET);
static volatile uint32_t *const data = (volatile uint32_t *)(IOLINK_TEST_BASE + IOLINK_DATA_OFFSET);

/* Deterministic and trivially reproducible on the far side, in C or a script. */
static uint32_t pattern(int region, uint32_t i)
{
    switch (region) {
        case 0: return i; /* counter: address aliasing            */
        case 1: return 1u << (i & 31); /* walking ones: stuck data bits        */
        default: return i * 2654435761u; /* Knuth hash: burst/ordering errors    */
    }
}

static const char *region_name(int region)
{
    switch (region) {
        case 0: return "counter";
        case 1: return "walking-ones";
        default: return "hash";
    }
}

/* Order writes so the far side never sees READY before the payload. A fence
 * orders; it does not write back L1. See the cache note above.
 */
static inline void order_writes(void)
{
#ifdef __riscv
    __asm__ volatile("fence" ::: "memory");
#else
    __asm__ volatile("" ::: "memory");
#endif
}

/* Push the CPU's view out / drop stale lines, as far as this SoC allows.
 * With no ESP caches built, esp_flush() finds no devices and is a no-op; the
 * region sizing carries the weight instead.
 */
static void sync_point(int have_caches)
{
    order_writes();
    if (have_caches) esp_flush(ACC_COH_NONE);
    order_writes();
}

int main(int argc, char **argv)
{
    struct esp_device *l2s = NULL, *llcs = NULL;
    int region, errors, tot_errors = 0;
    int nl2, nllc, have_caches;
    uint32_t region_words;
    uint32_t i;

    printf("I/O link read/write test\n");

    /* Discover the cache configuration rather than assuming it. */
    nl2         = probe(&l2s, VENDOR_CACHE, DEVID_L2_CACHE, DEVNAME_L2_CACHE);
    nllc        = probe(&llcs, VENDOR_CACHE, DEVID_LLC_CACHE, DEVNAME_LLC_CACHE);
    have_caches = (nl2 > 0);

#ifdef IOLINK_PARANOID
    region_words = IOLINK_REGION_WORDS_NOCOH;
#else
    region_words = have_caches ? IOLINK_REGION_WORDS_COH : IOLINK_REGION_WORDS_NOCOH;
#endif

    printf("  caches   : %s (%d L2, %d LLC)\n", have_caches ? "present -> flushing at sync points" :
                                                              "absent  -> relying on region size",
           nl2, nllc);
    printf("  window   : 0x%08x\n", (unsigned)IOLINK_TEST_BASE);
    printf("  regions  : %d x %u words (%u KiB each)\n", IOLINK_NREGIONS, (unsigned)region_words,
           (unsigned)(region_words * 4 / 1024));

    /* Phase 0: control. Prove the window itself works before blaming the
     * link for anything. A failure here is a memory or address-map problem,
     * not an I/O link problem.
     */
    printf("\n[0] local write/read control\n");
    errors = 0;
    for (i = 0; i < 1024; i++)
        data[i] = pattern(2, i);
    for (i = 0; i < 1024; i++)
        if (data[i] != pattern(2, i)) errors++;
    if (errors) {
        printf("    FAILED: %d/1024 errors -- window is broken, stopping\n", errors);
        return 1;
    }
    printf("    ok\n");

    /* Phase 1: publish the patterns for the far side to verify. */
    printf("\n[1] writing %d pattern regions\n", IOLINK_NREGIONS);
    for (region = 0; region < IOLINK_NREGIONS; region++) {
        volatile uint32_t *p = data + (uint32_t)region * region_words;
        for (i = 0; i < region_words; i++)
            p[i] = pattern(region, i);
        printf("    region %d (%s) written\n", region, region_name(region));
    }

    mbox[IOLINK_MBOX_NWORDS] = region_words;
    mbox[IOLINK_MBOX_ORDER]  = IOLINK_ORDER_MARKER;
    mbox[IOLINK_MBOX_MODE]   = (uint32_t)have_caches;
    mbox[IOLINK_MBOX_STATUS] = 0;
    mbox[IOLINK_MBOX_DONE]   = 0;
    sync_point(have_caches);

    printf("\n[2] signalling READY, waiting for the far side\n");
    mbox[IOLINK_MBOX_READY] = IOLINK_MAGIC_READY;
    sync_point(have_caches);

    /* Phase 3: bounded wait, so a dead link reports instead of hanging. */
    {
        uint32_t spins = 0;
        while (mbox[IOLINK_MBOX_DONE] != IOLINK_MAGIC_DONE) {
            if (++spins >= IOLINK_POLL_LIMIT) {
                printf("    TIMEOUT: DONE never arrived (read 0x%08x)\n", (unsigned)mbox[IOLINK_MBOX_DONE]);
                printf("    check: Aurora channel_up, the credit budget, and that\n");
                printf("           the far side polls 0x%08x for READY\n",
                       (unsigned)(IOLINK_TEST_BASE + IOLINK_MBOX_OFFSET));
                return 1;
            }
        }
        printf("    DONE after %u polls\n", (unsigned)spins);
    }

    /* Drop anything stale before trusting what we read back. */
    sync_point(have_caches);

    /* Phase 4: verify what the far side wrote back. */
    printf("\n[3] verifying inverted readback\n");
    for (region = 0; region < IOLINK_NREGIONS; region++) {
        volatile uint32_t *p = data + (uint32_t)region * region_words;
        uint32_t first_bad    = 0;
        int found_bad         = 0;
        errors                = 0;
        for (i = 0; i < region_words; i++) {
            uint32_t want = ~pattern(region, i);
            if (p[i] != want) {
                if (!found_bad) {
                    first_bad = i;
                    found_bad = 1;
                }
                errors++;
            }
        }
        tot_errors += errors;
        if (errors) {
            printf("    region %d (%-12s) %d errors; first at word %u\n", region, region_name(region), errors,
                   (unsigned)first_bad);
            printf("      expected 0x%08x  got 0x%08x\n", (unsigned)~pattern(region, first_bad),
                   (unsigned)p[first_bad]);
        } else {
            printf("    region %d (%-12s) ok\n", region, region_name(region));
        }
    }

    mbox[IOLINK_MBOX_STATUS] = (uint32_t)tot_errors;
    sync_point(have_caches);

    if (tot_errors)
        printf("\nFAILED: %d total errors\n", tot_errors);
    else
        printf("\nPASSED\n");

    return tot_errors ? 1 : 0;
}
