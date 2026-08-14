// Copyright (c) 2011-2026 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0

// Load ESP bootrom and optional DRAM payload images from ZynqMP Linux through
// /dev/mem. This mirrors the DE10-Pro loader flow for ZCU106 PS control.

#define _FILE_OFFSET_BITS 64
#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define ZYNQ_PS_ESP_AXI_BASE UINT64_C(0x0400000000)

#define ESP_ARIANE_BOOTROM_BASE UINT64_C(0x00010000)
#define ESP_IBEX_BOOTROM_BASE   UINT64_C(0x00000080)
#define ESP_LEON3_BOOTROM_BASE  UINT64_C(0x00000000)

#define ESP_RISCV_DRAM_BASE UINT64_C(0x80000000)
#define ESP_LEON3_DRAM_BASE UINT64_C(0x40000000)

#define ESP_RISCV_RESET_ADDR UINT64_C(0x60000400)
#define ESP_LEON3_RESET_ADDR UINT64_C(0x80000400)

#define ESP_RISCV_WAKE_ADDR UINT64_C(0x60090384)
#define ESP_LEON3_WAKE_ADDR UINT64_C(0x80090384)

#define ZCU106_PS_DDR_BACKING_BASE UINT64_C(0x0000000020000000)

#define DEFAULT_BOOTROM_SIZE_BYTES (128U * 1024U)
#define DEFAULT_DRAM_SIZE_BYTES ((size_t)1U << 30)
#define DEFAULT_RESET_HOLD_US 1000U
#define DEFAULT_RESET_GAP_US 500000U
#define DEFAULT_WAKE_COUNT 2U
#define PROGRESS_STEP_WORDS 1024U

enum image_format {
    FORMAT_AUTO = 0,
    FORMAT_BIN,
    FORMAT_TXT
};

enum text_header_mode {
    TEXT_HEADER_AUTO = 0,
    TEXT_HEADER_SKIP,
    TEXT_HEADER_KEEP
};

enum binary_word_order {
    BIN_WORD_BIG_ENDIAN = 0,
    BIN_WORD_LITTLE_ENDIAN
};

struct word_buffer {
    uint32_t *data;
    unsigned char *raw_data;
    size_t count;
    size_t capacity;
    size_t raw_byte_count;
    size_t raw_capacity;
    size_t byte_count;
    bool padded;
};

struct mapped_region {
    int fd;
    void *base;
    size_t map_len;
};

struct image_load {
    const char *path;
    enum image_format format;
    enum text_header_mode header_mode;
    struct word_buffer words;
    uint64_t base;
    size_t max_size_bytes;
    unsigned int write_width_bits;
    enum binary_word_order binary_word_order;
    bool pad_partial_word;
    bool raw_binary_program;
    bool sync_after_program;
    bool dump_after_load;
    size_t dump_count;
    const char *label;
};

struct cpu_profile {
    const char *name;
    const char *description;
    uint64_t bootrom_base;
    uint64_t dram_base;
    uint64_t dram_ps_base;
    uint64_t reset_addr;
    uint64_t wake_addr;
    enum binary_word_order binary_word_order;
};

static const struct cpu_profile cpu_profiles[] = {
    {
        .name = "ariane",
        .description = "RV64 Ariane/CVA6, bootrom at ESP 0x00010000, payload at ESP 0x80000000",
        .bootrom_base = ZYNQ_PS_ESP_AXI_BASE + ESP_ARIANE_BOOTROM_BASE,
        .dram_base = ZYNQ_PS_ESP_AXI_BASE + ESP_RISCV_DRAM_BASE,
        .dram_ps_base = ZCU106_PS_DDR_BACKING_BASE,
        .reset_addr = ZYNQ_PS_ESP_AXI_BASE + ESP_RISCV_RESET_ADDR,
        .wake_addr = ZYNQ_PS_ESP_AXI_BASE + ESP_RISCV_WAKE_ADDR,
        .binary_word_order = BIN_WORD_BIG_ENDIAN,
    },
    {
        .name = "ibex",
        .description = "RV32 Ibex, first fetch at ESP 0x00000080, payload at ESP 0x80000000",
        .bootrom_base = ZYNQ_PS_ESP_AXI_BASE + ESP_IBEX_BOOTROM_BASE,
        .dram_base = ZYNQ_PS_ESP_AXI_BASE + ESP_RISCV_DRAM_BASE,
        .dram_ps_base = ZCU106_PS_DDR_BACKING_BASE,
        .reset_addr = ZYNQ_PS_ESP_AXI_BASE + ESP_RISCV_RESET_ADDR,
        .wake_addr = ZYNQ_PS_ESP_AXI_BASE + ESP_RISCV_WAKE_ADDR,
        .binary_word_order = BIN_WORD_BIG_ENDIAN,
    },
    {
        .name = "leon3",
        .description = "SPARC LEON3, reset at ESP 0x00000000, payload at ESP 0x40000000",
        .bootrom_base = ZYNQ_PS_ESP_AXI_BASE + ESP_LEON3_BOOTROM_BASE,
        .dram_base = ZYNQ_PS_ESP_AXI_BASE + ESP_LEON3_DRAM_BASE,
        .dram_ps_base = ZCU106_PS_DDR_BACKING_BASE,
        .reset_addr = ZYNQ_PS_ESP_AXI_BASE + ESP_LEON3_RESET_ADDR,
        .wake_addr = ZYNQ_PS_ESP_AXI_BASE + ESP_LEON3_WAKE_ADDR,
        .binary_word_order = BIN_WORD_BIG_ENDIAN,
    },
};

static const struct cpu_profile *default_cpu_profile(void)
{
    return &cpu_profiles[0];
}

static const char *binary_word_order_name(enum binary_word_order order)
{
    switch (order) {
    case BIN_WORD_BIG_ENDIAN:
        return "be";
    case BIN_WORD_LITTLE_ENDIAN:
        return "le";
    default:
        return "unknown";
    }
}

