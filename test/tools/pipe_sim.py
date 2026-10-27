#!/usr/bin/env python3
"""
test/tools/pipe_sim.py -- a re-implementation of the Virtual Jaguar's RISC
pipeline timing model, as a STANDALONE CHECK on the core's own numbers,
plus a full register-level trace.

WHAT THIS IS FOR
----------------
The core models the RISC's pipeline in `src/tom/gpu.c` (GPUPipeCheckUse +
GPUPipeMemAccess) and `src/jerry/dsp.c` (the same, with the DSP's operand
map).  That model answers "how many ticks?" -- it does not answer "why?",
because a stall counter only says *which* opcode paid, not *when* the
data was supposed to arrive.

This tool re-implements the same rules in Python and runs the SAME
assembled payload on them, so that:

  * the per-opcode stall histogram it prints must match the core's own
    `gpu_pipe_*_by_op` / `dsp_pipe_*_by_op` counters exactly -- that is
    the check that the model below is the model the core runs; and
  * once it does, the tool can print the tick-by-tick timeline -- with
    the whole register file, the MAC accumulator and the flags -- which
    is where the "why" comes from.

Verified against the committed microbenchmark ROMs (see
docs/jaguar_risc_interleave.md 12.1d):

  benchgpu_interleave  naive  : score mult=960 imacn=512 | raw mult=64
                               div=64 cmp=64 | port 192 | flags 64
  benchgpu_interleave  2-deep: score imacn=8 | raw mult=126 div=64
                               cmp=63 | port 192 | flags 63
  benchdsp_interleave  2-deep: score imacn=12 | raw mult=126 div=64
                               cmp=63 | port 192 | flags 63
  benchdsp_mix         naive  : score mult=1024 imultn=512 | raw add=512
                               mult=256 cmp=320 move=256 storew=128
  benchdsp_mix         2-deep: score imultn=512 | raw add=512 mult=512
                               cmp=320 move=256 load=64 storew=128

THE REGISTERS
--------------
The Jaguar RISC has **64** registers in two banks of 32; only one bank is
nameable at a time (REGPAGE selects it), so a program sees r0..r31.  The
trace prints that window.  The DSP's MAC accumulator is 40-bit signed
(src/jerry/dsp_acc40.h) and is printed as such.

USAGE
-----
  pipe_sim.py <payload.bin> <gpu|dsp> <program.txt> [--trace N] [--regs]

<payload.bin> is a lyxass blob with the 12-byte BS94 header already
stripped (test/microbench/build.sh does that).  It is a little-endian
byte stream of 16-bit instruction words; the Jaguar is big-endian, so
every word is byte-swapped before it is decoded.

<program.txt> describes which instructions run, in order.  One line per
block; the indentation nests (a `repeat N:` block repeats its body N
times):

  0..8                # the setup
  41..68              # the loop body
  repeat 63:
    41..68

A block may also carry a memory class, because the load's cost depends
on WHERE it reads:

  15..15  ext         # main DRAM: the full access cost
  17..17  local       # the RISC's own local RAM: 3 ticks, no bus cycle
  35..36  io          # the I/O bus (the DAC's transmit registers)

Anything not marked is not a memory access at all.

The `mem` lines give the memory the payload reads (the ROMs build it):

  mem ext 0x020000 vertex 64     # 16 bytes per vertex: x=i, y=i+1, z=i+2
  mem local 0x00F1B400 counter 64 # one longword per entry: 0, 1, 2, ...
  mem ext 0x020000 envelope 4     # one DRAM page per voice: the volume

  --trace N   print the tick-by-tick timeline of iteration N (0 = first)
  --regs     print the whole register file with every instruction
"""

import sys

