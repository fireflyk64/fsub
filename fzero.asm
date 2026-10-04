; F-Zero style city, proof of concept.
;
; The picture is ONE static tilemap of a road and city drawn in perspective (fzero_gfx.py).
; Nothing in VRAM changes while it runs.  Every scanline, in HBlank, two registers are
; rewritten for the line about to be drawn:
;
;   BGP  recolours the line.  Which part of a building (wall/roof/street) lies under a line
;        depends on that line's depth plus how far we have driven, so the city flows toward
;        the camera at the right speed for every line: slow at the horizon, fast up close.
;   SCX  slides the line sideways.  A different amount per line bends the road.
;
; Each frame the main loop works out those two values for all 144 lines into a spare buffer
; and VBlank swaps it in, so the interrupt only has to copy two bytes.
;
; Controls: Left/Right bend the road by hand, Start hands it back to the demo track,
;           Up/Down change speed, Select changes the song.

INCLUDE "include/hardware.inc"
INCLUDE "fzero_gfx/consts.inc"

DEF GFX_BANK    EQU 2
DEF LCDC_UPPER  EQU LCDCF_ON | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ16 | LCDCF_BG8000 | LCDCF_BG9800
DEF LCDC_LOWER  EQU LCDCF_ON | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ16 | LCDCF_BG8800 | LCDCF_BG9800
DEF SPEED_START EQU $0300       ; world units per frame, 8.8
DEF SPEED_MAX   EQU $08
DEF STAR_LINES  EQU 16          ; top lines scroll at half the skyline's rate
DEF CAR_X       EQU 72
DEF CAR_Y       EQU 118
DEF NUM_SONGS   EQU 4

; ---------------------------------------------------------------------------------------
SECTION "vblank vector", ROM0[$40]
    jp VBlankISR

; HBlank of line LY: load the registers for line LY+1.  Runs 144 times a frame, so it is
; placed right at the vector (it runs on through the unused timer/serial/joypad vectors).
SECTION "stat vector", ROM0[$48]
StatISR:
    push af
    push hl
    ldh a, [rLY]
    inc a
    ld l, a
    ldh a, [hFront]
    ld h, a
    ld a, [hl]
    ldh [rBGP], a
    inc h
    ld a, [hl]
    ldh [rSCX], a
    ld a, l
    cp SPLIT_LINE
    jr z, .split
    pop hl
    pop af
    reti
.split                          ; lower part of the picture takes its tiles from $9000
    ld a, LCDC_LOWER
    ldh [rLCDC], a
    pop hl
    pop af
    reti

SECTION "header", ROM0[$100]
    jp EntryPoint
    ds $150 - @, 0

; ---------------------------------------------------------------------------------------
SECTION "fzero code", ROM0

VBlankISR:
    push af
    push hl
    ldh a, [hReady]             ; a finished buffer waiting?  make it the live one
    or a
    jr z, .keep
    ldh [hFront], a
    xor a
    ldh [hReady], a
.keep
    ldh a, [hFront]
    ld h, a
    ld l, 0
    ld a, [hl]                  ; line 0 has no HBlank before it
    ldh [rBGP], a
    inc h
    ld a, [hl]
    ldh [rSCX], a
    ld a, LCDC_UPPER
    ldh [rLCDC], a
    ldh a, [hCarY]              ; OAM can only be written safely now
    ld [_OAMRAM], a
    ld [_OAMRAM + 4], a
    ld a, 1
    ldh [hVBlank], a
    pop hl
    pop af
    reti

EntryPoint:
    di
    ld sp, $E000
.waitVBlank
    ldh a, [rLY]
    cp 144
    jr c, .waitVBlank
    xor a
    ldh [rLCDC], a

    ld a, GFX_BANK
    ld [rROMB0], a
    ld de, Tiles8000
    ld hl, _VRAM8000
    ld bc, Tiles8000.end - Tiles8000
    call Copy
    ld de, CarTiles
    ld hl, _VRAM8000 + CAR_TILE * 16
    ld bc, CarTiles.end - CarTiles
    call Copy
    ld de, Tiles8800
    ld hl, _VRAM8800
    ld bc, Tiles8800.end - Tiles8800
    call Copy
    ld de, Tiles9000
    ld hl, _VRAM9000
    ld bc, Tiles9000.end - Tiles9000
    call Copy
    ld de, Tilemap
    ld hl, _SCRN0
    ld bc, Tilemap.end - Tilemap
    call Copy

    ; sprites: the car is two 8x16 objects side by side
    ld hl, _OAMRAM
    ld b, 160
    xor a
