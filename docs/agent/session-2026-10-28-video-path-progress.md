# Jaguar RISC pipeline — session progress log

**Date:** 2026-10-28
**Branch:** `test/risc-pipeline-microbenches`
**Repo:** `/home/deck/opencode-saved/vjcore` (libretro/virtualjaguar-libretro fork)

---

## 0. Where the session started

The session resumed from a checkpoint: the GPU RISC instruction-interleaving
model was already validated and committed (`b6d371c`, `85a032f`). The
pending items were:

1. Open a PR / connect the GitHub account so commits could be pushed.
2. Implement **(A)** a ChibiAkumas-style hex register dump.
3. Implement **(B)** a watchable particle-explosion demo ROM.

The user asked for A and B; the recommended order was **A first, then B**
(the user chose this).

---

## 1. GitHub work — SUCCEEDED

| step | result |
|---|---|
| `gh auth status` | account `SolarJTR5`, token valid (scopes: gist, read:org, repo, workflow) |
| `gh api repos/libretro/... --jq .permissions` | `push: false` → **must fork** |
| fork | `SolarJTR5/virtualjaguar-libretro` already existed; used it as remote `fork` |
| rebase onto `develop` | 1 conflict in `Makefile` (both sides added test targets) → resolved as a **union** (kept `test_gpu_interleave` on both sides) |
| push | `git push -u fork test/risc-pipeline-microbenches` → OK |
| PR | **not opened** — repo CI wants a linked issue or the `no-issue` label |

Commits on the branch (after the rebase, hashes changed):

- `dd96a5b` feat(tom,jerry): model RISC instruction interleaving with stall counters
- `d41c245` test(microbench): add interleave, DSP mix and particle A/B ROMs
- `d0a2a98` test(tools): dump GPU/DSP registers in a hex grid   ← **new this session**

---

## 2. Feature (A) — RISC register dump — SUCCEEDED

**File:** `test/tools/risc_regdump.sh` (new, committed as `d0a2a98`)

Runs an existing microbench harness under host gdb, stops at
`harness_shutdown`, and reads the `TEST_EXPORTS=1` getters
(`GPUGetReg/GPUGetPC/GPUGetFlags/GPUGetControl`, and the DSP equivalents).
No core change, no extra build.

Usage:

```bash
test/tools/risc_regdump.sh                  # GPU, particle ROM
test/tools/risc_regdump.sh --map particle   # + register roles
test/tools/risc_regdump.sh --dsp            # DSP, benchdsp_mix
```

Real output (2-deep particle ROM, GPU halted):

```
GPU  PC=$F032B4  FLAGS=$00000000  CTRL=$00002000
r0 =$00000000  r1 =$000005FE  r2 =$00000000  r3 =$00000000
r4 =$00000000  r5 =$00000001  r6 =$00000002  r7 =$00000003
r8 =$000005FC  r9 =$000005FE  r10=$00000000  r11=$00000000
r12=$00000000  r13=$00F02114  r14=$00021010  r15=$00030FF0
r16=$00000000  r17=$00000100  r18=$00010000  r19=$00000000
r20=$00000000  r21=$00000000  r22=$00000000  r23=$00000000
r24=$00000000  r25=$00000000  r26=$00000000  r27=$00000000
r28=$0000002A  r29=$0000FB58  r30=$0000FBAC  r31=$000000FF
```