# ---------------------------------------------------------------- tables
# The GPU's operand map (src/tom/gpu.c: gpu_pipe_flags).  Bit 0: field 1
# names a register this op reads.  Bit 1: field 2 does.  Bit 2: the op
# writes field 2.  Bit 3: the field-2 read is NOT scoreboarded.  Bit 4:
# field 1 is an immediate offset that the scoreboard compares as a
# register anyway (the DSP only).
FLAGS_GPU = [
    7, 7, 6, 6, 7, 7, 6, 6,   # add addc addq addqt sub subc subq subqt
    6, 7, 7, 7, 6, 2, 6, 6,   # neg and or xor not btst bset bclr
    7, 7, 3, 4, 3, 7, 6, 7,   # mult imult imultn resmac imacn div abs sh
    6, 6, 7, 6, 7, 6, 3, 2,   # shlq shrq sha sharq ror rorq cmp cmpq
    6, 6, 5, 4, 1, 4, 4, 5,   # sat8 sat16 move moveq moveta movefa movei loadb
    5, 5, 5, 4, 4, 3, 3, 3,   # loadw load loadp ld_r14 ld_r15 storeb storew store
    3, 2, 2, 4, 1, 0, 6, 5,   # storep st_r14 st_r15 move_pc jump jr mmult mtoi
    5, 0, 5, 5, 3, 3, 6, 6,   # normi nop ld_r14ri ld_r15ri st_r14ri st_r15ri sat24 pack
]
# The DSP's map (src/jerry/dsp.c: dsp_pipe_flags).  The shared opcodes are
# the same; the DSP's indexed load has bit 4 set.
FLAGS_DSP = [
    7, 7, 6, 6, 7, 7, 6, 6,
    6, 7, 7, 7, 6, 2, 6, 6,
    7, 7, 3, 4, 3, 7, 6, 7,
    6, 6, 7, 6, 7, 6, 3, 2,
    6, 6, 5, 4, 1, 4, 4, 5,   # subqmod sat16s move moveq moveta movefa movei loadb
    5, 5, 6, 20, 20, 3, 3, 3, # loadw load sat32s ld_r14 ld_r15 storeb storew store
    6, 26, 26, 4, 1, 0, 6, 5, # mirror st_r14 st_r15 move_pc jump jr mmult mtoi
    5, 0, 5, 5, 11, 11, 0, 6, # normi nop ld_r14ri ld_r15ri st_r14ri st_r15ri illegal addqmod
]
# Which opcodes set the flags (the flags interlock, R3, fires on the next
# flag-reading op).
SETS_FLAGS = [
    1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0,
    1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
]
NAMES = ["add", "addc", "addq", "addqt", "sub", "subc", "subq", "subqt",
         "neg", "and", "or", "xor", "not", "btst", "bset", "bclr",
         "mult", "imult", "imultn", "resmac", "imacn", "div", "abs", "sh",
         "shlq", "shrq", "sha", "sharq", "ror", "rorq", "cmp", "cmpq",
         "sat8", "sat16", "move", "moveq", "moveta", "movefa", "movei", "loadb",
         "loadw", "load", "loadp", "ld_r14", "ld_r15", "storeb", "storew", "store",
         "storep", "st_r14", "st_r15", "move_pc", "jump", "jr", "mmult", "mtoi",
         "normi", "nop", "ld_r14ri", "ld_r15ri", "st_r14ri", "st_r15ri", "sat24", "pack"]

# The timing constants (src/tom/gpu.c; the DSP's are the same).
GRANT, EXT_ISSUE, EXT_RETURN = 2, 2, 3
LOCAL_LOAD, LOCAL_REPEAT = 3, 2
DIV_TICKS = 16
# The main-RAM access cost: DRAM_PAGE_CYCLE (2) + the DRAM row miss.
# The row miss comes from MEMCON1's speed bits (bus_arbiter.c:
# dram_row_miss_table = {7,7,5,3}); the microbenchmark ROMs leave the
# register at its reset value, which is speed 3 -> 3 ticks.
DRAM_COST = 2 + 3
IO_COST = 2
# gpu_convert_zero: the 5-bit immediate field, where 0 means 32.
CONVERT_ZERO = [0] + list(range(1, 32))


def decode(path):
    """-> [(opcode_index, field1, field2, immediate)]"""
    data = open(path, "rb").read()
    out = []
    i = 0
    while i + 1 < len(data):
        w = (data[i] << 8) | data[i + 1]      # byte-swap: the blob is LE
        i += 2
        op = (w >> 10) & 0x3F
        f1 = (w >> 5) & 0x1F
        f2 = w & 0x1F
        imm = 0
        if op == 38:
            # movei: + 2 immediate words.  The RISC reads them LSW/MSW
            # (src/tom/gpu.c: gpu_opcode_movei -- "a 32-bit value in
            # LSW / MSW format") and each word is big-endian.
            imm = (((data[i + 2] << 8) | data[i + 3]) << 16) | \
                  ((data[i] << 8) | data[i + 1])
            i += 4
        out.append((op, f1, f2, imm, i - 2 - (4 if op == 38 else 0)))
    return out


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def s32(v):
    v &= 0xFFFFFFFF
    return v - 0x100000000 if v & 0x80000000 else v


