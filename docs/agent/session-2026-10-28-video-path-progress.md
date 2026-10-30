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


---

## 8. UPDATE (same day, later) — the video path SOLVED

The part above stalled on "the demo is still black".  It is solved now;
here is what the remaining causes were, in the order they bit.

### 8.1 The four fixes that made the gradient appear

| # | symptom | cause | fix |
|---|---|---|---|
| 1 | screen black although the OP filled the line buffer | the core recomputes `tomWidth`/`tomHeight` **only when a TOM register in `$28..$4F` is written** (`tom.c`, "detect screen resolution changes"); a ROM that never writes VMODE leaves `tomWidth = 0` and the scanline renderers draw **zero pixels per row** | write VMODE/VDB/VDE at startup |
| 2 | pixels appear but as the wrong colours | `VMODE` bit 8 (`VARMOD`) selects the **per-pixel RGB555/CRY mix** renderer (mode 4); without it the core uses the CRY renderer (mode 0) where a 16-bit pixel is a cyan/red/yellow colour | `VMODE = $07C1`, and set **bit 0** in every pixel (bit 0 = "RGB, not CRY") |
| 3 | the colours are the right *values* but the wrong *hue* | RGB16 is `R[15:11] B[10:6] G[5:0]` — green is the low **six** bits and blue sits above it (`docs/jtrm-object-processor.md`; the core's `RGB16ToRGB32[]` agrees).  The usual 5-6-5 intuition is wrong here | pack green into bits 5..0, blue into 10..6 |
| 4 | the picture is shifted/swapped | **the OP fetches phrases little-endian; the 68000 is big-endian.**  The LBUF shows the source bytes reversed | store every 16-bit pixel **byte-swapped** |

Two more, found while porting the fixes to the particle demo:

| # | symptom | cause | fix |
|---|---|---|---|
| 5 | the OP draws one line and then nothing | the object is consumed once per **field**, and the re-arm fired on **every poll** inside the blanking window (38 times per field), racing the OP's write-back until the object was exhausted | wait *up* (VC inside the window) then *down* (VC wrapped) and re-arm **once**, in the blanking before the OP's first pass |
| 6 | the burst flies off the screen | `fb_addr` clobbered `d1` — the particle loop's **DBRA counter** — so the loop ran 65536 times | fixed the register discipline: the subroutines may only touch `d0`, `d4`, `d5`; `d1`/`d2`/`d3`/`d6`/`d7` are live in the caller |

### 8.2 The rmac/rln limits (upstream, pinned SHA 50e66ea)

Confirmed against a fresh clone of the pinned upstream, so not local damage:

* **Forward branch references cannot be resolved.**  rmac defers a
  branch to a label defined *later* in the file to the linker; rln can
  only patch a 16-bit displacement, so a short branch that needs patching
  makes rln fail outright.  **Every branch in an rmac-assembled ROM must
  target a label defined EARLIER in the file.**  The five benchmark ROMs
  only ever branch backwards, which is why this never showed up before.
  A conditional without a forward branch is a **backward loop whose body
  comes first**: the body is unconditional, the backward branch repeats it
  while the condition holds, and the fall-through is the "done" case.
* `cmp #imm,Dn` assembles as a **branch** — the 68000's
  compare-with-immediate is the separate `CMPI`, so write `cmpi.w`/`cmpi.l`.
* `move.l Dn,<absolute>` is assembled **backwards**.
* `lea disp(An),Am` swallows the following bytes as an absolute address —
  there is no working displacement form; use pointer registers and
  `add.l #n,An`.
* Only `d0`-`d7`/`a0`-`a7` exist, `MOVEQ` is Dn-only, shift immediates
  are 1..8, `ADDQ` immediates are 1..8, `MULU` has no register-register
  form.

### 8.3 Core-side findings (worth an upstream issue)

* **A cart ROM starts with A7 = 0.**  `JaguarReset()` writes the SSP into
  RAM[0] but never gives the 68000 a stack pointer; the CD HLE path does
  (`m68k_set_reg(M68K_REG_SP, 0x00200000)`), the cart path does not.  A
  cart ROM that uses `jsr`/`rts` must set A7 itself — otherwise the first
  `jsr` pushes its return address at `$FFFFFFFC` (discarded) and the `rts`
  returns to garbage.  The five benchmark ROMs never call a subroutine,
  which is why nobody noticed.
* `move.w #$2700,sr` is dangerous in this core: Musashi's `MakeFromSR`
  swaps the active stack pointer to the SSP (`regs.isp`) on that
  transition, and the SSP is never initialised for the cart path.  Stay
  in supervisor mode (it is what the IRQ path wants) and set A7 explicitly.

### 8.4 What the demo ROMs are

| file | what it is |
|---|---|
| `test/microbench/benchdemo_vidprobe.s` | the smallest ROM that puts a picture on the screen (a full-screen gradient) |
| `test/microbench/benchdemo_particles.s` | 256 particles exploding from the centre, each with its own colour |
| `test/microbench/benchdemo_min.s` | geometry + object + OLP + fill, nothing else |
| `test/microbench/benchdemo_acid.s` | a port of the acid test's 16-bpp BITOBJ scenario (the repo's own `test/acid/tests/op/op_bitmap_render.s`), so the question can be answered without `vasm` |
| `test/microbench/benchdemo_stacktest.s` | probes the A7 finding |
| `test/microbench/benchdemo_formtest.s` | which 68000 instruction forms this assembler gets right |
| `test/microbench/run_demo.sh` | installs the fresh core into RetroArch and launches it with the ROM |
| `test/tools/test_demo_particles.c` | headless driver: lit-pixel count, PNG frame dumps, "the particles moved" assertion |
| `test/tools/probe_op_bitmap.c` | decodes/dumps the OP object list and the line buffer |
| `test/tools/probe_tom_regs.c` | dumps TOM's registers and the CLUT after a run (the "what does a working game program?" tool) |

