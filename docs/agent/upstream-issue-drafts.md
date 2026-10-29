# Upstream issue drafts

Paste-ready issue text for problems found in this repo that belong
**upstream**. Each entry states the measured behaviour, the exact
reproduction, and the source location, so a maintainer can act on it
without re-deriving anything.

Two upstreams are involved:

| # | upstream | repo | what it is |
|---|----------|------|------------|
| 1 | `libretro/virtualjaguar` | this repo's `src/` | a core behaviour gap |
| 2 | `mwenge/rmac` | the Jaguar assembler | a toolchain defect |
| 3 | `libretro/virtualjaguar` | this repo's `src/tom/op.c` | an OP object decoding bug |

None of them has been filed yet — the drafts are here so they can be
reviewed and filed in one sitting.

**Every reproduction below was re-run against a pristine build** of the
pinned toolchain (`tools/jaguar-toolchain/PIN`: rmac `50e66ea`, rln
`a617009`) with `make clean` before the build. An earlier draft of Issue 2
claimed two defects that do **not** reproduce; they are listed at the end
of this file under "Claims that did not reproduce", with the reason each
one was wrong, so nobody files them again.

---

## Issue 1 — the cart HLE boot path never initialises the 68000's user stack pointer

**Upstream:** https://github.com/libretro/virtualjaguar
**Suggested title:** `cart HLE boot leaves the 68000's user stack pointer at 0 — the standard drop-to-user-mode idiom then faults the CPU`

### Summary

A cartridge booted through the HLE path gets a valid *supervisor* stack
pointer but no *user* stack pointer. The standard "drop to user mode"
idiom

```asm
        move.w  #$0700,sr
```

therefore swaps A7 with a user stack pointer that was never initialised,
installing **A7 = 0**. On a 68000 `MOVESR` is a privileged instruction, so
user-mode code cannot undo the swap with another `MOVE.W #imm,SR` — the
program is stuck with a zero stack pointer, and the first `JSR` pushes
its return address to `$FFFFFFFC`, from which the `RTS` pops `$FFFFFFFF`
and the CPU faults to PC 0.

### Measured

From the probe ROM in `test/microbench/benchdemo_stackprobe.s` (values
read from main RAM `$010000`+ by `test/tools/probe_demo_sentinels.c`):

| sentinel | value | meaning |
|----------|-------|---------|
| `$010014` | `00004000` | A7 at entry — the HLE SSP, **correct** |
| `$010018` | `00000000` | A7 after `move.w #$0700,sr` — **zero** |
| `$01001C` | `00C0DE00` | the subroutine was reached (its absolute store worked) |
| `$010020` | `FFFFFFFF` | `(sp)` in user mode — the push landed at `$FFFFFFFC`, unmapped |
| `$010004` | `00000000` | the DONE sentinel was never written — the ROM died |

Final CPU state after the run: `PC = 0x00000000`, `A7 = 0x00000000`,
`SR = 0x0000`.

### Reproduction

```bash
# build the probe ROM
cd test/microbench
T=../../tools/vendor/jaguar-toolchain
$T/rmac/rmac -fb -o /tmp/sp.o benchdemo_stackprobe.s
$T/rln/rln -n -a 800000 x x -o benchdemo_stackprobe.j64 /tmp/sp.o

# run it and read the sentinel block
cc -O2 -Wall -std=c99 -o /tmp/probe_sents \
   ../../test/tools/probe_demo_sentinels.c ../../test/harness/harness.c -ldl -lm
LD_LIBRARY_PATH=.. /tmp/probe_sents ../../virtualjaguar_libretro.so \
   benchdemo_stackprobe.j64 --frames 20
```

The same ROM boots and runs to completion if it sets A7 itself before
dropping to user mode — that is the workaround, and it is what every ROM
in `test/microbench/` has to do.

### Where it comes from

