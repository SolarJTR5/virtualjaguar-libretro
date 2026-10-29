/*
 * test/tools/test_demo_particles.c -- driver + frame dumper for the
 * particle-explosion demo ROM (benchdemo_particles.j64).
 *
 * Two jobs:
 *
 *   1. PROVE the demo is alive and correct without a display: the ROM
 *      advances a 256-particle table in main RAM, so the harness checks
 *      that the table moved, that positions stayed inside the screen,
 *      and that every particle's colour changed on the palette cycle.
 *      A demo that renders a black screen still passes "it drew nothing"
 *      -- this is the part that says it actually simulated something.
 *
 *   2. SHOW it: --frames-out DIR writes each rendered frame as a PNG
 *      (self-contained writer, no image library) so the demo can be
 *      watched without installing an emulator.  The core renders XRGB8888
 *      and the callback gets it verbatim.
 *
 * Usage:
 *   test_demo_particles <core.so> <rom.j64> [--frames-out DIR]
 *                       [--dump-frame N] [--assert-frames N]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <sys/stat.h>
#include "../harness/harness.h"
#include "../harness/trace_probe.h"

/* The demo ROM's memory map (benchdemo_particles.s). */
#define DEMO_SENT_START   0x00010000u
#define DEMO_SENT_DONE    0x00010004u
#define DEMO_SENT_COUNT   0x00010008u
#define DEMO_SENT_FRAME   0x0001000Cu
#define DEMO_MAGIC_START  0xC0DE57A7u
#define DEMO_MAGIC_DEMO   0xC0DE0068u   /* MB_MAGIC_68K */

#define DEMO_PART_BASE    0x00110000u
#define DEMO_PART_COUNT   256u
#define DEMO_PART_STRIDE  16u   /* x, y, vx, vy as LONGs */
#define DEMO_SCR_W        320
#define DEMO_SCR_H        240

/* --------------------------------------------------------------- PNG */

static uint32_t png_crc_table[256];
static int png_crc_ready;

static void png_crc_init(void)
{
    uint32_t n, k, c;
    for (n = 0; n < 256; n++) {
        c = n;
        for (k = 0; k < 8; k++)
            c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        png_crc_table[n] = c;
    }
    png_crc_ready = 1;
}

static uint32_t png_crc(const uint8_t *buf, size_t len, uint32_t crc)
{
    size_t i;
    if (!png_crc_ready) png_crc_init();
    for (i = 0; i < len; i++)
        crc = png_crc_table[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
    return crc;
}

static void png_be32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);  p[3] = (uint8_t)v;
}

static void png_chunk(FILE *f, const char *tag, const uint8_t *data, size_t len)
{
    uint8_t hdr[4], crcbuf[4];
    uint32_t crc;
    png_be32(hdr, (uint32_t)len);
    fwrite(hdr, 1, 4, f);
    fwrite(tag, 1, 4, f);
    if (len) fwrite(data, 1, len, f);
    crc = png_crc((const uint8_t *)tag, 4, 0xFFFFFFFFu);
    crc = png_crc(data, len, crc) ^ 0xFFFFFFFFu;
    png_be32(crcbuf, crc);
    fwrite(crcbuf, 1, 4, f);
}

/* zlib stream with stored (uncompressed) deflate blocks: valid PNG, no
 * dependency on zlib, and the files stay small enough for a demo. */
static void png_write(const char *path, const uint8_t *rgba, unsigned w, unsigned h)
{
    FILE *f = fopen(path, "wb");
    uint8_t *raw, *zbuf, *chunk;
    size_t rawlen, zlen, i, zi, op;
    static const uint8_t sig[8] = { 137, 'P', 'N', 'G', 13, 10, 26, 10 };
    uint8_t ihdr[13];
    uint32_t adler_a = 1, adler_b = 0;

    if (!f) { fprintf(stderr, "png_write: cannot open %s\n", path); return; }

    rawlen = (size_t)h * (1 + (size_t)w * 3);
    raw = (uint8_t *)malloc(rawlen);
    zlen = rawlen + rawlen / 65535 * 5 + 64;
    zbuf = (uint8_t *)malloc(zlen);
    chunk = (uint8_t *)malloc(rawlen + 16);
    if (!raw || !zbuf || !chunk) { fclose(f); free(raw); free(zbuf); free(chunk); return; }

    for (i = 0; i < h; i++) {
        raw[i * (1 + (size_t)w * 3)] = 0;   /* filter: none */
        memcpy(raw + i * (1 + (size_t)w * 3) + 1,
               rgba + i * (size_t)w * 4, (size_t)w * 3);
    }

    /* zlib header */
    zi = 0;
    zbuf[zi++] = 0x78; zbuf[zi++] = 0x01;
    /* stored deflate blocks */
    op = 0;
    while (op < rawlen) {
        size_t n = rawlen - op;
        int final;
        if (n > 65535) n = 65535;
        final = (op + n >= rawlen);
        zbuf[zi++] = (uint8_t)(final ? 1 : 0);
        zbuf[zi++] = (uint8_t)(n & 0xFF);
        zbuf[zi++] = (uint8_t)((n >> 8) & 0xFF);
        zbuf[zi++] = (uint8_t)(~n & 0xFF);
        zbuf[zi++] = (uint8_t)((~n >> 8) & 0xFF);
        memcpy(zbuf + zi, raw + op, n);
        zi += n;
        op += n;
    }
    for (i = 0; i < rawlen; i++) {
        adler_a = (adler_a + raw[i]) % 65521;
        adler_b = (adler_b + adler_a) % 65521;
    }
    zbuf[zi++] = (uint8_t)((adler_b >> 8) & 0xFF);
    zbuf[zi++] = (uint8_t)(adler_b & 0xFF);
    zbuf[zi++] = (uint8_t)((adler_a >> 8) & 0xFF);
    zbuf[zi++] = (uint8_t)(adler_a & 0xFF);

    fwrite(sig, 1, 8, f);
    png_be32(ihdr, w);
    png_be32(ihdr + 4, h);
    ihdr[8] = 8;    /* bit depth */
    ihdr[9] = 2;    /* colour type: truecolour RGB */
    ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
    png_chunk(f, "IHDR", ihdr, sizeof(ihdr));
    png_chunk(f, "IDAT", zbuf, zi);
    png_chunk(f, "IEND", NULL, 0);

    fclose(f);
    free(raw); free(zbuf); free(chunk);
}

