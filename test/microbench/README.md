# Purpose-built microbenchmark ROMs (#536)

Small, single-engine Jaguar cartridges with a **fixed iteration count** and a
**harness-assertable completion marker**. They fill the gap #533 identified
after auditing the public ROM corpus (jagniccc/yarc): real titles never give
single-engine isolation or an exact, deterministic termination.

| ROM | engine | what it isolates | DONE magic | status |
|---|---|---|---|---|
| `bench68k.j64` | 68000 only | pure 68K loop throughput (`addq.l`/`subq.l`/`bne.s`) fetching from cart ROM | `$C0DE0068` | shipped (task 1) |
| `benchgpu_arith.j64` | GPU, arithmetic-heavy | back-to-back ALU ops (`add`/`sub`/`and`/`or`) out of GPU local RAM -- the write-back port conflict rule's worst case | `$C0DE0A01` | shipped (task 2) |
| `benchgpu_branch.j64` | GPU, branch-heavy | control flow (`JR`/`NOP` delay-slot pairs, taken `JUMP`) out of GPU local RAM -- structurally immune to the write-back conflict that hits the arith ROM | `$C0DE0B02` | shipped (task 3) |
| `benchdsp.j64` | DSP | the same 20-instruction ALU body as `benchgpu_arith.j64`, run on the DSP interpreter instead of the GPU's -- a direct same-clock GPU-vs-DSP comparison, and proof the DSP has no `virtualjaguar_gpu_pipeline_timing`-equivalent cost model | `$C0DE0D53` | shipped (task 4) |
| `benchblit.j64` | blitter | fixed-count 32x32 8bpp PATDSEL solid-fill launches to main RAM -- the only ROM whose hot path touches external memory every iteration, so it responds to `virtualjaguar_dram_timing` and `virtualjaguar_blitter_timing` where the other four don't | `$C0DE0B17` | shipped (task 5) |
| `benchdsp_interleave.j64` | DSP, 3D vertex pipeline | the same three schedules as the GPU ROM below, but on Jerry's RISC -- which is the more interesting target: the audio path has no FIFO between the mix and the I2S interrupt, and Jerry reaches external memory over a 16-bit bus, so its loads are slower. Same shared payload sources, assembled once per core | `$C0DE0A03` | shipped (task 7) |
| `benchdsp_mix.j64` | DSP, audio mix | the workload that makes the method *mandatory* rather than optional: a 4-voice mix per sample, **published** to the DAC (LTXD/RTXD). There is no FIFO between the mix and the I2S interrupt, so an unfinished sample cannot be held back -- it has to be finished in time. Carries both schedules (1-deep and 2-deep) and picks one from the harness's flag; the envelopes live in MAIN RAM (one DRAM page per voice, so the reads are external and slow), the wavetable in the DSP's local RAM. Reports ticks per *published sample* against the I2S period (576 ticks at 46.2 kHz, 1280 at 20.8 kHz) | `$C0DE0A04` | shipped (task 8) |
| `benchgpu_interleave.j64` | GPU, 3D vertex pipeline | a software-pipelined vertex transform on the GPU RISC -- three MAC dot products, a perspective divide (the long op: 1 tick to issue, 16 ticks of background divide), the perspective multiplies -- with the vertices in MAIN RAM so the three loads per vertex are external accesses. Carries BOTH schedules and picks one at run time from a flag the harness writes into main RAM: the naive one consumes the quotient immediately (the divide's window shows up as a scoreboard stall), the interleaved one drops 16 independent, flag-transparent instructions into that window. The only ROM that reports the RISC's own tick counters, so it is the only one that can see the divide's background window at all -- the frame count cannot | `$C0DE0A03` | shipped (task 6) |
| `benchgpu_particle.j64` | GPU, particle transform | 256 particles through Euler integration + a fixed-point perspective divide, input and output in separate main-RAM buffers. The 2-deep member of an A/B pair whose two payloads are a *verified permutation* of one another (same 25 instructions, same operands, only the two MULTs move relative to the DIV), so the measured delta is placement and nothing else. The output buffer is checked bit for bit against an integer reference -- this is the ROM that exposed the timing-only harness | `$C0DE0B01` | shipped (task 9) |
| `benchgpu_particle_naive.j64` | GPU, particle transform | the immediate-consume control for the ROM above: identical instruction multiset, MULTs right after the DIV. Must show a large scoreboard count or the A/B proves nothing; the harness asserts that too | `$C0DE0B01` (same DONE magic, different `VARIANT` sentinel) | shipped (task 9) |

Run them:

```bash
make microbench          # builds the core (TEST_EXPORTS=1) + tools, runs all
```

CI runs `make microbench` on every PR/push touching `test/microbench/**` or
`test/tools/test_microbench_*` (`.github/workflows/microbench.yml`) --
see "CI" below.

Each tool prints one machine-parseable line; `done_frame` is the point of the
exercise:

```
MICROBENCH engine=68k done=1 done_frame=114 start_frame=1 count=1000000 expect_count=1000000 budget=600
```

The RISC tools also print the RISC's **per-opcode** stall histogram when
`VJ_ILV_HIST=1` is set (on stderr), which is the diagnostic a schedule
author needs:

```
ILV hist 2-deep: raw by opcode: mult=126 div=64 cmp=63 store=3  | score by opcode: imacn=8
```

⇒⇒□ `test/tools/pipe_sim.py` re-implements the core's pipeline timing model
in Python and runs the **same assembled payload** on it.  Its per-opcode
histogram must match the core's exactly -- that is the check that the model
is the model the core runs -- and once it does, it can print the
tick-by-tick timeline, which is where the "why" comes from (see
`docs/jaguar_risc_interleave.md` §12.1d).  The program descriptions live
in `test/tools/pipe_sim/`.

The `.j64` images are **committed**, so CI never needs an assembler. Regenerate
them only after editing a `.s`:

```bash
make jaguar-toolchain-build
eval "$(tools/jaguar-toolchain/setup.sh env)"
test/microbench/build.sh
```

---

## The cart bootstrap

`cartboot.inc` holds it; every ROM includes it first in `.text`. It is the
authority — this section explains *why* those bytes.

### Header layout

```
$800000 .. $8003FF   zero fill        (retail carts put the encrypted
                                       BootIntro block here; unused by us)
$800400              04 04 04 04      universal marker / cart-type byte
$800404              00 80 20 00      68K entry vector -> $802000
$800408              00 00 00 00
$80040C .. $801FFF   $FF fill
$802000              first instruction
```

This is **byte-identical** to the two public ROMs already in the repo. Both
`test/roms/yarc.j64` and `test/roms/jagniccc.j64` read, at file offset `$400`:

```
00000400: 0404 0404 0080 2000  ...... .
```

That was the working reference; the layout was pattern-matched from it rather
than inferred from spec text.

### What the core actually does with those bytes

Three separate consumers, all in this repo — verified by reading them, not
assumed:

1. **`src/core/file.c` `ParseFileType()`** — a sub-1 MiB image is accepted as
   `JST_ROM` only if `GET32(buffer, $400) == $04040404`
   (`CART_UNIVERSAL_MARKER` at `CART_UNIVERSAL_MARKER_OFFSET`). Without the
   marker our 8 KB cart would fall through to the raw-binary / unrecognized
   arms. (An exact-megabyte file is accepted on size alone, but padding five
   ROMs to 1 MiB each just to skip a header is not a trade worth making.)
2. **`src/core/file.c` `DetectPrependedHeaderSize()`** — reads file `$600`
   (= `512 + $400`) looking for the same marker to decide whether a 512-byte
   copier header is glued to the front. Our `$FF` padding there is not the
   marker, so nothing is stripped. **Keep the `$40C..$1FFF` fill non-`$04040404`.**
3. **`src/core/jaguar.c` HLE BIOS state** — `cartTypeByte =
   jagMemSpace[CART_HEADER_BASE]` (`$800400`), and `MEMCON1 = MEMCON1_BASE |
   (cartTypeByte & MEMCON1_CART_MASK)` → `$1861 | $04` = `$1865`. The marker's
   first byte doubles as the cart-type byte, so we inherit exactly the MEMCON1
   a commercial cart gets.

The entry vector at `$800404` is read by `file.c`, range-checked (must be even
and land in main RAM / cart ROM / boot ROM), stored in `jaguarRunAddress`, and
copied by `JaguarReset()` to main RAM `$000004` — which is where the 68000
fetches its reset PC. `$00802000` passes the check.

### Real-BIOS mode does **not** work — measured, not assumed

The plan's architecture note ("no BootIntro / jagcrypt") is confirmed
empirically. All runs 300 frames, sentinels read from main RAM afterwards:

| image | mode | final 68K PC | sentinels |
|---|---|---|---|
| `bench68k.j64` | HLE (harness default) | `$80202C` (the `bra.s *` park) | all written |
| `bench68k.j64` | `--bios` | `$0050B6` | untouched |
| jagcrypt `-u` signed variant | `--bios` | `$0059A0` | untouched |
| jagcrypt `-u` signed variant | HLE | `$80202C` | all written |

The pinned `pc_jagcrypt` *will* run (`jagcrypt -u bench68k.rom` produces a
`.U1`, contrary to what the `-tursi` gap might suggest), but the RSA data it
generates is not what the emulated Series K BIOS validates against, so the
signed image is no more bootable under `--bios` than the plain one. It is also
worse for our purposes: the signing pass is not byte-reproducible.

**Conclusion: these ROMs are HLE-boot only.** That is fine — `test/harness/`
defaults to HLE (`--bios` is opt-in) and the microbench tools never pass it.

---

## Sentinel convention — all five ROMs

`$010000`–`$01000F` is the **reserved sentinel block**. Benchmark working
buffers (blitter destinations, GPU scratch) must live at **`$020000` or
above** so they can never reach it.

| address | meaning |
|---|---|
| `$010000` | START magic `$C0DE57A7` — written at the entry point by every ROM |
| `$010004` | DONE magic — per-engine, see the table at the top |
| `$010008` | iterations actually executed |
| `$01000C` | reserved |

Write the **count before the magic**, so a reader that sees DONE is guaranteed
to see a settled count.

Why `$010000` and not the plan's sketched `$001000`: `HLE_SSP_CART` is `$4000`
(`src/core/jaguar.c`), and the 68K stack grows down from there straight through
`$1000`. `$010000` sits above the stack, above the HLE vector table
(`$0`–`$3FF`) and its RTE stubs (`$400`/`$404`), and well inside the 2 MB of
main RAM. Main RAM reads back all-zero at reset in HLE mode, so "never ran" is
distinguishable from any magic value.

Having **both** a START and a DONE marker is what makes a failure legible: the
tool reports `start_frame=-1` ("ROM never booted") separately from
`done_frame=-1` with `start_frame=1` ("booted, didn't finish in budget").

---

## Frame budget

The harness runs a fixed frame count and then reads memory; the ROM never has
to signal exit (each parks in `bra.s *`). **The budget must exceed the loop's
completion frame**, and completion moves with the core's timing model.
Measured for `bench68k.j64` (1,000,000 iterations):

| configuration | done_frame |
|---|---|
| harness defaults | 114 |
| `virtualjaguar_gpu_pipeline_timing=enabled` | 114 |
| PAL | 114 |
| `virtualjaguar_dram_timing=enabled` | 128 |
| both + `VJ_DRAM_SCALE=8` | 228 |
| both + `VJ_DRAM_SCALE=12` | 288 |
| both + `VJ_DRAM_SCALE=16` | 350 |

`virtualjaguar_dram_timing` and `virtualjaguar_gpu_pipeline_timing` both default to `disabled`, so the
default path is 114. The tools use **600** — clears the slowest measured
configuration with ~1.7x margin, at about a second of wall time.

Sanity check on 114: the 3-instruction body costs a nominal 26 cycles on a
68000 (`addq.l` 8 + `subq.l` 8 + taken `bne.s` 10), so 26 M cycles at ~13.3 MHz
≈ 1.95 s ≈ 117 fields at 60.05 Hz.

**If you change an `ITERATIONS` value, re-measure and update both the `.s`
comment and the tool's budget block.**

Measured for `benchgpu_arith.j64` (2,000,000 iterations). **Correction
(fix round 1, 2026-08-24): the `virtualjaguar_gpu_pipeline_timing=enabled` row below was
previously published as `86` (flat, no response). That was never re-measured
after being copied from an earlier draft of this table -- a direct run shows
it moves to `172`, a ~100% jump, the largest relative move of any
configuration tested against this ROM:**

| configuration | done_frame |
|---|---|
| harness defaults | 86 |
| `virtualjaguar_gpu_pipeline_timing=enabled` | 172 |
| `virtualjaguar_dram_timing=enabled` | 86 |
| PAL | 86 |
| both + `VJ_DRAM_SCALE=8` | 172 |
| both + `VJ_DRAM_SCALE=12` | 172 |
| both + `VJ_DRAM_SCALE=16` | 172 |

`virtualjaguar_dram_timing` alone doesn't move this ROM: the 2M-iteration hot loop runs
entirely out of GPU local RAM and touches external memory only for its two
sentinel STOREs, and `VJ_DRAM_SCALE` only scales external-memory latency.
`virtualjaguar_gpu_pipeline_timing` is the mover, and it roughly *doubles* the completion
frame -- see the explanation after the branch-ROM table below, which covers
both ROMs together. The tools use the same **600** budget as `bench68k.j64`
for consistency across the five ROMs; it clears 172 with ~3.5x margin.

Measured for `benchgpu_branch.j64` (2,000,000 iterations, 21-instruction
body -- see the `.s` for the exact composition: 1 CMPQ + 8 not-taken
JR/NOP pairs + ADDQ + SUBQ + 1 JUMP/NOP loop closer, ~90% branch dispatch):

| configuration | done_frame |
|---|---|
| harness defaults | 91 |
| `virtualjaguar_dram_timing=enabled` | 91 |
| PAL | 91 |
| `virtualjaguar_gpu_pipeline_timing=enabled` | 113 |
| both + `VJ_DRAM_SCALE=8` | 113 |
| both + `VJ_DRAM_SCALE=12` | 113 |
| both + `VJ_DRAM_SCALE=16` | 113 |

### `virtualjaguar_gpu_pipeline_timing` response: arith moves MORE than branch, not less

An earlier draft of this document (and `task-3-report.md`) claimed
`benchgpu_arith.j64` stayed flat under every configuration including
`virtualjaguar_gpu_pipeline_timing`, and that only `benchgpu_branch.j64` responded to it.
**That was false and came from an unverified copy of the arith row above.**
Directly measured, both ROMs respond, and arith responds *more*, both in
absolute frames (+86 vs. +22) and relative terms (+100% vs. +24%):

| ROM | defaults | `virtualjaguar_gpu_pipeline_timing=enabled` | delta |
|---|---|---|---|
| `benchgpu_arith.j64` | 86 | 172 | +86 frames (+100%) |
| `benchgpu_branch.j64` | 91 | 113 | +22 frames (+24%) |

`virtualjaguar_dram_timing` alone still doesn't move either ROM (both loops run entirely
out of GPU local RAM), and `VJ_DRAM_SCALE` has no further effect once
`virtualjaguar_gpu_pipeline_timing` is already enabled for either ROM -- confirming the
extra cost in both cases comes from the pipeline model's internal-RISC-time
accounting, not from DRAM access latency.

