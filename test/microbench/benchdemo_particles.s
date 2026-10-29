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
;   * Each particle is a 2x2 block.  Per frame the demo erases the old
;     position (black) and draws the new one (the particle's colour), so
;     it never has to clear the whole 153 KB framebuffer -- which the
;     68000 could not do in a 60 Hz frame anyway.
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
;   * Gravity pulls y down; particles bounce off the walls.
;   * Colour: the hue advances every frame, so the burst cycles through
;     the palette instead of being a static colour field.
;
; SENTINELS (the usual $010000 block)
;   $010000  START       "the ROM booted"
;   $010004  DONE        "the demo is running"
;   $010008  COUNT       frames simulated
;   $01000C  SPARE       reserved
;   $010010  PARTICLES   how many particles are alive
;
; ASSEMBLER NOTES (rmac, learned the hard way -- see README.md)
;   * Only d0-d7 and a0-a7 exist; d8+ are "undefined expression".
;   * MOVEQ is data-register only.
;   * Shift immediates are 1..8, so anything bigger is a loop.
;   * MULU has no register-register form.
;   * ADDQ's immediate is 1..8.
;   * A MOVE with a register SOURCE and an absolute-long DESTINATION is
;     assembled backwards (move.l d0,$00110000 becomes
;     move.l #$00110000,d0) -- use an address register instead:
;     move.l #ADDR,a3 ; move.l d0,(a3).
;   * LEA and MOVE with a DISPLACEMENT (2(a1)) are mis-assembled: LEA
;     swallows the following bytes as an absolute address, and a store
;     with a displacement becomes PC-relative.  There is no working
;     displacement form at all, so this ROM addresses everything through
;     pointer registers and ADD.L #n,An.
;
; Build (from this directory, toolchain on PATH):
;   eval "$(tools/jaguar-toolchain/setup.sh env)"
;   rmac -fb -o benchdemo_particles.o benchdemo_particles.s
;   rln  -n -a 800000 x x -o benchdemo_particles.j64 benchdemo_particles.o

        .68000
        .text

        .include "cartboot.inc"

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

FB_BASE        .equ    $00030000          ; 320x240x16bpp = 153600 bytes
        LIST_BASE      .equ    $00020000
        LIST_BASE_LO   .equ    (LIST_BASE&$FFFF)
        LIST_BASE_HI   .equ    ((LIST_BASE>>16)&$FFFF)
        BMP_OBJ        .equ    LIST_BASE+0
        STOP_OBJ       .equ    LIST_BASE+16

; --- particles -------------------------------------------------------
PARTICLE_BASE  .equ    $00110000          ; 256 * 16 bytes = 4096
        PARTICLE_COUNT .equ    256
        PARTICLE_STRIDE .equ    16                ; x, y, vx, vy (LONGs)

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
        BMP_P0_HI      .equ    $03000040
        BMP_P0_LO      .equ    $023C0000

; p1: xpos=0, depth=4 (16bpp), pitch=1 phrase (8 bytes), dwidth=640
;     bytes/line (80 << 18), iwidth=80 phrases (320 px).
        BMP_P1_HI      .equ    $00000005          ; iwidth 80 spills into the high word
        BMP_P1_LO      .equ    $0140C000

        STOP_P0_HI     .equ    $00000000
        STOP_P0_LO     .equ    $00000004

; --- physics ---------------------------------------------------------
        ; The burst's upward drift DECAYS with the velocity: a constant -1 per
; frame accumulated (the drag never touched it) and carried every particle
; off the top of the screen within seconds -- the "then black" you saw
; after the initial burst.  Zero keeps the burst where it is.
DRIFT          .equ    0                  ; no constant drift: the burst settles
        CENTER_X       .equ    SCR_W/2
        CENTER_Y       .equ    SCR_H/2

; --- sentinels -------------------------------------------------------
        MB_SENT_PART   .equ    MB_SENT_BASE+16
                
; --- register use ----------------------------------------------------
; a0  framebuffer pointer
; a1  particle table: x
; a2  particle table: y
; a3  particle table: vx
; a4  particle table: vy
; a5  scratch address
; a6  scratch address
; d0  scratch
; d1  loop counter
; d2  particle index
; d3  frame number
; d4  x
; d5  y
; d6  vx
; d7  vy

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
        ; $FFFFFFFC (discarded) and the rts returns to whatever is in the
        ; stack slot -- garbage.  The demo uses jsr/rts, so it must set
        ; A7 itself.  (The microbenchmark ROMs never call a subroutine,
        ; which is why they never noticed.)
        move.l  #$00003FF0,a7


; ---- 1. program the display geometry --------------------------------
        move.w  #VMODE_VAL,TOM_VMODE
        move.w  #VDB_VAL,TOM_VDB
        move.w  #VDE_VAL,TOM_VDE

; ---- 2. build the object list ---------------------------------------
        move.l  #BMP_P0_HI,BMP_OBJ
        move.l  #BMP_P0_LO,BMP_OBJ+4
        move.l  #BMP_P1_HI,BMP_OBJ+8
        move.l  #BMP_P1_LO,BMP_OBJ+12
        move.l  #STOP_P0_HI,STOP_OBJ
        move.l  #STOP_P0_LO,STOP_OBJ+4

; ---- 3. point OLP at the list ---------------------------------------
        move.w  #LIST_BASE_LO,TOM_OLP_LO
        move.w  #LIST_BASE_HI,TOM_OLP_HI

; ---- 4. seed the particles ------------------------------------------
; Deterministic pseudo-random sequence (a 32-bit LCG), so the explosion
; is the same on every run and two frames can be compared directly.
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

        ; vx: a pseudo-random value in -3..3
        move.l  d0,d2
        moveq   #29,d3
seed_shr29:
        lsr.l   #1,d2
        dbra    d3,seed_shr29            ; 29 shifts -> seed >> 29
        andi.l  #$000F,d2               ; the speed: -8..7 (the drag is
        sub.l   #8,d2                   ; 15/16, so this spreads ~128 px)
        move.l  d2,(a3)

        ; vy: a pseudo-random value in -6..-1 (the burst goes UP first)
        move.l  d0,d2
        moveq   #26,d3
seed_shr26:
        lsr.l   #1,d2
        dbra    d3,seed_shr26            ; 26 shifts -> seed >> 26
        andi.l  #$000F,d2               ; the speed: -8..7
        sub.l   #8,d2
        move.l  d2,(a4)

        ; next seed: seed = seed*1664525 + 1013904223, computed with the
        ; 68000's MULU (source-only) on the halves.
        move.l  d0,d2
        mulu.w  #$6A0D,d2                ; low16(seed) * 0x6A0D
        move.l  d0,d3
        moveq   #16,d4
seed_shl:
        lsr.l   #1,d3
        dbra    d4,seed_shl              ; d3 = seed >> 16
        mulu.w  #$0019,d3                ; (seed>>16) * 0x19
        add.l   d2,d3
        move.l  d3,d0
        addi.l  #$3C6EF35F,d0

        ; advance the four pointers by the stride
        add.l   #PARTICLE_STRIDE,a1
        add.l   #PARTICLE_STRIDE,a2
        add.l   #PARTICLE_STRIDE,a3
        add.l   #PARTICLE_STRIDE,a4
        dbra    d1,seedloop


; ---- 5. clear the framebuffer ---------------------------------------
        move.l  #FB_BASE,a0
        move.w  #0,d0
        move.w  #(SCR_H*SCR_W/8)-1,d1     ; 9600 longword stores = 76800 words
        move.l  #0,d3
fbclr:
        move.l  d3,(a0)+
        addq.l  #1,d3
        dbra    d1,fbclr


; ---- 6. run ----------------------------------------------------------
        move.l  #MB_MAGIC_68K,MB_SENT_DONE
        move.l  #PARTICLE_COUNT,a5
        move.l  a5,MB_SENT_PART
        moveq   #0,d3                     ; frame counter

frameloop:
        ; ---- wait until the beam is inside the visible window ...
waitup:
        move.w  TOM_VC,d0
        andi.w  #$07FF,d0
        cmpi.w  #VDB_VAL,d0
        blt.w   waitup

        ; ---- ... then until the field wraps back to the top.  Only there
        ;      is the OP idle (its first pass of the next field is at
        ;      VDB), and only then may the object be re-armed -- ONCE.
        ;      Re-arming on every poll inside the blanking window (38
        ;      times per field) races the OP's write-back and exhausts
        ;      the object: a black screen.
waitdn:
        move.w  TOM_VC,d0
        andi.w  #$07FF,d0
        cmpi.w  #VDB_VAL,d0
        bge.w   waitdn

        ; ---- re-arm the OP object (safe: the OP is not running here)
        move.l  #BMP_P0_HI,BMP_OBJ
        move.l  #BMP_P0_LO,BMP_OBJ+4
        move.w  #LIST_BASE_LO,TOM_OLP_LO
        move.w  #LIST_BASE_HI,TOM_OLP_HI

        ; ---- simulate and draw one frame ------------------------------
        move.l  #PARTICLE_BASE,a1
        move.l  #PARTICLE_BASE+4,a2
        move.l  #PARTICLE_BASE+8,a3
        move.l  #PARTICLE_BASE+12,a4
        move.w  #(PARTICLE_COUNT-1),d1
        moveq   #0,d2                     ; particle index
particleloop:
        ; --- load the particle
        move.l  (a1),d4                  ; x
        move.l  (a2),d5                 ; y
        move.l  (a3),d6                 ; vx
        move.l  (a4),d7                 ; vy

        ; --- erase the old position (2x2 block, black)
        jsr     erase_block

        ; --- advance.  The subroutines use d4/d5 as scratch, so x and y
        ; are re-read from the table (the table is the state).
        move.l  (a1),d4                  ; x
        move.l  (a2),d5                  ; y
        ; The burst DECELERATES (drag) instead of bouncing:
        ;     the velocities shrink by 1/8 every frame, so the whole
        ;     excursion stays well inside the screen and no bounds test
        ;     (a conditional) is needed at all.  This toolchain cannot
        ;     resolve a forward branch reference -- rmac defers it to the
        ;     linker and rln cannot patch an 8-bit displacement -- so
        ;     every conditional in this ROM is written as a backward loop.
        add.l   d6,d4                    ; x += vx
        add.l   d7,d5                    ; y += vy
        move.l  d6,d0
        asr.l   #4,d0
        sub.l   d0,d6                    ; drag: vx -= vx/16 (15/16 left)
        move.l  d7,d0
        asr.l   #4,d0
        sub.l   d0,d7                    ; drag: vy -= vy/16
        addi.l  #DRIFT,d7                ; a little upward drift

        ; --- store the new state
        move.l  d4,(a1)
        move.l  d5,(a2)
        move.l  d6,(a3)
        move.l  d7,(a4)

        ; --- draw the new position in the particle's colour
        jsr     draw_block

        ; --- next particle
        add.l   #PARTICLE_STRIDE,a1
        add.l   #PARTICLE_STRIDE,a2
        add.l   #PARTICLE_STRIDE,a3
        add.l   #PARTICLE_STRIDE,a4
        addq.w  #1,d2
        dbra    d1,particleloop

        ; ---- the frame is drawn; wait for the field to end -----------
waitout:
        move.w  TOM_VC,d0
        andi.w  #$07FF,d0
        cmpi.w   #VDE_VAL,d0
        bhi.w   waitout

        addq.w  #1,d3
        move.l  #MB_SENT_COUNT,a5
        move.l  d3,(a5)
        bra.w   frameloop

; ---------------------------------------------------------------------
; erase_block -- write a black 2x2 block at (d4,d5).
; ---------------------------------------------------------------------
erase_block:
        jsr     fb_addr                 ; a0 = FB_BASE + (y*320+x)*2
        moveq   #0,d2
        move.w  d2,(a0)
        move.l  a0,a5
        add.l   #2,a5
        move.w  d2,(a5)
        move.l  a0,a5
        add.l   #640,a5                  ; the row below
        move.w  d2,(a5)
        move.l  a5,a6
        add.l   #2,a6
        move.w  d2,(a6)
        rts

; ---------------------------------------------------------------------
; draw_block -- write a coloured 2x2 block at (d4,d5).
; The colour phase is d2 (particle index) + d3 (frame number).
; ---------------------------------------------------------------------
draw_block:
        ; colour: RGB555 with bit15 (RGB mode) and bit0 (RGB select).
        ; The hue rotates with the phase.
        ; d3 is the FRAME COUNTER and must survive this routine, so the
        ; colour maths uses d6/d7 (the velocities, already stored back
        ; into the particle table before the call).
        move.l  d2,d0
        add.l   d3,d0                    ; colour phase = index + frame
        move.l  d0,d1
        lsr.l   #8,d1
        andi.l  #$1F,d1                  ; red
        moveq   #3,d4
cr_shl3:
        lsl.l   #1,d1
        dbra    d4,cr_shl3
        moveq   #8,d4
cr_shl8:
        lsl.l   #1,d1
        dbra    d4,cr_shl8               ; red -> bits 15..11
        move.l  d0,d6
        moveq   #13,d4
cr_shr13:
        lsr.l   #1,d6
        dbra    d4,cr_shr13
        andi.l  #$1F,d6                  ; blue -> bits 10..6
        moveq   #4,d4
cr_shl4:
        lsl.l   #1,d6
        dbra    d4,cr_shl4
        or.l    d1,d6
        move.l  d0,d7
        andi.l  #$003F,d7                ; green -> bits 5..0
        or.l    d7,d6
        ori.l   #$0001,d6                ; bit0 = "this pixel is RGB, not CRY"
        lsr.l   #8,d6                    ; byte-swap for the OP's fetches
        move.l  d6,d7                    ; the colour word (memory order)

        jsr     fb_addr                 ; a0 = FB_BASE + (y*320+x)*2
        move.w  d7,(a0)
        move.l  a0,a5
        add.l   #2,a5
        move.w  d7,(a5)
        move.l  a0,a5
        add.l   #640,a5                  ; the row below
        move.w  d7,(a5)
        move.l  a5,a6
        add.l   #2,a6
        move.w  d7,(a6)
        rts

; ---------------------------------------------------------------------
; fb_addr -- a0 = FB_BASE + (d1*320 + d0)*2, clipped to the screen.
; ---------------------------------------------------------------------
fb_addr:
        ; d4 = x, d5 = y on entry; the pixel address comes back in a0.
        ;
        ; address = FB_BASE + y*640 + x*2, and y*640 = (y*5) << 7.
        ; No MULU (the 68000 has no register-register form) and no shift
        ; immediate over 8.
        ;
        ; REGISTER DISCIPLINE: d1 (the particle loop's DBRA counter),
        ; d2 (the particle index), d3 (the frame counter) and d6/d7
        ; (the velocities) are LIVE in the caller and must survive this
        ; call -- clobbering d1 alone makes the particle loop run 65536
        ; times and the burst flies off the screen.  So this routine
        ; may only touch d0, d4 and d5.
        move.l  d5,d0
        moveq   #2,d4
fb_x4:
        add.l   d0,d0                     ; d0 = y*4
        dbra    d4,fb_x4
        add.l   d5,d0                     ; d0 = y*5
        moveq   #7,d4
fb_x128:
        lsl.l   #1,d0
        dbra    d4,fb_x128                ; d0 = y*640
        move.l  d4,d5
        lsl.l   #1,d5                     ; d5 = x*2
        add.l   d5,d0
        add.l   #FB_BASE,d0
        move.l  d0,a0
        rts
