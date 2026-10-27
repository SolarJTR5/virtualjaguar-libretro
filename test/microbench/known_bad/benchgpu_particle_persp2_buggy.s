MB_SENT_DONE    .equ    $00010004
MB_SENT_COUNT   .equ    $00010008
MB_MAGIC_PART   .equ    $C0DE0B01
PART_BASE       .equ    $00020000
PART_COUNT      .equ    256

        .gpu
        .org    $F03200
        .run

start:
        movei   #PART_BASE,r14
        moveq   #0,r15
        movei   #PART_COUNT,r31
        moveq   #1,r0
        ; Prologue: load P0 coords into r4,r5,r6,r7
        load    (r14+4),r4
        load    (r14+8),r5
        load    (r14+12),r6
        load    (r14),r7
        ; Integrate P0
        add     r6,r4
        add     r7,r5
        addq    #1,r6
        addq    #1,r7
        move    r5,r1
        moveq   #1,r28
        div     r1,r28
        ; Load P1 coords
        load    (r14+20),r4
        load    (r14+24),r5
        load    (r14+28),r6
        load    (r14+16),r7
        addq    #16,r14
        movei   #loop,r13

loop:
        ; 1. Consume P0 result
        move    r4,r29
        mult    r28,r29
        move    r5,r30
        mult    r28,r30
        store   r29,(r14)
        store   r30,(r14+4)
        ; 2. Integrate P1 (current coords in r4,r5,r6,r7)
        add     r6,r4
        add     r7,r5
        addq    #1,r6
        addq    #1,r7
        ; 3. Divide P1
        move    r5,r1
        moveq   #1,r28
        div     r1,r28
        ; 4. Load P2
        load    (r14+4),r4
        load    (r14+8),r5
        load    (r14+12),r6
        load    (r14),r7
        ; 5. Bookkeeping
        addq    #16,r14
        addq    #1,r15
        cmp     r31,r15
        jump    ne,(r13)
        nop
        movei   #MB_SENT_COUNT,r13
        store   r15,(r13)
        movei   #MB_MAGIC_PART,r0
        movei   #MB_SENT_DONE,r13
        store   r0,(r13)
        movei   #$00F02114,r13
        moveq   #0,r0
        store   r0,(r13)
halt:
        jr      halt
        nop
        .end
