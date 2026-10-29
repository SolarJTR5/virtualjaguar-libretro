; test/microbench/benchdemo_audio.s -- a 68K-only square wave through the
; Jaguar's I2S port.
;
; WHAT THIS PROVES
; ---------------
; The 68000 can drive the audio path on its own, with no DSP program at
; all.  The 68K:
;
;   * installs a handler at the Jaguar's 68K interrupt vector (vector 64,
;     i.e. $100 -- irq_ack_handler() returns 64 for every hardware
;     interrupt),
;   * arms JERRY's timer 1 so that it interrupts at ~50 kHz,
;   * and writes a square wave straight into the I2S transmit registers
;     (LTXD/RTXD).
;
; JERRY's I2S hardware latches LTXD/RTXD on every word strobe (46.1 kHz
; in master mode with SCLK = 8) and the DAC resamples that stream into
; the 48 kHz output.  So the whole chain is exercised:
;
;   68K -> LTXD/RTXD -> I2S word strobe -> DAC ring -> resampler ->
;   libretro audio
;
; This is the first step of the 32X PWM port: the PWM driver's job is to
; fill a FIFO with samples, and this ROM shows that a 68000 can put
; samples into the Jaguar's DAC at a metered rate with nothing but a
; timer interrupt.
;
; THE TONE
; --------
; JERRY's PIT counts the full 26.59 MHz RISC clock, so one tick is
; (PIT1+1)*(PIT2+1) = 4*133 = 532 cycles = 20.005 us, i.e. a 49.99 kHz
; interrupt rate.  The square wave's phase is the tick count divided by
; 8, so the output is a square wave with a 16-tick period:
;
;     tone = 49.99 kHz / 16 = 3124 Hz (nominal)
;
; The *measured* tone is a little lower than the nominal, and that is
; hardware behaviour rather than a bug: JERRY's pending-interrupt latch
; is cleared by the 68000's own write to JINTCTRL, so a timer tick that
; lands between the interrupt acknowledge and that write is swallowed.
; The harness therefore measures the tick rate the ROM actually achieved
; (it publishes the tick count) and derives the expected tone from it
; instead of trusting the nominal.
;
; SENTINELS (main RAM $010000+)
;   $010000  START magic
;   $010004  DONE magic (written once the setup is complete)
;
; PUBLISHED STATE (main RAM $020000+)
;   $020000  the number of interrupts taken (the tick count)
;   $020010  the tick count at the last interrupt
;   $020014  the value last written to LTXD
;   $020028  breadcrumb: the setup code ran
;   $02002C  breadcrumb: the ISR was entered
;   $020030  the A7 the ISR ran with
;
; ASSEMBLER CONSTRAINTS
; ---------------------
; This toolchain cannot resolve a forward branch reference, so there are
; no conditionals in this ROM: the square wave's phase is computed
; branchlessly.  The register+register index form and the
; absolute-indexed form are mis-assembled by rmac, so the table below is
; read with a plain (An) access.
;
; The ISR's address is placed in the cart as DATA and copied into the
; vector at run time: an *immediate* built from a forward label is
; mis-resolved by this assembler, but a forward label inside a `dc.l`
; is deferred to the linker and patched correctly.
;
; Branches are backward-only; the only loop is the main spin.
MB_SENT_BASE    .equ    $00010000
MB_SENT_START   .equ    MB_SENT_BASE+0
MB_SENT_DONE    .equ    MB_SENT_BASE+4
MB_MAGIC_START  .equ    $C0DE57A7
MB_MAGIC_68K    .equ    $C0DE0068

; TOM INT1 bit 4 is the JERRY -> 68K gate (C_JERENA).
TOM_INT1_ENA    .equ    $00F000E1
; JERRY's programmable interval timers.  The PIT counts the 26.59 MHz
; system clock, so the period is (PIT1+1)*(PIT2+1) cycles.
JERRY_PIT1      .equ    $00F10000
JERRY_PIT2      .equ    $00F10002
; JINTCTRL ($F10020) is a split register: the low byte holds the
; interrupt enable mask and the high byte the write-one-to-clear pending
; bits (J_TIM1CLR is bit 10, i.e. $0400).  Both halves are written with
; one 16-bit store: $0404 enables timer 1 (enable bit 2 in the low byte)
; and clears its pending latch (clear bit 2 in the high byte).
JERRY_INT_CTRL  .equ    $00F10020
JERRY_INT_ENABLE equ    $0004                 ; enable mask: timer 1
JERRY_INT_CLR1  equ    $0400                 ; clear bit: timer 1 pending
JERRY_INT_BOTH  equ    JERRY_INT_ENABLE+JERRY_INT_CLR1
; The I2S transmit registers are 16-bit and live at the even address
; above their byte address.
DAC_LTXD        .equ    $00F1A14A
DAC_RTXD        .equ    $00F1A14E
DAC_SCLK        .equ    $00F1A152
DAC_SMODE       .equ    $00F1A156

