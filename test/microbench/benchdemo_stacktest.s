; test/microbench/benchdemo_stacktest.s -- does a cart ROM's jsr/rts work?
;
; Minimal probe for the 68000 stack in this core's cart HLE path:
;   * the HLE writes the SSP into RAM[0] but never gives the 68000 a
;     stack pointer, so A7 starts at 0;
;   * a ROM that uses jsr/rts must therefore set A7 itself.
;
; Writes:
;   $010014  A7 as seen at entry (before the ROM sets it)
;   $010018  the value the subroutine wrote (proves jsr/rts worked)
;   $01001C  the return address the subroutine saw (via (sp))
        .68000
        .text
        .include "cartboot.inc"

start:
        move.w  #$0700,sr
        move.l  #MB_MAGIC_START,MB_SENT_START

        move.l  a7,d0
        move.l  #MB_SENT_BASE+20,a1
        move.l  d0,(a1)

        move.l  #$00003FF0,a7

        jsr     subr

        move.l  #MB_MAGIC_68K,MB_SENT_DONE
spin:
        bra.s   spin

subr:
        move.l  #$00C0DE00,(MB_SENT_BASE+24)
        move.l  (sp),d0
        move.l  d0,(MB_SENT_BASE+28)
        rts
