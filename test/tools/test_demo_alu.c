/*
 * test/tools/test_demo_alu.c -- check the assembler's register-register
 * ALU forms against the 68000's documented results.
 *
 * The toolchain that builds the microbench ROMs is vendored outside this
 * repository (tools/jaguar-toolchain/PIN), so it is not under this repo's
 * control and it can be wrong in ways nothing else catches.  A local,
 * uncommitted edit to rmac's machine table once changed the AND opcode
 * from $C to $B, so every `and.l Dn,Dm` assembled as `cmp.l Dn,Dm` -- a
 * silent, well-formed, completely wrong instruction.
 *
 * The ROM (test/microbench/benchdemo_alu.s) runs 16 register-register ALU
 * forms with known operands and publishes each result in the sentinel
 * block.  The expected values below come from the 68000 instruction set,
 * not from this emulator, so a mis-assembled mnemonic shows up as a
 * failed case instead of a silent behavioural difference.
 *
 * Usage:  test_demo_alu <core.so> <rom.j64> [--frames N]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "../harness/harness.h"

#define SENT_BASE   0x00010000u
#define RESULTS     (SENT_BASE + 20u)

#define MAGIC_START 0xC0DE57A7u
#define MAGIC_DONE  0xC0DE0068u

struct alu_case
{
    const char *name;
    uint32_t    expect;
};

static const struct alu_case cases[] =
{
    { "add.l d3,d2  (5+10)",      15u },
    { "sub.l d3,d2  (10-5)",       5u },
    { "sub.l d0,d2  (10-7)",       3u },
    { "and.l d0,d3  (mask=all)",   0xFFFF0000u },
    { "and.l d0,d3  (mask=0)",     0u },
    { "or.l  d0,d3",               0xFFFF0F0Fu },
    { "eor.l d0,d3",               0x0000FFFFu },
    { "and.l d1,d2",               0x00FF00FFu },
    { "add.l d2,d3  (5+7)",       12u },
    { "neg.l d0",                  0xFFFFFFFBu },
    { "not.l d0",                  0xFFFFFFFFu },
    { "addq.l #1,d2",             11u },
    { "lsl.l #1,d0",               6u },
    { "lsr.l #1,d0",               1u },
    { "swap d0",                   0x56781234u },
    { "move.l d3,d2",              5u }
};

#define NCASES ((int)(sizeof(cases) / sizeof(cases[0])))

static uint32_t rd32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
         | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

int main(int argc, char **argv)
{
    harness_config cfg = HARNESS_CONFIG_DEFAULT;
    uint8_t **ramp;
    const uint8_t *ram;
    unsigned frames = 10;
    int argi, i, bad = 0;
    uint32_t start, done;
    harness_result res[1];

    if (argc < 3)
    {
        fprintf(stderr, "usage: %s <core.so> <rom.j64> [--frames N]\n",
                argv[0]);
        return 2;
    }
    for (argi = 2; argi < argc; argi++)
        if (!strcmp(argv[argi], "--frames") && argi + 1 < argc)
            frames = (unsigned)atoi(argv[++argi]);

    cfg.frames = frames;
    cfg.quiet = 1;
    if (!harness_init_from_args(&cfg, argc, argv))
        return 2;
    if (!harness_load_rom(&cfg))
    {
        fprintf(stderr, "test_demo_alu: failed to load ROM\n");
        harness_shutdown(&cfg);
        return 2;
    }

    ramp = (uint8_t **)harness_dlsym(&cfg, "jaguarMainRAM");
    if (!ramp || !*ramp)
    {
        fprintf(stderr, "test_demo_alu: core does not export jaguarMainRAM\n");
        harness_shutdown(&cfg);
        return 2;
    }
    ram = *ramp;

    harness_run(&cfg);

    start = rd32(ram + SENT_BASE + 0);
    done  = rd32(ram + SENT_BASE + 4);

    if (start != MAGIC_START)
    {
        printf("ALU START sentinel = %08lX (want %08lX) -- the ROM did not "
               "reach its first instruction\n",
               (unsigned long)start, (unsigned long)MAGIC_START);
    }
    if (done != MAGIC_DONE)
    {
        printf("ALU DONE  sentinel = %08lX (want %08lX) -- the ROM did not "
               "finish\n",
               (unsigned long)done, (unsigned long)MAGIC_DONE);
    }

    for (i = 0; i < NCASES; i++)
    {
        uint32_t got = rd32(ram + RESULTS + (unsigned)i * 4u);

        if (got != cases[i].expect)
        {
            printf("ALU case %2d %-26s got %08lX want %08lX  MISMATCH\n",
                   i + 1, cases[i].name, (unsigned long)got,
                   (unsigned long)cases[i].expect);
            bad++;
        }
        else
            printf("ALU case %2d %-26s = %08lX  ok\n", i + 1, cases[i].name,
                   (unsigned long)got);
    }

    printf("ALU %d cases, %d mismatches\n", NCASES, bad);

    if (bad == 0 && start == MAGIC_START && done == MAGIC_DONE)
    {
        res[0].status = "PASS";
        res[0].name   = "alu_forms";
        res[0].detail = "every register-register ALU form matched the 68000";
    }
    else
    {
        res[0].status = "FAIL";
        res[0].name   = "alu_forms";
        res[0].detail = "a register-register ALU form was mis-assembled";
    }
    harness_report(&cfg, res, 1);

    harness_shutdown(&cfg);
    return (bad == 0 && start == MAGIC_START && done == MAGIC_DONE) ? 0 : 1;
}
