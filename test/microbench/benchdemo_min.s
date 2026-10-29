; test/microbench/benchdemo_min.s -- the smallest ROM that puts a
; picture on the Jaguar screen.
;
; Everything the video path needs and nothing else:
;   1. program VMODE/VDB/VDE (the core recomputes its display geometry
;      only when a register in $28..$4F is WRITTEN);
;   2. build one BITMAP object covering the whole 320x240 screen in
;      16-bit RGB;
;   3. point TOM's OLP at the object list;
;   4. fill the framebuffer with one colour;
;   5. spin.
;
; No field sync, no re-arm, no loops beyond the fill: if this shows a
; solid colour, the OP->line-buffer->host path is intact and whatever
; else is broken is the field sync.
;
; Build: rmac -fb -o benchdemo_min.o benchdemo_min.s
;         rln  -n -a 800000 x x -o benchdemo_min.j64 benchdemo_min.o

        .68000
        .text

        .include "cartboot.inc"

TOM_OLP_LO     .equ    $00F00020
TOM_OLP_HI     .equ    $00F00022
TOM_VMODE      .equ    $00F00028
TOM_VDB        .equ    $00F00046
TOM_VDE        .equ    $00F00048

SCR_W          .equ    320
SCR_H          .equ    240

FB_BASE        .equ    $00030000
LIST_BASE      .equ    $00020000
LIST_BASE_LO   .equ    (LIST_BASE&$FFFF)
LIST_BASE_HI   .equ    ((LIST_BASE>>16)&$FFFF)
BMP_OBJ        .equ    LIST_BASE+0
STOP_OBJ       .equ    LIST_BASE+16

; p0: type=0 (BITMAP), ypos=0, height=240, link=STOP_OBJ, data=FB_BASE
BMP_P0_HI      .equ    $03000040
BMP_P0_LO      .equ    $023C0000
; p1: xpos=0, depth=4 (16bpp), pitch=1 phrase, dwidth=640, iwidth=80
BMP_P1_HI      .equ    $00000005
BMP_P1_LO      .equ    $0140C000
STOP_P0_HI     .equ    $00000000
STOP_P0_LO     .equ    $00000004

start:
        move.w  #$2700,sr
        move.l  #MB_MAGIC_START,MB_SENT_START

        move.w  #$06C1,TOM_VMODE
        move.w  #38,TOM_VDB
        move.w  #518,TOM_VDE

        move.l  #BMP_P0_HI,BMP_OBJ
        move.l  #BMP_P0_LO,BMP_OBJ+4
        move.l  #BMP_P1_HI,BMP_OBJ+8
        move.l  #BMP_P1_LO,BMP_OBJ+12
        move.l  #STOP_P0_HI,STOP_OBJ
        move.l  #STOP_P0_LO,STOP_OBJ+4

        move.w  #LIST_BASE_LO,TOM_OLP_LO
        move.w  #LIST_BASE_HI,TOM_OLP_HI

        ; fill the framebuffer with a solid colour
        lea     FB_BASE,a0
        move.w  #(SCR_H-1),d1           ; rows
        move.w  #$8001,d2
row:
        move.w  #(SCR_W-1),d3           ; words per row
inner:
        move.w  d2,(a0)+
        dbra    d3,inner
        dbra    d1,row

        ; Read the line buffer WHILE the OP is drawing: VC 100 is an
        ; even halfline, so the OP has just drawn line 100 into it.
        move.w  #0,d0
wait:
        move.w  $00F00006,d0            ; VC
        andi.w  #$07FF,d0
        cmpi.w  #100,d0
        blt.s   wait

        ; read the line buffer back: did the OP put anything there?
        move.l  #MB_SENT_BASE+16,a0
        move.w  $00F01800,d1
        move.l  d1,(a0)+
        move.w  $00F01802,d1
        move.l  d1,(a0)+
        move.w  $00F01804,d1
        move.l  d1,(a0)+
        move.w  $00F01806,d1
        move.l  d1,(a0)+

        move.l  #MB_MAGIC_68K,MB_SENT_DONE
spin:
        bra.s   spin
