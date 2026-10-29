; test/microbench/benchdemo_stackprobe.s -- pin down the 68000 stack-pointer
; behaviour at the start of a cart program.
;
; WHY THIS EXISTS
; --------------
; A cart program is entered in supervisor mode with A7 = the SSP the boot
; path left in main RAM $0000.  The classic "drop to user mode" idiom is
;
;       move.w  #$0700,sr
;
; which on a 68000 swaps A7 with the *user* stack pointer.  This probe
; records A7 at the two points that matter, so the swap's behaviour is
; measured rather than assumed:
;
;   $010014  A7 at entry (before any SR change)
;   $010018  A7 after `move.w #$0700,sr`   (supervisor -> user)
;   $01001C  the magic a subroutine wrote (proves the jsr reached it)
;   $010020  the return address the subroutine saw via (sp)
;
; The subroutine is called in USER mode and does NOT set A7 itself, so
; if the user stack pointer is bogus the push goes to the wrong place.
;
; Note on the probe's own correctness: MOVESR (`move.w #imm,sr`) is a
; PRIVILEGED instruction, so `move.w #$2700,sr` is illegal in user mode
; and raises a privilege violation (vector 8) instead of returning to
; supervisor mode.  An earlier revision of this probe tried to use it as
; the way back and therefore measured its own fault, not a stack swap.
; There is no legal way back from user mode except RTE.
;
; Branches: this toolchain cannot resolve a forward branch reference, so
; every conditional here is written as a backward loop.
        .68000
        .text
        .include "cartboot.inc"

start:
        move.l  #MB_MAGIC_START,MB_SENT_START

        ; --- A7 at entry
        move.l  a7,d0
        move.l  #MB_SENT_BASE+20,a1
        move.l  d0,(a1)

        ; --- drop to user mode: on a 68000 this swaps A7 with the USER
        ;     stack pointer
        move.w  #$0700,sr

        ; --- A7 now
        move.l  a7,d0
        move.l  #MB_SENT_BASE+24,a1
        move.l  d0,(a1)

        ; --- call a subroutine in user mode (A7 is whatever the swap left)
        jsr     subr

        move.l  #MB_MAGIC_68K,MB_SENT_DONE
spin:
        bra.s   spin

subr:
        move.l  #$00C0DE00,(MB_SENT_BASE+28)
        move.l  (sp),d0
        move.l  d0,(MB_SENT_BASE+32)
        rts