.clearOam
    ld [hl+], a
    dec b
    jr nz, .clearOam
    ld hl, _OAMRAM
    ld a, CAR_Y + 16
    ld [hl+], a
    ld a, CAR_X + 8
    ld [hl+], a
    ld a, CAR_TILE
    ld [hl+], a
    xor a
    ld [hl+], a
    ld a, CAR_Y + 16
    ld [hl+], a
    ld a, CAR_X + 16
    ld [hl+], a
    ld a, CAR_TILE + 2
    ld [hl+], a
    ld [hl], 0
    ld a, %11100000             ; car: 1 white, 2 dark grey, 3 black
    ldh [rOBP0], a

    ; both line buffers: sky palette for the top, something sane for the rest
    ld hl, wLinesA
    call InitLines
    ld hl, wLinesB
    call InitLines

    xor a
    ldh [hReady], a
    ldh [hVBlank], a
    ldh [hPos], a
    ldh [hPos + 1], a
    ldh [hPos + 2], a
    ldh [hSkyX], a
    ldh [hSkyX + 1], a
    ldh [hFrame], a
    ldh [hCurKeys], a
    ldh [hNewKeys], a
    ldh [hScript], a
    ldh [hSong], a
    ld a, HIGH(wLinesA)
    ldh [hFront], a
    ld a, LOW(SPEED_START)
    ldh [hSpeed], a
    ld a, HIGH(SPEED_START)
    ldh [hSpeed + 1], a
    ld a, BEND_LEVELS
    ldh [hBend], a
    ldh [hTarget], a
    ld a, 1
    ldh [hAuto], a
    ldh [hScriptTimer], a
    ld a, CAR_Y + 16
    ldh [hCarY], a

    ld de, note_table_rom       ; this repo's driver plays from a RAM copy of the notes
    ld hl, wNoteTable
    ld bc, 144
    call Copy
    ld a, $80
    ldh [rAUDENA], a
    ld a, $FF
    ldh [rAUDTERM], a
    ld a, $77
    ldh [rAUDVOL], a
    call StartSong

    ld a, STATF_MODE00
    ldh [rSTAT], a
    xor a
    ldh [rIF], a
    ld a, IEF_VBLANK | IEF_STAT
    ldh [rIE], a
    ld a, LCDC_UPPER
    ldh [rLCDC], a
    ei

MainLoop:
    xor a
    ldh [hVBlank], a
.wait
    halt
    ldh a, [hVBlank]
    or a
    jr z, .wait

    call UpdateKeys
    call Drive
    call BuildLines
    call SongBank
    call hUGE_dosound
    ldh a, [rLY]                ; load meter: the line on which this frame's work ended
    ldh [hLoad], a              ; (144 = started, wraps through 153 to 0; must stay < 144)
    jr MainLoop

; ---------------------------------------------------------------------------------------
; Fill one distance band of the BGP buffer.
; \1 = palette table for the band, \2 = first line after the band, \3 = 1 for far bands
; in: b = high byte of the BGP buffer, de = RowPhase + line.  e carries on into the next band.
MACRO FILL_BAND
    IF \3
        ldh a, [hPosCoarse]
    ELSE
        ldh a, [hPos + 1]
    ENDC
    ld c, a
    ld h, HIGH(\1)
.line\@
    ld a, [de]                  ; this line's depth
    add c                       ; plus distance driven
    ld l, a
    ld a, [hl]                  ; -> what the city looks like there
    ld d, b
    ld [de], a
    ld d, HIGH(RowPhase)
    inc e
    ld a, e
    cp \2
    jr nz, .line\@
ENDM

BuildLines:
    ldh a, [hFront]
    xor HIGH(wLinesA) ^ HIGH(wLinesB)
    ld b, a                     ; b = the buffer not on screen

    ld d, HIGH(RowPhase)
    ld e, HORIZON
    FILL_ALL_BANDS

    ; SCX: stars, skyline, then the bend table for the ground
    inc b
    ld h, b
    ld l, 0
    ldh a, [hSkyX + 1]
    ld c, a
    srl a
.stars
    ld [hl+], a
    bit 4, l                    ; STAR_LINES = 16
    jr z, .stars
    ld a, c
.skyline
    ld [hl+], a
    ld a, l
    cp HORIZON
    ld a, c
    jr nz, .skyline

    ld a, GFX_BANK
    ld [rROMB0], a
    ldh a, [hBend]
    add a
    ld l, a
    ld h, 0
    ld de, BendPointers
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ld d, b
    ld e, HORIZON
