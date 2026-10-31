; test/microbench/benchdemo_sine.s -- a 68K-only SINE wave through the
; Jaguar's I2S port.
;
; WHAT THIS IS
; ------------
; The same mechanism as benchdemo_audio.s (a JERRY timer interrupt that
; writes one sample into LTXD/RTXD per tick, which JERRY's I2S hardware
; latches on each word strobe), except that the sample is read from a
; 64-entry sine table instead of being a two-level square wave.
;
; It exists to be *measured*, not just heard: test/tools/test_demo_audio
; --sine fits a sine to the captured output and reports the fitted
; frequency, the amplitude in dBFS and the SNR against a pure sine --
; the same three numbers the Sega 32X PWM test reports, so the two
; machines' audio paths can be compared directly.
;
;     tone = (the tick rate the ROM actually achieved) / 64
;          ~ 41550 / 64 ~= 649 Hz
;
; which is close to the 32X test's 689.5 Hz (= its PWM rate / 32), so
; the two numbers can be read side by side.
;
; THE TABLE
; ---------
; 64 signed 16-bit samples of sin(2*pi*k/64) scaled to +/-16000, stored
; at $802004 -- a FIXED cart address, immediately behind the "bra.w
; start" at the entry point.  That is the one addressing pattern this
; assembler gets right: an immediate built from a label expression is
; section-relative here, and the register+register indexed form is
; mis-encoded, so the ISR builds the table pointer by hand and then
; uses a plain (An) access.
;
; SENTINELS (main RAM $010000+)
;   $010000  START magic
;   $010004  DONE magic (written once the setup is complete)
;
; PUBLISHED STATE (main RAM $020000+)
;   $020000  the number of interrupts taken (the tick count)
;   $020010  the tick count at the last interrupt
;   $020014  the sample last written to LTXD (sign-extended)
;
; The ISR's address is placed in the cart as DATA and copied into the
; vector at run time (a forward label inside a `dc.l` is deferred to the
; linker and patched correctly; an immediate is not).
; TOM INT1 bit 4 is the JERRY -> 68K gate (C_JERENA).
TOM_INT1_ENA    .equ    $00F000E1
; JERRY's programmable interval timers.
JERRY_PIT1      .equ    $00F10000
JERRY_PIT2      .equ    $00F10002
; JINTCTRL: low byte = enable mask, high byte = write-one-to-clear.
JERRY_INT_CTRL  .equ    $00F10020
JERRY_INT_ENABLE equ    $0004
JERRY_INT_CLR1  equ    $0400
JERRY_INT_BOTH  equ    JERRY_INT_ENABLE+JERRY_INT_CLR1
; The I2S transmit registers live at the even address above their byte
; address.
DAC_LTXD        .equ    $00F1A14A
DAC_RTXD        .equ    $00F1A14E
DAC_SCLK        .equ    $00F1A152
DAC_SMODE       .equ    $00F1A156

IRQ_VECTOR      .equ    $00000100
TICK_COUNT      .equ    $00020000
STATE_COUNT     .equ    $00020010
STATE_VALUE     .equ    $00020014

; One tick is (PIT1+1)*(PIT2+1) = 4*160 = 640 cycles of the 26.59 MHz
; RISC clock = 24.07 us, i.e. a 41.55 kHz interrupt rate -- deliberately
; the SAME as the I2S word strobe rate (SCLK = 9 -> 26.59 MHz / (64*10)
; = 41.55 kHz).
;
; Why exactly equal: the DAC has no FIFO, only the transmit registers.
; A sample written faster than the strobes is simply dropped; one
; written slower is held for two strobes.  Either way the sine picks up
; timing jitter, which is distortion.  Matching the divider to the
; strobe makes the two rate-locked, so every sample is latched exactly
; once.  The divider is deliberately slow enough (640 cycles = 320 68K
; cycles) that the ISR always finishes inside one tick; when the ISR
; overruns instead, JERRY swallows the tick and the rate drifts below
; the strobe, which is the jitter this ROM is trying to avoid.
PIT1_VALUE      .equ    3
PIT2_VALUE      .equ    159