static void list_cpu_profiles(FILE *out)
{
    size_t i;

    fprintf(out, "CPU profiles:\n");
    for (i = 0; i < sizeof(cpu_profiles) / sizeof(cpu_profiles[0]); ++i) {
        fprintf(out,
                "  %-6s bootrom=0x%016" PRIx64
                " esp-dram=0x%016" PRIx64
                " ps-dram=0x%016" PRIx64
                " reset=0x%016" PRIx64
                " wake=0x%016" PRIx64
                " esp-bin-order=%s\n"
                "         %s\n",
                cpu_profiles[i].name,
                cpu_profiles[i].bootrom_base,
                cpu_profiles[i].dram_base,
                cpu_profiles[i].dram_ps_base,
                cpu_profiles[i].reset_addr,
                cpu_profiles[i].wake_addr,
                binary_word_order_name(cpu_profiles[i].binary_word_order),
                cpu_profiles[i].description);
    }
}

static const struct cpu_profile *find_cpu_profile(const char *name)
{
    size_t i;

    for (i = 0; i < sizeof(cpu_profiles) / sizeof(cpu_profiles[0]); ++i) {
        if (strcmp(name, cpu_profiles[i].name) == 0) {
            return &cpu_profiles[i];
        }
    }

    fprintf(stderr, "Invalid CPU profile: %s\n", name);
    list_cpu_profiles(stderr);
    exit(EXIT_FAILURE);
}

static uint64_t default_dram_base(const struct cpu_profile *profile,
                                  bool dram_via_ps_ddr,
                                  uint64_t ps_ddr_base)
{
    return dram_via_ps_ddr ? ps_ddr_base : profile->dram_base;
}

static enum binary_word_order default_dram_word_order(const struct cpu_profile *profile)
{
    return profile->binary_word_order;
}

static void usage(const char *prog)
{
    const struct cpu_profile *profile = default_cpu_profile();

    fprintf(stderr,
            "Usage: %s <bootrom_image> [options]\n"
            "\n"
            "Options:\n"
            "  --cpu <ariane|ibex|leon3>   CPU address profile (default: %s)\n"
            "  --list-cpus                 List CPU profiles and exit\n"
            "  --format <auto|bin|txt>      Bootrom input format (default: auto)\n"
            "  --binary-word-order <be|le>  Bootrom .bin word packing (default: CPU profile)\n"
            "  --base <phys_addr>           Bootrom base address (default: 0x%016" PRIx64 ")\n"
            "  --dram-image <image_file>    Optional DRAM image to load after bootrom\n"
            "  --dram-format <auto|bin|txt> DRAM input format (default: auto)\n"
            "  --dram-binary-word-order <be|le>\n"
            "                               DRAM .bin word packing; disables raw mode\n"
            "  --dram-base <phys_addr>      Override selected DRAM load address\n"
            "  --dram-via-ps-ddr            Write DRAM payload to PS DDR backing\n"
            "  --dram-via-esp               Write DRAM payload through ESP aperture (default)\n"
            "  --dram-ps-base <phys_addr>   PS DDR backing base (default: 0x%016" PRIx64 ")\n"
            "  --dram-raw-binary            Copy DRAM .bin bytes directly (default with PS DDR)\n"
            "  --dram-word-pack             Program DRAM .bin as packed 32-bit words\n"
            "  --dram-write-width <32|64>   DRAM programming store width (default: 32)\n"
            "  --reset-addr <phys_addr>     Soft-reset CSR address (default: 0x%016" PRIx64 ")\n"
            "  --reset-before               Enable reset before load (default)\n"
            "  --no-reset-before            Disable reset before load\n"
            "  --reset-after                Enable reset after load (default)\n"
            "  --no-reset-after             Disable reset after load\n"
            "  --reset-hold-us <usec>       Delay after asserting reset (default: %u)\n"
            "  --reset-gap-us <usec>        Delay after clearing reset (default: %u)\n"
            "  --reset-clear                Clear reset after each pulse (default)\n"
            "  --no-reset-clear             Leave reset asserted after each pulse write\n"
            "  --wake-addr <phys_addr>      ESP CSR read before load (default: CPU profile)\n"
            "  --wake-count <count>         Number of wake reads before load (default: %u)\n"
            "  --wake                       Enable ESP CSR wake reads (default)\n"
            "  --no-wake                    Skip ESP CSR wake reads before load\n"
            "  --verify                     Enable per-word readback verification\n"
            "  --no-verify                  Disable per-word readback verification (default)\n"
            "  --dump-after-load            Print bootrom words after programming\n"
            "  --dump-count <words>         Bootrom dump word count (default: loaded words)\n"
            "  --dump-dram-after-load       Print DRAM words after programming\n"
            "  --dram-dump-count <words>    DRAM dump word count (default: loaded words)\n"
            "  --skip-count-header          For bootrom text input, drop first word\n"
            "  --keep-first-word            For bootrom text input, always load first word\n"
            "  --dram-skip-count-header     For DRAM text input, drop first word\n"
            "  --dram-keep-first-word       For DRAM text input, always load first word\n"
            "  -h, --help                   Show this help message\n"
            "\n"
            "Notes:\n"
            "  - auto format treats .bin as binary and other extensions as text\n"
            "  - bootrom binary images use ESP's big-endian 32-bit word packing\n"
            "  - DRAM binary images default to ESP aperture packed-word loading\n"
            "  - --dram-via-ps-ddr copies DRAM .bin bytes directly into PS DDR\n"
            "  - readback verification is disabled by default because PS-side fabric\n"
            "    readback can fail even when writes are usable\n"
            "  - each reset sequence sends two reset pulses\n",
            prog,
            profile->name,
            profile->bootrom_base,
            profile->dram_ps_base,
            profile->reset_addr,
            DEFAULT_RESET_HOLD_US,
            DEFAULT_RESET_GAP_US,
            DEFAULT_WAKE_COUNT);
    list_cpu_profiles(stderr);
}

static void die_errno(const char *what)
{
    perror(what);
    exit(EXIT_FAILURE);
}

static void die_msg(const char *what)
{
    fprintf(stderr, "%s\n", what);
    exit(EXIT_FAILURE);
}

static uint64_t parse_u64(const char *text, const char *name)
{
    char *end = NULL;
    unsigned long long value;

    errno = 0;
    value = strtoull(text, &end, 0);
    if (errno != 0) {
        perror(name);
        exit(EXIT_FAILURE);
    }
    if (end == text || *end != '\0') {
        fprintf(stderr, "Invalid %s: %s\n", name, text);
        exit(EXIT_FAILURE);
    }

    return (uint64_t)value;
}

