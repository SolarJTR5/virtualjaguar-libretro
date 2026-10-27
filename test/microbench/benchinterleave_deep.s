; test/microbench/benchinterleave_deep.s -- 2-deep pipeline payload for the
; GPU/DSP interleave microbenchmark.  SHARED SOURCE: assembled twice,
; once per core, with the local-RAM base and the control register
; defined on the command line:
;
;   lyxass -D BASE=$F03000 -D CTRL=$00F02114 -o x_gpu.o  benchinterleave_deep.s
;   lyxass -D BASE=$F1B000 -D CTRL=$00F1A114 -o x_dsp.o  benchinterleave_deep.s
;
; (the RISC has no relocatable code, so the base address is baked in
; -- see the note in the 1-deep payload.) -- GPU-side payload
; for the "interleave vs naive" microbenchmark ROM (task 6): the
; 2-DEEP software pipeline.
;
; What is different from the 1-deep payload
; -----------------------------------------
; The 1-deep schedule is: load vertex N, chain N, divide N, consume N.
; The divide's 16-tick window is then dead time, and the next vertex's
; LOADS cannot go into it -- the MAC chain needs x,y,z the instant it
; starts, so the loads would have to land a full iteration early.
;
; This payload keeps the pipeline two iterations deep, so the window is
; filled with REAL work and the loads land in time:
;
;   iteration k:
;     1. CONSUME the vertex divided in iteration k-1 (its quotient is
;        ready -- a whole iteration has passed);
;     2. CHAIN the vertex whose coords were loaded in iteration k-1 (its
;        data has landed -- a whole iteration has passed);
;     3. DIVIDE the vertex just chained (16 ticks of background work);
;     4. LOAD the coords for the vertex that iteration k+1 will chain;
;     5. the bookkeeping.
;
; So the divide's window contains steps 4 and 5 of iteration k plus step
; 1 of iteration k+1 -- all real work, no filler.  And step 4's loads
; have a full iteration to land before step 2 of iteration k+1 reads
; them.
;
; Only ONE coord set (r4,r5,r6) and ONE result set (r1,r2,r3) are
; needed: the chain (step 2) consumes the coords before the loads
; (step 4) overwrite them, and the consume (step 1) reads the results
; before the chain (step 2) overwrites them.  That is the same
; "disjoint in time" rule the rotating register allocation follows.
;
; The RISC has no relocatable code, so the payload must be assembled for
; the address it will run at ($F03200) -- see the note in the 1-deep
; interleaved payload.

MB_SENT_DONE    .equ    $00010004
MB_SENT_COUNT   .equ    $00010008
MB_MAGIC_ILV    .equ    $C0DE0A03


VERT_BASE       .equ    $00020000       ; the vertex buffer, in main RAM
ITERATIONS      .equ    63              ; vertices consumed (the prologue
                                        ; chains one more)

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

        ; ---------------- the prologue ----------------
        ; V0's coords, then V0's chain, then V0's divide, then V1's
        ; coords -- so that iteration 0 can consume V0 (the quotient is
        ; already in flight) and chain V1 (the coords are already in).
        load    (r14+4),r4            ; V0 x
        load    (r14+8),r5            ; V0 y
        load    (r14+12),r6           ; V0 z
        imultn  r4,r20
        imacn   r5,r21
        imacn   r6,r22
        imacn   r0,r23
        resmac  r1                    ; w of V0
        imultn  r4,r16
        imacn   r5,r17
        imacn   r6,r18
        imacn   r0,r19
        resmac  r2                    ; nx of V0
        imultn  r4,r24
        imacn   r5,r25
        imacn   r6,r26
        imacn   r0,r27
        resmac  r3                    ; ny of V0
        moveq   #1,r28
        div     r1,r28                ; 1/w of V0 -- 16 background ticks
        load    (r14+20),r4           ; V1 x
        load    (r14+24),r5           ; V1 y
        load    (r14+28),r6           ; V1 z
        addq    #16,r14               ; the base now points at V1
        movei   #loop,r13             ; the loop-back address

loop:
        ; --- 1. consume the vertex divided in the previous iteration ---
        move    r2,r29
        mult    r28,r29
        move    r3,r30
        mult    r28,r30
        ; --- 2. chain the vertex whose coords were loaded last iteration ---
        imultn  r4,r20
        imacn   r5,r21
        imacn   r6,r22
        imacn   r0,r23
        resmac  r1                    ; w
        imultn  r4,r16
        imacn   r5,r17
        imacn   r6,r18
        imacn   r0,r19
        resmac  r2                    ; nx
        imultn  r4,r24
        imacn   r5,r25
        imacn   r6,r26
        imacn   r0,r27
        resmac  r3                    ; ny
        ; --- 3. divide this vertex: 16 ticks of background work ---
        moveq   #1,r28
        div     r1,r28
        ; --- 4. load the coords for the vertex the NEXT iteration chains ---
        load    (r14+4),r4
        load    (r14+8),r5
        load    (r14+12),r6
        ; --- 5. the bookkeeping ---
        addq    #16,r14
        addq    #1,r15
        cmp     r31,r15
        jump    ne,(r13)
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
