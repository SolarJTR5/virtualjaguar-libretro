/*
 * test/tools/test_demo_audio.c -- check the 68K-only I2S square wave.
 *
 * The demo ROM test/microbench/benchdemo_audio.s drives the Jaguar's
 * I2S port from the 68000 alone: a JERRY timer interrupt writes a
 * square wave straight into LTXD/RTXD, JERRY's I2S hardware latches it
 * on every word strobe, and the DAC resamples it into the 48 kHz
 * output.
 *
 * This tool captures the raw output stream and checks that what comes
 * out is the tone the ROM asked for:
 *
 *   - the stream is not silent,
 *   - the left and right channels carry the same signal,
 *   - the tone is at the frequency the ROM asked for.
 *
 * The frequency is estimated from the zero crossings of the summed
 * channels, which is exact for a square wave.
 *
 * The expected frequency is *derived from the ROM itself*, not from a
 * hard-coded number: the ROM publishes its interrupt-tick count, and
 * the square wave's period is a fixed number of ticks, so the tone must
 * be (tick rate / 16).  Measuring the tick rate in the same capture
 * window makes the check independent of how many timer ticks the
 * hardware actually delivers -- and JERRY's pending-interrupt latch is
 * cleared by the 68000's own write, so a tick that lands between the
 * interrupt acknowledge and that write is swallowed.  The measured tick
 * rate is reported next to the nominal one so that difference is
 * visible rather than hidden.
 *
 * Usage:  test_demo_audio <core.so> <rom.j64> [--frames N] [--wav FILE]
 *
 * --wav writes what the core's audio callback produced as a 48 kHz
 * stereo WAV, so the demo can be heard without an emulator frontend.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "../harness/harness.h"

#define RATE        48000
#define MAX_FRAMES  20000
#define TICKS_PER_HALF  8        /* the ROM's phase divider: 16 ticks/period */
#define TICK_ADDR   0x00020000u /* the ROM's published tick count */
#define NOMINAL_TICK_HZ 49990.0 /* 26.590906 MHz / 532 cycles */

static int16_t  g_samples[MAX_FRAMES * 2];
static size_t   g_count;
static uint64_t g_dropped;

static uint32_t g_tick_first;
static uint32_t g_tick_last;
static int      g_tick_seen;

static uint8_t **g_ramp;

static uint32_t rd32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
         | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

/* Write the captured audio as a 16-bit stereo RIFF/WAVE file, so the
 * demo can be heard without an emulator (any player will do). */
static int write_wav(const char *path, const int16_t *samples, size_t frames)
{
    FILE *f;
    uint32_t data_bytes = (uint32_t)(frames * 4u);
    uint32_t riff_size = 36u + data_bytes;
    uint16_t one = 1, chans = 2, bits = 16, block = 4;
    uint32_t rate = RATE, byte_rate = RATE * 4u, fmt = 16;

    f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "write_wav: cannot open %s\n", path); return 1; }
    fwrite("RIFF", 1, 4, f);
    fwrite(&riff_size, 4, 1, f);
    fwrite("WAVEfmt ", 1, 8, f);
    fwrite(&fmt, 4, 1, f);
    fwrite(&one, 2, 1, f);
    fwrite(&chans, 2, 1, f);
    fwrite(&rate, 4, 1, f);
    fwrite(&byte_rate, 4, 1, f);
    fwrite(&block, 2, 1, f);      /* nBlockAlign is TWO bytes */
    fwrite(&bits, 2, 1, f);
    fwrite("data", 1, 4, f);
    fwrite(&data_bytes, 4, 1, f);
    fwrite(samples, 4, frames, f);
    fclose(f);
    return 0;
}

