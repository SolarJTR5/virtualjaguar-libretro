; test/microbench/benchgpu_interleave.s -- 68K bootstrap for the
; "interleave vs naive" microbenchmark ROM (task 6).
;
; The 68K's jobs:
;   1. write the START sentinel;
;   2. build the vertex buffer in MAIN RAM ($020000) -- so the GPU's
;      loads are EXTERNAL accesses (L = 7 + D), not local-RAM hits;
;   3. copy BOTH GPU payloads into GPU local RAM (the naive one at
;      $F03000, the interleaved one at $F03100);
;   4. read the schedule flag from main RAM and start the GPU at the
;      matching entry;
;   5. keep the bus busy (the 68K is the Jaguar's other co-processor,
;      and an idle bus is not a realistic bus).
;
; The schedule flag lives at $020800 in main RAM and is written by the
; HARNESS before the run (test/tools/test_microbench_gpu_interleave.c),
; because the two schedules must run under IDENTICAL conditions: same
; ROM, same buffers, same bus traffic -- only the GPU's instruction
; placement differs.  0 = the naive schedule, 1 = the interleaved one.
;
; The DONE/COUNT sentinels are written by the GPU itself (a STORE to
; an external main-RAM address is a normal GPU instruction).
;
; Build (from this directory, toolchain on PATH):
;   eval "$(tools/jaguar-toolchain/setup.sh env)"
;   ./build.sh
; or by hand:
;   lyxass -o benchgpu_interleave_naive_gpu.o benchgpu_interleave_naive_gpu.s
;   tail -c +13 benchgpu_interleave_naive_gpu.o > benchgpu_interleave_naive_gpu.bin
;   lyxass -o benchgpu_interleave_shadow_gpu.o benchgpu_interleave_shadow_gpu.s
;   tail -c +13 benchgpu_interleave_shadow_gpu.o > benchgpu_interleave_shadow_gpu.bin
;   rmac -fb -o benchgpu_interleave.o benchgpu_interleave.s
;   rln  -n -a 800000 x x -o benchgpu_interleave.j64 benchgpu_interleave.o

        .68000
        .text

        .include "cartboot.inc"

; --- GPU control registers ($F02100-$F0211F) ---
G_FLAGS         .equ    $00F02100
G_PC            .equ    $00F02110
G_CTRL          .equ    $00F02114
GPU_RAM_BASE    .equ    $00F03000       ; GPU local RAM, 4 KB
GPUGO           .equ    $00000001       ; G_CTRL bit 0: start/stop GPU

; --- the benchmark's working set ---
VERT_BASE       .equ    $00020000       ; the vertex buffer (main RAM)
VERT_COUNT      .equ    64              ; vertices
VERT_STRIDE     .equ    16              ; bytes per vertex (4 long words)
FLAG_ADDR       .equ    $00020800       ; the schedule flag, written by the harness
SHADOW_ENTRY    .equ    $00000100       ; the interleaved payload's offset
DEEP_ENTRY      .equ    $00000200       ; the 2-deep payload's offset

; --- the 68K's own DRAM traffic, so the bus is not idle ---
BUSY_BASE       .equ    $00021000

start:
        ; Mask every interrupt level (same rationale as benchgpu_arith.s:
        ; the HLE BIOS leaves the video/timer IRQs live and 68K ISR
        ; cycles would only add noise).
        move.w  #$2700,sr

        ; "the cart booted"
        move.l  #MB_MAGIC_START,MB_SENT_START

        ; --- build the vertex buffer in main RAM ---
        ; x = i, y = 2i, z = 3i, so the dot products are not all zero
        ; and the divide has a real divisor.
        lea     VERT_BASE,a0
        moveq   #0,d2
        move.w  #VERT_COUNT-1,d1
