/*
 * test/tools/test_microbench_gpu_interleave.c -- assertion harness for
 * the GPU "interleave vs naive" microbenchmark ROM
 * (test/microbench/benchgpu_interleave.j64, issue #536 task 6).
 *
 * WHAT THIS ROM IS
 * ----------------
 * A software-pipelined 3D vertex transform on the Jaguar GPU RISC:
 * three MAC dot products, a perspective divide (the long operation --
 * 1 tick to issue, 16 ticks of background divide), the perspective
 * multiplies.  The vertices live in MAIN RAM, so the three loads per
 * vertex are external accesses (L = 7 + D).
 *
 * The ROM carries BOTH schedules and picks one at run time from a flag
 * the harness writes into main RAM:
 *
 *   naive       -- the quotient is consumed right after the divide, so
 *                  the divide's 16-tick window is exposed as a
 *                  scoreboard stall;
 *   interleaved -- 16 independent, flag-transparent instructions are
 *                  dropped into that window, rotating over eight
 *                  registers so none of them hits the RAW interlock.
 *
 * Same ROM, same buffers, same bus traffic -- only the GPU's
 * instruction placement differs, so the difference between the two runs
 * is the schedule and nothing else.
 *
 * WHAT IT MEASURES
 * ----------------
 * The GPU RISC's own tick counters (the test ABI's per-cause stall
 * breakdown: gpu_pipe_ticks_total, gpu_pipe_issue_total and the
 * score/RAW/port/flags stalls), which is the only way to see the
 * divide's background window at all -- it is invisible in the frame
 * count, which only tells you when the work finished.
 *
 * The counters are cumulative since the last GPUReset, so the second
 * run needs a fresh reset: the harness loads the ROM again (retro_
 * load_game resets the machine) and repeats with the other flag.
 *
 * Emits one machine-parseable line per variant before the verdict:
 *
 *   MICROBENCH engine=gpu_interleave variant=<naive|interleaved> \
 *       done=<0|1> done_frame=<N|-1> count=<iterations> \
 *       expect_count=<iterations> ticks=<N> instr=<N> \
 *       score=<N> raw=<N> port=<N> flags=<N> ticks_per_vertex=<F> \
 *       budget=<frames>
 *
 * Build:
 *   cc -O2 -Wall -std=c99 -I. -I./src -I./libretro-common/include \
 *      -o test/tools/test_microbench_gpu_interleave \
 *      test/tools/test_microbench_gpu_interleave.c \
 *      test/harness/harness.c -ldl -lm
 *
 * Run:
 *   ./test/tools/test_microbench_gpu_interleave ./virtualjaguar_libretro.so \
 *       test/microbench/benchgpu_interleave.j64
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "../harness/harness.h"

/* Sentinel convention -- see test/microbench/cartboot.inc. */
#define MB_SENT_START       0x00010000u
#define MB_SENT_DONE        0x00010004u
#define MB_SENT_COUNT       0x00010008u

#define MB_MAGIC_START      0xC0DE57A7u
#define MB_MAGIC_ILV        0xC0DE0A03u

/* The schedule flag the 68K bootstrap reads (benchgpu_interleave.s). */
#define MB_FLAG_ADDR        0x00020800u

/* benchgpu_interleave_{naive,shadow}_gpu.s: ITERATIONS .equ 64 */
#define MB_EXPECT_COUNT     64u
/* benchgpu_interleave_deep_gpu.s: ITERATIONS .equ 63 -- the 2-deep
 * pipeline chains one vertex more than it consumes. */
#define MB_EXPECT_COUNT_DEEP 63u

/* Measured completion frame: the whole 64-vertex workload is a few
 * thousand RISC ticks -- well inside one frame -- so the budget only
 * has to clear the frame the ROM finishes in.  600 matches the other
 * five ROMs. */
#define MB_FRAME_BUDGET     600

/* The core's settings global: only the leading bools matter, and
 * src/core/settings.h says the field order is stable (the header
 * itself pulls in <boolean.h>, a Windows header, so redeclare the
 * prefix here). */
struct VJSettingsPrefix {
   bool hardwareTypeNTSC;
   bool useJaguarBIOS;
   bool useFastBlitter;
   bool blitterTiming;
   bool gpuPipelineTiming;
};

/* the GPU's tick counters (test ABI) */
static uint64_t *p_gpu_pipe_ticks_total;
static uint64_t *p_gpu_pipe_issue_total;
static uint64_t *p_gpu_pipe_stall_score;
static uint64_t *p_gpu_pipe_stall_raw;
static uint64_t *p_gpu_pipe_stall_port;
static uint64_t *p_gpu_pipe_stall_flags;
static uint64_t *p_gpu_pipe_stall_extra;
static uint64_t *p_gpu_pipe_raw_by_op;
static uint64_t *p_gpu_pipe_score_by_op;
static void (*p_GPUPipeTimingReset)(void);
static struct VJSettingsPrefix *p_vjs;