### 8.5 Calibration that unlocked it

Running a **known-good public ROM** (`test/roms/yarc.j64`) through the
same harness showed 61 022 lit pixels and a correct Atari Karts HC
attract screen.  That proved the core's video path was fine and the
problem was in the ROM — and the probe tools then answered "what does a
working game program?" (mode 0/CRY, VDB 25, VDE 507, a **1 bpp** object:
a palette index, so the endianness of the pixel data does not matter).

### 8.6 Status

Committed as `de1515f` and pushed.  The demo renders; RetroArch shows it
(`test/microbench/run_demo.sh`).  Sample frames are in
`docs/images/`.

---

## 9. UPDATE (2026-10-29) — the demo renders, the audio path works, and the toolchain was lying to us

### 9.1 The toolchain was locally corrupted — and it poisoned every conclusion drawn from it

`tools/vendor/jaguar-toolchain/` is gitignored and shared between
sessions.  Its rmac checkout had an **uncommitted local edit** to
`68k.mch`:

```diff
-and   NBWL   C_DATA          M_DREG          %1100rrr0sseR1S00   m_ea      +
+and   NBWL   C_DATA          M_DREG          %1011rrr0sseR1S00   m_ea      +
```

`$C` (AND) became `$B` (CMP), so **every `and.l Dn,Dm` assembled as
`cmp.l Dn,Dm`** — a silent, well-formed, completely wrong instruction.
The audio demo's square wave was constant because of it, and the
"rmac mis-assembles `SUB.L`" conclusion was an artefact of the same
era's ROM bug (see 9.4).

The edit is reverted (`git -C tools/vendor/jaguar-toolchain/rmac status`
is clean again) and rmac was rebuilt from scratch.  **Check the
vendored toolchain's git status before trusting anything it says** — and
rebuild it with `make clean && make` so no stale object survives.  The
new `test/microbench/benchdemo_alu.s` + `test/tools/test_demo_alu.c`
are the tripwire: 16 register-register ALU forms checked against the
68000's documented answers.

### 9.2 The audio spike works — 68K -> LTXD/RTXD -> I2S -> DAC -> libretro

`test/microbench/benchdemo_audio.s` + `test/tools/test_demo_audio.c`:

```
PASS: [audio_present]        the 68K-written I2S stream reaches the output
PASS: [audio_stereo_match]   left and right carry the same signal
PASS: [audio_tone_frequency] the tone is at the frequency the ROM asked for
PASS: [audio_timer_rate]     the 68000's timer interrupt rate is as programmed
```

