#!/usr/bin/env python3
"""
test/tools/check_particle_permutation.py -- prove the particle A/B pair is
a controlled experiment.

The claim benchgpu_particle_gpu.s and benchgpu_particle_naive_gpu.s make
is narrow and testable: their steady-state loop bodies contain the SAME
instructions with the SAME operands, in the SAME number, and differ ONLY
in where the two MULTs sit relative to the DIV.  If that is true, any
tick difference between the two ROMs is attributable to instruction
placement and nothing else.

This script decodes both assembled payloads (the raw blobs the ROMs
embed, header already stripped) and compares:

  * the multiset of (opcode, f1, f2, imm) tuples in each steady-state
    body  -- must be equal;
  * the body LENGTH                      -- must be equal;
  * the prologue and epilogue instruction multisets -- reported, since
    the deep variant primes P0 early and the naive one does not.

Usage:
    python3 test/tools/check_particle_permutation.py \
        test/microbench/benchgpu_particle_gpu.bin \
        test/microbench/benchgpu_particle_naive_gpu.bin
"""

import sys
import os
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pipe_sim import decode  # noqa: E402

OP_MOVEI = 38
OP_JUMP = 52
OP_NOP = 57

OPNAMES = [
    "add", "addc", "addq", "addqt", "sub", "subc", "subq", "subqt",
    "neg", "and", "or", "xor", "not", "btst", "bset", "bclr",
    "mult", "imult", "imultn", "resmac", "imacn", "div", "abs", "sh",
    "shlq", "shrq", "sha", "sharq", "ror", "rorq", "cmp", "cmpq",
    "sat8", "sat16", "move", "moveq", "moveta", "movefa", "movei", "loadb",
    "loadw", "load", "loadp", "ld_r14", "ld_r15", "storeb", "storew", "store",
    "storep", "st_r14", "st_r15", "move_pc", "jump", "jr", "mmult", "mtoi",
    "normi", "nop", "ld_r14ri", "ld_r15ri", "st_r14ri", "st_r15ri",
    "sat24", "pack",
]


def name(op):
    return OPNAMES[op] if 0 <= op < len(OPNAMES) else "op%d" % op


def body_range(prog, load_base=0xF03200):
    """-> (start_index, end_index_exclusive) of the steady-state loop.

    The loop head is the target of `movei #loop,r13`; the end is the
    `jump` that uses r13, plus its delay slot.  The immediate is an
    ABSOLUTE address (the payload is baked for the address it runs at),
    while decode()'s pc field is a blob offset, so subtract the load
    base -- or accept an immediate that is already an offset.
    """
    pcs = {p[4] for p in prog}
    loop_pc = None
    for op, f1, f2, imm, pc in prog:
        if op == OP_MOVEI and f2 == 13:
            for cand in (imm - load_base, imm):
                if cand in pcs:
                    loop_pc = cand
                    break
    if loop_pc is None:
        raise SystemExit("no movei #loop,r13 with an in-code target found "
                         "(is the payload loaded at $%06X?)" % load_base)

    start = next(i for i, ins in enumerate(prog) if ins[4] == loop_pc)
    jump = None
    for i in range(start, len(prog)):
        if prog[i][0] == OP_JUMP:
            jump = i
            break
    if jump is None:
        raise SystemExit("no jump found after the loop head")

    end = jump + 1
    if end < len(prog) and prog[end][0] == OP_NOP:
        end += 1
    return start, end


def key(ins):
    op, f1, f2, imm, _pc = ins
    return (op, f1, f2, imm)


def describe(multiset):
    lines = []
    for k, n in sorted(multiset.items(), key=lambda kv: (kv[0][0], kv[0][1], kv[0][2])):
        op, f1, f2, imm = k
        extra = " #$%X" % imm if imm else ""
        lines.append("  %-8s f1=%-2d f2=%-2d%-10s x%d" % (name(op), f1, f2, extra, n))
    return "\n".join(lines)


def check(path, load_base):
    prog = decode(path)
    start, end = body_range(prog, load_base)
    body = prog[start:end]
    pre = prog[:start]
    post = prog[end:]
    return prog, start, end, body, pre, post


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2

    deep_path, naive_path = argv[1], argv[2]
    load_base = int(argv[3], 0) if len(argv) > 3 else 0xF03200
    dprog, dstart, dend, dbody, dpre, dpost = check(deep_path, load_base)
    nprog, nstart, nend, nbody, npre, npost = check(naive_path, load_base)

    print("deep  : %s" % deep_path)
    print("         body = instructions [%d..%d) of %d, %d long"
          % (dstart, dend, len(dprog), len(dbody)))
    print("naive : %s" % naive_path)
    print("         body = instructions [%d..%d) of %d, %d long"
          % (nstart, nend, len(nprog), len(nbody)))

    ok = True

    if len(dbody) != len(nbody):
        print("\nFAIL: body lengths differ (%d vs %d)" % (len(dbody), len(nbody)))
        ok = False

    dmulti = Counter(key(i) for i in dbody)
    nmulti = Counter(key(i) for i in nbody)

    if dmulti != nmulti:
        print("\nFAIL: body instruction multisets differ")
        print("  only in deep:")
        print(describe(Counter({k: v for k, v in (dmulti - nmulti).items()})))
        print("  only in naive:")
        print(describe(Counter({k: v for k, v in (nmulti - dmulti).items()})))
        ok = False
    else:
        print("\nOK: body instruction multisets are IDENTICAL (%d instructions)"
              % len(dbody))
        print(describe(dmulti))

    # Positional diff is the point of the experiment: show it, don't fail it.
    if len(dbody) == len(nbody):
        diffs = [(i, dbody[i], nbody[i]) for i in range(len(dbody))
                 if key(dbody[i]) != key(nbody[i])]
        print("\npositions that differ (0-based within the body): %d of %d"
              % (len(diffs), len(dbody)))
        for i, di, ni in diffs:
            print("  [%2d] deep  %-8s f1=%-2d f2=%-2d"
                  % (i, name(di[0]), di[1], di[2]))
            print("       naive %-8s f1=%-2d f2=%-2d"
                  % (name(ni[0]), ni[1], ni[2]))

    # Prologue/epilogue are allowed to differ; report the delta so a reader
    # can see how much of the total instruction count is not steady state.
    print("\nprologue: deep %d instr, naive %d instr"
          % (len(dpre), len(npre)))
    print("epilogue: deep %d instr, naive %d instr"
          % (len(dpost), len(npost)))

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
