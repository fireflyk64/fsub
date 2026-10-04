; F-Zero style city, proof of concept.
;
; The picture is ONE static tilemap of a road and city drawn in perspective (tools/gen_gfx.py).
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
; Steering moves the camera sideways, which is a shear: near lines slide a lot, far lines
; hardly at all.  That is one more per-line table added into SCX.
;
; Forks: a tunnel mouth (a sprite that grows as it nears) comes down the left lane.  Drive
; into it and the screen fades out, the track switches to the tunnel branch, and it fades
; back in.  The tunnel itself is the same tilemap under darker palette tables.
;
; Controls: Left/Right steer, Up/Down change speed, A jumps.
;
; Music is music/race.uge (edit it in hUGETracker), played by hUGEDriver.

INCLUDE "include/hardware.inc"
INCLUDE "build/consts.inc"

DEF GFX_BANK    EQU 2
DEF LCDC_UPPER  EQU LCDCF_ON | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ16 | LCDCF_BG8000 | LCDCF_BG9800
DEF LCDC_LOWER  EQU LCDCF_ON | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ16 | LCDCF_BG8800 | LCDCF_BG9800
DEF SPEED_START EQU $0300       ; world units per frame, 8.8
DEF SPEED_MAX   EQU $08
DEF STAR_LINES  EQU 16          ; top lines scroll at half the skyline's rate
DEF CAR_X       EQU 72          ; screen position when centred
DEF CAR_Y       EQU 118
DEF SHADOW_TILE EQU CAR_TILE + 12
DEF MOUTH_TILE  EQU CAR_TILE + 16
DEF OBJ_SPRITES EQU 5           ; OAM entries kept for the road object
DEF LANE_EDGE   EQU -6          ; left of this, the car is in the tunnel's lane
DEF FADE_LENGTH EQU 64          ; frames; the switch happens half way, in the dark
DEF X_LIMIT     EQU ROAD_HALF - 12  ; how far from the centre line the car may go
DEF STEER_MAX   EQU 24          ; sideways speed, 1/16 pixel per frame
DEF BANK_AT     EQU 10          ; sideways speed at which the car visibly leans
DEF JUMP_SPEED  EQU $0300       ; upward speed at take-off, 8.8 pixels per frame
DEF GRAVITY     EQU $28
DEF RAIL_SCRUB  EQU $20         ; speed lost per frame against the edge of the road

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
    ldh a, [hCarX]
    ld [_OAMRAM + 1], a
    ld [_OAMRAM + 9], a
    add 8
    ld [_OAMRAM + 5], a
    ld [_OAMRAM + 13], a
    ldh a, [hCarTile]
    ld [_OAMRAM + 2], a
    add 2
    ld [_OAMRAM + 6], a
    ldh a, [hShadowTile]
    ld [_OAMRAM + 10], a
    ld [_OAMRAM + 14], a
    push bc
    push de
    ld hl, wObjOam
    ld de, _OAMRAM + 16
    ld b, OBJ_SPRITES * 4
.objOam
    ld a, [hl+]
    ld [de], a
    inc e
    dec b
    jr nz, .objOam
    pop de
    pop bc
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

    ; sprites: the car is two 8x16 objects side by side, its shadow two more behind it
    ld hl, _OAMRAM
    ld b, 160
    xor a
.clearOam
    ld [hl+], a
    dec b
    jr nz, .clearOam
    ld de, InitialOam
    ld hl, _OAMRAM
    ld bc, InitialOam.end - InitialOam
    call Copy
    ld a, %11100000             ; car: 1 white, 2 dark grey, 3 black
    ldh [rOBP0], a
    ld a, %10100000             ; shadow: all dark grey
    ldh [rOBP1], a

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
    ldh [hObjOn], a
    ldh [hTunnel], a
    ldh [hFadeStep], a
    ldh [hFadeLevel], a
    ldh [hX], a
    ldh [hX + 1], a
    ldh [hVX], a
    ldh [hAir], a
    ldh [hZ], a
    ldh [hZ + 1], a
    ldh [hVZ], a
    ldh [hVZ + 1], a
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
    ldh [hScriptTimer], a
    ld a, LOW(Track)
    ldh [hTrack], a
    ld a, HIGH(Track)
    ldh [hTrack + 1], a
    ld a, CAR_Y + 16
    ldh [hCarY], a
    ld a, CAR_X + 8
    ldh [hCarX], a
    ld a, CAR_TILE
    ldh [hCarTile], a
    ld a, SHEAR_MAX
    ldh [hShear], a
    ld a, SHADOW_TILE
    ldh [hShadowTile], a

    ld de, note_table_rom       ; this driver plays from a RAM copy of the note table
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
    call UpdateObject
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
    ldh a, [hTunnel]
    or a
    jp nz, .tunnel
    FILL_ALL_BANDS
    ld de, SkyBgp               ; sky fades toward the horizon glow
    ld h, b
    ld l, 0