def s40(v):
    v &= 0xFFFFFFFFFF
    return v - 0x10000000000 if v & (1 << 39) else v


class Sim(object):
    def __init__(self, dsp=False, dram_cost=DRAM_COST):
        self.dsp = dsp
        self.flags_tab = FLAGS_DSP if dsp else FLAGS_GPU
        self.dram_cost = dram_cost
        self.clock = 0
        self.reg_ready = [0] * 32
        self.ext_done = [0, 0]
        self.gate_free = 0
        self.local_busy = 0
        self.prev_dest = 0xFF
        self.prev_flags = 0
        self.bus = 0
        self.core = 0
        self.score_by_op = [0] * 64
        self.raw_by_op = [0] * 64
        self.port_by_op = [0] * 64
        self.flags_by_op = [0] * 64
        self.issue = 0
        self.trace = None
        # the machine state
        self.regs = [0] * 32
        self.acc = 0                    # the MAC accumulator (40-bit on the DSP)
        self.flag_z = self.flag_n = self.flag_c = 0
        self.mem = {}                   # address -> 32-bit value
        self.pc = 0

    # -- the value model ----------------------------------------------
    def set_flags_add(self, a, b, res):
        self.flag_z = 1 if (res & 0xFFFFFFFF) == 0 else 0
        self.flag_n = 1 if (res & 0x80000000) else 0
        self.flag_c = 1 if res > 0xFFFFFFFF else 0

    def set_flags_sub(self, a, b, res):
        self.flag_z = 1 if (res & 0xFFFFFFFF) == 0 else 0
        self.flag_n = 1 if (res & 0x80000000) else 0
        self.flag_c = 1 if (a & 0xFFFFFFFF) < (b & 0xFFFFFFFF) else 0

    def exec_value(self, index, f1, f2, imm, mem):
        """Execute the instruction's effect on the register file."""
        RM = self.regs[f1]
        RN = self.regs[f2]
        M = 0xFFFFFFFF
        if index == 0:                                   # add (RMW)
            res = (RN + RM) & M
            self.set_flags_add(RN, RM, res)
            self.regs[f2] = res
        elif index == 1:                                 # addc
            res = (RN + RM + self.flag_c) & M
            self.set_flags_add(RN, RM, res)
            self.regs[f2] = res
        elif index == 2:                                 # addq (immediate)
            r1 = CONVERT_ZERO[f1 & 0x1F]
            res = (RN + r1) & M
            self.set_flags_add(RN, r1, res)
            self.regs[f2] = res
        elif index == 3:                                 # addqt
            self.regs[f2] = (RN + CONVERT_ZERO[f1 & 0x1F]) & M
        elif index == 4:                                 # sub (RMW)
            res = (RN - RM) & M
            self.set_flags_sub(RN, RM, res)
            self.regs[f2] = res
        elif index == 5:                                 # subc
            res = (RN - RM - self.flag_c) & M
            self.set_flags_sub(RN, RM, res)
            self.regs[f2] = res
        elif index == 6:                                 # subq
            r1 = CONVERT_ZERO[f1 & 0x1F]
            res = (RN - r1) & M
            self.set_flags_sub(RN, r1, res)
            self.regs[f2] = res
        elif index == 7:                                 # subqt
            self.regs[f2] = (RN - CONVERT_ZERO[f1 & 0x1F]) & M
        elif index == 16:                                # mult (16.16, RMW)
            res = ((RM & 0xFFFF) * (RN & 0xFFFF)) & M
            self.flag_z = 1 if res == 0 else 0
            self.flag_n = 1 if (res & 0x80000000) else 0
            self.regs[f2] = res
        elif index == 17:                                # imult
            res = (s16(RN) * s16(RM)) & M
            self.flag_z = 1 if res == 0 else 0
            self.flag_n = 1 if (res & 0x80000000) else 0
            self.regs[f2] = res
        elif index == 18:                                # imultn: acc = RN*RM
            res = s16(RN) * s16(RM)
            self.acc = res & (0xFFFFFFFFFF if self.dsp else M)
            self.flag_z = 1 if (res & M) == 0 else 0
            self.flag_n = 1 if (res & 0x80000000) else 0
        elif index == 19:                                # resmac
            self.regs[f2] = self.acc & M
        elif index == 20:                                # imacn: acc += RN*RM
            res = s16(RN) * s16(RM)
            if self.dsp:
                self.acc = (s40(self.acc) + res) & 0xFFFFFFFFFF
            else:
                self.acc = (self.acc + res) & M
        elif index == 21:                                # div (RN / RM)
            if RM == 0:
                self.regs[f2] = 0xFFFFFFFF
            else:
                q = abs(s32(RN)) // abs(s32(RM))
                if (s32(RN) < 0) != (s32(RM) < 0):
                    q = -q
                self.regs[f2] = q & M
        elif index == 30:                                # cmp (flags only)
            self.set_flags_sub(RN, RM, (RN - RM) & M)
        elif index == 31:                                # cmpq
            r1 = CONVERT_ZERO[f1 & 0x1F]
            self.set_flags_sub(RN, r1, (RN - r1) & M)
        elif index == 34:                                # move: RN = RM
            self.regs[f2] = RM
        elif index == 35:                                # moveq
            self.regs[f2] = CONVERT_ZERO[f1 & 0x1F]
        elif index == 38:                                # movei
            self.regs[f2] = imm & M
        elif index in (40, 41):                          # loadw / load
            addr = (RM + (CONVERT_ZERO[f1 & 0x1F] << 2)) if index == 41 else RM
            val = self.mem.get(addr & M, 0)
            self.regs[f2] = val & (0xFFFF if index == 40 else M)
        elif index in (43, 44):                          # load (r14/r15 + offset)
            base = self.regs[14] if index == 43 else self.regs[15]
            addr = base + (CONVERT_ZERO[f1 & 0x1F] << 2)
            self.regs[f2] = self.mem.get(addr & M, 0)
        elif index in (46, 47):                          # storew / store
            addr = RM
            self.mem[addr & M] = self.regs[f2] & (0xFFFF if index == 46 else M)
        elif index == 57:                                # nop
            pass
        # the rest (the branches, the shifts, the saturation ops) do not
        # change anything the payloads we trace depend on

    # -- GPUPipeCheckUse ------------------------------------------------
    def check_use(self, index, f1, f2):
        f = self.flags_tab[index]
        ready = self.clock
        wait = 0
        wait_ext = False
        if self.dsp:
            sb1 = (f & 1) or (f & 16)
            sb2 = (f & 2) and not (f & 8)
        else:
            sb1 = (f & 1) != 0
            sb2 = (f & 2) != 0
        if sb1:
            r = self.reg_ready[f1]
            if r > ready:
                ready, wait_ext = r, True
        if sb2:
            r = self.reg_ready[f2]
            if r > ready:
                ready, wait_ext = r, True
        wait = ready - self.clock
        kind = 1 if wait else 0
        if wait < 1 and self.prev_dest != 0xFF:
            if ((sb1 and f1 == self.prev_dest) or (sb2 and f2 == self.prev_dest)):
                wait, kind = 1, 2
            elif (f & 1) and (f & 2) and not ((f & 8) and f2 == self.prev_dest):
                wait, kind = 1, 3
        if wait < 1 and self.prev_flags:
            if index in (1, 5) or ((index in (52, 53)) and f2 != 0):
                wait, kind = 1, 4
        extra = 0
        if index == 38:
            extra = 2
        elif index in (43, 44, 58, 59):
            extra = 2
        elif index in (49, 50, 60, 61):
            extra = 1
        if wait:
            if wait_ext:
                self.bus += wait
            else:
                self.core += wait
            if kind == 1:
                self.score_by_op[index] += wait
            elif kind == 2:
                self.raw_by_op[index] += wait
            elif kind == 3:
                self.port_by_op[index] += wait
            else:
                self.flags_by_op[index] += wait
        if extra:
            self.core += extra
        return wait, kind

    # -- GPUPipeMemAccess ----------------------------------------------
    def mem_access(self, kind, is_load, f2, is_long=True):
        t0 = self.clock + self.bus + self.core
        t = t0
        if kind == "local":
            if self.local_busy > t:
                t = self.local_busy
            self.local_busy = t + LOCAL_REPEAT
            if is_load:
                self.reg_ready[f2] = t + LOCAL_LOAD
            if t > t0:
                self.core += t - t0
            return
        if not is_load:
            # A store drains the pending loads first.
            t = max(t, self.ext_done[0], self.ext_done[1])
        elif self.ext_done[0] > t and self.ext_done[1] > t:
            # Both slots pending: the third access waits for the earlier.
            t = min(self.ext_done[0], self.ext_done[1])
        if self.gate_free > t:
            t = self.gate_free
        if t > t0:
            self.bus += t - t0
        cost = self.dram_cost if kind == "ext" else IO_COST
        if self.dsp and is_long:
            # JERRY reaches external memory over a 16-bit bus: a long
            # transfer is split into two word cycles (bus_arbiter.c:
            # bus_arbiter_dsp_access -- the split pause plus the second
            # word's cost).
            cost += 1 + 2
        done = t + EXT_ISSUE + GRANT + cost + (EXT_RETURN if is_load else 0)
        self.gate_free = t + EXT_ISSUE
        slot = 0 if self.ext_done[0] <= self.ext_done[1] else 1
        self.ext_done[slot] = done
        if is_load:
            self.reg_ready[f2] = done

    # -- one instruction ------------------------------------------------
    def step(self, index, f1, f2, imm, mem, pc=0):
        self.bus = 0
        self.core = 0
        wait, kind = self.check_use(index, f1, f2)
        start = self.clock
        if mem is not None:
            self.mem_access(mem[0], mem[1], f2, mem[2])
        if index in (52, 53):
            # A taken jump/jr runs its delay slot inline and costs 2 (jump)
            # or 3 (jr) dead refill ticks on top.
            self.core += (1 + 2) if index == 52 else (1 + 3)
        self.clock += 1 + self.bus + self.core
        self.issue += 1
        self.prev_dest = f2 if (self.flags_tab[index] & 4) else 0xFF
        self.prev_flags = SETS_FLAGS[index]
        if index == 21:
            self.reg_ready[f2] = self.clock + DIV_TICKS
        ready = self.reg_ready[f2] if (mem and mem[1]) else 0
        self.exec_value(index, f1, f2, imm, mem)
        if self.trace is not None:
            self.trace.append({
                "tick": start, "index": index, "f1": f1, "f2": f2, "pc": pc,
                "wait": wait, "kind": kind, "bus": self.bus,
                "core": self.core, "ready": ready,
                "regs": list(self.regs), "acc": self.acc,
                "z": self.flag_z, "n": self.flag_n, "c": self.flag_c,
                "mem": mem,
            })