static void audio_batch(const int16_t *buf, size_t frames)
{
    size_t i, n;

    if (frames > (size_t)((MAX_FRAMES * 2 - g_count) / 2))
        n = (size_t)((MAX_FRAMES * 2 - g_count) / 2);
    else
        n = frames;

    /* Sample the ROM's tick counter in the same window as the audio:
     * the tick rate is what the expected tone is derived from.  Only
     * the batches that are actually kept count -- the capture stops at
     * MAX_FRAMES, but the ROM keeps ticking for the rest of the run. */
    if (n > 0 && g_ramp && *g_ramp)
    {
        uint32_t ticks = rd32(*g_ramp + TICK_ADDR);

        if (!g_tick_seen)
        {
            g_tick_first = ticks;
            g_tick_seen = 1;
        }
        g_tick_last = ticks;
    }
    for (i = 0; i < n * 2; i++)
        g_samples[g_count++] = buf[i];

    g_dropped += (frames - n) * 2;
}

int main(int argc, char **argv)
{
    harness_config cfg = HARNESS_CONFIG_DEFAULT;
    void (*set_batch)(void (*)(const int16_t *, size_t));
    unsigned frames = 120;
    const char *wav_path = NULL;
    size_t i, pairs;
    int peak = 0, nonsilent = 0, mismatch = 0;
    int crossings = 0;
    double hz, tick_hz, expect_hz;
    uint32_t ticks;
    int ok = 1;
    harness_result res[4];

    if (argc < 3)
    {
        fprintf(stderr, "usage: %s <core.so> <rom.j64> [--frames N] "
                        "[--wav FILE]\n", argv[0]);
        return 2;
    }
    for (i = 2; i < (size_t)argc; i++)
    {
        if (!strcmp(argv[i], "--frames") && i + 1 < (size_t)argc)
            frames = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--wav") && i + 1 < (size_t)argc)
            wav_path = argv[++i];
    }

    cfg.frames = frames;
    cfg.quiet = 1;
    if (!harness_init_from_args(&cfg, argc, argv))
        return 2;

    if (!harness_load_rom(&cfg))
    {
        fprintf(stderr, "test_demo_audio: failed to load ROM\n");
        harness_shutdown(&cfg);
        return 2;
    }

    g_ramp = (uint8_t **)harness_dlsym(&cfg, "jaguarMainRAM");
    if (!g_ramp || !*g_ramp)
    {
        fprintf(stderr, "test_demo_audio: core does not export jaguarMainRAM\n");
        harness_shutdown(&cfg);
        return 2;
    }

    /* After harness_load_rom(), so ours is the callback the core keeps. */
    set_batch = (void (*)(void (*)(const int16_t *, size_t)))
                harness_dlsym(&cfg, "retro_set_audio_sample_batch");
    if (!set_batch)
    {
        fprintf(stderr, "test_demo_audio: core has no "
                        "retro_set_audio_sample_batch\n");
        harness_shutdown(&cfg);
        return 2;
    }
    set_batch(audio_batch);

    /* The tick counter before the run: the ROM only starts counting
     * once its timer interrupt is armed, so this is the baseline. */
    ticks = rd32(*g_ramp + TICK_ADDR);
    g_tick_first = ticks;

    harness_run(&cfg);

    /* ... and after it: the whole run's worth of ticks, measured over
     * the whole run's worth of audio (the capture window is shorter
     * than the run). */
    g_tick_last = rd32(*g_ramp + TICK_ADDR);

    pairs = g_count / 2;
    printf("AUDIO sample_frames=%lu  dropped=%lu\n",
           (unsigned long)pairs, (unsigned long)g_dropped);

    if (wav_path)
    {
        if (write_wav(wav_path, g_samples, pairs))
        {
            harness_shutdown(&cfg);
            return 2;
        }
        printf("AUDIO wrote %s (%lu frames, %.2f s at %d Hz)\n", wav_path,
               (unsigned long)pairs, (double)pairs / (double)RATE, RATE);
    }

    if (pairs < 100)
    {
        printf("AUDIO too few samples\n");
        res[0].status = "FAIL";
        res[0].name   = "audio_samples";
        res[0].detail = "the core produced almost no audio frames";
        harness_report(&cfg, res, 1);
        harness_shutdown(&cfg);
        return 1;
    }

    for (i = 0; i < pairs; i++)
    {
        int l = g_samples[i * 2 + 0];
        int r = g_samples[i * 2 + 1];
        int a = l > 0 ? l : -l;
        int b = r > 0 ? r : -r;

        if (a > peak) peak = a;
        if (a > 64 || b > 64) nonsilent++;
        if (l != r) mismatch++;
    }
    printf("AUDIO peak=%d nonsilent=%lu/%lu  L!=R on %lu frames\n",
           peak, (unsigned long)nonsilent, (unsigned long)pairs,
           (unsigned long)mismatch);

    /* Zero crossings over the middle of the capture: the square wave's
     * edges are the only sign changes. */
    {
        size_t start = pairs / 4;
        size_t end   = pairs - pairs / 4;
        int prev = 0;

        for (i = start; i < end; i++)
        {
            int v = g_samples[i * 2 + 0] + g_samples[i * 2 + 1];

            if (v > 0) v = 1; else if (v < 0) v = -1;
            if (prev != 0 && v != 0 && v != prev)
                crossings++;
            if (v != 0) prev = v;
        }
        hz = (double)crossings / 2.0 / ((double)(end - start) / (double)RATE);
    }

    /* The tick rate the ROM actually achieved, measured over the whole
     * run (the audio clock is the 48 kHz output clock). */
    ticks = g_tick_last - g_tick_first;
    {
        double audio_frames = (double)pairs + (double)(g_dropped / 2);

        tick_hz = (double)ticks / (audio_frames / (double)RATE);
    }
    expect_hz = tick_hz / (double)(TICKS_PER_HALF * 2);

    printf("AUDIO ticks=%lu over %lu frames -> tick rate %.0f Hz "
           "(nominal %.0f Hz), expected tone %.0f Hz\n",
           (unsigned long)ticks, (unsigned long)pairs, tick_hz,
           NOMINAL_TICK_HZ, expect_hz);
    printf("AUDIO zero-crossing tone estimate = %.0f Hz (expected %.0f Hz)\n",
           hz, expect_hz);

    /* --- the four checks --- */
    if (nonsilent * 2 < pairs)
    {
        res[0].status = "FAIL";
        res[0].name   = "audio_present";
        res[0].detail = "the 68K-written I2S stream is silent";
        ok = 0;
    }
    else
    {
        res[0].status = "PASS";
        res[0].name   = "audio_present";
        res[0].detail = "the 68K-written I2S stream reaches the output";
    }

    if (mismatch > pairs / 20)
    {
        res[1].status = "FAIL";
        res[1].name   = "audio_stereo_match";
        res[1].detail = "left and right differ; the ROM writes both";
        ok = 0;
    }
    else
    {
        res[1].status = "PASS";
        res[1].name   = "audio_stereo_match";
        res[1].detail = "left and right carry the same signal";
    }

    if (hz < expect_hz * 0.92 || hz > expect_hz * 1.08)
    {
        res[2].status = "FAIL";
        res[2].name   = "audio_tone_frequency";
        res[2].detail = "the tone is not at the frequency the ROM asked for";
        ok = 0;
    }
    else
    {
        res[2].status = "PASS";
        res[2].name   = "audio_tone_frequency";
        res[2].detail = "the tone is at the frequency the ROM asked for";
    }

    /* The timer itself: the nominal rate is 26.590906 MHz / 532 cycles.
     * A large shortfall would mean the interrupts are being lost, which
     * is worth knowing about even though the tone check above is
     * self-referential. */
    if (tick_hz < NOMINAL_TICK_HZ * 0.8 || tick_hz > NOMINAL_TICK_HZ * 1.2)
    {
        res[3].status = "FAIL";
        res[3].name   = "audio_timer_rate";
        res[3].detail = "the 68000's timer interrupt rate is off";
        ok = 0;
    }
    else
    {
        res[3].status = "PASS";
        res[3].name   = "audio_timer_rate";
        res[3].detail = "the 68000's timer interrupt rate is as programmed";
    }

    harness_report(&cfg, res, 4);
    harness_shutdown(&cfg);
    return ok ? 0 : 1;
}
