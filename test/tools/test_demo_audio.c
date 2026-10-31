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
 * --sine checks benchdemo_sine.j64 instead: same capture, same timer
 * check, but the tone is a 64-step sine and the analysis is a
 * least-squares sine fit -- the fitted frequency, the amplitude in dBFS
 * and the SNR against a pure sine, which are the same three numbers the
 * Sega 32X PWM test reports.  A square wave is exactly periodic at two
 * levels, so zero crossings settle the frequency question by
 * themselves; a sine carries its quality in the *residual*, which is
 * why it needs a fit.
 *
 * Usage:  test_demo_audio <core.so> <rom.j64> [--frames N] [--wav FILE]
 *                         [--sine]
 *
 * --wav writes what the core's audio callback produced as a 48 kHz
 * stereo WAV, so the demo can be heard without an emulator frontend.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>

#include "../harness/harness.h"

#define RATE        48000
#define MAX_FRAMES  20000
#define TICKS_PER_HALF  8        /* the square ROM's phase divider: 16 ticks/period */
#define SINE_LEN    64           /* the sine ROM's table length: 64 ticks/period */
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

/* ---- the sine analysis ----------------------------------------------
 * With the model
 *
 *     x[n] = A*cos(w*n) + B*sin(w*n) + noise
 *
 * the least-squares A and B at a trial frequency w are just the
 * projections onto cos and sin, and the power they explain is
 * (A^2+B^2)*n/2.  Maximising that over w is the same as minimising the
 * residual, so one scan gives both the frequency the ROM actually
 * produced and the share of the signal that a pure sine explains --
 * the "SNR vs a pure sine" number the 32X PWM test reports.
 *
 * The scan is coarse (240 points over +-3%) followed by three
 * refinements, each over one step of the previous pass, so the fitted
 * frequency lands well inside a millihertz on a 10 ksample window.
 */
#define PI_CONST 3.14159265358979323846

static double sine_explained(const double *x, size_t n, double w,
                             double *pa, double *pb)
{
    double c = 1.0, s = 0.0, cs = cos(w), sn = sin(w);
    double xc = 0.0, xs = 0.0, nc, ns;
    size_t i;

    for (i = 0; i < n; i++)
    {
        xc += x[i] * c;
        xs += x[i] * s;
        nc = c * cs - s * sn;
        ns = s * cs + c * sn;
        c  = nc;
        s  = ns;
    }
    *pa = 2.0 * xc / (double)n;
    *pb = 2.0 * xs / (double)n;
    return (*pa * *pa + *pb * *pb) * (double)n / 2.0;
}

