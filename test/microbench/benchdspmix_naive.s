; test/microbench/benchdspmix_naive.s -- the DSP audio-mix payload for the
; benchdsp_mix.j64 ROM, in its 1-DEEP (naive) form.
;
; SHARED SOURCE: assembled once per core and once per slot, because the
; RISC has no relocatable code -- the local-RAM base and the control
; register are baked in at assembly time:
;
;   lyxass -D BASE=$F03000 -D CTRL=$00F02114 -o x_gpu.o benchdspmix_naive.s
;   lyxass -D BASE=$F1B000 -D CTRL=$00F1A114 -o x_dsp.o benchdspmix_naive.s
;
; THE WORKLOAD
; -----------
; One sample of a 4-voice mix, then the sample is PUBLISHED to the DAC.
; Per voice:
;   - read the voice's envelope from MAIN RAM -- an EXTERNAL access, and
;     the slow one (JERRY reaches external memory over a 16-bit bus);
;   - read the wavetable entry (the DSP's local RAM -- fast);
;   - a 2-tap MAC filter over it (IMULTN + IMACN + RESMAC -- the DSP's
;     40-bit accumulator);
;   - multiply by the envelope (the volume) and accumulate into the left
;     and right sums (the pan).
; Then the publish: the two sums go to LTXD and RTXD.
;
; WHY THE PUBLISH IS THE POINT
; ----------------------------
; On a real Jaguar the I2S interrupt fires when the DAC wants a sample
; and the DSP's ISR writes LTXD/RTXD.  There is no FIFO: an unfinished
; sample cannot be held back, it has to be FINISHED IN TIME.  So the
; number that matters is "ticks per published sample" against the I2S
; sample period.
;
; THIS FORM: 1-DEEP (the naive schedule)
; -------------------------------------
; The voice's envelope read is issued and then immediately used, so its
; latency is exposed as a stall.  benchdspmix_deep.s is the same program
; with the NEXT voice's envelope read issued at the top of the voice
; loop, so the external read's latency is covered by the voice's own
; work instead of stalling it.  Only the voice loop differs; the sample
; loop and the publish are identical.
;
; The RISC has no relocatable code, so this payload must be assembled
; for the address it runs at (BASE / CTRL come from the command line:
;   lyxass -D BASE=$F1B000 -D CTRL=$00F1A114 ...).

MB_SENT_DONE    .equ    $00010004
MB_SENT_COUNT   .equ    $00010008
MB_MAGIC_MIX    .equ    $C0DE0A04

; CTRL (the D_CTRL register) comes from the command line: -D CTRL=$00F1A114
LTXD            .equ    $00F1A148       ; the left-channel transmit data
RTXD            .equ    $00F1A14C       ; the right-channel transmit data

WT_BASE         .equ    $00F1B400       ; the wavetable (DSP local RAM)
ENV_BASE        .equ    $00020000       ; the envelopes (MAIN RAM -- external!)
ENV_STRIDE      .equ    1024            ; one DRAM page per voice
MIX_VOICES      .equ    4
SAMPLES         .equ    64              ; samples published

        .gpu
        .org    BASE
        .run

start:
        moveq   #0,r1             ; the sample counter
        movei   #SAMPLES,r2       ; the limit
        moveq   #0,r3             ; the published count
        movei   #WT_BASE,r11      ; the wavetable pointer
        moveq   #1,r13            ; the right pan
        movei   #32768,r18        ; the filter's c0 (0.5 in 16.16)
        movei   #16384,r19        ; the filter's c1 (0.25)
        movei   #ENV_STRIDE,r22   ; the envelope stride (one DRAM page)
        movei   #sample_loop,r17  ; the sample loop's back address

sample_loop:
        moveq   #0,r7             ; the left sum
        moveq   #0,r8             ; the right sum
        movei   #ENV_BASE,r15     ; the envelope pointer
        moveq   #0,r9             ; the voice counter
        moveq   #MIX_VOICES,r10   ; the voice limit
        movei   #voice_loop,r14   ; the voice loop's back address

voice_loop:
        ; --- the voice's envelope: an EXTERNAL read (MAIN RAM) ---
        load    (r15),r4
        add     r22,r15            ; the next voice is a page away
        ; --- the wavetable entry (local RAM, fast) ---
        load    (r11),r5
        ; --- the 2-tap MAC filter (the DSP's 40-bit accumulator) ---
        imultn  r5,r18
        imacn   r16,r19
        resmac  r6
        ; --- the volume, the pan, the accumulates ---
        move    r6,r5
        mult    r4,r5             ; the volume
        add     r5,r7             ; the left sum
        move    r6,r5
        mult    r13,r5            ; the pan (right)
        add     r5,r8             ; the right sum
        move    r4,r16            ; the filter's history tap
        addq    #1,r9
        cmp     r10,r9
        jump    ne,(r14)
        nop                            ; the delay slot always executes

        ; --- PUBLISH: the sample goes to the DAC ---
        movei   #LTXD,r5
        storew  r7,(r5)
        movei   #RTXD,r5
        storew  r8,(r5)
        addq    #1,r3             ; the published count

        ; --- the next sample ---
        addq    #4,r11            ; the wavetable pointer advances
        addq    #1,r1
        cmp     r2,r1
        jump    ne,(r17)
        nop                            ; the delay slot always executes

        ; --- the sentinel: the count first, then the magic ---
        movei   #MB_SENT_COUNT,r5
        store   r3,(r5)
        movei   #MB_MAGIC_MIX,r0
        movei   #MB_SENT_DONE,r5
        store   r0,(r5)
        ; --- park: clear DSPGO so the RISC stops (the tick counters
        ; freeze here, which is what the harness samples) ---
        movei   #CTRL,r5
        moveq   #0,r0
        store   r0,(r5)

halt:
        jr      halt
        nop
        .end