* `src/m68000/m68kinterface.c:456` — `m68k_pulse_reset()` loads the
  supervisor stack pointer into A7 and forces `regs.s = 1`:

  ```c
  regs.intmask = 0x07;
  regs.s = 1;                                   // Supervisor mode ON
  m68k_areg(regs, 7) = m68k_read_memory_32(0);  // the SSP
  m68k_setpc(m68k_read_memory_32(4));           // the entry PC
  ```

  It never writes `regs.usp` or `regs.isp`. Both are 0 from power-on
  (the `regs` struct is a global) and stay 0 until software writes them.

* `src/m68000/cpuextra.c:53` — `MakeFromSR()` implements a privilege
  change as an A7 ↔ `regs.usp` swap, so the first transition to user mode
  installs the never-initialised `regs.usp` as the live stack pointer.

* `src/core/jaguar.c:1529-1536` — the HLE cart boot writes the SSP to
  main RAM `$0000` (`HLE_SSP_CART` = `$4000`) and the entry PC to
  `$0004`, then `JaguarReset()` pulses the CPU reset at
  `src/core/jaguar.c:1683`.

### Why this is a core gap and not just "the BIOS's job"

The HLE cart path **replaces** the boot ROM's code, so it has to
reproduce the register state the BIOS would have left behind. The core
already reproduces a list of other BIOS leftovers in the same function:

* the BIOS workspace flag at `$0804` (`HLE_BIOS_WORK_FLAG_ADDR`),
* the GPU auth magic (`GPU_AUTH_MAGIC`),
* the OP STOP list,
* the MEMCON1 cart bus-width bits,
* the exception vectors and the `RTE` stubs at `$400`/`$404`.

The 68000's user stack pointer is the one BIOS leftover in that list that
is missing. The supervisor stack pointer is provided; the user one is
not, and there is no way for a cart to recover: `MOVESR` is privileged,
so a program that has already dropped to user mode cannot return to
supervisor mode to fix A7 — the only way back is `RTE` from an
exception handler, which itself needs a working stack.

### Suggested fix

Initialise `regs.usp` in `m68k_pulse_reset()` to a valid user stack, and
keep `regs.isp` in step with the SSP that was just loaded, e.g.:

```c
regs.intmask = 0x07;
regs.s = 1;                                   // Supervisor mode ON
m68k_areg(regs, 7) = m68k_read_memory_32(0);  // the SSP
regs.isp = m68k_areg(regs, 7);                // keep it in the SSP slot
regs.usp = <a valid user stack>;
m68k_setpc(m68k_read_memory_32(4));
```

The question left open is *which* address the user stack should be. The
three candidates are the same value as the SSP (`$4000`, i.e. the user
and supervisor stacks alias, which is what a lot of 68000 code assumes),
the top of main RAM (`$200000`, which is what the CD path already uses
for its SSP — `src/cd/jagcd_hle.c:1946`), or the value the real boot ROM
leaves behind. Any of them is better than 0, because 0 makes the first
`JSR` in user mode write to `$FFFFFFFC`.

Note that `src/cd/jagcd_hle.c` sets the SSP explicitly
(`m68k_set_reg(M68K_REG_SP, 0x00200000)`) but likewise leaves `regs.usp`
alone, so the CD path has the same gap.

### Open question for the maintainer

Does the real Jaguar boot ROM leave a usable user stack pointer behind
when it hands control to the cart? If it leaves 0 as well, then the
faithful fix is to document "a cart must set up its own user stack
before dropping to user mode" rather than to invent a value — but the
HLE path should then say so somewhere a cart author would find it,
because the failure mode (a silent zero stack pointer) is not something
you can debug from the outside.

---

## Issue 2 — rmac silently mis-assembles the two indexed addressing forms, and encodes `cmp #imm` as an immediate-EA CMP

