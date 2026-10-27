# known_bad/ -- regression control for the particle harness

`benchgpu_particle_persp2_buggy.s` is the **first revision** of the GPU
particle-transform payload, kept here on purpose.  It is not built by
`test/microbench/build.sh` and is not part of `make microbench`.

## What is wrong with it

It stored each particle's result back through the **input** cursor:

    store r29,(r14)
    store r30,(r14+4)
    ...
    addq  #16,r14

so particle *k*'s projected x,y landed in particle *k+1*'s x,y slots and
were read back as input on the next iteration.  Live reads of `$00020000`
showed `P1=(0,0,5,6)` where the 68K had written `P1=(3,4,5,6)`: from P1
on, the simulation ran on zeros.

It still counted 256 particles and still produced a near-perfect
scoreboard (score=10), so the old timing-only harness passed it.  That is
the whole point of keeping it: it is the ROM that motivated the
bit-exact check now in `test/tools/test_microbench_gpu_particle.c`.

## Expected result

    data_bad=256   first bad P0
    FAIL: output buffer does not match the reference model

## Rebuilding the control image

    test/microbench/known_bad/build.sh
    ./test/tools/test_microbench_gpu_particle ./virtualjaguar_libretro.so \
        /tmp/benchgpu_particle_buggy.j64

Needs `lyxass`, `rmac` and `rln` on `PATH`
(`eval "$(tools/jaguar-toolchain/setup.sh env)"` from the repo root).
