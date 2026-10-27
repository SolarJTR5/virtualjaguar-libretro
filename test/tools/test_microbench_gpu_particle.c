/*
 * test/tools/test_microbench_gpu_particle.c -- assertion harness for
 * the GPU particle-transform microbenchmark pair:
 *
 *   benchgpu_particle.j64        2-deep schedule   (variant 1)
 *   benchgpu_particle_naive.j64  immediate consume (variant 2)
 *
 * WHAT THIS ASSERTS
 * -----------------
 * Three independent claims, because "the ROM works" is three claims:
 *
 *   1. COMPLETION   -- the GPU ran the expected number of particles.
 *   2. CORRECTNESS  -- the output buffer at $00030000 holds exactly what
 *                      the integer model says it should, word for word.
 *                      A timing-only assertion passes a ROM that computes
 *                      garbage; the first revision of this benchmark did
 *                      exactly that (it stored results through the input
 *                      cursor, so every particle after P0 was loaded back
 *                      in as x=y=0).  See particle_reference.py.
 *   3. SCHEDULE     -- the 2-deep run keeps scoreboard stalls near zero,
 *                      and the naive control DOES show the divider's
 *                      latency.  The second half matters: without it, a
 *                      "quiet" counter could simply mean the divisor was
 *                      never waited on in either ROM.
 *
 * The two ROMs are a controlled pair: check_particle_permutation.py
 * proves their steady-state bodies are the same 25-instruction multiset,
 * so the tick difference is placement and nothing else.
 *
 * The per-particle math (mirrored from the RISC payload):
 *
 *   input   P_i = (3i, 3i+1, 3i+2, 3i+3)      (the 68K bootstrap's fill)
 *   x += vx ; y += vy ; vx += 1 ; vy += 1
 *   q     = 65536 / y
 *   out_x = x * q ; out_y = y * q
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "../harness/harness.h"

/* Sentinel convention (cartboot.inc) */
#define MB_SENT_START       0x00010000u
#define MB_SENT_DONE        0x00010004u
#define MB_SENT_COUNT       0x00010008u
#define MB_SENT_VARIANT     0x0001000Cu

#define MB_MAGIC_START      0xC0DE57A7u
#define MB_MAGIC_PART       0xC0DE0B01u

/* Working set (particle_boot.inc / the payload sources) */
#define MB_PART_COUNT       256u
#define MB_PART_STRIDE      16u
#define MB_OUT_BASE         0x00030000u
#define MB_FIXED            65536u

#define MB_VARIANT_DEEP     1u
#define MB_VARIANT_NAIVE    2u

#define MB_FRAME_BUDGET     600

/* The gates.  Deep: the schedule must not wait on the divider.  Naive:
 * the control must visibly wait, or the comparison proves nothing. */
#define MB_DEEP_SCORE_MAX   20u
#define MB_NAIVE_SCORE_MIN  1000u

struct VJSettingsPrefix {
   bool hardwareTypeNTSC;
   bool useJaguarBIOS;
   bool useFastBlitter;
   bool blitterTiming;
   bool gpuPipelineTiming;
};

static uint64_t *p_gpu_pipe_ticks_total;
static uint64_t *p_gpu_pipe_issue_total;
static uint64_t *p_gpu_pipe_stall_score;
static uint64_t *p_gpu_pipe_stall_raw;
static uint64_t *p_gpu_pipe_stall_port;
static uint64_t *p_gpu_pipe_stall_flags;
static uint64_t *p_gpu_pipe_raw_by_op;
static uint64_t *p_gpu_pipe_score_by_op;
static void (*p_GPUPipeTimingReset)(void);
static struct VJSettingsPrefix *p_vjs;

typedef struct {
    uint8_t **ramp;
    unsigned frame;
    int start_frame;
    int done_frame;
    uint32_t count;
} mb_state;

static uint32_t mb_read32(const uint8_t *ram, uint32_t addr)
{
    return ((uint32_t)ram[addr] << 24)
         | ((uint32_t)ram[addr + 1] << 16)
         | ((uint32_t)ram[addr + 2] << 8)
         |  (uint32_t)ram[addr + 3];
}

/* Bit-exact check of the output buffer against the integer model.
 * Returns true when every particle matches and the invariant holds. */