static double sine_analyse(const double *x, size_t n, double rate,
                           double f0, double *amp, double *snr_db)
{
    double sig = 0.0;
    double lo = f0 * 0.97, hi = f0 * 1.03;
    double best_f = f0, best_p, a = 0.0, b = 0.0, f, w, resid, step;
    size_t i;
    int pass, k, steps;

    for (i = 0; i < n; i++)
        sig += x[i] * x[i];

    for (pass = 0; pass < 4; pass++)
    {
        steps = (pass == 0) ? 240 : 60;
        step  = (hi - lo) / (double)steps;
        best_p = -1.0;
        for (k = 0; k <= steps; k++)
        {
            f = lo + (hi - lo) * (double)k / (double)steps;
            w = 2.0 * PI_CONST * f / rate;
            {
                double p = sine_explained(x, n, w, &a, &b);
                if (p > best_p)
                {
                    best_p = p;
                    best_f = f;
                }
            }
        }
        lo = best_f - step;
        hi = best_f + step;
    }

    w = 2.0 * PI_CONST * best_f / rate;
    best_p = sine_explained(x, n, w, &a, &b);
    *amp = sqrt(a * a + b * b);
    resid = sig - best_p;
    if (resid < 1.0) resid = 1.0;
    *snr_db = 10.0 * log10(best_p / resid);
    return best_f;
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
    int sine = 0;
    double hz = 0.0, tick_hz, expect_hz, nominal_hz, amp = 0.0, snr_db = 0.0;
    double corr = 1.0;
    uint32_t ticks;
    int ok = 1;
    harness_result res[5];
    size_t nres = 4;

    if (argc < 3)
    {
        fprintf(stderr, "usage: %s <core.so> <rom.j64> [--frames N] "
                        "[--wav FILE] [--sine]\n", argv[0]);
        return 2;
    }
    for (i = 2; i < (size_t)argc; i++)
    {
        if (!strcmp(argv[i], "--frames") && i + 1 < (size_t)argc)
            frames = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--wav") && i + 1 < (size_t)argc)
            wav_path = argv[++i];
        else if (!strcmp(argv[i], "--sine"))
            sine = 1;
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
    /* The sine ROM's divider is 640 cycles (41.55 kHz, deliberately
     * rate-locked to the I2S strobe at SCLK = 9); the square ROM's is
     * the 532-cycle default.
     *
     * The sine's expected tone comes from the NOMINAL rate, not the
     * measured tick rate: because the divider and the strobe are locked,
     * the tone is predictable to well under 1%, and a fit that misses it
     * means the two have drifted apart (an ISR overrun is the usual
     * cause).  The square wave is the opposite case -- its ISR really
     * does swallow ticks, so there the measured rate is the honest
     * denominator. */
    nominal_hz = sine ? (26590906.0 / 640.0) : NOMINAL_TICK_HZ;
    expect_hz = sine ? (nominal_hz / (double)SINE_LEN)
                     : (tick_hz / (double)(TICKS_PER_HALF * 2));

    printf("AUDIO ticks=%lu over %lu frames -> tick rate %.0f Hz "
           "(nominal %.0f Hz), expected tone %.0f Hz\n",
           (unsigned long)ticks, (unsigned long)pairs, tick_hz,
           nominal_hz, expect_hz);

    if (!sine)
        printf("AUDIO zero-crossing tone estimate = %.0f Hz (expected %.0f Hz)\n",
               hz, expect_hz);
    else
    {
        /* The sine: fit a pure sine to the middle half of the capture
         * and report what is left over. */
        size_t start = pairs / 4;
        size_t n = pairs - pairs / 2;
        double *x = (double *)malloc(n * sizeof(double));
        double mean = 0.0, sl = 0.0, sr = 0.0, slr = 0.0, ml = 0.0, mr = 0.0;

        if (!x)
        {
            fprintf(stderr, "out of memory\n");
            harness_shutdown(&cfg);
            return 2;
        }
        for (i = 0; i < n; i++)
            mean += g_samples[(start + i) * 2 + 0];
        mean /= (double)n;
        for (i = 0; i < n; i++)
            x[i] = (double)g_samples[(start + i) * 2 + 0] - mean;

        /* Stereo: the ROM writes the same sample to both registers, but
         * the two writes are a few cycles apart, so an I2S strobe that
         * lands between them latches adjacent samples.  That shows up
         * as a handful of frames where L and R differ slightly, so the
         * meaningful test is that the two channels are the same SIGNAL
         * (correlation), not the same bytes. */
        for (i = 0; i < n; i++)
        {
            ml += g_samples[(start + i) * 2 + 1];
            mr += g_samples[(start + i) * 2 + 0];
        }
        ml /= (double)n;
        mr /= (double)n;
        for (i = 0; i < n; i++)
        {
            double l = (double)g_samples[(start + i) * 2 + 1] - ml;
            double r = (double)g_samples[(start + i) * 2 + 0] - mr;

            sl  += l * l;
            sr  += r * r;
            slr += l * r;
        }
        if (sl > 0.0 && sr > 0.0)
            corr = slr / sqrt(sl * sr);

        hz = sine_analyse(x, n, (double)RATE, expect_hz, &amp, &snr_db);
        free(x);

        printf("AUDIO sine fit: %.2f Hz (expected %.2f Hz), amplitude "
               "%.0f/32767 (%.1f dBFS), SNR vs a pure sine %.1f dB, "
               "L/R correlation %.5f\n",
               hz, expect_hz, amp, 20.0 * log10(amp / 32768.0), snr_db, corr);
    }

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

    if (sine ? (corr < 0.99) : (mismatch > pairs / 20))
    {
        res[1].status = "FAIL";
        res[1].name   = "audio_stereo_match";
        res[1].detail = "left and right do not carry the same signal";
        ok = 0;
    }
    else
    {
        res[1].status = "PASS";
        res[1].name   = "audio_stereo_match";
        res[1].detail = "left and right carry the same signal";
    }

    if (hz < expect_hz * 0.98 || hz > expect_hz * 1.02)
    {
        res[2].status = "FAIL";
        res[2].name   = sine ? "sine_frequency" : "audio_tone_frequency";
        res[2].detail = "the tone is not at the frequency the ROM asked for";
        ok = 0;
    }
    else
    {
        res[2].status = "PASS";
        res[2].name   = sine ? "sine_frequency" : "audio_tone_frequency";
        res[2].detail = "the tone is at the frequency the ROM asked for";
    }

    /* The timer itself: the nominal rate is 26.590906 MHz / 532 cycles.
     * A large shortfall would mean the interrupts are being lost, which
     * is worth knowing about even though the tone check above is
     * self-referential. */
    if (tick_hz < nominal_hz * 0.8 || tick_hz > nominal_hz * 1.2)
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

    /* The sine's quality: how much of the output a pure sine explains.
     * A 64-step table on a 46 kHz sample rate should be well above
     * 30 dB; the floor is set where "the waveform is a sine" stops
     * being true (a square wave, for instance, fits at about 10 dB). */
    if (sine)
    {
        nres = 5;
        if (snr_db < 25.0)
        {
            res[4].status = "FAIL";
            res[4].name   = "sine_purity";
            res[4].detail = "the output is not close enough to a pure sine";
            ok = 0;
        }
        else
        {
            res[4].status = "PASS";
            res[4].name   = "sine_purity";
            res[4].detail = "the output is a clean sine at the table's rate";
        }
    }

    harness_report(&cfg, res, nres);
    harness_shutdown(&cfg);
    return ok ? 0 : 1;
}
