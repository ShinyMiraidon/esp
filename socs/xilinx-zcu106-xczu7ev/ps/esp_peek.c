// Copyright (c) 2011-2026 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0

// Read one 32-bit physical word from ZynqMP Linux through /dev/mem.

#define _FILE_OFFSET_BITS 64

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

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

int main(int argc, char *argv[])
{
    uint64_t phys_addr;
    long page_size;
    uint64_t page_mask;
    uint64_t page_base;
    uint64_t page_offset;
    int fd;
    void *map;
    volatile uint32_t *ptr;
    uint32_t value;

    if (argc != 2) {
        fprintf(stderr, "Usage: %s <physical_address>\n", argv[0]);
        return EXIT_FAILURE;
    }

    phys_addr = parse_u64(argv[1], "physical address");

    page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) {
        perror("sysconf(_SC_PAGESIZE)");
        return EXIT_FAILURE;
    }

    page_mask = (uint64_t)page_size - 1U;
    page_base = phys_addr & ~page_mask;
    page_offset = phys_addr - page_base;

    fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) {
        perror("open(/dev/mem)");
        return EXIT_FAILURE;
    }

    map = mmap(NULL, (size_t)page_size, PROT_READ, MAP_SHARED, fd, (off_t)page_base);
    if (map == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return EXIT_FAILURE;
    }

    ptr = (volatile uint32_t *)((uint8_t *)map + page_offset);
    value = *ptr;
    __sync_synchronize();

    printf("Read 32-bit value at 0x%016" PRIx64 " = 0x%08" PRIx32 "\n",
           phys_addr,
           value);

    munmap(map, (size_t)page_size);
    close(fd);

    return EXIT_SUCCESS;
}