SINE_LEN        .equ    64
SINE_ADDR       .equ    $00802004          ; the table's fixed address
ISR_PTR_ADDR    .equ    $00802084          ; the ISR address as DATA

        .68000
        .text

        .include "cartboot.inc"           ; header; entry = $802000

        bra.w   start                     ; $802000: jump over the table
SINE_TABLE:
        dc.w    $0000,$0620,$0C31,$1225,$17EB,$1D76,$22B9,$27A6
        dc.w    $2C32,$3050,$33F8,$371F,$39BE,$3BCF,$3D4D,$3E33
        dc.w    $3E80,$3E33,$3D4D,$3BCF,$39BE,$371F,$33F8,$3050
        dc.w    $2C32,$27A6,$22B9,$1D76,$17EB,$1225,$0C31,$0620
        dc.w    $0000,$F9E0,$F3CF,$EDDB,$E815,$E28A,$DD47,$D85A
        dc.w    $D3CE,$CFB0,$CC08,$C8E1,$C642,$C431,$C2B3,$C1CD
        dc.w    $C180,$C1CD,$C2B3,$C431,$C642,$C8E1,$CC08,$CFB0
        dc.w    $D3CE,$D85A,$DD47,$E28A,$E815,$EDDB,$F3CF,$F9E0

        dc.l    isr                       ; $802084: the ISR address

start:
        move.l  #MB_MAGIC_START,MB_SENT_START

        move.w  #$2700,sr                  ; supervisor mode, interrupts off
        move.l  #$00060000,a7              ; the stack, above the framebuffer

        ; --- install the interrupt handler (68K IRQ vector 64 -> $100)
        move.l  #ISR_PTR_ADDR,a0
        move.l  (a0),d0
        move.l  #IRQ_VECTOR,a0
        move.l  d0,(a0)

        ; --- open TOM's JERRY -> 68K gate (INT1 bit 4)
        move.b  #$10,TOM_INT1_ENA

        ; --- start the I2S chain: SMODE first, then SCLK (the SCLK write
        ;     is what schedules JERRY's I2S callback).  Master mode with
        ;     SCLK = 9 gives 26.59 MHz / (64 * 10) = 41.55 kHz strobes.
        move.w  #1,DAC_SMODE
        move.w  #9,DAC_SCLK

        ; --- arm JERRY's timer 1 (one tick every 20.005 us)
        move.w  #PIT1_VALUE,JERRY_PIT1
        move.w  #PIT2_VALUE,JERRY_PIT2

        ; --- enable timer 1 and clear its pending latch in one write
        move.w  #JERRY_INT_BOTH,JERRY_INT_CTRL

        ; --- let the interrupts in
        move.w  #$2000,sr

        move.l  #MB_MAGIC_68K,MB_SENT_DONE

mainloop:
        bra.s   mainloop

; ---------------------------------------------------------------------
isr:
        ; clear the timer-1 pending latch (and keep it enabled)
        move.w  #JERRY_INT_BOTH,JERRY_INT_CTRL

        ; count the tick
        move.l  #TICK_COUNT,a0
        move.l  (a0),d1
        addq.l  #1,d1
        move.l  d1,(a0)

        ; the sine sample: index = tick & 63, then the pointer is built
        ; by hand because the indexed forms are mis-encoded here
        move.l  d1,d0
        andi.l  #SINE_LEN-1,d0
        add.l   d0,d0                       ; words, not longs
        move.l  #SINE_ADDR,a0
        add.l   d0,a0
        move.w  (a0),d2
        ext.l   d2                          ; signed 16-bit sample

        ; write the I2S transmit registers
        move.w  d2,DAC_LTXD
        move.w  d2,DAC_RTXD

        ; publish the state for the harness
        move.l  #STATE_COUNT,a0
        move.l  d1,(a0)
        move.l  #STATE_VALUE,a0
        move.l  d2,(a0)

        rte