static size_t parse_size_arg(const char *text, const char *name)
{
    uint64_t value = parse_u64(text, name);

    if (value > SIZE_MAX) {
        fprintf(stderr, "%s is too large: %s\n", name, text);
        exit(EXIT_FAILURE);
    }

    return (size_t)value;
}

static unsigned int parse_uint_arg(const char *text, const char *name)
{
    size_t value = parse_size_arg(text, name);

    if (value > UINT_MAX) {
        fprintf(stderr, "%s is too large: %s\n", name, text);
        exit(EXIT_FAILURE);
    }

    return (unsigned int)value;
}

static void words_push(struct word_buffer *buf, uint32_t word)
{
    if (buf->count == buf->capacity) {
        size_t new_capacity = buf->capacity == 0 ? 1024U : buf->capacity * 2U;
        uint32_t *new_data = realloc(buf->data, new_capacity * sizeof(*new_data));

        if (new_data == NULL) {
            die_errno("realloc");
        }

        buf->data = new_data;
        buf->capacity = new_capacity;
    }

    buf->data[buf->count++] = word;
}

static void raw_bytes_append(struct word_buffer *buf,
                             const unsigned char *data,
                             size_t count)
{
    if (count == 0) {
        return;
    }

    if (buf->raw_byte_count + count > buf->raw_capacity) {
        size_t new_capacity = buf->raw_capacity == 0 ? 4096U : buf->raw_capacity;
        unsigned char *new_data;

        while (buf->raw_byte_count + count > new_capacity) {
            new_capacity *= 2U;
        }

        new_data = realloc(buf->raw_data, new_capacity);
        if (new_data == NULL) {
            die_errno("realloc");
        }

        buf->raw_data = new_data;
        buf->raw_capacity = new_capacity;
    }

    memcpy(buf->raw_data + buf->raw_byte_count, data, count);
    buf->raw_byte_count += count;
}

static enum image_format detect_format(const char *path)
{
    const char *dot = strrchr(path, '.');

    if (dot != NULL) {
        if (strcasecmp(dot, ".bin") == 0) {
            return FORMAT_BIN;
        }
        if (strcasecmp(dot, ".txt") == 0) {
            return FORMAT_TXT;
        }
    }

    return FORMAT_TXT;
}

static uint32_t pack_binary_word(const unsigned char raw[4],
                                 enum binary_word_order binary_word_order)
{
    if (binary_word_order == BIN_WORD_LITTLE_ENDIAN) {
        return ((uint32_t)raw[0] << 0) |
               ((uint32_t)raw[1] << 8) |
               ((uint32_t)raw[2] << 16) |
               ((uint32_t)raw[3] << 24);
    }

    return ((uint32_t)raw[0] << 24) |
           ((uint32_t)raw[1] << 16) |
           ((uint32_t)raw[2] << 8) |
           ((uint32_t)raw[3] << 0);
}

static void load_bin_file(const char *path,
                          struct word_buffer *words,
                          enum binary_word_order binary_word_order,
                          bool pad_partial_word)
{
    FILE *fp;

    fp = fopen(path, "rb");
    if (fp == NULL) {
        die_errno("fopen");
    }

    while (1) {
        unsigned char raw[4] = {0, 0, 0, 0};
        size_t got = fread(raw, 1, sizeof(raw), fp);

        if (got == sizeof(raw)) {
            raw_bytes_append(words, raw, got);
            words_push(words, pack_binary_word(raw, binary_word_order));
            words->byte_count += got;
        } else if (got == 0) {
            break;
        } else if (pad_partial_word) {
            raw_bytes_append(words, raw, sizeof(raw));
            words_push(words, pack_binary_word(raw, binary_word_order));
            words->byte_count += got;
            words->padded = true;
            break;
        } else {
            fclose(fp);
            die_msg("Binary image size is not a multiple of 4 bytes");
        }
    }

    if (ferror(fp)) {
        fclose(fp);
        die_errno("fread");
    }

    fclose(fp);
}

static bool parse_text_word(const char *line, uint32_t *word_out)
{
    const char *p = line;
    char *end = NULL;
    unsigned long long value;

    while (*p != '\0' && isspace((unsigned char)*p)) {
        ++p;
    }

    if (*p == '\0' || *p == '\n' || *p == '#') {
        return false;
    }

    errno = 0;
    value = strtoull(p, &end, 0);
    if (errno != 0) {
        die_errno("strtoull");
    }
    if (end == p || value > UINT32_MAX) {
        fprintf(stderr, "Invalid text image word: %s", line);
        exit(EXIT_FAILURE);
    }

    while (*end != '\0' && isspace((unsigned char)*end)) {
        ++end;
    }
    if (*end != '\0' && *end != '#') {
        fprintf(stderr, "Unexpected trailing characters in text image line: %s", line);
        exit(EXIT_FAILURE);
    }

    *word_out = (uint32_t)value;
    return true;
}

static void load_text_file(const char *path,
                           struct word_buffer *words,
                           enum text_header_mode header_mode)
{
    FILE *fp;
    char *line = NULL;
    size_t line_cap = 0;
    ssize_t line_len;

    fp = fopen(path, "r");
    if (fp == NULL) {
        die_errno("fopen");
    }

    while ((line_len = getline(&line, &line_cap, fp)) != -1) {
        uint32_t word;

        (void)line_len;
        if (parse_text_word(line, &word)) {
            words_push(words, word);
        }
    }

    if (ferror(fp)) {
        free(line);
        fclose(fp);
        die_errno("getline");
    }

    free(line);
    fclose(fp);

    if (words->count == 0) {
        die_msg("Text image does not contain any data words");
    }

    if (header_mode == TEXT_HEADER_AUTO &&
        words->count > 1 &&
        words->data[0] == (uint32_t)(words->count - 1U)) {
        header_mode = TEXT_HEADER_SKIP;
        printf("Detected count header 0x%08" PRIx32 " in text image; skipping it.\n",
               words->data[0]);
    }

    if (header_mode == TEXT_HEADER_SKIP) {
        if (words->count < 2) {
            die_msg("Cannot skip count header because the text image only has one word");
        }
        memmove(words->data, words->data + 1, (words->count - 1U) * sizeof(*words->data));
        words->count -= 1U;
    }

    words->byte_count = words->count * sizeof(uint32_t);
}

static size_t align_up(size_t value, size_t alignment)
{
    return (value + alignment - 1U) & ~(alignment - 1U);
}