.sky
    ld a, [de]
    ld [hl+], a
    inc de
    ld a, l
    cp HORIZON
    jr nz, .sky
    jp .bgpDone
.tunnel
    FILL_TUNNEL_BANDS
    ld h, b                     ; no sky down here: everything above the road is black
    ld l, 0
    ld a, $FF
.roof
    ld [hl+], a
    ld a, l
    cp HORIZON
    ld a, $FF
    jr nz, .roof
.bgpDone

    ; fading: push every line's palette through a "darker" table
    ldh a, [hFadeLevel]
    or a
    jr z, .noFade
    add HIGH(FadeTables) - 1
    ld h, a
    ld d, b
    ld e, 0
.fade
    ld a, [de]
    ld l, a
    ld a, [hl]
    ld [de], a
    inc e
    ld a, e
    cp 144
    jr nz, .fade
.noFade

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

    ; ground: bend (how the road curves) + shear (where the camera is across it)
    ld d, b
    ld a, GFX_BANK
    ld [rROMB0], a
    ldh a, [hShear]
    add a
    ld l, a
    ld h, 0
    ld bc, ShearPointers
    add hl, bc
    ld a, [hl+]
    ld b, [hl]
    ld c, a
    ldh a, [hBend]
    add a
    ld l, a
    ld h, 0
    push de
    ld de, BendPointers
    add hl, de
    pop de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ld e, HORIZON
.ground
    ld a, [bc]
    add [hl]
    inc bc
    inc hl
    ld [de], a
    inc e
    ld a, e
    cp 144
    jr nz, .ground

    ld a, d
    ldh [hBuiltScx], a          ; UpdateObject looks up where the road is on each line
    dec a
    ldh [hReady], a             ; VBlank will show it
    ret

; ---------------------------------------------------------------------------------------
; The road object (tunnel mouth): work out which line it is on, how big, and where the
; road has been slid to on that line, and stage its sprites for VBlank.
UpdateObject:
    ld hl, wObjOam
    ld b, OBJ_SPRITES * 4
    xor a
.clear
    ld [hl+], a
    dec b
    jr nz, .clear
    ldh a, [hObjOn]
    or a
    ret z

    ldh a, [hPos + 1]           ; distance ahead = where it is - where we are
    ld c, a
    ldh a, [hPos + 2]
    ld b, a
    ldh a, [hObjZ]
    sub c
    ld l, a
    ldh a, [hObjZ + 1]
    sbc b
    ld h, a
    cp 8                        ; 2048+ (or negative): gone past
    jp nc, .gone
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ld h, HIGH(DistToLine)
    ld a, [hl]                  ; ground line d, 1 at the horizon
    cp GROUND_LINES + 1
    jr nc, .gone
    ld c, a

    cp CAR_D                    ; reached the car: are we in its lane, and on the ground?
    jr c, .draw
    ldh a, [hObjOn]
    cp 1
    jr nz, .draw
    inc a
    ldh [hObjOn], a             ; only test once
    ldh a, [hAir]
    ld b, a
    ldh a, [hFadeStep]
    or b
    jr nz, .draw
    ldh a, [hX + 1]
    cp LANE_EDGE & $FF
    jr nc, .draw                ; -6..-1: too near the middle
    cp $80
    jr c, .draw                 ; 0..127: right of the lane
    ld hl, TunnelTrack
    ld a, 1
    call StartFade