# ------------------------------------------------------------- the program
def parse_program(path):
    """-> (blocks, memory)"""
    root = []
    memory = []
    stack = [(-1, root)]
    for raw in open(path):
        line = raw.split("#")[0].split(";")[0].strip()
        if not line:
            continue
        indent = len(raw) - len(raw.lstrip())
        parts = line.split()
        if parts[0] == "mem":
            # mem <class> <addr> <pattern> [count]
            memory.append((parts[1], int(parts[2], 0), parts[3],
                           int(parts[4]) if len(parts) > 4 else 1))
            continue
        while len(stack) > 1 and indent <= stack[-1][0]:
            stack.pop()
        if parts[0] == "repeat":
            n = int(parts[1].rstrip(":"))
            body = []
            stack[-1][1].append(("repeat", n, body))
            stack.append((indent, body))
            continue
        rng = parts[0]
        mem = parts[1] if len(parts) > 1 else None
        a, b = rng.split("..")
        stack[-1][1].append(("block", int(a), int(b), mem, []))
    return root, memory


def build_memory(sim, memory):
    """Fill the modelled memory the way the ROM's 68K builds it."""
    for kind, addr, pattern, count in memory:
        if pattern == "vertex":
            # 16 bytes per vertex: the SPARE word first (the RISC's
            # indexed load cannot encode a zero offset -- the field's 0
            # means 32 words -- so the payload's "load (r14+4),r4" is the
            # vertex's x), then x=i, y=i+1, z=i+2.
            for i in range(count):
                base = addr + i * 16
                sim.mem[base] = 0
                sim.mem[base + 4] = i & 0xFFFFFFFF
                sim.mem[base + 8] = (i + 1) & 0xFFFFFFFF
                sim.mem[base + 12] = (i + 2) & 0xFFFFFFFF
        elif pattern == "counter":
            for i in range(count):
                sim.mem[addr + i * 4] = i & 0xFFFFFFFF
        elif pattern == "envelope":
            # one DRAM page per voice: the volume, then zeros
            for v in range(count):
                base = addr + v * 1024
                sim.mem[base] = (v + 1) & 0xFFFFFFFF
        elif pattern == "zero":
            for i in range(count):
                sim.mem[addr + i * 4] = 0
        else:
            raise SystemExit("pipe_sim: unknown memory pattern %r" % pattern)