.ground
    ld a, [hl+]
    ld [de], a
    inc e
    ld a, e
    cp 144
    jr nz, .ground

    dec b
    ld a, b
    ldh [hReady], a             ; VBlank will show it
    ret

; ---------------------------------------------------------------------------------------
; Speed, bend, distance and the direction the skyline faces.
Drive:
    ld hl, hFrame
    inc [hl]

    ldh a, [hNewKeys]
    and PADF_SELECT
    jr z, .noSong
    ldh a, [hSong]
    inc a
    cp NUM_SONGS
    jr c, .songOk
    xor a
.songOk
    ldh [hSong], a
    call StartSong
.noSong

    ; --- speed: Up/Down
    ldh a, [hSpeed]
    ld l, a
    ldh a, [hSpeed + 1]
    ld h, a
    ldh a, [hCurKeys]
    ld b, a
    bit 6, b                    ; PADF_UP
    jr z, .noUp
    ld de, $0010
    add hl, de
    ld a, h
    cp SPEED_MAX
    jr c, .noUp
    ld hl, SPEED_MAX << 8
.noUp
    bit 7, b                    ; PADF_DOWN
    jr z, .noDown
    ld de, -$0010
    add hl, de
    jr c, .noDown               ; no borrow
    ld hl, 0
.noDown
    ld a, l
    ldh [hSpeed], a
    ld a, h
    ldh [hSpeed + 1], a

    ; --- distance driven (24 bit: fraction, units, 256s)
    ldh a, [hPos]
    add l
    ldh [hPos], a
    ldh a, [hPos + 1]
    adc h
    ldh [hPos + 1], a
    ld c, a
    ldh a, [hPos + 2]
    adc 0
    ldh [hPos + 2], a
    ; far bands count in steps of 16 units
    swap a
    and $F0
    ld e, a
    ld a, c
    swap a
    and $0F
    or e
    ldh [hPosCoarse], a

    ; --- where should the bend be heading?
    ld a, b
    and PADF_LEFT | PADF_RIGHT
    jr z, .noSteer
    xor a
    ldh [hAuto], a
.noSteer
    bit 3, b                    ; PADF_START
    jr z, .noStart
    ld a, 1
    ldh [hAuto], a
.noStart
    ldh a, [hAuto]
    or a
    jr z, .manual
    ld hl, hScriptTimer         ; demo track: (frames, bend) pairs
    dec [hl]
    jr nz, .haveTarget
    ldh a, [hScript]
    add a
    ld e, a
    ld d, 0
    ld hl, Track
    add hl, de
    ld a, [hl+]
    ldh [hScriptTimer], a
    ld a, [hl]
    ldh [hTarget], a
    ldh a, [hScript]
    inc a
    cp (Track.end - Track) / 2
    jr c, .scriptOk
    xor a
.scriptOk
    ldh [hScript], a
    jr .haveTarget
.manual
    ld a, BEND_LEVELS
    bit 5, b                    ; PADF_LEFT
    jr z, .notLeft
    xor a
.notLeft
    bit 4, b                    ; PADF_RIGHT
    jr z, .notRight
    ld a, BEND_LEVELS * 2
.notRight
    ldh [hTarget], a
.haveTarget

    ; --- ease the bend toward it, one step every other frame
    ldh a, [hFrame]
    rra
    jr c, .bendDone
    ldh a, [hTarget]
    ld c, a
    ldh a, [hBend]
    cp c
    jr z, .bendDone
    jr c, .bendUp
    dec a
    dec a
.bendUp
    inc a
    ldh [hBend], a
.bendDone

    ; --- the skyline turns while we are in a bend: skyX += bend * speed
    ldh a, [hSpeed + 1]
    add a
    add a
    jr z, .skyDone
    ld b, a
    ldh a, [hBend]
    sub BEND_LEVELS
    ld e, a
    add a                       ; sign extend into d
    sbc a
    ld d, a
    ldh a, [hSkyX]
    ld l, a
    ldh a, [hSkyX + 1]
    ld h, a
.skyAdd
    add hl, de
    dec b
    jr nz, .skyAdd
    ld a, l
    ldh [hSkyX], a
    ld a, h
    ldh [hSkyX + 1], a
.skyDone

    ; --- hover bob
    ldh a, [hFrame]
    and %00010000
    swap a
    add CAR_Y + 16
    ldh [hCarY], a
    ret

; (frames to hold, bend 0..64 where 32 is straight)
Track:
    db 150, 32
    db 200, 52
    db 120, 32
    db 220, 8
    db 100, 40
    db 160, 64
    db 140, 20
    db 180, 0
