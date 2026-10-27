/*
 * test/tools/test_microbench_dsp_mix.c -- assertion harness for the DSP
 * audio-mix microbenchmark ROM
 * (test/microbench/benchdsp_mix.j64, issue #536 task 8).
 *
 * THE QUESTION
 * ------------
 * "Can the DSP's mix keep ahead of the I2S?"  On a real Jaguar the I2S
 * interrupt fires when the DAC wants a sample and the DSP's ISR writes
 * LTXD/RTXD.  There is no FIFO: an unfinished sample cannot be held
 * back, it has to be FINISHED IN TIME.
 *
 * The ROM mixes 4 voices per sample and publishes each sample to the
 * DAC.  This harness measures the mix's cost per PUBLISHED sample (from
 * the DSP's own tick counters) and compares it with the I2S sample
 * period, so the answer is a percentage of the budget and a voice count.
 *
 *   I2S_sample_rate = system_clock / (64 * (SCLK + 1))
 *   sample period in RISC ticks = system_clock / sample_rate
 *                              = 64 * (SCLK + 1)
 *
 * so at SCLK = 8 (46.2 kHz) the period is 576 ticks, and at the
 * emulator's default SCLK = 19 (20.8 kHz) it is 1280 ticks.
 *
 * TWO SCHEDULES
 * -------------
 * The ROM carries both and picks one at run time from a flag the
 * harness writes into main RAM (0 = 1-deep, anything else = 2-deep):
 *
 *   1-deep -- the voice's envelope read (an EXTERNAL access, MAIN RAM)
 *             is issued and used immediately, so its latency is
 *             exposed as a stall;
 *   2-deep -- the NEXT voice's envelope read is issued at the top of
 *             the voice loop into a SECOND register (r20 in flight, r21
 *             in use) and harvested at the bottom with "move r20,r21",
 *             so the external read's latency is covered by the voice's
 *             own work.  Two registers, not one: the scoreboard makes a
 *             read of a register with a pending load wait for the load
 *             and then return the NEW value, so a one-register
 *             "pipeline" would multiply by the NEXT voice's envelope.
 *
 * Emits one machine-parseable line per variant before the verdict:
 *
 *   MICROBENCH engine=dsp_mix variant=<1-deep|2-deep> done=<0|1> \
 *       done_frame=<N|-1> count=<samples> expect_count=<samples> \
 *       ticks=<N> instr=<N> score=<N> raw=<N> ticks_per_sample=<F> \
 *       budget_46k=<F>% mixes_at_46k=<F> voices_at_46k=<F>
 *
 * With VJ_ILV_HIST=1 it also prints the DSP's per-opcode stall
 * histogram on stderr (the diagnostic a schedule author needs).
 *
 * Build:
 *   cc -O2 -Wall -std=c99 -I. -I./src -I./libretro-common/include \
 *      -o test/tools/test_microbench_dsp_mix \
 *      test/tools/test_microbench_dsp_mix.c \
 *      test/harness/harness.c -ldl -lm
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "../harness/harness.h"

#define MB_SENT_START       0x00010000u
#define MB_SENT_DONE        0x00010004u
#define MB_SENT_COUNT       0x00010008u

#define MB_MAGIC_START      0xC0DE57A7u
#define MB_MAGIC_MIX        0xC0DE0A04u

/* The schedule flag the 68K bootstrap reads (benchdsp_mix.s).  It lives
 * above the four envelope pages ($020000-$020FFF), so it cannot be
 * clobbered by the benchmark's own data. */
#define MB_FLAG_ADDR        0x00021000u

/* benchdspmix_naive.s: SAMPLES .equ 64 */
#define MB_EXPECT_COUNT     64u

/* benchdspmix_*.s: MIX_VOICES .equ 4 -- one 4-voice mix per sample */
#define MB_MIX_VOICES       4.0

/* The I2S sample period, in RISC ticks: 64 * (SCLK + 1). */
#define MB_PERIOD_46K       576u   /* SCLK = 8  -> 26.59 MHz / 576 = 46.2 kHz */
#define MB_PERIOD_21K       1280u  /* SCLK = 19 -> 26.59 MHz / 1280 = 20.8 kHz */

#define MB_FRAME_BUDGET     600

struct VJSettingsPrefix {
   bool hardwareTypeNTSC;
   bool useJaguarBIOS;
   bool useFastBlitter;
   bool blitterTiming;
   bool gpuPipelineTiming;
};

static struct VJSettingsPrefix *p_vjs;

static uint64_t *p_dsp_pipe_ticks_total;
static uint64_t *p_dsp_pipe_issue_total;
static uint64_t *p_dsp_pipe_stall_score;
static uint64_t *p_dsp_pipe_stall_raw;
static uint64_t *p_dsp_pipe_stall_port;
static uint64_t *p_dsp_pipe_stall_flags;
static uint64_t *p_dsp_pipe_raw_by_op;
static uint64_t *p_dsp_pipe_score_by_op;

