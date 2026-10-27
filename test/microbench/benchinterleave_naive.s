; test/microbench/benchinterleave_naive.s -- naive payload for the
; GPU/DSP interleave microbenchmark.  SHARED SOURCE: assembled twice,
; once per core, with the local-RAM base and the control register
; defined on the command line:
;
;   lyxass -D BASE=$F03000 -D CTRL=$00F02114 -o x_gpu.o  benchinterleave_naive.s
;   lyxass -D BASE=$F1B000 -D CTRL=$00F1A114 -o x_dsp.o  benchinterleave_naive.s
;
; (the RISC has no relocatable code, so the base address is baked in
; -- see the note in the 1-deep payload.) -- GPU-side payload
; for the "interleave vs naive" microbenchmark ROM (task 6).
;
; Assembled with lyxass (the GPU RISC has its own ISA).  The 12-byte
; BS94 header is stripped by build.sh and the raw code is .incbin'd by
; the 68K bootstrap (benchgpu_interleave.s).
;
; WHAT IT MEASURES
; ----------------
; A software-pipelined 3D vertex transform, the shape a Jaguar game
; would use to use the GPU as a maths co-processor while the Object
; Processor and the blitter draw:
;
;   - three dot products through the MAC unit (IMULTN + 3x IMACN +
;     RESMAC each): w, nx, ny from a 3x4 matrix;
;   - a perspective divide (DIV): the LONG operation.  The divider is a
;     separate array: 1 tick to issue, 16 ticks of background work, and
;     only a READER of the quotient stalls (R15);
;   - the perspective multiplies and the screen-coordinate results.
;
; The vertex data lives in MAIN RAM ($020000), so the three loads per
; vertex are EXTERNAL accesses (L = 7 + D ticks) -- the second long
; operation, and the one the bus arbiter charges for real.
;
; This is the NAIVE schedule: the quotient is consumed immediately
; after the divide, so the divide's 16-tick window is exposed as a
; scoreboard stall.  The companion payload
; (benchgpu_interleave_shadow_gpu.s) is the same program with 16
; independent instructions dropped into that window.
;
; The two payloads are IDENTICAL except for the block between the
; divide and the consumer.  That is the whole point of the benchmark:
; same work, different placement.
;
; REGISTERS
;   r0  = 1                     r1  = w          r2  = nx        r3  = ny
;   r4,r5,r6 = x,y,z (loaded)   r13 = the loop address
;   r14 = the vertex base       r15 = the counter
;   r16..r27 = the 3x4 matrix   r28 = 1/w        r29 = screen x   r30 = screen y
;   r31 = the iteration limit
;
; The vector data is 4 long words per vertex (x, y, z, spare) so the
; indexed load (R14+n) can walk it: the base advances 16 bytes per
; vertex and the three loads use n = 1, 2, 3.

MB_SENT_DONE    .equ    $00010004
MB_SENT_COUNT   .equ    $00010008
MB_MAGIC_ILV    .equ    $C0DE0A03


VERT_BASE       .equ    $00020000       ; the vertex buffer, in main RAM
ITERATIONS      .equ    64              ; vertices per run

        .gpu
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
        ; 1 tick to issue, 16 ticks of background divide, and only a
        ; reader of r28 stalls.
        moveq   #1,r28
        div     r1,r28
        ; --- THE NAIVE PART: consume the quotient at once ---
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