Documented in `test/microbench/README.md` (section "Reading the RISC
register file (host-only)").

**Gotcha fixed while writing it:** `set -o pipefail` + `grep -q` → SIGPIPE
(141) made an `if ! nm | grep -q` test always fail. Fixed by using a `case`
match on the captured output instead of a pipeline.

---

## 3. Feature (B) — particle demo — IN PROGRESS

### 3.1 Files created (all uncommitted at this point)

| file | purpose |
|---|---|
| `test/microbench/benchdemo_vidprobe.s` / `.j64` | **working** minimal video-path probe: full-screen gradient through the OP |
| `test/microbench/benchdemo_particles.s` / `.j64` | the particle-explosion demo (not yet running) |
| `test/microbench/benchdemo_formtest.s` | assembler-form probe ROM (which 68000 forms assemble correctly) |
| `test/microbench/benchdemo_stacktest.s` / `.j64` | stack/jsr-rts probe ROM |
| `test/tools/test_demo_particles.c` | harness driver: runs a ROM, dumps frames as PNG, asserts the sim moved |
| `test/tools/probe_op_bitmap.c` | diagnostic: decodes/dumps the OP bitmap object + line buffer |

### 3.2 The video path — SOLVED (this is the big win)

`benchdemo_vidprobe.j64` renders a full-screen red/green gradient through the
Jaguar Object Processor and **the host framebuffer shows it** (verified by
dumping a PNG: `00 00 80 01 00 00 80 01 ...` → the gradient).

Five separate root causes had to be fixed to get there:

1. **The core never programs the display geometry.** `tomWidth`/`tomHeight`
   are only recomputed when a TOM register in `$28..$4F` is *written*
   (`tom.c`: "detect screen resolution changes"). A ROM that never writes
   VMODE leaves `tomWidth = 0`, and the scanline renderers then draw
   **zero pixels per row** → a completely black screen even though the OP
   filled the line buffer correctly.
   → **Fix:** the ROM writes `VMODE=$06C1`, `VDB=38`, `VDE=518`.

2. **OP object-list encoding (p0/p1).** Encoded from `src/tom/op.c`:
   - `p0 = type | ypos<<3 | height<<14 | link<<21 | data<<40`
   - `p1 = xpos | depth<<12 | pitch<<15 | dwidth<<18 | iwidth<<28`
   - `pitch` = bytes per phrase (field value **1** → 8 bytes);
     `dwidth` = bytes per source line (field = bytes>>3 → **80** for 640);
     `iwidth` = phrases across (**80** → 320 px, and it **spills into the
     high longword**).
   - The **LINK** field bit lands in the *high* longword bit 6
     (`$00000040`); getting it wrong (bit 5) encodes link `$010010` — the
     sentinel block — and the OP follows the link into the wrong place.

3. **The OP consumes the object once per field.** It decrements HEIGHT and
   advances DATA on every line it renders, so the object must be re-armed
   **once per field** (a field = VP+1 = 524 halflines; the OP renders the
   240 even halflines of the visible window).

4. **Re-arm must not be torn.** The re-arm is two longword stores. If the
   OP reads the object between them it sees a fresh DATA with an
   **exhausted HEIGHT of 0**, skips the object, and the line comes out
   background black. → Re-arm in the blanking **before** the OP's first
   pass of the field (VC below VDB), where the OP cannot be mid-object.
   (Waiting for "VC past the visible window" is a *level* test — true for
   ~5 halflines — and the 68K re-armed ~200 times per field.)

5. **16-bit pixels need WORD stores.** A longword store pads each pixel to
   four bytes and the OP reads the padding as pixels.

Extra facts learned:

- The OP runs the OP only on **even** halflines; the visible window is
  VDB=38..VDE=518 → 240 OP passes per field.
- `VC` ($F00006) is updated by the core every halfline → it is a usable
  field sync, but **bit 11 ($0800) marks the lower field** and stays set for
  that whole field, so the comparison must mask it off.
- 16-bit pixel format: RGB555 (R=bits15..11, G=10..5, B=4..0) with bit 15
  set for direct RGB and **bit 0 = 1** to select the RGB (not CRY) path in
  the core's `MIX16ToRGB32` table.
- `TOMGetBottomVisible()` returns the fallback (511) when VDE==518 && VDB==38,
  so the OP effectively renders 237 of the 240 lines.

### 3.3 The toolchain problems (rmac/rln) — FOUND, NOT YET WORKED AROUND

These are the blockers for the particle demo. **All are upstream rmac
behaviour, reproduced with a fresh clone at the pinned SHA `50e66ea`**
(`tools/jaguar-toolchain/PIN`), so they are not a local build accident.
The vendored tree is gitignored; the pinned SHA is what `setup.sh fetch`
checks out, so **anyone rebuilding the ROMs today hits the same bugs**.

| # | symptom | root cause | status |
|---|---|---|---|
| T1 | `cmp.w #imm,dN` assembles as `B0 7C …` (a *branch*) | the 68000 encodes compare-immediate as the **separate CMPI instruction**; rmac models `cmp` and `cmpi` as distinct mnemonics, and `cmp #imm,Dn` silently becomes a CMP with an (invalid) immediate EA | **workaround: use `cmpi.w`/`cmpi.l`** ✓ applied |
| T2 | **forward** branches are left unresolved (`6Cxx`, `60xx`) and rln cannot patch an 8-bit displacement → garbage displacements | rmac resolves only **backward** branch references; forward ones are deferred to the linker, which only does word/long relocations | **NOT yet worked around** |
| T3 | `lea disp(An),Am` mis-assembles as `LEA xxx.L,Am` with a **garbage absolute address** (it swallows the following bytes) | rmac's displacement form is broken | **workaround: no displacement addressing at all** — use pointer registers + `add.l #n,An` ✓ applied |
| T4 | a **store with a displacement** (`2(a1)`) is assembled PC-relative | same area of rmac | **workaround: `lea`/pointer + plain `(An)`** ✓ applied |
| T5 | `move.l Dn,<absolute>` is assembled **backwards** (`move.l #imm,Dn`) | rmac 68000 `move` forms | **workaround: `move.l #ADDR,aN` + `move.l Dn,(aN)`** ✓ applied |
| T6 | only `d0-d7`/`a0-a7` exist; `moveq` is Dn-only; shift immediates are 1..8; `addq` immediate is 1..8; `mulu` has no register-register form | rmac/68000 limits | **worked around** ✓ |

T2 is the current blocker: the demo's `fb_addr` uses forward short
branches to `.fx`/`.fxok`/`.fy`/`.fyok`, and `erase_block`/`draw_block`
are called with forward `jsr`s.

### 3.4 Core-side findings (worth reporting upstream)

| # | finding | evidence |
|---|---|---|
| C1 | **The cart HLE path never gives the 68000 a stack pointer.** `JaguarReset()` writes the SSP into RAM[0] (`$00400000`) but the CPU's A7 starts at **0**. The CD HLE path *does* call `m68k_set_reg(M68K_REG_SP, 0x00200000)`; the cart path does not. A cart ROM that uses `jsr`/`rts` therefore pushes its return address at `$FFFFFFFC` (discarded) and `rts` returns to garbage. | `benchdemo_stacktest.j64`: A7 at entry = `$00000000`; after the ROM sets A7 itself, `jsr`/`rts` works perfectly |
| C2 | `move.w #$2700,sr` at ROM entry is dangerous: Musashi's `MakeFromSR` swaps the active stack to the **SSP (`regs.isp`)**, which this core never initialises for the cart path | `src/m68000/cpuextra.c:65-77` |
| C3 | The display geometry is only recomputed on a **write** to TOM `$28..$4F` — a ROM that relies on reset defaults gets `tomWidth = 0` and a black screen | `src/tom/tom.c` (TOMWriteWord → "detect screen resolution changes") |

### 3.5 What FAILED during the session (and why)

1. **First ROM build → black screen.** Cause: geometry never programmed
   (C3) + DATA field encoded from the ACID test's `$60000` example instead
   of `$30000` → the OP faithfully read an empty buffer.
2. **Link bit flipped** → the OP followed link `$010010` (the sentinel
   block) instead of `$20010`.
3. **LW/P1 encoding**: iwidth 80 spills into the high longword; pitch is
   3 bits of *bytes per phrase*; dwidth is a separate 10-bit field.
4. **Object consumed once per field** → the screen went black after the
   first frame.
5. **Torn re-arm** → black lines (fresh DATA + exhausted HEIGHT).
6. **Longword pixel stores** → the OP read padding zeros.
7. **`cmp` vs `cmpi`** (T1) → every comparison became a branch; this made
   the wait loops and the bounds checks behave nonsensically. It cost a lot
   of time because it *looked* like a branch-encoding bug.
8. **A7 = 0 at entry** (C1) → `rts` returned into the particle table.
9. **Host-side byte-order confusion** — several "bugs" were my own LE
   pointer reads over BE data. Worth remembering: read bytes, not ints.
10. **`.s` branch with a zero displacement → NOP** (`4E 71`) — rmac
    converts a zero-offset `bra.s` to a NOP on purpose (sect.c FU_BBRA).

### 3.6 What SUCCEEDED

- The whole **video path** (68K → DRAM → OP object list → line buffer →
  host framebuffer) works; the gradient PNG proves it.
- `test_demo_particles` writes real PNGs (self-contained writer, no zlib) and
  counts lit pixels.
- The **register dump** (feature A) works and is committed.
- The **seed loop** of the particle demo is verified correct:
  particle 0 = x=`$000000A0`, y=`$00000078`, vx=3, vy=5; the diagnostics
  at `$010014`/`$010018` match.
- The **particle loop** runs: after the stack fix, particle 0 ends at
  x=`$0000013F`, y=`$000000EF` (bouncing in the corner) — i.e. the
  simulation itself is correct.
- The field sync works: the ROM records VC=`$0008` when it leaves the wait.

---

## 4. Where we are RIGHT NOW

- Branch: `test/risc-pipeline-microbenches` — committed `d0a2a98` (feature A)
  pushed to the fork; **feature B is uncommitted** (the four new ROM
  sources + the two tools).
- `benchdemo_vidprobe.j64` **works** and shows the gradient.
- `benchdemo_particles.j64` builds, seeds correctly and simulates, but the
  **screen is still black** because of T2 (unresolved forward branches) —
  `fb_addr`'s `.fx`/`.fxok`/`.fy`/`.fyok` branches and the forward `jsr`s.
  The 68K ends up executing the particle table because the corrupted
  branch targets point into RAM.
- The particle demo also still needs: the framebuffer clear to actually
  clear the whole 153 KB (the loop only clears 1200 longwords = 19 KB),
  and the `move.l a5,MB_SENT_PART` form replaced with the
  `move.l #ADDR,aN` + `move.l Dn,(aN)` idiom.

---

## 5. Plan — how to finish (and how to recalibrate)

### 5.1 Fix T2 (forward branches) — the blocker

Three options, in order of preference:

1. **Restructure the source so every branch target is defined earlier.**
   This is the toolchain's contract and needs no toolchain change:
   - In `fb_addr`, replace the `.fx`/`.fxok`/`.fy`/`.fyok` short branches
     with **arithmetic** (no branches at all):
     `cmpi.l #0,d0; moveq #0,d0` → use `move.l d0,d2; cmpi.l #0,d2;
     bge.s <earlier label>` … better: compute the clipped value with
     `neg`/`sub`/`add` + `cmpi` **backward** branches only, or move the
     clamping into a **backward-branch helper loop**.
   - Move the three subroutines (`erase_block`, `draw_block`, `fb_addr`)
     **above** their callers so every `jsr` target is already defined.
   - Put the `waitin`/`waitout` loops so their labels precede the branches
     (they already do — those branches are backward and work).
2. **Patch rmac** (one-line change to the short-branch fixup) and make it
   reproducible by adding a patch step to `tools/jaguar-toolchain/setup.sh`
   (that file *is* committed). This is the better long-term fix but needs
   upstream-style care.
3. **Post-process the .o/.j64** — too fragile, not recommended.

**Recalibration plan for T2:** before touching the demo again, build a
2-minute probe ROM that does exactly one *forward* branch and one
*backward* branch, dump the linked bytes, and confirm the rule. That
converts the assumption into a measurement. (The `benchdemo_formtest.s`
ROM already exists for this purpose — extend it with forward/backward
branch cases and assert the encodings.)

### 5.2 Then finish the demo

1. Rework `fb_addr` to avoid forward branches (clamping with backward
   branches only).
2. Move the subroutines above their callers (forward `jsr` → backward).
3. Fix the framebuffer clear (clear all 76800 words, or clear once at
   startup and rely on erase+draw afterwards).
4. Replace the remaining `move.l Dn,<absolute>` idiom.
5. Rebuild, run `test_demo_particles`, and check:
   - `lit_pixels > 0` on most frames,
   - the particle table changes between frames and stays on screen,
   - the PNG frames show a coloured burst.
6. Add the demo to `build.sh` (the ROMs are committed, like the others) and
   to `MICROBENCH_ROMS`/`MICROBENCH_TOOLS` only if it is meant to run in
   `make microbench` (it is a *demo*, not a benchmark — probably a
   separate `make demo` target plus a `test/tools/test_demo_particles`
   build rule).

### 5.3 Documentation to write (all in-repo, so the next session benefits)

- `test/microbench/README.md`:
  - the **video-path recipe** (the five fixes above) — the most valuable
    artefact of this session;
  - the **rmac/rln constraint table** (T1..T6) under "Assembling: what
    actually worked";
  - the **cart-ROM stack requirement** (C1).
- `docs/` (or the `projects-sdraylib/audio/docs/jaguar_risc_interleave.md`
  notes repo): a short "video path" section with the PNG evidence.
- Optional: a `docs/rmac-68000-pitfalls.md` capturing T1..T6, since it
  will bite anyone writing 68000 code for this repo.

### 5.4 Git

- Commit feature B as `test(microbench): add the particle-explosion demo ROM`
  (+ the two tools and the README section), push to the fork.
- Only then open the PR (`gh pr create --repo libretro/virtualjaguar-libretro
  --base develop --head SolarJTR5:test/risc-pipeline-microbenches`),
  with the `no-issue` label if no issue number is available.

---

## 6. Quick reference — the useful discoveries

```
OP object (16bpp, full screen):
  p0 = 0x03000040_023C0000     # type0, ypos0, height240, link $20010, data $30000
  p1 = 0x00000005_0140C000     # xpos0, depth4, pitch1, dwidth 640, iwidth 80
  STOP = 0x00000000_00000004
OPL = $00020000, FB = $00030000 (320x240x2)

Tom registers: VMODE $F00028, VDB $F00046, VDE $F00048, OLP $F00020/22,
               VC $F00006, LBUF $F01800
Field sync: poll VC, mask $07FF, wait VC < VDB (re-arm) and VC > VDE (done)
16-bit pixel: $8001 | (r<<11) | (g<<5) | (b)   (bit15 = RGB, bit0 = RGB select)
Cart ROM: A7 starts at 0 -> set it yourself before any jsr/rts
rmac: use cmpi not cmp for immediates; no displacement addressing;
      only BACKWARD branches resolve
```

## 7. Files to touch next

- `test/microbench/benchdemo_particles.s` — rework branches + clear loop
- `test/microbench/benchdemo_formtest.s` — extend with the branch matrix
- `test/tools/test_demo_particles.c` — fix the expected DONE magic
  (`MB_MAGIC_68K` = `$C0DE0068`, not `$C0DE0DE0`) and the particle
  assertions (the probe ROM has no particles)
- `test/microbench/README.md` — document the video path + the rmac table
- `test/microbench/build.sh` — add the new ROMs so they rebuild
