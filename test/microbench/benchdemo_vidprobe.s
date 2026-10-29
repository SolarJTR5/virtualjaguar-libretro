; test/microbench/benchdemo_vidprobe.s -- video-path probe ROM.
;
; Not a benchmark: a minimal program that stands up an Object Processor
; BITMAP object covering the whole screen and fills the framebuffer with a
; known pattern, so a harness can prove the OP actually scanned it out.
;
; This is the video-path half of the particle demo, kept as its own ROM
; because it is the part most likely to need debugging: the object-list
; encoding (p0/p1 bit fields), the 68K<->OP handshake (re-priming the
; object every frame), and the framebuffer geometry are all easier to get
; right in isolation than inside a demo that also simulates.
;
; What it does:
;   1. installs a BITMAP object + STOP in a list at $00020000;
;   2. points TOM's OLP at it;
;   3. fills the 320x240x16bpp framebuffer at $00030000 with a pattern
;      whose every pixel encodes its own coordinates, so a harness can
;      check the geometry AND the pixel order without a reference image;
;   4. re-primes the object (HEIGHT/DATA) once per frame while the beam
;      is in vertical blanking, because the OP decrements HEIGHT and
;      advances DATA on every line it renders.
;
; Object encoding (from src/tom/op.c):
;   p0 = type | ypos<<3 | height<<14 | link<<21 | data<<40
;   p1 = xpos | depth<<12 | pitch<<15 | dwidth<<18 | iwidth<<28
; with pitch = bytes per phrase (8) and dwidth = bytes per source line.

        .68000
        .text

        .include "cartboot.inc"

; --- TOM registers ---------------------------------------------------
TOM_OLP_LO     .equ    $00F00020
TOM_OLP_HI     .equ    $00F00022
TOM_VC         .equ    $00F00006
TOM_BG         .equ    $00F00058
TOM_LBUF       .equ    $00F01800
TOM_LBUF_A     .equ    $00F00800
TOM_LBUF_B     .equ    $00F01000
TOM_VMODE      .equ    $00F00028
TOM_VDB        .equ    $00F00046
TOM_VDE        .equ    $00F00048

; The visible window (halflines) and the video mode register.  These are
; the reset values, but the core derives its DISPLAY GEOMETRY (tomWidth /
; tomHeight) only when a register in $28..$4F is WRITTEN (tom.c's
; TOMWriteWord -> "detect screen resolution changes").  A ROM that never
; programs them leaves tomWidth at 0, and the scanline renderers write
; zero pixels per row -- a completely black screen even though the OP
; filled the line buffer correctly.
VMODE_VAL      .equ    $07C1         ; bit 8 (VARMOD) = the per-pixel
                                        ; CRY/RGB16 renderer.  WITHOUT it
                                        ; the core uses the CRY renderer
                                        ; and looks every pixel up in
                                        ; the (all-zero) CLUT: black.
VDB_VAL        .equ    38
VDE_VAL        .equ    518

; Where the LBUF readback lands (readable from a host debugger).
; NOTE: main RAM is 2 MB ($000000-$1FFFFF).  A scratch address above
; that (e.g. $00070000) is silently dropped -- the 68K write goes
; nowhere and the readback reads unrelated RAM.
LBUF_SNAP      .equ    $00100000

; --- geometry --------------------------------------------------------
SCR_W          .equ    320
SCR_H          .equ    240
FB_BASE        .equ    $00030000
FB_BYTES       .equ    SCR_W*SCR_H*2

LIST_BASE      .equ    $00020000
LIST_BASE_LO   .equ    (LIST_BASE&$FFFF)
LIST_BASE_HI   .equ    ((LIST_BASE>>16)&$FFFF)
BMP_OBJ        .equ    LIST_BASE+0
STOP_OBJ       .equ    LIST_BASE+16