static bool mb_check_output(const uint8_t *ram, uint32_t *bad,
                            uint32_t *weak, uint32_t *first)
{
    uint32_t i;

    *bad = 0;
    *weak = 0;
    *first = 0xFFFFFFFFu;

    for (i = 0; i < MB_PART_COUNT; i++)
    {
        uint32_t d  = 3u * i;
        uint32_t x  = (d + (d + 2u)) & 0xFFFFFFFFu;         /* x += vx */
        uint32_t y  = ((d + 1u) + (d + 3u)) & 0xFFFFFFFFu;  /* y += vy */
        uint32_t q  = y ? (MB_FIXED / y) : 0u;
        uint32_t ex = x * q;
        uint32_t ey = y * q;
        uint32_t base = MB_OUT_BASE + i * MB_PART_STRIDE;
        uint32_t gx = mb_read32(ram, base);
        uint32_t gy = mb_read32(ram, base + 4);

        if (gx != ex || gy != ey) {
            if (*bad == 0)
                *first = i;
            (*bad)++;
        }
        /* out_y = FIXED - (FIXED mod y), so it can only fall by y-1:
         * FIXED-(y-1) <= gy <= FIXED, i.e. gy + y > FIXED. */
        if (gy > MB_FIXED || gy + y <= MB_FIXED)
            (*weak)++;
    }

    return *bad == 0 && *weak == 0;
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

    if (st->done_frame < 0 && mb_read32(ram, MB_SENT_DONE) == MB_MAGIC_PART) {
        st->done_frame = (int)st->frame;
        st->count = mb_read32(ram, MB_SENT_COUNT);
    }
}

typedef struct {
    int done_frame, start_frame;
    uint32_t count, variant;
    uint64_t ticks, instr, score, raw, port, flags;
    uint32_t bad, weak, first;
    int ok;
} run_result;