The mechanism (read from `src/tom/gpu.c` `GPUPipeCheckUse()`, not guessed):
`virtualjaguar_gpu_pipeline_timing` implements two interlocks off the JTRM's
"Register Write-Back" section, checked in order. First, an **ALU RAW
interlock**: if either of the instruction's register reads targets the
*previous* instruction's write-back destination, that read isn't ready yet
and the instruction stalls 1 cycle -- this is the common case, since reading
a value the instruction immediately before you just produced is exactly what
chained ALU code does. Only if that check doesn't fire does the second rule
apply: a **write-back port conflict** -- the GPU register bank is dual-port,
so an instruction that reads **two** registers, *neither* of which is the
previous instruction's destination, still can't have both reads serviced
alongside the pending write-back and pays the same 1-cycle stall. The only
way to dodge both is to read **fewer than two** registers and, if you read
one, have it not be the previous instruction's destination -- back-to-back
register-writing ALU code essentially never satisfies that (`gpu.c` around
the "ALU RAW interlock" / "Write-back port conflict" comments).

- **`benchgpu_arith.j64`'s** loop body is 16 back-to-back ALU ops
  (`add`/`sub`/`and`/`or`), each of which both reads two registers and writes
  a third (JTRM ISA classification 7 = reads-both-writes-dest in
  `gpu_pipe_flags[]`). Consecutive pairs almost never share the prior
  instruction's destination as an operand, so nearly every one of the 16 ALU
  ops eats the 1-cycle write-back stall -- roughly +16 cycles on a ~20-cycle
  nominal body, which is why the completion frame very nearly doubles (86 ->
  172, and 172/86 = 2.00).
