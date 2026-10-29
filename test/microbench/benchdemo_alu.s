; test/microbench/benchdemo_alu.s -- a register-register ALU conformance
; probe for the 68000 assembler in use (rmac).
;
; WHY THIS EXISTS
; ---------------
; The toolchain is vendored outside this repository (see
; tools/jaguar-toolchain/PIN), so the assembler that builds these ROMs
; is not under this repo's control -- and it can be wrong in ways that
; no diagnostic catches.  A local, uncommitted edit to rmac's machine
; table (68k.mch) once changed the AND opcode from $C to $B, so every
; `and.l Dn,Dm` assembled as `cmp.l Dn,Dm`: a silent, well-formed,
; completely wrong instruction.  Nothing in the build reported it.
;
; This ROM is the tripwire.  It runs a fixed list of register-register
; ALU forms with known operands and publishes every result in the
; sentinel block, so test/tools/test_demo_alu.c can compare them
; against the 68000's documented results.  A mis-assembled mnemonic
; changes a result and the test fails; it does not need a debugger.
;
; The expected values live in the *tool*, not here: they come from the
; 68000 instruction set, not from this emulator, so the tool is an
; independent check of the assembler (and of the core's execution of
; those forms).
;
; SENTINELS (main RAM $010000+)
;   $010000  START magic
;   $010004  DONE magic (written once every case has run)
;   $010014+ the results, one 32-bit word per case, in the order of
;            the CASE table below
;
; ASSEMBLER CONSTRAINTS
; ---------------------
; rmac cannot resolve a forward branch reference, so the cases are
; straight-line code with no branches.  The register+register index form
; and the absolute-indexed form are mis-assembled by rmac, so no
; addressing mode is used here beyond the plain (An) form.
        .68000
        .text

MB_SENT_BASE    .equ    $00010000
MB_SENT_START   .equ    MB_SENT_BASE+0
MB_SENT_DONE    .equ    MB_SENT_BASE+4
MB_MAGIC_START  .equ    $C0DE57A7
MB_MAGIC_68K    .equ    $C0DE0068

; The result words start at $010014 and follow each other.
MB_RESULTS      .equ    MB_SENT_BASE+20

        dcb.b   $400,0                      ; $800000: the BootIntro slot
        dc.l    $04040404                   ; $800400: the universal marker
        dc.l    $00802000                   ; $800404: the 68K entry vector
        dc.l    $00000000                   ; $800408
        dcb.b   $2000-$40C,$FF              ; pad to $801FFC

start:
        move.l  #MB_MAGIC_START,MB_SENT_START
        move.w  #$2700,sr                  ; supervisor mode, interrupts off
        move.l  #$00060000,a7              ; the stack, above the framebuffer
        move.l  #MB_RESULTS,a3             ; a3 walks the result words

        ; --- case 1: add.l d3,d2   (5 + 10 = 15)
        move.l  #5,d3
        move.l  #10,d2
        add.l   d3,d2
        move.l  d2,(a3)
        addq.l  #4,a3

        ; --- case 2: sub.l d3,d2   (10 - 5 = 5)
        move.l  #5,d3
        move.l  #10,d2
        sub.l   d3,d2
        move.l  d2,(a3)
        addq.l  #4,a3

        ; --- case 3: sub.l d0,d2   (10 - 7 = 3)
        move.l  #7,d0
        move.l  #10,d2
        sub.l   d0,d2
        move.l  d2,(a3)
        addq.l  #4,a3

        ; --- case 4: and.l d0,d3   ($FFFF0000 & $FFFFFFFF)
        move.l  #$FFFFFFFF,d0
        move.l  #$FFFF0000,d3
        and.l   d0,d3
        move.l  d3,(a3)
        addq.l  #4,a3

        ; --- case 5: and.l d0,d3 with a zero mask (the case that caught
        ;     the $C -> $B opcode edit: as CMP it leaves d3 alone)
        move.l  #0,d0
        move.l  #$FFFF0000,d3
        and.l   d0,d3
        move.l  d3,(a3)
        addq.l  #4,a3

        ; --- case 6: or.l d0,d3
        move.l  #$0F0F0F0F,d0
        move.l  #$FFFF0000,d3
        or.l    d0,d3
        move.l  d3,(a3)
        addq.l  #4,a3

        ; --- case 7: eor.l d0,d3
        move.l  #$FFFFFFFF,d0
        move.l  #$FFFF0000,d3
        eor.l   d0,d3
        move.l  d3,(a3)
        addq.l  #4,a3

        ; --- case 8: and.l d1,d2
        move.l  #$00FF00FF,d1
        move.l  #$FFFFFFFF,d2
        and.l   d1,d2
        move.l  d2,(a3)
        addq.l  #4,a3

        ; --- case 9: add.l d2,d3
        move.l  #5,d2
        move.l  #7,d3
        add.l   d2,d3
        move.l  d3,(a3)
        addq.l  #4,a3

        ; --- case 10: neg.l d0
        move.l  #5,d0
        neg.l   d0
        move.l  d0,(a3)
        addq.l  #4,a3

        ; --- case 11: not.l d0
        move.l  #0,d0
        not.l   d0
        move.l  d0,(a3)
        addq.l  #4,a3

        ; --- case 12: addq.l #1,d2
        move.l  #10,d2
        addq.l  #1,d2
        move.l  d2,(a3)
        addq.l  #4,a3

        ; --- case 13: lsl.l #1,d0
        move.l  #3,d0
        lsl.l   #1,d0
        move.l  d0,(a3)
        addq.l  #4,a3

        ; --- case 14: lsr.l #1,d0
        move.l  #3,d0
        lsr.l   #1,d0
        move.l  d0,(a3)
        addq.l  #4,a3

        ; --- case 15: swap d0
        move.l  #$12345678,d0
        swap    d0
        move.l  d0,(a3)
        addq.l  #4,a3

        ; --- case 16: move.l d3,d2
        move.l  #5,d3
        move.l  d3,d2
        move.l  d2,(a3)
        addq.l  #4,a3

        move.l  #MB_MAGIC_68K,MB_SENT_DONE
spin:
        bra.s   spin