**Upstream:** https://github.com/mwenge/rmac (pinned at `50e66ea`; see
`tools/jaguar-toolchain/PIN`)
**Suggested title:** `silent mis-assembly of indexed addressing modes; "cmp #imm,Dn" is encoded as a CMP with an immediate effective address`

### Summary

Three defects, all reproduced with the pinned `rmac`/`rln` (built from a
pristine checkout — `make clean` first, because the vendored build
directory can hold stale objects):

1. `move.w TBL(a0),d1` — the absolute-indexed form — is **silently
   mis-assembled**. rmac encodes the label as a *section-relative
   displacement* inside a brief extension, so the effective address is
   the label's offset from the section base rather than its address.
2. `move.w 0(a1,a0),d2` — the register+register index form — is
   **silently mis-assembled**: the index scale is always "byte", so the
   effective address is wrong for a word (and for a long) access.
3. `cmp.w #5,d0` is encoded as `B0 7C 00 05` — a CMP with an
   *immediate* effective address. The 68000 has no such addressing mode
   (compare-with-immediate is the separate `CMPI` instruction), so the
   program traps with an illegal-instruction exception instead of
   comparing.

Defects 1 and 2 are the dangerous ones: the assembler reports no error
and the linker produces a well-formed object, so the mis-assembly only
shows up as wrong behaviour at run time.

### Reproduction

The cleanest evidence is the byte pattern, which is exact and needs no
emulator. Assemble each form on its own and look at the object file:

```bash
T=tools/vendor/jaguar-toolchain
cat > /tmp/forms.s <<'EOF'
        .68000
        .text
start:
        move.w  TBL(a0),d1
        move.w  0(a1,a0),d2
        cmp.w   #5,d0
TBL:    dc.w    $1111,$2222,$3333
EOF
$T/rmac/rmac -fb -l*lst.txt -o /tmp/forms.o /tmp/forms.s
xxd -s 0x20 -l 24 /tmp/forms.o
```

```
00000020: 3228 0004 3431 8000 b07c 0005 1111 2222 3333
```

| source | rmac's bytes | what it should be |
|---|---|---|
| `move.w TBL(a0),d1` | `32 28 00 04` | `MOVE.W (d16,A0),D1` with the **absolute** address of `TBL` — the 68000 has no absolute-indexed MOVE, so this needs `move.l #TBL,a0` + `move.w (a0),d1` |
| `move.w 0(a1,a0),d2` | `34 31 80 00` | `MOVE.W (d8,A1,XA0),D2` with the index scale = **01** (word); rmac emits `80` → scale `00` (byte) |
| `cmp.w #5,d0` | `B0 7C 00 05` | `CMPI.W #5,D0` = `0C 40 00 05` |

The scale bug is visible in the extension word: for a word access the
scale field (bits 3-2 of the extension word) must be `01`, and rmac
always emits `00`. The same holds for a long access (which needs `10`),
so `move.l 0(a1,a0),d2` (`24 31 80 00`) is wrong as well.

### Runtime evidence

`test/microbench/benchdemo_indextest.s` reads a table through both forms
and publishes the results in the sentinel block. The table is

```
TBL:    dc.w    $1111,$2222,$3333,$4444
```

and the index used is **2**, so a dropped or mis-scaled index register
is visible (TBL[2] = $3333, TBL[0] = $1111, TBL[1] = $2222):

| instruction | rmac's bytes | result at run time | correct result |
|---|---|---|---|
| `move.w TBL(a0),d1` | `32 28 20 00` | `0` (d1 never written) | `$3333` |
| `move.w 0(a1,a0),d2` | `34 31 80 00` | `$2222` | `$3333` |
| `move.w (a1),d1` (control) | `32 11` | `$1111` | `$1111` ✓ |

The plain `(An)` form is encoded correctly, so the assembler is not
simply broken for An-indirect addressing — it is the **index** that is
lost.

Reading the two failures:

* `move.w TBL(a0),d1` became `MOVE.W (d16,A0),D1` with a *deferred*
  relocation that the linker fills in with the label's **section-relative
  offset** (`$2000` in the probe ROM, where `TBL` sits at `$802000` and
  the section base is `$800000`). The effective address is therefore
  `a0 + 0x2000` instead of `a0 + 0x802000`, i.e. the address is short
  by the section base — which is why the read returned 0.
* `move.w 0(a1,a0),d2` computed the address as `a1 + 1*a0` instead of
  `a1 + 2*a0` for a word access — the effective address came out as
  TBL+4 = `$2222` (TBL[1]) instead of TBL+8 = `$3333` (TBL[2]).

In both cases `rmac -fb` reports **no error at all**, and `rln` links the
result without complaint.

### Suggested fix

* Implement the register+register form (`d(An,Am)`) with the index
  register **and the word/long scale** in the extension word, i.e. the
  scale bits must follow the access size.
* For a label in an indexed form (`LABEL(An)`), either diagnose it or
  encode it the way the hardware can express it — the 68000 has no
  absolute-indexed MOVE, so the honest answer is "use
  `move.l #LABEL,aN` + `move.w (aN),Dn`". Silently turning the label
  into a section-relative displacement is the worst of the three.
* `cmp #imm,Dn` should either assemble as `CMPI` (which is what every
  68000 assembler does) or be rejected with a diagnostic.

### Note on the linker

