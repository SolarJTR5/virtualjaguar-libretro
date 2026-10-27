#!/usr/bin/env python3
"""
test/tools/particle_reference.py -- bit-exact reference model for the
GPU particle-transform microbenchmark, and a comparator for the output
buffer a run actually produced.

WHY THIS EXISTS
---------------
test_microbench_gpu_particle.c used to pass a ROM purely on "the loop
finished with the expected count and the scoreboard stayed quiet".  That
is a timing assertion, not a correctness one: the earlier revision of
this ROM stored particle k's result through the INPUT cursor, so every
particle after P0 was loaded back in as x=y=0 and the simulation
collapsed -- while still passing.  This script is the missing half: it
computes what the ROM is supposed to leave in the output buffer and
compares it word for word.

THE MODEL (mirrors the RISC payload exactly)
--------------------------------------------
The 68K bootstrap fills the input buffer with

    P_i = (x, y, vx, vy) = (3i, 3i+1, 3i+2, 3i+3)          [32-bit BE]

and the RISC payload computes, for every particle,

    x += vx ; y += vy ; vx += 1 ; vy += 1
    q     = FIXED // y                     (FIXED = 65536)
    out_x = x * q                          (low 32 bits)
    out_y = y * q                          (low 32 bits)

Note out_y = y * floor(FIXED/y) = FIXED - (FIXED mod y), so a correct run
keeps out_y in [FIXED-(max_y-1), FIXED] -- with this input, max_y is 1534,
so the floor is 64003.  That invariant alone catches a collapsed or
partially-written buffer.

USAGE
-----
  # print the expected buffer as a C array / hex dump
  python3 test/tools/particle_reference.py --print

  # compare a raw 4096-byte little-host-endian dump of $00030000
  python3 test/tools/particle_reference.py --compare /tmp/out.bin

The dump is produced from the RUNNING core, e.g.

  gdb -q -batch -ex 'set breakpoint pending on' -ex 'break harness_report' \
      -ex run -ex 'set $r=(unsigned char*)jaguarMainRAM' \
      -ex 'dump binary memory /tmp/out.bin $r+0x30000 $r+0x31000' -ex quit \
      --args ./test/tools/test_microbench_gpu_particle \
             ./virtualjaguar_libretro.so test/microbench/benchgpu_particle.j64

The host is little-endian, so each 32-bit word in the dump is the
byte-reverse of the big-endian value the 68K/RISC wrote; --compare
handles that.
"""

import struct
import sys

PART_COUNT = 256
STRIDE = 16
FIXED = 65536
OUT_BASE = 0x00030000


def input_particle(i):
    """The 68K bootstrap's fill: (x, y, vx, vy) for particle i."""
    d = 3 * i
    return (d, d + 1, d + 2, d + 3)


def expected(i):
    """What the RISC payload must leave in the output slot for particle i."""
    x, y, vx, vy = input_particle(i)
    x = (x + vx) & 0xFFFFFFFF
    y = (y + vy) & 0xFFFFFFFF
    q = FIXED // y if y else 0
    return ((x * q) & 0xFFFFFFFF, (y * q) & 0xFFFFFFFF,
            (x * (q + 1)) & 0xFFFFFFFF, 0)


def expected_words():
    """Full output buffer as big-endian 32-bit values, 4 per particle.

    Each particle writes out_x, out_y, then two untouched words (the
    payload only stores the first two).
    """
    words = []
    for i in range(PART_COUNT):
        ox, oy = expected(i)[:2]
        words.extend([ox, oy, 0, 0])
    return words


def dump_words(path):
    data = open(path, "rb").read()
    if len(data) != PART_COUNT * STRIDE:
        raise SystemExit("%s is %d bytes, expected %d"
                         % (path, len(data), PART_COUNT * STRIDE))
    # The machine writes big-endian words; the raw dump therefore holds
    # those bytes in order, so unpack big-endian to recover the values.
    return list(struct.unpack(">%dI" % (len(data) // 4), data))


def describe(i, got, want):
    return ("  P%-3d  got (x=%08x y=%08x)  want (x=%08x y=%08x)"
            % (i, got[0], got[1], want[0], want[1]))


def main(argv):
    if "--print" in argv:
        words = expected_words()
        for i in range(0, PART_COUNT * 4, 4):
            print("%3d: %08x %08x %08x %08x"
                  % (i // 4, words[i], words[i + 1], words[i + 2], words[i + 3]))
        return 0

    if "--compare" in argv:
        idx = argv.index("--compare")
        if idx + 1 >= len(argv):
            raise SystemExit("--compare needs a file")
        got = dump_words(argv[idx + 1])

        bad = 0
        first = []
        for i in range(PART_COUNT):
            g = (got[i * 4], got[i * 4 + 1])
            w = expected(i)[:2]
            if g != w:
                bad += 1
                if len(first) < 8:
                    first.append(describe(i, g, w))

        print("particles compared : %d" % PART_COUNT)
        print("mismatches         : %d" % bad)
        for line in first:
            print(line)

        # the invariant, stated separately so a failure is self-explaining
        max_y = max(sum(input_particle(i)[1::2]) for i in range(PART_COUNT))
        lo = FIXED - (max_y - 1)
        weak = [i for i in range(PART_COUNT)
                if not (lo <= got[i * 4 + 1] <= FIXED)]
        print("out_y outside [%d, %d]: %d" % (lo, FIXED, len(weak)))
        if weak[:4]:
            print("  first offenders:", weak[:4])

        return 0 if bad == 0 and not weak else 1

    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