static enum image_format parse_format_value(const char *value, const char *option_name)
{
    if (strcmp(value, "auto") == 0) {
        return FORMAT_AUTO;
    }
    if (strcmp(value, "bin") == 0) {
        return FORMAT_BIN;
    }
    if (strcmp(value, "txt") == 0) {
        return FORMAT_TXT;
    }

    fprintf(stderr, "Invalid %s value; expected auto, bin, or txt\n", option_name);
    exit(EXIT_FAILURE);
}

static enum binary_word_order parse_binary_word_order_value(const char *value,
                                                            const char *option_name)
{
    if (strcmp(value, "be") == 0 || strcmp(value, "big") == 0 ||
        strcmp(value, "big-endian") == 0) {
        return BIN_WORD_BIG_ENDIAN;
    }
    if (strcmp(value, "le") == 0 || strcmp(value, "little") == 0 ||
        strcmp(value, "little-endian") == 0) {
        return BIN_WORD_LITTLE_ENDIAN;
    }

    fprintf(stderr, "Invalid %s value; expected be or le\n", option_name);
    exit(EXIT_FAILURE);
}

static void map_region(struct mapped_region *region,
                       uint64_t phys_addr,
                       size_t span_bytes,
                       int prot)
{
    long page_size_long = sysconf(_SC_PAGESIZE);
    uint64_t page_size;
    uint64_t page_mask;
    uint64_t page_base;
    uint64_t page_offset;
    size_t map_len;

    if (span_bytes == 0) {
        die_msg("Internal error: requested zero-byte mapping");
    }
    if (page_size_long <= 0) {
        die_errno("sysconf(_SC_PAGESIZE)");
    }

    page_size = (uint64_t)page_size_long;
    page_mask = page_size - 1U;
    page_base = phys_addr & ~page_mask;
    page_offset = phys_addr - page_base;
    map_len = align_up((size_t)page_offset + span_bytes, (size_t)page_size);

    region->fd = open("/dev/mem", (prot & PROT_WRITE) ? (O_RDWR | O_SYNC) :
                                                       (O_RDONLY | O_SYNC));
    if (region->fd < 0) {
        die_errno("open(/dev/mem)");
    }

    region->base = mmap(NULL, map_len, prot, MAP_SHARED, region->fd, (off_t)page_base);
    if (region->base == MAP_FAILED) {
        close(region->fd);
        fprintf(stderr, "Failed physical address: 0x%016" PRIx64 "\n", phys_addr);
        die_errno("mmap");
    }

    region->map_len = map_len;
}

static void unmap_region(struct mapped_region *region)
{
    if (region->base != NULL && region->base != MAP_FAILED) {
        munmap(region->base, region->map_len);
    }
    if (region->fd >= 0) {
        close(region->fd);
    }

    region->fd = -1;
    region->base = NULL;
    region->map_len = 0;
}

static uint64_t page_offset_for(uint64_t phys_addr)
{
    long page_size_long = sysconf(_SC_PAGESIZE);

    if (page_size_long <= 0) {
        die_errno("sysconf(_SC_PAGESIZE)");
    }

    return phys_addr & ((uint64_t)page_size_long - 1U);
}

static volatile uint32_t *map_u32_ptr(const struct mapped_region *region, uint64_t phys_addr)
{
    return (volatile uint32_t *)((uint8_t *)region->base + page_offset_for(phys_addr));
}

static volatile uint64_t *map_u64_ptr(const struct mapped_region *region, uint64_t phys_addr)
{
    return (volatile uint64_t *)((uint8_t *)region->base + page_offset_for(phys_addr));
}

static uint32_t read_u32_phys(uint64_t phys_addr)
{
    struct mapped_region region = {.fd = -1, .base = NULL, .map_len = 0};
    volatile uint32_t *reg;
    uint32_t value;

    map_region(&region, phys_addr, sizeof(uint32_t), PROT_READ);
    reg = map_u32_ptr(&region, phys_addr);
    value = *reg;
    __sync_synchronize();
    unmap_region(&region);

    return value;
}

static void print_progress(const char *label, size_t done, size_t total)
{
    const size_t bar_width = 40U;
    size_t filled = total == 0 ? bar_width : (done * bar_width) / total;
    size_t i;

    printf("Loading %s: [", label);
    for (i = 0; i < bar_width; ++i) {
        putchar(i < filled ? '#' : ' ');
    }
    printf("] %3zu%%", total == 0 ? 100U : (done * 100U) / total);
    if (done == total) {
        putchar('\n');
    } else {
        putchar('\r');
    }
    fflush(stdout);
}

static void sleep_us(unsigned int delay_us)
{
    struct timespec req;
    struct timespec rem;

    req.tv_sec = delay_us / 1000000U;
    req.tv_nsec = (long)(delay_us % 1000000U) * 1000L;

    while (nanosleep(&req, &rem) != 0) {
        if (errno != EINTR) {
            die_errno("nanosleep");
        }
        req = rem;
    }
}

static void wake_esp_bus(uint64_t wake_addr, unsigned int wake_count)
{
    unsigned int i;

    for (i = 0; i < wake_count; ++i) {
        uint32_t value = read_u32_phys(wake_addr);

        printf("Wake read %u/%u at 0x%016" PRIx64 " = 0x%08" PRIx32 "\n",
               i + 1U,
               wake_count,
               wake_addr,
               value);
    }
}

static void dump_region_words(const char *label,
                              uint64_t base,
                              volatile uint32_t *mapped_words,
                              size_t word_count)
{
    size_t i;

    printf("%s dump (%zu words):\n", label, word_count);
    for (i = 0; i < word_count; ++i) {
        printf("[%05zu] 0x%016" PRIx64 " : 0x%08" PRIx32 "\n",
               i,
               base + (uint64_t)(i * sizeof(uint32_t)),
               mapped_words[i]);
    }
}

static void pulse_reset_sequence(uint64_t reset_addr,
                                 unsigned int reset_hold_us,
                                 unsigned int reset_gap_us,
                                 bool reset_clear)
{
    struct mapped_region region = {.fd = -1, .base = NULL, .map_len = 0};
    volatile uint32_t *reset_reg;
    int i;

    map_region(&region, reset_addr, sizeof(uint32_t), PROT_READ | PROT_WRITE);
    reset_reg = map_u32_ptr(&region, reset_addr);

    printf("Pulsing soft reset at 0x%016" PRIx64
           " (%s x2, hold=%u us, gap=%u us)\n",
           reset_addr,
           reset_clear ? "1/0 sequence" : "1 strobe",
           reset_hold_us,
           reset_gap_us);

    for (i = 0; i < 2; ++i) {
        *reset_reg = 0x1;
        __sync_synchronize();
        sleep_us(reset_hold_us);

        if (reset_clear) {
            *reset_reg = 0x0;
            __sync_synchronize();
        }
        sleep_us(reset_gap_us);
    }

    unmap_region(&region);
}

