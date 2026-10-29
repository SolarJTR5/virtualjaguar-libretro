/*
 * test/tools/probe_op_bitmap.c -- decode-and-dump probe for the OP
 * BITMAP object encoding used by the particle demo ROM.
 *
 * Not a test: a diagnostic.  It installs ONE bitmap object with the exact
 * p0/p1 the demo ROM uses, fills the source with a known pattern, calls
 * OPProcessList() directly (the same entry point the TOM halfline loop
 * calls) and prints what landed in the line buffer.
 *
 * Why this exists: the demo ROM renders a black screen when the object
 * encoding is wrong, and the encoding is easy to get subtly wrong -- the
 * DATA field is bits 40..63 of p0 (so it lands in the HIGH longword),
 * IWIDTH is bits 28..37 and can SPILL into the high longword, PITCH is
 * 3 bits of "bytes per phrase" and dwidth is a separate 10-bit field of
 * "bytes per line".  Reading the LBUF directly says which field is off
 * without guessing.
 *
 * Usage: probe_op_bitmap <core.so> [rom.j64]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <dlfcn.h>
#include "../harness/harness.h"

#define LIST_BASE 0x20000u
#define BMP_OBJ   (LIST_BASE + 0x00)
#define STOP_OBJ  (LIST_BASE + 0x10)
#define SRC_BASE  0x30000u

#define SCR_W 320
#define SCR_H 240

static uint8_t *g_tom;
static uint8_t *g_ram;
static void (*g_opproc)(int, bool);

static void put_phrase(uint32_t addr, uint64_t v)
{
    int i;
    for (i = 7; i >= 0; i--) {
        g_ram[addr + i] = (uint8_t)(v & 0xFF);
        v >>= 8;
    }
}

static void set_olp(uint32_t addr)
{
    g_tom[0x20] = (uint8_t)((addr >> 8) & 0xFF);
    g_tom[0x21] = (uint8_t)(addr & 0xFF);
    g_tom[0x22] = (uint8_t)((addr >> 24) & 0xFF);
    g_tom[0x23] = (uint8_t)((addr >> 16) & 0xFF);
}

static uint64_t make_p0(uint32_t ypos, uint32_t height, uint32_t link, uint32_t data)
{
    uint64_t p0 = 0;
    p0 |= (uint64_t)(ypos & 0x7FF) << 3;
    p0 |= (uint64_t)(height & 0x3FF) << 14;
    p0 |= (uint64_t)(link & 0x3FFFF8) << 21;
    p0 |= (uint64_t)(data & 0xFFFFF8) << 40;
    return p0;
}

static uint64_t make_p1(uint32_t xpos, uint32_t depth, uint32_t pitch,
                        uint32_t dwidth, uint32_t iwidth)
{
    uint64_t p1 = 0;
    p1 |= (uint64_t)(xpos & 0xFFF);
    p1 |= (uint64_t)(depth & 0x07) << 12;
    p1 |= (uint64_t)(pitch & 0x07) << 15;
    p1 |= (uint64_t)(dwidth & 0x3FF) << 18;
    p1 |= (uint64_t)(iwidth & 0x3FF) << 28;
    return p1;
}

static void decode_p1(uint64_t p1)
{
    printf("  decode p1: xpos=%d depth=%u pitch=%u dwidth=%u iwidth=%u\n",
           (int)(int16_t)((p1 << 4) & 0xFFFF) >> 4,
           (unsigned)((p1 >> 12) & 7), (unsigned)((p1 >> 15) & 7),
           (unsigned)((p1 & 0x0FFC0000) >> 15),
           (unsigned)((p1 >> 28) & 0x3FF));
}

int main(int argc, char **argv)
{
    harness_config cfg = HARNESS_CONFIG_DEFAULT;
    uint8_t **ramp;
    uint64_t p0, p1;
    unsigned x, y;
    int i;

    cfg.frames = 1;
    if (!harness_init_from_args(&cfg, argc, argv)) return 2;
    if (argc < 3) cfg.rom_path = "test/microbench/benchdemo_vidprobe.j64";
    if (!harness_load_rom(&cfg)) return 2;
    harness_run(&cfg);

    g_tom = (uint8_t *)dlsym(cfg.core_handle, "tomRam8");
    ramp = (uint8_t **)dlsym(cfg.core_handle, "jaguarMainRAM");
    g_ram = ramp ? *ramp : NULL;
    g_opproc = (void (*)(int, bool))dlsym(cfg.core_handle, "OPProcessList");
    if (!g_tom || !g_ram || !g_opproc) {
        fprintf(stderr, "probe_op_bitmap: needs a TEST_EXPORTS=1 core\n");
        return 2;
    }

    /* Phase 1 (optional): run the ROM itself and look at what TOM's own
     * halfline loop did -- OLP as the ROM left it, the object the ROM
     * installed, and the line buffer the OP wrote during the frame. */
    if (getenv("PROBE_ROM_RUN")) {
        uint64_t rb = 0, r1 = 0;
        int b;
        printf("--- ROM run ---\n");
        printf("OLP=%06X  VC=%04X\n", (unsigned)((g_tom[0x20] << 24) | (g_tom[0x21] << 16)
                                  | (g_tom[0x22] << 8) | g_tom[0x23]),
               (unsigned)((g_tom[0x06] << 8) | g_tom[0x07]));
        {
            static const char *nm[] = {"OLP_LO","OLP_HI","","","","","","","","","",
                "VC","","","HC","","VMODE","","","","","","VDB","","VDE","","",
                "","","","","","","","","","","BG","",0};
            int q;
            printf("TOM regs:");
            for (q = 0; q < 0x60; q += 2)
                printf(" %s=%04X", nm[q/2] ? nm[q/2] : "?", (unsigned)((g_tom[q] << 8) | g_tom[q+1]));
            printf("\n");
        }
        {   /* is the CLUT populated? */
            int q, nonzero = 0;
            for (q = 0; q < 0x200; q += 2)
                if (g_tom[0x400 + q] || g_tom[0x401 + q]) nonzero++;
            printf("CLUT nonzero words: %d/256\n", nonzero);
        }
        for (b = 7; b >= 0; b--) rb = (rb << 8) | g_ram[BMP_OBJ + b];
        for (b = 7; b >= 0; b--) r1 = (r1 << 8) | g_ram[BMP_OBJ + 8 + b];
        printf("rom obj p0=%016llX height=%u data=%06X\n",
               (unsigned long long)rb,
               (unsigned)((rb & 0xFFC000) >> 14),
               (unsigned)((rb & 0xFFFFF80000000000ull) >> 40));
        printf("rom obj p1=%016llX\n", (unsigned long long)r1);
        decode_p1(r1);
        printf("lbuf C[0..7]: %02X %02X %02X %02X %02X %02X %02X %02X\n",
               g_tom[0x1800], g_tom[0x1801], g_tom[0x1802], g_tom[0x1803],
               g_tom[0x1804], g_tom[0x1805], g_tom[0x1806], g_tom[0x1807]);
        {
            int nz = 0;
            for (i = 0; i < 1440; i++) if (g_tom[0x1800 + i]) nz++;
            printf("lbuf C nonzero: %d/1440  A: %02X%02X%02X%02X  B: %02X%02X%02X%02X\n",
                   nz, g_tom[0x800], g_tom[0x801], g_tom[0x802], g_tom[0x803],
                   g_tom[0x1000], g_tom[0x1001], g_tom[0x1002], g_tom[0x1003]);
        }
        {
            uint32_t *sb = (uint32_t *)dlsym(cfg.core_handle, "screenBuffer");
            uint32_t pitch = 0;
            if (sb) {
                unsigned yy, xx, nz = 0;
                for (yy = 0; yy < 240; yy++) {
                    for (xx = 0; xx < 320; xx++) {
                        uint32_t px = sb[(size_t)yy * 320 + xx];
                        if (px & 0x00FFFFFFu) nz++;
                    }
                }
                printf("screenBuffer nonzero pixels: %u\n", nz);
                printf("screenBuffer row0[0..7]: %08X %08X %08X %08X %08X %08X %08X %08X\n",
                       sb[0], sb[1], sb[2], sb[3], sb[4], sb[5], sb[6], sb[7]);
                printf("screenBuffer row100[0..3]: %08X %08X %08X %08X\n",
                       sb[100*320], sb[100*320+1], sb[100*320+2], sb[100*320+3]);
            } else {
                printf("screenBuffer not exported\n");
            }
            (void)pitch;
        }
        /* Call the core's own scanline renderer on the LIVE line buffer
         * and see what it produces.  If it produces our pixels, the
         * renderer is fine and the problem is upstream of it. */
        {
            typedef void (*render_fn)(uint32_t *);
            render_fn *tbl = (render_fn *)dlsym(cfg.core_handle, "scanline_render");
            uint32_t buf[320];
            int m;
            for (m = 0; m < 8; m++) {
                memset(buf, 0, sizeof(buf));
                if (tbl && tbl[m]) {
                    tbl[m](buf);
                    printf("scanline_render[%d]: %08X %08X %08X %08X\n",
                           m, buf[0], buf[1], buf[2], buf[3]);
                }
            }
            {
                uint32_t *mix = (uint32_t *)dlsym(cfg.core_handle, "MIX16ToRGB32");
                if (mix) {
                    printf("MIX16ToRGB32[0x8001] = %08X  [0x0000] = %08X\n",
                           mix[0x8001], mix[0]);
                } else {
                    printf("MIX16ToRGB32 not exported\n");
                }
            }
        }
        printf("rom snapshot @100000:");
        for (i = 0; i < 32; i++) printf(" %02X", g_ram[0x100000 + i]);
        printf("\n");
        /* Where did the object list actually land? */
        {
            int a;
            printf("ram $20000..$2001f:");
            for (a = 0; a < 32; a++) printf(" %02X", g_ram[0x20000 + a]);
            printf("\n");
            printf("ram $30000..$30007:");
            for (a = 0; a < 8; a++) printf(" %02X", g_ram[0x30000 + a]);
            printf("\n");
            /* hunt for the p0 signature 03 00 00 40 anywhere in RAM */
            {
                uint32_t hit = 0xFFFFFFFFu, n = 0;
                for (a = 0; a < 0x200000 - 4; a++) {
                    if (g_ram[a] == 0x03 && g_ram[a+1] == 0x00 &&
                        g_ram[a+2] == 0x00 && g_ram[a+3] == 0x40) {
                        if (hit == 0xFFFFFFFFu) hit = (uint32_t)a;
                        n++;
                    }
                }
                printf("p0_hi signature hits: %u (first at %08X)\n", n, hit);
            }
        }
        harness_shutdown(&cfg);
        return 0;
    }

    /* Source: pixel (x,y) = RGB555 with bit15 (RGB mode) and bit0 (RGB
     * select) set, red = x>>3, green = y>>3 -- the same pattern the demo
     * ROM paints. */
    for (y = 0; y < SCR_H; y++) {
        uint8_t *row = g_ram + SRC_BASE + (size_t)y * SCR_W * 2;
        for (x = 0; x < SCR_W; x++) {
            uint16_t v = (uint16_t)(0x8001 | ((x >> 3) << 11) | ((y >> 3) << 5));
            row[x * 2 + 0] = (uint8_t)(v >> 8);
            row[x * 2 + 1] = (uint8_t)(v & 0xFF);
        }
    }

    p0 = make_p0(0, SCR_H, STOP_OBJ, SRC_BASE);
    p1 = make_p1(0, 4, 1, SCR_W * 2 / 8, SCR_W / 4);
    printf("p0=%016llX p1=%016llX\n",
           (unsigned long long)p0, (unsigned long long)p1);
    decode_p1(p1);

    put_phrase(BMP_OBJ, p0);
    put_phrase(BMP_OBJ + 8, p1);
    put_phrase(STOP_OBJ, 0x04ull);
    set_olp(LIST_BASE);

    memset(&g_tom[0x1800], 0, 1440);
    g_opproc(100, 1);

    printf("lbuf[0..15]:");
    for (i = 0; i < 16; i++) printf(" %02X", g_tom[0x1800 + i]);
    printf("\n");
    {
        int nonzero = 0;
        for (i = 0; i < 1440; i++) if (g_tom[0x1800 + i]) nonzero++;
        printf("lbuf nonzero bytes: %d/1440\n", nonzero);
    }

    /* The OP rewrites p0 (HEIGHT--, DATA+=dwidth): show what it thinks. */
    {
        uint64_t rb = 0;
        int b;
        for (b = 7; b >= 0; b--) rb = (rb << 8) | g_ram[BMP_OBJ + b];
        printf("p0 after OP: %016llX  height=%u data=%06X\n",
               (unsigned long long)rb,
               (unsigned)((rb & 0xFFC000) >> 14),
               (unsigned)((rb & 0xFFFFF80000000000ull) >> 40));
    }

    harness_shutdown(&cfg);
    return 0;
}