def run(sim, prog, blocks, trace=None):
    for b in blocks:
        if b[0] == "repeat":
            for _ in range(b[1]):
                run(sim, prog, b[2], trace)
        else:
            _, a, bnd, mem, _ = b
            for k in range(a, bnd + 1):
                op, f1, f2, imm, pc = prog[k]
                m = None
                is_mem = op in (40, 41, 43, 44, 45, 46, 47, 49, 50, 58,
                                59, 60, 61)
                if is_mem:
                    is_load = op in (40, 41, 43, 44, 58, 59)
                    is_long = op not in (40, 45, 46)
                    kind = mem if mem in ("ext", "local", "io") else "ext"
                    m = (kind, is_load, is_long)
                sim.step(op, f1, f2, imm, m, pc)


def hist(a):
    return " ".join("%s=%d" % (NAMES[i], a[i]) for i in range(64) if a[i])


KINDNAME = {0: "-", 1: "SCORE", 2: "RAW", 3: "PORT", 4: "FLAGS"}


def print_trace(entries, regs):
    print("  tick  pc    op        operands        wait cause  bus core"
          "  ready   ACC(40)      Z N C")
    for e in entries:
        extra = ""
        if e["mem"]:
            extra = " %s%s" % (e["mem"][0], "L" if e["mem"][1] else "S")
        print("  %5d  %04x  %-8s r%-2d->r%-2d %4d %-5s %3d %4d %5d"
              "  %010x  %d %d %d%s"
              % (e["tick"], e["pc"], NAMES[e["index"]], e["f1"], e["f2"], e["wait"],
                 KINDNAME[e["kind"]], e["bus"], e["core"], e["ready"],
                 e["acc"] & 0xFFFFFFFFFF, e["z"], e["n"], e["c"], extra))
        if regs:
            for row in range(4):
                cells = []
                for col in range(8):
                    r = row * 8 + col
                    cells.append("r%02d=%08x" % (r, e["regs"][r]))
                print("        " + " ".join(cells))