static void load_image_words(struct image_load *image)
{
    if (image->path == NULL) {
        return;
    }

    if (image->format == FORMAT_AUTO) {
        image->format = detect_format(image->path);
    }

    if (image->format == FORMAT_BIN) {
        load_bin_file(image->path,
                      &image->words,
                      image->binary_word_order,
                      image->pad_partial_word);
        if (image->raw_binary_program) {
            printf("Loaded %zu bytes (%zu packed words) from raw binary %s image %s\n",
                   image->words.raw_byte_count,
                   image->words.count,
                   image->label,
                   image->path);
        } else {
            printf("Loaded %zu words from %s-endian binary %s image %s\n",
                   image->words.count,
                   binary_word_order_name(image->binary_word_order),
                   image->label,
                   image->path);
        }
    } else {
        load_text_file(image->path, &image->words, image->header_mode);
        printf("Loaded %zu words from text %s image %s\n",
               image->words.count,
               image->label,
               image->path);
    }

    if (image->words.count == 0) {
        fprintf(stderr, "%s image is empty\n", image->label);
        exit(EXIT_FAILURE);
    }

    if (image->raw_binary_program &&
        image->format == FORMAT_BIN &&
        image->words.raw_byte_count > image->max_size_bytes) {
        fprintf(stderr,
                "%s image is too large: %zu bytes > %zu bytes\n",
                image->label,
                image->words.raw_byte_count,
                image->max_size_bytes);
        exit(EXIT_FAILURE);
    }

    if (!(image->raw_binary_program && image->format == FORMAT_BIN) &&
        image->words.count * sizeof(uint32_t) > image->max_size_bytes) {
        fprintf(stderr,
                "%s image is too large: %zu bytes > %zu bytes\n",
                image->label,
                image->words.count * sizeof(uint32_t),
                image->max_size_bytes);
        exit(EXIT_FAILURE);
    }

    if (image->words.padded) {
        printf("%s image was zero-padded to a final 32-bit word\n", image->label);
    }

    if (image->dump_after_load && image->dump_count == 0) {
        image->dump_count = image->words.count;
    }

    if (image->dump_count * sizeof(uint32_t) > image->max_size_bytes) {
        fprintf(stderr,
                "Requested %s dump exceeds region size: %zu bytes > %zu bytes\n",
                image->label,
                image->dump_count * sizeof(uint32_t),
                image->max_size_bytes);
        exit(EXIT_FAILURE);
    }

    if (image->write_width_bits != 32U && image->write_width_bits != 64U) {
        fprintf(stderr,
                "Invalid %s write width: %u bits\n",
                image->label,
                image->write_width_bits);
        exit(EXIT_FAILURE);
    }

    if (image->write_width_bits == 64U && (image->base & UINT64_C(0x7)) != 0) {
        fprintf(stderr,
                "%s base must be 8-byte aligned for 64-bit writes: 0x%016" PRIx64 "\n",
                image->label,
                image->base);
        exit(EXIT_FAILURE);
    }
}

static size_t image_program_span_bytes(const struct image_load *image)
{
    if (image->raw_binary_program && image->format == FORMAT_BIN) {
        return image->words.raw_byte_count;
    }

    size_t bytes = image->words.count * sizeof(uint32_t);

    if (image->write_width_bits == 64U) {
        bytes = align_up(bytes, sizeof(uint64_t));
    }

    return bytes;
}

static void sync_programmed_region(const struct mapped_region *region, const char *label)
{
    __sync_synchronize();
    if (msync(region->base, region->map_len, MS_SYNC) != 0) {
        fprintf(stderr,
                "Warning: msync failed for %s image: %s\n",
                label,
                strerror(errno));
    }
    __sync_synchronize();
}

static void print_raw_edge_bytes(const char *label,
                                 const unsigned char *data,
                                 size_t byte_count,
                                 bool first)
{
    size_t count = byte_count < 8U ? byte_count : 8U;
    size_t start = first || byte_count <= count ? 0U : byte_count - count;
    size_t i;

    printf("%s %s bytes   :",
           label,
           first ? "first" : "last ");
    for (i = 0; i < count; ++i) {
        printf(" %02x", data[start + i]);
    }
    putchar('\n');
}

static void program_raw_binary_image(const struct image_load *image, bool verify)
{
    struct mapped_region region = {.fd = -1, .base = NULL, .map_len = 0};
    volatile uint32_t *mapped_words;
    volatile uint8_t *mapped_bytes;
    size_t word_count = image->words.raw_byte_count / sizeof(uint32_t);
    size_t byte_tail_offset = word_count * sizeof(uint32_t);
    size_t i;

    map_region(&region, image->base, image_program_span_bytes(image), PROT_READ | PROT_WRITE);
    mapped_bytes = (volatile uint8_t *)((uint8_t *)region.base + page_offset_for(image->base));
    mapped_words = map_u32_ptr(&region, image->base);

    print_progress(image->label, 0, image->words.raw_byte_count);
    for (i = 0; i < word_count; ++i) {
        uint32_t word;
        size_t byte_offset = i * sizeof(uint32_t);

        memcpy(&word, image->words.raw_data + byte_offset, sizeof(word));
        mapped_words[i] = word;

        if (((i + 1U) % PROGRESS_STEP_WORDS) == 0) {
            print_progress(image->label,
                           (i + 1U) * sizeof(uint32_t),
                           image->words.raw_byte_count);
        }
    }
    for (i = byte_tail_offset; i < image->words.raw_byte_count; ++i) {
        mapped_bytes[i] = image->words.raw_data[i];
    }
    if (image->sync_after_program) {
        sync_programmed_region(&region, image->label);
    } else {
        __sync_synchronize();
    }
    print_progress(image->label, image->words.raw_byte_count, image->words.raw_byte_count);

    if (verify) {
        for (i = 0; i < image->words.raw_byte_count; ++i) {
            uint8_t observed = mapped_bytes[i];
            uint8_t expected = image->words.raw_data[i];

            if (observed != expected) {
                fprintf(stderr,
                        "\nVerify failed in raw %s image at byte %zu "
                        "(addr 0x%016" PRIx64 "): wrote 0x%02" PRIx8
                        ", read 0x%02" PRIx8 "\n",
                        image->label,
                        i,
                        image->base + (uint64_t)i,
                        expected,
                        observed);
                unmap_region(&region);
                exit(EXIT_FAILURE);
            }
        }
    }

    printf("%s raw byte load complete.\n", image->label);
    print_raw_edge_bytes(image->label, image->words.raw_data, image->words.raw_byte_count, true);
    print_raw_edge_bytes(image->label, image->words.raw_data, image->words.raw_byte_count, false);

    if (image->dump_after_load) {
        dump_region_words(image->label, image->base, mapped_words, image->dump_count);
    }

    unmap_region(&region);
}

