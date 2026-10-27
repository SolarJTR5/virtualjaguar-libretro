; test/microbench/benchinterleave_shadow.s -- 1-deep interleave payload for the
; GPU/DSP interleave microbenchmark.  SHARED SOURCE: assembled twice,
; once per core, with the local-RAM base and the control register
; defined on the command line:
;
;   lyxass -D BASE=$F03000 -D CTRL=$00F02114 -o x_gpu.o  benchinterleave_shadow.s
;   lyxass -D BASE=$F1B000 -D CTRL=$00F1A114 -o x_dsp.o  benchinterleave_shadow.s
;
; (the RISC has no relocatable code, so the base address is baked in
; -- see the note in the 1-deep payload.) -- GPU-side payload
; for the "interleave vs naive" microbenchmark ROM (task 6): the
; INTERLEAVED schedule.
;
; Identical to benchgpu_interleave_naive_gpu.s except for the block
; between the divide and the consumer.  Here, 16 independent
; instructions are dropped into the divide's 16-tick background window:
;
;   - they are flag-transparent (ADDQT does not touch the flags), so
;     they cannot disturb the primary stream's Z/C/N;
;   - they read ONE register each, so they do not hit the write-back
;     port conflict (R4) -- a two-source ALU op would cost 2 ticks;
;   - they rotate over EIGHT registers, so no two of them touch the
;     same register back to back: the RAW interlock (R2) is one stage
;     deep, so a register reused eight instructions later costs
;     nothing.  (Sixteen ADDQTs on ONE register cost 2 ticks each --
;     measured; the rotation is what makes the shadow free.)
;
; 16 ticks of shadow = exactly the divide's 16-tick window.
;
; r29 and r30 are the consumer's own output registers; the shadow runs
; BEFORE the consumer, so it may borrow them.

MB_SENT_DONE    .equ    $00010004
MB_SENT_COUNT   .equ    $00010008
MB_MAGIC_ILV    .equ    $C0DE0A03


VERT_BASE       .equ    $00020000       ; the vertex buffer, in main RAM
ITERATIONS      .equ    64              ; vertices per run

        .gpu
; The payload is copied byte-for-byte to $F03100 (the 68K bootstrap's
; SHADOW_ENTRY), and its internal addresses -- the loop-back address
; in particular -- are ABSOLUTE.  So it MUST be assembled for the
; address it will run at: assembling it at $F03000 and relocating it
; makes `movei #loop` point into the OTHER payload (measured: the
; interleaved ROM silently ran the naive body and the shadow executed
; exactly once).
        .org    BASE
        .run

start:
        movei   #VERT_BASE,r14        ; the vertex base
        moveq   #0,r15                ; the counter
        movei   #ITERATIONS,r31       ; the limit
        moveq   #1,r0                 ; the constant 1 (the w row's m23)
        ; seed the 3x4 matrix
        moveq   #1,r16
        moveq   #2,r17
        moveq   #3,r18
        moveq   #4,r19
        moveq   #5,r20
        moveq   #6,r21
        moveq   #7,r22
        moveq   #8,r23
        moveq   #9,r24
        moveq   #10,r25
        moveq   #11,r26
        moveq   #12,r27
        movei   #loop,r13             ; the loop-back address

loop:
        ; --- the three loads: EXTERNAL (main RAM), L = 7 + D ---
        load    (r14+4),r4            ; x
        load    (r14+8),r5            ; y
        load    (r14+12),r6           ; z
        ; --- w = m20*x + m21*y + m22*z + m23 ---
        imultn  r4,r20
        imacn   r5,r21
        imacn   r6,r22
        imacn   r0,r23
        resmac  r1
        ; --- nx = m00*x + m01*y + m02*z + m03 ---
        imultn  r4,r16
        imacn   r5,r17
        imacn   r6,r18
        imacn   r0,r19
        resmac  r2
        ; --- ny = m10*x + m11*y + m12*z + m13 ---
        imultn  r4,r24
        imacn   r5,r25
        imacn   r6,r26
        imacn   r0,r27
        resmac  r3
        ; --- the perspective divide: r28 = 1 / w ---
        moveq   #1,r28
        div     r1,r28
        ; --- THE INTERLEAVE: 16 independent instructions in the
        ; divide's background window.  Flag-transparent, one register
        ; read each, rotating over eight registers. ---
        addqt   #1,r7
        addqt   #1,r8
        addqt   #1,r9
        addqt   #1,r10
        addqt   #1,r11
        addqt   #1,r12
        addqt   #1,r29
        addqt   #1,r30
        addqt   #1,r7
        addqt   #1,r8
        addqt   #1,r9
        addqt   #1,r10
        addqt   #1,r11
        addqt   #1,r12
        addqt   #1,r29
        addqt   #1,r30
        ; --- the consumer: the quotient is ready, no wait ---
        move    r2,r29
        mult    r28,r29
        move    r3,r30
        mult    r28,r30
        ; --- the loop ---
        addq    #16,r14               ; the next vertex
        addq    #1,r15                ; the counter
        cmp     r31,r15
        jump    ne,(r13)              ; while r15 != limit
        nop                            ; the delay slot always executes

        ; --- the sentinel: the count first, then the magic ---
        movei   #MB_SENT_COUNT,r13
        store   r15,(r13)
        movei   #MB_MAGIC_ILV,r0
        movei   #MB_SENT_DONE,r13
        store   r0,(r13)
        ; --- park: clear GPUGO so the RISC stops (the tick counters
        ; freeze here, which is what the harness samples) ---
        movei   #CTRL,r13
        moveq   #0,r0
        store   r0,(r13)

halt:
        jr      halt
        nop
        .end
