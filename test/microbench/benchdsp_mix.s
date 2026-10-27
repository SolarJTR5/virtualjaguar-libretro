; test/microbench/benchdsp_mix.s -- 68K bootstrap for the DSP audio-mix
; microbenchmark ROM (task 8): benchdsp_mix.j64.
;
; WHAT IT MEASURES
; ----------------
; "Can the DSP's mix keep ahead of the I2S?"  On a real Jaguar the I2S
; interrupt fires when the DAC wants a sample and the DSP's ISR writes
; LTXD/RTXD.  There is no FIFO: an unfinished sample cannot be held
; back, it has to be FINISHED IN TIME.  So the number that matters is
; the ticks per PUBLISHED sample against the I2S sample period:
;
;   sample_rate = system_clock / (64 * (SCLK + 1))
;   sample period in RISC ticks = 64 * (SCLK + 1)
;
; so at SCLK = 8 the period is 576 ticks (46.2 kHz) and at the
; emulator's default SCLK = 19 it is 1280 ticks (20.8 kHz).
;
; The ROM mixes 4 voices per sample and publishes each sample to the
; DAC.  Both schedules (1-deep and 2-deep) are carried in the ROM and
; one is picked at run time from the flag the harness writes into main
; RAM.
;
; The 68K's jobs:
;   1. write the START sentinel;
;   2. build the wavetable in the DSP's LOCAL RAM ($F1B400);
;   3. build the envelopes in MAIN RAM ($020000, one DRAM page per
;      voice) -- so the envelope reads are EXTERNAL accesses, the slow
;      ones (JERRY reaches external memory over a 16-bit bus);
;   4. copy both DSP payloads into DSP local RAM at $F1B000 (naive) and
;      $F1B200 (2-deep);
;   5. read the schedule flag from main RAM and start the DSP at the
;      matching entry;
;   6. keep the bus busy (the 68K is the Jaguar's other co-processor).
;
; The schedule flag lives at $021000 in main RAM and is written by the
; HARNESS before the run (test/tools/test_microbench_dsp_mix.c).  It is
; read by the 68K as a longword, and the Jaguar is big-endian, so the
; harness must write it big-endian.
;
;   0 = the 1-deep schedule (the envelope read is used immediately, so
;       its latency is exposed),
;   2 = the 2-deep schedule (the NEXT voice's envelope read is issued
;       at the top of the voice loop, so the latency is covered by the
;       voice's own work).
;
; $021000 and not $020800: the four envelopes occupy $020000-$020FFF
; (a DRAM page each), so the flag has to live above them.
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
WT_BASE         .equ    $00F1B400       ; the wavetable (DSP local RAM)
WT_SAMPLES      .equ    64              ; one entry per published sample
ENV_BASE        .equ    $00020000       ; the envelopes (main RAM)
ENV_STRIDE      .equ    1024            ; one DRAM page per voice
MIX_VOICES      .equ    4
FLAG_ADDR       .equ    $00021000       ; the schedule flag, written by the harness
DEEP_ENTRY      .equ    $00000200       ; the 2-deep payload's offset

start:
        ; Mask every interrupt level (same rationale as the other ROMs:
        ; the HLE BIOS leaves the video/timer IRQs live and 68K ISR
        ; cycles would only add noise).
        move.w  #$2700,sr

        ; "the cart booted"
        move.l  #MB_MAGIC_START,MB_SENT_START

        ; --- build the wavetable in the DSP's local RAM ---
        ; The DSP reads it with a LOCAL load: 3 ticks of latency, no
        ; bus transaction.  It is the ENVELOPE in main RAM that costs
        ; the external round trip.
        lea     WT_BASE,a0
        moveq   #0,d0
        move.w  #WT_SAMPLES-1,d1
wtfill:
        move.l  d0,(a0)+
        addq.l  #1,d0
        dbf     d1,wtfill

        ; --- build the envelopes in main RAM: one DRAM page per voice ---
        ; A page each, so the four reads walk four different DRAM rows
        ; -- the realistic case for a mixer with per-voice parameter
        ; blocks, and the case where the external read is slowest.
        lea     ENV_BASE,a0
        moveq   #1,d2                    ; the envelope (the volume)
        move.w  #MIX_VOICES-1,d1
envfill:
        move.l  d2,(a0)
        addq.l  #1,d2
        adda.l  #ENV_STRIDE,a0           ; the next voice is a page away
        dbf     d1,envfill

        ; --- copy the 1-DEEP payload into DSP local RAM at $F1B000 ---
        lea     dsp_code_naive(pc),a0
        movea.l #DSP_RAM_BASE,a1
        move.w  #NAIVE_LEN-1,d0
ncopy:
        move.b  (a0)+,(a1)+
        dbf     d0,ncopy

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
        move.l  #DSP_RAM_BASE+DEEP_ENTRY,d1
        bra.s   have_pc
use_naive:
        move.l  #DSP_RAM_BASE,d1
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
; and an idle DRAM is not the realistic case.  $022000 is well clear of
; the envelopes ($020000-$020FFF) and of the flag ($021000).
spin:
        lea     $00022000,a0
        moveq   #0,d0
        move.w  #255,d1
busy:
        move.l  d0,(a0)+
        addq.l  #1,d0
        dbf     d1,busy
        bra.s   spin

; --- the embedded DSP payloads -------------------------------------
; Both are lyxass output with the 12-byte BS94 header already stripped
; (see build.sh) -- raw DSP RISC code.  They are assembled FOR THE
; ADDRESS THEY RUN AT, because the RISC has no relocatable code.
dsp_code_naive:
        .incbin "benchdspmix_naive_dsp.bin"
dsp_code_naive_end:

dsp_code_deep:
        .incbin "benchdspmix_deep_dsp.bin"
dsp_code_deep_end:

NAIVE_LEN       .equ    dsp_code_naive_end-dsp_code_naive
DEEP_LEN        .equ    dsp_code_deep_end-dsp_code_deep

        .end