- **`benchgpu_branch.j64`'s** loop body is dominated by JR and its
  mandatory delay-slot NOP (16 of 21 instructions across the 8 not-taken
  pairs). Both JR and NOP are classified as reading zero registers
  (`gpu_pipe_flags[]` index 0 for both), so they structurally cannot trigger
  the two-register-read write-back conflict -- only the loop's CMPQ, ADDQ,
  and SUBQ (each of which reads at most one register per the same table) are
  even eligible, and none of those pairings triggers the rule either. What
  branch-heavy code does pay for instead is the JTRM's documented taken-JUMP
  refill cost and the flags interlock between CMPQ and a conditional
  JR/JUMP -- smaller, less frequent charges, which is why the ROM moves by
  22 frames instead of 86.

In short: `virtualjaguar_gpu_pipeline_timing`'s dominant cost in this model is a per-ALU-op
register-bank contention charge, not a branch-misprediction charge -- so a
tightly-chained ALU body (arith) is the *worse* case for it, and a
control-flow-heavy body built from register-free JR/NOP pairs (branch) is
comparatively cheap. This is the opposite of the "branch-heavy code is what
pipeline timing punishes" intuition #536 set out to test, and is worth
knowing before using either ROM as a stand-in for real branch-misprediction
cost. The tools use the same **600** budget as the other ROMs for both
ROMs; it clears the highest measured frame (172) with ~3.5x margin.