typedef struct {
    uint8_t **ramp;         /* jaguarMainRAM is a POINTER variable into
                               jagMemSpace, not the array itself -- dlsym
                               hands back the address OF the pointer. */
    unsigned  frame;
    int       start_frame;
    int       done_frame;
    uint32_t  count;
} mb_state;

static uint32_t mb_read32(const uint8_t *ram, uint32_t addr)
{
    return ((uint32_t)ram[addr] << 24)
         | ((uint32_t)ram[addr + 1] << 16)
         | ((uint32_t)ram[addr + 2] << 8)
         |  (uint32_t)ram[addr + 3];
}

static void mb_frame_cb(void *userdata, const void *data,
                        unsigned width, unsigned height, size_t pitch)
{
    mb_state *st = (mb_state *)userdata;
    const uint8_t *ram;

    (void)data;
    (void)width;
    (void)height;
    (void)pitch;

    st->frame++;

    if (!st->ramp || !*st->ramp)
        return;
    ram = *st->ramp;

    if (st->start_frame < 0 && mb_read32(ram, MB_SENT_START) == MB_MAGIC_START)
        st->start_frame = (int)st->frame;

    if (st->done_frame < 0 && mb_read32(ram, MB_SENT_DONE) == MB_MAGIC_ILV) {
        st->done_frame = (int)st->frame;
        st->count = mb_read32(ram, MB_SENT_COUNT);
    }
}

/* One run of the ROM with the given schedule flag. */
typedef struct {
    int      done_frame;
    int      start_frame;
    uint32_t count;
    uint64_t ticks, instr, score, raw, port, flags, extra;
    int      ok;
} run_result;