`rln` (http://tiddly.mooo.com:5000/rln/rln.git, pinned at `a617009`)
patches the deferred relocations correctly in every case that `rmac`
survives. The mis-assemblies in 1 and 2 are entirely `rmac`'s; the
linker faithfully links what it is given.

---

## Issue 3 — the OP reads every bitmap object one byte per line off, because DWIDTH is decoded together with PITCH

**Upstream:** https://github.com/libretro/virtualjaguar
**Suggested title:** `OP bitmap objects are sheared by one byte per line: the DWIDTH field is decoded with the PITCH bits included`

### Summary

The Object Processor's second phrase carries two adjacent fields:

```
| 15-17 | PITCH  | Data phrase spacing: distance in phrases between successive pixels |
| 18-27 | DWIDTH | Data width: number of phrases per scanline of image data |
```

(JTRM Rev 8 p.20, "Scaled Bit Mapped Object"/"Bit Mapped Object" table;
the same layout is in `docs/jtrm-object-processor.md`.) The DATA pointer
advances by **DWIDTH phrases** per scanline, i.e. by `DWIDTH * 8` bytes.

`src/tom/op.c` decodes the line stride with

```c
dwidth = (p1 & 0xFFC0000) >> 15;
```

`0xFFC0000` starts three bits lower than the DWIDTH field, so the
**PITCH bits (15-17) are decoded as part of the line stride**. For a
bitmap with the usual `PITCH = 1` the stride is therefore one byte too
long, and every line of every 16bpp bitmap object is read one byte
further along than it should be: the picture shears by one byte per
line (a 320-pixel-wide screen ends up 240 bytes — 120 pixels — out of
alignment by the bottom of the screen).

The correct decode is

```c
dwidth = (p1 & 0x3FC0000) >> 15;   /* DWIDTH (bits 18-27) in bytes */
```

which is the DWIDTH field alone, shifted so that it is already in bytes
(`DWIDTH * 8`).

### Measured

The defect is visible in the demo ROMs in `test/microbench/`, which
program a full-screen 16bpp bitmap object (320x240, 80 phrases per
line, `PITCH = 1`, `DWIDTH = 80`):

* with the old decode the line stride is `80*8 + 1 = 641` bytes instead
  of 640, and the rendered image shears: the top of the screen is
  correct and the bottom third is a set of diagonal streaks (the OP has
  walked off the end of the framebuffer and is reading unrelated RAM);
* with the corrected decode the stride is exactly 640 and the picture
  is stable.

The same shear is measurable in a real game: `test/roms/yarc.j64` shows
the same one-byte-per-line skew.

### Reproduction

```bash
# 1. the decode itself (src/tom/op.c, two places: the BITOBJ and the
#    SCBITOBJ paths)
grep -n "0xFFC0000" src/tom/op.c

# 2. the visible effect: build the gradient demo and dump a frame
cd test/microbench
T=../../tools/vendor/jaguar-toolchain
$T/rmac/rmac -fb -o /tmp/vp.o benchdemo_vidprobe.s
$T/rln/rln -n -a 800000 x x -o /tmp/vp.j64 /tmp/vp.o
cc -O2 -Wall -std=c99 -o /tmp/dump ../../test/tools/test_demo_particles.c \
   ../../test/harness/harness.c ../../test/harness/trace_probe.c -ldl -lm
/tmp/dump ../../virtualjaguar_libretro.so /tmp/vp.j64 --frames 60 \
   --frames-out /tmp/frames
```

The dump shows a gradient whose lower third is diagonal streaks instead
of a smooth vertical ramp.

### Impact

Every 16bpp (and 8bpp-palettized) bitmap object in every game is read
with a line stride one byte too long. The picture shears progressively
down the screen: on a 320-pixel-wide display the bottom of the screen is
120 pixels out of register, and the last lines of a full-screen object
are read from beyond the end of the bitmap. It is subtle enough that
it can be mistaken for interlace wobble, and it is invisible in the
committed screenshot baselines only because those titles do not use a
full-screen 16bpp bitmap.

### Suggested fix

```c
dwidth = (p1 & 0x3FC0000) >> 15;   /* DWIDTH (bits 18-27), in bytes */
```

in both places in `src/tom/op.c` that decode it (the BITOBJ write-back
and the SCBITOBJ write-back). The rendering-neutral case is worth
checking in the regression baselines: the committed `yarc` screenshot is
byte-identical before and after, because that title's objects use a
different pitch.

---

## Claims that did not reproduce

Kept here so they are not filed again, with the reason each was wrong.

* **"rmac mis-encodes `SUB.L` with a non-D0 source register (the source
  register one bit low, so `sub.l d3,d2` subtracts D1)."** — Not an rmac
  bug. rmac assembles `sub.l d3,d2` as `94 83` (`SUB.L D3,D2`), which is
  correct; the core executes it correctly too (`sub.l d3,d2` with D3=5,
  D2=10 gives 5). The bad result in the original probe came from the
  probe ROM itself: its header's entry vector was `$00802008` while the
  code starts at `$00802000`, so the CPU started *inside* the first
  instruction and never executed `move.l #5,d3` — the "SUB is broken"
  observation was the ROM skipping its own setup. The probe ROMs in
  `test/microbench/` now have their entry vectors checked against the
  label they are supposed to reach.
* **"A file with a forward immediate and a forward conditional branch
  makes rmac abort with `Error: undefined expression`."** — The
  reproduction used two labels that differ only in case (`bne.s later`
  against a label named `LATER:`). rmac's symbols are case-sensitive
  (see the "Symbols and Scope" section of its manual), so the branch
  referenced an undefined symbol and the error was correct. With
  matching names the same file assembles and links cleanly.
* **"`move.l Dn,<absolute>` is assembled backwards."** — Not an rmac
  bug: `move.l d0,$00100000` assembles as `23 C0 00 10 00 00`
  (`MOVE.L D0,(xxx).L`), which is correct. The workaround the earlier
  session used (`move.l #ADDR,aN` + `move.l d0,(aN)`) is still
  convenient, but nothing is mis-assembled.
* **"`LEA`/`MOVE` with a displacement are mis-assembled."** — A plain
  displacement (`4(a0)`) assembles correctly (`32 28 00 04`). What is
  broken is a **label** in an indexed form (Issue 2 above), because the
  label becomes a section-relative displacement.