.draw
    ; x of the lane centre on that line = 128 + lane offset - that line's SCX
    ld h, HIGH(LaneOffsets)
    ld l, c
    ld a, [hl]
    add 128
    ld b, a
    ldh a, [hBuiltScx]
    ld h, a
    ld a, c
    add HORIZON - 1
    ld l, a
    ld a, b
    sub [hl]
    ld b, a                     ; b = screen x of the centre
    ld a, c
    add HORIZON                 ; OAM y: a 16-high object whose bottom row is on that line
    ldh [hObjY], a

    ld hl, MouthSize0
    ld a, c
    cp MOUTH_D1
    jr c, .sized
    ld hl, MouthSize1
    cp MOUTH_D2
    jr c, .sized
    ld hl, MouthSize2
    cp MOUTH_D3
    jr c, .sized
    ld hl, MouthSize3
.sized
    ld a, [hl+]
    ld c, a                     ; sprites in this size
    ld de, wObjOam
.sprite
    ldh a, [hObjY]
    ld [de], a
    inc de
    ld a, [hl+]
    add b
    ld [de], a                  ; x
    inc de
    ld a, [hl+]
    ld [de], a                  ; tile
    inc de
    ld a, [hl+]
    ld [de], a                  ; flip
    inc de
    dec c
    jr nz, .sprite
    ret
.gone
    xor a
    ldh [hObjOn], a
    ret

; hl = track to continue on, a = 1 if that is the tunnel.  Takes effect half way through.
StartFade:
    ldh [hFadeTunnel], a
    ld a, l
    ldh [hFadeDest], a
    ld a, h
    ldh [hFadeDest + 1], a
    ld a, 1
    ldh [hFadeStep], a
    ret

; ---------------------------------------------------------------------------------------
; Speed, bend, distance and the direction the skyline faces.
Drive:
    ld hl, hFrame
    inc [hl]

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

    ; --- a fade in progress?  Half way through, in the dark, change track
    ldh a, [hFadeStep]
    or a
    jr z, .fadeDone
    inc a
    cp FADE_LENGTH
    jr c, .fadeStep
    xor a
.fadeStep
    ldh [hFadeStep], a
    cp FADE_LENGTH / 2
    jr nz, .fadeLevel
    ldh a, [hFadeDest]
    ldh [hTrack], a
    ldh a, [hFadeDest + 1]
    ldh [hTrack + 1], a
    ldh a, [hFadeTunnel]
    ldh [hTunnel], a
    ld a, 1
    ldh [hScriptTimer], a
    ld a, BEND_LEVELS           ; come out straight and centred
    ldh [hBend], a
    ldh [hTarget], a
    xor a
    ldh [hX], a
    ldh [hX + 1], a
    ldh [hVX], a
    ldh [hObjOn], a
.fadeLevel
    ld c, 0
    ldh a, [hFadeStep]
    or a
    jr z, .levelSet
    rra
    rra
    rra
    and 7
    ld e, a
    ld d, 0
    ld hl, FadeLevels
    add hl, de
    ld c, [hl]
.levelSet
    ld a, c
    ldh [hFadeLevel], a
    add a
    ld e, a
    ld d, 0
    ld hl, SpriteFade           ; the sprites darken with the background
    add hl, de
    ld a, [hl+]
    ldh [rOBP0], a
    ld a, [hl]
    ldh [rOBP1], a
.fadeDone

    ; --- the track: (frames, bend, command) entries; 0 frames = "continue at this address"
    ld hl, hScriptTimer
    dec [hl]
    jr nz, .haveTarget
    ldh a, [hTrack]
    ld l, a
    ldh a, [hTrack + 1]
    ld h, a
.nextEntry
    ld a, [hl+]
    or a
    jr nz, .entry
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    jr .nextEntry
.entry
    ldh [hScriptTimer], a
    ld a, [hl+]
    ldh [hTarget], a
    ld a, [hl+]
    ld c, a
    ld a, l
    ldh [hTrack], a
    ld a, h
    ldh [hTrack + 1], a
    ld a, c
    or a
    jr z, .haveTarget
    dec a
    jr nz, .leaveTunnel
    ldh a, [hPos + 1]           ; TRACK_MOUTH: a tunnel mouth appears up ahead
    add LOW(SPAWN_DIST)
    ldh [hObjZ], a
    ldh a, [hPos + 2]
    adc HIGH(SPAWN_DIST)
    ldh [hObjZ + 1], a
    ld a, 1
    ldh [hObjOn], a
    jr .haveTarget
