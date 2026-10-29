/*
 * test/tools/probe_tom_regs.c -- dump TOM's register block and the CLUT
 * after a ROM has run.
 *
 * Ground truth for "what does a working Jaguar program program?": run a
 * real game (test/roms/yarc.j64) or a demo ROM and print the VMODE /
 * VDB / VDE / OLP / BG that the ROM left behind, plus how many CLUT
 * entries it filled.
 *
 * The rendering mode follows from VMODE:
 *   bit 8 (VARMOD) clear -> mode 0: the CRY renderer, every pixel is a
 *                           CLUT index (a game MUST fill the CLUT);
 *   bit 8 set           -> mode 4: the mixed renderer, bit 0 of each
 *                           pixel picks RGB555-direct vs CLUT.
 *
 * Usage: probe_tom_regs <core.so> <rom.j64> [frames]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>
#include "../harness/harness.h"

int main(int argc, char **argv)
{
    harness_config cfg = HARNESS_CONFIG_DEFAULT;
    uint8_t *tom;
    int clut_nonzero = 0, i;

    if (argc < 3) {
        fprintf(stderr, "usage: %s <core.so> <rom.j64> [frames]\n", argv[0]);
        return 2;
    }
    if (argc > 3) cfg.frames = (unsigned)atoi(argv[3]);
    if (!harness_init_from_args(&cfg, argc, argv)) return 2;
    if (!harness_load_rom(&cfg)) return 2;
    harness_run(&cfg);

    tom = (uint8_t *)dlsym(cfg.core_handle, "tomRam8");
    if (!tom) {
        fprintf(stderr, "probe_tom_regs: core does not export tomRam8\n");
        return 2;
    }

#define RD16(o) ((unsigned)((tom[o] << 8) | tom[(o) + 1]))
    printf("OLP   =%06X\n", (unsigned)(((tom[0x20] << 8) | tom[0x21])
                                    | (((tom[0x22] << 8) | tom[0x23]) << 16)));
    printf("VC    =%04X\n", RD16(0x06));
    printf("VMODE =%04X   (bit8=%u -> mode %u)\n", RD16(0x28),
           (RD16(0x28) >> 8) & 1, (((RD16(0x28) & 0x0100) >> 6)
                                  | ((RD16(0x28) & 0x000E) >> 1)) & 7);
    printf("VDB   =%04X\n", RD16(0x46));
    printf("VDE   =%04X\n", RD16(0x48));
    printf("VBB   =%04X\n", RD16(0x40));
    printf("BG    =%04X\n", RD16(0x58));
    printf("HDB1  =%04X  HDE=%04X\n", RD16(0x3A), RD16(0x4A));

    for (i = 0; i < 0x200; i += 2)
        if (tom[0x400 + i] || tom[0x401 + i]) clut_nonzero++;
    printf("CLUT  : %d/256 entries non-zero\n", clut_nonzero);

    /* the object list the game built (OLP), decoded */
    {
        uint32_t olp = (uint32_t)(((tom[0x20] << 8) | tom[0x21])
                                 | (((tom[0x22] << 8) | tom[0x23]) << 16));
        uint8_t **ramp = (uint8_t **)dlsym(cfg.core_handle, "jaguarMainRAM");
        uint8_t *ram = ramp ? *ramp : NULL;
        uint32_t a = olp & 0x1FFFFF;
        int guard = 0;
        printf("object list at %06X:\n", olp);
        while (ram && guard++ < 8) {
            uint64_t p0 = 0, p1 = 0;
            int b;
            for (b = 7; b >= 0; b--) p0 = (p0 << 8) | ram[a + b];
            for (b = 7; b >= 0; b--) p1 = (p1 << 8) | ram[a + 8 + b];
            printf("  obj@%06X raw p0=%016llX p1=%016llX"
                   "  type=%u height=%u link=%06X data=%06X"
                   " depth=%u pitch=%u dwidth=%u iwidth=%u\n",
                   a, (unsigned long long)p0, (unsigned long long)p1,
                   (unsigned)(p0 & 7), (unsigned)((p0 >> 14) & 0x3FF),
                   (unsigned)((p0 >> 21) & 0x3FFFF8),
                   (unsigned)((p0 >> 40) & 0xFFFFF8),
                   (unsigned)((p1 >> 12) & 7), (unsigned)((p1 >> 15) & 7),
                   (unsigned)((p1 & 0x0FFC0000) >> 15),
                   (unsigned)((p1 >> 28) & 0x3FF));
            if ((p0 & 7) == 4) break;           /* STOP */
            a = (uint32_t)((p0 >> 21) & 0x3FFFF8);
            if (!a) break;
        }
    }

    /* the line buffer the OP draws into */
    printf("LBUF  : %02X%02X %02X%02X %02X%02X %02X%02X\n",
           tom[0x1800], tom[0x1801], tom[0x1802], tom[0x1803],
           tom[0x1804], tom[0x1805], tom[0x1806], tom[0x1807]);

    harness_shutdown(&cfg);
    return 0;
}
