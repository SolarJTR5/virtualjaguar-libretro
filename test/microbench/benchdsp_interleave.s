; test/microbench/benchdsp_interleave.s -- 68K bootstrap for the
; DSP "interleave vs naive" microbenchmark ROM (task 7).
;
; The DSP sibling of benchgpu_interleave.s: the same three schedules
; (naive / 1-deep interleave / 2-deep pipeline), the same vertex
; pipeline, but running on the DSP -- Jerry's RISC.
;
; Why the DSP is the more interesting target:
;
;   - the audio path has NO FIFO between the mix and the I2S interrupt,
;     so "do not publish an unfinished sample" is MANDATORY there, not
;     an optimisation;
;   - the DSP's MAC accumulator is 40 bits (D_MACHI at $F1A120 holds
;     bits 32-39) -- the GPU's is 32 bits and wraps;
;   - the DSP reaches external memory over JERRY's 16-bit bus
;     ("the DSP's 16-bit external interface (v8 p.97) splits a long
;     transfer into two word cycles"), so its loads are slower than the
;     GPU's -- the load stall is bigger, so the 2-deep pipeline should
;     matter more.
;
; The 68K's jobs:
;   1. write the START sentinel;
;   2. build the vertex buffer in MAIN RAM ($020000) -- so the DSP's
;      loads are EXTERNAL accesses, not local-RAM hits;
;   3. copy all three DSP payloads into DSP local RAM (8 KB at $F1B000)
;      at $F1B000 / $F1B100 / $F1B200;
;   4. read the schedule flag from main RAM and start the DSP at the
;      matching entry;
;   5. keep the bus busy (the 68K is the Jaguar's other co-processor).
;
; The schedule flag lives at $020800 in main RAM and is written by the
; HARNESS before the run (test/tools/test_microbench_dsp_interleave.c).
; It is read by the 68K as a longword, and the Jaguar is big-endian, so
; the harness must write it big-endian.
;
;   0 = the naive schedule, 1 = the interleaved one (1 deep),
;   2 = the 2-deep software pipeline.
;
; The DONE/COUNT sentinels are written by the DSP itself (a STORE to an
; external main-RAM address is a normal DSP instruction).
;
; Build (from this directory, toolchain on PATH):
;   eval "$(tools/jaguar-toolchain/setup.sh env)"
;   ./build.sh

        .68000
        .text

        .include "cartboot.inc"

; --- DSP control registers ($F1A100-$F1A120) ---
; The DSP is structurally similar to the GPU but lives inside Jerry, with
; its own control register block and 8 KB (not 4 KB) of local RAM.
D_FLAGS         .equ    $00F1A100
D_PC            .equ    $00F1A110
D_CTRL          .equ    $00F1A114
DSP_RAM_BASE    .equ    $00F1B000       ; DSP local RAM, 8 KB
DSPGO           .equ    $00000001       ; D_CTRL bit 0: start/stop DSP

; --- the benchmark's working set ---
VERT_BASE       .equ    $00020000       ; the vertex buffer (main RAM)
VERT_COUNT      .equ    64              ; vertices
FLAG_ADDR       .equ    $00020800       ; the schedule flag, written by the harness
SHADOW_ENTRY    .equ    $00000100       ; the interleaved payload's offset
DEEP_ENTRY      .equ    $00000200       ; the 2-deep payload's offset

start:
        ; Mask every interrupt level (same rationale as the other ROMs:
        ; the HLE BIOS leaves the video/timer IRQs live and 68K ISR
        ; cycles would only add noise).
        move.w  #$2700,sr

        ; "the cart booted"
        move.l  #MB_MAGIC_START,MB_SENT_START

        ; --- build the vertex buffer in main RAM ---
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

        ; --- copy the NAIVE payload into DSP local RAM at $F1B000 ---
        lea     dsp_code_naive(pc),a0
        movea.l #DSP_RAM_BASE,a1
        move.w  #NAIVE_LEN-1,d0
ncopy:
        move.b  (a0)+,(a1)+
        dbf     d0,ncopy

        ; --- copy the INTERLEAVED payload to $F1B000+SHADOW_ENTRY ---
        lea     dsp_code_shadow(pc),a0
        movea.l #DSP_RAM_BASE+SHADOW_ENTRY,a1
        move.w  #SHADOW_LEN-1,d0
scopy:
        move.b  (a0)+,(a1)+
        dbf     d0,scopy

        ; --- copy the 2-DEEP payload to $F1B000+DEEP_ENTRY ---
        lea     dsp_code_deep(pc),a0
        movea.l #DSP_RAM_BASE+DEEP_ENTRY,a1
        move.w  #DEEP_LEN-1,d0
dcopy:
        move.b  (a0)+,(a1)+
        dbf     d0,dcopy

        ; --- pick the entry point from the flag the harness wrote ---
        lea     FLAG_ADDR,a0
        move.l  (a0),d0
        tst.l   d0
        beq.s   use_naive
        subq.l  #1,d0
        tst.l   d0
        beq.s   use_shadow
        move.l  #DSP_RAM_BASE+DEEP_ENTRY,d1
        bra.s   have_pc
use_naive:
        move.l  #DSP_RAM_BASE,d1
        bra.s   have_pc
use_shadow:
        move.l  #DSP_RAM_BASE+SHADOW_ENTRY,d1
have_pc:
        ; (debug) publish the chosen entry point so a harness can see
        ; which schedule ran.
        lea     FLAG_ADDR+12,a0
        move.l  d1,(a0)
        ; D_PC must be written before DSPGO.
        move.l  d1,D_PC
        move.l  #0,D_FLAGS
        move.l  #DSPGO,D_CTRL

; --- keep the bus busy: the 68K is the Jaguar's other co-processor
; and an idle DRAM is not the realistic case.
spin:
        lea     $00021000,a0
        moveq   #0,d0
        move.w  #255,d1
busy:
        move.l  d0,(a0)+
        addq.l  #1,d0
        dbf     d1,busy
        bra.s   spin

; --- the embedded DSP payloads -------------------------------------
; All three are lyxass output with the 12-byte BS94 header already
; stripped (see build.sh) -- raw DSP RISC code.
dsp_code_naive:
        .incbin "benchinterleave_naive_dsp.bin"
dsp_code_naive_end:

dsp_code_shadow:
        .incbin "benchinterleave_shadow_dsp.bin"
dsp_code_shadow_end:

dsp_code_deep:
        .incbin "benchinterleave_deep_dsp.bin"
dsp_code_deep_end:

NAIVE_LEN       .equ    dsp_code_naive_end-dsp_code_naive
SHADOW_LEN      .equ    dsp_code_shadow_end-dsp_code_shadow
DEEP_LEN        .equ    dsp_code_deep_end-dsp_code_deep

        .end