The tone is measured **against the ROM's own tick counter**, not against
a hard-coded number: the ROM publishes how many timer interrupts it
took, the test samples that counter in the same window as the audio,
and the expected frequency is (tick rate / 16).  That matters because
JERRY's pending-interrupt latch is cleared by the 68000's own write to
JINTCTRL, so a timer tick that lands between the interrupt acknowledge
and that write is swallowed — the measured tick rate is ~12% below the
nominal 50 kHz, and the test says so rather than hiding it.

The ROM also uses the **documented** JINTCTRL layout now (one 16-bit
write, `$0404` = enable timer 1 + clear its pending latch).  The byte
lanes of JINTCTRL in the core are swapped relative to that layout
(`$F10020` is the enable mask and `$F10021` the clear field per the
JTRM-derived notes in `docs/jtrm-jerry.md`; the core's byte handlers
have them the other way round) — recorded here as an open question, not
filed, because the manual itself is not in this checkout.

### 9.3 The core's OP decodes DWIDTH together with PITCH — every bitmap is sheared by a byte per line

`src/tom/op.c` decoded the OP's line stride as

```c
dwidth = (p1 & 0xFFC0000) >> 15;
```

`0xFFC0000` starts three bits below the DWIDTH field, so the **PITCH
bits (15-17) became part of the stride**: a 16bpp bitmap with
`PITCH = 1` was read one byte further along on every line, and the
picture sheared 120 pixels by the bottom of a 320-pixel screen.  The
fix is `0x3FC0000` (the DWIDTH field alone).

This is what made the demo ROMs look like garbage.  With it fixed, the
gradient demo renders a clean full-screen gradient and the particle demo
renders a moving burst.

### 9.4 The demo ROMs had bugs of their own — the list, so nobody re-derives it

| bug | effect |
|---|---|
| `mulu.w #$imm,Dn` (rmac's immediate-EA form) | "multiplied" the *table pointer* and corrupted the particle table — the burst's velocities were garbage |
| the framebuffer "clear" stored an incrementing counter | the screen was painted with a gradient, not cleared |
| `draw_block` clobbered the DBRA counter (`d1`) | the particle loop stopped after one particle per frame |
| `fb_addr` clobbered `d4` (the x coordinate) before using it | every particle was drawn at x = 7 |
| `DBRA` runs the body N+1 times for a counter of N | `y*4` became `y*8` — the row address was wrong by a factor of two |
| the velocities came from the top two bits of a 32-bit LCG | the LCG's top bits have a period of 4: every particle got nearly the same velocity and the "explosion" was a blob drifting up and left |
| the byte-swap before storing a pixel | the core's OP reads the framebuffer big-endian; the swap threw the green away and dropped the word into CRY mode |
| the DWIDTH field encoded as 64 instead of 80 phrases | the stride was 513 bytes instead of 640 — the picture was a smear |

The demo now uses a **double buffer** (two framebuffers plus a small
"shadow" table per buffer recording the positions that buffer holds),
which is what removes the trails: the back buffer is erased exactly,
because the shadow table says exactly what it contains.

### 9.5 What the demo does now

64 particles, each a 2x2 block, bouncing off the screen edges so the
burst never settles, with the hue rotating every frame.  The particle
count is a **budget**, not a taste: the OP renders a full-screen bitmap
every field and the 68000's framebuffer writes share that DRAM bus, so
64 particles x (2 erase + 2 draw + 1 shadow) = 320 writes is about 6 ms
— comfortably inside one 16.6 ms field.  Draw more and the drawing
overruns the field, the object cannot be re-armed in time, its
remaining height runs out and the screen decays to black.

`test/tools/test_demo_particles.c` reads the particle count from the
ROM's sentinel block (the ROM's business) and checks that every
particle moved, stayed on screen, and that the screen is lit.

### 9.6 The upstream drafts were rewritten

`docs/agent/upstream-issue-drafts.md` now carries three issues, all
reproduced against a **pristine** build of the pinned toolchain:

1. the cart HLE boot never initialises the 68000's user stack pointer;
2. rmac mis-assembles a label in an indexed form, loses the index scale
   of `d(An,Am)`, and encodes `cmp #imm` as an immediate-EA CMP;
3. the OP's DWIDTH/PITCH decode (this session's core bug).