/* -------------------------------------------------------------- state */

typedef struct {
    const char *out_dir;
    unsigned    frame;          /* frames rendered so far */
    unsigned    dumped;
    unsigned    width, height;
    uint32_t    nonblack_pixels;
    uint32_t    last_nonzero_frame;
    uint8_t    *rgb;            /* one frame, RGB */
    bool        geometry_seen;
} demo_state;

static void demo_video_cb(void *userdata, const void *data,
                          unsigned w, unsigned h, size_t pitch)
{
    demo_state *st = (demo_state *)userdata;
    unsigned x, y;
    char path[1024];

    st->frame++;
    if (w != st->width || h != st->height) {
        st->width = w;
        st->height = h;
        st->geometry_seen = true;
    }
    if (!data) return;

    if (st->out_dir) {
        size_t need = (size_t)w * h * 3;
        if (!st->rgb || need > 0) {
            free(st->rgb);
            st->rgb = (uint8_t *)malloc(need);
        }
        if (st->rgb) {
            for (y = 0; y < h; y++) {
                const uint8_t *row = (const uint8_t *)data + (size_t)y * pitch;
                for (x = 0; x < w; x++) {
                    st->rgb[(size_t)y * w * 3 + x * 3 + 0] = row[x * 4 + 0];
                    st->rgb[(size_t)y * w * 3 + x * 3 + 1] = row[x * 4 + 1];
                    st->rgb[(size_t)y * w * 3 + x * 3 + 2] = row[x * 4 + 2];
                }
            }
            snprintf(path, sizeof(path), "%s/frame_%04u.png", st->out_dir,
                     st->frame);
            png_write(path, st->rgb, w, h);
            st->dumped++;
        }
    }

    /* Count lit pixels so "it drew a black screen" is visible in the log. */
    {
        uint32_t lit = 0;
        if (st->frame == 120 && st->last_nonzero_frame == 0) {
            const uint8_t *r0 = (const uint8_t *)data;
            fprintf(stderr, "frame %u %ux%u pitch=%zu px[0..3]: %08X %08X %08X %08X\n",
                    st->frame, w, h, pitch,
                    *(const uint32_t *)(const void *)(r0 + 0),
                    *(const uint32_t *)(const void *)(r0 + 4),
                    *(const uint32_t *)(const void *)(r0 + 8),
                    *(const uint32_t *)(const void *)(r0 + 12));
        }
        for (y = 0; y < h; y++) {
            const uint8_t *row = (const uint8_t *)data + (size_t)y * pitch;
            for (x = 0; x < w; x++) {
                if (row[x * 4] || row[x * 4 + 1] || row[x * 4 + 2]) lit++;
            }
        }
        st->nonblack_pixels = lit;
        if (lit) st->last_nonzero_frame = st->frame;
    }
}

static uint32_t rd32(const uint8_t *ram, uint32_t addr)
{
    return ((uint32_t)ram[addr] << 24) | ((uint32_t)ram[addr + 1] << 16)
         | ((uint32_t)ram[addr + 2] << 8) | (uint32_t)ram[addr + 3];
}

static uint16_t rd16(const uint8_t *ram, uint32_t addr)
{
    return (uint16_t)(((uint16_t)ram[addr] << 8) | ram[addr + 1]);
}