; --- object list fields ---------------------------------------------
; p0: type=0 (BITMAP), ypos=0, height=240, link=STOP_OBJ, data=FB_BASE
;
;   data   = $00030000 -> $00030000 << 40 lands in the high longword's
;            bits 24..25: $30000 has bits 16 and 17 set, so
;            $30000 << 40 = bits 56,57 -> high32 $03000000.
;   link   = $00020010 -> $20010 << 21.  LINK bit 17 (0x20000) lands on
;            p0 bit 38 = HIGH longword bit 6 ($00000040); LINK bit 4
;            (0x10) lands on p0 bit 25 = LOW longword bit 25
;            ($02000000).  Getting the high-longword bit wrong (5
;            instead of 6) encodes link $010010 instead of $020010:
;            the OP then follows the link into the sentinel block and
;            the screen stays black.
;   height = 240 << 14 = $003C0000.
BMP_P0_HI      .equ    $03000040
BMP_P0_LO      .equ    $023C0000

; p1: xpos=0, depth=4 (16bpp), pitch=1 phrase (8 bytes), dwidth=640
;     bytes/line (80 << 18), iwidth=80 phrases (320 px).
;
;   dwidth field: (p1 & $0FFC0000) >> 15 = bytes advanced per rendered
;   line, so the field holds bytes>>3 = 80 -> 80 << 18 = $01400000.
;   iwidth field: (p1 >> 28) & $3FF = 80 -> 80 << 28 = $500000000, i.e.
;   it SPILLS INTO THE HIGH LONGWORD ($00000005); the low longword keeps
;   only the fields below bit 28.
;   pitch field: (p1 >> 15) & 7 -> 1, then <<3 = 8 bytes per phrase.
;   depth field: (p1 >> 12) & 7 -> 4 = 16bpp.
BMP_P1_HI      .equ    $00000005
BMP_P1_LO      .equ    $0140C000

; STOP object: type 4, no IRQ.
STOP_P0_HI     .equ    $00000000
STOP_P0_LO     .equ    $00000004

; The OP only runs on even halflines, and the visible window is
; VDB..VDE (38..518 by default: 240 even halflines).  The object is
; re-primed while the beam is in blanking so the frame is never torn by
; a half-written object.
VDB_DEFAULT    .equ    38
VDE_DEFAULT    .equ    518

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
        moveq   #0,d2                  ; frame counter (d2 is clobbered below)

; ---- 1. program the display geometry --------------------------------
; Writing VMODE/VDB/VDE is what makes the core compute its display
; geometry (tomWidth/tomHeight).  Without it the scanline renderers draw
; a zero-pixel row and the screen stays black.
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

; ---- 3. point OLP at the list --------------------------------------
; NOTE: the address halves are named constants on purpose.  rmac
; mis-assembles `move.w #((LIST_BASE>>16)&$FFFF),TOM_OLP_HI` -- the `&`
; outside the parentheses is not part of the immediate expression as
; this assembler reads it, and the store lands at a garbage address
; (observed: `move.w #$000000f0,$002033fc`).  The result is a silently
; wrong OLP and a black screen, so keep the halves in .equ.
        move.w  #LIST_BASE_LO,TOM_OLP_LO
        move.w  #LIST_BASE_HI,TOM_OLP_HI

