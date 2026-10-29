/*
 * test/tools/probe_demo_sentinels.c -- dump the microbench sentinel block.
 *
 * The demo ROMs in test/microbench/ follow one sentinel convention
 * (see test/microbench/cartboot.inc): main RAM $010000-$01000F holds
 * START / DONE / COUNT / SPARE, and the bytes above that are free for
 * whatever a given probe wants to publish.
 *
 * This tool loads a ROM, runs it for N frames and prints the sentinel
 * block as 32-bit big-endian words, so a probe ROM's findings can be
 * read without a debugger attached.  It is a diagnostic, not a test: it
 * always reports PASS.
 *
 * Usage:  probe_demo_sentinels <core.so> <rom.j64> [--frames N] [--words N]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../harness/harness.h"

#define SENT_BASE   0x00010000u
#define SENT_WORDS  16u   /* $010000-$01003F */

int main(int argc, char **argv)
{
    harness_config cfg = HARNESS_CONFIG_DEFAULT;
    unsigned frames = 60;
    unsigned words = SENT_WORDS;
    uint8_t **ramp;
    const uint8_t *ram;
    unsigned i;
    int argi;

    for (argi = 1; argi < argc; argi++) {
        if (!strcmp(argv[argi], "--frames") && argi + 1 < argc)
            frames = (unsigned)atoi(argv[++argi]);
        else if (!strcmp(argv[argi], "--words") && argi + 1 < argc)
            words = (unsigned)atoi(argv[++argi]);
    }
    if (argc < 3) {
        fprintf(stderr, "usage: %s <core.so> <rom.j64> [--frames N] [--words N]\n",
                argv[0]);
        return 2;
    }
    if (words > SENT_WORDS)
        words = SENT_WORDS;

    cfg.frames = frames;
    cfg.quiet = 1;
    if (!harness_init_from_args(&cfg, argc, argv))
        return 2;

    ramp = (uint8_t **)harness_dlsym(&cfg, "jaguarMainRAM");
    if (!ramp || !*ramp) {
        fprintf(stderr, "probe_demo_sentinels: core does not export jaguarMainRAM\n");
        harness_shutdown(&cfg);
        return 2;
    }

    if (!harness_load_rom(&cfg)) {
        fprintf(stderr, "probe_demo_sentinels: failed to load ROM\n");
        harness_shutdown(&cfg);
        return 2;
    }

    harness_run(&cfg);

    ram = *ramp;
    for (i = 0; i < words; i++) {
        uint32_t v = ((uint32_t)ram[SENT_BASE + i * 4 + 0] << 24) |
                     ((uint32_t)ram[SENT_BASE + i * 4 + 1] << 16) |
                     ((uint32_t)ram[SENT_BASE + i * 4 + 2] << 8) |
                     ((uint32_t)ram[SENT_BASE + i * 4 + 3]);
        printf("SENT %02X: %08X\n", i * 4, v);
    }

    harness_shutdown(&cfg);
    return 0;
}