.leaveTunnel                    ; TRACK_EXIT: back up to the surface
    ld hl, TrackRejoin
    xor a
    call StartFade
.haveTarget

    ; --- ease the bend toward it, one step a frame
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

    ; --- de = bend * speed: how hard this bend is turning us this frame
    ld hl, 0
    ldh a, [hSpeed + 1]
    or a
    jr z, .noTurn
    ld c, a
    ldh a, [hBend]
    sub BEND_LEVELS
    ld e, a
    add a                       ; sign extend into d
    sbc a
    ld d, a
.turnAdd
    add hl, de
    dec c
    jr nz, .turnAdd
.noTurn
    ld d, h
    ld e, l

    ; the skyline swings round by that much
    ldh a, [hSkyX]
    add e
    ldh [hSkyX], a
    ldh a, [hSkyX + 1]
    adc d
    ldh [hSkyX + 1], a

    sla e                       ; the push on the car is twice that: flat out, a full
    rl d                        ; bend outruns the steering and you have to slow down

    ; --- steering: ease sideways speed toward what the d-pad asks for
    ldh a, [hAir]
    or a
    jr z, .grounded
    ldh a, [hVX]                ; no grip in the air: keep drifting the way we were
    ld b, a
    jr .vxDone
.grounded
    ld c, 0
    bit 5, b                    ; PADF_LEFT
    jr z, .notLeft
    ld c, -STEER_MAX
.notLeft
    bit 4, b                    ; PADF_RIGHT
    jr z, .notRight
    ld c, STEER_MAX
.notRight
    ldh a, [hVX]
    ld b, a
    ld a, c
    sub b                       ; wanted - current
    jr z, .vxDone
    bit 7, a
    jr z, .vxUp
    dec b
    dec b
    dec b
    dec b
.vxUp
    inc b
    inc b
    ld a, b
    ldh [hVX], a
.vxDone

    ; --- X += sideways speed, and the bend throws the car toward the outside
    ld a, b
    ld l, a
    add a
    sbc a
    ld h, a
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                  ; 1/16 px -> 8.8
    ldh a, [hX]
    add l
    ld l, a
    ldh a, [hX + 1]
    adc h
    ld h, a
    ld a, l
    sub e
    ld l, a
    ld a, h
    sbc d
    ld h, a
    ld a, h                     ; keep it on the road
    add X_LIMIT
    cp X_LIMIT * 2
    jr c, .xOk
    bit 7, h
    ld hl, X_LIMIT << 8
    jr z, .xStop
    ld hl, -(X_LIMIT << 8)
.xStop
    ldh a, [hSpeed + 1]         ; scraping the rail costs speed, down to cruising pace
    cp 3
    jr c, .noScrub
    ldh a, [hSpeed]
    sub RAIL_SCRUB
    ldh [hSpeed], a
    jr nc, .noScrub
    ldh a, [hSpeed + 1]
    dec a
    ldh [hSpeed + 1], a
.noScrub
    xor a
    ldh [hVX], a
    ld b, a
.xOk
    ld a, l
    ldh [hX], a
    ld a, h
    ldh [hX + 1], a

    ; --- the camera follows half way; the car shows the rest
    sra a
    ld c, a                     ; X / 2
    add CAR_X + 8
    ldh [hCarX], a
    ld a, h
    sub c
    add SHEAR_MAX
    ldh [hShear], a

    ; --- lean into the turn
    ld c, CAR_TILE
    ld a, b
    add BANK_AT - 1
    cp BANK_AT * 2 - 1
    jr c, .leanDone             ; |speed| < BANK_AT
    ld c, CAR_TILE + 4          ; left
    bit 7, b
    jr nz, .leanDone
    ld c, CAR_TILE + 8          ; right