typedef struct {
    uint8_t **ramp;
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

    (void)data; (void)width; (void)height; (void)pitch;

    st->frame++;
    if (!st->ramp || !*st->ramp)
        return;
    ram = *st->ramp;

    if (st->start_frame < 0 && mb_read32(ram, MB_SENT_START) == MB_MAGIC_START)
        st->start_frame = (int)st->frame;
    if (st->done_frame < 0 && mb_read32(ram, MB_SENT_DONE) == MB_MAGIC_MIX) {
        st->done_frame = (int)st->frame;
        st->count = mb_read32(ram, MB_SENT_COUNT);
    }
}

typedef struct {
    int      done_frame;
    int      start_frame;
    uint32_t count;
    uint64_t ticks, instr, score, raw, port, flags;
    int      ok;
} run_result;

static int run_variant(harness_config *cfg, uint8_t **ramp, int flag,
                       const char *name, run_result *out)
{
    mb_state st;
    memset(&st, 0, sizeof(st));
    st.start_frame = -1;
    st.done_frame  = -1;
    st.ramp = ramp;

    cfg->video_callback      = mb_frame_cb;
    cfg->video_callback_data = &st;

    if (!harness_load_rom(cfg)) {
        fprintf(stderr, "test_microbench_dsp_mix: failed to load ROM\n");
        return 0;
    }
    /* The tick counters only move when the pipeline-timing model is on.
     * Set it AFTER the load: retro_load_game resets the machine and
     * re-reads the core options, which would turn it back off. */
    if (p_vjs)
        p_vjs->gpuPipelineTiming = true;
    if (ramp && *ramp) {
        /* BIG-ENDIAN: the 68K reads the flag as a longword and the
         * Jaguar is big-endian. */
        uint8_t *ram = *ramp;
        ram[MB_FLAG_ADDR + 0] = (uint8_t)((flag >> 24) & 0xFF);
        ram[MB_FLAG_ADDR + 1] = (uint8_t)((flag >> 16) & 0xFF);
        ram[MB_FLAG_ADDR + 2] = (uint8_t)((flag >> 8) & 0xFF);
        ram[MB_FLAG_ADDR + 3] = (uint8_t)(flag & 0xFF);
    }

    harness_run(cfg);

    if (p_dsp_pipe_raw_by_op && getenv("VJ_ILV_HIST")) {
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
        fprintf(stderr, "MIX hist %s: raw by opcode:", name);
        for (q = 0; q < 64; q++)
            if (p_dsp_pipe_raw_by_op[q])
                fprintf(stderr, " %s=%llu", names[q], (unsigned long long)p_dsp_pipe_raw_by_op[q]);
        fprintf(stderr, "  | score by opcode:");
        for (q = 0; q < 64; q++)
            if (p_dsp_pipe_score_by_op[q])
                fprintf(stderr, " %s=%llu", names[q], (unsigned long long)p_dsp_pipe_score_by_op[q]);
        fprintf(stderr, "\n");
    }

    if (getenv("VJ_DEBUG_MIX")) {
        fprintf(stderr, "MIX dbg: flag=%d vjs=%p timing=%d ticks=%llu instr=%llu\n",
                flag, (void *)p_vjs,
                p_vjs ? (int)p_vjs->gpuPipelineTiming : -1,
                p_dsp_pipe_ticks_total ? (unsigned long long)*p_dsp_pipe_ticks_total : 0ULL,
                p_dsp_pipe_issue_total ? (unsigned long long)*p_dsp_pipe_issue_total : 0ULL);
    }

    out->done_frame  = st.done_frame;
    out->start_frame = st.start_frame;
    out->count       = st.count;
    out->ok          = (st.done_frame >= 0);
    if (p_dsp_pipe_ticks_total) {
        out->ticks = *p_dsp_pipe_ticks_total;
        out->instr = *p_dsp_pipe_issue_total;
        out->score = *p_dsp_pipe_stall_score;
        out->raw   = *p_dsp_pipe_stall_raw;
        out->port  = *p_dsp_pipe_stall_port;
        out->flags = *p_dsp_pipe_stall_flags;
    }
    {
        double per = out->count ? (double)out->ticks / (double)out->count : 0.0;
        printf("MICROBENCH engine=dsp_mix variant=%-8s done=%d done_frame=%d "
               "start_frame=%d count=%u expect_count=%u ticks=%llu instr=%llu "
               "score=%llu raw=%llu port=%llu flags=%llu ticks_per_sample=%.2f "
               "budget_46k=%.1f%% mixes_at_46k=%.2f voices_at_46k=%.2f "
               "budget_21k=%.1f%% mixes_at_21k=%.2f voices_at_21k=%.2f\n",
               name, out->ok ? 1 : 0, out->done_frame, out->start_frame,
               (unsigned)out->count, (unsigned)MB_EXPECT_COUNT,
               (unsigned long long)out->ticks, (unsigned long long)out->instr,
               (unsigned long long)out->score, (unsigned long long)out->raw,
               (unsigned long long)out->port, (unsigned long long)out->flags,
               per,
               per ? 100.0 * per / (double)MB_PERIOD_46K : 0.0,
               per ? (double)MB_PERIOD_46K / per : 0.0,
               per ? (double)MB_PERIOD_46K / per * MB_MIX_VOICES : 0.0,
               per ? 100.0 * per / (double)MB_PERIOD_21K : 0.0,
               per ? (double)MB_PERIOD_21K / per : 0.0,
               per ? (double)MB_PERIOD_21K / per * MB_MIX_VOICES : 0.0);
    }
    return out->ok;
}