int main(int argc, char **argv)
{
    harness_config cfg = HARNESS_CONFIG_DEFAULT;
    harness_result res;
    uint8_t **ramp;
    mb_state st;
    run_result out;
    int failed = 0;
    int data_ok;
    const char *detail = "particle transform computed the reference values";
    const char *vname;

    cfg.frames = MB_FRAME_BUDGET;
    cfg.quiet  = 1;
    if (!harness_init_from_args(&cfg, argc, argv))
        return 2;

    ramp = (uint8_t **)harness_dlsym(&cfg, "jaguarMainRAM");
    if (!ramp) {
        fprintf(stderr, "test_microbench_gpu_particle: core does not export jaguarMainRAM\n");
        harness_shutdown(&cfg);
        return 2;
    }

    p_gpu_pipe_ticks_total = harness_dlsym(&cfg, "gpu_pipe_ticks_total");
    p_gpu_pipe_issue_total = harness_dlsym(&cfg, "gpu_pipe_issue_total");
    p_gpu_pipe_stall_score = harness_dlsym(&cfg, "gpu_pipe_stall_score");
    p_gpu_pipe_stall_raw   = harness_dlsym(&cfg, "gpu_pipe_stall_raw");
    p_gpu_pipe_stall_port  = harness_dlsym(&cfg, "gpu_pipe_stall_port");
    p_gpu_pipe_stall_flags = harness_dlsym(&cfg, "gpu_pipe_stall_flags");
    p_gpu_pipe_raw_by_op   = harness_dlsym(&cfg, "gpu_pipe_raw_by_op");
    p_gpu_pipe_score_by_op = harness_dlsym(&cfg, "gpu_pipe_score_by_op");
    if (!p_gpu_pipe_ticks_total || !p_gpu_pipe_issue_total) {
        fprintf(stderr, "test_microbench_gpu_particle: core does not export the GPU tick counters\n");
        harness_shutdown(&cfg);
        return 2;
    }

    p_vjs = (struct VJSettingsPrefix *)harness_dlsym(&cfg, "vjs");
    p_GPUPipeTimingReset = harness_dlsym(&cfg, "GPUPipeTimingReset");

    memset(&st, 0, sizeof(st));
    st.start_frame = -1;
    st.done_frame  = -1;
    st.ramp = ramp;
    cfg.video_callback = mb_frame_cb;
    cfg.video_callback_data = &st;

    if (!harness_load_rom(&cfg)) {
        fprintf(stderr, "test_microbench_gpu_particle: failed to load ROM\n");
        return 0;
    }
    if (p_vjs) {
        p_vjs->gpuPipelineTiming = true;
        if (p_GPUPipeTimingReset)
            p_GPUPipeTimingReset();
    }

    harness_run(&cfg);

    memset(&out, 0, sizeof(out));
    out.done_frame = st.done_frame;
    out.start_frame = st.start_frame;
    out.count = st.count;
    out.ok = (st.done_frame >= 0);
    if (p_gpu_pipe_ticks_total) {
        out.ticks = *p_gpu_pipe_ticks_total;
        out.instr = *p_gpu_pipe_issue_total;
        out.score = *p_gpu_pipe_stall_score;
        out.raw   = *p_gpu_pipe_stall_raw;
        out.port  = *p_gpu_pipe_stall_port;
        out.flags = *p_gpu_pipe_stall_flags;
    }

    /* The machine has stopped; read the sentinels and the results out of
     * main RAM as it stands. */
    {
        const uint8_t *ram = (ramp && *ramp) ? *ramp : NULL;
        out.variant = ram ? mb_read32(ram, MB_SENT_VARIANT) : 0;
        data_ok = ram ? mb_check_output(ram, &out.bad, &out.weak, &out.first)
                      : 0;
    }

    vname = (out.variant == MB_VARIANT_DEEP)  ? "2-deep"
          : (out.variant == MB_VARIANT_NAIVE) ? "naive"
          : "unknown";

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
        fprintf(stderr, "ILV hist %s: raw by opcode:", vname);
        for (q = 0; q < 64; q++)
            if (p_gpu_pipe_raw_by_op[q])
                fprintf(stderr, " %s=%llu", names[q], (unsigned long long)p_gpu_pipe_raw_by_op[q]);
        fprintf(stderr, "  | score by opcode:");
        for (q = 0; q < 64; q++)
            if (p_gpu_pipe_score_by_op[q])
                fprintf(stderr, " %s=%llu", names[q], (unsigned long long)p_gpu_pipe_score_by_op[q]);
        fprintf(stderr, "\n");
    }

    printf("MICROBENCH engine=gpu_particle variant=%s "
           "done=%d done_frame=%d start_frame=%d count=%u expect_count=%u "
           "ticks=%llu instr=%llu score=%llu raw=%llu port=%llu flags=%llu "
           "data_bad=%u ticks_per_particle=%.2f budget=%u\n",
           vname,
           out.ok ? 1 : 0, out.done_frame, out.start_frame,
           (unsigned)out.count, (unsigned)MB_PART_COUNT,
           (unsigned long long)out.ticks, (unsigned long long)out.instr,
           (unsigned long long)out.score, (unsigned long long)out.raw,
           (unsigned long long)out.port, (unsigned long long)out.flags,
           (unsigned)out.bad,
           out.count > 0 ? (double)out.ticks / (double)out.count : 0.0,
           (unsigned)MB_FRAME_BUDGET);

    if (!out.ok || out.count != MB_PART_COUNT) {
        detail = "particle transform did not complete with expected count";
        failed = 1;
    } else if (out.ticks == 0) {
        detail = "the GPU tick counters did not move";
        failed = 1;
    } else if (out.variant != MB_VARIANT_DEEP && out.variant != MB_VARIANT_NAIVE) {
        detail = "ROM did not publish a known schedule variant";
        failed = 1;
    } else if (!data_ok) {
        static char buf[160];
        snprintf(buf, sizeof(buf),
                 "output buffer does not match the reference model "
                 "(%u particles wrong, %u outside the out_y invariant, "
                 "first bad P%u)", out.bad, out.weak, out.first);
        detail = buf;
        failed = 1;
    } else if (out.variant == MB_VARIANT_DEEP
               && out.score > MB_DEEP_SCORE_MAX) {
        detail = "too many scoreboard stalls in the 2-deep schedule";
        failed = 1;
    } else if (out.variant == MB_VARIANT_NAIVE
               && out.score < MB_NAIVE_SCORE_MIN) {
        detail = "the naive control did not stall on the divider -- "
                 "the A/B comparison would be meaningless";
        failed = 1;
    }

    res.status = failed ? "FAIL" : "PASS";
    res.name   = "microbench_gpu_particle";
    res.detail = detail;
    harness_report(&cfg, &res, 1);
    harness_shutdown(&cfg);
    return failed ? 1 : 0;
}
