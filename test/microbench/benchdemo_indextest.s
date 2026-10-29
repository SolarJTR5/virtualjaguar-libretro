; test/microbench/benchdemo_indextest.s -- do the indexed addressing forms
; work at run time?
;
; Two forms are exercised, both reading a table:
;
;   1. move.w TBL(a0),d1    -- absolute-indexed, TBL defined BEFORE the
;                              instruction (a backward reference)
;   2. move.w 0(a1,a0),d2   -- register+register index (a1 = the table,
;                              a0 = the index)
;
; Both should read TBL[0] = $1111.  The results are published in the
; sentinel block:
;
;   $010014  d1 from form 1   -- must be $3333 (TBL[2])
;   $010018  d2 from form 2   -- must be $3333 (TBL[2])
;   $01001C  d1 from a control read: move.w (a1),d1 -- must be $1111 (TBL[0])
;
; The index is 2, not 0, so an index register that is silently dropped
; shows up as $1111 instead of $3333.
;
; This ROM has its own header (not cartboot.inc) so that the table can
; sit BEFORE the entry point -- the entry vector is $802010, which is
; what makes form 1 a backward reference.
                .68000
        .text

MB_SENT_BASE    .equ    $00010000
MB_SENT_START   .equ    MB_SENT_BASE+0
MB_SENT_DONE    .equ    MB_SENT_BASE+4
MB_MAGIC_START  .equ    $C0DE57A7
MB_MAGIC_68K    .equ    $C0DE0068


        dcb.b   $400,0                      ; $800000: BootIntro slot, unused
        dc.l    $04040404                   ; $800400: universal marker
        dc.l    $00802008                   ; $800404: the 68K entry vector
        dc.l    $00000000                   ; $800408
        dcb.b   $2000-$40C,$FF              ; pad to $801FFC
TBL:    dc.w    $1111,$2222,$3333,$4444      ; $802000: TBL (before the entry)

start:
        move.l  #MB_MAGIC_START,MB_SENT_START

        ; --- form 1: absolute-indexed, backward label.
        ;     The index is 2, so a dropped index register shows up:
        ;     TBL[2] = $3333, TBL[0] = $1111.
        move.l  #2,a0
        move.w  TBL(a0),d1
        move.l  #MB_SENT_BASE+20,a2
        move.l  d1,(a2)

        ; --- form 2: register+register index (index 2 as well)
        move.l  #TBL,a1
        move.l  #2,a0
        move.w  0(a1,a0),d2
        move.l  #MB_SENT_BASE+24,a2
        move.l  d2,(a2)

        ; --- control: no index at all -- must equal $1111
        move.l  #TBL,a1
        move.w  (a1),d1
        move.l  #MB_SENT_BASE+28,a2
        move.l  d1,(a2)

        move.l  #MB_MAGIC_68K,MB_SENT_DONE
spin:
        bra.s   spin
