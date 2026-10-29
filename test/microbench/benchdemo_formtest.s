; test/microbench/benchdemo_formtest.s -- which 68000 instruction forms
; does rmac actually assemble correctly?
;
; The demo ROM needs long moves and table lookups; this ROM executes the
; candidate forms and stores the RESULTS into main RAM, so a harness (or
; gdb) can read what really happened instead of decoding the encoding by
; hand.
;
; The results land at $00130000, one longword per test:
;   +0   move.l #$12345678,d0        (control: the immediate form)
;   +4   move.w d2,a0                after move.w #$2222,d2
;   +8   move.l a3,(a0)              after move.l #RESULT_AREA,a3
;   +12  move.l (a3),d4              then move.l d4,(a4)
;   +16  move.w #$1111,d2 ; move.l d2,a0
;   +20  table lookup: lea TBL,a3 ; move.w 0(a3,a0),d4 ; move.l d4,(a4)
;   +24  the value of a0 after the table lookup
;   +28  the value of d2 after move.w #$2222,d2
;   +32  the value of a0 after lea $00130000,a0
;
; Build: rmac -fb -o benchdemo_formtest.o benchdemo_formtest.s
;         rln  -n -a 800000 x x -o benchdemo_formtest.j64 benchdemo_formtest.o

        .68000
        .text

        .include "cartboot.inc"

RESULT_BASE     .equ    $00130000
RESULT_LO       .equ    (RESULT_BASE&$FFFF)
RESULT_HI       .equ    ((RESULT_BASE>>16)&$FFFF)

; A small table of recognisable words.
TBL_BASE        .equ    $00131000
TBL_LO          .equ    (TBL_BASE&$FFFF)
TBL_HI          .equ    ((TBL_BASE>>16)&$FFFF)

        move.w  #$2700,sr
        move.l  #MB_MAGIC_START,MB_SENT_START

; --- put the lookup table in main RAM (the ROM's own data lives in
; --- CART space, which is a different address space entirely)
        move.l  #TBL_BASE,a5
        move.l  #$22223333,(a5)
        move.l  #$44445555,4(a5)

; --- control: the immediate long form --------------------------------
        move.l  #$12345678,d0
        move.l  #RESULT_BASE,a5
        move.l  d0,(a5)

; --- move.w d2,a0 ---------------------------------------------------
        move.w  #$2222,d2
        move.w  d2,a0
        move.l  #RESULT_BASE+4,a5
        move.l  a0,(a5)

; --- move.l a3,(a0) and move.l (a3),d4 ------------------------------
        move.l  #RESULT_BASE+8,a3
        move.l  #$0000AAAA,d4
        move.l  d4,(a3)
        move.l  (a3),d4
        move.l  #RESULT_BASE+12,a4
        move.l  #RESULT_BASE+12,a5
        move.l  d4,(a5)

; --- move.l #imm,d2 then move.l d2,a0 --------------------------------
        move.l  #$00003333,d2
        move.l  d2,a0
        move.l  #RESULT_BASE+16,a5
        move.l  a0,(a5)

; --- table lookup: lea TBL,a3 ; move.w 0(a3,a0),d4 -------------------
        move.l  #2,a0          ; MOVEQ is Dn-only
        move.l  #TBL_BASE,a3
        move.w  0(a3,a0),d4           ; index 2 -> the low word of $44445555
        move.l  #RESULT_BASE+20,a5
        move.l  d4,(a5)
        move.l  #RESULT_BASE+24,a5
        move.l  a0,(a5)

; --- record the other operands ---------------------------------------
        move.l  #RESULT_BASE+28,a5
        move.l  d2,(a5)
        move.l  #RESULT_BASE+32,a5
        move.l  #RESULT_BASE,(a5)

; --- lea of an absolute address ---------------------------------------
        move.l  #RESULT_BASE+36,a5
        lea     $00130000,a0
        move.l  a0,(a5)
        move.l  #RESULT_BASE+40,a5
        lea     $00131000,a3
        move.l  a3,(a5)

; --- lea with a displacement (the 2x2 block's second row) --------------
        move.l  #RESULT_BASE+44,a5
        move.l  $00130000,a0
        lea     640(a0),a2
        move.l  a2,(a5)
        move.l  #RESULT_BASE+48,a5
        lea     4(a0),a2
        move.l  a2,(a5)

; --- jsr/rts round trip ------------------------------------------------
        move.l  #RESULT_BASE+52,a5
        move.l  #$00C0FFEE,d2
        jsr     subr
        move.l  d2,(a5)

; --- ADD-based displacement (the replacement for lea disp(An),Am) ------
        move.l  #RESULT_BASE+56,a5
        move.l  $00130000,a0
        move.l  a0,a2
        addi.l  #640,a2
        move.l  a2,(a5)
        move.l  #RESULT_BASE+60,a5
        move.l  a0,a2
        addi.l  #4,a2
        move.l  a2,(a5)
        move.l  #RESULT_BASE+64,a5
        move.l  a0,a2
        addq.l  #16,a2
        move.l  a2,(a5)

        move.l  #MB_MAGIC_68K,MB_SENT_DONE
spin:
        bra.s   spin

; a subroutine: d2 = d2 + 1, returned with rts
subr:
        addq.l  #1,d2
        rts

; The table: index 0..3 -> $1111, $2222, $3333, $4444
TBL:
        dc.w    $1111, $2222, $3333, $4444
