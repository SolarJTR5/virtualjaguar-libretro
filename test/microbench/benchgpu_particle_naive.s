; test/microbench/benchgpu_particle_naive.s -- 68K bootstrap for the
; immediate-consume (naive) control of the particle transform.  Same
; bootstrap, same input data, same output buffer; only the RISC payload
; differs.

VARIANT .equ    2
        .include "particle_boot.inc"