Measured for `benchdsp.j64` (2,000,000 iterations, identical 20-instruction
body to `benchgpu_arith.j64` for a direct GPU-vs-DSP interpreter comparison
at the same clock):

| configuration | done_frame |
|---|---|
| harness defaults | 86 |
| `virtualjaguar_gpu_pipeline_timing=enabled` | 86 |
| `virtualjaguar_dram_timing=enabled` | 86 |
| both | 86 |

Same default completion frame as `benchgpu_arith.j64` (both 86, both engines
run this identical body at the same ~26.6 MHz full-system clock), **but the
DSP does not respond to `virtualjaguar_gpu_pipeline_timing` the way the GPU does** -- all
four configurations above were re-run directly against this ROM (not
inferred from the GPU table). This isn't a coincidence of this workload:
`src/jerry/dsp.c`'s `DSPExec()` comment block states outright that "the DSP
has no pipeline-timing mode of its own (`DSPExecP`/`DSPExecP2` are declared
in `dsp.h` but never called)" -- `virtualjaguar_gpu_pipeline_timing` only gates the DSP's
*idle-skip fast-forward* path (irrelevant here, since this loop never idles)
and adds no per-instruction cost model for the DSP the way `GPUPipeCheckUse()`
does for the GPU. `virtualjaguar_dram_timing` doesn't move it either, for the same reason
as the GPU ROM: the hot loop runs entirely out of DSP local RAM and touches
external memory only for its two sentinel STOREs. The tool uses the same
**600** budget as the other four ROMs; it clears 86 with ~7x margin.

Measured for `benchblit.j64` (150,000 launches of a 32x32 8bpp PATDSEL solid
fill; see "The blitter ROM is 68K-only" below for why this one has no
companion GPU/DSP source and no per-loop table like the previous three).
Unlike the other four ROMs, its fill destination (`$020000`, the benchmark
work buffer) is **main RAM**, so — checked directly, not assumed by analogy
with the GPU/DSP ROMs whose hot loops never leave local RAM — it responds to
`virtualjaguar_dram_timing` on its own, `virtualjaguar_blitter_timing` dominates, and the
combination can exceed the other ROMs' 600-frame budget:

| configuration | done_frame |
|---|---|
| harness defaults | 87 |
| `virtualjaguar_gpu_pipeline_timing=enabled` | 87 |
| PAL | 87 |
| `virtualjaguar_dram_timing=enabled` | 101 |
| `virtualjaguar_blitter_timing=enabled` | 434 |
| `virtualjaguar_dram_timing` + `virtualjaguar_blitter_timing` + `virtualjaguar_gpu_pipeline_timing` | 458 |
| all three + `VJ_DRAM_SCALE=8` | 564 |
| all three + `VJ_DRAM_SCALE=12` | 607 |
| all three + `VJ_DRAM_SCALE=16` (worst measured) | 631 |

`virtualjaguar_blitter_timing` (default disabled, off in `make microbench`'s
run) is the mover by a wide margin — it is the option that charges the
blit's own bus-occupancy cost (`BlitDurationSysclks()` in
`src/tom/blitter_mmio.c`; the "Fixed setup" comment in `benchblit.s` covers
where that cost lands). `virtualjaguar_gpu_pipeline_timing` never moves this ROM at all
(it gates GPU/DSP RISC-instruction pipeline accounting; nothing here runs on
either processor). Because 631 exceeds the other ROMs' 600-frame budget,
`test_microbench_blit`'s `MB_FRAME_BUDGET` is **1200**, not 600 — a
deliberate, documented difference, not an oversight (see the tool's own
comment).

### The interleave ROM measures the RISC's tick counters, not frames

`benchgpu_interleave.j64` is the first ROM in this set whose *result* is
not a frame count. The frame count cannot see the divide's background
window: a divide that issues in 1 tick and takes 16 ticks of background
work looks identical to a divide that takes 17 ticks, unless something
else is stalled behind it.

So this ROM reports the GPU's own pipeline counters (the test ABI's
per-cause stall breakdown: `gpu_pipe_ticks_total`, `gpu_pipe_issue_total`
and the score/RAW/port/flags stalls). The GPU clears its own `GPUGO` when
it is done, which freezes the counters, so the harness can read them
exactly.

It also runs the ROM **twice** -- once per schedule -- by loading the ROM
again between the runs (`retro_load_game` resets the machine, which clears
both main RAM and the tick counters) and writing the schedule flag into
main RAM in between. Same ROM, same buffers, same bus traffic; only the
GPU's instruction placement differs.

Measured (64 vertices, the default configuration):