The file also keeps a **"Claims that did not reproduce"** section, with
the reason each was wrong, so the false ones are not filed again.

## 10. UPDATE (2026-10-30) — the trail, the band, and the "colours" were all one bug each

Three complaints about the demo ("comet trails survive", "a band across
the bottom third", "it is all yellow") turned out to be three separate,
small, *tool-side* or *ROM-side* bugs — the core's OP rendering was
correct the whole time.  They are worth writing down because the first
two had been blamed on the core.

### 10.1 The framebuffer clear wrote half a colour

The clear stores LONGWORDS, and a longword is two 16-bit pixels, but the
colour was only in one half:

    move.w  #BG_COLOUR,d0      ; d0 = $0000_0001
    swap    d0                 ; d0 = $0001_0000   <- still only one half

so every other pixel was `$0001` (RGB16 black) and `$0000` (bit 0
clear => the core's MIX16 table decodes it as **CRY**, and CRY 0 is a
faint red, not black).  The result was a screen-wide dither of dark
red/green/blue, plus solid bands wherever the *erase* pass had written
proper `$0001` words over it.  That was the "band across the bottom
third".  The fix is one line: `move.l #$00010001,d0`.

### 10.2 The PNG dumper walked the RGB buffer at 4 bytes per pixel

`png_write()` copied each row out of the frame buffer with

    rgba + i * w * 4

but the buffer it was handed was `w * h * 3` (the callback had already
packed RGB).  Every row therefore started 4/3 of a row further along
than the last, which produced a perfect 3-pixel R/G/B cycle — diagonal
smearing that read as "vertical stripes" and "comet trails" in every
screenshot the demo had ever produced.  The callback also copied bytes
0,1,2 in order, but the core hands back 32-bit **XBGR** little-endian,
so red and blue were swapped on top of that.

Lesson: the frame-dump path is part of the measurement apparatus.  A
renderer bug and a dumper bug look the same in a PNG.  `--ram-out FILE`
now exists on `test_demo_particles` so the framebuffer can be inspected
directly: with a correct ROM the 16-bit words are exactly the
background word plus N distinct particle colours, 4 pixels each, and any
disagreement with the PNG is the dumper's fault.

### 10.3 "All yellow" — the particle colour lookup

The palette was built from an LCG seed, and the visible result was
yellow-ish because green (6 bits) dominated red (5) and blue (5) for the
values the LCG produced.  The lookup itself was also broken twice over:

    lsl.l   #2,d0            ; palette entries are WORDS, not longs
    move.l  #PALETTE,a0
    add.l   a0,d0            ; ...and the sum was left in d0
    move.l  (a0),d6          ; while the load used a0, unindexed

so every particle read the same two words and drew the same colour.  The
palette is now a **64-entry hue wheel** (red -> yellow -> green -> cyan ->
blue -> magenta -> red, RGB555 with bit 0 set so the core decodes it as
RGB16), emitted as `dc.w` data at a fixed cart address and copied to RAM
at startup, and the index is `(particle + frame) & 63`: every particle
is a different hue, and every hue advances 5.6 degrees per field.

The table sits at `$802004`, immediately after a `bra.w start` at the
entry point, because an immediate built from a label expression is
section-relative in this assembler — a *fixed* address is the one thing
that always links correctly.

### 10.4 The demo runner grew an audio mode and a WAV mode

`test/microbench/run_demo.sh` now takes `particles | vidprobe | audio`,
`--wav [FILE]` (headless: run the core, capture the audio callback and
write a 48 kHz stereo WAV — no emulator needed), and `bigpemu` (launch
the ROM in the flathub BigPEmu, as an independent implementation to
compare against).  The WAV writer in `test_demo_audio.c` needed one
non-obvious fix: the WAV `nBlockAlign` field is **two** bytes, and a
four-byte write there shifts every following field, which is what
"no 'data' tag found" from ffmpeg actually meant.

### 10.5 State

`make demos` passes: `particle_demo`, four audio assertions, and the 16
68000 ALU forms.  A rendered frame is a clean black background with 64
two-pixel rainbow blocks (256 lit pixels, 65 distinct framebuffer words
including the background) and no trails, because the shadow table erases
exactly what each buffer holds.