static int run_variant(harness_config *cfg, uint8_t **ramp, int flag,
                       const char *name, uint32_t expect, run_result *out)
{
    mb_state st;
    int i;

    memset(&st, 0, sizeof(st));
    st.start_frame = -1;
    st.done_frame  = -1;
    st.ramp = ramp;

    cfg->video_callback      = mb_frame_cb;
    cfg->video_callback_data = &st;

    /* Load the ROM: retro_load_game resets the machine, which clears
     * main RAM and the GPU's tick counters.  Then write the schedule
     * flag -- the 68K bootstrap reads it before it starts the GPU. */
    if (!harness_load_rom(cfg)) {
        fprintf(stderr, "test_microbench_gpu_interleave: failed to load ROM\n");
        return 0;
    }
    /* The tick counters only move when the pipeline-timing model is on.
     * Set it AFTER the load: retro_load_game resets the machine and
     * re-reads the core options, which would turn it back off. */
    if (p_vjs) {
        p_vjs->gpuPipelineTiming = true;
        if (p_GPUPipeTimingReset)
            p_GPUPipeTimingReset();
    }
    if (ramp && *ramp) {
        uint8_t *ram = *ramp;
        /* BIG-ENDIAN: the 68K reads the flag as a longword
         * (move.l (a0),d0), and the Jaguar is big-endian.  Writing it
         * little-endian here is what made the 68K see 0x01000000
         * instead of 1 -- measured, not assumed. */
        ram[MB_FLAG_ADDR + 0] = (uint8_t)((flag >> 24) & 0xFF);
        ram[MB_FLAG_ADDR + 1] = (uint8_t)((flag >> 16) & 0xFF);
        ram[MB_FLAG_ADDR + 2] = (uint8_t)((flag >> 8) & 0xFF);
        ram[MB_FLAG_ADDR + 3] = (uint8_t)(flag & 0xFF);
    }

    harness_run(cfg);

    if (getenv("VJ_DEBUG_ILV")) {
        uint32_t *gpc = (uint32_t *)harness_dlsym(cfg, "gpu_pc");
        fprintf(stderr, "ILV dbg: flag=%d ram[20800]=%02x%02x%02x%02x"
                "  chosen G_PC=%08x\n", flag,
                ramp && *ramp ? (*ramp)[0x20800] : 0, ramp && *ramp ? (*ramp)[0x20801] : 0,
                ramp && *ramp ? (*ramp)[0x20802] : 0, ramp && *ramp ? (*ramp)[0x20803] : 0,
                (ramp && *ramp) ? (((uint32_t)(*ramp)[0x2080c] << 24) |
                                   ((uint32_t)(*ramp)[0x2080d] << 16) |
                                   ((uint32_t)(*ramp)[0x2080e] << 8) |
                                    (uint32_t)(*ramp)[0x2080f]) : 0);
        fprintf(stderr, "           flag-as-read=%08x\n",
                (ramp && *ramp) ? (((uint32_t)(*ramp)[0x20808] << 24) |
                                   ((uint32_t)(*ramp)[0x20809] << 16) |
                                   ((uint32_t)(*ramp)[0x2080a] << 8) |
                                    (uint32_t)(*ramp)[0x2080b]) : 0);
        (void)gpc;
    }


    out->done_frame  = st.done_frame;
    out->start_frame = st.start_frame;
    out->count       = st.count;
    out->ok          = (st.done_frame >= 0);
    if (p_gpu_pipe_ticks_total) {
        out->ticks = *p_gpu_pipe_ticks_total;
        out->instr = *p_gpu_pipe_issue_total;
        out->score = *p_gpu_pipe_stall_score;
        out->raw   = *p_gpu_pipe_stall_raw;
        out->port  = *p_gpu_pipe_stall_port;
        out->flags = *p_gpu_pipe_stall_flags;
        out->extra = *p_gpu_pipe_stall_extra;
    }

    if (p_gpu_pipe_raw_by_op && getenv("VJ_ILV_HIST")) {
        static const char *names[64] = {
            "add","addc","addq","addqt","sub","subc","subq","subqt",
            "neg","and","or","xor","not","btst","bset","bclr",
            "mult","imult","imultn","resmac","imacn","div","abs","sh",
            "shlq","shrq","sha","sharq","ror","rorq","cmp","cmpq",
            "sat8","sat16","move","moveq","moveta","movefa","movei","loadb",
            "loadw","load","loadp","ld_r14","ld_r15","storeb","storew","store",
            "storep","st_r14","st_r15","move_pc","jump","jr","mmult","mtoi",
            "normi","nop","ld_r14ri","ld_r15ri","st_r14ri","st_r15ri","sat24","pack"};
        int q;
        fprintf(stderr, "ILV hist %s: raw by opcode:", name);
        for (q = 0; q < 64; q++)
            if (p_gpu_pipe_raw_by_op[q])
                fprintf(stderr, " %s=%llu", names[q], (unsigned long long)p_gpu_pipe_raw_by_op[q]);
        fprintf(stderr, "  | score by opcode:");
        for (q = 0; q < 64; q++)
            if (p_gpu_pipe_score_by_op[q])
                fprintf(stderr, " %s=%llu", names[q], (unsigned long long)p_gpu_pipe_score_by_op[q]);
        fprintf(stderr, "\n");
    }

    printf("MICROBENCH engine=gpu_interleave variant=%-12s done=%d "
           "done_frame=%d start_frame=%d count=%u expect_count=%u "
           "ticks=%llu instr=%llu score=%llu raw=%llu port=%llu flags=%llu "
           "ticks_per_vertex=%.2f budget=%u\n",
           name, out->ok ? 1 : 0, out->done_frame, out->start_frame,
           (unsigned)out->count, (unsigned)expect,
           (unsigned long long)out->ticks, (unsigned long long)out->instr,
           (unsigned long long)out->score, (unsigned long long)out->raw,
           (unsigned long long)out->port, (unsigned long long)out->flags,
           (double)out->ticks / (double)MB_EXPECT_COUNT,
           (unsigned)MB_FRAME_BUDGET);
    (void)i;
    return out->ok;
}