; The 68K's interrupt vector (IRQ vector 64 -> $100).
IRQ_VECTOR      .equ    $00000100
; The ISR's tick counter and the published state.
TICK_COUNT      .equ    $00020000
STATE_COUNT     .equ    $00020010
STATE_VALUE     .equ    $00020014

AMP             .equ    16000               ; the square wave's amplitude
; One tick is (PIT1+1)*(PIT2+1) cycles of the 26.59 MHz RISC clock.
PIT1_VALUE      .equ    3                   ; (3+1)*(132+1) = 532 cycles
PIT2_VALUE      .equ    132                 ; 26.59 MHz / 532 = 20.005 us

        .68000
        .text

        dcb.b   $400,0                      ; $800000: the BootIntro slot
        dc.l    $04040404                   ; $800400: the universal marker
        dc.l    $00802004                   ; $800404: the 68K entry vector
        dc.l    $00000000                   ; $800408
        dcb.b   $2000-$40C,$FF              ; pad to $801FFC

VECTBL: dc.l   isr                        ; $802000: the ISR's address

start:
        move.l  #MB_MAGIC_START,MB_SENT_START

        move.w  #$2700,sr                  ; supervisor mode, interrupts off
        move.l  #$00060000,a7              ; the stack, above the framebuffer

        ; --- install the interrupt handler.  The Jaguar's 68K interrupt
        ;     vector is 64, i.e. main RAM $100.
        move.l  #$00802000,a0            ; the cart slot (a raw constant:
                                         ;   rmac would encode the
                                         ;   VECTBL label section-relative)
        move.l  (a0),d0
        move.l  #IRQ_VECTOR,a0
        move.l  d0,(a0)

        ; --- open TOM's JERRY -> 68K gate (INT1 bit 4)
        move.b  #$10,TOM_INT1_ENA

        ; --- start the I2S chain.  Writing SCLK is what schedules
        ;     JERRY's I2S callback -- and therefore the word strobes that
        ;     latch LTXD/RTXD into the DAC.  Master mode (SMODE_INTERNAL)
        ;     with SCLK = 8 gives 26.59 MHz / (64 * 9) = 46.1 kHz.
        ;     SMODE is written first so the reschedule picks it up.
        move.w  #1,DAC_SMODE              ; SMODE_INTERNAL = master
        move.w  #8,DAC_SCLK

        ; --- arm JERRY's timer 1: one tick every 20.005 us (49.99 kHz)
        move.w  #PIT1_VALUE,JERRY_PIT1
        move.w  #PIT2_VALUE,JERRY_PIT2

        ; --- enable the timer-1 interrupt and clear any pending latch
        ;     in one 16-bit write (see the JINTCTRL comment above)
        move.w  #JERRY_INT_BOTH,JERRY_INT_CTRL

        ; --- let the interrupts in.  The Jaguar routes every hardware
        ;     interrupt to the 68K at IPL 2, so a mask of 0 admits it.
        move.w  #$2000,sr

        ; breadcrumb: the CPU got this far
        move.l  #$00020028,a0
        move.l  #$A5A5A5A5,(a0)

        move.l  #MB_MAGIC_68K,MB_SENT_DONE

mainloop:
        bra.s   mainloop

; ---------------------------------------------------------------------
isr:
        ; breadcrumb: the ISR was entered, and with which stack pointer
        move.l  #$0002002C,a0
        move.l  #$5A5A5A5A,(a0)
        move.l  a7,(a0)
        move.l  a7,d0
        move.l  #$00020030,a0
        move.l  d0,(a0)

        ; --- clear the timer-1 pending latch.  Without this the request
        ;     stays asserted and the 68K takes the interrupt again
        ;     immediately.  The high byte of JINTCTRL is the clear field;
        ;     the low byte is the enable mask, so the same value also
        ;     keeps timer 1 enabled.
        move.w  #JERRY_INT_BOTH,JERRY_INT_CTRL

        ; --- count the tick
        move.l  #TICK_COUNT,a0
        move.l  (a0),d1
        addq.l  #1,d1
        move.l  d1,(a0)

        ; --- the square wave, branchlessly: the phase is the tick count
        ;     divided by 8, and the output is +AMP or -AMP.
        move.l  d1,d0
        lsr.l   #3,d0
        andi.l  #1,d0
        neg.l   d0                    ; 0 or all-ones
        move.l  #AMP,d2
        move.l  d2,d3
        add.l   d2,d3                 ; 2 * AMP
        and.l   d0,d3                 ; d3 = 0 or 2*AMP
        ; The subtrahend is moved into D0 first so that the SUB.L reads
        ; it from a register the encoder is known to get right (the
        ; register-register ALU forms are checked by
        ; test/microbench/benchdemo_alu.s).
        move.l  d3,d0
        sub.l   d0,d2                 ; +AMP or -AMP

        ; --- write the I2S transmit registers
        move.w  d2,DAC_LTXD
        move.w  d2,DAC_RTXD

        ; --- publish the state for the harness
        move.l  #STATE_COUNT,a0
        move.l  d1,(a0)
        move.l  #STATE_VALUE,a0
        move.l  d2,(a0)

        rte
