; test/microbench/benchdemo_acid.s -- a faithful port of the acid
; test's 16-bpp BITMAP scenario (test/acid/tests/op/op_bitmap_render.s),
; so the "does the OP put 16-bit pixels into the line buffer at all?"
; question can be answered without vasm (which this box does not have).
;
; The acid test's object, verbatim:
;   p0 = $060000A0 / $02FFC000   type=0, ypos=0, height=$3FF,
;                               link=$50010, data=$60000
;   p1 = $00000000 / $10004000   xpos=0, depth=4 (16bpp), pitch=1,
;                               dwidth=1, iwidth=1
; and its source pixels at $60000: 12 34 56 78 9A BC DE F0.
;
; The acid test checks the line buffer at $F01800 for exactly those bytes
; after one OP pass.  This ROM does the same thing from the 68K side: it
; reads $F01800 back and parks it in the sentinel block, where a host
; debugger (or the probe tool) can see it.
;
; Build: rmac -fb -o benchdemo_acid.o benchdemo_acid.s
;         rln  -n -a 800000 x x -o benchdemo_acid.j64 benchdemo_acid.o

        .68000
        .text

        .include "cartboot.inc"

TOM_OLP_LO     .equ    $00F00020
TOM_OLP_HI     .equ    $00F00022
TOM_VC         .equ    $00F00006
TOM_VMODE      .equ    $00F00028
TOM_VDB        .equ    $00F00046
TOM_VDE        .equ    $00F00048
TOM_LBUF       .equ    $00F01800

LIST_BASE      .equ    $00050000
LIST_BASE_LO   .equ    (LIST_BASE&$FFFF)
LIST_BASE_HI   .equ    ((LIST_BASE>>16)&$FFFF)
BMP_OBJ        .equ    LIST_BASE+0
STOP_OBJ       .equ    LIST_BASE+16
SRC_BASE       .equ    $00060000

; the acid test's object, verbatim
ACID_P0_HI     .equ    $060000A0
ACID_P0_LO     .equ    $02FFC000
ACID_P1_HI     .equ    $00000000
ACID_P1_LO     .equ    $10004000
ACID_STOP_HI   .equ    $00000000
ACID_STOP_LO   .equ    $00000004

; where the LBUF readback lands
LBUF_SNAP      .equ    $00110000   ; NOT the sentinel block ($00100000)

start:
        move.w  #$2700,sr

        move.l  #MB_MAGIC_START,MB_SENT_START

        move.w  #$06C1,TOM_VMODE
        move.w  #38,TOM_VDB
        move.w  #518,TOM_VDE

        ; the source pixels
        lea     SRC_BASE,a0
        move.l  #$78563412,(a0)        ; bytes 12 34 56 78
        move.l  #$F0DEBC9A,4(a0)       ; bytes 9A BC DE F0

        ; the object list
        move.l  #ACID_P0_HI,BMP_OBJ
        move.l  #ACID_P0_LO,BMP_OBJ+4
        move.l  #ACID_P1_HI,BMP_OBJ+8
        move.l  #ACID_P1_LO,BMP_OBJ+12
        move.l  #ACID_STOP_HI,STOP_OBJ
        move.l  #ACID_STOP_LO,STOP_OBJ+4

        move.w  #LIST_BASE_LO,TOM_OLP_LO
        move.w  #LIST_BASE_HI,TOM_OLP_HI

        ; read the line buffer while the OP is drawing: VC 100 is an even
        ; halfline, so the OP has just drawn that line.
waitvc:
        move.w  TOM_VC,d0
        andi.w  #$07FF,d0
        cmpi.w  #100,d0
        blt.s   waitvc

        lea     LBUF_SNAP,a0
        move.w  TOM_LBUF,d1
        move.l  d1,(a0)+
        move.w  TOM_LBUF+2,d1
        move.l  d1,(a0)+
        move.w  TOM_LBUF+4,d1
        move.l  d1,(a0)+
        move.w  TOM_LBUF+6,d1
        move.l  d1,(a0)+

        move.l  #MB_MAGIC_68K,MB_SENT_DONE
spin:
        bra.s   spin
