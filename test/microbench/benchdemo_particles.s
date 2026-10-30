; test/microbench/benchdemo_particles.s -- the particle-explosion demo.
;
; A WATCHABLE Jaguar program: an explosion of 256 particles, each with its
; own colour, simulated on the 68000 and drawn through the Object
; Processor.
;
; This is NOT a benchmark.  It exists because the microbenchmark ROMs in
; this directory deliberately draw nothing -- they are timing harnesses,
; and every cycle they spend on video is a cycle that muddies the
; measurement.  This ROM is the opposite: it is here to be LOOKED AT, and
; to prove the whole video path (68K -> DRAM -> OP object list -> line
; buffer -> host framebuffer) works in this core.
;
; HOW IT WORKS
; ------------
;   * TOM's display geometry is programmed (VMODE/VDB/VDE).  The core
;     derives tomWidth/tomHeight only when a register in $28..$4F is
;     WRITTEN; a ROM that skips that leaves tomWidth at 0 and the
;     scanline renderers draw zero-pixel rows -- a black screen even
;     though the OP filled the line buffer correctly.
;
;   * One BITMAP object covers the whole 320x240 screen in 16-bit RGB.
;     The OP walks the object list on every even halfline, so the object
;     has to be re-armed once per FIELD (a field is VP+1 = 524
;     halflines) -- the OP decrements HEIGHT and advances DATA on every
;     line it renders.
;
;   * The re-arm happens in the blanking BEFORE the OP's first pass of
;     the field (VC below VDB), where the OP cannot be mid-object.  This
;     matters: re-arming on a LEVEL ("VC past the visible window") is
;     true for several halflines, and each re-arm is two longword
;     stores.  If the OP reads the object between them it sees a fresh
;     DATA with an exhausted HEIGHT, skips the object, and the line
;     comes out black.
;
;   * The framebuffer is 16-bit pixels written with WORD stores.  A
;     longword store would pad every pixel to four bytes and the OP
;     would read the padding as pixels.
;
; DOUBLE BUFFERING
; ----------------
;   The OP renders the framebuffer line by line as the beam sweeps, so
;   a framebuffer that the 68000 rewrites while the OP reads it tears.
;   Worse, a framebuffer that only ever gets the CURRENT particle
;   positions erased keeps every older position as a trail, and after
;   a few seconds the screen is a smear of the particle history.
;
;   So the demo keeps TWO framebuffers:
;
;     * the OP renders the FRONT buffer,
;     * the 68000 draws the next frame into the BACK buffer,
;
;   and the buffers are swapped every field.  The back buffer holds the
;   drawing from TWO fields ago (the front one was drawn in between), so
;   a small "shadow" table per buffer -- the positions that buffer
;   holds -- says exactly which pixels have to be erased before it is
;   reused.  Nothing else is ever written to a framebuffer, so the
;   erase is complete and no trail survives.
;
; THE SIMULATION
; --------------
;   * The particle table lives at PARTICLE_BASE, four LONGs per
;     particle: x, y, vx, vy.  Four POINTERS walk the table (one per
;     field), each advanced by the 16-byte stride, so no displacement
;     addressing is needed.
;   * The explosion: every particle starts at the screen centre with a
;     pseudo-random direction and speed, so the burst spreads out
;     instead of moving as a block.
;   * The particles BOUNCE off the screen edges.  A decaying burst
;     stops moving after a second or two and the demo turns into the
;     static field this demo was written to avoid; bouncing keeps every
;     particle in motion for as long as the ROM is left running.
;   * Colour: the hue advances every frame, so the burst cycles through
;     the palette instead of being a static colour field.
;
; SENTINELS (the usual $010000 block)
;   $010000  START       "the ROM booted"
;   $010004  DONE        "the demo is running"
;   $010008  COUNT       frames simulated
;   $01000C  SPARE       reserved
;   $010010  PARTICLES   how many particles are alive
;   $010014  BUFFER      0 = the front buffer is A, 1 = it is B
;
; ASSEMBLER NOTES (rmac, verified against the pinned build -- see
; README.md and docs/agent/upstream-issue-drafts.md)
;   * Only d0-d7 and a0-a7 exist; d8+ are "undefined expression".
;   * MOVEQ is data-register only, and its immediate is 0..255.
;   * Shift immediates are 1..8; a bigger shift needs the register form
;     (moveq #27,d4 ; lsr.l d4,d2).
;   * ADDQ's immediate is 1..8; anything bigger needs ADD.L #n,An.
;   * MULU has no register-register LONG form on the 68000 (rmac
;     rejects it: "unsupported for selected CPU"), and MULU with an
;     IMMEDIATE source is not a 68000 instruction at all -- rmac
;     assembles `mulu.w #$6A0D,d2` as MOVE.B #$6A0D,(A2)+, which
;     silently corrupts the table and the pointer.  Use MULU.W with a
;     register source only.
;   * A label in an INDEXED form (`TBL(a0)`) is assembled as a
;     section-relative displacement, not as an absolute address, so
;     indexed accesses to labels are wrong.  A plain displacement
;     (`4(a0)`) is fine.
;   * The index SCALE of a register+register form (`d(a1,a0)`) is always
;     byte, whatever the access width, so the effective address is
;     wrong for word and long accesses.
;   * Forward branches DO assemble (rmac sizes the displacement itself);
;     the only quirk is that a branch to the immediately following
;     instruction comes out as a NOP, which is the same behaviour.
;   * DBRA runs the body N+1 times for a counter of N (it branches
;     until the counter is -1), so "N iterations" means "counter = N-1".
;
; Build (from this directory, toolchain on PATH):
;   eval "$(tools/jaguar-toolchain/setup.sh env)"
;   rmac -fb -o benchdemo_particles.o benchdemo_particles.s
;   rln  -n -a 800000 x x -o benchdemo_particles.j64 benchdemo_particles.o

        .68000
        .text

        .include "cartboot.inc"

; ---- the palette ----------------------------------------------------
; 64 RGB555 words: a full hue wheel (red -> orange -> yellow -> green ->
; cyan -> blue -> magenta -> red), each with the low bit set so the core's
; MIX16 table decodes it as RGB16 rather than CRY.  The demo indexes the
; palette with (particle + frame) & 63, so every particle walks the whole
; wheel once per second and the burst shimmers through the spectrum.
;
; The table sits at the cart entry point itself, immediately behind a
; branch that jumps over it: that gives it a FIXED address ($802004)
; which the ROM can load with a plain immediate.  (A pointer built from
; a label expression is section-relative in this assembler, so the
; address is written out longhand instead.)
        bra.w   start                     ; $802000: jump over the table
PALETTE_SRC:
        dc.w    $F801,$F807,$F80D,$F813,$F819,$F81F,$F823,$F829
        dc.w    $F82F,$F835,$F83B,$F03F,$D83F,$C03F,$A83F,$903F
        dc.w    $803F,$683F,$503F,$383F,$203F,$083F,$00BF,$017F
        dc.w    $023F,$02FF,$03BF,$043F,$04FF,$05BF,$067F,$073F
        dc.w    $07FF,$07F9,$07F3,$07ED,$07E7,$07E1,$07DD,$07D7
        dc.w    $07D1,$07CB,$07C5,$0FC1,$27C1,$3FC1,$57C1,$6FC1
        dc.w    $87C1,$97C1,$AFC1,$C7C1,$DFC1,$F7C1,$FF41,$FE81
        dc.w    $FDC1,$FD01,$FC41,$FBC1,$FB01,$FA41,$F981,$F8C1

; --- TOM registers ---------------------------------------------------
        TOM_OLP_LO     .equ    $00F00020
        TOM_OLP_HI     .equ    $00F00022
        TOM_VC         .equ    $00F00006
        TOM_VMODE      .equ    $00F00028
        TOM_VDB        .equ    $00F00046
        TOM_VDE        .equ    $00F00048

; --- geometry --------------------------------------------------------
        SCR_W          .equ    320
        SCR_H          .equ    240
VMODE_VAL      .equ    $07C1         ; bit 8 (VARMOD) = the per-pixel
                                        ; CRY/RGB16 renderer
        VDB_VAL        .equ    38
        VDE_VAL        .equ    518

; --- the two framebuffers -------------------------------------------
; 320 x 240 pixels x 2 bytes = 153600 bytes each.
FB_A           .equ    $00030000
FB_B           .equ    $00058000
BACKPTR        .equ    $00010018      ; the buffer being drawn into
SHADOWPTR      .equ    $0001001C      ; its shadow table (x,y per particle)
BUFFLAG        .equ    $00010014      ; 0 = the front buffer is A

LIST_BASE      .equ    $00020000
LIST_BASE_LO   .equ    (LIST_BASE&$FFFF)
LIST_BASE_HI   .equ    ((LIST_BASE>>16)&$FFFF)
        BMP_OBJ        .equ    LIST_BASE+0
        STOP_OBJ       .equ    LIST_BASE+16

; --- particles -------------------------------------------------------
PARTICLE_BASE  .equ    $00110000          ; 256 * 16 bytes = 4096
; The number of particles is a BUDGET, not a taste: the OP renders a
; full-screen bitmap every field, and the 68000's framebuffer writes
; share that DRAM bus.  A 16bpp DRAM write costs the 68000 a couple of
; hundred cycles here, so 64 particles x (2 erase + 2 draw + 1 shadow)
; = 320 writes is about 6 ms -- comfortably inside one 16.6 ms field.
; Draw more than that and the drawing overruns the field: the object
; cannot be re-armed in time, its remaining height runs out, and the
; screen decays to black.
PARTICLE_COUNT .equ    64
PARTICLE_STRIDE .equ    16                ; x, y, vx, vy (LONGs)
SHADOW_A       .equ    $00111000          ; 256 * 4 bytes: (y << 16) | x
SHADOW_B       .equ    $00111800
PALETTE        .equ    $00112000          ; 64 colour words (RGB555)

; --- object list fields ---------------------------------------------
; p0: type=0 (BITMAP), ypos=0, height=240, link=STOP_OBJ, data=FB_BASE
;
;   data   = $00030000 -> $30000 << 40 = bits 56,57 -> high32 $03000000.
;   link   = $00020010 -> link bit 17 lands on p0 bit 38 = HIGH longword
;            bit 6 ($00000040); link bit 4 lands on p0 bit 25 = LOW
;            longword bit 25 ($02000000).  (High longword bit 5 would
;            encode link $010010 -- the sentinel block -- and the screen
;            would stay black.)
;   height = 240 << 14 = $003C0000.
; The high longword also carries the link bit, so there is one variant
; per framebuffer: data $03000000 for A, $05800000 for B.
        BMP_P0_HI_A    .equ    $03000040
        BMP_P0_HI_B    .equ    $05800040
        BMP_P0_LO      .equ    $023C0000

; p1: xpos=0, depth=4 (16bpp), pitch=1 phrase (8 bytes), dwidth=640
;     bytes/line (80 << 18), iwidth=80 phrases (320 px).
        BMP_P1_HI      .equ    $00000005          ; iwidth 80 spills into the high word
        BMP_P1_LO      .equ    $140C000

        STOP_P0_HI     .equ    $00000000
        STOP_P0_LO     .equ    $00000004

; --- physics ---------------------------------------------------------
; The burst: every particle leaves the centre with a pseudo-random
; direction and a speed of up to 16 pixels per frame.  The particles
; bounce off the edges of the screen, so they never leave it and never
; stop moving.
;
; The random numbers come from a Weyl sequence (seed += 0x9E3779B9):
; the high bits of that sequence are the best distributed bits of any
; cheap 32-bit counter, and the velocity is taken from bits 27-31 and
; 22-26, which gives all 256 different (vx,vy) pairs.
;
; The velocities used to come out of the TOP TWO BITS of a 32-bit
; multiplicative LCG, whose period is 4 -- every particle got nearly the
; same velocity and the "explosion" was a blob drifting up and to the
; left.
; The background colour.  The core's MIX16 table selects RGB16 or CRY
; from bit 0 of the 16-bit pixel, and CRY 0 decodes to a grey, so a black
; background is RGB16 black WITH the select bit set.
BG_COLOUR     .equ    $0001

VEL_SHIFT_X   .equ    27
VEL_SHIFT_Y   .equ    22
VEL_MASK      .equ    $001F               ; 5 bits -> -16..15
VEL_BIAS      .equ    16
WELLY_STEP    .equ    $9E3779B9           ; 2^32 / golden ratio
CENTER_X       .equ    SCR_W/2
CENTER_Y       .equ    SCR_H/2

; The 2x2 block has to stay inside the 320x240 framebuffer.
MAX_X         .equ    SCR_W-2
MAX_Y         .equ    SCR_H-2

; --- sentinels -------------------------------------------------------
        MB_SENT_PART   .equ    MB_SENT_BASE+16

; --- register use ----------------------------------------------------
; a0  framebuffer pointer
; a1  particle table: x        (or the shadow table in the erase pass)
; a2  particle table: y
; a3  particle table: vx
; a4  particle table: vy
; a5  shadow table: x, y
; a6  scratch
; d0  scratch
; d1  loop counter            (LIVE across the subroutines)
; d2  particle index          (LIVE across the subroutines)
; d3  frame number            (LIVE across the subroutines)
; d4  x                       (an INPUT to the subroutines)
; d5  y                       (an INPUT to the subroutines)
; d6  vx -> the colour word   (after the state has been stored)
; d7  vy -> colour scratch    (after the state has been stored)
;
; The subroutines (erase_block, draw_block, fb_addr) may clobber d0 and
; a0 and nothing else.

start:
        ; Supervisor mode, interrupts masked.
        ;
        ; The supervisor bit MATTERS: in user mode the core's interrupt
        ; path (Musashi's Exception()) switches to regs.isp -- the SSP --
        ; and this core's cart HLE path never initialises it, so the
        ; first video/timer IRQ lands its frame on a garbage stack and
        ; the CPU dies.  In supervisor mode the IRQ frame goes on the
        ; CURRENT A7, which the next line sets up.
        move.w  #$2700,sr
        move.l  #MB_MAGIC_START,MB_SENT_START

        ; Set up the stack explicitly.  This core's cart HLE path writes
        ; the SSP into RAM[0] but never gives the 68000 a stack pointer,
        ; so A7 starts at 0: the first jsr pushes its return address at
        ; $FFFFFFFC (discarded) and the rts returns to whatever is in
        ; the stack slot -- garbage.  The demo uses jsr/rts, so it must set
        ; A7 itself.  (The microbenchmark ROMs never call a subroutine,
        ; which is why they never noticed.)
        move.l  #$00003FF0,a7


; ---- 1. program the display geometry --------------------------------
        move.w  #VMODE_VAL,TOM_VMODE
        move.w  #VDB_VAL,TOM_VDB
        move.w  #VDE_VAL,TOM_VDE

; ---- 2. build the object list ---------------------------------------
        move.l  #BMP_P0_HI_A,BMP_OBJ
        move.l  #BMP_P0_LO,BMP_OBJ+4
        move.l  #BMP_P1_HI,BMP_OBJ+8
        move.l  #BMP_P1_LO,BMP_OBJ+12
        move.l  #STOP_P0_HI,STOP_OBJ
        move.l  #STOP_P0_LO,STOP_OBJ+4

; ---- 3. point OLP at the list ---------------------------------------
        move.w  #LIST_BASE_LO,TOM_OLP_LO
        move.w  #LIST_BASE_HI,TOM_OLP_HI

; ---- 4. seed the particles ------------------------------------------
; Deterministic pseudo-random sequence (a Weyl sequence), so the
; explosion is the same on every run and two frames can be compared
; directly.
;
; Each particle: start at the centre, leave in a pseudo-random
; direction with a pseudo-random speed.
        move.l  #$0000C0DE,d0            ; the seed

        ; the four table pointers
        move.l  #PARTICLE_BASE,a1
        move.l  #PARTICLE_BASE+4,a2
        move.l  #PARTICLE_BASE+8,a3
        move.l  #PARTICLE_BASE+12,a4

        move.w  #(PARTICLE_COUNT-1),d1
seedloop:
        ; x, y: the centre
        move.l  #CENTER_X,a5
        move.l  a5,(a1)
        move.l  #CENTER_Y,a5
        move.l  a5,(a2)

        ; vx: bits 27-31 of the seed, minus 16 -> -16..15
        move.l  d0,d2
        moveq   #VEL_SHIFT_X,d4
        lsr.l   d4,d2
        andi.l  #VEL_MASK,d2
        sub.l   #VEL_BIAS,d2
        move.l  d2,(a3)

        ; vy: bits 22-26 of the seed, minus 16 -> -16..15
        move.l  d0,d2
        moveq   #VEL_SHIFT_Y,d4
        lsr.l   d4,d2
        andi.l  #VEL_MASK,d2
        sub.l   #VEL_BIAS,d2
        move.l  d2,(a4)

        ; next seed: seed += 0x9E3779B9 (the golden-ratio step)
        addi.l  #WELLY_STEP,d0

        ; advance the four pointers by the stride
        add.l   #PARTICLE_STRIDE,a1
        add.l   #PARTICLE_STRIDE,a2
        add.l   #PARTICLE_STRIDE,a3
        add.l   #PARTICLE_STRIDE,a4
        dbra    d1,seedloop

        ; the shadow tables start out empty: the first frames erase
        ; nothing and the buffers are already clear.
        move.l  #0,d0
        move.l  #SHADOW_A,a6
        move.w  #(PARTICLE_COUNT-1),d1
shclr:
        move.l  d0,(a6)
        addq.l  #4,a6
        dbra    d1,shclr
        move.l  #SHADOW_B,a6
        move.w  #(PARTICLE_COUNT-1),d1
shclr2:
        move.l  d0,(a6)
        addq.l  #4,a6
        dbra    d1,shclr2


; ---- 4b. copy the colour palette into RAM ----------------------------
; The table is 64 words of RGB555 (a full hue wheel); the demo indexes it
; with (particle + frame) & 63, so the burst shimmers through the spectrum
; and every particle changes colour as it flies.
        move.l  #$00802004,a0             ; PALETTE_SRC (a fixed cart address)
        move.l  #PALETTE,a1
        move.w  #63,d1
palcopy:
        move.w  (a0),d0
        move.w  d0,(a1)
        addq.l  #2,a0
        addq.l  #2,a1
        dbra    d1,palcopy


; ---- 5. clear both framebuffers -------------------------------------
; The clear stores LONGWORDS and a longword holds TWO pixels, so the
; background colour has to be in BOTH halves -- $0001_0001, not
; $0001_0000.  Half a colour is not a cosmetic detail: a $0000 pixel is
; decoded by the core's MIX16 table as CRY (bit 0 clear) instead of
; RGB16, and CRY 0 renders as a faint red rather than black.  The result
; was a screen-wide dither of dark red/green/blue, with solid bands
; where the erase pass had written proper $0001 words over it.
        move.l  #$00010001,d0                ; BG_COLOUR in both halves
        move.w  #((SCR_H*SCR_W)/2)-1,d1  ; 38400 longword stores
        move.l  #FB_A,a0
fbclrA:
        move.l  d0,(a0)+
        dbra    d1,fbclrA
        move.w  #((SCR_H*SCR_W)/2)-1,d1
        move.l  #FB_B,a0
fbclrB:
        move.l  d0,(a0)+
        dbra    d1,fbclrB


; ---- 6. run ----------------------------------------------------------
        move.l  #MB_MAGIC_68K,MB_SENT_DONE
        move.l  #PARTICLE_COUNT,a5
        move.l  a5,MB_SENT_PART
        moveq   #0,d3                     ; frame counter

frameloop:
        ; ---- wait for the TOP of the field.  The OP only renders the
        ;      visible window (VC from VDB to VDE), so the blanking above
        ;      VDB is the one place where the OP cannot be mid-object --
        ;      and the object has to be re-armed there, exactly once.
        ;
        ;      Waiting for "VC > VDE" instead is a LEVEL test: it stays
        ;      true for the rest of the field, and the 68K polls it in a
        ;      tight loop, so the object gets re-armed hundreds of times
        ;      per field.  Each re-arm is two longword stores (DATA, then
        ;      HEIGHT/LINK), and if the OP reads the object between them
        ;      it sees a FRESH DATA with an EXHAUSTED HEIGHT, skips the
        ;      object, and the line comes out black.
        ;
        ;      VC ($F00006) is updated by the core on every halfline;
        ;      bit 11 ($0800) marks the lower field, so it has to be
        ;      masked off before the comparison.
waitdn:
        move.w  TOM_VC,d0
        andi.w  #$07FF,d0
        cmpi.w  #VDB_VAL,d0
        bge.w   waitdn
        ; ---- pick the buffers.  The OP renders the FRONT buffer; the
        ;      68000 draws the next frame into the BACK one.
        move.l  #BUFFLAG,a0
        move.l  (a0),d0
        tst.l   d0
        beq.w   front_is_a
        ; the front is B, so the back is A
        move.l  #BMP_P0_HI_B,BMP_OBJ
        move.l  #FB_A,d1
        move.l  d1,BACKPTR
        move.l  #SHADOW_A,d1
        move.l  d1,SHADOWPTR
        bra.w   buffers_set
front_is_a:
        move.l  #BMP_P0_HI_A,BMP_OBJ
        move.l  #FB_B,d1
        move.l  d1,BACKPTR
        move.l  #SHADOW_B,d1
        move.l  d1,SHADOWPTR
buffers_set:
        move.l  #BMP_P0_LO,BMP_OBJ+4
        move.w  #LIST_BASE_LO,TOM_OLP_LO
        move.w  #LIST_BASE_HI,TOM_OLP_HI

        ; ---- pass 1: erase what the back buffer holds ---------------
        ;     The shadow table holds exactly the positions that buffer
        ;     was drawn with, so erasing them clears it completely.
        move.l  #SHADOWPTR,a0
        move.l  (a0),a1                ; the shadow table's base
        move.w  #(PARTICLE_COUNT-1),d1
erasepass:
        move.l  (a1),d0                 ; the packed position
        move.l  d0,d4
        andi.l  #$FFFF,d4                ; x
        moveq   #16,d6
        lsr.l   d6,d0                    ; y
        move.l  d0,d5
        jsr     erase_block
        addq.l  #4,a1
        dbra    d1,erasepass

        ; ---- pass 2: advance every particle and draw it ---------------
        move.l  #PARTICLE_BASE,a1
        move.l  #PARTICLE_BASE+4,a2
        move.l  #PARTICLE_BASE+8,a3
        move.l  #PARTICLE_BASE+12,a4
        move.l  #SHADOWPTR,a0
        move.l  (a0),a5                ; the shadow table's base
        move.w  #(PARTICLE_COUNT-1),d1
        moveq   #0,d2                     ; particle index
particleloop:
        ; --- load the particle
        move.l  (a1),d4                  ; x
        move.l  (a2),d5                 ; y
        move.l  (a3),d6                 ; vx
        move.l  (a4),d7                 ; vy

        ; --- advance
        add.l   d6,d4                    ; x += vx
        add.l   d7,d5                    ; y += vy

        ; --- bounce off the edges.  The 2x2 block has to stay inside the
        ;     framebuffer, so the particle is reflected at 0 and at
        ;     MAX_X/MAX_Y.  Reflecting (rather than clamping) keeps the
        ;     speed, so the burst never settles.
        cmpi.w  #0,d4
        blt.w   px_low
        cmpi.w  #MAX_X,d4
        bgt.w   px_high
        bra.w   px_done
px_low:
        neg.l   d4
        neg.l   d6
        bra.w   px_done
px_high:
        move.l  #MAX_X,d4
        neg.l   d6
px_done:
        cmpi.w  #0,d5
        blt.w   py_low
        cmpi.w  #MAX_Y,d5
        bgt.w   py_high
        bra.w   py_done
py_low:
        neg.l   d5
        neg.l   d7
        bra.w   py_done
py_high:
        move.l  #MAX_Y,d5
        neg.l   d7
py_done:

        ; --- store the new state
        move.l  d4,(a1)
        move.l  d5,(a2)
        move.l  d6,(a3)
        move.l  d7,(a4)

        ; --- remember where this buffer now holds the particle: the
        ;     position is packed into one longword, (y << 16) | x, so
        ;     that the erase pass needs a single read per particle
        move.l  d5,d0
        moveq   #16,d6
        lsl.l   d6,d0
        or.l    d4,d0
        move.l  d0,(a5)
        addq.l  #4,a5

        ; --- the colour: one lookup in the palette, indexed by
        ;     (index + frame) so the hue rotates every frame.
        ;
        ;     The OP fetches the framebuffer's pixels BIG-ENDIAN (the
        ;     same order the 68000's word stores use -- see the phrase
        ;     fetch in src/tom/op.c), so the word is stored exactly as
        ;     the core's MIX16 table wants it: R in bits 15-11, B in
        ;     bits 10-6, G in bits 5-0, and bit 0 selecting RGB16
        ;     instead of CRY.  (Byte-swapping it -- as this demo used to
        ;     do -- throws the green away and lands in CRY mode.)
        move.l  d2,d0
        add.l   d3,d0                    ; colour phase = index + frame
        andi.l  #$003F,d0
        add.l   d0,d0                     ; entries are WORDS, not longs
        move.l  #PALETTE,a0
        add.l   d0,a0                     ; (the indexed form is broken in
        move.w  (a0),d6                   ;  this assembler: scale is bytes)

        ; --- draw the new position in the particle's colour
        jsr     draw_block

        ; --- next particle
        add.l   #PARTICLE_STRIDE,a1
        add.l   #PARTICLE_STRIDE,a2
        add.l   #PARTICLE_STRIDE,a3
        add.l   #PARTICLE_STRIDE,a4
        addq.w  #1,d2
        dbra    d1,particleloop

        ; ---- the frame is drawn.  Swap the buffers and wait for the top
        ;      of the next field, so the demo advances once per field
        ;      (60 times a second).
        move.l  #BUFFLAG,a0
        move.l  (a0),d0
        eori.l  #1,d0
        move.l  d0,(a0)

        addq.w  #1,d3
        move.l  #MB_SENT_COUNT,a5
        move.l  d3,(a5)
        bra.w   frameloop

; ---------------------------------------------------------------------
; erase_block -- write a black 2x2 block at (d4,d5) in the BACK buffer.
; ---------------------------------------------------------------------
erase_block:
        jsr     fb_addr                 ; a0 = the pixel address
        move.w  #BG_COLOUR,d0
        move.w  d0,(a0)
        addq.l  #2,a0
        move.w  d0,(a0)
        subq.l  #2,a0
        add.l   #640,a0                  ; the row below
        move.w  d0,(a0)
        addq.l  #2,a0
        move.w  d0,(a0)
        rts

; ---------------------------------------------------------------------
; draw_block -- write a coloured 2x2 block at (d4,d5) in the BACK buffer.
; d6 holds the colour word (already byte-swapped).
; ---------------------------------------------------------------------
draw_block:
        jsr     fb_addr                 ; a0 = the pixel address
        move.w  d6,(a0)
        addq.l  #2,a0
        move.w  d6,(a0)
        subq.l  #2,a0
        add.l   #640,a0                  ; the row below
        move.w  d6,(a0)
        addq.l  #2,a0
        move.w  d6,(a0)
        rts

; ---------------------------------------------------------------------
; fb_addr -- a0 = the back buffer + y*640 + x*2.
;
; d4 = x, d5 = y on entry.  Only d0 may be clobbered: d1/d2/d3 are live
; in the caller and d4/d5 are the position the caller still needs.
;
; The address is built with shifts only (the 68000 has no MULU with a
; register source and rmac cannot do a 32-bit multiply), and every
; shift is unrolled because the assembler's immediate shift counts stop
; at 8:
;
;     y*640 = (y*5) << 7
;     x*2   = x + x
; ---------------------------------------------------------------------
fb_addr:
        move.l  d5,d0
        lsl.l   #1,d0                    ; y*2
        lsl.l   #1,d0                    ; y*4
        add.l   d5,d0                    ; y*5
        lsl.l   #7,d0                    ; y*640
        add.l   d4,d0                    ; + x
        add.l   d4,d0                    ; + x  ->  y*640 + 2*x
        move.l  #BACKPTR,a0
        move.l  (a0),a0                  ; the back buffer's base
        add.l   a0,d0
        move.l  d0,a0
        rts