vfill:
        ; The SPARE word comes first: the RISC's indexed load cannot
        ; encode a zero offset (the field's 0 means 32 words), so the
        ; vertex has to start at +4 for "load (r14+4),r4" to be the x.
        moveq   #0,d3
        move.l  d3,(a0)+            ; spare
        move.l  d2,(a0)+            ; x = i
        addq.l  #1,d2
        move.l  d2,(a0)+            ; y = i+1
        addq.l  #1,d2
        move.l  d2,(a0)+            ; z = i+2
        dbf     d1,vfill

        ; --- copy the NAIVE payload into GPU local RAM at $F03000 ---
        lea     gpu_code_naive(pc),a0
        movea.l #GPU_RAM_BASE,a1
        move.w  #NAIVE_LEN-1,d0
ncopy:
        move.b  (a0)+,(a1)+
        dbf     d0,ncopy

        ; --- copy the INTERLEAVED payload to $F03000+SHADOW_ENTRY ---
        lea     gpu_code_shadow(pc),a0
        movea.l #GPU_RAM_BASE+SHADOW_ENTRY,a1
        move.w  #SHADOW_LEN-1,d0
scopy:
        move.b  (a0)+,(a1)+
        dbf     d0,scopy

        ; --- copy the 2-DEEP payload to $F03000+DEEP_ENTRY ---
        lea     gpu_code_deep(pc),a0
        movea.l #GPU_RAM_BASE+DEEP_ENTRY,a1
        move.w  #DEEP_LEN-1,d0
dcopy:
        move.b  (a0)+,(a1)+
        dbf     d0,dcopy

        ; --- pick the entry point from the flag the harness wrote ---
        ; 0 = naive, 1 = interleaved (1 deep), 2 = 2-deep pipeline
        lea     FLAG_ADDR,a0
        move.l  (a0),d0
        tst.l   d0
        beq.s   use_naive
        subq.l  #1,d0
        tst.l   d0
        beq.s   use_shadow
        move.l  #GPU_RAM_BASE+DEEP_ENTRY,d1
        bra.s   have_pc
use_naive:
        move.l  #GPU_RAM_BASE,d1
        bra.s   have_pc
use_shadow:
        move.l  #GPU_RAM_BASE+SHADOW_ENTRY,d1
have_pc:
        ; (debug) publish the chosen entry point so a harness can see
        ; which schedule ran.
        lea     FLAG_ADDR+8,a0
        move.l  d0,(a0)        ; (debug) the flag AS THE 68K READ IT
        lea     FLAG_ADDR+12,a0
        move.l  d1,(a0)       ; (debug) the chosen entry
        ; G_PC must be written before GPUGO.
        move.l  d1,G_PC
        move.l  #0,G_FLAGS
        move.l  #GPUGO,G_CTRL

; --- keep the bus busy: the 68K is the Jaguar's other co-processor
; and an idle DRAM is not the realistic case.  A rolling long-word
; write over a 4 KB window, so every iteration touches DRAM.
spin:
        lea     BUSY_BASE,a0
        moveq   #0,d0
        move.w  #255,d1
busy:
        move.l  d0,(a0)+
        addq.l  #1,d0
        dbf     d1,busy
        bra.s   spin

; --- the embedded GPU payloads -------------------------------------
; Both are lyxass output with the 12-byte BS94 header already
; stripped (see build.sh) -- raw GPU RISC code.
gpu_code_naive:
        .incbin "benchinterleave_naive_gpu.bin"
gpu_code_naive_end:

gpu_code_shadow:
        .incbin "benchinterleave_shadow_gpu.bin"
gpu_code_shadow_end:

gpu_code_deep:
        .incbin "benchinterleave_deep_gpu.bin"
gpu_code_deep_end:

NAIVE_LEN       .equ    gpu_code_naive_end-gpu_code_naive
SHADOW_LEN      .equ    gpu_code_shadow_end-gpu_code_shadow
DEEP_LEN        .equ    gpu_code_deep_end-gpu_code_deep

        .end