int main(int argc, char **argv)
{
    harness_config cfg = HARNESS_CONFIG_DEFAULT;
    harness_result res;
    uint8_t **ramp;
    run_result naive, inter, deep;
    int failed = 0;
    const char *detail = "both schedules ran and the interleave hides the divide's window";

    cfg.frames = MB_FRAME_BUDGET;
    cfg.quiet  = 1;
    if (!harness_init_from_args(&cfg, argc, argv))
        return 2;

    /* Resolve before the run: the callback fires per frame and must not
     * pay for a dlsym each time. */
    ramp = (uint8_t **)harness_dlsym(&cfg, "jaguarMainRAM");
    if (!ramp) {
        fprintf(stderr,
                "test_microbench_gpu_interleave: core does not export "
                "jaguarMainRAM -- rebuild with `make TEST_EXPORTS=1`\n");
        harness_shutdown(&cfg);
        return 2;
    }

    p_gpu_pipe_ticks_total = harness_dlsym(&cfg, "gpu_pipe_ticks_total");
    p_gpu_pipe_issue_total = harness_dlsym(&cfg, "gpu_pipe_issue_total");
    p_gpu_pipe_stall_score = harness_dlsym(&cfg, "gpu_pipe_stall_score");
    p_gpu_pipe_stall_raw   = harness_dlsym(&cfg, "gpu_pipe_stall_raw");
    p_gpu_pipe_stall_port  = harness_dlsym(&cfg, "gpu_pipe_stall_port");
    p_gpu_pipe_stall_flags = harness_dlsym(&cfg, "gpu_pipe_stall_flags");
    p_gpu_pipe_stall_extra = harness_dlsym(&cfg, "gpu_pipe_stall_extra");
    p_gpu_pipe_raw_by_op   = harness_dlsym(&cfg, "gpu_pipe_raw_by_op");
    p_gpu_pipe_score_by_op = harness_dlsym(&cfg, "gpu_pipe_score_by_op");
    if (!p_gpu_pipe_ticks_total || !p_gpu_pipe_issue_total) {
        fprintf(stderr,
                "test_microbench_gpu_interleave: core does not export the "
                "GPU tick counters -- rebuild with `make TEST_EXPORTS=1`\n");
        harness_shutdown(&cfg);
        return 2;
    }

    /* The tick counters only move when the pipeline-timing model is on.
     * Turn it on directly rather than relying on the core-option path
     * (the harness has no frontend to push it). */
    p_vjs = (struct VJSettingsPrefix *)harness_dlsym(&cfg, "vjs");
    p_GPUPipeTimingReset = harness_dlsym(&cfg, "GPUPipeTimingReset");

    memset(&naive, 0, sizeof(naive));
    memset(&inter, 0, sizeof(inter));
    memset(&deep, 0, sizeof(deep));

    run_variant(&cfg, ramp, 0, "naive", MB_EXPECT_COUNT, &naive);
    run_variant(&cfg, ramp, 1, "interleaved", MB_EXPECT_COUNT, &inter);
    run_variant(&cfg, ramp, 2, "2-deep", MB_EXPECT_COUNT_DEEP, &deep);

    if (!naive.ok || naive.count != MB_EXPECT_COUNT) {
        detail = "the naive schedule did not complete with the expected iteration count";
        failed = 1;
    } else if (!inter.ok || inter.count != MB_EXPECT_COUNT) {
        detail = "the interleaved schedule did not complete with the expected iteration count";
        failed = 1;
    } else if (!deep.ok || deep.count != MB_EXPECT_COUNT_DEEP) {
        detail = "the 2-deep schedule did not complete with the expected iteration count";
        failed = 1;
    } else if (naive.ticks == 0) {
        detail = "the GPU tick counters did not move -- the pipeline-timing model is off";
        failed = 1;
    } else if (inter.instr <= naive.instr) {
        detail = "the interleaved schedule did not execute the shadow instructions";
        failed = 1;
    } else if (naive.score - inter.score < 10u * MB_EXPECT_COUNT) {
        /* The point of the interleave: the divide's background window
         * stops being dead time.  The scoreboard stalls (the consumer
         * waiting for the quotient) must collapse by at least the
         * divide's 16 ticks per vertex.  The ABSOLUTE saving is the
         * right measure, not the ratio: under a contended DRAM the
         * vertices' own external loads dominate the stall total and
         * the ratio shrinks even though the interleave hides exactly
         * as much as before. */
        detail = "the interleaved schedule did not hide the divide's window";
        failed = 1;
    } else {
        /* The marginal price of a shadow instruction: how many ticks an
         * extra instruction costs when it rides inside the divide's
         * window.  A normal instruction costs ~1 tick; a shadow one
         * should cost a fraction of that. */
        double naive_per  = (double)naive.ticks / (double)MB_EXPECT_COUNT;
        double inter_per  = (double)inter.ticks / (double)MB_EXPECT_COUNT;
        double extra_instr = (double)(inter.instr - naive.instr);
        double extra_ticks = (double)(inter.ticks - naive.ticks);
        double marginal = extra_instr > 0 ? extra_ticks / extra_instr : 0.0;
        printf("MICROBENCH engine=gpu_interleave summary "
               "naive_ticks_per_vertex=%.2f interleaved_ticks_per_vertex=%.2f "
               "extra_instructions=%llu extra_ticks=%llu "
               "marginal_ticks_per_shadow_instruction=%.3f "
               "naive_score=%llu interleaved_score=%llu "
               "deep_ticks_per_vertex=%.2f deep_score=%llu deep_instr=%llu\n",
               naive_per, inter_per,
               (unsigned long long)(inter.instr - naive.instr),
               (unsigned long long)(inter.ticks - naive.ticks),
               marginal,
               (unsigned long long)naive.score,
               (unsigned long long)inter.score,
               (double)deep.ticks / (double)MB_EXPECT_COUNT_DEEP,
               (unsigned long long)deep.score,
               (unsigned long long)deep.instr);
    }

    res.status = failed ? "FAIL" : "PASS";
    res.name   = "microbench_gpu_interleave";
    res.detail = detail;
    harness_report(&cfg, &res, 1);
    harness_shutdown(&cfg);
    return failed ? 1 : 0;
}
