; test/microbench/particle_boot.inc -- shared 68K bootstrap for the
; particle-transform A/B pair (benchgpu_particle.s / _naive.s).
;
; The including source sets VARIANT (1 = 2-deep, 2 = naive) before the
; .include, which selects the .incbin below; everything else is common
; so the two ROMs differ ONLY in the GPU payload they carry.
;
; What the 68K does:
;   1. writes the START sentinel;
;   2. fills the INPUT buffer at $00020000 with P_i = (3i, 3i+1, 3i+2, 3i+3)
;      (matching the fill every earlier microbench used, so numbers stay
;      comparable);
;   3. CLEARS the output buffer at $00030000 -- the verification step in
;      test/tools/particle_reference.py requires a known initial state,
;      and clearing also catches a payload that silently stops storing;
;   4. copies the RISC payload into GPU local RAM at $F03200;
;   5. writes the VARIANT sentinel so a harness can label its own run;
;   6. starts the GPU and then keeps the bus busy (an idle bus is not a
;      realistic bus).

        .68000
        .text

        .include "cartboot.inc"

; --- GPU control registers ---
G_FLAGS         .equ    $00F02100
G_PC            .equ    $00F02110
G_CTRL          .equ    $00F02114
GPU_RAM_BASE    .equ    $00F03000
GPUGO           .equ    $00000001

; --- working set (kept in step with the payload sources) ---
PART_BASE       .equ    $00020000       ; input particles
OUT_BASE        .equ    $00030000       ; transformed particles
PART_COUNT      .equ    256
PART_STRIDE     .equ    16
PARTICLE_ENTRY  .equ    $00000200       ; payload runs at $F03200

MB_SENT_VARIANT .equ    MB_SENT_BASE+12

start:
        move.w  #$2700,sr
        move.l  #MB_MAGIC_START,MB_SENT_START

        ; ---- 2. fill the input buffer ------------------------------
        lea     PART_BASE,a0
        move.w  #PART_COUNT-1,d1
        moveq   #0,d2
pfill:
        move.l  d2,(a0)+            ; x
        addq.l  #1,d2
        move.l  d2,(a0)+            ; y
        addq.l  #1,d2
        move.l  d2,(a0)+            ; vx
        addq.l  #1,d2
        move.l  d2,(a0)+            ; vy
        dbf     d1,pfill

        ; ---- 3. clear the output buffer ----------------------------
        lea     OUT_BASE,a0
        move.w  #(PART_COUNT*PART_STRIDE/4)-1,d1
        moveq   #0,d0
oclr:
        move.l  d0,(a0)+
        dbf     d1,oclr

        ; ---- 4. copy the RISC payload to GPU local RAM -------------
        lea     gpu_code_particle(pc),a0
        movea.l #GPU_RAM_BASE+PARTICLE_ENTRY,a1
        move.w  #PARTICLE_LEN-1,d0
pcopy:
        move.b  (a0)+,(a1)+
        dbf     d0,pcopy

        ; ---- 5. label this ROM's schedule --------------------------
        move.l  #VARIANT,MB_SENT_VARIANT

        ; ---- 6. start the GPU --------------------------------------
        move.l  #GPU_RAM_BASE+PARTICLE_ENTRY,d1
        move.l  d1,G_PC
        move.l  #0,G_FLAGS
        move.l  #GPUGO,G_CTRL

spin:
        lea     $00021000,a0
        moveq   #0,d0
        move.w  #255,d1
busy:
        move.l  d0,(a0)+
        addq.l  #1,d0
        dbf     d1,busy
        bra.s   spin

; --- the selected RISC payload ---
gpu_code_particle:
        .if     VARIANT = 1
        .incbin "benchgpu_particle_gpu.bin"
        .else
        .incbin "benchgpu_particle_naive_gpu.bin"
        .endif
gpu_code_particle_end:

PARTICLE_LEN    .equ    gpu_code_particle_end-gpu_code_particle

        .end