def main():
    args = sys.argv[1:]
    trace_at = None
    show_regs = False
    trace_from = 0
    if "--trace" in args:
        i = args.index("--trace")
        trace_at = int(args[i + 1])
        del args[i:i + 2]
    if "--regs" in args:
        args.remove("--regs")
        show_regs = True
    if "--from" in args:
        i = args.index("--from")
        trace_from = int(args[i + 1])
        del args[i:i + 2]
    binpath, core, progpath = args[0], args[1], args[2]
    prog = decode(binpath)
    sim = Sim(dsp=(core == "dsp"))
    blocks, memory = parse_program(progpath)
    build_memory(sim, memory)
    if trace_at is not None:
        # the top-level repeat: pick one iteration
        sim.trace = []
        for b in blocks:
            if b[0] == "repeat":
                for n in range(b[1]):
                    run(sim, prog, b[2], sim.trace)
                    if n == trace_at:
                        break
                break
            run(sim, prog, [b], sim.trace)
        print("=== the prologue + iteration %d of the top-level repeat"
              " (entries %d..%d) ===" % (trace_at, trace_from,
                                          len(sim.trace) - 1))
        print_trace(sim.trace[trace_from:], show_regs)
        return
    run(sim, prog, blocks)
    print("total ticks : %d   instructions : %d" % (sim.clock, sim.issue))
    print("score stalls: %s" % hist(sim.score_by_op))
    print("raw stalls  : %s" % hist(sim.raw_by_op))
    print("port stalls : %s" % hist(sim.port_by_op))
    print("flags stalls: %s" % hist(sim.flags_by_op))


if __name__ == "__main__":
    main()