; ---- 4. fill the framebuffer ---------------------------------------
; Each pixel: bit15 set (direct-RGB mode in the core's MIX16 table),
; bit0 set (the mix table's "RGB, not CRY" selector), red = x>>3,
; green = y>>3.
;
; The store is a WORD store, not a longword one: the framebuffer is
; 16-bit pixels, and the OP reads two bytes per pixel.  A longword
; store would pad every pixel to four bytes and the OP would then see
; a zero in front of each real pixel.
        lea     FB_BASE,a0
        move.w  #(SCR_H-1),d1
        moveq   #0,d2                 ; y
yl:
        move.w  #(SCR_W-1),d3
        moveq   #0,d4                 ; x
xl:
        move.w  d4,d5
        lsr.w   #3,d5                 ; red = x >> 3
        move.w  d2,d6
        lsr.w   #3,d6                 ; green = y >> 3
        lsl.w   #3,d5                 ; red -> bits 15..11 (11 = 3 + 8;
        lsl.w   #8,d5                 ;  a 68000 shift immediate is 1..8)
        lsl.w   #5,d6                 ; green -> bits 10..5
        or.w    d5,d6
        or.w    #$0180,d6             ; byte-swapped: bit15 = RGB mode, bit0 = RGB select
        move.w  d6,(a0)+
        addq.w  #1,d4
        dbra    d3,xl
        addq.w  #1,d2
        dbra    d1,yl

; ---- 5. re-prime the object once per FIELD --------------------------
; The OP decrements the object's HEIGHT and advances its DATA pointer on
; every line it renders, so the object must be re-armed every time the
; beam leaves the visible window -- which is once per FIELD, not once per
; frame: a Jaguar field is VP+1 = 524 halflines and the object covers
; exactly the even halflines the OP renders in one field.
;
; The re-arm has to happen ONCE, and it has to happen where the OP is
; not running.  Two traps, both hit while writing this:
;
;   * Waiting for "VC > VDE" is a LEVEL test, true for the ~5 halflines
;     of blanking, and the 68K polls it in a tight loop -- so the ROM
;     re-armed the object ~200 times per field.
;   * Each re-arm is two longword stores (DATA, then HEIGHT/LINK).  If
;     the OP reads the object between them it sees a FRESH DATA with an
;     EXHAUSTED HEIGHT of 0, skips the object, and the line comes out
;     background black.  The screen was entirely black for exactly this
;     reason.
;
; So: wait for VC to come back BELOW VDB -- which happens exactly once
; per field, in the blanking BEFORE the OP's first pass of that field
; (the OP only runs on even halflines from VDB).  Re-arm there: the OP
; cannot be mid-object, so the two stores are never seen torn.
;
; VC ($F00006) is updated by the core on every halfline.  Bit 11 ($0800)
; marks the lower field and stays set for that whole field, so the
; comparison has to mask it off.
frame:
        ; Wait until the beam is INSIDE the visible window ...
waitup:
        move.w  TOM_VC,d0
        andi.w  #$07FF,d0              ; drop the lower-field bit
        cmpi.w  #VDB_DEFAULT,d0
        blt.w   waitup                 ; still in the blanking above

        ; ... then until the field wraps back to the top.  Only then is
        ; the OP idle (its first pass of the next field is at VDB), and
        ; only then may the object be re-armed -- ONCE.  Re-arming on
        ; every poll inside the blanking window (38 times per field)
        ; races the OP's write-back and leaves the field with an
        ; exhausted object: a black screen.
waitdn:
        move.w  TOM_VC,d0
        andi.w  #$07FF,d0
        cmpi.w  #VDB_DEFAULT,d0
        bge.w   waitdn                 ; still in the visible area

        ; re-arm the object, where the OP is guaranteed not to be running
        move.l  #BMP_P0_HI,BMP_OBJ
        move.l  #BMP_P0_LO,BMP_OBJ+4
        move.w  #LIST_BASE_LO,TOM_OLP_LO
        move.w  #LIST_BASE_HI,TOM_OLP_HI

        ; wait for the field to finish
waitout:
        move.w  TOM_VC,d0
        andi.w  #$07FF,d0
        cmp.w   #VDE_DEFAULT,d0
        bhi.w   waitout                ; still in the visible area
        ; record what VC looked like (diagnostic)
        move.w  TOM_VC,d3
        move.l  d3,LBUF_SNAP+16
        ; track the VC range seen across the wait loop
        move.w  TOM_VC,d4
        andi.w  #$07FF,d4
        move.l  d4,LBUF_SNAP+20
        move.l  d4,LBUF_SNAP+24

; ---- 6. read the line buffer back ----------------------------------
; The OP writes its pixels into TOM's line buffer at $F01800; the core
; then copies that buffer into the host framebuffer.  Snapshotting the
; first few words here is how a harness tells "the OP drew nothing" from
; "the OP drew but the core did not present it".
;
; All three LBUF banks are sampled: A ($F00800), B ($F01000) and the
; "currently selected" one ($F01800).
        lea     LBUF_SNAP,a0
        move.w  TOM_LBUF,d1
        move.l  d1,(a0)+               ; raw LBUF word 0
        move.w  TOM_LBUF+2,d1
        move.l  d1,(a0)+               ; raw LBUF word 1
        move.w  TOM_LBUF_A,d1
        move.l  d1,(a0)+
        move.w  TOM_LBUF_B,d1
        move.l  d1,(a0)+

; ---- 7. count frames and loop ---------------------------------------
        addq.l  #1,d2
        move.l  #MB_SENT_COUNT,a3
        move.l  d2,(a3)
        move.l  #MB_MAGIC_68K,MB_SENT_DONE
        bra.w   frame                  ; .w: the loop body is long (>128 bytes)
