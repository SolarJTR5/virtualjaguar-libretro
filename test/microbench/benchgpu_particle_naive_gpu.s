; test/microbench/benchgpu_particle_naive_gpu.s -- GPU particle
; transform, 1-DEEP / immediate-consume schedule ("naive" member of the
; A/B pair).
;
; This is the control for benchgpu_particle_gpu.s.  The steady-state
; body is the SAME 25 instructions with the SAME operands as the 2-deep
; body, in the SAME number.  The only difference is placement:
;
;   naive : move r8,r29 / mult r28,r29 / move r9,r30 / mult r28,r30
;           sit IMMEDIATELY after `div r1,r28`, so the two MULTs wait
;           on the divider through the scoreboard;
;   deep  : those four instructions sit at the TOP of the next
;           iteration, consuming the quotient produced one iteration
;           earlier, so they never wait.
;
; test/tools/check_particle_permutation.py asserts the two bodies are a
; permutation of each other, so the tick delta between the ROMs is
; attributable to placement alone.
;
; The per-particle math is identical to the deep variant:
;   x += vx ; y += vy ; vx += 1 ; vy += 1 ; q = FIXED/y ;
;   out_x = x*q ; out_y = y*q
; and the input/output buffers are separate ($00020000 / $00030000).

PART_BASE       .equ    $00020000
OUT_BASE        .equ    $00030000
PART_COUNT      .equ    256
FIXED           .equ    65536

MB_SENT_BASE    .equ    $00010000
MB_SENT_DONE    .equ    MB_SENT_BASE+4
MB_SENT_COUNT   .equ    MB_SENT_BASE+8
MB_SENT_VARIANT .equ    MB_SENT_BASE+12
MB_MAGIC_PART   .equ    $C0DE0B01
MB_VARIANT      .equ    2

GPU_CTRL        .equ    $00F02114       ; GPU control register

        .gpu
        .org    $F03200         ; where the 68K bootstrap copies this
        .run

start:
        movei   #PART_BASE,r14
        movei   #OUT_BASE,r15
        moveq   #0,r17
        movei   #PART_COUNT,r31         ; 256 particles, one per iteration
        movei   #FIXED,r18

        load    (r14+0),r4
        load    (r14+4),r5
        load    (r14+8),r6
        load    (r14+12),r7
        addq    #16,r14

        movei   #loop,r13

        ; ---- steady state: the same 25 instructions, permuted --------
loop:
        add     r6,r4
        add     r7,r5
        addq    #1,r6
        addq    #1,r7

        move    r4,r8
        move    r5,r9

        move    r5,r1
        move    r18,r28
        div     r1,r28                  ; quotient requested...

        move    r8,r29                  ; ...and consumed right away, so
        mult    r28,r29                 ; both MULTs stall until the
        move    r9,r30                  ; divider retires
        mult    r28,r30
        store   r29,(r15)
        store   r30,(r15+4)
        addq    #16,r15

        load    (r14+0),r4
        load    (r14+4),r5
        load    (r14+8),r6
        load    (r14+12),r7
        addq    #16,r14

        addq    #1,r17
        cmp     r31,r17
        jump    ne,(r13)
        nop

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