| schedule | instructions | ticks | scoreboard stalls | ticks/vertex |
|---|---|---|---|---|
| naive (the quotient is consumed at once) | 1818 | 4713 | 1472 | 73.64 |
| interleaved (16 instructions in the divide's window) | 2842 | 4841 | 512 | 75.64 |

⇒ **1024 extra instructions (16 per vertex) for 128 extra ticks (2 per
vertex): the marginal price of a shadow instruction is 0.125 ticks
instead of ~1.** The scoreboard stalls drop by 960 -- exactly the
divide's 15 ticks per vertex. The vertex rate itself is 2.7% *slower*,
because the shadow is not free in the strict sense: it is free against
the divide's window, but the loop's own work still has to happen.

The ROM also carries a **third** schedule, the 2-deep software pipeline
(flag 2), which keeps two vertices in flight so the loads land a full
iteration before their use:

| schedule | GPU instr | GPU ticks | GPU score | GPU ticks/vertex | DSP ticks/vertex | DSP score |
|---|---|---|---|---|---|---|
| naive | 1818 | 4713 | 1472 | 73.64 | 79.69 | 1664 |
| interleaved (1 deep, 16 filler ops) | 2842 | 4841 | 512 | 75.64 | 81.69 | 704 |
| **2-deep** | **1814** | **3314** | **8** | **51.78** | **54.98** | **12** |

⇒ On the DSP the 1-deep interleave is **not enough** -- Jerry's 16-bit
external bus makes the load stall bigger than the 16-tick divide window
can absorb (the score stalls only fall 1664 -> 704, not -> 512).  The
2-deep pipeline handles it anyway (704 -> 12), and its gain is bigger
than the GPU's: **79.69 -> 54.98 ticks/vertex, 31%**.

⇒ The 2-deep pipeline is a **30% better vertex rate** *and* it needs
**no filler instructions at all** -- the divide's window is filled with
the next vertex's real work, and the loads' latency is hidden by the
same one-iteration gap. It uses **no extra registers**: the pipeline
reuses the same coordinate and result sets in a different order, which
is the same "disjoint in time" rule the rotating register allocation
follows.

(The flag the harness writes into main RAM is **big-endian** -- the 68K
reads it as a longword and the Jaguar is big-endian. Writing it
little-endian is what made the 68K see `0x01000000` instead of `1`;
measured, not assumed.)

With a contended DRAM (`VJ_DRAM_SCALE=8`) the absolute saving is
unchanged (960 ticks, the same 15 per vertex) but the *ratio* of stalls
shrinks, because the vertices' own external loads now dominate the stall
total: 3712 → 2752. That is why the tool's pass condition is an
absolute saving (>= 10 ticks per vertex) and not a ratio.

### The blitter ROM is 68K-only

`benchblit.s` has no `benchblit_gpu.s`/`benchblit_dsp.s` companion and no
lyxass pass. The blitter is a DMA engine addressed entirely through 68K
writes to its MMIO register file (`$F02200-$F0229F`); there is no separate
program to load onto another processor, so this ROM reuses Task 1's
cart-boot shape directly (`bench68k.s`'s `.include "cartboot.inc"` followed
by 68K code) rather than Tasks 2-4's 68K-bootstrap-plus-RISC-payload split.

### IDLE poll is a no-op in this emulator — verified, not inferred

`benchblit.s` polls `B_CMD`'s bit 0 between blit launches, matching the
hardware-programming idiom in `docs/jtrm-blitter.md`'s "B_CMD Status"
section. In **this core specifically**, that poll never actually waits:
`src/tom/blitter_mmio.c`'s `BlitterReadByte` hard-codes the status byte at
`COMMAND+3` to `$05` ("always idle/never stopped"), and `BlitterWriteWord`
dispatches the fill synchronously (calls straight into `blitter_blit()` /
`BlitterMidsummer2()`) before the write instruction that triggered it even
retires — there is no modeled "blitter running in the background" state for
a poll to observe. The poll is included because it is what real Jaguar code
does and because the ROM should look like a plausible blit-launch loop, not
because it changes this ROM's timing on this core.

---

## The particle-transform pair — and how to prove a ROM, not just time it

`benchgpu_particle.j64` runs 256 particles through

```
x += vx ; y += vy ; vx += 1 ; vy += 1
q     = 65536 / y            <- the long op
out_x = x * q ; out_y = y * q
```

with the input at `$020000` and the output at `$030000` (the 68K bootstrap
clears the output first, so a payload that silently stops storing cannot
hide behind stale RAM).  `benchgpu_particle_naive.j64` is the same math on
the same data with the two `mult`s moved next to the `div`.

### The bug this pair was built to catch

The first revision of this ROM stored through the **input** cursor:

```
store r29,(r14)
store r30,(r14+4)
addq  #16,r14
```

so particle *k*'s result overwrote particle *k+1*'s x,y and was read back
as input.  A live `gdb` read of `$020000` showed `P1=(0,0,5,6)` where the
68K had written `P1=(3,4,5,6)`: from P1 on, the "simulation" integrated
zeros.

It still finished 256 particles and still scored **10** stall ticks, so it
**passed** the old harness.  That is the failure mode the current harness
closes: `test_microbench_gpu_particle.c` now recomputes all 256 outputs in
C and compares them word for word (`data_bad=` in the MICROBENCH line).
The original payload is kept as a regression control in
`known_bad/` — rebuild it with `known_bad/build.sh` and it fails with
`data_bad=256 first bad P0`.

### Why the A/B is a controlled experiment

`test/tools/check_particle_permutation.py` decodes both assembled blobs,
locates the steady-state loop (via the `movei #loop,r13` target) and
asserts the two 25-instruction bodies are the **same multiset** — same op,
same operands, same count:

```
$ python3 test/tools/check_particle_permutation.py deep.bin naive.bin
OK: body instruction multisets are IDENTICAL (25 instructions)
```

The only difference is where four instructions sit:

| | 2-deep | naive |
|---|---|---|
| `move r8,r29` / `mult r28,r29` / `move r9,r30` / `mult r28,r30` | top of the body, consuming the *previous* iteration's quotient | immediately after `div`, waiting on it |

So the measured difference cannot be explained by "more work" or
"different data".

### Measured

| `VJ_DRAM_SCALE` | 2-deep ticks | naive ticks | 2-deep t/p | naive t/p | saved |
|---|---|---|---|---|---|
| 1 | 14142 | 18497 | 55.24 | 72.25 | 23.5% |
| 2 | 16734 | 23637 | 65.37 | 92.33 | 29.2% |
| 4 | 26249 | 33917 | 102.54 | 132.49 | 22.6% |
| 8 | 46809 | 54477 | 182.85 | 212.80 | 14.1% |

Scoreboard stalls: **9 vs 4101** at scale 1 (14 vs 5381 at 2, 24 vs 7941
at 4).  The deep run's handful of stalls are the load→`add` boundary, not
the divide; the naive run's 3840 `mult` stalls are the divide window,
exposed once per particle (15 ticks × 256).

`pipe_sim.py` on the same payloads:

| | core ticks | model ticks | core instr | model instr | score stalls |
|---|---|---|---|---|---|
| 2-deep | 14142 | 14408 | 6164 | 6420 | add=9 / add=9 |
| naive | 18497 | 18764 | 6167 | 6424 | add=261 mult=3840 / add=6 mult=3840 |

The instruction offset is the jump delay slot: the core folds it into the
jump, the model charges it, so model = core + iterations + 1.  The tick
offset is that plus a constant 10 ticks of prologue accounting, in both
runs.  **The schedule's value agrees to 1 tick out of 4356** (core saved
4355, model 4356).  The one histogram difference is the naive control's
`add` count: the core's per-access DRAM cost comes from
`bus_arbiter_charge_access` (address/page dependent) while the model uses
a constant, and at the load→`add` boundary that moves a 1-tick wait
between the scoreboard and bus counters.  The `mult` signal — the thing
being measured — matches exactly.