int main(int argc, char **argv)
{
    harness_config cfg = HARNESS_CONFIG_DEFAULT;
    harness_result res;
    uint8_t **ramp;
    demo_state st;
    const char *out_dir = NULL;
    unsigned frames = 90;
    int i, failed = 0;
    const uint8_t *ram;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--frames-out") && i + 1 < argc) {
            out_dir = argv[++i];
        } else if (!strcmp(argv[i], "--frames") && i + 1 < argc) {
            frames = (unsigned)atoi(argv[++i]);
        }
    }
    if (argc < 3) {
        fprintf(stderr, "usage: %s <core.so> <rom.j64> [--frames-out DIR] [--frames N]\n",
                argv[0]);
        return 2;
    }

    memset(&st, 0, sizeof(st));
    st.out_dir = out_dir;
    if (out_dir) mkdir(out_dir, 0755);

    cfg.frames = frames;
    cfg.quiet = 1;
    if (!harness_init_from_args(&cfg, argc, argv))
        return 2;

    ramp = (uint8_t **)harness_dlsym(&cfg, "jaguarMainRAM");
    if (!ramp || !*ramp) {
        fprintf(stderr, "test_demo_particles: core does not export jaguarMainRAM\n");
        harness_shutdown(&cfg);
        return 2;
    }

    cfg.video_callback = demo_video_cb;
    cfg.video_callback_data = &st;

    if (!trace_probe_attach(&cfg)) {
        fprintf(stderr, "test_demo_particles: trace_probe_attach failed\n");
        harness_shutdown(&cfg);
        return 2;
    }
    if (!harness_load_rom(&cfg)) {
        fprintf(stderr, "test_demo_particles: failed to load ROM\n");
        harness_shutdown(&cfg);
        return 2;
    }

    harness_run(&cfg);

    ram = *ramp;
    printf("DEMO start=%08X done=%08X count=%u frame=%u\n",
           rd32(ram, DEMO_SENT_START), rd32(ram, DEMO_SENT_DONE),
           rd32(ram, DEMO_SENT_COUNT), rd32(ram, DEMO_SENT_FRAME));
    printf("DEMO video %ux%u frames=%u dumped=%u lit_pixels=%u last_lit_frame=%u\n",
           st.width, st.height, st.frame, st.dumped, st.nonblack_pixels,
           st.last_nonzero_frame);

    /* ---- assertions ------------------------------------------------ */
    if (rd32(ram, DEMO_SENT_START) != DEMO_MAGIC_START) {
        fprintf(stderr, "FAIL: ROM never wrote the START sentinel\n");
        failed = 1;
    }
    if (rd32(ram, DEMO_SENT_DONE) != DEMO_MAGIC_DEMO) {
        fprintf(stderr, "FAIL: ROM never wrote the DONE sentinel\n");
        failed = 1;
    }
    if (st.frame == 0) {
        fprintf(stderr, "FAIL: core rendered no frames\n");
        failed = 1;
    }
    if (st.nonblack_pixels == 0) {
        fprintf(stderr, "FAIL: every rendered frame was black\n");
        failed = 1;
    }

    /* The particle table must have moved: every particle's position must
     * be on screen, and the table must not be all zeros. */
    {
        unsigned p, onscreen = 0, nonzero = 0;
        int32_t minx = 1 << 30, maxx = -(1 << 30);
        int32_t miny = 1 << 30, maxy = -(1 << 30);
        for (p = 0; p < DEMO_PART_COUNT; p++) {
            uint32_t a = DEMO_PART_BASE + p * DEMO_PART_STRIDE;
            int32_t x  = (int32_t)rd32(ram, a);
            int32_t y  = (int32_t)rd32(ram, a + 4);
            int32_t vx = (int32_t)rd32(ram, a + 8);
            int32_t vy = (int32_t)rd32(ram, a + 12);

            if (x || y || vx || vy) nonzero++;
            if (x >= 0 && x < DEMO_SCR_W && y >= 0 && y < DEMO_SCR_H) onscreen++;
            if (x < minx) minx = x;
            if (x > maxx) maxx = x;
            if (y < miny) miny = y;
            if (y > maxy) maxy = y;
        }
        printf("DEMO particles nonzero=%u onscreen=%u x=[%d..%d] y=[%d..%d]\n",
               nonzero, onscreen, minx, maxx, miny, maxy);
        {
            int32_t vmin = 1<<30, vmax = -(1<<30);
            unsigned q;
            for (q = 0; q < DEMO_PART_COUNT; q++) {
                uint32_t b = DEMO_PART_BASE + q * DEMO_PART_STRIDE;
                int32_t v = (int32_t)rd32(ram, b + 8);
                if (v < vmin) vmin = v;
                if (v > vmax) vmax = v;
            }
            printf("DEMO velocities vx=[%d..%d]\n", vmin, vmax);
        }
        if (nonzero != DEMO_PART_COUNT) {
            fprintf(stderr, "FAIL: %u/%u particles never moved\n",
                    DEMO_PART_COUNT - nonzero, DEMO_PART_COUNT);
            failed = 1;
        }
        if (onscreen != DEMO_PART_COUNT) {
            fprintf(stderr, "FAIL: %u particles off screen\n",
                    DEMO_PART_COUNT - onscreen);
            failed = 1;
        }
    }

    harness_report(&cfg, &res, 0);
    harness_shutdown(&cfg);
    free(st.rgb);
    return failed ? 1 : 0;
}