int main(int argc, char **argv)
{
    harness_config cfg = HARNESS_CONFIG_DEFAULT;
    harness_result res;
    uint8_t **ramp;
    run_result shallow, deep;
    int failed = 0;
    const char *detail = "both mixes ran and the 2-deep schedule covered the external read";

    cfg.frames = MB_FRAME_BUDGET;
    cfg.quiet  = 1;
    if (!harness_init_from_args(&cfg, argc, argv))
        return 2;

    ramp = (uint8_t **)harness_dlsym(&cfg, "jaguarMainRAM");
    if (!ramp) {
        fprintf(stderr, "test_microbench_dsp_mix: core does not export "
                "jaguarMainRAM -- rebuild with `make TEST_EXPORTS=1`\n");
        harness_shutdown(&cfg);
        return 2;
    }

    p_dsp_pipe_ticks_total = harness_dlsym(&cfg, "dsp_pipe_ticks_total");
    p_dsp_pipe_issue_total = harness_dlsym(&cfg, "dsp_pipe_issue_total");
    p_dsp_pipe_stall_score = harness_dlsym(&cfg, "dsp_pipe_stall_score");
    p_dsp_pipe_stall_raw   = harness_dlsym(&cfg, "dsp_pipe_stall_raw");
    p_dsp_pipe_stall_port  = harness_dlsym(&cfg, "dsp_pipe_stall_port");
    p_dsp_pipe_stall_flags = harness_dlsym(&cfg, "dsp_pipe_stall_flags");
    p_dsp_pipe_raw_by_op   = harness_dlsym(&cfg, "dsp_pipe_raw_by_op");
    p_dsp_pipe_score_by_op = harness_dlsym(&cfg, "dsp_pipe_score_by_op");
    if (!p_dsp_pipe_ticks_total || !p_dsp_pipe_issue_total) {
        fprintf(stderr, "test_microbench_dsp_mix: core does not export the "
                "DSP tick counters -- rebuild with `make TEST_EXPORTS=1`\n");
        harness_shutdown(&cfg);
        return 2;
    }

    p_vjs = (struct VJSettingsPrefix *)harness_dlsym(&cfg, "vjs");
    if (p_vjs)
        p_vjs->gpuPipelineTiming = true;

    memset(&shallow, 0, sizeof(shallow));
    memset(&deep, 0, sizeof(deep));

    run_variant(&cfg, ramp, 0, "1-deep", &shallow);
    run_variant(&cfg, ramp, 2, "2-deep", &deep);

    if (!shallow.ok || shallow.count != MB_EXPECT_COUNT) {
        detail = "the 1-deep mix did not complete with the expected sample count";
        failed = 1;
    } else if (!deep.ok || deep.count != MB_EXPECT_COUNT) {
        detail = "the 2-deep mix did not complete with the expected sample count";
        failed = 1;
    } else if (shallow.ticks == 0) {
        detail = "the DSP tick counters did not move -- the pipeline-timing model is off";
        failed = 1;
    } else if (deep.score >= shallow.score) {
        detail = "the 2-deep mix did not cover the external read's latency";
        failed = 1;
    } else {
        double per1 = (double)shallow.ticks / (double)shallow.count;
        double per2 = (double)deep.ticks / (double)deep.count;
        printf("MICROBENCH engine=dsp_mix summary "
               "ticks_per_sample_1deep=%.2f ticks_per_sample_2deep=%.2f "
               "saved=%.2f (%.1f%%) score_1deep=%llu score_2deep=%llu "
               "mixes_at_46k=%.2f voices_at_46k=%.2f "
               "mixes_at_21k=%.2f voices_at_21k=%.2f\n",
               per1, per2, per1 - per2, 100.0 * (per1 - per2) / per1,
               (unsigned long long)shallow.score,
               (unsigned long long)deep.score,
               (double)MB_PERIOD_46K / per2,
               (double)MB_PERIOD_46K / per2 * MB_MIX_VOICES,
               (double)MB_PERIOD_21K / per2,
               (double)MB_PERIOD_21K / per2 * MB_MIX_VOICES);
    }

    res.status = failed ? "FAIL" : "PASS";
    res.name   = "microbench_dsp_mix";
    res.detail = detail;
    harness_report(&cfg, &res, 1);
    harness_shutdown(&cfg);
    return failed ? 1 : 0;
}