### Running the proof

```bash
make particle-verify
```

or directly (needs `gdb` and `python3`, no compiler):

```bash
test/tools/particle_ab.sh
```

It (1) regenerates the blobs and checks the permutation, (2) runs both
ROMs, (3) reads the output buffer live out of the running core with
`dump binary memory` at a `harness_report` breakpoint and compares it to
`test/tools/particle_reference.py`, and (4) cross-checks both tick totals
against `pipe_sim.py`.  `make microbench` also runs both ROMs and asserts
each one's expected stall profile.

---

## The demo ROMs — putting a picture on the Jaguar screen

The five benchmark ROMs above are headless by design: they measure ticks,
and every cycle they spend on video is a cycle that muddies the
measurement.  Two extra ROMs here are the opposite — they exist to be
**looked at**, and they are the proof that the whole video path works in
this core:

| ROM | what it shows |
|---|---|
| `benchdemo_vidprobe.j64` | a full-screen gradient — the smallest ROM that proves the Object Processor path |
| `benchdemo_particles.j64` | 64 particles exploding from the screen centre, each a different hue, on a 320×240 screen |
| `benchdemo_audio.j64` | a 68K-only I2S square wave (~2.75 kHz, stereo) — the audio path end to end |

Watch them in RetroArch, or listen to the audio one without an emulator:

```bash
test/microbench/run_demo.sh              # the particle explosion
test/microbench/run_demo.sh vidprobe     # the gradient probe
test/microbench/run_demo.sh audio        # the square wave, in RetroArch
test/microbench/run_demo.sh audio --wav  # ...or straight to a .wav file
test/microbench/run_demo.sh bigpemu      # run it in BigPEmu instead
```

The script copies the freshly built core into RetroArch's cores directory
and launches it with the ROM loaded.  It needs RetroArch
(`flatpak install --user flathub org.libretro.RetroArch`); if RetroArch is
not installed it prints that command and exits.

`--wav` needs no emulator at all: it runs the core headless (through
`test/tools/test_demo_audio`), captures what the audio callback produced
and writes a plain 48 kHz stereo WAV, then hands it to the desktop's
default player.  That is the quickest way to hear the demo, and the file
is also something a regression can be diffed against.

`bigpemu` launches the same ROM in BigPEmu (`flatpak install --user
flathub com.richwhitehouse.BigPEmu`), which is a useful second opinion:
the two emulators are independent implementations, so if they disagree
about a ROM one of them has a real bug.

`test/tools/test_demo_particles.c` is the headless counterpart: it runs a
demo ROM, counts the lit pixels, dumps every frame as a PNG
(`--frames-out DIR`), can dump the 2 MB of main RAM (`--ram-out FILE`)
and asserts that the simulation actually moved the particles.  Sample
output is committed under `docs/images/`.

### The recipe — how a 16-bpp Jaguar bitmap reaches the screen

This is the part that took the whole session to get right, so it is
written down here rather than rediscovered:

1. **Program the display geometry.** The core recomputes `tomWidth` /
   `tomHeight` only when a TOM register in `$28..$4F` is *written*
   (`tom.c`, "detect screen resolution changes").  A ROM that never
   writes VMODE leaves `tomWidth = 0`, and the scanline renderers then
   draw **zero pixels per row** — a completely black screen even though
   the OP filled the line buffer correctly.  Write VMODE/VDB/VDE at
   startup.

2. **VMODE's bit 8 (`VARMOD`) picks the pixel format.** Without it the
   core uses mode 0, the **CRY** renderer, where a 16-bit pixel is a
   cyan/red/yellow colour.  With it (mode 4) the *mixed* renderer runs
   and **bit 0 of each pixel** picks RGB555-direct vs CRY.  For a plain
   RGB picture use `VMODE = $07C1` and set bit 0 in every pixel.

3. **RGB16 is `R[15:11] B[10:6] G[5:0]`** — green is the low *six*
   bits and blue sits above it (`docs/jtrm-object-processor.md`; the core's
   `RGB16ToRGB32[]` agrees).  The usual 5-6-5 intuition is wrong here.

4. **The OP fetches phrases little-endian; the 68000 is big-endian.**
   A 16-bit pixel must be stored **byte-swapped** in memory, or the OP
   reads it with its halves exchanged.

5. **The OP consumes the object once per field.** It decrements HEIGHT
   and advances DATA on every line it renders, so the object must be
   re-armed once per field (a field is `VP+1` = 524 halflines; the OP
   renders the 240 even halflines of the visible window).

6. **Re-arm in the blanking *before* the OP's first pass of the field**
   (VC below VDB), not "whenever VC is past the visible window": the
   blanking window is several halflines wide and a level test fires on
   every poll in it.  Worse, each re-arm is two longword stores, and if
   the OP reads the object between them it sees a fresh DATA with an
   **exhausted HEIGHT**, skips the object, and the line comes out
   background black.

7. **The framebuffer holds 16-bit pixels written with WORD stores.** A
   longword store pads every pixel to four bytes and the OP reads the
   padding as pixels.

### The BITOBJ encoding (from `src/tom/op.c`)

```
p0 = type | ypos<<3 | height<<14 | link<<21 | data<<40
p1 = xpos | depth<<12 | pitch<<15 | dwidth<<18 | iwidth<<28
```

* `depth` 4 = 16 bpp.  `pitch` = bytes per phrase (1 → 8).
  `dwidth` = **bytes** per source line (the field holds phrases: 80 for a
  640-byte line).  `iwidth` = phrases to render (80 for 320 px) and it
  **spills into the high longword**.
* `link`/`data` are byte addresses with the low three bits clear.  The
  LINK's high bits land in the **high longword bit 6** — one bit off
  encodes link `$010010` (the sentinel block) and the screen stays black.

## Reading the RISC register file (host-only)

`test/tools/risc_regdump.sh` prints the GPU or DSP register file as a
4-per-row hex grid, in the style of a ChibiAkumas debugger screenshot.
It runs the existing harness under host gdb, stops at `harness_shutdown`,
and reads the `TEST_EXPORTS=1` getters (`GPUGetReg`/`GPUGetPC`/
`GPUGetFlags`/`GPUGetControl`, or the DSP equivalents) — no core change
and no extra build:

```bash
test/tools/risc_regdump.sh                  # GPU, particle ROM
test/tools/risc_regdump.sh --map particle   # + register roles
test/tools/risc_regdump.sh --dsp            # DSP, benchdsp_mix
```

The dump is the state at halt, not a trace.  It is deliberately not part
of `make test`: it needs gdb, which the devbox image does not ship.  Run
it on the host against a tree already built with `TEST_EXPORTS=1`.  The
particle ROM's `r14`/`r15`/`r17` snapshot is a useful sanity check that
the cursor and counter landed where the schedule model says they should.

## Assembling: what actually worked

> **Check the assembler you are using before you trust it.** The toolchain
> is vendored *outside* this repository (`tools/vendor/jaguar-toolchain/`,
> gitignored, fetched by `tools/jaguar-toolchain/setup.sh`), so it is not
> under this repo's control — and it can be wrong in ways that nothing
> reports.  A local, uncommitted edit to rmac's machine table
> (`68k.mch`) once changed the AND opcode from `$C` to `$B`, so every
> `and.l Dn,Dm` assembled as `cmp.l Dn,Dm`: a silent, well-formed,
> completely wrong instruction, and every "the assembler is broken"
> conclusion drawn from it was wrong.
>
> Before trusting an assembler result:
>
> ```bash
> git -C tools/vendor/jaguar-toolchain/rmac status --short   # must be empty
> git -C tools/vendor/jaguar-toolchain/rmac diff              # must be empty
> ```
>
> and rebuild it from scratch (`make clean && make`) so no stale object
> file from an earlier experiment survives.  `test/microbench/benchdemo_alu.s`
> plus `test/tools/test_demo_alu.c` exist for exactly this: they run 16
> register-register ALU forms and compare the results against the 68000's
> documented answers, so a mis-assembled mnemonic fails a test instead of
> quietly changing the demo.
>
> rmac's real limits, all re-verified against the pinned upstream SHA
> `50e66ea` built from a pristine checkout:
>
> * **A label in an indexed form is mis-assembled.** `move.w TBL(a0),d1`
>   comes out as `MOVE.W (d16,A0),D1` with the *section-relative*
>   offset of `TBL` in the extension word, so the effective address is
>   short by the section base and the read lands in the wrong place.
>   `move.l #TBL,aN` + `move.w (aN),Dn` is the way to write it.
> * **The index scale of `d(An,Am)` is always "byte"**, whatever the
>   access width, so a word or long access through two registers reads
>   the wrong address.  Use one register plus an explicit add.
> * `cmp #imm,Dn` is encoded as a CMP with an *immediate* effective
>   address (`B0 7C ..`), which the 68000 does not have — write
>   `cmpi.w` / `cmpi.l`.
> * `mulu.w #$imm,Dn` is likewise an immediate-EA form (`C4FC` + the
>   immediate, i.e. `MOVE.L #imm,(A2)+`), not a multiply.  `mulu.w
>   Dn,Dn` (a register source) is correct.
> * Only `d0`-`d7`/`a0`-`a7` exist; `d8+` is an "undefined expression".
>   `MOVEQ` is data-register only.  Shift immediates are 1..8 and `ADDQ`
>   immediates are 1..8.  `MULU` has no register-register *long* form
>   ("unsupported for selected CPU").
> * **Forward branches do work.** rmac sizes the displacement itself and
>   the linker patches the deferred 16-bit form; the one exception is a
>   branch to the *immediately following* instruction, which comes out
>   as a NOP (`4E 71`) — the same behaviour, so it is harmless.
> * Symbols are **case-sensitive** (`later` and `LATER` are different
>   symbols).  A case mismatch is reported as
>   `Error: undefined expression`, which reads like a toolchain bug but
>   is not.
> * A number without a `$` is **decimal**: `#00010020` is ten thousand
>   and twenty, not `$10020`.  Always write hex constants with `$`.

```bash
rmac -fb -o bench68k.o bench68k.s
rln  -n -a 800000 x x -o bench68k.j64 bench68k.o
```

```bash
rmac -fb -o bench68k.o bench68k.s
rln  -n -a 800000 x x -o bench68k.j64 bench68k.o
```

Gotchas, all learned from the tools' own errors:

- **No `.org` in a 68K section.** rmac: *"Error: .org permitted only in
  GPU/DSP/OP, 56001, 6502 and 68k (with -fr switch) sections"*. The load address
  goes on `rln -a` instead, which is how a real cart is built anyway — hence
  the header being laid out with `dcb.b` fill from offset 0 and linked at
  `$800000`.
- **`-fb`** selects BSD object format, which rmac's own usage text labels *"use
  this for Jaguar"* and is what rln consumes.
- **`rln -n`** suppresses rln's file header, so the output is the raw
  big-endian cart image. rln pads the tail out to an 8-byte phrase, which is
  why `bench68k.j64` is 8240 bytes rather than the 8238 the source emits.
- **`rln` needs the two positional `x x` placeholders** (data/bss segment
  addresses) after `-a <text>`.
- `.include` and `.incbin` both work in rmac (verified). `build.sh` `cd`s into
  `test/microbench/` so `.include "cartboot.inc"` resolves without an `-i` flag.
- **Output is byte-reproducible.** Two consecutive builds of an unchanged
  source `cmp` identical, so a regenerated `.j64` diffs only when the source
  really changed.

### For tasks 2–5: embedding a lyxass GPU/DSP blob

`lyxass` output is **not** raw code. It is a **12-byte BS94 header** followed by
the code (see `tools/jaguar-toolchain/smoke/hellogpu.s`, which documents the
exact layout):

```
4253 3934    "BS94" magic
00F0 3000    run address
0000 0004    code length
D7E0 E400    <-- the actual code starts here, at offset 12
```

A naive `.incbin` of a lyxass `.o` therefore embeds the header, and the RISC
will happily execute `BS94` + address + length as instructions. **Skip the
first 12 bytes** — either strip them when generating the blob, or have the 68K
loader copy from `blob+12`.

The other lyxass trap from that same file: it emits **nothing** for code placed
before its `.run` directive, while still exiting 0 and still writing a
12-byte-header file. Put `.run` after `.org` and before the first instruction.