.leanDone
    ld a, c
    ldh [hCarTile], a

    ; --- jumping: A launches the car; the shadow stays on the road
    ldh a, [hAir]
    or a
    jr nz, .inAir
    ldh a, [hNewKeys]
    and PADF_A
    jr z, .onGround
    ld a, 1
    ldh [hAir], a
    ld a, LOW(JUMP_SPEED)
    ldh [hVZ], a
    ld a, HIGH(JUMP_SPEED)
    ldh [hVZ + 1], a
.inAir
    ldh a, [hVZ]
    sub GRAVITY
    ld e, a
    ldh [hVZ], a
    ldh a, [hVZ + 1]
    sbc 0
    ld d, a
    ldh [hVZ + 1], a
    ldh a, [hZ]
    ld l, a
    ldh a, [hZ + 1]
    ld h, a
    add hl, de
    bit 7, h
    jr z, .stillUp
    xor a                       ; touched down
    ldh [hAir], a
    ld h, a
    ld l, a
.stillUp
    ld a, l
    ldh [hZ], a
    ld a, h
    ldh [hZ + 1], a
    ld a, CAR_Y + 16
    sub h
    ldh [hCarY], a
    ld a, h
    cp 12                       ; high up: the shadow shrinks
    ld a, SHADOW_TILE
    jr c, .shadowSet
    ld a, SHADOW_TILE + 2
.shadowSet
    ldh [hShadowTile], a
    ret

.onGround                       ; hover bob
    ldh a, [hFrame]
    and %00010000
    swap a
    add CAR_Y + 16
    ldh [hCarY], a
    ret

; Track entries: frames to hold, bend (0..64, 32 is straight), command.
DEF TRACK_MOUTH EQU 1           ; a tunnel mouth appears ahead in the left lane
DEF TRACK_EXIT  EQU 2           ; (in the tunnel) fade back to the surface at TrackRejoin
MACRO TRACK_GOTO
    db 0
    dw \1
ENDM

Track:
    db 120, 32, 0
    db 140, 44, 0               ; easy right
    db 90, 32, TRACK_MOUTH      ; fork: the tunnel on the left cuts out the hairpins
    db 250, 32, 0
    db 170, 0, 0                ; hairpin left
    db 60, 32, 0
    db 150, 64, 0               ; hairpin right
    db 70, 18, 0                ; chicane
    db 70, 46, 0
TrackRejoin:
    db 120, 6, 0
    db 100, 32, 0
    TRACK_GOTO Track

TunnelTrack:
    db 150, 32, 0
    db 120, 40, 0
    db 100, 26, 0
    db 60, 32, TRACK_EXIT
    db 255, 32, 0
    TRACK_GOTO TunnelTrack

FadeLevels:                     ; darkness for each eighth of a fade
    db 1, 2, 3, 3, 3, 3, 2, 1

SpriteFade:                     ; OBP0, OBP1 at each darkness
    db %11100000, %10100000
    db %11110100, %11110000
    db %11111000, %11110000
    db %11111100, %11110000

; Sprites for each size of tunnel mouth: count, then (x offset from the centre, tile, flip).
MouthSize0:
    db 1
    db 4, MOUTH_TILE, 0
MouthSize1:
    db 2
    db 0, MOUTH_TILE + 2, 0
    db 8, MOUTH_TILE + 2, OAMF_XFLIP
MouthSize2:
    db 4
    db -8, MOUTH_TILE + 4, 0
    db 0, MOUTH_TILE + 6, 0
    db 8, MOUTH_TILE + 6, OAMF_XFLIP
    db 16, MOUTH_TILE + 4, OAMF_XFLIP
MouthSize3:
    db 5
    db -12, MOUTH_TILE + 8, 0
    db -4, MOUTH_TILE + 10, 0
    db 4, MOUTH_TILE + 12, 0
    db 12, MOUTH_TILE + 10, OAMF_XFLIP
    db 20, MOUTH_TILE + 8, OAMF_XFLIP

; ---------------------------------------------------------------------------------------
StartSong:
    call SongBank
    ld hl, race_song
    jp hUGE_init

SongBank:
    ld a, BANK(race_song)
    ld [rROMB0], a
    ret

InitialOam:
    db CAR_Y + 16, CAR_X + 8, CAR_TILE, 0
    db CAR_Y + 16, CAR_X + 16, CAR_TILE + 2, 0
    db CAR_Y + 30, CAR_X + 8, SHADOW_TILE, OAMF_PAL1
    db CAR_Y + 30, CAR_X + 16, SHADOW_TILE, OAMF_PAL1 | OAMF_XFLIP