static void program_image(const struct image_load *image, bool verify)
{
    struct mapped_region region = {.fd = -1, .base = NULL, .map_len = 0};
    volatile uint32_t *mapped_words;
    size_t i;

    if (image->path == NULL) {
        return;
    }

    if (image->raw_binary_program && image->format == FORMAT_BIN) {
        program_raw_binary_image(image, verify);
        return;
    }

    map_region(&region, image->base, image_program_span_bytes(image), PROT_READ | PROT_WRITE);
    mapped_words = map_u32_ptr(&region, image->base);

    print_progress(image->label, 0, image->words.count);
    if (image->write_width_bits == 64U) {
        volatile uint64_t *mapped_beats = map_u64_ptr(&region, image->base);

        for (i = 0; i < image->words.count; i += 2U) {
            uint32_t lo = image->words.data[i];
            uint32_t hi = (i + 1U) < image->words.count ? image->words.data[i + 1U] : 0U;
            uint64_t beat = ((uint64_t)hi << 32) | (uint64_t)lo;
            size_t done = (i + 2U) < image->words.count ? i + 2U : image->words.count;

            mapped_beats[i / 2U] = beat;
            __sync_synchronize();

            if (verify) {
                uint32_t observed_lo = mapped_words[i];

                if (observed_lo != lo) {
                    fprintf(stderr,
                            "\nVerify failed in %s image at word %zu "
                            "(addr 0x%016" PRIx64 "): wrote 0x%08" PRIx32
                            ", read 0x%08" PRIx32 "\n",
                            image->label,
                            i,
                            image->base + (uint64_t)(i * sizeof(uint32_t)),
                            lo,
                            observed_lo);
                    unmap_region(&region);
                    exit(EXIT_FAILURE);
                }

                if ((i + 1U) < image->words.count) {
                    uint32_t observed_hi = mapped_words[i + 1U];

                    if (observed_hi != hi) {
                        fprintf(stderr,
                                "\nVerify failed in %s image at word %zu "
                                "(addr 0x%016" PRIx64 "): wrote 0x%08" PRIx32
                                ", read 0x%08" PRIx32 "\n",
                                image->label,
                                i + 1U,
                                image->base + (uint64_t)((i + 1U) * sizeof(uint32_t)),
                                hi,
                                observed_hi);
                        unmap_region(&region);
                        exit(EXIT_FAILURE);
                    }
                }
            }

            if ((done % PROGRESS_STEP_WORDS) == 0 || done == image->words.count) {
                print_progress(image->label, done, image->words.count);
            }
        }
    } else {
        for (i = 0; i < image->words.count; ++i) {
            uint32_t expected = image->words.data[i];

            mapped_words[i] = expected;
            __sync_synchronize();

            if (verify) {
                uint32_t observed = mapped_words[i];

                if (observed != expected) {
                    fprintf(stderr,
                            "\nVerify failed in %s image at word %zu "
                            "(addr 0x%016" PRIx64 "): wrote 0x%08" PRIx32
                            ", read 0x%08" PRIx32 "\n",
                            image->label,
                            i,
                            image->base + (uint64_t)(i * sizeof(uint32_t)),
                            expected,
                            observed);
                    unmap_region(&region);
                    exit(EXIT_FAILURE);
                }
            }

            if (((i + 1U) % PROGRESS_STEP_WORDS) == 0 || (i + 1U) == image->words.count) {
                print_progress(image->label, i + 1U, image->words.count);
            }
        }
    }

    printf("%s load complete.\n", image->label);
    printf("%s first word    : 0x%08" PRIx32 "\n", image->label, image->words.data[0]);
    printf("%s last word     : 0x%08" PRIx32 "\n",
           image->label,
           image->words.data[image->words.count - 1U]);

    if (image->sync_after_program) {
        sync_programmed_region(&region, image->label);
    }

    if (image->dump_after_load) {
        dump_region_words(image->label, image->base, mapped_words, image->dump_count);
    }

    unmap_region(&region);
}

