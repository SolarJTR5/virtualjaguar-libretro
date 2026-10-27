; test/microbench/benchgpu_particle.s -- 68K bootstrap for the 2-DEEP
; particle transform.  The bootstrap itself lives in particle_boot.inc;
; this file only selects which RISC payload the ROM carries.
;
; Build with test/microbench/build.sh (needs lyxass + rmac + rln).

VARIANT .equ    1
        .include "particle_boot.inc"