---

## CI

`.github/workflows/microbench.yml` runs `make microbench` on `ubuntu-latest`
for every PR/push (to `develop`/`master`) that touches `test/microbench/**`,
`test/tools/test_microbench_*`, `test/harness/**`, `Makefile`, or
`Makefile.common`, plus `workflow_dispatch`. Same shape as `jaguar-demos.yml`'s
smoke job: build the core with `TEST_EXPORTS=1`, run the target, tee the log
to the step summary, upload it as an artefact on any outcome. It path-filters
on `test/microbench/**` and `test/tools/test_microbench_*` specifically --
**not** `tools/jaguar-toolchain/**` -- because the whole point of committing
the `.j64` images is that this job never has to build or invoke the assembler
toolchain: `make microbench` builds the core plus the five
`test_microbench_*` tools and runs each against its committed `.j64`, and
nothing in that path touches `tools/jaguar-toolchain/`, `rmac`, `rln`, or
`lyxass` (verified by grepping the `microbench` target and its tool build
rules in the `Makefile`). `test/microbench/build.sh` is the only thing that
calls into the toolchain, and it's a manual regeneration step CI never runs.

**What this job does NOT cover.** The path filter deliberately omits
`src/**`, so a change to `src/tom/gpu.c`, `src/jerry/dsp.c`, or any other
emulation-accuracy source does not trigger this workflow -- see
`jaguar-demos.yml`/`c-cpp.yml` for the jobs that build+test on `src/**`
changes. Even when it does run, these tools assert on **iteration count**,
not wall-clock or cycle-count -- `done=1` just means the fixed loop finished
inside the frame budget (600/1200 frames against a measured 86-114 default).
That makes this a "did the engine still run to completion in a sane window"
smoke check, not a performance regression gate; a change that quietly halves
or doubles a `done_frame` without ever exceeding the budget will not fail
here.

## How to add a 6th ROM

Follow Task 1-5's pattern exactly; nothing here is per-engine special-cased
in the harness or the Makefile beyond adding one more of each.

1. **Source.** Write `test/microbench/benchNNN.s` (68K-only, following
   `bench68k.s`), or `benchNNN.s` + `benchNNN_gpu.s`/`benchNNN_dsp.s` (68K
   bootstrap + RISC payload, following `benchgpu_arith.s` /
   `benchgpu_arith_gpu.s`). Start from `.include "cartboot.inc"` -- do not
   hand-roll the cart header. Pick a fixed `ITERATIONS` and a **new** DONE
   magic (`$C0DE0xxx` convention; don't reuse one of the five above) written
   to `MB_SENT_DONE` (`$010004`) after the count at `MB_SENT_COUNT`
   (`$010008`), per the sentinel convention above. Any working buffer goes at
   `$020000` or above, never in `$010000-$01000F`.
2. **Assemble + commit the `.j64`.** Add `benchNNN.s` (and any RISC
   companion) to the loop in `build.sh`, then run it (needs the toolchain:
   `make jaguar-toolchain-build && eval "$(tools/jaguar-toolchain/setup.sh env)"`)
   and commit the resulting `benchNNN.j64` alongside the source. CI never
   assembles -- if the committed `.j64` and the `.s` it should come from
   diverge, nothing catches that automatically, so regenerate and diff
   before committing.
3. **Harness tool.** Copy `test/tools/test_microbench_68k.c` (or
   `test_microbench_gpu_arith.c` if it's a GPU/DSP payload) to
   `test/tools/test_microbench_NNN.c`, and update: the DONE magic, expected
   iteration count, and `MB_FRAME_BUDGET` (measure the real completion frame
   across at least harness defaults, `virtualjaguar_dram_timing=enabled`,
   `virtualjaguar_gpu_pipeline_timing=enabled`, and PAL before picking a budget -- see the
   "Frame budget" tables above for the methodology and how much headroom the
   existing five carry). **The harness's `--option` flag silently ignores any
   key it doesn't recognize** -- there is no error, no warning, and the
   `done_frame` comes back identical to the default run, which is
   indistinguishable from "this ROM doesn't respond to the option." This is
   exactly what produced the false `gpu_pipeline_timing=86` (flat) claim
   fixed in commit `10c9a62`: the option name was missing its
   `virtualjaguar_` prefix. Always pass the **full, prefixed** core option
   key, e.g.:

   ```bash
   ./test/tools/test_microbench_NNN ./virtualjaguar_libretro.dylib \
       test/microbench/benchNNN.j64 \
       --option virtualjaguar_gpu_pipeline_timing=enabled
   ```

   and confirm at least one row of your frame-budget table actually moves
   off the default `done_frame` before publishing a table where it doesn't
   -- a flat row you haven't independently verified is more likely a typo'd
   option key than a genuinely inert configuration.
4. **Wire the Makefile.** Add a `test/tools/test_microbench_NNN` build rule
   next to the other five (same recipe shape, `test/tools/test_microbench_68k`
   is the template), and append the new tool + `.j64` to
   `MICROBENCH_TOOLS`/`MICROBENCH_ROMS` in the `microbench` target.
5. **Document it.** Add a row to the ROM table at the top of this file (what
   it isolates, DONE magic), and a "Measured for `benchNNN.j64`" frame-budget
   table in the style of the existing five if the numbers are interesting.
6. **Verify.** `make microbench` must still exit 0 with all six PASS lines.
   No CI change is needed -- `.github/workflows/microbench.yml`'s path
   filters already cover any new file under `test/microbench/` or a
   `test/tools/test_microbench_*` name.

---

## Honesty notes

- The 68K loop **executes from cart ROM at `$802000`**, so the measurement
  includes 68K instruction-fetch cost through the cart window — it is not pure
  register-op throughput. Relevant when comparing numbers across the five ROMs,
  since the GPU/DSP benches will run from local RISC RAM instead.
- Interrupts are masked (`move.w #$2700,sr`) before the loop. The HLE BIOS
  leaves video/timer IRQs live with RTE stubs installed; letting them fire
  would put BIOS-path 68K cycles inside the measured window and make the loop's
  cost depend on video timing.
- TOM still renders a (blank) display throughout. Video cost is not isolated
  away and cannot be, short of blanking the screen.
