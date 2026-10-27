; test/microbench/benchgpu_particle_gpu.s -- GPU particle transform,
; 2-DEEP software pipeline ("deep" member of the A/B pair).
;
; WHAT THIS IS
; ------------
; The particle counterpart of benchinterleave_deep.s: a per-particle
; Euler integration plus a fixed-point perspective divide, run over 256
; particles, with the divide's latency hidden behind the next load.
;
;   per particle k:   x += vx ; y += vy ; vx += 1 ; vy += 1
;                     q  = FIXED / y            (the long operation)
;                     out_x = x * q
;                     out_y = y * q
;
; out_y is therefore ~FIXED for every particle -- a property the
; verification step relies on (see test/tools/particle_reference.py).
;
; INPUT / OUTPUT ARE SEPARATE BUFFERS
; -----------------------------------
; The earlier revision of this benchmark stored the result back through
; the INPUT cursor, so particle k's output landed on particle k+1's x,y
; and was then re-loaded as input.  Live reads of $00020000 showed
; P1=(0,0,5,6) where the 68K had written P1=(3,4,5,6): every particle
; after the first entered the loop with x=y=0.  The loop still produced
; correct tick counts (same instruction stream, same addresses), but it
; was not computing a particle simulation.  r14 now walks the input
; buffer and r15 walks a distinct output buffer at $00030000.
;
; THE A/B PAIR
; ------------
; benchgpu_particle_naive_gpu.s runs the SAME 25 instructions per
; particle with the SAME operands, in the SAME number, differing ONLY in
; where the two MULTs sit relative to the DIV:
;
;   deep  : MULTs at the top of the body consume the quotient produced
;           in the PREVIOUS iteration (r28 plus the saved numerands in
;           r8,r9), so they never wait on the divider;
;   naive : MULTs immediately follow the DIV, so the scoreboard stalls
;           until the divider has finished.
;
; test/tools/check_particle_permutation.py decodes both assembled blobs
; and proves the per-iteration instruction multisets are identical, so
; any tick difference between the two ROMs is placement and nothing
; else.
;
; REGISTER ROLES
; --------------
;   r14  input cursor          r15  output cursor
;   r17  iteration counter     r31  iteration limit
;   r18  FIXED (65536)         r13  loop-back address
;   r4..r7   current particle: x, y, vx, vy
;   r8,r9    the numerands (x,y) saved for the NEXT iteration's consume
;   r1       divider divisor input
;   r28      quotient (FIXED / y), consumed one iteration later
;   r29,r30  the two projected outputs
;
; Assembled with lyxass for the address it runs at (the RISC has no
; relocatable code): the 68K bootstrap copies this blob to $F03200.
; The base is baked in below, so test/microbench/build.sh's generic
; *_gpu.s pass can assemble this with no -D on the command line.

PART_BASE       .equ    $00020000       ; input: 256 particles, 16 B each
OUT_BASE        .equ    $00030000       ; output: same shape, 68K-cleared
PART_COUNT      .equ    256
FIXED           .equ    65536           ; 16.16 fixed-point 1.0

MB_SENT_BASE    .equ    $00010000
MB_SENT_DONE    .equ    MB_SENT_BASE+4
MB_SENT_COUNT   .equ    MB_SENT_BASE+8
MB_SENT_VARIANT .equ    MB_SENT_BASE+12  ; 1 = deep, 2 = naive
MB_MAGIC_PART   .equ    $C0DE0B01
MB_VARIANT      .equ    1

GPU_CTRL        .equ    $00F02114       ; GPU control register

        .gpu
        .org    $F03200         ; where the 68K bootstrap copies this
        .run

start:
        movei   #PART_BASE,r14
        movei   #OUT_BASE,r15
        moveq   #0,r17
        movei   #PART_COUNT-1,r31      ; 255 steady-state iterations
        movei   #FIXED,r18

        ; ---- prologue: P0 is integrated and divided here -------------
        load    (r14+0),r4             ; P0 x
        load    (r14+4),r5             ; P0 y
        load    (r14+8),r6             ; P0 vx
        load    (r14+12),r7            ; P0 vy
        addq    #16,r14

        add     r6,r4                  ; x += vx
        add     r7,r5                  ; y += vy
        addq    #1,r6                  ; vx += 1
        addq    #1,r7                  ; vy += 1

        move    r4,r8                  ; numerands for iteration 0's consume
        move    r5,r9

        move    r5,r1
        move    r18,r28
        div     r1,r28                 ; q0 = FIXED / y0  (in flight)

        ; ---- load P1 so iteration 0 has real work to pipeline --------
        load    (r14+0),r4
        load    (r14+4),r5
        load    (r14+8),r6
        load    (r14+12),r7
        addq    #16,r14

        movei   #loop,r13

        ; ---- steady state: 25 instructions, DIV window filled --------
loop:
        move    r8,r29                 ; consume the quotient from the
        mult    r28,r29                ; previous iteration (already
        move    r9,r30                 ; ready -- no scoreboard stall)
        mult    r28,r30
        store   r29,(r15)
        store   r30,(r15+4)
        addq    #16,r15

        add     r6,r4                  ; integrate the current particle
        add     r7,r5
        addq    #1,r6
        addq    #1,r7

        move    r4,r8                  ; save its numerands for next time
        move    r5,r9

        move    r5,r1
        move    r18,r28
        div     r1,r28                 ; 16 background ticks...

        load    (r14+0),r4             ; ...filled with the next particle's
        load    (r14+4),r5             ; loads, which have a full
        load    (r14+8),r6             ; iteration to land
        load    (r14+12),r7
        addq    #16,r14

        addq    #1,r17
        cmp     r31,r17
        jump    ne,(r13)
        nop

        ; ---- epilogue: consume P255 ---------------------------------
        move    r8,r29
        mult    r28,r29
        move    r9,r30
        mult    r28,r30
        store   r29,(r15)
        store   r30,(r15+4)

        addq    #1,r17                 ; 255 loop + 1 epilogue = 256
        movei   #MB_SENT_COUNT,r13
        store   r17,(r13)
        movei   #MB_VARIANT,r0
        movei   #MB_SENT_VARIANT,r13
        store   r0,(r13)
        movei   #MB_MAGIC_PART,r0
        movei   #MB_SENT_DONE,r13
        store   r0,(r13)
        movei   #GPU_CTRL,r13
        moveq   #0,r0
        store   r0,(r13)
halt:
        jr      halt
        nop
        .end
