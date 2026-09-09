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
 *   2. publish NWORDS and ORDER marker
 *   3. write READY magic            --->  4. poll READY
 *                                         5. read + verify the 3 regions
 *                                         6. write back each word inverted
 *   8. poll DONE                    <---  7. write DONE magic
 *   9. verify the inverted readback
 *  10. publish error count in STATUS
 *
 * Three pattern kinds are used because they fail differently: a counter
 * catches address aliasing, walking-ones catches stuck or shorted data bits,
 * and a multiplicative hash catches burst/ordering errors that a smooth
 * pattern would hide. ORDER is a separate marker so a byte swap -- the
 * ahbslv2iolink little_end generic being wrong, say -- is obvious rather than
 * showing up as noise across every region.
 *
 * KNOWN LIMITATION -- CPU cache coherence.
 *
 * Ariane's L1 data cache is not coherent with an external master writing
 * DRAM, and ESP's esp_flush() only reaches the L2/LLC, which this board does
 * not build (CONFIG_CACHE_EN is off in the VC707 defconfig). So:
 *
 *   - the CPU's pattern writes may sit dirty in L1 rather than in DRAM when
 *     the far side reads them, and
 *   - the CPU may read stale L1 lines rather than what the far side wrote.
 *
 * IOLINK_REGION_WORDS is sized well past L1 capacity so that walking a region
 * evicts the lines written earlier in that same region, which makes both
 * directions mostly work in practice. That is a mitigation, not a fix. If
 * results look flaky on hardware, resolve it properly before trusting the
 * numbers: map the test window non-cacheable, or add an L1 invalidate. Do not
 * "fix" it by shrinking the regions.
 */

#include <stdint.h>
#include <stdio.h>

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

/* Order writes so the far side never sees READY before the payload. A plain
 * fence is enough for ordering; it does not write back L1 (see the header
 * comment above).
 */
static inline void order_writes(void)
{
#ifdef __riscv
    __asm__ volatile("fence" ::: "memory");
#else
    __asm__ volatile("" ::: "memory");
#endif
}

int main(int argc, char **argv)
{
    int region, errors, tot_errors = 0;
    uint32_t i;

    printf("I/O link read/write test\n");
    printf("  window   : 0x%08x\n", (unsigned)IOLINK_TEST_BASE);
    printf("  regions  : %d x %u words (%u KiB each)\n", IOLINK_NREGIONS, (unsigned)IOLINK_REGION_WORDS,
           (unsigned)(IOLINK_REGION_WORDS * 4 / 1024));

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
        volatile uint32_t *p = data + (uint32_t)region * IOLINK_REGION_WORDS;
        for (i = 0; i < IOLINK_REGION_WORDS; i++)
            p[i] = pattern(region, i);
        printf("    region %d (%s) written\n", region, region_name(region));
    }

    mbox[IOLINK_MBOX_NWORDS] = IOLINK_REGION_WORDS;
    mbox[IOLINK_MBOX_ORDER]  = IOLINK_ORDER_MARKER;
    mbox[IOLINK_MBOX_STATUS] = 0;
    mbox[IOLINK_MBOX_DONE]   = 0;
    order_writes();

    printf("\n[2] signalling READY, waiting for the far side\n");
    mbox[IOLINK_MBOX_READY] = IOLINK_MAGIC_READY;
    order_writes();

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

    /* Phase 4: verify what the far side wrote back. */
    printf("\n[3] verifying inverted readback\n");
    for (region = 0; region < IOLINK_NREGIONS; region++) {
        volatile uint32_t *p = data + (uint32_t)region * IOLINK_REGION_WORDS;
        uint32_t first_bad    = 0xFFFFFFFFu;
        errors                = 0;
        for (i = 0; i < IOLINK_REGION_WORDS; i++) {
            uint32_t want = ~pattern(region, i);
            if (p[i] != want) {
                if (errors == 0) first_bad = i;
                errors++;
            }
        }
        tot_errors += errors;
        if (errors) {
            uint32_t bad = first_bad;
            printf("    region %d (%-12s) %d errors; first at word %u\n", region, region_name(region), errors, (unsigned)bad);
            printf("      expected 0x%08x  got 0x%08x\n", (unsigned)~pattern(region, bad), (unsigned)p[bad]);
        } else {
            printf("    region %d (%-12s) ok\n", region, region_name(region));
        }
    }

    mbox[IOLINK_MBOX_STATUS] = (uint32_t)tot_errors;
    order_writes();

    if (tot_errors)
        printf("\nFAILED: %d total errors\n", tot_errors);
    else
        printf("\nPASSED\n");

    return tot_errors ? 1 : 0;
}