.end

; ---------------------------------------------------------------------------------------
StartSong:
    call SongBank
    ldh a, [hSong]
    add a
    add a
    ld e, a
    ld d, 0
    ld hl, Songs + 2
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    jp hUGE_init

SongBank:
    ldh a, [hSong]
    add a
    add a
    ld e, a
    ld d, 0
    ld hl, Songs
    add hl, de
    ld a, [hl]
    ld [rROMB0], a
    ret

MACRO SONG
    dw BANK(\1), \1
ENDM
Songs:
    SONG lvl4song
    SONG level3_music
    SONG _level2_music
    SONG menusong

; hl = BGP page of a buffer (SCX page follows it)
InitLines:
    ld de, SkyBgp
    ld b, HORIZON
.sky
    ld a, [de]
    ld [hl+], a
    inc de
    dec b
    jr nz, .sky
    ld a, %11100100
.rest
    ld [hl+], a
    inc l
    dec l
    jr nz, .rest
    ld a, VIEW_X
.scx
    ld [hl+], a
    inc l
    dec l
    jr nz, .scx
    ret

; de = source, hl = destination, bc = length
Copy:
    ld a, [de]
    ld [hl+], a
    inc de
    dec bc
    ld a, b
    or c
    jr nz, Copy
    ret

UpdateKeys:
    ld a, P1F_GET_BTN
    call .nibble
    ld b, a
    ld a, P1F_GET_DPAD
    call .nibble
    swap a
    xor b
    ld b, a
    ld a, P1F_GET_NONE
    ldh [rP1], a
    ldh a, [hCurKeys]
    xor b
    and b
    ldh [hNewKeys], a
    ld a, b
    ldh [hCurKeys], a
    ret
.nibble
    ldh [rP1], a
    call .knownret
    ldh a, [rP1]
    ldh a, [rP1]
    ldh a, [rP1]
    or $F0
.knownret
    ret

BendPointers:
    FOR N, BEND_LEVELS * 2 + 1
        dw BendTables + N * GROUND_LINES
    ENDR

SkyBgp:
    INCBIN "fzero_gfx/skybgp.bin"

; ---------------------------------------------------------------------------------------
; Page-aligned lookups: the low byte of the address is the index.
SECTION "row phase", ROM0, ALIGN[8]
RowPhase:                       ; indexed by screen line
    INCBIN "fzero_gfx/rowphase.bin"

MACRO PAL_TABLE
SECTION "pal \1", ROM0, ALIGN[8]
Pal\1:
    INCBIN "fzero_gfx/pal_\2.bin"
ENDM
    PAL_TABLE Near0, near0
    PAL_TABLE Near1, near1
    PAL_TABLE Near2, near2
    PAL_TABLE Near3, near3
    PAL_TABLE Far0, far0
    PAL_TABLE Far1, far1
    PAL_TABLE Far2, far2

SECTION "fzero gfx", ROMX, BANK[GFX_BANK]
Tiles8000:
    INCBIN "fzero_gfx/tiles8000.bin"
.end
Tiles8800:
    INCBIN "fzero_gfx/tiles8800.bin"
.end
Tiles9000:
    INCBIN "fzero_gfx/tiles9000.bin"
.end
CarTiles:
    INCBIN "fzero_gfx/car.bin"
.end
Tilemap:
    INCBIN "fzero_gfx/map.bin"
.end
BendTables:                     ; (BEND_LEVELS*2+1) x GROUND_LINES values of SCX
    INCBIN "fzero_gfx/bend.bin"

; ---------------------------------------------------------------------------------------
; Two sets of per-line values; one is on screen while the other is being filled.
; Each is a BGP page followed by an SCX page, indexed by screen line.
SECTION "line buffers", WRAM0[$C100]
wLinesA: ds 512
wLinesB: ds 512

SECTION "note table", WRAM0
wNoteTable:: ds 144

SECTION "fzero hram", HRAM
hFront:       db    ; high byte of the buffer the interrupts read
hReady:       db    ; high byte of a finished buffer, 0 if none
hVBlank:      db
hFrame:       db
hPos:         ds 3  ; distance driven: fraction, units, 256s
hPosCoarse:   db    ; the same in steps of 16 units
hSpeed:       dw
hBend:        db    ; 0 hard left .. 32 straight .. 64 hard right
hTarget:      db
hSkyX:        dw
hAuto:        db
hScript:      db
hScriptTimer: db
hCarY:        db
hSong:        db
hCurKeys:     db
hNewKeys:     db
hLoad:        db