int main(int argc, char *argv[])
{
    bool verify = false;
    bool reset_before = true;
    bool reset_after = true;
    const struct cpu_profile *profile = default_cpu_profile();
    uint64_t reset_addr = profile->reset_addr;
    uint64_t wake_addr = profile->wake_addr;
    unsigned int reset_hold_us = DEFAULT_RESET_HOLD_US;
    unsigned int reset_gap_us = DEFAULT_RESET_GAP_US;
    unsigned int wake_count = DEFAULT_WAKE_COUNT;
    bool reset_clear = true;
    bool wake_before_load = true;
    bool dram_via_ps_ddr = false;
    bool bootrom_base_override = false;
    bool dram_base_override = false;
    bool dram_ps_base_override = false;
    bool reset_addr_override = false;
    bool wake_addr_override = false;
    bool bootrom_binary_word_order_override = false;
    bool dram_binary_word_order_override = false;
    bool dram_raw_binary_override = false;
    bool dram_raw_binary_requested = false;
    uint64_t dram_ps_base = profile->dram_ps_base;
    struct image_load bootrom = {
        .path = NULL,
        .format = FORMAT_AUTO,
        .header_mode = TEXT_HEADER_AUTO,
        .words = {0},
        .base = profile->bootrom_base,
        .max_size_bytes = DEFAULT_BOOTROM_SIZE_BYTES,
        .write_width_bits = 32U,
        .binary_word_order = profile->binary_word_order,
        .pad_partial_word = false,
        .raw_binary_program = false,
        .sync_after_program = false,
        .dump_after_load = false,
        .dump_count = 0,
        .label = "bootrom",
    };
    struct image_load dram = {
        .path = NULL,
        .format = FORMAT_AUTO,
        .header_mode = TEXT_HEADER_AUTO,
        .words = {0},
        .base = profile->dram_base,
        .max_size_bytes = DEFAULT_DRAM_SIZE_BYTES,
        .write_width_bits = 32U,
        .binary_word_order = profile->binary_word_order,
        .pad_partial_word = true,
        .raw_binary_program = false,
        .sync_after_program = false,
        .dump_after_load = false,
        .dump_count = 0,
        .label = "DRAM",
    };
    int i;

    if (setvbuf(stdout, NULL, _IONBF, 0) != 0) {
        die_errno("setvbuf(stdout)");
    }
    if (setvbuf(stderr, NULL, _IONBF, 0) != 0) {
        die_errno("setvbuf(stderr)");
    }

    if (argc < 2) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }

    if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
        usage(argv[0]);
        return EXIT_SUCCESS;
    }

    if (strcmp(argv[1], "--list-cpus") == 0) {
        list_cpu_profiles(stdout);
        return EXIT_SUCCESS;
    }

    bootrom.path = argv[1];

    for (i = 2; i < argc; ++i) {
        if (strcmp(argv[i], "--cpu") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --cpu");
            }
            profile = find_cpu_profile(argv[i]);
            if (!bootrom_base_override) {
                bootrom.base = profile->bootrom_base;
            }
            if (!dram_ps_base_override) {
                dram_ps_base = profile->dram_ps_base;
            }
            if (!dram_base_override) {
                dram.base = default_dram_base(profile, dram_via_ps_ddr, dram_ps_base);
            }
            if (!reset_addr_override) {
                reset_addr = profile->reset_addr;
            }
            if (!wake_addr_override) {
                wake_addr = profile->wake_addr;
            }
            if (!bootrom_binary_word_order_override) {
                bootrom.binary_word_order = profile->binary_word_order;
            }
            if (!dram_binary_word_order_override) {
                dram.binary_word_order = default_dram_word_order(profile);
            }
        } else if (strcmp(argv[i], "--list-cpus") == 0) {
            list_cpu_profiles(stdout);
            return EXIT_SUCCESS;
        } else if (strcmp(argv[i], "--format") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --format");
            }
            bootrom.format = parse_format_value(argv[i], "--format");
        } else if (strcmp(argv[i], "--binary-word-order") == 0 ||
                   strcmp(argv[i], "--bootrom-binary-word-order") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --binary-word-order");
            }
            bootrom.binary_word_order =
                parse_binary_word_order_value(argv[i], "--binary-word-order");
            bootrom_binary_word_order_override = true;
        } else if (strcmp(argv[i], "--base") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --base");
            }
            bootrom.base = parse_u64(argv[i], "--base");
            bootrom_base_override = true;
        } else if (strcmp(argv[i], "--dram-image") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --dram-image");
            }
            dram.path = argv[i];
        } else if (strcmp(argv[i], "--dram-format") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --dram-format");
            }
            dram.format = parse_format_value(argv[i], "--dram-format");
        } else if (strcmp(argv[i], "--dram-binary-word-order") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --dram-binary-word-order");
            }
            dram.binary_word_order =
                parse_binary_word_order_value(argv[i], "--dram-binary-word-order");
            dram_binary_word_order_override = true;
            dram_raw_binary_override = true;
            dram_raw_binary_requested = false;
        } else if (strcmp(argv[i], "--dram-base") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --dram-base");
            }
            dram.base = parse_u64(argv[i], "--dram-base");
            dram_base_override = true;
        } else if (strcmp(argv[i], "--dram-via-ps-ddr") == 0) {
            dram_via_ps_ddr = true;
            if (!dram_base_override) {
                dram.base = default_dram_base(profile, dram_via_ps_ddr, dram_ps_base);
            }
            if (!dram_binary_word_order_override) {
                dram.binary_word_order = default_dram_word_order(profile);
            }
        } else if (strcmp(argv[i], "--dram-via-esp") == 0) {
            dram_via_ps_ddr = false;
            if (!dram_base_override) {
                dram.base = default_dram_base(profile, dram_via_ps_ddr, dram_ps_base);
            }
            if (!dram_binary_word_order_override) {
                dram.binary_word_order = default_dram_word_order(profile);
            }
        } else if (strcmp(argv[i], "--dram-ps-base") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --dram-ps-base");
            }
            dram_ps_base = parse_u64(argv[i], "--dram-ps-base");
            dram_ps_base_override = true;
            if (dram_via_ps_ddr && !dram_base_override) {
                dram.base = default_dram_base(profile, dram_via_ps_ddr, dram_ps_base);
            }
        } else if (strcmp(argv[i], "--dram-raw-binary") == 0) {
            dram_raw_binary_override = true;
            dram_raw_binary_requested = true;
        } else if (strcmp(argv[i], "--dram-word-pack") == 0 ||
                   strcmp(argv[i], "--no-dram-raw-binary") == 0) {
            dram_raw_binary_override = true;
            dram_raw_binary_requested = false;
        } else if (strcmp(argv[i], "--dram-write-width") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --dram-write-width");
            }
            dram.write_width_bits = parse_uint_arg(argv[i], "--dram-write-width");
            if (dram.write_width_bits != 32U && dram.write_width_bits != 64U) {
                die_msg("Invalid --dram-write-width value; expected 32 or 64");
            }
        } else if (strcmp(argv[i], "--wake-addr") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --wake-addr");
            }
            wake_addr = parse_u64(argv[i], "--wake-addr");
            wake_addr_override = true;
        } else if (strcmp(argv[i], "--wake-count") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --wake-count");
            }
            wake_count = parse_uint_arg(argv[i], "--wake-count");
            if (wake_count == 0U) {
                die_msg("Invalid --wake-count value; expected nonzero count");
            }
        } else if (strcmp(argv[i], "--wake") == 0) {
            wake_before_load = true;
        } else if (strcmp(argv[i], "--no-wake") == 0) {
            wake_before_load = false;
        } else if (strcmp(argv[i], "--reset-addr") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --reset-addr");
            }
            reset_addr = parse_u64(argv[i], "--reset-addr");
            reset_addr_override = true;
        } else if (strcmp(argv[i], "--reset-hold-us") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --reset-hold-us");
            }
            reset_hold_us = parse_uint_arg(argv[i], "--reset-hold-us");
        } else if (strcmp(argv[i], "--reset-gap-us") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --reset-gap-us");
            }
            reset_gap_us = parse_uint_arg(argv[i], "--reset-gap-us");
        } else if (strcmp(argv[i], "--reset-clear") == 0) {
            reset_clear = true;
        } else if (strcmp(argv[i], "--no-reset-clear") == 0) {
            reset_clear = false;
        } else if (strcmp(argv[i], "--reset-before") == 0) {
            reset_before = true;
        } else if (strcmp(argv[i], "--no-reset-before") == 0) {
            reset_before = false;
        } else if (strcmp(argv[i], "--reset-after") == 0) {
            reset_after = true;
        } else if (strcmp(argv[i], "--no-reset-after") == 0) {
            reset_after = false;
        } else if (strcmp(argv[i], "--verify") == 0) {
            verify = true;
        } else if (strcmp(argv[i], "--no-verify") == 0) {
            verify = false;
        } else if (strcmp(argv[i], "--dump-after-load") == 0) {
            bootrom.dump_after_load = true;
        } else if (strcmp(argv[i], "--dump-count") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --dump-count");
            }
            bootrom.dump_count = parse_size_arg(argv[i], "--dump-count");
            bootrom.dump_after_load = true;
        } else if (strcmp(argv[i], "--dump-dram-after-load") == 0) {
            dram.dump_after_load = true;
        } else if (strcmp(argv[i], "--dram-dump-count") == 0) {
            if (++i >= argc) {
                die_msg("Missing value for --dram-dump-count");
            }
            dram.dump_count = parse_size_arg(argv[i], "--dram-dump-count");
            dram.dump_after_load = true;
        } else if (strcmp(argv[i], "--skip-count-header") == 0) {
            bootrom.header_mode = TEXT_HEADER_SKIP;
        } else if (strcmp(argv[i], "--keep-first-word") == 0) {
            bootrom.header_mode = TEXT_HEADER_KEEP;
        } else if (strcmp(argv[i], "--dram-skip-count-header") == 0) {
            dram.header_mode = TEXT_HEADER_SKIP;
        } else if (strcmp(argv[i], "--dram-keep-first-word") == 0) {
            dram.header_mode = TEXT_HEADER_KEEP;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return EXIT_SUCCESS;
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            usage(argv[0]);
            return EXIT_FAILURE;
        }
    }

    if (dram_raw_binary_override) {
        dram.raw_binary_program = dram_raw_binary_requested;
    } else {
        dram.raw_binary_program = dram_via_ps_ddr;
    }

    if (dram.raw_binary_program && !dram_via_ps_ddr) {
        die_msg("--dram-raw-binary is only valid with --dram-via-ps-ddr");
    }

    dram.sync_after_program = dram_via_ps_ddr;

    load_image_words(&bootrom);
    load_image_words(&dram);

    printf("CPU profile       : %s\n", profile->name);
    printf("Bootrom base      : 0x%016" PRIx64 "\n", bootrom.base);
    printf("Bootrom bin order : %s\n", binary_word_order_name(bootrom.binary_word_order));
    printf("DRAM image        : %s\n", dram.path != NULL ? dram.path : "<none>");
    if (dram.path != NULL) {
        printf("DRAM path         : %s\n",
               dram_via_ps_ddr ? "PS DDR backing" : "ESP aperture");
        if (dram_via_ps_ddr) {
            printf("DRAM PS base      : 0x%016" PRIx64 "\n", dram_ps_base);
        }
        printf("DRAM base         : 0x%016" PRIx64 "\n", dram.base);
        printf("DRAM write width  : %u-bit\n", dram.write_width_bits);
        if (dram.format == FORMAT_BIN && dram.raw_binary_program) {
            printf("DRAM bin mode     : raw bytes\n");
        } else {
            printf("DRAM bin order    : %s\n", binary_word_order_name(dram.binary_word_order));
        }
    }
    printf("Reset CSR         : 0x%016" PRIx64 "\n", reset_addr);
    printf("Reset before load : %s\n", reset_before ? "yes" : "no");
    printf("Reset after load  : %s\n", reset_after ? "yes" : "no");
    printf("Reset hold/gap    : %u us / %u us\n", reset_hold_us, reset_gap_us);
    printf("Reset clear       : %s\n", reset_clear ? "yes" : "no");
    printf("Wake before load  : %s\n", wake_before_load ? "yes" : "no");
    if (wake_before_load) {
        printf("Wake addr/count   : 0x%016" PRIx64 " / %u\n", wake_addr, wake_count);
    }
    printf("Verify            : %s\n", verify ? "yes" : "no");
    printf("Bootrom words     : %zu (%zu bytes)\n",
           bootrom.words.count,
           bootrom.words.count * sizeof(uint32_t));
    if (dram.path != NULL) {
        printf("DRAM words        : %zu (%zu bytes)\n",
               dram.words.count,
               dram.words.count * sizeof(uint32_t));
    }

    if (wake_before_load && wake_count > 0U) {
        printf("BEGIN ESP bus wake reads\n");
        wake_esp_bus(wake_addr, wake_count);
        printf("END ESP bus wake reads\n");
    }
    if (reset_before) {
        printf("BEGIN reset-before sequence\n");
        pulse_reset_sequence(reset_addr, reset_hold_us, reset_gap_us, reset_clear);
        printf("END reset-before sequence\n");
    }

    printf("BEGIN bootrom programming\n");
    program_image(&bootrom, verify);
    printf("END bootrom programming\n");
    if (dram.path != NULL) {
        printf("BEGIN DRAM programming\n");
    }
    program_image(&dram, verify);
    if (dram.path != NULL) {
        printf("END DRAM programming\n");
    }

    if (reset_after) {
        printf("BEGIN reset-after sequence\n");
        pulse_reset_sequence(reset_addr, reset_hold_us, reset_gap_us, reset_clear);
        printf("END reset-after sequence\n");
    }

    free(bootrom.words.data);
    free(bootrom.words.raw_data);
    free(dram.words.data);
    free(dram.words.raw_data);

    return EXIT_SUCCESS;
}