.end

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

ShearPointers:
    FOR N, SHEAR_MAX * 2 + 1
        dw ShearTables + N * GROUND_LINES
    ENDR

BendTables:                     ; (BEND_LEVELS*2+1) x GROUND_LINES values of SCX
    INCBIN "build/bend.bin"

SkyBgp:
    INCBIN "build/skybgp.bin"

; ---------------------------------------------------------------------------------------
; Page-aligned lookups: the low byte of the address is the index.
SECTION "row phase", ROM0, ALIGN[8]
RowPhase:                       ; indexed by screen line
    INCBIN "build/rowphase.bin"

SECTION "dist to line", ROM0, ALIGN[8]
DistToLine:                     ; distance ahead / 8 -> ground line
    INCBIN "build/dist.bin"

SECTION "lane offsets", ROM0, ALIGN[8]
LaneOffsets:                    ; ground line -> pixels from road centre to the left lane
    INCBIN "build/lane.bin"

SECTION "fade tables", ROM0, ALIGN[8]
FadeTables:                     ; BGP -> BGP one, two, three shades darker
    INCBIN "build/fade.bin"

MACRO PAL_TABLE
SECTION "pal \1", ROM0, ALIGN[8]
Pal\1:
    INCBIN "build/pal_\2.bin"
ENDM
    PAL_TABLE Near0, near0
    PAL_TABLE Near1, near1
    PAL_TABLE Near2, near2
    PAL_TABLE Near3, near3
    PAL_TABLE Far0, far0
    PAL_TABLE Far1, far1
    PAL_TABLE Far2, far2
    PAL_TABLE TNear0, tnear0
    PAL_TABLE TNear1, tnear1
    PAL_TABLE TNear2, tnear2
    PAL_TABLE TNear3, tnear3
    PAL_TABLE TFar, tfar

SECTION "fzero gfx", ROMX, BANK[GFX_BANK]
Tiles8000:
    INCBIN "build/tiles8000.bin"
.end
Tiles8800:
    INCBIN "build/tiles8800.bin"
.end
Tiles9000:
    INCBIN "build/tiles9000.bin"
.end
CarTiles:
    INCBIN "build/car.bin"
.end
Tilemap:
    INCBIN "build/map.bin"
.end
ShearTables:                    ; (SHEAR_MAX*2+1) x GROUND_LINES amounts to add to SCX
    INCBIN "build/shear.bin"

; ---------------------------------------------------------------------------------------
; Two sets of per-line values; one is on screen while the other is being filled.
; Each is a BGP page followed by an SCX page, indexed by screen line.
SECTION "line buffers", WRAM0[$C100]
wLinesA: ds 512
wLinesB: ds 512

SECTION "object oam", WRAM0
wObjOam: ds OBJ_SPRITES * 4     ; staged here, copied to OAM in VBlank

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
hX:           dw    ; car's place across the road, 8.8 pixels, 0 = centre line
hVX:          db    ; sideways speed, signed, 1/16 pixel per frame
hShear:       db    ; camera's place across the road, 0..SHEAR_MAX*2
hCarX:        db
hCarTile:     db
hShadowTile:  db
hAir:         db    ; nonzero while jumping
hZ:           dw    ; height above the road, 8.8 pixels
hVZ:          dw    ; upward speed, signed 8.8
hTrack:       dw    ; next track entry
hTunnel:      db    ; nonzero while underground
hObjOn:       db    ; road object: 0 none, 1 approaching, 2 lane already tested
hObjZ:        dw    ; its place along the track, same units as hPos + 1
hObjY:        db
hBuiltScx:    db    ; high byte of the SCX buffer BuildLines just filled
hFadeStep:    db    ; 0 = not fading, else 1..FADE_LENGTH-1
hFadeLevel:   db    ; current darkness, 0..3
hFadeDest:    dw    ; track to switch to half way through the fade
hFadeTunnel:  db    ; and whether that track is the tunnel
hScriptTimer: db
hCarY:        db
hCurKeys:     db
hNewKeys:     db
hLoad:        db
