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
; Rivals: every car uses the same tiles.  A livery is a sprite palette, and OBP1 is one more
; register rewritten per scanline, so each rival gets its own paint on the lines it occupies.
;
; The race: one lap is 64 chunks of 256 units.  The course shape, the rivals' pace and the
; places things happen (finish line, recharge strip, tunnel) are all tables indexed by chunk.
;
; Driving feel: the throttle pulls hard at low speed and tails off toward the top; bends
; throw the car outward, less if you lift off; braking while steering is a skid turn (much
; more steering, at a cost in speed); the rail bounces you back and hurts; boosts (one per
; lap, or free from a dash plate) break the speed limit for a moment.
;
; Hazards: dirt strips (dark bands that drag the car down unless you jump them) and barriers
; (blocks in one lane that hurt, slow and toss the car unless you steer round or jump).
;
; Controls: Left/Right steer, A accelerate, Down brake, B jump, Up boost.
;           Select turns the engine note on and off (it borrows the music's second channel).
;           Start after a race: go again.  Select+Start together steps through the modes:
;           race, practice (Select and Start bend the road by hand), two-player link.
;
; Two players: both pick link mode, one presses Start.  Each console runs its own car and
; two rivals and tells the other where they are; the other shows them a few frames late.
; The serial port is polled (LinkPump), never interrupt driven, so it cannot delay HBlank.
;
; Music is music/race.uge (edit it in hUGETracker), played by hUGEDriver.

INCLUDE "include/hardware.inc"
INCLUDE "build/consts.inc"

DEF GFX_BANK    EQU 2           ; per-line bend and shear tables, read every frame
DEF TILE_BANK   EQU 4           ; tiles and tilemap, copied to VRAM once
DEF PAL_BANK    EQU 5           ; palette tables, each with two darker copies for fades
DEF LCDC_UPPER  EQU LCDCF_ON | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ16 | LCDCF_BG8000 | LCDCF_BG9800
DEF LCDC_LOWER  EQU LCDCF_ON | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ16 | LCDCF_BG8800 | LCDCF_BG9800
DEF SPEED_MAX   EQU $08
DEF STAR_LINES  EQU 16          ; top lines scroll at half the skyline's rate
DEF CAR_X       EQU 72          ; screen position when centred
DEF CAR_Y       EQU 118
DEF SHADOW_TILE EQU CAR_TILE + 2
DEF MOUTH_TILE  EQU CAR_TILE + 6
DEF CAR12_TILE  EQU CAR_TILE + 18  ; the car at 12, 8 and 4 pixels, for rivals up the road
DEF CAR8_TILE   EQU CAR_TILE + 20
DEF CAR4_TILE   EQU CAR_TILE + 22
DEF NUM_RIVALS  EQU 7
DEF PLAYER_Z    EQU 175         ; how far ahead of the camera the player's car is
DEF RIVAL_OAM   EQU 9 * 4       ; rivals own four OAM entries each from here on
DEF PLAYER_D    EQU 95          ; ground line the player's car sits on
DEF BOOST_MAX   EQU $0B         ; top speed while boosting
DEF BOOST_TIME  EQU 80          ; frames a boost lasts
DEF DASH_TIME   EQU 45          ; frames of boost from a dash plate
DEF BOOSTS_MAX  EQU 3
DEF COUNTDOWN   EQU 180         ; frames on the grid before the start
DEF STEER_SKID  EQU 40          ; sideways speed in a skid turn
DEF SKID_COST   EQU $000C       ; extra speed a skid turn scrubs off per frame
DEF RAIL_BOUNCE EQU 20          ; sideways speed coming back off the rail
DEF RAIL_COST   EQU 4           ; health lost hitting it
DEF JUMP_PLATE  EQU $0400       ; take-off speed from a jump plate
DEF DIRT_DRAG   EQU $0030       ; speed lost per frame on dirt, down to DIRT_SPEED
DEF DIRT_SPEED  EQU 3
DEF BARRIER_COST EQU 8          ; health lost hitting a barrier
DEF BARRIER_HOP EQU $0200       ; and how hard it throws the car up
DEF ENGINE_BASE EQU $02C0       ; engine note at rest (a frequency register value, ~97 Hz)
DEF FRICTION    EQU $0004       ; lost per frame off it
DEF BRAKE       EQU $0020
DEF HEALTH_MAX  EQU 64
DEF KNOCK_COST  EQU 3           ; health lost bumping a rival
DEF STUN_TIME   EQU 45          ; frames a knocked rival runs at half pace
DEF CHUNK_MASK  EQU 63          ; 64 chunks to a lap
DEF TUNNEL_SKIP EQU 8           ; chunks the tunnel cuts off the lap
DEF EXIT_CHUNK  EQU 30          ; where the tunnel comes back up
DEF PIT_START   EQU 256         ; recharge strip, in units from the finish line
DEF PIT_END     EQU 768
DEF LINE_END    EQU 20          ; depth of the painted finish line
DEF MODE_RACE     EQU 0
DEF MODE_PRACTICE EQU 1
DEF MODE_LINK     EQU 2
DEF LINK_MASTER   EQU 1         ; hLinked: this console clocks the cable
DEF LINK_SLAVE    EQU 2
DEF LINK_CALL     EQU $AA       ; "anyone there?" from whoever pressed Start
DEF LINK_ANSWER   EQU $55       ; what a waiting console has loaded
DEF LINK_N        EQU 9         ; bytes in a packet: sync, 4 player, 3 rival, checksum
DEF LINK_TIMA     EQU 256 - 8   ; the master leaves 8 timer ticks (2 ms) between bytes, so
                                ; the other side has time to notice one and load the next
DEF LINK_TIMEOUT  EQU 180       ; frames without a good packet before giving up
DEF REMOTE        EQU %10000000 ; lane byte: placed by the other console, not moved here
DEF FREE_X        EQU %01000000 ; lane byte: not in a lane; x is in the skill byte
DEF HIDDEN        EQU -30000    ; a distance no car is ever seen at
DEF OBJ_SPRITES EQU 5           ; OAM entries kept for the road object
DEF LANE_EDGE   EQU -6          ; left of this, the car is in the tunnel's lane
DEF SCX_STAMP   EQU 200         ; offset in an SCX page of its (bend, shear) note
DEF FADE_LENGTH EQU 64          ; frames; the switch happens half way, in the dark
DEF X_LIMIT     EQU ROAD_HALF - 12  ; how far from the centre line the car may go
DEF STEER_MAX   EQU 24          ; sideways speed, 1/16 pixel per frame
DEF BANK_AT     EQU 10          ; sideways speed at which the car visibly leans
DEF JUMP_SPEED  EQU $0300       ; upward speed at take-off, 8.8 pixels per frame
DEF GRAVITY     EQU $28
DEF RAIL_SCRUB  EQU $0100       ; speed lost hitting the rail

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
    inc h
    ld a, [hl]
    ldh [rOBP1], a
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
    ldh a, [hReady]             ; a finished frame waiting?  make it the live one
    or a
    jr z, .keep
    ldh [hFront], a
    xor a
    ldh [hReady], a
    call hDma                   ; and its sprites with it
    ldh a, [hHudDirty]
    or a
    jr z, .keep
    xor a
    ldh [hHudDirty], a
    push bc
    push de
    ld hl, wHud                 ; and the status bar, if it changed
    ld de, _SCRN0
    ld b, 20
.hud
    ld a, [hl+]
    ld [de], a
    inc e
    dec b
    jr nz, .hud
    pop de
    pop bc
.keep
    ldh a, [hFront]
    ld h, a
    ld l, 0
    ld a, [hl]                  ; line 0 has no HBlank before it
    ldh [rBGP], a
    inc h
    ld a, [hl]
    ldh [rSCX], a
    inc h
    ld a, [hl]
    ldh [rOBP1], a
    ld a, LCDC_UPPER
    ldh [rLCDC], a
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

    ld a, TILE_BANK
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

    ; sprites are staged in wOam and sent to the screen by DMA in VBlank
    ld hl, _OAMRAM
    ld b, 160
    xor a
.clearOam
    ld [hl+], a
    dec b
    jr nz, .clearOam
    ld hl, wOam
    ld b, 160
.clearStage
    ld [hl+], a
    dec b
    jr nz, .clearStage
    ld de, DmaCode
    ld hl, hDma
    ld bc, DmaCode.end - DmaCode
    call Copy
    ld a, %11100000             ; player: 1 white, 2 dark grey, 3 black
    ldh [rOBP0], a

    ; both line buffers: sky palette for the top, something sane for the rest
    ld hl, wLinesA
    call InitLines
    ld hl, wLinesB
    call InitLines

    xor a
    ldh [hReady], a
    ldh [hVBlank], a
    ldh [hFrame], a
    ldh [hCurKeys], a
    ldh [hNewKeys], a
    ldh [hMode], a
    ldh [hEngine], a
    ldh [hPractice], a
    ldh [hLinked], a
    ldh [hLinkTry], a
    ldh [hGen], a
    ldh [hLevel], a
    ldh [hSkyX], a
    ldh [hSkyX + 1], a
    ld a, HIGH(wLinesA)
    ldh [hFront], a
    call InitRace

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
    halt                        ; (wakes every scanline for the HBlank interrupt)
    ldh a, [hVBlank]
    or a
    jr nz, .frame
    call LinkPump
    jr .wait
.frame
    call UpdateKeys
    call LinkIdle
    call Drive
    call LinkPump
    call LinkApply
    call BuildLines
    call LinkPump
    call UpdateObject
    call UpdateRivals
    call PlayerSprites
    call UpdateHud
    call LinkPump
    ldh a, [hBuiltScx]          ; everything for this frame is staged: let VBlank show it
    dec a
    ldh [hReady], a
    call SongBank
    call hUGE_dosound
    call LinkPump
    ldh a, [rLY]                ; load meter: the line on which this frame's work ended
    ldh [hLoad], a              ; (144 = started, wraps through 153 to 0; must stay < 144)
    jr MainLoop

; ---------------------------------------------------------------------------------------
; Filling the BGP buffer.  FILL_BAND picks a distance band's palette table and how far we
; have driven in that table's units; FILL_LINE then does one line, whose depth is a constant
; in the code (tools/gen_gfx.py writes the list).  de = where the line's BGP goes.
MACRO LINK_PUMP                 ; a safe place to look at the cable: a and flags are free
    ldh a, [hLinked]
    or a
    call nz, LinkPump
ENDM
MACRO FILL_BAND
    IF \2
        ldh a, [hPosCoarse]
    ELSE
        ldh a, [hPos + 1]
    ENDC
    ld c, a
    ldh a, [hFadeLevel]         ; the darker copies of a table follow it
    add HIGH(\1)
    ld h, a
ENDM
MACRO FILL_LINE
    ld a, c                     ; distance driven
    add \1                      ; plus this line's depth
    ld l, a
    ld a, [hl]                  ; -> what the city looks like there
    ld [de], a
    inc e
ENDM

BuildLines:
    ldh a, [hFront]
    xor HIGH(wLinesA) ^ HIGH(wLinesB)
    ld b, a                     ; b = the buffer not on screen
    ld a, PAL_BANK
    ld [rROMB0], a

    ldh a, [hFadeLevel]
    or a
    jr z, .lit
    ld a, 3
    ldh [hSkyStale], a          ; the sky lines change with the fade: redo them until it is over
    ldh a, [hFadeLevel]
    cp 3
    jr nz, .lit
    ld h, b                     ; fully dark: nothing to work out
    ld l, 0
    ld a, $FF
.black
    ld [hl+], a
    ld a, l
    cp 144
    ld a, $FF
    jr nz, .black
    jp .bgpReady
.lit
    ld d, b
    ld e, HORIZON
    ldh a, [hTunnel]
    or a
    jp nz, .tunnel
    FILL_ALL_BANDS
    ldh a, [hSkyStale]
    or a
    jp z, .bgpDone
    dec a
    ldh [hSkyStale], a
    ld de, SkyBgp               ; sky fades toward the horizon glow
    ldh a, [hFadeLevel]         ; (its darker copies follow it too)
    or a
    jr z, .skyTable
    ld de, SkyBgp + HORIZON
    dec a
    jr z, .skyTable
    ld de, SkyBgp + HORIZON * 2
.skyTable
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
    ld h, b                     ; no sky down here: black above the road, below the status bar
    ld l, 8
    ld a, $FF
.roof
    ld [hl+], a
    ld a, l
    cp HORIZON
    ld a, $FF
    jr nz, .roof
.bgpDone
    call RoadFeatures           ; finish line, recharge strip, dash and jump plates

.bgpReady

    ; SCX: stars, skyline, then the bend table for the ground
    inc b
    ld h, b
    ld l, 0
    ldh a, [hSkyX + 1]
    ld c, a
    xor a
.hudLines                       ; the status bar does not scroll
    ld [hl+], a
    bit 3, l
    jr z, .hudLines
    ld a, c
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

    ; ground: bend (how the road curves) + shear (where the camera is across it).
    ; Each buffer notes the bend and shear it was filled for (in two spare bytes of its SCX
    ; page): on a straight with the wheel still, that is unchanged and the fill is skipped.
    ld d, b
    ld a, GFX_BANK
    ld [rROMB0], a
    ld h, b
    ld l, SCX_STAMP
    ldh a, [hBend]
    cp [hl]
    jr nz, .refill
    inc l
    ldh a, [hShear]
    cp [hl]
    jr z, .scxDone
    dec l
.refill
    ldh a, [hBend]
    ld [hl+], a
    ldh a, [hShear]
    ld [hl], a
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
    REPT 8
        ld a, [bc]
        add [hl]
        inc bc
        inc hl
        ld [de], a
        inc e
    ENDR
    LINK_PUMP
    ld a, e
    cp 144
    jr nz, .ground
.scxDone
    ld a, d
    ldh [hBuiltScx], a          ; sprites look up where the road is on each line
    ret

; ---------------------------------------------------------------------------------------
; The player's car and shadow.  Leaning is free: the two halves sit a pixel apart.
PlayerSprites:
    ld hl, wOam
    ldh a, [hLean]
    ld c, a
    ldh a, [hCarY]
    ld b, a
    ldh a, [hState]
    cp STATE_DEAD               ; destroyed: flicker out
    jr nz, .alive
    ldh a, [hFrame]
    and 2
    jr z, .alive
    ld b, 0
.alive
    ld a, b
    bit 0, c                    ; leaning left: left half lower
    jr z, .leftY
    inc a
.leftY
    ld [hl+], a
    ldh a, [hCarX]
    ld e, a
    ld [hl+], a
    ld a, CAR_TILE
    ld [hl+], a
    xor a
    ld [hl+], a
    ld a, b
    bit 1, c                    ; leaning right: right half lower
    jr z, .rightY
    inc a
.rightY
    ld [hl+], a
    ld a, e
    add 8
    ld d, a
    ld [hl+], a
    ld a, CAR_TILE
    ld [hl+], a
    ld a, OAMF_XFLIP
    ld [hl+], a
    ldh a, [hShadowTile]
    ld c, a
    ld a, CAR_Y + 30
    ld [hl+], a
    ld a, e
    ld [hl+], a
    ld a, c
    ld [hl+], a
    xor a
    ld [hl+], a
    ld a, CAR_Y + 30
    ld [hl+], a
    ld a, d
    ld [hl+], a
    ld a, c
    ld [hl+], a
    ld [hl], OAMF_XFLIP
    ret

; ---------------------------------------------------------------------------------------
; Rivals.  Each keeps a distance ahead of the camera; from that comes the line it is on, its
; size, and (with that line's SCX) where the road is under it.
;
; To fit the frame, each rival is only moved and redrawn every other frame (half of them on
; even frames, half on odd), covering two frames of travel at a time.  Each owns four OAM
; entries, which simply keep their last position in between.  Its paint has to go into
; every frame's OBP1 lines though, so that is redone from a remembered line.  They are
; visited far to near so that where two share scanlines the nearer one's paint wins.
UpdateRivals:
    ; one pass of a bubble sort a frame keeps wOrder far-to-near: the order changes slowly
    ld hl, wOrder
    ld b, NUM_RIVALS - 1
.pair
    push hl
    ld a, [hl+]
    ld e, [hl]
    add a
    add a
    add a
    inc a
    ld c, a
    ld a, e
    add a
    add a
    add a
    inc a
    ld e, a
    ld d, HIGH(wRivals)
    ld h, d
    ld l, c
    ld a, [de]
    ld c, a
    ld a, [hl+]
    sub c
    inc e
    ld a, [de]
    ld c, a
    ld a, [hl]
    sbc c                       ; first - second, negative if the first is nearer
    pop hl
    bit 7, a
    jr z, .sorted
    ld a, [hl+]
    ld c, [hl]
    ld [hl-], a
    ld [hl], c
.sorted
    inc hl
    dec b
    jr nz, .pair

    xor a
    ldh [hRankCount], a
.each
    ldh [hRivalIdx], a
    ld e, a
    ld d, 0
    ld hl, wOrder
    add hl, de
    ld a, [hl]
    ld c, a                     ; which rival
    add a
    add a
    add a
    ld l, a
    ld h, HIGH(wRivals)
    ldh [hRivalRec], a
    ldh a, [hFrame]
    xor c
    rra
    jr c, .resting
    call .move
    jr .next
.resting                        ; not its frame: count it, and repaint where it was
    inc l
    ld a, [hl+]
    ld c, a
    ld b, [hl]
    call .aheadOfUs
    ld a, l
    add 4
    ld l, a
    ld a, [hl+]                 ; paint
    ld l, [hl]                  ; the line its sprite sits on, 0 if out of sight
    inc l
    dec l
    call nz, .paint
.next
    LINK_PUMP
    ldh a, [hRivalIdx]
    inc a
    cp NUM_RIVALS
    jp nz, .each
    ldh a, [hState]             ; our place: one more than the cars ahead (frozen at the flag)
    cp STATE_FINISHED
    ret z
    ldh a, [hRankCount]
    inc a
    ldh [hRank], a
    ret

; bc = a rival's distance ahead of the camera: count it if that puts it ahead of us
.aheadOfUs
    bit 7, b
    ret nz
    ld a, b
    or a
    jr nz, .isAhead
    ld a, c
    cp PLAYER_Z
    ret c
.isAhead
    ldh a, [hRankCount]
    inc a
    ldh [hRankCount], a
    ret

; a = paint, l = bottom line of the car: give its lines that OBP1
.paint
    ld d, a
    ldh a, [hFadeLevel]         ; (not while fading: see below)
    or a
    ret nz
    ldh a, [hBuiltScx]
    inc a
    ld h, a
    ld a, d
    REPT 18
        ld [hl], a
        dec l
    ENDR
    ret

; e = this rival's x across the road, in road units
.acrossRoad
    ldh a, [hRLane]
    bit 6, a
    jr nz, .freeX
    and 3
    ld e, a
    ld d, 0
    ld hl, RivalLaneU
    add hl, de
    ld e, [hl]
    ret
.freeX
    ld h, HIGH(wRivals)
    ldh a, [hRivalRec]
    add 3
    ld l, a
    ld e, [hl]
    ret

; out of sight: park its sprites and forget its line
.hide
    ld h, HIGH(wRivals)
    ldh a, [hRivalRec]
    ld c, a
    add 7
    ld l, a
    ld [hl], 0
    ld a, c                     ; record offset is rival * 8; its OAM is rival * 16 on
    add a
    add RIVAL_OAM
    ld l, a
    ld h, HIGH(wOam)
    xor a
    ld [hl], a
    ld a, l
    add 4
    ld l, a
    xor a
    ld [hl], a
    ld a, l
    add 4
    ld l, a
    xor a
    ld [hl], a
    ld a, l
    add 4
    ld l, a
    ld [hl], 0
    ret

; hl = this rival's record: move it two frames' worth and redraw it
.move
    ld a, l
    add 5
    ld l, a
    ld e, [hl]                  ; lane byte, with its REMOTE / FREE_X flags
    dec l
    bit 7, e
    jr z, .local
    ld a, [hl]                  ; a remote car: the other console says where it is.  The
    or a                        ; stun byte is just our own "bumped it a moment ago" timer
    jr z, .calm
    dec [hl]
.calm
    dec l
    dec l
    ld a, [hl-]
    ld b, a
    ld c, [hl]
    inc l                       ; hl -> high byte of the distance, as after a local move
    jr .moved
.local
    dec l
    dec l
    dec l
    dec l
    ; its pace: the profile for the chunk it is in, plus its skill, halved while stunned
    push hl
    inc l
    ld a, [hl+]
    ld c, a
    ld a, [hl+]
    ld b, a                     ; bc = distance ahead; hl -> skill
    ldh a, [hPos + 1]
    add c
    ldh a, [hPos + 2]
    adc b
    and CHUNK_MASK
    ld e, a
    ld a, [hl+]
    ld c, a                     ; skill
    ld a, [hl]                  ; stun timer
    ld b, a
    or a
    jr z, .awake
    dec [hl]
.awake
    ld d, 0
    ld hl, SpeedProfile
    add hl, de
    ldh a, [hPace]
    add c
    add [hl]
    inc b
    dec b
    jr z, .fullPace
    srl a
.fullPace
    ld c, a
    ldh a, [hCount]             ; nobody moves until the start
    or a
    ld a, c
    jr z, .racing
    xor a
.racing
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl                  ; 8.8 units per frame
    ldh a, [hSpeed]
    ld c, a
    ldh a, [hSpeed + 1]
    ld b, a
    ld a, l
    sub c
    ld e, a
    ld a, h
    sbc b
    ld d, a                     ; de = its speed - ours
    sla e
    rl d                        ; two frames of it
    add a
    sbc a
    ld b, a                     ; sign, for the top byte
    pop hl
    ld a, [hl]
    add e
    ld [hl+], a
    ld a, [hl]
    adc d
    ld [hl+], a
    ld c, a
    ld a, [hl]
    adc b
    ld [hl], a
    ld b, a                     ; bc = whole units ahead of the camera
.moved
    call .aheadOfUs
    ld a, b
    cp 8
    jp nc, .hide                ; behind the camera, or beyond the horizon
    inc l
    inc l
    inc l
    ld a, [hl+]
    ldh [hRLane], a
    ld a, [hl]
    ldh [hRPaint], a
    srl b
    rr c
    srl b
    rr c
    srl b
    rr c
    ld l, c
    ld h, HIGH(DistToLine)
    ld a, [hl]                  ; ground line d
    cp GROUND_LINES + 1
    jp nc, .hide
    cp RIVAL_D4
    jp c, .hide
    ld c, a

    ; --- touching the player?  same depth, overlapping across the road, both on the ground
    sub PLAYER_D - 7
    cp 15
    jr nc, .noHit
    ldh a, [hAir]
    or a
    jr nz, .noHit
    call .acrossRoad            ; e = its x across the road
    ldh a, [hX + 1]
    sub e                       ; our x - its x
    ld d, a
    add 13
    cp 27
    jr nc, .noHit
    ld a, STEER_MAX             ; we bounce off...
    bit 7, d
    jr z, .shove
    ld a, -STEER_MAX
.shove
    ldh [hVX], a
    ld h, HIGH(wRivals)         ; ...and it is knocked a lane away and stunned
    ldh a, [hRivalRec]
    add 4
    ld l, a
    ld a, [hl]
    or a
    jr nz, .noHit               ; already reeling from the last knock
    ld [hl], STUN_TIME
    inc l
    ld a, [hl]
    bit 7, a                    ; a remote car only moves when its own console says so
    jr nz, .knocked
    bit 7, d
    jr z, .knockLeft
    cp 3                        ; we are on its left: it goes right
    jr z, .knocked
    inc [hl]
    jr .knocked
.knockLeft
    or a
    jr z, .knocked
    dec [hl]
.knocked
    ld a, KNOCK_COST
    call Damage
.noHit

    ; --- where is it across the road on that line?
    ldh a, [hRLane]
    bit 6, a
    jr z, .inLane
    call .acrossRoad            ; not in a lane (the other player): scale its x by the
    ld a, e                     ; line's depth, using the camera shear tables: x/2 picks
    sra a                       ; a table, the answer is doubled
    add SHEAR_MAX
    add a
    ld e, a
    ld d, 0
    ld hl, ShearPointers
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ld e, c
    dec e
    add hl, de
    ld a, [hl]
    add a
    jr .haveOffset
.inLane
    and 3
    ld l, c
    srl a
    jr nc, .evenLane
    set 7, l
.evenLane
    add HIGH(RivalLanes)
    ld h, a
    ld a, [hl]
.haveOffset
    add 128
    ld b, a
    ldh a, [hBuiltScx]
    ld h, a
    ld a, c
    add HORIZON - 1
    ld l, a
    ld a, b
    sub [hl]
    ld b, a                     ; b = screen x of its centre

    ; --- its paint on the lines it covers; remember the line for its resting frames.
    ; During a fade it borrows the player's palette, which is being darkened anyway.
    ld e, l
    ld h, HIGH(wRivals)
    ldh a, [hRivalRec]
    add 7
    ld l, a
    ld [hl], e
    ld a, $FF
    ldh [hAttrMask], a
    ldh a, [hFadeLevel]
    or a
    jr z, .paintIt
    ld a, ~OAMF_PAL1
    ldh [hAttrMask], a
.paintIt
    ld l, e
    ldh a, [hRPaint]
    call .paint

    ld a, c
    add HORIZON
    ldh [hObjY], a
    ld hl, RivalSize16
    ld a, c
    cp RIVAL_D16
    jr nc, .sized
    ld hl, RivalSize12
    cp RIVAL_D12
    jr nc, .sized
    ld hl, RivalSize8
    cp RIVAL_D8
    jr nc, .sized
    ld hl, RivalSize4
.sized
    ldh a, [hRivalRec]
    add a
    add RIVAL_OAM
    ld e, a
    ld d, HIGH(wOam)
    ld a, [hl+]
    ld c, a                     ; sprites in this size
    cpl
    add 5                       ; 4 - that many entries left over
    ldh [hRivalIdx + 1], a
.sprite
    ldh a, [hObjY]
    add [hl]
    inc hl
    ld [de], a
    inc e
    ld a, [hl+]
    add b
    ld [de], a
    inc e
    ld a, [hl+]
    ld [de], a
    inc e
    ldh a, [hAttrMask]
    and [hl]
    inc hl
    ld [de], a
    inc e
    dec c
    jr nz, .sprite
    ldh a, [hRivalIdx + 1]
    or a
    ret z
    ld c, a
.spare
    xor a
    ld [de], a
    ld a, e
    add 4
    ld e, a
    dec c
    jr nz, .spare
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
    jp nc, .gone
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
    ldh a, [hObjKind]
    or a
    jr z, .mouth
    dec a                       ; a barrier: are we in its lane?
    ld e, a
    ld d, 0
    ld hl, RivalLaneU
    add hl, de
    ldh a, [hX + 1]
    sub [hl]
    add 13
    cp 27
    jr nc, .draw
    ld a, BARRIER_COST          ; yes: it hurts, it slows and it throws the car
    call Damage
    ld a, SFX_HIT
    call Sfx
    ldh a, [hSpeed + 1]
    srl a
    ldh [hSpeed + 1], a
    ld a, 1
    ldh [hAir], a
    ld a, LOW(BARRIER_HOP)
    ldh [hVZ], a
    ld a, HIGH(BARRIER_HOP)
    ldh [hVZ + 1], a
    jr .draw
.mouth
    ldh a, [hX + 1]
    cp LANE_EDGE & $FF
    jr nc, .draw                ; -6..-1: too near the middle
    cp $80
    jr c, .draw                 ; 0..127: right of the lane
    ld a, 1
    call StartFade

.draw
    ; x of the lane centre on that line = 128 + lane offset - that line's SCX
    ld h, HIGH(LaneOffsets)
    ld l, c
    ldh a, [hObjKind]
    or a
    jr z, .laneFound
    dec a                       ; barriers sit in the rivals' lanes
    srl a
    jr nc, .evenLane
    set 7, l
.evenLane
    add HIGH(RivalLanes)
    ld h, a
.laneFound
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

    ldh a, [hObjKind]
    or a
    jr z, .mouthSizes
    ld hl, BarrierFar           ; a barrier: a dot far off, then a block
    ld a, c
    cp MOUTH_D2
    jr c, .sized
    ld hl, MouthSize1
    jr .sized
.mouthSizes
    ld hl, MouthSize1
    ld a, c
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

; a = 1 to go down into the tunnel, 0 to come back up.  Takes effect half way through.
StartFade:
    ldh [hFadeTunnel], a
    ld a, 1
    ldh [hFadeStep], a
    ret

; a = health to take off.  Running out destroys the car.  No damage in practice or after the race.
Damage:
    push bc
    ld b, a
    ldh a, [hPractice]
    ld c, a
    ldh a, [hState]
    or c
    jr nz, .done
    ldh a, [hHealth]
    sub b
    jr z, .dead
    jr nc, .alive
.dead
    ld a, STATE_DEAD
    ldh [hState], a
    xor a
.alive
    ldh [hHealth], a
.done
    pop bc
    ret

; Things painted across the road: finish line, recharge strip, dash plates, jump plates.
; Each is drawn if it is in view and acted on if the car is on it.  b = BGP page being built.
RoadFeatures:
    ld hl, Features
.next
    ld a, [hl+]                 ; first chunk it can be seen from; $FF ends the list
    cp $FF
    ret z
    ld c, a
    ldh a, [hChunk]
    sub c
    and CHUNK_MASK
    cp [hl]                     ; how many chunks it stays relevant for
    inc hl
    jr c, .near
    inc hl
    inc hl
    inc hl
    inc hl
    inc hl
    jr .next
.near
    ld a, [hl+]
    ld e, a
    ld a, [hl+]
    ld d, a                     ; de = where it starts
    ld a, [hl+]
    ldh [hBandEnd], a
    ld a, [hl+]
    ldh [hBandEnd + 1], a
    ld a, [hl+]
    push hl
    ld c, a                     ; what it is
    ; --- is the car on it?  (lap position - start) < length
    ldh a, [hPos + 1]
    sub e
    ld l, a
    ldh a, [hPos + 2]
    and CHUNK_MASK
    sbc d
    and CHUNK_MASK
    ld h, a                     ; hl = how far past its start we are
    ldh a, [hBandEnd]
    sub e
    push de
    ld e, a
    ldh a, [hBandEnd + 1]
    sbc d
    ld d, a                     ; de = its length
    ld a, l
    sub e
    ld a, h
    sbc d
    pop de
    jr nc, .notOn
    ldh a, [hAir]
    ld l, a
    ldh a, [hState]
    or l
    jr nz, .notOn
    ld a, c
    cp FEATURE_DASH
    jr nz, .notDash
    ldh a, [hBoost]             ; dash plate: a free burst
    or a
    jr nz, .notOn
    ld a, DASH_TIME
    ldh [hBoost], a
    ld a, SFX_BOOST
    call Sfx
    jr .notOn
.notDash
    cp FEATURE_DIRT
    jr nz, .notDirt
    ldh a, [hSpeed + 1]         ; dirt: drags the car down to a crawl
    cp DIRT_SPEED
    jr c, .notOn
    ldh a, [hSpeed]
    sub LOW(DIRT_DRAG)
    ldh [hSpeed], a
    jr nc, .notOn
    ldh a, [hSpeed + 1]
    dec a
    ldh [hSpeed + 1], a
    jr .notOn
.notDirt
    cp FEATURE_JUMP
    jr nz, .notOn
    ld a, 1                     ; jump plate: thrown into the air
    ldh [hAir], a
    ld a, LOW(JUMP_PLATE)
    ldh [hVZ], a
    ld a, HIGH(JUMP_PLATE)
    ldh [hVZ + 1], a
.notOn
    ; --- paint it: white, black for a jump plate; a dash plate flashes
    ldh a, [hFadeLevel]
    add a
    add a
    ld l, a
    ld a, c
    cp FEATURE_JUMP
    jr nz, .notBlack
    ld l, %00001100
.notBlack
    cp FEATURE_DIRT
    jr nz, .notGrey
    ld l, %00001000
.notGrey
    cp FEATURE_DASH
    jr nz, .steady
    ldh a, [hFrame]
    and %00000100
    jr z, .skip
.steady
    ld a, l
    ldh [hBandOr], a
    ldh a, [hBandEnd]
    ld l, a
    ldh a, [hBandEnd + 1]
    ld h, a
    push bc
    call RoadBand
    pop bc
.skip
    pop hl
    jp .next

DEF FEATURE_PLAIN EQU 0
DEF FEATURE_DASH  EQU 1
DEF FEATURE_JUMP  EQU 2
DEF FEATURE_DIRT  EQU 3
; \1 start, \2 end (units from the finish line), \3 kind.  In view from 8 chunks before.
MACRO FEATURE
    db ((\1) / 256 - 8) & CHUNK_MASK
    db ((\2) - 1) / 256 - (\1) / 256 + 9
    dw \1, \2
    db \3
ENDM
Features:
    FEATURE 0, LINE_END, FEATURE_PLAIN
    FEATURE PIT_START, PIT_END, FEATURE_PLAIN
    FEATURE 12 * 256, 12 * 256 + 90, FEATURE_DASH
    FEATURE 19 * 256, 19 * 256 + 200, FEATURE_DIRT
    FEATURE 35 * 256, 35 * 256 + 60, FEATURE_JUMP
    FEATURE 42 * 256, 42 * 256 + 200, FEATURE_DIRT
    FEATURE 45 * 256, 45 * 256 + 90, FEATURE_DASH
    FEATURE 54 * 256, 54 * 256 + 200, FEATURE_DIRT
    FEATURE 61 * 256, 61 * 256 + 90, FEATURE_DASH
    db $FF

; Sound effects on the noise channel (the music's drums take it back on their next hit).
DEF SFX_SKID  EQU 0
DEF SFX_HIT   EQU 2
DEF SFX_BOOST EQU 4
Sfx:
    push hl
    push de
    ld e, a
    ld d, 0
    ld hl, .table
    add hl, de
    xor a
    ldh [rAUD4LEN], a
    ld a, [hl+]
    ldh [rAUD4ENV], a
    ld a, [hl]
    ldh [rAUD4POLY], a
    ld a, $80
    ldh [rAUD4GO], a
    pop de
    pop hl
    ret
.table
    db $51, $23                 ; skid: short hiss
    db $F2, $65                 ; hit: thud
    db $A5, $14                 ; boost: rush

; Paint a stretch of the road.  de = where it starts, hl = where it ends, in units from
; the finish line.  b = BGP page being built, hBandOr = the road colour's bits there.
RoadBand:
    push bc
    ldh a, [hPos + 1]
    ld c, a
    ldh a, [hPos + 2]
    and CHUNK_MASK
    ld b, a                     ; bc = where we are on the lap
    ld a, e
    sub c
    ld e, a
    ld a, d
    sbc b
    and CHUNK_MASK
    ld d, a                     ; de = how far ahead it starts (wrapping round the lap)
    ld a, l
    sub c
    ld l, a
    ld a, h
    sbc b
    and CHUNK_MASK
    ld h, a                     ; hl = how far ahead it ends
    pop bc
    ld a, h
    cp 8
    jr c, .endInView
    ld a, d                     ; its end is beyond the horizon
    cp 8
    jr c, .toHorizon            ; ...but its start is in view
    ld a, e                     ; neither is in view: either it is all far ahead,
    sub l
    ld a, d
    sbc h
    ret c
    ld c, GROUND_LINES          ; or we are in the middle of it
    ld a, RIVAL_D4
    jr .paint
.toHorizon
    ld a, RIVAL_D4
    jr .haveFar
.endInView
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ld h, HIGH(DistToLine)
    ld a, [hl]
    cp GROUND_LINES + 1
    ret nc                      ; it has all gone by
.haveFar
    ld c, GROUND_LINES
    ld l, a                     ; keep the far line
    ld a, d
    cp 8
    ld a, l
    jr nc, .paint               ; its start is behind us: paint down to the bottom
    push af
    srl d
    rr e
    srl d
    rr e
    srl d
    rr e
    ld d, HIGH(DistToLine)
    ld a, [de]
    cp GROUND_LINES + 1
    jr nc, .startBehind
    ld c, a
.startBehind
    pop af
.paint                          ; a = far line, c = near line
    ld e, a
    ld a, c
    sub e
    ret c
    inc a
    ld c, a                     ; lines to paint
    ld a, e
    add HORIZON - 1
    ld l, a
    ld h, b
    ldh a, [hBandOr]
    ld e, a
    ld d, %11110011
    ld a, c
    and 3
    jr z, .fours
    ld b, a
.odd
    ld a, [hl]
    and d
    or e
    ld [hl+], a
    dec b
    jr nz, .odd
.fours
    srl c
    srl c
    ret z
.four
    REPT 4
        ld a, [hl]
        and d
        or e
        ld [hl+], a
    ENDR
    dec c
    jr nz, .four
    ret

; The status bar: place, lap, health.  Staged in wHud, copied to the tilemap in VBlank.
UpdateHud:
    ldh a, [hRank]              ; anything on it changed?  (cheap to check, dear to redo)
    ld b, a
    ldh a, [hLap]
    swap a
    or b
    ld b, a
    ldh a, [hFrame]
    and %00010000
    add a
    add a
    or b
    ld b, a
    ldh a, [hState]
    rrca
    rrca
    xor b
    ld b, a
    ldh a, [hHealth]
    ld c, a
    ldh a, [hBoosts]
    rrca
    rrca
    add c
    ld c, a
    ldh a, [hCount]
    add 59
    and %11000000
    rrca
    add c
    ld c, a
    ldh a, [hLinked]
    add c
    ld c, a
    ldh a, [hMode]
    swap a
    add c
    ld c, a
    ldh a, [hHudSeen]
    cp b
    jr nz, .redo
    ldh a, [hHudSeen + 1]
    cp c
    ret z
.redo
    ld a, b
    ldh [hHudSeen], a
    ld a, c
    ldh [hHudSeen + 1], a
    ld a, 1
    ldh [hHudDirty], a
    ld hl, wHud
    ldh a, [hMode]
    cp MODE_LINK
    jr nz, .notWaiting
    ldh a, [hLinked]
    or a
    jr nz, .notWaiting
    ld a, HUD_2                 ; "2P": waiting for the other console
    ld [hl+], a
    ld a, HUD_P
    ld [hl+], a
    ld a, HUD_BLANK
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    jp .bar
.notWaiting
    ldh a, [hPractice]
    or a
    jr nz, .noRace
    ldh a, [hState]
    cp STATE_FINISHED           ; after the flag, the finishing place blinks
    jr nz, .place
    ldh a, [hFrame]
    and %00010000
    jr z, .place
.noRace
    ld a, HUD_BLANK
    ld [hl+], a
    ld [hl+], a
    jr .lap
.place
    ld a, HUD_P
    ld [hl+], a
    ldh a, [hRank]
    call .digit
.lap
    ld a, HUD_BLANK
    ld [hl+], a
    ldh a, [hPractice]
    or a
    jr z, .laps
    ld a, HUD_BLANK
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    jr .bar
.laps
    ld a, HUD_L
    ld [hl+], a
    ldh a, [hLap]
    call .digit
    ld a, HUD_SLASH
    ld [hl+], a
    ldh a, [hLaps]
    call .digit
.bar
    ld a, HUD_BLANK
    ld [hl+], a
    ldh a, [hCount]             ; the start countdown: 3, 2, 1
    or a
    jr z, .boosts
    add 59
    rlca
    rlca
    and 3
    jr nz, .counting
    inc a
.counting
    call .digit
    ld a, HUD_BLANK
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    jr .health
.boosts
    ldh a, [hBoosts]            ; otherwise, a pip for each boost in hand
    ld c, a
    ld b, 3
.pip
    ld a, HUD_BLANK
    inc c
    dec c
    jr z, .noPip
    dec c
    ld a, HUD_HALF
.noPip
    ld [hl+], a
    dec b
    jr nz, .pip
    ld a, HUD_BLANK
    ld [hl+], a
.health
    ldh a, [hHealth]
    ld c, a                     ; health left to show
    ld b, 8
.cell
    ld a, c
    cp 8
    jr c, .partial
    sub 8
    ld c, a
    ld a, HUD_FULL
    jr .put
.partial
    cp 4
    ld c, 0
    ld a, HUD_HALF
    jr nc, .put
    ld a, HUD_EMPTY
.put
    ld [hl+], a
    dec b
    jr nz, .cell
    ret
.digit                          ; a = 1..8
    push hl
    ld e, a
    ld d, 0
    ld hl, HudDigits - 1
    add hl, de
    ld a, [hl]
    pop hl
    ld [hl+], a
    ret

HudDigits:
    db HUD_1, HUD_2, HUD_3, HUD_4, HUD_5, HUD_6, HUD_7, HUD_8

; ---------------------------------------------------------------------------------------
; Link cable.  A packet is LINK_N bytes, exchanged one at a time; both consoles send the
; same layout to each other in step:
;   0  %1000_00gw  sync (the only byte with bit 7 set): w = which rival this packet carries,
;                  g flips when that player restarts the race
;   1  position bits 0-6        2  bits 7-13      3  bits 14-15, then x bit 7, -, state (2 bits)
;   4  x bits 0-6
;   5  rival distance bits 0-6  6  bits 7-13      7  its lane
;   8  sum of 1..7, 7 bits
; "position" is the 16-bit count of units driven; distances are 14-bit signed.

; Called once a frame.  In link mode with no partner yet: listen, or call when Start is pressed.
LinkIdle:
    ldh a, [hMode]
    cp MODE_LINK
    ret nz
    ldh a, [hLinked]
    or a
    ret nz
    ldh a, [rSC]
    rla
    jr c, .armed
    ldh a, [rSB]                ; a byte went by (or nothing has been set up yet)
    ld b, a
    ldh a, [hLinkTry]
    or a
    jr z, .wasListening
    xor a
    ldh [hLinkTry], a
    ld a, b                     ; we called: did a waiting console answer?
    cp LINK_ANSWER
    jr nz, .listen
    ld a, LINK_MASTER
    jr .linked
.wasListening
    ld a, b                     ; we were listening: was that a call?
    cp LINK_CALL
    jr nz, .listen
    ld a, LINK_SLAVE
.linked
    ldh [hLinked], a
    xor a
    ldh [hGen], a
    ldh [hLinkIdx], a
    ldh [hLinkBusy], a
    ldh [hLinkFresh], a
    ldh [hLinkStale], a
    ldh [hLinkWhich], a
    call InitRace
    call BuildPacket
    ld a, [wLinkTx]
    ldh [rSB], a
    xor a                       ; timer: 4096 Hz, reloading from 0, interrupt not enabled
    ldh [rTMA], a
    ld a, LINK_TIMA
    ldh [rTIMA], a
    ld a, TACF_START | TACF_4KHZ
    ldh [rTAC], a
    ldh a, [hLinked]
    cp LINK_SLAVE
    ret nz
    ld a, $80                   ; the slave waits for the master's clock
    ldh [rSC], a
    ret
.listen
    ld a, LINK_ANSWER
    ldh [rSB], a
    ld a, $80
    ldh [rSC], a
    ret
.armed
    ldh a, [hLinkTry]
    or a
    ret nz
    ldh a, [hCurKeys]
    and PADF_SELECT
    ret nz
    ldh a, [hNewKeys]
    and PADF_START
    ret z
    ld a, LINK_CALL             ; Start: call the other console, on our clock
    ldh [rSB], a
    ld a, $81
    ldh [rSC], a
    ld a, 1
    ldh [hLinkTry], a
    ret

; Look at the serial port and move the packet exchange along a byte if it is time.
; Called from many places so that a byte never waits long.  Keeps bc, de, hl.
LinkPump:
    ldh a, [hLinked]
    or a
    ret z
    dec a
    jr nz, .slave
    ldh a, [hLinkBusy]          ; master
    or a
    jr nz, .onWire
    ldh a, [rTIMA]              ; the timer (no interrupt, just read) measures the gap:
    cp LINK_TIMA                ; set to LINK_TIMA when a byte finishes, it has wrapped
    ret nc                      ; round to a small number once the gap is over
    ld a, $81
    ldh [rSC], a                ; clock the next byte out
    ld a, 1
    ldh [hLinkBusy], a
    ret
.onWire
    ldh a, [rSC]
    rla
    ret c                       ; still going
    xor a
    ldh [hLinkBusy], a
    push hl
    push de
    push bc
    call LinkReceive
    pop bc
    pop de
    pop hl
    ld a, LINK_TIMA
    ldh [rTIMA], a
    ret
.slave
    ldh a, [rSC]
    rla
    ret c                       ; nothing has come yet
    push hl
    push de
    push bc
    call LinkReceive
    ld a, $80
    ldh [rSC], a                ; ready for the next
    pop bc
    pop de
    pop hl
    ret

; A byte has arrived: file it, and load the next one to send.
LinkReceive:
    ldh a, [rSB]
    ld b, a
    ldh a, [hLinkIdx]
    ld e, a
    bit 7, b
    jr z, .file
    ldh a, [hLinked]            ; a sync byte: the slave lines its packet up on the master's
    cp LINK_SLAVE
    jr nz, .file
    ld e, 0
.file
    ld d, 0
    ld hl, wLinkRx
    add hl, de
    ld [hl], b
    inc e
    ld a, e
    cp LINK_N
    jr c, .next
    call PacketDone
    ld e, 0
.next
    ld a, e
    ldh [hLinkIdx], a
    ld d, 0
    ld hl, wLinkTx
    add hl, de
    ld a, [hl]
    ldh [rSB], a
    ret

; A whole packet is in: if it adds up, keep it for LinkApply.  Then make our next one.
PacketDone:
    ld hl, wLinkRx
    bit 7, [hl]
    jr z, BuildPacket
    inc hl
    ld b, 7
    xor a
.sum
    add [hl]
    inc hl
    dec b
    jr nz, .sum
    and $7F
    cp [hl]
    jr nz, BuildPacket
    ld hl, wLinkRx
    ld de, wRemote
    ld b, LINK_N - 1
.keep
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .keep
    ld a, 1
    ldh [hLinkFresh], a
    ; fall through

; Our side of the next packet, from where things are right now.
BuildPacket:
    ld hl, wLinkTx
    ldh a, [hLinkWhich]
    xor 1
    ldh [hLinkWhich], a
    ld c, a                     ; which of our two rivals goes in this one
    ldh a, [hGen]
    add a
    or c
    or $80
    ld [hl+], a
    ldh a, [hPos + 1]
    ld e, a
    ldh a, [hPos + 2]
    ld d, a
    rlca
    rlca
    and 3
    ld b, a                     ; bits 14-15
    call .put14
    ldh a, [hX + 1]
    ld e, a
    rlca
    rlca
    rlca
    and %00000100
    or b
    ld b, a
    ldh a, [hState]
    swap a
    and %00110000
    or b
    ld [hl+], a
    ld a, e
    and $7F
    ld [hl+], a
    push hl
    ld a, c                     ; rival record c: distance at +1, lane at +5
    add a
    add a
    add a
    inc a
    ld l, a
    ld h, HIGH(wRivals)
    ld a, [hl+]
    ld e, a
    ld a, [hl+]
    ld d, a
    inc l
    inc l
    ld a, [hl]
    and 3
    ld b, a
    pop hl
    ld a, d                     ; keep it inside 14 bits signed
    add $20
    cp $40
    jr c, .fits
    bit 7, d
    ld de, $1FFF
    jr z, .fits
    ld de, $2000
.fits
    call .put14
    ld a, b
    ld [hl+], a
    ld de, wLinkTx + 1
    ld b, 7
    xor a
.sum
    ld c, a
    ld a, [de]
    add c
    inc de
    dec b
    jr nz, .sum
    and $7F
    ld [hl], a
    ret
.put14                          ; de -> two 7-bit bytes at hl.  Leaves d shifted left by one
    ld a, e
    and $7F
    ld [hl+], a
    sla e
    rl d
    ld a, d
    and $7F
    ld [hl+], a
    ret

; Once a frame: use the newest packet to place the other console's cars.
LinkApply:
    ldh a, [hLinked]
    or a
    ret z
    ldh a, [hLinkFresh]
    or a
    jr nz, .fresh
    ldh a, [hLinkStale]         ; nothing new: has the cable gone?
    inc a
    ldh [hLinkStale], a
    cp LINK_TIMEOUT
    ret c
    xor a
    ldh [hLinked], a
    ldh [rSC], a
    jp InitRace
.fresh
    xor a
    ldh [hLinkFresh], a
    ldh [hLinkStale], a
    ld a, [wRemote]             ; they restarted the race?  so do we
    rra
    and 1
    ld b, a
    ldh a, [hGen]
    cp b
    jr z, .sameRace
    ld a, b
    ldh [hGen], a
    jp InitRace
.sameRace
    ld hl, wRemote + 1
    call .get14
    ld a, [hl]                  ; bits 14-15 of their position
    rrca
    rrca
    and %11000000
    or d
    ld d, a
    ldh a, [hPos + 1]           ; how far they are ahead of us
    ld c, a
    ld a, e
    sub c
    ld e, a
    ldh a, [hPos + 2]
    ld c, a
    ld a, d
    sbc c
    ld d, a
    push de
    ; the other player: record 4
    ld a, [hl+]
    ld b, a                     ; flags
    ld a, [hl+]
    bit 2, b
    jr z, .xPositive
    or $80
.xPositive
    add X_LIMIT                 ; (keep it on the road: it may be mid-jump over the edge)
    cp X_LIMIT * 2 + 1
    jr c, .xOnRoad
    bit 7, a
    ld a, X_LIMIT * 2
    jr z, .xOnRoad
    xor a
.xOnRoad
    sub X_LIMIT
    ld [wRivals + 4 * 8 + 3], a
    ld a, b
    and %00110000
    cp STATE_DEAD << 4
    jr nz, .theyLive
    ld de, HIDDEN - PLAYER_Z    ; a wreck is not shown
.theyLive
    ld a, e
    add PLAYER_Z
    ld [wRivals + 4 * 8 + 1], a
    ld a, d
    adc 0
    ld [wRivals + 4 * 8 + 2], a
    ; one of their rivals: record 2 or 3
    call .get14
    bit 5, d                    ; 14-bit signed
    jr z, .ahead
    ld a, d
    or %11000000
    ld d, a
.ahead
    ld a, [hl]                  ; its lane
    and 3
    or REMOTE
    ld b, a
    pop hl                      ; + how far their player is ahead of us
    add hl, de
    ld d, h
    ld e, l
    ld a, [wRemote]
    and 1
    add 2
    add a
    add a
    add a
    inc a
    ld l, a
    ld h, HIGH(wRivals)
    ld a, e
    ld [hl+], a
    ld a, d
    ld [hl+], a
    inc l
    inc l
    ld [hl], b
    ret
.get14                          ; two 7-bit bytes at hl -> de
    ld a, [hl+]
    ld e, a
    ld a, [hl+]
    ld d, a
    rra
    jr nc, .evenTop
    set 7, e
.evenTop
    srl d
    ret

; Put everything back on the grid.  Keeps the mode and the level.
InitRace:
    xor a
    ldh [hPos], a
    ldh [hPos + 1], a
    ldh [hPos + 2], a
    ldh [hPosCoarse], a
    ldh [hSpeed], a
    ldh [hSpeed + 1], a
    ldh [hChunk], a
    ldh [hState], a
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
    ldh [hLean], a
    ld a, %11100000
    ldh [rOBP0], a
    ld a, BEND_LEVELS
    ldh [hBend], a
    ldh [hTarget], a
    ld a, CAR_Y + 16
    ldh [hCarY], a
    ld a, CAR_X + 8
    ldh [hCarX], a
    ld a, 3
    ldh [hSkyStale], a
    ld a, SHEAR_MAX
    ldh [hShear], a
    ld a, SHADOW_TILE
    ldh [hShadowTile], a
    ld a, $FF                   ; force the status bar to redraw
    ldh [hHudSeen], a
    ldh [hHudSeen + 1], a
    xor a
    ldh [hBoost], a
    ldh [hSkid], a
    ldh [hCount], a
    ldh a, [hPractice]
    or a
    jr nz, .noCountdown
    ld a, COUNTDOWN
    ldh [hCount], a
.noCountdown
    ld a, 1
    ldh [hBoosts], a
    ld a, HEALTH_MAX
    ldh [hHealth], a
    ld a, 1
    ldh [hLap], a
    ld a, NUM_RIVALS + 1
    ldh [hRank], a
    ldh a, [hLevel]             ; level 1: three laps.  level 2: five, and a quicker field
    or a
    ld a, 3
    ld b, 0
    jr z, .level
    ld a, 5
    ld b, 16
.level
    ldh [hLaps], a
    ld a, b
    ldh [hPace], a
    ld de, RivalStart
    ldh a, [hMode]
    cp MODE_LINK
    jr nz, .grid
    ld de, RivalsAlone          ; link mode: nobody until the cable is up, then the
    ldh a, [hLinked]            ; two-player grid, players side by side
    or a
    jr z, .grid
    ld de, RivalsMaster
    ld b, -16
    dec a
    jr z, .side
    ld de, RivalsSlave
    ld b, 16
.side
    ld a, b
    ldh [hX + 1], a
.grid
    ld hl, wRivals
    ld bc, NUM_RIVALS * 8
    call Copy
    ld hl, wOrder
    xor a
.order
    ld [hl+], a
    inc a
    cp NUM_RIVALS
    jr nz, .order
    ret

; ---------------------------------------------------------------------------------------
; Speed, bend, distance and the direction the skyline faces.
Drive:
    ld hl, hFrame
    inc [hl]
    ldh a, [hCurKeys]
    ld b, a

    ; --- Select and Start together: switch between racing and practice
    and PADF_START | PADF_SELECT
    cp PADF_START | PADF_SELECT
    jr nz, .noChord
    ldh a, [hNewKeys]
    and PADF_START | PADF_SELECT
    jr z, .noChord
    ldh a, [hMode]              ; race -> practice -> link -> race
    inc a
    cp MODE_LINK + 1
    jr c, .modeSet
    xor a
.modeSet
    ldh [hMode], a
    cp MODE_PRACTICE
    ld a, 0
    jr nz, .practiceSet
    inc a
.practiceSet
    ldh [hPractice], a
    xor a                       ; any change of mode drops the cable
    ldh [hLinked], a
    ldh [hLinkTry], a
    ldh [rSC], a
    jp InitRace
.noChord
    ; --- Select (outside practice): engine note on / off
    ldh a, [hPractice]
    or a
    jr nz, .engineSet
    ldh a, [hNewKeys]
    and PADF_SELECT
    jr z, .engineSet
    ldh a, [hEngine]
    xor 1
    ldh [hEngine], a
    push bc
    ld c, a
    ld b, 1                     ; it takes over channel 2 from the music
    call hUGE_mute_channel
    pop bc
    ldh a, [hEngine]
    or a
    jr z, .engineOff
    ld a, %01000000             ; 25% duty
    ldh [rAUD2LEN], a
    ld a, $50
    ldh [rAUD2ENV], a
    ld a, $80 | HIGH(ENGINE_BASE)
    ldh [rAUD2HIGH], a
    jr .engineSet
.engineOff
    xor a
    ldh [rAUD2ENV], a
.engineSet
    ; --- Start once the race is over: go again, on the next level if we finished
    ldh a, [hState]
    or a
    jr z, .throttle
    ldh a, [hNewKeys]
    and PADF_START
    jr z, .throttle
    ldh a, [hState]
    cp STATE_FINISHED
    jr nz, .again
    ldh a, [hLevel]
    xor 1
    ldh [hLevel], a
.again
    ldh a, [hGen]               ; (linked: the other console sees this flip and restarts too)
    xor 1
    ldh [hGen], a
    jp InitRace

.throttle
    ldh a, [hSpeed]
    ld l, a
    ldh a, [hSpeed + 1]
    ld h, a
    ldh a, [hState]
    cp STATE_DEAD
    jr z, .braking              ; a wreck just stops
    or a
    jr nz, .coast               ; past the flag: roll to a halt
    ldh a, [hCount]             ; on the grid: wait for the start
    or a
    jr z, .go
    dec a
    ldh [hCount], a
    ld hl, 0
    jp .speedSet
.go
    ; Up fires a boost if there is one
    ldh a, [hNewKeys]
    and PADF_UP
    jr z, .noFire
    ldh a, [hBoosts]
    or a
    jr z, .noFire
    dec a
    ldh [hBoosts], a
    ld a, BOOST_TIME
    ldh [hBoost], a
    ld a, SFX_BOOST
    call Sfx
.noFire
    ldh a, [hBoost]
    or a
    jr z, .noBoost
    dec a
    ldh [hBoost], a
    ld de, $0040                ; boosting: shove toward the higher limit
    add hl, de
    ld a, h
    cp BOOST_MAX
    jr c, .speedSet
    ld hl, BOOST_MAX << 8
    jr .speedSet
.noBoost
    ld a, h                     ; over the normal limit (after a boost): bleed back down
    cp SPEED_MAX
    jr c, .underLimit
    ld de, -$0010
    add hl, de
    jr .speedSet
.underLimit
    bit 0, b                    ; PADF_A
    jr z, .coast
    ; the throttle: strong from rest, fading to nothing at top speed
    ld a, SPEED_MAX
    sub h                       ; 1..8 "gears" below the limit
    add a
    add 3
    ld e, a
    ld d, 0
    add hl, de
    ld a, h
    cp SPEED_MAX
    jr c, .throttled
    ld hl, SPEED_MAX << 8
.throttled
    bit 7, b                    ; throttle and brake together: the brake wins a little
    jr z, .speedSet
.braking
    ld de, -BRAKE
    jr .slow
.coast
    ld de, -BRAKE
    bit 7, b                    ; PADF_DOWN
    jr nz, .slow
    ld de, -FRICTION
.slow
    add hl, de
    jr c, .speedSet             ; no borrow
    ld hl, 0
.speedSet
    ld a, l
    ldh [hSpeed], a
    ld a, h
    ldh [hSpeed + 1], a

    ldh a, [hEngine]            ; the engine note climbs with speed
    or a
    jr z, .noNote
    ld d, h
    ld e, l
    srl d
    rr e
    srl d
    rr e
    ld a, e
    add LOW(ENGINE_BASE)
    ldh [rAUD2LOW], a
    ld a, d
    adc HIGH(ENGINE_BASE)
    ldh [rAUD2HIGH], a
.noNote

    ; --- distance driven (24 bit: fraction, units, chunks)
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

    ; --- a fade in progress?  Half way through, in the dark, change level
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
    xor a
    ldh [hX], a
    ldh [hX + 1], a
    ldh [hVX], a
    ldh [hObjOn], a
    ldh a, [hFadeTunnel]
    ldh [hTunnel], a
    or a
    jr z, .fadeLevel
    ldh a, [hPos + 2]           ; the tunnel is a short cut: we come out further on,
    add TUNNEL_SKIP
    ldh [hPos + 2], a
    ld hl, wRivals + 2          ; which puts every rival that much less far ahead
    ld c, NUM_RIVALS
.shift
    ld a, [hl]
    sub TUNNEL_SKIP
    ld [hl], a
    ld a, l
    add 8
    ld l, a
    dec c
    jr nz, .shift
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
    ld e, a
    ld d, 0
    ld hl, SpriteFade           ; the sprites darken with the background
    add hl, de
    ld a, [hl]
    ldh [rOBP0], a
.fadeDone

    ; --- which chunk of the lap are we in?  Things happen on entering one
    ldh a, [hPos + 2]
    and CHUNK_MASK
    ld c, a
    ldh a, [hChunk]
    cp c
    jr z, .sameChunk
    ld a, c
    ldh [hChunk], a
    ldh a, [hPractice]
    ld e, a
    ldh a, [hState]
    or e
    jr nz, .sameChunk           ; nothing counts in practice or once the race is over
    ld a, c
    or a
    jr nz, .notLine
    ldh a, [hLaps]              ; across the line
    ld e, a
    ldh a, [hLap]
    cp e
    jr c, .nextLap
    ld a, STATE_FINISHED
    ldh [hState], a
    jr .sameChunk
.nextLap
    inc a
    ldh [hLap], a
    ldh a, [hBoosts]            ; a boost for every lap done
    cp BOOSTS_MAX
    jr nc, .sameChunk
    inc a
    ldh [hBoosts], a
    jr .sameChunk
.notLine
    ld e, a                     ; does something appear on the road ahead here?
    ld d, 0
    ld hl, ChunkSpawn
    add hl, de
    ld a, [hl]
    or a
    jr z, .notMouth
    ld e, a
    ldh a, [hObjOn]
    or a
    jr nz, .notMouth            ; (one thing at a time)
    ld a, e
    dec a
    ldh [hObjKind], a           ; 0 the tunnel mouth, 1-4 a barrier in that lane
    ldh a, [hPos + 1]
    add LOW(SPAWN_DIST)
    ldh [hObjZ], a
    ldh a, [hPos + 2]
    adc HIGH(SPAWN_DIST)
    ldh [hObjZ + 1], a
    ld a, 1
    ldh [hObjOn], a
    jr .sameChunk
.notMouth
    ldh a, [hChunk]
    cp EXIT_CHUNK
    jr nz, .sameChunk
    ldh a, [hTunnel]
    or a
    jr z, .sameChunk
    xor a
    call StartFade              ; back up to the surface
.sameChunk

    ; --- the recharge strip tops the car up
    ldh a, [hState]
    or a
    jr nz, .noCharge
    ldh a, [hPos + 2]
    and CHUNK_MASK
    dec a
    cp (PIT_END - PIT_START) / 256
    jr nc, .noCharge
    ldh a, [hFrame]
    rra
    jr c, .noCharge
    ldh a, [hHealth]
    cp HEALTH_MAX
    jr nc, .noCharge
    inc a
    ldh [hHealth], a
.noCharge

    ; --- where should the bend be heading?
    ldh a, [hPractice]
    or a
    jr nz, .byHand
    ld hl, TrackBend
    ldh a, [hTunnel]
    or a
    jr z, .surface
    ld hl, TunnelBend
.surface
    ld e, c
    ld d, 0
    add hl, de
    ld a, [hl]
    ldh [hTarget], a
    jr .haveTarget
.byHand                         ; practice: Select bends it left, Start right
    ldh a, [hTarget]
    bit 2, b                    ; PADF_SELECT
    jr z, .notBendLeft
    or a
    jr z, .notBendLeft
    dec a
.notBendLeft
    bit 3, b                    ; PADF_START
    jr z, .notBendRight
    cp BEND_LEVELS * 2
    jr nc, .notBendRight
    inc a
.notBendRight
    ldh [hTarget], a
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

    bit 0, b                    ; on the throttle the push on the car is twice that: flat
    jr z, .lifted               ; out, a full bend outruns the steering.  Lift off and the
    sla e                       ; car grips
    rl d
.lifted

    ; --- steering: ease sideways speed toward what the d-pad asks for
    ldh a, [hAir]
    ld c, a
    ldh a, [hState]
    or c
    jr z, .grounded
    ldh a, [hVX]                ; no grip in the air (or in a wreck): keep drifting
    ld b, a
    jr .vxDone
.grounded
    ; braking while steering at speed is a skid turn: far more steering, less speed
    xor a
    ldh [hSkid], a
    ld h, STEER_MAX
    ld a, b
    and PADF_LEFT | PADF_RIGHT
    jr z, .noSkid
    bit 7, b                    ; PADF_DOWN
    jr z, .noSkid
    ldh a, [hSpeed + 1]
    cp 3
    jr c, .noSkid
    ld h, STEER_SKID
    ld a, 1
    ldh [hSkid], a
    ldh a, [hSpeed]
    sub LOW(SKID_COST)
    ldh [hSpeed], a
    jr nc, .skidSound
    ldh a, [hSpeed + 1]
    dec a
    ldh [hSpeed + 1], a
.skidSound
    ldh a, [hFrame]
    and 7
    jr nz, .noSkid
    ld a, SFX_SKID
    call Sfx
.noSkid
    ld c, 0
    bit 5, b                    ; PADF_LEFT
    jr z, .notLeft
    ld a, h
    cpl
    inc a
    ld c, a
.notLeft
    bit 4, b                    ; PADF_RIGHT
    jr z, .notRight
    ld c, h
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
    dec b
    dec b
    dec b
    dec b
.vxUp
    inc b
    inc b
    inc b
    inc b
    ld a, c                     ; (do not overshoot what was asked for)
    sub b
    add 3
    cp 7
    jr nc, .vxSet
    ld b, c
.vxSet
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
    ldh a, [hAir]               ; there is no rail in the air: come down outside it and
    or a                        ; the car is gone
    jr nz, .xOk
    ld a, h                     ; on the ground the rail keeps us in, at a price
    add X_LIMIT
    cp X_LIMIT * 2
    jr c, .xOk
    bit 7, h                    ; the rail: bounce back off it, at a price
    ld hl, X_LIMIT << 8
    ld b, -RAIL_BOUNCE
    jr z, .bounce
    ld hl, -(X_LIMIT << 8)
    ld b, RAIL_BOUNCE
.bounce
    ld a, b
    ldh [hVX], a
    ld a, RAIL_COST
    call Damage
    ld a, SFX_HIT
    call Sfx
    ldh a, [hSpeed + 1]
    or a
    jr z, .xOk
    dec a                       ; RAIL_SCRUB is one whole unit
    ldh [hSpeed + 1], a
.xOk
    ld a, l
    ldh [hX], a
    ld a, h
    ldh [hX + 1], a

    ; --- the camera follows half way (as far as the picture reaches); the car shows the rest
    sra a
    add SHEAR_MAX
    bit 7, a
    jr z, .camLow
    xor a
.camLow
    cp SHEAR_MAX * 2 + 1
    jr c, .camSet
    ld a, SHEAR_MAX * 2
.camSet
    ldh [hShear], a
    sub SHEAR_MAX
    ld c, a
    ld a, h
    sub c
    add CAR_X + 8
    ldh [hCarX], a

    ; --- lean into the turn
    ld c, 0
    ld a, b
    add BANK_AT - 1
    cp BANK_AT * 2 - 1
    jr c, .leanDone             ; |speed| < BANK_AT
    inc c                       ; left
    bit 7, b
    jr nz, .leanDone
    inc c                       ; right
.leanDone
    ld a, c
    ldh [hLean], a

    ; --- jumping: B launches the car; the shadow stays on the road
    ldh a, [hAir]
    or a
    jr nz, .inAir
    ldh a, [hState]
    or a
    jr nz, .onGround
    ldh a, [hNewKeys]
    and PADF_B
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
    ldh a, [hX + 1]             ; ...on the road?
    add X_LIMIT
    cp X_LIMIT * 2 + 1
    jr c, .stillUp
    ld a, HEALTH_MAX            ; no: destroyed
    call Damage
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

DEF STATE_FINISHED EQU 1
DEF STATE_DEAD     EQU 2

; The course, one entry per chunk.  \1 chunks at bend \2 (0 hard left, 32 straight, 64 hard right).
MACRO STRETCH
    REPT \1
        db \2
    ENDR
ENDM

TrackBend:
    STRETCH 6, 32               ; start/finish straight, recharge strip
    STRETCH 4, 44               ; easy right
    STRETCH 6, 32               ; the tunnel mouth is on this straight
    STRETCH 6, 4                ; hairpin left
    STRETCH 2, 32
    STRETCH 6, 60               ; hairpin right
    STRETCH 2, 18               ; chicane
    STRETCH 2, 46
    STRETCH 4, 32
    STRETCH 6, 12               ; long left
    STRETCH 4, 32
    STRETCH 4, 50               ; right
    STRETCH 4, 16               ; left
    STRETCH 4, 44               ; right
    STRETCH 4, 32
    ASSERT @ - TrackBend == CHUNK_MASK + 1

; What appears ahead on entering each chunk: 0 nothing, 1 the tunnel mouth, 2-5 a barrier in
; lane 0-3.  It turns up SPAWN_DIST (four chunks) further on.
DEF MOUTH    EQU 1
DEF BARRIER  EQU 2
ChunkSpawn:
    db 0, 0, 0, BARRIER + 1, 0, 0, 0, 0
    db 0, 0, MOUTH, 0, 0, 0, 0, 0
    db 0, 0, 0, 0, 0, 0, 0, 0
    db 0, 0, BARRIER + 2, 0, 0, 0, 0, 0
    db 0, BARRIER + 0, 0, 0, 0, 0, 0, 0
    db BARRIER + 3, 0, 0, 0, 0, 0, 0, BARRIER + 1
    db 0, 0, 0, 0, 0, BARRIER + 2, 0, 0
    db 0, 0, BARRIER + 0, 0, 0, 0, 0, 0
    ASSERT @ - ChunkSpawn == CHUNK_MASK + 1

TunnelBend:                     ; what the same chunks are like underground
    STRETCH 24, 32
    STRETCH 4, 38
    STRETCH 4, 28
    STRETCH 32, 32
    ASSERT @ - TunnelBend == CHUNK_MASK + 1

; The pace the field runs at through each chunk, in 1/32 unit per frame.
; Each rival adds its own skill to this.
SpeedProfile:
    STRETCH 6, 185
    STRETCH 4, 150
    STRETCH 6, 185
    STRETCH 6, 105
    STRETCH 2, 150
    STRETCH 6, 105
    STRETCH 2, 125
    STRETCH 2, 125
    STRETCH 4, 185
    STRETCH 6, 125
    STRETCH 4, 185
    STRETCH 4, 140
    STRETCH 4, 130
    STRETCH 4, 145
    STRETCH 4, 185
    ASSERT @ - SpeedProfile == CHUNK_MASK + 1

FadeLevels:                     ; darkness for each eighth of a fade
    db 1, 2, 3, 3, 3, 3, 2, 1

SpriteFade:                     ; OBP0 at each darkness
    db %11100000, %11110100, %11111000, %11111100

; Sprites for each size of tunnel mouth: count, then (x offset from the centre, tile, flip).
BarrierFar:
    db 1
    db 4, CAR4_TILE, 0
MouthSize1:
    db 2
    db 0, MOUTH_TILE, 0
    db 8, MOUTH_TILE, OAMF_XFLIP
MouthSize2:
    db 4
    db -8, MOUTH_TILE + 2, 0
    db 0, MOUTH_TILE + 4, 0
    db 8, MOUTH_TILE + 4, OAMF_XFLIP
    db 16, MOUTH_TILE + 2, OAMF_XFLIP
MouthSize3:
    db 5
    db -12, MOUTH_TILE + 6, 0
    db -4, MOUTH_TILE + 8, 0
    db 4, MOUTH_TILE + 10, 0
    db 12, MOUTH_TILE + 8, OAMF_XFLIP
    db 20, MOUTH_TILE + 6, OAMF_XFLIP

; Sprites for each size of rival: count, then (y offset, x offset, tile, attributes).
DEF RP EQU OAMF_PAL1
DEF RPX EQU OAMF_PAL1 | OAMF_XFLIP
RivalSize16:
    db 4
    db -2, 0, CAR_TILE, RP
    db -2, 8, CAR_TILE, RPX
    db 13, 0, SHADOW_TILE, RP
    db 13, 8, SHADOW_TILE, RPX
RivalSize12:
    db 2
    db -1, 0, CAR12_TILE, RP
    db -1, 8, CAR12_TILE, RPX
RivalSize8:
    db 1
    db -1, 4, CAR8_TILE, RP
RivalSize4:
    db 1
    db 0, 4, CAR4_TILE, RP

RivalLaneU:
    RIVAL_LANE_U

; Each rival: distance ahead of the camera (fraction, low, high), skill, stun timer, lane,
; paint, spare.  Paint is an OBP1 value; colour 2 stays dark grey in all so shadows work.
MACRO RIVAL
    db 0
    dw \1
    db \2, 0, \3, \4, 0
ENDM
; Link mode.  Each console drives two rivals (first two records) and is told about the other
; console's two and the other player (next three).  The last two never appear.
MACRO GHOST                     ; a car the other console places: paint, flags
    db 0
    dw HIDDEN
    db 0, 0, \2, \1, 0
ENDM
DEF PAINT_A EQU %11100100
DEF PAINT_B EQU %01100000
DEF PAINT_C EQU %00100100
DEF PAINT_D EQU %11101000
DEF PAINT_P EQU %00101100       ; the other player: black, white trim
RivalsMaster:
    RIVAL PLAYER_Z + 70, 30, 0, PAINT_A
    RIVAL PLAYER_Z + 110, 20, 3, PAINT_B
    GHOST PAINT_C, REMOTE
    GHOST PAINT_D, REMOTE
    GHOST PAINT_P, REMOTE | FREE_X
    GHOST PAINT_P, REMOTE
    GHOST PAINT_P, REMOTE
RivalsSlave:
    RIVAL PLAYER_Z + 150, 30, 1, PAINT_C
    RIVAL PLAYER_Z + 190, 20, 2, PAINT_D
    GHOST PAINT_A, REMOTE
    GHOST PAINT_B, REMOTE
    GHOST PAINT_P, REMOTE | FREE_X
    GHOST PAINT_P, REMOTE
    GHOST PAINT_P, REMOTE
RivalsAlone:
    REPT NUM_RIVALS
        GHOST PAINT_P, REMOTE
    ENDR

RivalStart:                     ; the grid: everyone starts ahead of the player
    RIVAL PLAYER_Z + 40, 10, 1, %11100100   ; grey, black trim
    RIVAL PLAYER_Z + 80, 22, 2, %00101100   ; black, white trim
    RIVAL PLAYER_Z + 120, 4, 0, %01101100   ; black, grey trim
    RIVAL PLAYER_Z + 160, 34, 3, %01100000  ; white, grey trim
    RIVAL PLAYER_Z + 200, 16, 1, %00100100  ; grey, white trim
    RIVAL PLAYER_Z + 240, 28, 2, %11101000  ; dark, black trim
    RIVAL PLAYER_Z + 280, 40, 0, %00101000  ; dark, white trim

DmaCode:                        ; runs from HRAM: nothing else is readable during DMA
    ld a, HIGH(wOam)
    ldh [rDMA], a
    ld a, 40
.wait
    dec a
    jr nz, .wait
    ret
.end

; ---------------------------------------------------------------------------------------
StartSong:
    call SongBank
    ld hl, race_song
    jp hUGE_init

SongBank:
    ld a, BANK(race_song)
    ld [rROMB0], a
    ret

; hl = BGP page of a buffer (SCX and OBP1 pages follow it)
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
    ld a, %11100000
.obp
    ld [hl+], a
    inc l
    dec l
    jr nz, .obp
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

SkyBgp:
    INCBIN "build/skybgp.bin"

; ---------------------------------------------------------------------------------------
; Page-aligned lookups: the low byte of the address is the index.
SECTION "dist to line", ROM0, ALIGN[8]
DistToLine:                     ; distance ahead / 8 -> ground line
    INCBIN "build/dist.bin"

SECTION "lane offsets", ROM0, ALIGN[8]
LaneOffsets:                    ; ground line -> pixels from road centre to the left lane
    INCBIN "build/lane.bin"

SECTION "rival lanes", ROM0, ALIGN[8]
RivalLanes:                     ; lane * 128 + ground line -> pixels from the road centre
    INCBIN "build/rlane.bin"

MACRO PAL_TABLE
SECTION "pal \1", ROMX, BANK[PAL_BANK], ALIGN[8]
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

SECTION "fzero tiles", ROMX, BANK[TILE_BANK]
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

SECTION "fzero line tables", ROMX, BANK[GFX_BANK]
BendTables:                     ; (BEND_LEVELS*2+1) x GROUND_LINES values of SCX
    INCBIN "build/bend.bin"
ShearTables:                    ; (SHEAR_MAX*2+1) x GROUND_LINES amounts to add to SCX
    INCBIN "build/shear.bin"

; ---------------------------------------------------------------------------------------
; Two sets of per-line values; one is on screen while the other is being filled.
; Each is a BGP page, an SCX page and an OBP1 page, indexed by screen line.
SECTION "line buffers", WRAM0[$C100]
wLinesA: ds 768
wLinesB: ds 768

SECTION "staged oam", WRAM0[$C700]
wOam:                           ; copied to OAM by DMA in VBlank
    ds 16                       ; player car and shadow
wObjOam:
    ds OBJ_SPRITES * 4          ; road object
    ds 160 - 16 - OBJ_SPRITES * 4   ; rivals

SECTION "rivals", WRAM0[$C800]
wRivals: ds NUM_RIVALS * 8
wOrder:  ds NUM_RIVALS          ; rival numbers, far to near
wHud:    ds 20                  ; the status bar's tiles
wLinkTx: ds LINK_N              ; the packet being sent
wLinkRx: ds LINK_N              ; the one arriving
wRemote: ds LINK_N              ; the last good one

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
hLean:        db    ; 0 level, 1 leaning left, 2 leaning right
hRivalIdx:    ds 2  ; loop counter, and a spare
hRLane:       db
hRPaint:      db
hAttrMask:    db
hSkyStale:    db    ; frames for which the sky lines still need rewriting
hDma:         ds 10 ; the DMA routine
hShadowTile:  db
hAir:         db    ; nonzero while jumping
hZ:           dw    ; height above the road, 8.8 pixels
hVZ:          dw    ; upward speed, signed 8.8
hTunnel:      db    ; nonzero while underground
hObjOn:       db    ; road object: 0 none, 1 approaching, 2 lane already tested
hObjZ:        dw    ; its place along the track, same units as hPos + 1
hObjY:        db
hBuiltScx:    db    ; high byte of the SCX buffer BuildLines just filled
hFadeStep:    db    ; 0 = not fading, else 1..FADE_LENGTH-1
hFadeLevel:   db    ; current darkness, 0..3
hFadeTunnel:  db    ; which way the fade is taking us: 1 down into the tunnel, 0 back up
hMode:        db    ; MODE_RACE, MODE_PRACTICE, MODE_LINK
hPractice:    db    ; 1 in practice mode: no laps, no damage, bend the road by hand
hLinked:      db    ; 0 no partner, LINK_MASTER, LINK_SLAVE
hLinkTry:     db    ; we have called and are waiting for the answer
hLinkIdx:     db    ; byte of the packet being exchanged
hLinkBusy:    db    ; master: a byte is on the wire
hLinkFresh:   db    ; a good packet is waiting in wRemote
hLinkStale:   db    ; frames since the last one
hLinkWhich:   db    ; which of our rivals the next packet carries
hGen:         db    ; flips when a linked race is restarted
hState:       db    ; 0 racing, STATE_FINISHED, STATE_DEAD
hLevel:       db
hLaps:        db    ; laps in this race
hLap:         db    ; the one we are on, from 1
hChunk:       db    ; chunk of the lap we were in last frame
hHealth:      db
hRank:        db    ; our place, 1 = leading
hRankCount:   db
hPace:        db    ; added to every rival's speed on this level
hRivalRec:    db    ; low byte of the rival record being worked on
hHudSeen:     dw    ; what the status bar was last drawn from
hHudDirty:    db    ; wHud is waiting to be copied to the screen
hBoost:       db    ; frames of boost left
hBoosts:      db    ; boosts in hand
hSkid:        db    ; in a skid turn this frame
hCount:       db    ; frames until the start
hBandEnd:     dw
hBandOr:      db
hObjKind:     db    ; road object: 0 tunnel mouth, 1-4 barrier in lane 0-3
hEngine:      db    ; engine note on
hScriptTimer: db
hCarY:        db
hCurKeys:     db
hNewKeys:     db
hLoad:        db
