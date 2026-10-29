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

Neither has been filed yet — the drafts are here so they can be reviewed
and filed in one sitting.

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

## Issue 2 — rmac silently mis-assembles indexed addressing, and aborts on a forward immediate + a forward conditional branch

**Upstream:** https://github.com/mwenge/rmac (pinned at `50e66ea`; see
`tools/jaguar-toolchain/PIN`)
**Suggested title:** `silent mis-assembly of indexed addressing modes; "undefined expression" when a forward immediate and a forward conditional branch appear in the same file`

### Summary

Three defects, all reproduced with the pinned `rmac`/`rln`:

1. `move.w TBL(a0),d1` — the absolute-indexed form — is **silently
   mis-assembled**. The instruction that comes out loads a long value
   into `A1`; the index register, the operand width and the destination
   register are all changed.
2. `move.w 0(a1,a0),d2` — the register+register index form — is
   **silently mis-assembled**. The index register is kept but not scaled
   for the word access, so the effective address is wrong.
3. A file that contains **both** a forward immediate (`move.l #LATER,a0`)
   **and** a forward conditional branch (`bne.s later`) makes `rmac`
   abort with `Error: undefined expression` and produce **no object
   file**.

Defects 1 and 2 are the dangerous ones: the assembler reports no error
and the linker produces a well-formed object, so the mis-assembly only
shows up as wrong behaviour at run time.

### Reproduction

**1 and 2 — the two indexed forms are mis-assembled.** The clearest
evidence is behavioural rather than bit-pattern archaeology: the probe ROM
`test/microbench/benchdemo_indextest.s` reads a table through both forms
and publishes the results in the sentinel block. The table is

```
TBL:    dc.w    $1111,$2222,$3333,$4444
```

and the index used is **2**, so a dropped or mis-scaled index register is
visible (TBL[2] = $3333, TBL[0] = $1111, TBL[1] = $2222).

| instruction | rmac's bytes | result at run time | correct result |
|---|---|---|---|
| `move.w TBL(a0),d1` | `32 28 20 00` | `0` (d1 never written) | `$3333` |
| `move.w 0(a1,a0),d2` | `34 31 80 00` | `$2222` | `$3333` |
| `move.w (a1),d1` (control) | `32 11` | `$1111` | `$1111` ✓ |

The plain `(An)` form is encoded correctly, so the assembler is not
simply broken for An-indirect addressing — it is the **index** that is
lost.

Reading the two failures:

* `move.w TBL(a0),d1` became an instruction that loads a **long** value
  into **A1** and never touches `d1` — the index register, the operand
  width and the destination register were all changed. The listing shows
  `3228xxxx` with a *deferred* relocation; the linker fills in the base
  address correctly (`3228 2000`), so the mis-assembly is entirely
  `rmac`'s. This happens with the label defined **before** the
  instruction as well as after it, so it is not a forward-reference
  problem.
* `move.w 0(a1,a0),d2` computed the address as `a1 + 2*a0` instead of
  `a1 + 2*a0` scaled for a word access — the effective address came out
  as TBL+4 = `$2222` (TBL[1]) instead of TBL+8 = `$3333` (TBL[2]).

In both cases `rmac -fb` reports **no error at all**, and `rln` links the
result without complaint.

**3 — forward immediate + forward conditional branch.**

```asm
start:
        move.l  #LATER,a0
        moveq   #0,d0
        cmpi.l  #3,d0
        bne.s   later
        bra.s   start
LATER:  dc.l    $12345678
```

```
$ rmac -fb -o fwd.o fwdref.s
fwdref.s 20: Error: undefined expression
$ ls -l fwd.o
ls: cannot access 'fwd.o': No such file or directory
```

The error is reported for line 20, the *forward immediate* — but that
line assembles fine on its own, and so does every other form in the
file. Isolating the two forward references shows which combination
fails:

| file contains | result |
|---|---|
| forward immediate only | assembles and links correctly |
| forward `jsr` only | assembles and links correctly |
| forward conditional branch only | assembles and links correctly |
| forward immediate + forward `jsr` | assembles and links correctly |
| forward `jsr` + forward conditional branch | assembles and links correctly |
| **forward immediate + forward conditional branch** | **`rmac` aborts, no object file** |

In `rmac`'s own listing (`rmac -fb -l`) the three forms look like this:

```
20  00002000  207Cxxxxxxxx    move.l  #LATER,a0
21  00002006  4EB9xxxxxxxx    jsr     sub
25  00002016  66xx            bne.s   later
32  0000201C  12345678        LATER:  dc.l    $12345678
```

The `66xx` is the giveaway: `rmac` could not even size the branch
displacement, so the conditional branch is emitted with **no displacement
byte at all** — everything after it in the section is misaligned by one
byte.

### Why this matters beyond the Jaguar

`rmac` is a general 68000/RISC assembler. A silent mis-assembly of the
two most common indexed addressing forms is a serious defect for any
target: the object file is well-formed, the linker is happy, and the
program misbehaves at run time with no diagnostic anywhere.

### Suggested fix

* Implement the absolute-indexed form (`LABEL(An)`) as the 68000's
  brief-extension MOVE with an absolute-long base and the index register
  in the extension word, and implement the register+register form
  (`d(An,Am)`) with the index register and the word scale in the
  extension word. (The correct 68000 encodings are left to the
  maintainer here; the point of the report is the observable behaviour
  above, not the byte patterns.)
* At minimum, **diagnose** both forms instead of silently changing the
  instruction.
* For the forward-reference combination: either resolve forward
  references in a second pass (the assembler already defers them to the
  linker, so the two-pass machinery may already exist) or report which
  construct is unresolvable — the current `undefined expression` message
  points at a line that is not the problem.
* If a conditional branch's displacement cannot be sized at the point of
  assembly, emit a *long* branch (16-bit displacement) rather than an
  opcode with no displacement byte.

### Note on the linker

`rln` (http://tiddly.mooo.com:5000/rln/rln.git, pinned at `a617009`)
patches the deferred relocations correctly in every case that `rmac`
survives — the forward `jsr` and the forward immediate both link to the
right address when they are not in the failing combination above. The
mis-assemblies in 1 and 2 are entirely `rmac`'s; the linker faithfully
links what it is given.
