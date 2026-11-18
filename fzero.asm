; F-Zero style city, proof of concept.
;
; The picture is ONE static tilemap of a road and city drawn in perspective (tools/gen_gfx.py).
; Nothing in VRAM changes while it runs.  Every scanline, in HBlank, two registers are
; rewritten for the line about to be drawn:
;
;   BGP  recolours the line.  Which part of a building (wall/roof/street) lies under a line
;        depends on that line's depth plus how far we have driven, so the city flows toward
;        the camera at the right speed for every line: slow at the horizon, fast up close.
;   SCX  slides the line sideways.  A different amount per line bends the road.  Up the
;        road, past where the next corner starts, the lines take that corner's bend: it is
;        seen as a kink on the horizon a couple of seconds early and comes down the screen.
;
; Each frame the main loop works out those two values for all 144 lines into a spare buffer
; and VBlank swaps it in, so the interrupt only has to copy two bytes.
;
; Steering moves the camera sideways, which is a shear: near lines slide a lot, far lines
; hardly at all.  That is one more per-line table added into SCX.
;
; Forks: a tunnel mouth (a sprite that grows as it nears) comes down the left lane.  Drive
; into it and the screen fades out and back in underground, a few chunks further on (a short
; cut); at its exit it fades back up.  The tunnel is the same tilemap under darker palette
; tables, and follows the same bends as the road above.
;
; Rivals: every car uses the same tiles.  A livery is a sprite palette, and OBP1 is one more
; register rewritten per scanline, so each rival gets its own paint on the lines it occupies.
;
; The race: one lap is 64 chunks of 256 units.  The course shape, the rivals' pace and the
; places things happen (finish line, recharge strip, tunnel) are all tables indexed by chunk.
;
; The course is straights and short corners (tools/gen_tracks.py): a corner lasts a chunk
; or two, half a second or so, and each lap turns exactly once round.
;
; Driving feel: the throttle pulls hard at low speed and tails off toward the top; bends
; throw the car outward, less if you lift off; the brakes take the edge off but never stop
; the car, and cut a boost short; braking while steering is a skid turn (much more
; steering, at a cost in speed); the rail bounces you back and costs health (never speed:
; only dirt slows the car); boosts (one per lap, or free from a dash plate) break the speed
; limit for a moment.
;
; Hazards, both things to steer round: dirt patches (dirt spilled over one half of the road,
; which drags the car down) and barriers (blocks in one lane that hurt, slow and toss it).
; Dirt, boost pads and recharge patches are the same three tiles: the OBP1 value painted on
; their lines decides whether the dirt shows or the arrows hidden in it do.
;
; Scenery: each chunk of the lap has a scenery (city, underpass, water), which is nothing but
; a choice of palette tables.  Each distance band looks up the scenery of the chunk it is
; over, so a change of scenery comes toward you from the horizon.
;
; A wreck: the car's sprite is switched to a spare tile which is then overwritten in VRAM
; with noise for the explosion, and put back from ROM for the next race.
;
; Controls: Left/Right steer, B accelerate, A (or Down) brake, Up boost.
;           Select turns the engine note on and off (it borrows the music's second channel).
;           Start after a race: go again; Select then: back to the menu.
;           Select+Start together: back to the menu at any time.
;
; The menu picks the track, how quick the rivals are (or none), the mode (race, practice, two-player
; link) and the engine note.  It has real lettering because it borrows the tiles a track's
; skyline uses; choosing a track loads that skyline, the track's tables (into RAM, so the
; rest of the code just reads fixed addresses), its sceneries and its song.
;
; Two players: both pick link mode, one presses Start.  Each console runs its own car and
; two rivals and tells the other where they are; the other shows them a few frames late.
; The console that called sets the track and the rivals for both (RIVALS NONE: just the two).
; The serial port is polled (LinkPump), never interrupt driven, so it cannot delay HBlank.
;
; Music is music/race.uge (edit it in hUGETracker), played by hUGEDriver.

INCLUDE "include/hardware.inc"
INCLUDE "build/consts.inc"

DEF GFX_BANK    EQU 2           ; per-line bend and shear tables, read every frame
DEF TILE_BANK   EQU 4           ; tiles and tilemap, copied to VRAM once
DEF PAL_BANK    EQU 5           ; palette tables, each with two darker copies for fades:
DEF PAL_BANK2   EQU 6           ; one bank per set of sceneries (a track uses one set)
DEF RESULT_BANK EQU 12          ; the places painted on the road at the end (Finale)
DEF PAINT_DONE  EQU 2           ; Finale's painting: 0 not yet, 1 under way, 2 done
DEF FINISH_BRAKE EQU $0020      ; past the flag the camera comes to a stop (a second or so)
DEF NUM_TRACKS  EQU 4
DEF SKY_FONT    EQU 4           ; the menu's lettering, loaded where a skyline goes
DEF MENU_LCDC   EQU LCDCF_ON | LCDCF_BGON | LCDCF_BG8000 | LCDCF_BG9C00
DEF LCDC_COMMON EQU LCDCF_ON | LCDCF_BGON | LCDCF_OBJON | LCDCF_OBJ16 | LCDCF_BG9800 | LCDCF_WINON | LCDCF_WIN9C00
DEF LCDC_UPPER  EQU LCDC_COMMON | LCDCF_BG8000
DEF LCDC_LOWER  EQU LCDC_COMMON | LCDCF_BG8800
DEF SPEED_MAX   EQU $08
DEF CAR_X       EQU 72          ; screen position when centred
DEF CAR_Y       EQU 118
DEF SHADOW_TILE EQU CAR_TILE + 2
DEF MOUTH_TILE  EQU CAR_TILE + 6
DEF CAR12_TILE  EQU CAR_TILE + 18  ; the car at 12, 8 and 4 pixels, for rivals up the road
DEF CAR8_TILE   EQU CAR_TILE + 20
DEF CAR4_TILE   EQU CAR_TILE + 22
DEF HERO_TILE   EQU CAR_TILE + 30  ; the player's own car: the one picked in the menu (CarStats)
    ASSERT HERO_TILE + 2 == 128
DEF NUM_RIVALS  EQU 7
DEF PLAYER_Z    EQU 175         ; how far ahead of the camera the player's car is
DEF RIVAL_OAM   EQU 14 * 4      ; rivals own three OAM entries each from here on
DEF SPEEDO_OAM  EQU 39 * 4      ; the speedometer's car (after the rivals' 21)
DEF SPEEDO_X    EQU 12 * 8      ; where its track starts on the status bar (tile 12)
DEF PLAYER_D    EQU 95          ; ground line the player's car sits on
DEF BOOST_MAX   EQU $0B         ; top speed while boosting
DEF BOOST_TIME  EQU 80          ; frames a boost lasts
DEF DASH_TIME   EQU 45          ; frames of boost from a dash plate
DEF BOOSTS_MAX  EQU 3
DEF COUNTDOWN   EQU 180         ; frames on the grid before the start
DEF LEVELS      EQU 5           ; difficulty settings: how quick the rivals are
DEF LEVEL_START EQU 3
DEF STEER_SKID  EQU 40          ; sideways speed in a skid turn
DEF SKID_COST   EQU $000C       ; extra speed a skid turn scrubs off per frame
DEF RAIL_BOUNCE EQU 20          ; sideways speed coming back off the rail
DEF RAIL_COST   EQU 5           ; health lost hitting it
DEF RAIL_COOL   EQU 45          ; frames before another hit can hurt again
DEF PUSH_K      EQU 72          ; how hard bends throw the car outward (see PushScale)
DEF CATCH_UP    EQU 6           ; extra pace for rivals just behind the player (1/16 unit)
DEF CATCH_UP_FAR EQU 18         ; ...and for ones over two chunks behind: the field stays in
                                ; touch whatever the level (ROOKIE's rivals are 16 slower)
DEF EASE_OFF    EQU 8           ; less for ones four chunks or more ahead
DEF BEHIND_Z    EQU PLAYER_Z - 90  ; where a rival is put to pounce on a mistake
DEF JUMP_PLATE  EQU $0400       ; take-off speed from a jump plate
DEF DIRT_DRAG   EQU $0030       ; speed lost per frame on dirt, down to DIRT_SPEED
DEF DIRT_TIME   EQU 30          ; frames a patch drags for once driven into
DEF DIRT_TILE   EQU CAR_TILE + 24  ; ground patch pieces (dirt, pads), 8, 12 and 16 lines deep
; Their colour numbers are roles (dirt_objects in tools/gen_gfx.py): 1 the arrows, 2 dirt,
; 3 darker specks.  These OBP1 values pick which show (shades: 0 white .. 3 black):
DEF DIRT_OBP    EQU %11101000   ; dirt: arrows the same dark grey as the dirt, specks black
DEF PAD_OBP_A   EQU %01010000   ; boost pad: dirt in the road's grey, arrows white...
DEF PAD_OBP_B   EQU %01011100   ; ...then black
DEF HEAL_OBP_A  EQU %10100000   ; recharge patch: dark, with white arrows...
DEF HEAL_OBP_B  EQU %00001000   ; ...then light, with dark ones
DEF RAMP_OBP    EQU %01101100   ; jump ramp (the tunnel mouth's shape): light grey, dark stripes, black rim
DEF BARRIER_D3  EQU 66          ; ground line from which a barrier is drawn at its biggest
DEF BOOM_TILE   EQU SHADOW_TILE + 2  ; the small shadow's tile: the explosion is drawn into it
DEF BOOM_TIME   EQU 70          ; frames the explosion lasts
DEF DIRT_SPEED  EQU 3
DEF BARRIER_COST EQU 12         ; health lost hitting a barrier
DEF ENGINE_BASE EQU $02C0       ; engine note at rest (a frequency register value, ~97 Hz)
DEF REV_GAS     EQU 64          ; how far the note rides above the speed on the gas (accelerating)
DEF REV_TOP     EQU 16          ; ...on the gas at top speed
DEF REV_LIFT    EQU -40         ; ...and below it off the gas
DEF RASP        EQU 6           ; the engine's flutter, every other pair of frames
DEF FRICTION    EQU $000A       ; lost per frame off it: lifting scrubs speed off (a unit in ~0.4 s)
DEF BRAKE       EQU $0014
DEF BRAKE_FLOOR EQU 2           ; braking alone takes the car no lower than this
DEF HEALTH_MAX  EQU 64
DEF LOW_HEALTH  EQU 16          ; below this: an alarm ticks and the health bar blinks
DEF KNOCK_COST  EQU 3           ; health lost bumping a rival
DEF STUN_TIME   EQU 45          ; frames a knocked rival runs at half pace
DEF RIVAL_AIR   EQU 18          ; a rival off a ramp: its moves in the air (each two frames)...
DEF RIVAL_LIFT  EQU 10          ; ...how high it goes (pixels, at its biggest)...
DEF RIVAL_JUMP_PACE EQU 48      ; ...and the ramp's boost while it flies (1/16 unit a frame)
DEF FLYING      EQU %10000000   ; a rival's stun byte: set, the rest is its moves left in the air
DEF RAMP_WINDOW EQU 48          ; a rival takes off within this many units of its chunk's start
DEF LEAD        EQU SPAWN_DIST / 256   ; chunks between where a thing appears and where it sits
DEF CHUNK_MASK  EQU 63          ; 64 chunks to a lap
DEF HEAL_BASE   EQU 26          ; health from a recharge patch at a standstill...
DEF HEAL_SPEED  EQU 2           ; ...less this for each unit of speed: slow down for more
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
DEF OBJ_SPRITES EQU 5           ; OAM entries kept for each road object
DEF OBJ_SLOTS   EQU 2           ; road objects that can be out at once
DEF LANE_EDGE   EQU -6          ; left of this, the car is in the tunnel's lane
DEF SCX_STAMP   EQU 200         ; offset in an SCX page of its (bend, shear) note
DEF FADE_LENGTH EQU 64          ; frames; the switch happens half way, in the dark
DEF X_LIMIT     EQU ROAD_HALF - 12  ; how far from the centre line the car may go
DEF STEER_MAX   EQU 24          ; sideways speed, 1/16 pixel per frame
DEF BANK_AT     EQU 10          ; sideways speed at which the car visibly leans
DEF JUMP_SPEED  EQU $0300       ; upward speed at take-off, 8.8 pixels per frame
DEF JUMP_RAMP   EQU $0300       ; take-off speed from a ramp: about 38 frames in the air
DEF LAND_SLIDE  EQU 24          ; frames after landing that steering takes hold slowly
DEF GRAVITY     EQU $28

; ---------------------------------------------------------------------------------------
SECTION "vblank vector", ROM0[$40]
    jp VBlankISR

; HBlank of line LY: load the registers for line LY+1.  This is the most expensive thing in
; the program (it runs once a scanline), so:
;  - It does not run at all for the top of the sky.  VBlank arms only the LY=LYC interrupt,
;    for line SKY_STATIC-1; lines above that all use what VBlank loaded for line 0.  That
;    first call then switches the interrupt over to HBlank for the rest of the frame.
;  - The two once-a-frame jobs (that switch, and changing tile block at SPLIT_LINE) are found
;    with one mask test, because 32 and 64 are the only lines in range with five low zero bits
;    that need anything.
; It is placed right at the vector (and runs on through the unused vectors after it).
    ASSERT SKY_STATIC == 32 && SPLIT_LINE == 64
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
    and %00011111
    jr z, .event
    pop hl
    pop af
    reti
.event
    ld a, l
    cp SPLIT_LINE
    jr z, .split
    cp SKY_STATIC
    jr nz, .done
    ldh a, [rSTAT]              ; first call of the frame (from LY=LYC): from here on, HBlank.
    and STATF_MODE00            ; (Only once: on a DMG, writing STAT can itself raise this
    jr nz, .done                ; interrupt again.)
    ld a, STATF_MODE00
    ldh [rSTAT], a
    jr .done
.split                          ; lower part of the picture takes its tiles from $9000
    ld a, LCDC_LOWER
    ldh [rLCDC], a
.done
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
    ldh a, [hMenu]              ; in the menu there is nothing to do but say it happened
    or a
    jr z, .game
    ld a, 1
    ldh [hVBlank], a
    pop af
    reti
.game
    push hl
    ldh a, [hReady]             ; a finished frame waiting?  make it the live one
    or a
    jp z, .keep
    ldh [hFront], a
    xor a
    ldh [hReady], a
    call hDma                   ; and its sprites with it
    ldh a, [hTileJob]           ; anything to draw into the explosion's tile?
    or a
    jr z, .noJob
    push bc
    ld b, a
    xor a
    ldh [hTileJob], a
    ld hl, _VRAM8000 + BOOM_TILE * 16
    dec b
    jr nz, .boom
    push de                     ; TILE_RESTORE: the small shadow, back from ROM
    ld de, BoomTilePristine
    ld b, 32
.restore
    ld a, [de]
    ld [hl+], a
    inc de
    dec b
    jr nz, .restore
    pop de
    jr .jobDone
.boom                           ; TILE_BOOM: noise, thinning out as the explosion ages
    ldh a, [hRand]
    ld c, a
    ld b, 32
.noise
    ld a, c                     ; an 8-bit shift register for the noise
    srl a
    jr nc, .noTap
    xor $B8
.noTap
    ld c, a
    ldh a, [hBoom]
    cp BOOM_TIME / 2
    ld a, c
    jr c, .dense
    rrca
    and c                       ; later: sparser
    push af
    ldh a, [hBoom]
    cp BOOM_TIME - 8
    jr c, .sparse
    pop af
    xor a                       ; last frames: gone
    push af
.sparse
    pop af
.dense
    ld [hl+], a
    dec b
    jr nz, .noise
    ld a, c
    ldh [hRand], a
.jobDone
    pop bc
.noJob
    ldh a, [hHudDirty]
    or a
    jr z, .noHud
    ld a, [wPainted]            ; (its tiles lent to the place painted on the road: blank)
    or a
    jr nz, .noHud
    ldh [hHudDirty], a
    push bc
    push de
    ld hl, wHud                 ; and the status bar, if it changed
    ld de, _SCRN1
    ld b, 20
.hud
    ld a, [hl+]
    ld [de], a
    inc e
    dec b
    jr nz, .hud
    pop de
    pop bc
.noHud
    ld a, [wPaintCount]         ; a piece of the painted place, staged by Finale?
    or a
    jr z, .keep
    push bc
    push de
    ld b, a
    ld a, [wPaintDst]
    ld e, a
    ld a, [wPaintDst + 1]
    ld d, a
    ld hl, wPaintBuf
.paint
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .paint
    xor a
    ld [wPaintCount], a
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
    ld a, STATF_LYC             ; no HBlank interrupts until the sky's last few lines.
    ldh [rSTAT], a              ; (If this write raises a stray one on a DMG, it finds copies
    ld a, 1                     ; of line 0's values in the buffer entries past the screen.)
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
    ld de, Tilemap              ; the ground: tile rows 5 down.  The sky rows come with a track
    ld hl, _SCRN0 + SKY_MAP_BYTES
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

    xor a
    ldh [hReady], a
    ldh [hVBlank], a
    ldh [hFrame], a
    ldh [hCurKeys], a
    ldh [hNewKeys], a
    ldh [hMode], a
    ldh [hTileJob], a
    ldh [hEngine], a
    ldh [hPractice], a
    ldh [hLinked], a
    ldh [hLinkTry], a
    ldh [hGen], a
    ldh [hSkyX], a
    ldh [hSkyX + 1], a
    ldh [hTrackNo], a
    ld [wMenuRow], a
    ld [wPainted], a            ; (nothing painted on the road to put back)
    ld [wCar], a
    ld [wPaintStep], a
    ld [wPaintCount], a
    dec a
    ld [wSongNow], a            ; (no song yet)
    ld a, 1                     ; the engine note on: half of how fast it feels (Select: off)
    ldh [hEngine], a
    ld a, HIGH(wLinesA)
    ldh [hFront], a
    ld a, LEVEL_START
    ldh [hLevel], a

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

    ld a, HUD_LINE              ; the status bar: a window over the bottom eight lines
    ldh [rWY], a
    ld a, 7
    ldh [rWX], a
    ld a, SKY_STATIC - 1
    ldh [rLYC], a
    ; fall through into the menu (the screen is still off)

; ---------------------------------------------------------------------------------------
; The menu.  Up/Down pick a line, Left/Right change it, Start (or A or B) goes racing.
Menu:
    ld sp, $E000                ; (we get here from deep inside the game too)
    call LcdOff
    call Unpaint
    ld a, 1
    ldh [hMenu], a
    xor a
    ldh [rSCX], a
    ldh [rSCY], a
    ldh [rSC], a                ; coming back here drops any link
    ldh [hLinked], a
    ldh [hLinkTry], a
    ldh [rAUD2ENV], a           ; and silences the engine
    ld b, 1
    ld c, a
    call hUGE_mute_channel
    ld a, %00011011             ; white letters on black
    ldh [rBGP], a
    ld a, SKY_FONT
    call LoadSky
    ld hl, _SCRN1
    ld bc, 32 * 18
.clear
    ld a, ' '
    ld [hl+], a
    dec bc
    ld a, b
    or c
    jr nz, .clear
    ld hl, MenuText
.label                          ; (address, length, text) until a zero length
    ld a, [hl+]
    ld e, a
    ld a, [hl+]
    ld d, a
    ld a, [hl+]
    or a
    jr z, .labelled
    ld b, a
.letter
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .letter
    jr .label
.labelled
    call DrawMenu
    xor a
    ldh [rIF], a
    ld a, IEF_VBLANK
    ldh [rIE], a
    ld a, MENU_LCDC
    ldh [rLCDC], a
    ei
.frame
    xor a
    ldh [hVBlank], a
.wait
    di
    ldh a, [hVBlank]
    or a
    jr nz, .awake
    ei
    halt
    jr .wait
.awake
    ei
    ld a, [wMenuDirty]          ; (VBlank has just begun: a safe moment to redraw)
    or a
    call nz, DrawMenu
    call UpdateKeys
    ldh a, [hNewKeys]
    ld b, a
    and PADF_START | PADF_A | PADF_B
    jp nz, StartRace
    ld a, [wMenuRow]
    bit 6, b                    ; PADF_UP
    jr z, .notUp
    or a
    jr z, .notUp
    dec a
.notUp
    bit 7, b                    ; PADF_DOWN
    jr z, .notDown
    cp 4
    jr nc, .notDown
    inc a
.notDown
    ld [wMenuRow], a
    add a                       ; each line: where its value lives, and how many it has
    add a
    ld e, a
    ld d, 0
    ld hl, MenuLines
    add hl, de
    ld a, [hl+]
    ld e, a
    ld a, [hl+]
    ld d, a                     ; de -> the value
    ld a, [hl+]
    ld c, a                     ; lowest
    ld h, [hl]                  ; highest
    ld a, [de]
    bit 5, b                    ; PADF_LEFT
    jr z, .notLeft
    cp c
    jr z, .notLeft
    dec a
.notLeft
    bit 4, b                    ; PADF_RIGHT
    jr z, .notRight
    cp h
    jr nc, .notRight
    inc a
.notRight
    ld [de], a
    ld a, b
    and PADF_UP | PADF_DOWN | PADF_LEFT | PADF_RIGHT
    ld [wMenuDirty], a
    call SongBank
    call hUGE_dosound
    jr .frame

MenuLines:                      ; value, lowest, highest
    dw hTrackNo
    db 0, NUM_TRACKS - 1
    dw wCar
    db 0, NUM_CARS - 1
    dw hLevel
    db 0, LEVELS                ; 0: no rivals (a time trial; linked, just the two players)
    dw hMode
    db 0, MODE_LINK
    dw hEngine
    db 0, 1

MACRO MENU_TEXT                 ; \1 = row, \2 = column, \3 = text
    dw _SCRN1 + (\1) * 32 + (\2)
    db STRLEN(\3), \3
ENDM
MenuText:
    MENU_TEXT 2, 5, "FSUB RACER"
    MENU_TEXT 5, 3, "TRACK"
    MENU_TEXT 7, 3, "CAR"
    MENU_TEXT 9, 3, "RIVALS"
    MENU_TEXT 11, 3, "MODE"
    MENU_TEXT 13, 3, "ENGINE"
    MENU_TEXT 16, 5, "START - GO"
    dw 0
    db 0

DEF MENU_VALUE EQU 9            ; letters in a value
MenuValues:                     ; for each line, its values in order
    dw .tracks, .cars, .rivals, .modes, .engine
.tracks
    db "NEO CITY ", "BLUE DEEP", "GOLD WIND", "OLD PORT "
.cars
    db "ARROW    ", "HORNET   ", "BISON    ", "COMET    "
.rivals
    db "NONE     ", "ROOKIE   ", "EASY     ", "NORMAL   ", "HARD     ", "EXPERT   "
.modes
    db "RACE     ", "PRACTICE ", "LINK     "
.engine
    db "OFF      ", "ON       "

; Write the cursor and the five values.  (Only when the screen is off or VBlank has just begun.)
DrawMenu:
    xor a
    ld [wMenuDirty], a
    ld c, a                     ; line
.line
    ld a, c                     ; where on the screen: rows 5, 7, 9, 11, 13
    add a
    add 5
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    ld de, _SCRN1 + 1
    add hl, de
    ld a, [wMenuRow]
    cp c
    ld a, '>'
    jr z, .cursor
    ld a, ' '
.cursor
    ld [hl], a
    ld de, 9
    add hl, de                  ; the value starts at column 10
    push hl
    ld a, c
    add a
    add a
    ld e, a
    ld d, 0
    ld hl, MenuLines
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ld b, [hl]                  ; the value's number
    ld a, c
    add a
    ld e, a
    ld hl, MenuValues
    add hl, de
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ld a, b
    add a
    add a
    add a
    add b                       ; * MENU_VALUE
    ld e, a
    add hl, de
    ld d, h
    ld e, l
    pop hl
    ld b, MENU_VALUE
.value
    ld a, [de]
    ld [hl+], a
    inc de
    dec b
    jr nz, .value
    inc c
    ld a, c
    cp 5
    jr nz, .line
    ret

; Leave the menu: load the chosen track and start a race.
StartRace:
    call LcdOff
    xor a
    ldh [hMenu], a
    ldh [hReady], a
    ldh [hGen], a
    call LoadCar
    call LoadTrackData
    ld hl, _SCRN1               ; a clean status bar
    ld b, 32
    ld a, HUD_BLANK
.clearHud
    ld [hl+], a
    dec b
    jr nz, .clearHud
    ld hl, wLinesA
    call InitLines
    ld hl, wLinesB
    call InitLines
    ld a, HIGH(wLinesA)
    ldh [hFront], a
    ldh a, [hMode]
    cp MODE_PRACTICE
    ld a, 0
    jr nz, .practice
    inc a
.practice
    ldh [hPractice], a
    call StartSong
    call EngineApply
    call InitRace
    ld a, STATF_LYC
    ldh [rSTAT], a
    xor a
    ldh [rIF], a
    ld a, IEF_VBLANK | IEF_STAT
    ldh [rIE], a
    ld a, LCDC_UPPER
    ldh [rLCDC], a
    ei
    jp MainLoop

; Turn the screen off (only ever done in VBlank; interrupts are left off for the caller).
LcdOff:
    di
    ldh a, [rLCDC]
    add a
    ret nc                      ; already off
.wait
    ldh a, [rLY]
    cp 145
    jr nz, .wait
    xor a
    ldh [rLCDC], a
    ret

; Everything a track needs, from its number in hTrackNo.  The screen must be off.
LoadTrackData:
    ld a, TILE_BANK
    ld [rROMB0], a
    ld de, Tracks
    ldh a, [hTrackNo]
    add a                       ; 512 bytes each
    add d
    ld d, a
    ld hl, wTrack
    ld bc, 512
    call Copy
    ld hl, PalSetA              ; its set of sceneries: which bank, and the table pages
    ld a, [wTrkPalSet]
    or a
    jr z, .set
    ld hl, PalSetB
.set
    ld a, [hl+]
    ld [wPalBank], a
    ld de, wScenePages
    ld b, 21
.pages
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .pages
    ld a, $FF                   ; where the track's ramp sits (one at most), and the lanes
    ld [wRampChunk], a          ; that take off from it (rivals: UpdateRivals .move)
    ld c, 0
.rampChunk
    ld a, c
    sub LEAD                    ; (a thing appears LEAD chunks before it sits)
    and CHUNK_MASK
    ld e, a
    ld d, 0
    ld hl, wChunkSpawn
    add hl, de
    ld a, [hl]
    ld b, %0011                 ; the left half: lanes 0 and 1
    cp JUMP_L
    jr z, .ramp
    ld b, %1100
    cp JUMP_R
    jr nz, .notRamp
.ramp
    ld a, c
    ld [wRampChunk], a
    ld a, b
    ld [wRampLanes], a
.notRamp
    inc c
    bit 6, c
    jr z, .rampChunk
    ld a, 3
    ldh [hSkyStale], a
    ld a, [wTrkSkyline]
    ; fall through

; Load skyline a (or the menu's lettering) into the sky's tile slots, with its part of the
; tilemap and its sky palettes if it has them.  The screen must be off.
LoadSky:
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                  ; 16 bytes an entry
    ld de, SkyTable
    add hl, de
    ld a, TILE_BANK
    ld [rROMB0], a
    ld de, _VRAM8000 + SKY_8000_FIRST * 16
    call .piece
    ld de, _VRAM8800 + SKY_8800_FIRST * 16
    call .piece
    ld de, _SCRN0
    call .piece
    ld de, wSkyBgp
.piece                          ; (source, length) at hl, destination de
    push de
    ld a, [hl+]
    ld e, a
    ld a, [hl+]
    ld d, a                     ; de = source
    ld a, [hl+]
    ld c, a
    ld a, [hl+]
    ld b, a                     ; bc = length
    push hl                     ; our place in the table
    ld hl, sp + 2
    ld a, [hl+]
    ld h, [hl]
    ld l, a                     ; hl = destination
    ld a, b
    or c
    call nz, Copy
    pop hl
    pop de
    ret

; The engine note setting -> the sound hardware.
EngineApply:
    ldh a, [hEngine]
    ld c, a
    ld b, 1                     ; it takes channel 2 from the music
    call hUGE_mute_channel
    xor a
    ldh [hEngineMode], a
    ldh a, [hEngine]
    or a
    jr z, .off
    ld a, %01000000             ; 25% duty
    ldh [rAUD2LEN], a
    ld a, $50
    ldh [rAUD2ENV], a
    ld a, $80 | HIGH(ENGINE_BASE)
    ldh [rAUD2HIGH], a
    ret
.off
    xor a
    ldh [rAUD2ENV], a
    ret

MainLoop:
    xor a
    ldh [hVBlank], a
.wait
    di                          ; checking the flag and going to sleep must not be split by
    ldh a, [hVBlank]            ; the VBlank interrupt, or the sleep would last until the
    or a                        ; next interrupt, which is now well down the sky
    jr nz, .frame
    ldh a, [hLinked]
    or a
    jr nz, .awake               ; linked: stay awake and keep the cable moving
    ei
    halt                        ; (ei takes effect after the next instruction: no gap)
    jr .wait
.awake
    ei
    call LinkPump
    jr .wait
.frame
    ei
    call UpdateKeys
    call LinkIdle
    call Drive
    call LinkPump
    call LinkApply
    call Finale
    call BuildLines
    call LinkPump
    call UpdateRivals
    call UpdateObject           ; (after the rivals: a boost pad's palette wins on its lines)
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
MACRO FILL_BAND                 ; \1 = band, 0 the furthest; \2 = 1 if it counts in 16s
    IF \2
        ldh a, [hPosCoarse]
    ELSE
        ldh a, [hPos + 1]
    ENDC
    ld c, a
    ldh a, [hBandBase + \1]     ; this band's palette table, for the scenery it is over
    ld h, a
    ldh a, [hFadeLevel]         ; (the darker copies of a table follow it)
    add h
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
    call UpdateScene
    ldh a, [hFront]
    xor HIGH(wLinesA) ^ HIGH(wLinesB)
    ld b, a                     ; b = the buffer not on screen
    ld a, [wPalBank]
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
    cp HUD_LINE
    ld a, $FF
    jr nz, .black
    jp .bgpReady
.lit
    ld d, b
    ld e, HORIZON
    FILL_ALL_BANDS
    ldh a, [hSkyStale]
    or a
    jp z, .bgpDone
    dec a
    ldh [hSkyStale], a
    ldh a, [hRoof]
    or a
    jr nz, .roofed
    ld de, wSkyBgp              ; sky fades toward the horizon glow
    ldh a, [hFadeLevel]         ; (its darker copies follow it too)
    or a
    jr z, .flashing
    ld de, wSkyBgp + HORIZON
    dec a
    jr z, .skyTable
    ld de, wSkyBgp + HORIZON * 2
    jr .skyTable
.flashing
    ldh a, [hFlash]             ; a boost has just fired: the sky flashes white, then grey
    or a
    jr z, .skyTable
    ld de, wSkyFlash
    cp 5
    jr nc, .skyTable
    ld de, wSkyFlash + HORIZON
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
.roofed
    ld h, b                     ; underground: everything above the road is black
    ld l, 0
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
    ld h, b                     ; the status bar's lines: their own palette, flashing in
    ld l, HUD_LINE              ; negative for a moment when a new lap begins
    ldh a, [hLapFlash]
    or a
    ld a, HUD_BGP
    jr z, .hudPalette
    ldh a, [hFrame]
    and %00001000
    ld a, HUD_BGP
    jr z, .hudPalette
    ld a, HUD_BGP ^ $FF
.hudPalette
    REPT 8
        ld [hl+], a
    ENDR

    ; A stray interrupt during VBlank (see VBlankISR) would load from just past line 144:
    ; keep copies of line 0's values there.
    ld h, b
    ld l, 0
    ld a, [hl]
    ld l, 144
    REPT 8
        ld [hl+], a
    ENDR

    ; SCX: the sky all turns together.  Only line 0 and the lines from SKY_STATIC are ever
    ; loaded, so only those are written.
    inc b
    ld h, b
    ldh a, [hSkyX + 1]
    ld [hl], a                  ; (l is 152 here; harmless)
    ld l, 0
    ld [hl], a
    ld l, SKY_STATIC
    REPT HORIZON - SKY_STATIC
        ld [hl+], a
    ENDR
    ld l, 144
    REPT 8
        ld [hl+], a
    ENDR

    ; ground: bend (how the road curves) + shear (where the camera is across it).  Up the
    ; road, where the next corner (or the end of this one) starts, the road changes to that
    ; corner's bend: a kink far off that comes down the screen as the car closes on it.  The
    ; lines above that point are drawn with the far bend and then moved across to join on.
    ; Each buffer notes the bend and shear it was filled for (in two spare bytes of its SCX
    ; page): on a straight with the wheel still and no corner in sight, that is unchanged and
    ; the fill is skipped.
    ld a, b
    ldh [hBuiltScx], a          ; sprites look up where the road is on each line
    ld a, GFX_BANK
    ld [rROMB0], a
    call CornerAhead
    ld a, c
    ldh [hFarLines], a           ; how many lines from the horizon down show the far bend
    ldh a, [hBuiltScx]
    ld h, a
    ld l, SCX_STAMP
    ld a, c
    or a
    jr z, .plain
    ld [hl], $FF                ; (a corner in sight: drawn every frame, noted as no plain fill)
    jr .refill
.plain
    ldh a, [hBend]
    cp [hl]
    jr nz, .note
    inc l
    ldh a, [hShear]
    cp [hl]
    jp z, .scxDone
    dec l
.note
    ldh a, [hBend]
    ld [hl+], a
    ldh a, [hShear]
    ld [hl], a
.refill
    ldh a, [hShear]
    add a
    ld l, a
    ld h, 0
    ld bc, ShearPointers + (SHEAR_SPAN - SHEAR_MAX) * 2  ; (the tables go wider than the camera)
    add hl, bc
    ld a, [hl+]
    ld b, [hl]
    ld c, a                     ; bc -> the shear row
    ldh a, [hBuiltScx]
    ld d, a
    ld e, HORIZON               ; de -> the first ground line's SCX
    ldh a, [hFarLines]
    or a
    jr z, .near
    ld hl, .near                ; the lines up to the corner, with its bend (they return to .near)
    push hl
    call GroundEntry
    push hl
    ldh a, [hFar]
    call BendRow
    ret
.near
    LINK_PUMP
    ld hl, .joined              ; the rest, with the bend the car is in
    push hl
    ldh a, [hFarLines]
    cpl
    add HUD_LINE - HORIZON + 1  ; (all the ground lines but those)
    call GroundEntry
    push hl
    ldh a, [hBend]
    call BendRow
    ldh a, [hFarLines]
    add l
    ld l, a
    adc h
    sub l
    ld h, a                     ; (from the line it has got to)
    ret
.joined
    LINK_PUMP
    ldh a, [hFarLines]
    or a
    jr z, .scxDone
    ld c, a                     ; join the far road on where the near road reaches the corner:
    ldh a, [hFar]               ; move it by near bend - far bend on that line
    call BendRow
    ld a, c
    add l
    ld l, a
    adc h
    sub l
    ld h, a
    ld b, [hl]
    ldh a, [hBend]
    call BendRow
    ld a, c
    add l
    ld l, a
    adc h
    sub l
    ld h, a
    ld a, [hl]
    sub b
    ld b, a                     ; b = how far
    ld a, c
    call ShiftEntry
    push hl
    ldh a, [hBuiltScx]
    ld h, a
    ld l, HORIZON
    ret                         ; (it returns from BuildLines)
.scxDone
    ret

; Where the next change of bend up the road is: the first chunk past the car's whose bend
; differs from the one the car is in.  Returns c = how many ground lines, from the horizon
; down, lie beyond where it starts (0: none in sight), and that bend in hFar.
CornerAhead:
    ld c, 0
    ldh a, [hPractice]
    or a
    ret nz
    ldh a, [hPos + 1]           ; first chunk past the one the car is in
    add PLAYER_Z
    ldh a, [hPos + 2]
    adc 0
    inc a
    ld c, a                     ; c = that chunk, counting on from the start of the race
    ld e, a
    ld d, 0
    ld hl, wTrackBend
    ldh a, [hTunnel]
    or a
    jr z, .aheadTable
    ld hl, wTunnelBend
.aheadTable
    ld b, 8                     ; look up to 8 chunks ahead
    ldh a, [hBend]
    ldh [hNear], a
.ahead
    ld a, e
    and CHUNK_MASK
    push hl
    add l
    ld l, a
    adc h
    sub l
    ld h, a
    ld a, [hl]
    pop hl
    and $7F
    ld d, a
    ldh a, [hNear]
    cp d
    jr nz, .found
    inc e
    dec b
    jr nz, .ahead
.none
    ld c, 0
    ret                         ; the same bend all the way to the horizon
.found
    ld a, d
    ldh [hFar], a
    ld d, e                     ; how far ahead of the camera that chunk starts
    ldh a, [hPos + 1]
    cpl
    inc a
    ld l, a                     ; distance = chunk * 256 - position (low byte: -pos lo)
    ld a, d
    ld h, a
    ldh a, [hPos + 1]
    or a
    jr z, .exact
    dec h                       ; (borrow from the high byte)
.exact
    ldh a, [hPos + 2]
    ld e, a
    ld a, h
    sub e
    ld h, a                     ; hl = units from the camera to the boundary
    cp 8
    jr nc, .none                ; beyond the horizon
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ld h, HIGH(DistToLine)
    ld a, [hl]
    cp VISIBLE_D + 1
    jr c, .lineKnown
    ld a, VISIBLE_D             ; (already under the car: all of the road)
.lineKnown
    ld c, a                     ; the corner starts on line d: the d - 1 lines above are beyond it
    dec c
    ret

; hl -> the bend row for bend a (line d = 1 first)
BendRow:
    add a
    add LOW(BendPointers)
    ld l, a
    adc HIGH(BendPointers)
    sub l
    ld h, a
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    ret

; hl -> where in GroundLines to start to draw the last a lines
GroundEntry:
    ld l, a
    ld h, 0
    add hl, hl
    push de
    ld d, h
    ld e, l
    add hl, hl
    add hl, de                  ; 6 bytes a line
    pop de
    ld a, LOW(GroundLinesEnd)
    sub l
    ld l, a
    ld a, HIGH(GroundLinesEnd)
    sbc h
    ld h, a
    ret

; hl -> where in ShiftLines to start to move the last a lines
ShiftEntry:
    ld l, a
    ld h, 0
    push de
    ld d, h
    ld e, l
    add hl, hl
    add hl, de                  ; 3 bytes a line
    pop de
    ld a, LOW(ShiftLinesEnd)
    sub l
    ld l, a
    ld a, HIGH(ShiftLinesEnd)
    sbc h
    ld h, a
    ret

; SCX = shear + bend, one line after another down to the bottom of the ground: bc -> shear
; row, hl -> bend row, de -> SCX.  Entered part way in (GroundEntry) to do the last few.
GroundLines:
    REPT HUD_LINE - HORIZON
        ld a, [bc]
        add [hl]
        inc bc
        inc hl
        ld [de], a
        inc e
    ENDR
GroundLinesEnd:
    ret

; SCX += b, line after line: hl -> SCX.  Entered part way in (ShiftEntry).
ShiftLines:
    REPT HUD_LINE - HORIZON
        ld a, [hl]
        add b
        ld [hl+], a
    ENDR
ShiftLinesEnd:
    ret

; ---------------------------------------------------------------------------------------
; Which palette tables each distance band uses.  One band is looked at per frame (the eighth
; frame checks whether we are under a roof): pos + how far ahead the band is -> chunk ->
; scenery -> table.  The tunnel short cut is the underpass scenery everywhere.
UpdateScene:
    ldh a, [hFrame]
    and 7
    cp 7
    jr z, .roof
    ld c, a
    add a
    ld e, a
    ld d, 0
    ld hl, BandAhead
    add hl, de
    ldh a, [hPos + 1]
    add [hl]
    inc hl
    ldh a, [hPos + 2]
    adc [hl]
    call .sceneAt
    ld e, a                     ; table = ScenePages[scenery * 7 + band]
    add a
    add a
    add a
    sub e
    add c
    ld e, a
    ld hl, wScenePages
    add hl, de
    ld a, [hl]
    ld e, c
    ld hl, hBandBase
    add hl, de
    ld [hl], a
    ret
.roof
    ldh a, [hPos + 2]
    call .sceneAt
    dec a                       ; SCENE_UNDER is 1
    ld a, 0
    jr nz, .roofKnown
    inc a
.roofKnown
    ld hl, hRoof
    cp [hl]
    ret z
    ld [hl], a
    ld a, 3                     ; the sky lines need redoing
    ldh [hSkyStale], a
    ret
.sceneAt                        ; a = chunk -> a = its scenery (d = 0 on return)
    and CHUNK_MASK
    ld e, a
    ld d, 0
    ld hl, wSceneOfChunk
    add hl, de
    ldh a, [hTunnel]
    or a
    ld a, [hl]
    ret z
    ld a, SCENE_UNDER
    ret

DEF SCENE_CITY  EQU 0
DEF SCENE_UNDER EQU 1
DEF SCENE_WATER EQU 2
PalSetA:                        ; sceneries 0 city, 1 underpass, 2 water
    db PAL_BANK
    db HIGH(PalFar2), HIGH(PalFar1), HIGH(PalFar0), HIGH(PalNear3), HIGH(PalNear2), HIGH(PalNear1), HIGH(PalNear0)
    BAND_TABLES T
    BAND_TABLES W
PalSetB:                        ; sceneries 0 wheat, 1 underpass, 2 city
    db PAL_BANK2
    BAND_TABLES F
    BAND_TABLES 2T
    db HIGH(Pal2Far2), HIGH(Pal2Far1), HIGH(Pal2Far0), HIGH(Pal2Near3), HIGH(Pal2Near2), HIGH(Pal2Near1), HIGH(Pal2Near0)

; What goes in the sky's tile slots: for each skyline (and then the menu's lettering), the
; tiles for the $8000 block, the tiles for the $8800 block, its rows of the tilemap and its
; sky palettes, each as (address, length).
MACRO SKY_PIECE
    dw \1, \1.end - \1
ENDM
SkyTable:
    FOR N, 4
        SKY_PIECE Sky{d:N}Low
        SKY_PIECE Sky{d:N}High
        SKY_PIECE Sky{d:N}Map
        SKY_PIECE Sky{d:N}Bgp
    ENDR
    SKY_PIECE FontLow
    SKY_PIECE FontHigh
    dw 0, 0, 0, 0
BandAhead:                      ; how far ahead each band looks, far band first
    dw 2040, 2040, 900, 550, 400, 280, 200

; The player's car and shadow.  Leaning is free: the two halves sit a pixel apart.
PlayerSprites:
    ldh a, [hState]             ; over the line: the car speeds off up the road (Finale)
    cp STATE_FINISHED
    jr nz, .here
    ld a, [wGone + 1]
    ld b, a
    ld a, [wGone]
    or b
    jp nz, Departing
.here
    ld hl, wOam
    ldh a, [hLean]
    ld c, a
    ldh a, [hKick]              ; a boost: the car surges up the screen and settles back;
    srl a
    srl a
    ld b, a
    ldh a, [hBrake]             ; braking: it sits back a pixel
    sub b
    ldh [hYOff], a
    ld b, a
    ldh a, [hCarY]
    add b
    ld b, a
    ld a, HERO_TILE
    ldh [hCarTile], a
    ldh a, [hState]
    cp STATE_DEAD               ; destroyed: the explosion plays in a spare tile, then nothing
    jr nz, .alive
    ld a, BOOM_TILE
    ldh [hCarTile], a
    ldh a, [hBoom]
    cp BOOM_TIME
    jr c, .alive
    ld b, 0
.alive
    ld a, b
    bit 0, c                    ; leaning left: left half lower
    jr z, .leftY
    inc a
.leftY
    ld [hl+], a
    ld a, [wShake]              ; hit: the car jolts from side to side for a few frames
    or a
    jr z, .steady
    dec a
    ld [wShake], a
    and 2
    ld a, 2
    jr z, .jolt
    ld a, -2
.jolt
    ld d, a
    ldh a, [hCarX]
    add d
    jr .shaken
.steady
    ldh a, [hCarX]
.shaken
    ld e, a
    ld [hl+], a
    ldh a, [hCarTile]
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
    ldh a, [hCarTile]
    ld [hl+], a
    ld a, OAMF_XFLIP
    ld [hl+], a
    ldh a, [hShadowTile]
    ld c, a
    ldh a, [hState]             ; (a wreck casts no shadow)
    cp STATE_DEAD
    ldh a, [hYOff]
    jr z, .noShadow
    add CAR_Y + 30
    jr .shadowY
.noShadow
    xor a
.shadowY
    ld b, a
    ld [hl+], a
    ld a, e
    ld [hl+], a
    ld a, c
    ld [hl+], a
    xor a
    ld [hl+], a
    ld a, b
    ld [hl+], a
    ld a, d
    ld [hl+], a
    ld a, c
    ld [hl+], a
    ld [hl], OAMF_XFLIP

    ; --- the speedometer: a little car sliding along the status bar, further right the
    ; faster (2.25 pixels a unit of speed: standing still at the left, a boost at the right)
.speedo
    ld hl, wOam + SPEEDO_OAM
    ld a, [wPainted]            ; (not while the bar is lent to the place painted on the road)
    or a
    jr z, .speedoOn
    xor a
    ld [hl], a
    ret
.speedoOn
    ld a, HUD_LINE + 16 - 8     ; (an 8x16 sprite whose drawn rows are the bottom eight)
    ld [hl+], a
    ldh a, [hSpeed + 1]
    ld b, a
    add a
    srl b
    srl b
    add b
    add SPEEDO_X + 8
    ld [hl+], a
    ld a, CAR8_TILE
    ld [hl+], a
    xor a
    ld [hl], a
    ret

; ---------------------------------------------------------------------------------------
; Rivals.  Each keeps a distance ahead of the camera; from that comes the line it is on, its
; size, and (with that line's SCX) where the road is under it.
;
; To fit the frame, each rival is only moved and redrawn every other frame (half of them on
; even frames, half on odd), covering two frames of travel at a time.  Each owns three OAM
; entries, which simply keep their last position in between.  Its paint has to go into
; every frame's OBP1 lines though, so that is redone from a remembered line.  They are
; visited far to near so that where two share scanlines the nearer one's paint wins.
UpdateRivals:
    ; wOrder is kept far-to-near by comparing one neighbouring pair a frame: the order
    ; only changes when somebody overtakes
    ldh a, [hSortAt]
    inc a
    cp NUM_RIVALS - 1
    jr c, .sortAt
    xor a
.sortAt
    ldh [hSortAt], a
    ld e, a
    ld d, 0
    ld hl, wOrder
    add hl, de
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
    call nz, .restPaint
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

; .paint for a resting frame: with its lift off a ramp, if it is flying
.restPaint
    ld e, a
    ld a, [wFlying]
    or a
    ld a, e
    jr z, .paint
    push af
    call .hopOf
    pop af
    ; fall through

; .paint for a car wHop up in the air over line l: its lines, lifted (its size is the line's)
.paintLifted
    ld d, a
    ldh a, [hFadeLevel]
    or a
    ret nz
    ldh a, [hBuiltScx]
    inc a
    ld h, a
    ld a, [wHop]
    ld e, a
    ld a, l
    sub e
    ld e, a
    ld a, l
    ld l, e
    jr .paintSized

; a = paint, l = bottom line of the car: give its lines that OBP1
.paint
    ld d, a
    ldh a, [hFadeLevel]         ; (not while fading: see below)
    or a
    ret nz
    ldh a, [hBuiltScx]
    inc a
    ld h, a
    ld a, l                     ; a small car far up the road covers few lines
.paintSized
    cp HORIZON - 1 + RIVAL_D8
    jr c, .paint6
    cp HORIZON - 1 + RIVAL_D12
    jr c, .paint10
    cp HORIZON - 1 + RIVAL_D16
    jr c, .paint14
    ld a, d
    REPT 4
        ld [hl], a
        dec l
    ENDR
.paint14
    ld a, d
    REPT 4
        ld [hl], a
        dec l
    ENDR
.paint10
    ld a, d
    REPT 4
        ld [hl], a
        dec l
    ENDR
.paint6
    ld a, d
    REPT 6
        ld [hl], a
        dec l
    ENDR
    ret

; wHop = how high the rival in hRivalRec flies off a ramp, with l the line it is over: less
; the further up the road.  Keeps hl, bc.
.hopOf
    ld d, HIGH(wRivals)
    ldh a, [hRivalRec]
    add 4
    ld e, a
    ld a, [de]                  ; its stun byte
    bit 7, a                    ; (FLYING; on the road, as nearly always: quickly)
    jr nz, .flies
    xor a
    ld [wHop], a
    ret
.flies
    and ~FLYING
    add LOW(RivalHop)
    ld e, a
    ld a, HIGH(RivalHop)
    adc 0
    ld d, a
    ld a, [de]
    ld e, a
    ld a, l
    cp HORIZON - 1 + RIVAL_D16
    jr nc, .hopSet
    srl e
    cp HORIZON - 1 + RIVAL_D12
    jr nc, .hopSet
    srl e
    cp HORIZON - 1 + RIVAL_D8
    jr nc, .hopSet
    srl e
.hopSet
    ld a, e
    ld [wHop], a
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
    ld a, c                     ; record offset is rival * 8; its OAM is rival * 12 on
    srl a
    add c
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
    jp .moved
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
    ld d, a                     ; (where in its chunk it is)
    ldh a, [hPos + 2]
    adc b
    and CHUNK_MASK
    ld e, a
    ld a, b
    ldh [hRivalIdx + 1], a      ; (how far ahead it is, for the catch-up below)
    ld a, [hl+]
    ld c, a                     ; skill
    ld a, [hl]                  ; stun timer, or FLYING and its moves left in the air
    ld b, a
    or a
    jr z, .steady
    dec [hl]
    cp FLYING + 1
    jr nz, .awake
    ld [hl], 0                  ; (down)
    ld a, [wFlying]
    dec a
    ld [wFlying], a
    jr nz, .awake
    ld [wHop], a                ; (nobody up: no lift for anyone)
    jr .awake
.steady                         ; on the road and steady: at the ramp, on its side?  Up it goes
    ld a, [wRampChunk]
    cp e
    jr nz, .awake               ; (b = 0)
    ld a, d
    cp RAMP_WINDOW              ; (just past the start of the chunk, where the ramp sits)
    jr nc, .awake
    ldh a, [hRLane]
    and 3
    inc a
    ld d, a
    ld a, [wRampLanes]
.laneBit
    rrca
    dec d
    jr nz, .laneBit
    jr nc, .awake
    ld a, FLYING | RIVAL_AIR
    ld [hl], a
    ld b, a
    ld a, [wFlying]
    inc a
    ld [wFlying], a
    jr .awake
.awake
    ld d, 0
    ld hl, wSpeedProfile
    add hl, de
    ld a, [hl]
    add c
    jr nc, .skilled
    ld a, 255
.skilled
    ld c, a
    ldh a, [hPace]              ; the level's shift, up or down
    bit 7, a
    jr nz, .slower
    add c
    jr nc, .paced
    ld a, 255
    jr .paced
.slower
    add c
    jr c, .paced
    xor a
.paced
    ld c, a
    ldh a, [hRivalIdx + 1]      ; keep the field in touch: quicker behind us (much quicker
    bit 7, a                    ; when well behind),
    jr z, .notBehind
    cp -2
    ld a, c
    jr nc, .nearBehind
    add CATCH_UP_FAR
    jr nc, .banded
    ld a, 255
    jr .banded
.nearBehind
    add CATCH_UP
    jr nc, .banded
    ld a, 255
    jr .banded
.notBehind
    cp 4                        ; a little slower when well ahead
    ld a, c
    jr c, .banded
    sub EASE_OFF
.banded
    bit 7, b                    ; (FLYING: the ramp's boost)
    jr nz, .flying
    inc b
    dec b
    jr z, .fullPace
    srl a                       ; stunned: half pace
    jr .fullPace
.flying
    add RIVAL_JUMP_PACE
    jr nc, .fullPace
    ld a, 255
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
    add hl, hl
    add hl, hl                  ; (1/16 unit) -> 8.8 units per frame
    ld a, [wAdvance]            ; (how far we really went: the racing line)
    ld c, a
    ld a, [wAdvance + 1]
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
    cp VISIBLE_D + 1
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
    ASSERT X_LIMIT / 2 <= SHEAR_SPAN    ; (there must be a table for a car right at the rail)
    add SHEAR_SPAN
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

    ld a, [wFlying]             ; off a ramp, in the air: how high (wHop; 0 while nobody flies)
    or a
    call nz, .hopOf

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
    ld a, [wHop]
    or a
    ldh a, [hRPaint]
    jr nz, .liftIt
    call .paint
    jr .painted
.liftIt
    call .paintLifted
.painted

    ld a, [wHop]
    ld e, a
    ld a, c
    add HORIZON
    sub e
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
    ld e, a
    srl a
    add e
    add RIVAL_OAM
    ld e, a
    ld d, HIGH(wOam)
    ld a, [hl+]
    ld c, a                     ; sprites in this size
    cpl
    add 4                       ; 3 - that many entries left over
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
    ld a, [wHop]                ; in the air: its shadow (the 16 pixel car's last piece) is
    or a                        ; put back down on the road
    jr z, .landed
    ld c, a
    dec e
    dec e
    ld a, [de]
    dec e
    dec e
    cp SHADOW_TILE
    jr nz, .noShadow
    ld a, [de]
    add c
    ld [de], a
.noShadow
    ld a, e
    add 4
    ld e, a
.landed
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
    ld hl, wObjSlots
    ld a, LOW(wObjOam)
    call .slot
    ld hl, wObjSlots + 4
    ld a, LOW(wObjOam) + OBJ_SPRITES * 4
.slot                           ; work on one slot through the hObj* variables
    ldh [hObjOam], a
    push hl
    ld a, [hl+]
    ldh [hObjOn], a
    ld a, [hl+]
    ldh [hObjKind], a
    ld a, [hl+]
    ldh [hObjZ], a
    ld a, [hl]
    ldh [hObjZ + 1], a
    call .one
    pop hl
    ldh a, [hObjOn]
    ld [hl], a
    ret
.one
    ldh a, [hObjOam]
    ld l, a
    ld h, HIGH(wOam)
    xor a
    REPT OBJ_SPRITES            ; park its sprites (a y of 0 is off screen)
        ld [hl], a
        inc l
        inc l
        inc l
        inc l
    ENDR
    ldh a, [hObjOn]
    or a
    ret z
    ld a, [wPaintStep]          ; the place being painted on the road: nothing in front of it
    or a
    ret nz

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
    cp VISIBLE_D + 1
    jp nc, .gone
    ld c, a

    cp CAR_D                    ; reached the car: are we in its lane, and on the ground?
    jp c, .draw
    ldh a, [hObjOn]
    cp 1
    jp nz, .draw
    inc a
    ldh [hObjOn], a             ; only test once
    ldh a, [hAir]
    ld b, a
    ldh a, [hFadeStep]
    or b
    jp nz, .draw
    ldh a, [hObjKind]
    or a
    jp z, .mouth
    cp KIND_DIRT_L
    jp c, .barrier
    ld e, a                     ; a patch over half the road (odd kinds left, even right):
    rra                         ; are we on that half?
    ldh a, [hX + 1]
    jr nc, .patchRight
    cp $FE                      ; left half: x of -3 or less
    jp nc, .draw
    cp $80
    jp c, .draw
    jr .onPatch
.patchRight
    cp 3                        ; right half: x of 3 or more
    jp c, .draw
    cp $80
    jp nc, .draw
.onPatch
    ld a, e
    cp KIND_JUMP_L
    jp nc, .onRamp
    cp KIND_HEAL_L
    jr c, .notHeal
    ldh a, [hSpeed + 1]         ; a recharge patch: the slower we cross it, the more it gives
    add a                       ; (HEAL_SPEED is 2)
    ld e, a
    ld a, HEAL_BASE
    sub e
    ld e, a
    ldh a, [hHealth]
    add e
    cp HEALTH_MAX
    jr c, .healed
    ld a, HEALTH_MAX
.healed
    ldh [hHealth], a
    ld a, SFX_BOOST
    call Sfx
    jp .draw
.notHeal
    cp KIND_PAD_L
    jr nc, .onPad
    ld a, DIRT_TIME             ; dirt: dragged down, and somebody pounces
    ldh [hDirt], a
    ld a, SFX_SKID
    call Sfx
    push bc
    call RivalPounce
    pop bc
    jp .draw
.onPad
    ldh a, [hBoost]             ; a boost pad: a free burst, all of it within 12 pixels of
    or a                        ; the pad's middle, two thirds of it for its edge
    jp nz, .draw
    ld a, e
    rra
    ld a, 28                    ; (the middle of a pad: 28 pixels either side of the line)
    jr nc, .padRight
    ld a, -28
.padRight
    ld d, a
    ldh a, [hX + 1]
    sub d
    add 12
    cp 25
    ld a, DASH_TIME
    jr c, .padFull
    ld a, DASH_TIME * 2 / 3
.padFull
    ldh [hBoost], a
    ld a, SFX_BOOST
    call Sfx
    jp .draw
.onRamp                         ; a ramp (drawn as the tunnel mouth, in grey): only within
    ld a, e                     ; 18 pixels of its middle (28 either side of the line), as
    rra                         ; it looks; miss it and nothing happens
    ld a, 28
    jr nc, .rampRight
    ld a, -28
.rampRight
    ld d, a
    ldh a, [hX + 1]
    sub d
    add 18
    cp 37
    jp nc, .draw
    ldh a, [hVX]                ; up into the air.  Half the slide the car had carries on, with
    sra a                       ; no grip up there to stop it: come down off the edge and the
    ldh [hVX], a                ; car is gone, so go over it straight
    ld a, 1
    ldh [hAir], a
    ld a, LOW(JUMP_RAMP)
    ldh [hVZ], a
    ld a, HIGH(JUMP_RAMP)
    ldh [hVZ + 1], a
    ld a, DASH_TIME             ; and a full boost forward (with its surge and flash), which
    ldh [hBoost], a             ; it keeps through the air: no drag up there
    xor a
    ldh [hBoostSeen], a
    ld a, SFX_BOOST
    call Sfx
    jp .draw
.barrier
    dec a                       ; a barrier: are we in its lane?
    ld e, a
    ld d, 0
    ld hl, RivalLaneU
    add hl, de
    ldh a, [hX + 1]
    sub [hl]
    ld e, a                     ; which side of it we are
    add 13
    cp 27
    jr nc, .draw
    ld a, BARRIER_COST          ; yes: it hurts and knocks the car aside (but only dirt slows it)
    call Damage
    ld a, SFX_HIT
    call Sfx
    ld a, STEER_MAX
    bit 7, e
    jr z, .knocked
    ld a, -STEER_MAX
.knocked
    ldh [hVX], a
    push bc
    call RivalPounce
    pop bc
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
    cp KIND_DIRT_L
    jr c, .barrierLane
    rra
    jr c, .laneFound            ; left-hand patches are where the tunnel mouth goes
    ld a, [hl]                  ; right-hand ones: the same distance the other way
    cpl
    inc a
    jr .haveLane
.barrierLane
    dec a                       ; barriers sit in the rivals' lanes
    srl a
    jr nc, .evenLane
    set 7, l
.evenLane
    add HIGH(RivalLanes)
    ld h, a
.laneFound
    ld a, [hl]
.haveLane
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

    ; A patch lies on the road, so the player's car should be drawn over it.  But where two
    ; sprites overlap, the DMG shows the one with the smaller x, whatever their order.  So
    ; once a patch reaches the car's top row, its pieces are kept from winning (see .sprite).
    xor a
    ldh [hUnder], a
    ldh a, [hObjKind]
    cp KIND_DIRT_L
    jr c, .over
    ldh a, [hKick]              ; (a boost surges the car up the screen by kick / 4)
    srl a
    srl a
    ld e, a
    ldh a, [hObjY]
    add 16
    add e
    ld e, a
    ldh a, [hCarY]
    cp e
    jr nc, .over                ; the car's top row is still below the patch's bottom row
    ld a, 1
    ldh [hUnder], a
.over

    ; Dirt, boost pads and recharge patches are the same tiles: the OBP1 value on their lines
    ; decides whether the dirt shows or the arrows hidden in it do.
    xor a
    ldh [hObjAttr], a
    ldh a, [hObjKind]
    cp KIND_DIRT_L
    jr c, .noPaint
    ldh a, [hFadeLevel]
    or a
    jr nz, .noPaint
    ld a, OAMF_PAL1
    ldh [hObjAttr], a
    ldh a, [hBuiltScx]
    inc a
    ld h, a
    ld a, c
    add HORIZON - 1
    ld l, a
    ldh a, [hObjKind]
    cp KIND_PAD_L
    ld a, DIRT_OBP              ; dirt: the arrows hidden in it
    jr c, .flash
    ldh a, [hObjKind]           ; a ramp: black, white arrows
    cp KIND_JUMP_L
    ld a, RAMP_OBP
    jr nc, .flash
    ldh a, [hObjKind]           ; a boost pad's arrows flicker white and black; a recharge
    cp KIND_HEAL_L              ; patch pulses slowly between dark and light
    ldh a, [hFrame]
    jr c, .flicker
    and %00100000
    ld a, HEAL_OBP_A
    jr z, .flash
    ld a, HEAL_OBP_B
    jr .flash
.flicker
    and %00000100
    ld a, PAD_OBP_A
    jr z, .flash
    ld a, PAD_OBP_B
.flash
    REPT 18
        ld [hl], a
        dec l
    ENDR
.noPaint

    ldh a, [hObjKind]
    or a
    jr z, .mouthSizes
    cp KIND_DIRT_L
    jr c, .barrierSizes
    cp KIND_JUMP_L              ; a ramp: the tunnel mouth's shape, in grey (RAMP_OBP)
    jr nc, .mouthSizes
    ld hl, DirtSize1
    ld a, c
    cp MOUTH_D2
    jr c, .sized
    ld hl, DirtSize2
    cp MOUTH_D3
    jr c, .sized
    ld hl, DirtSize3
    ldh a, [hObjKind]           ; (a pad's nearest size has four pieces: whole arrows only)
    cp KIND_PAD_L
    jr c, .sized
    ld hl, PadSize3
    jr .sized
.barrierSizes
    ld hl, BarrierFar           ; a barrier: a dot far off, then a striped roadblock, bigger
    ld a, c                     ; close to
    cp MOUTH_D2
    jr c, .sized
    ld hl, BarrierSize2
    cp BARRIER_D3
    jr c, .sized
    ld hl, BarrierSize3
    jr .sized
.mouthSizes
    ld hl, MouthSize1
    ld a, c
    cp MOUTH_D2
    jr c, .sized
    ld hl, MouthSize2
.sized
    ld a, [hl+]
    ld c, a                     ; sprites in this size
    ldh a, [hObjOam]
    ld e, a
    ld d, HIGH(wOam)
.sprite
    ldh a, [hObjY]
    ld [de], a
    inc de
    ld a, [hl+]
    add b
    push bc
    ld b, a                     ; b = x
    ldh a, [hUnder]             ; Under the car, the whole patch moves onto the car's 8-pixel
    or a                        ; grid, by at most 4 pixels either way: each piece then has the
    jr z, .placed               ; same x as a half of the car (and the car, earlier in OAM,
    ldh a, [hCarX]              ; wins) or is clear of it.  All the pieces move alike, so the
    ld c, a                     ; patch, and a pad's arrows, stay whole.
    ld a, b
    sub c
    and 7                       ; how far the pieces are off the car's grid
    jr z, .placed
    cp 5
    jr c, .back                 ; 1-4: move them left by that much
    sub 8                       ; 5-7: move them right, to the next column of the grid
.back
    ld c, a
    ld a, b
    sub c
    ld b, a
.placed
    ld a, b
    pop bc
    ld [de], a                  ; x
    inc de
    ld a, [hl+]
    ld [de], a                  ; tile
    inc de
    ldh a, [hObjAttr]
    or [hl]
    inc hl
    ld [de], a                  ; flip, palette
    inc de
    dec c
    jr nz, .sprite
    ret
.gone
    xor a
    ldh [hObjOn], a
    ret

; The player has made a mistake (dirt, a barrier): the last of our rivals, if it is behind,
; turns up right on the player's tail on the clear side of the road, ready to go by.
RivalPounce:
    ld hl, wOrder + NUM_RIVALS - 1
    ld b, NUM_RIVALS
.scan
    ld a, [hl-]                 ; from the back of the field forward
    add a
    add a
    add a
    add 5
    ld e, a
    ld d, HIGH(wRivals)
    ld a, [de]
    bit 7, a                    ; (not one the other console is driving)
    jr z, .ours
    dec b
    jr nz, .scan
    ret
.ours
    ld h, d
    ld a, e
    sub 3
    ld l, a                     ; -> high byte of its distance
    bit 7, [hl]
    ret z                       ; our last car is not behind: nobody to send
    xor a
    ld [hl-], a
    ld [hl], BEHIND_Z
    inc l
    inc l
    inc l
    ld [hl+], a                 ; not stunned
    ldh a, [hX + 1]
    rla
    ld a, 0                     ; we are on the right: it takes the left lane
    jr nc, .lane
    ld a, 3
.lane
    ld [hl], a
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
    ld a, b                     ; the car's build: the cost in quarters (rounded up, so every
    cp HEALTH_MAX               ; knock costs something; and a wreck is a wreck)
    jr nc, .built
    ld a, [wArmor]
    ld c, a
    xor a
.armor
    add b
    dec c
    jr nz, .armor
    add 3
    srl a
    srl a
    ld b, a
.built
    ld a, 8                     ; it jolts the car (PlayerSprites)
    ld [wShake], a
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
    ld hl, wFeatures
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
    xor a                       ; jump plate: thrown into the air, straight (any sideways
    ldh [hVX], a                ; slide would otherwise carry on all the way to the landing)
    ld a, 1
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
    jr z, .black
    cp FEATURE_DARK
    jr nz, .notBlack
.black
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
DEF FEATURE_DARK  EQU 4         ; a black band that does nothing
; Sound effects on the noise channel (the music's drums take it back on their next hit).
DEF SFX_SKID  EQU 0
DEF SFX_HIT   EQU 2
DEF SFX_BOOST EQU 4
DEF SFX_BOOM  EQU 6
DEF SFX_ALARM EQU 8
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
    db $F7, $73                 ; wreck: long low roar
    db $B1, $01                 ; low energy: a sharp tick

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
    ld c, VISIBLE_D             ; or we are in the middle of it
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
    cp VISIBLE_D + 1
    ret nc                      ; it has all gone by
.haveFar
    ld c, VISIBLE_D
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
    cp VISIBLE_D + 1
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
    ldh a, [hLapFlash]
    or a
    jr z, .noFlash
    ld a, b
    xor %00001000
    ld b, a
.noFlash
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
    jr z, .blink
    or a
    jr nz, .place
    ldh a, [hPos + 2]           ; racing, in the last 24 chunks of the lap (the grid starts
    and CHUNK_MASK              ; everyone behind), and behind the place this lap asks for:
    cp 40                       ; it blinks
    jr c, .place
    push hl
    call RankNeeded
    pop hl
    ld b, a
    ldh a, [hRank]
    cp b
    jr c, .place
    jr z, .place
.blink
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
    ldh a, [hState]
    cp STATE_DEAD
    jr nc, .out                 ; (wrecked, or ranked out)
    jr .lapCount
.out
    ld a, HUD_O                 ; wrecked: OUT
    ld [hl+], a
    ld a, HUD_U
    ld [hl+], a
    ld a, HUD_T
    ld [hl+], a
    ld a, HUD_BLANK
    ld [hl+], a
    jr .bar
.lapCount
    ldh a, [hLapFlash]          ; just crossed the line: the lap count flashes
    or a
    jr z, .lapShown
    ld a, HUD_L                 ; "LAP n" for as long as the bar is flashing
    ld [hl+], a
    ld a, HUD_A
    ld [hl+], a
    ld a, HUD_P
    ld [hl+], a
    ldh a, [hLap]
    call .digit
    jr .bar
.lapShown
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
    jr .speedTrack
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
.speedTrack                     ; four tiles where the speedometer's car slides (PlayerSprites)
    ld a, HUD_BLANK
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
.health
    ldh a, [hHealth]
    ld c, a                     ; health left to show
    cp LOW_HEALTH               ; low: the bar blinks (on and off every 16 frames)
    jr nc, .shown
    ldh a, [hState]
    or a
    jr nz, .shown
    ldh a, [hFrame]
    and %00010000
    jr z, .shown
    ld c, 0
.shown
    ld b, 4                     ; four cells of 16: full, half (8 or more) or empty
.cell
    ld a, c
    cp 16
    jr c, .partial
    sub 16
    ld c, a
    ld a, HUD_FULL
    jr .put
.partial
    cp 8
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
;   5  rival distance bits 0-6  6  bits 7-13      7  its lane, then the level (3 bits; 0: no rivals)
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
    ldh a, [hTrackNo]
    add a
    add a
    or c
    ld c, a
    ldh a, [hGen]
    add a
    or c
    or $80
    ld [hl+], a
    ldh a, [hPos + 1]
    ld e, a
    ldh a, [hPos + 2]
    ld d, a
    ld a, [wGone]               ; (past the flag: where our car has sped on to, so that the
    add e                       ; other screen sees it go too, and not the camera stopping)
    ld e, a
    ld a, [wGone + 1]
    adc d
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
    ldh a, [hLevel]             ; with our level (0: no rivals), for the other side to follow
    add a
    add a
    or b
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
    ldh a, [hLinked]            ; the console that called chose the track: the other follows
    cp LINK_SLAVE
    jr nz, .sameTrack
    ld a, [wRemote]
    rrca
    rrca
    and 3
    ld b, a
    ldh a, [hTrackNo]
    cp b
    jr z, .sameTrackSlave
    ld a, b
    ldh [hTrackNo], a
    call LcdOff
    call LoadTrackData
    call StartSong
    ld a, LCDC_UPPER
    ldh [rLCDC], a
    ei
    jp InitRace
.sameTrackSlave                 ; ... and the rivals: how quick, or none
    ld a, [wRemote + 7]
    rrca
    rrca
    and 7
    cp LEVELS + 1
    jr nc, .sameTrack
    ld b, a
    ldh a, [hLevel]
    cp b
    jr z, .sameTrack
    ld a, b
    ldh [hLevel], a
    jp InitRace
.sameTrack
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
    ; one of their rivals: record 2 or 3 (they have none at level 0)
    ld a, [wRemote + 7]
    and %00011100
    jr nz, .theirRival
    pop de
    ld a, LOW(HIDDEN)           ; (any they had before are gone from our road too)
    ld [wRivals + 2 * 8 + 1], a
    ld [wRivals + 3 * 8 + 1], a
    ld a, HIGH(HIDDEN)
    ld [wRivals + 2 * 8 + 2], a
    ld [wRivals + 3 * 8 + 2], a
    ret
.theirRival
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

; The difficulty level (1..LEVELS, or 0 for no rivals) sets how many laps and how the
; rivals' pace is shifted.
SetLevel:
    ldh a, [hLevel]
    ld e, a
    ld d, 0
    ld hl, LevelPace
    add hl, de
    ld a, [hl]
    ldh [hPace], a
    ld a, e
    cp 4
    ld a, 3
    jr c, .laps
    ld a, 5
.laps
    ldh [hLaps], a
    ret
LevelPace:                      ; added to every rival's pace (1/16 unit per frame), signed
    db 0, -16, -7, 0, 4, 8      ; (level 0 has nobody to pace)

; Put everything back on the grid.  Keeps the mode and the level.
InitRace:
    ld a, [wPainted]            ; the last race's place still painted on the road: the sky and
    or a                        ; the road put back first (the screen off a moment)
    jr z, .unpainted
    ldh a, [rLCDC]
    add a
    jr nc, .screenOff
    call LcdOff
    call Unpaint
    ld a, LCDC_UPPER
    ldh [rLCDC], a
    ei
    jr .unpainted
.screenOff
    call Unpaint
.unpainted
    xor a
    ld [wHop], a
    ld [wFlying], a
    ld [wGone], a
    ld [wGone + 1], a
    ld [wGoneV], a
    ld [wPaintStep], a
    ld [wPaintCount], a
    ldh [hPos], a
    ldh [hPos + 1], a
    ldh [hPos + 2], a
    ldh [hPosCoarse], a
    ldh [hSpeed], a
    ldh [hSpeed + 1], a
    ldh [hChunk], a
    ldh [hState], a
    ld [wObjSlots], a
    ld [wObjSlots + 4], a
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
    ld a, TILE_RESTORE          ; undo any explosion drawn over the spare tile
    ldh [hTileJob], a
    ld hl, hBandBase            ; city everywhere until UpdateScene says otherwise
    ld de, wScenePages
    ld b, 7
.bands
    ld a, [de]
    ld [hl+], a
    inc de
    dec b
    jr nz, .bands
    xor a
    ldh [hRoof], a
    ldh [hFlash], a
    ldh [hKick], a
    ldh [hBrake], a
    ldh [hBoostSeen], a
    ldh [hEngineMode], a
    ldh [hBoom], a
    ldh [hRailCool], a
    ldh [hLapFlash], a
    ldh [hDirt], a
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
    call SetLevel

    ld de, RivalStart
    ldh a, [hLevel]             ; no rivals: nobody on the grid
    or a
    jr nz, .someRivals
    ld de, RivalsAlone
.someRivals
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
    ldh a, [hLevel]             ; linked with no rivals: our two are never placed either,
    or a                        ; and only the two players race
    jr nz, .ordered
    ld de, RivalsAlone
    ld hl, wRivals
    ld bc, 2 * 8
    call Copy
.ordered
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
    bit 0, a                    ; A brakes, as Down does
    jr z, .noBrakeButton
    set 7, a
.noBrakeButton
    ld b, a

    ; --- Select and Start together: back to the menu
    and PADF_START | PADF_SELECT
    cp PADF_START | PADF_SELECT
    jp z, Menu
    ; --- Select (outside practice): engine note on / off.  Once the race is over: the menu
    ldh a, [hPractice]
    or a
    jr nz, .engineSet
    ldh a, [hNewKeys]
    and PADF_SELECT
    jr z, .engineSet
    ldh a, [hState]
    or a
    jp nz, Menu
    ldh a, [hEngine]
    xor 1
    ldh [hEngine], a
    push bc
    call EngineApply
    pop bc
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
    ldh a, [hRank]              ; won it: the next race starts a level up (it can be put back)
    dec a
    jr nz, .again
    ldh a, [hLevel]
    or a                        ; (not from no rivals at all)
    jr z, .again
    cp LEVELS
    jr nc, .again
    inc a
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
    ldh a, [hRailCool]
    or a
    jr z, .railCool
    dec a
    ldh [hRailCool], a
.railCool
    ldh a, [hKick]
    or a
    jr z, .kicked
    dec a
    ldh [hKick], a
.kicked
    ldh a, [hFlash]
    or a
    jr z, .flashed
    dec a
    ldh [hFlash], a
    ld a, 3
    ldh [hSkyStale], a
.flashed
    ldh a, [hLapFlash]
    or a
    jr z, .lapFlash
    dec a
    ldh [hLapFlash], a
.lapFlash
    ldh a, [hDirt]              ; in the dirt: dragged down toward a crawl
    or a
    jr z, .clean
    dec a
    ldh [hDirt], a
    ld a, h
    cp DIRT_SPEED
    jr c, .clean
    ld de, -DIRT_DRAG
    add hl, de
.clean
    ldh a, [hState]             ; a wreck: count its explosion along
    cp STATE_DEAD
    jr nz, .noBoom
    ldh a, [hBoom]
    cp BOOM_TIME + 4
    jr nc, .noBoom
    inc a
    ldh [hBoom], a
    cp 1
    jr nz, .boomTick
    ld a, SFX_BOOM
    call Sfx
.boomTick
    ldh a, [hBoom]
    and 3
    jr nz, .noBoom
    ld a, TILE_BOOM             ; a new frame of it every fourth frame
    ldh [hTileJob], a
.noBoom
    ldh a, [hState]
    cp STATE_DEAD
    jp z, .wreck                ; a wreck just stops
    or a
    jp nz, .coast               ; past the flag: roll to a halt

    ldh a, [hCount]             ; the countdown
    or a
    jr z, .go
    dec a
    ldh [hCount], a
    ld hl, 0
    jp .speedSet
.go
    ldh a, [hHealth]            ; low on health: an alarm ticks, twice a second
    cp LOW_HEALTH
    jr nc, .noAlarm
    ldh a, [hFrame]
    and 31
    jr nz, .noAlarm
    ld a, SFX_ALARM
    call Sfx
.noAlarm
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
    ld c, a
    ldh a, [hBoostSeen]
    cp c
    jr nc, .noSurge
    ld a, 8                     ; a boost has just started (fired, or from a pad): flash, surge
    ldh [hFlash], a
    ld a, 15
    ldh [hKick], a
.noSurge
    ld a, c
    ldh [hBoostSeen], a
    or a
    jr z, .noBoost
    bit 7, b                    ; braking cuts a boost short
    jr nz, .cutBoost
    dec a
    ldh [hBoost], a
    ldh [hBoostSeen], a
    ld de, $0040                ; boosting: shove toward the higher limit
    add hl, de
    ld a, h
    cp BOOST_MAX
    jr c, .speedSet
    ld hl, BOOST_MAX << 8
    jr .speedSet
.cutBoost
    xor a
    ldh [hBoost], a
    ldh [hBoostSeen], a
.noBoost
    ld a, [wTop]                ; over the normal limit (after a boost): bleed back down
    ld c, a
    ld a, h
    cp c
    jr c, .underLimit
    ld de, -$0010
    add hl, de
    bit 7, b                    ; (with the brake on top)
    jr nz, .braking
    jr .speedSet
.underLimit
    bit 1, b                    ; PADF_B
    jr z, .coast
    ; the throttle: strong from rest, fading to nothing at top speed (the car's own curve)
    ld a, [wTop]
    sub h                       ; "gears" below the limit
    ld c, a
    ld a, [wGearK]
    ld d, a
    ld a, [wGrunt]
.gear
    add c
    dec d
    jr nz, .gear
    ld e, a
    ld d, 0
    add hl, de
    ld a, [wTop]
    ld c, a
    ld a, h
    cp c
    jr c, .throttled
    ld h, c
    ld l, 0
.throttled
    bit 7, b                    ; throttle and brake together: the brake wins a little
    jr z, .speedSet
.braking                        ; the brakes take the edge off: they will not stop the car
    ld a, h
    cp BRAKE_FLOOR
    jr c, .speedSet
    ld de, -BRAKE
    ld a, b                     ; steering too: a skid turn, which scrubs speed itself
    and PADF_LEFT | PADF_RIGHT  ; (SKID_COST): the brake bites half as hard, so a drift
    jr z, .fullBrake            ; through a corner keeps more of its speed
    ld de, -(BRAKE / 2)
.fullBrake
    add hl, de
    ld a, h
    cp BRAKE_FLOOR
    jr nc, .speedSet
    ld hl, BRAKE_FLOOR << 8
    jr .speedSet
.wreck
    ld de, -$0020
    jr .slow
.coast
    ldh a, [hAir]               ; in the air: no drag, no brakes
    or a
    jr nz, .speedSet
    ldh a, [hState]             ; past the flag (or out): the camera comes to a stop, while
    or a                        ; your car speeds on (Finale)
    jr z, .rolling
    ld de, -FINISH_BRAKE
    jr .slow
.rolling
    bit 7, b                    ; PADF_DOWN
    jr nz, .braking
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

    ldh a, [hEngine]            ; the engine note: it climbs with speed, rides above it on the
    or a                        ; gas while there is speed to gain and drops when you lift,
    jp z, .noNote               ; with a rasp; louder on the gas, fuller still on a boost
    ld c, REV_LIFT
    ldh a, [hAir]               ; (in the air: nothing to push against, the note falls away)
    or a
    jr nz, .revAim
    bit 1, b                    ; PADF_B
    jr z, .revAim
    ld c, REV_GAS
    ld a, [wTop]
    dec a
    ld e, a
    ld a, h
    cp e                        ; (the speed only creeps up to the top: within a unit is there)
    jr c, .revAim
    ld c, REV_TOP
.revAim
    ld a, [wRev]                ; (eased there, 3 a frame)
    cp c
    jr z, .revHeld
    ld e, a
    sub c
    bit 7, a
    ld a, e
    jr nz, .revUp
    sub 3
    jr .revSet
.revUp
    add 3
.revSet
    ld [wRev], a
.revHeld
    ld d, h                     ; frequency: base + speed / 4 + the rev (+ the rasp)
    ld e, l
    srl d
    rr e
    srl d
    rr e
    ld a, [wRev]
    add e
    ld e, a
    ld a, d
    adc 0
    ld d, a
    ld a, [wRev]
    bit 7, a
    jr z, .revPositive
    dec d
.revPositive
    ldh a, [hFrame]             ; the rasp: a little higher every other pair of frames
    and 2
    jr z, .smooth
    ld a, e
    add RASP
    ld e, a
    jr nc, .smooth
    inc d
.smooth
    ld a, e
    add LOW(ENGINE_BASE)
    ldh [rAUD2LOW], a
    ld a, d
    adc HIGH(ENGINE_BASE)
    ld d, a
    ldh [rAUD2HIGH], a
    ld c, 3                     ; the voice: 0 coasting, 1 on the gas, 2 boosting, 3 flying
    ldh a, [hAir]
    or a
    jr nz, .voiceSet
    ld c, 0
    bit 1, b
    jr z, .gasVoice
    inc c
.gasVoice
    ldh a, [hBoost]
    or a
    jr z, .voiceSet
    ld c, 2
.voiceSet
    ldh a, [hEngineMode]
    cp c
    jr z, .noNote
    ld a, c
    ldh [hEngineMode], a
    or a
    ld a, %01000000             ; coasting: thin and quiet
    ld e, $40
    jr z, .voice
    dec c
    ld e, $60                   ; on the gas: louder
    jr z, .voice
    dec c
    ld a, %10000000             ; a boost: fuller and louder still
    ld e, $90
    jr z, .voice
    xor a                       ; in the air: no roar, a thin whisper (thrust on nothing)
    ld e, $20
.voice
    ldh [rAUD2LEN], a
    ld a, e
    ldh [rAUD2ENV], a
    ld a, d
    or $80                      ; (a new envelope takes effect on a restart)
    ldh [rAUD2HIGH], a
.noNote
    ; --- the noise channel: a boost howls upward, the brakes scrub lower as the car slows
    xor a
    ldh [hBrake], a
    ldh a, [hAir]               ; (not in the air, though a ramp gives a boost)
    or a
    jr nz, .quiet
    ldh a, [hBoost]
    or a
    jr z, .noHowl
    ld c, a
    ldh a, [hFrame]
    and 3
    jr nz, .quiet
    ld a, c
    and %01110000
    or 3
    ld c, a
    ld a, $62
    jr .noise
.noHowl
    bit 7, b
    jr z, .quiet
    ld a, h
    cp 2
    jr c, .quiet
    ld a, 1
    ldh [hBrake], a
    ldh a, [hSkid]
    or a
    jr nz, .quiet
    ldh a, [hFrame]
    and 7
    jr nz, .quiet
    ld a, 9
    sub h
    and 7
    swap a
    or 5
    ld c, a
    ld a, $31
.noise
    ldh [rAUD4ENV], a
    ld a, c
    ldh [rAUD4POLY], a
    xor a
    ldh [rAUD4LEN], a
    ld a, $80
    ldh [rAUD4GO], a
.quiet

    ; --- the racing line: in a bend the inside is the shorter way round, so the car covers
    ; more of the course there and less on the outside: bend * speed * x / 4096 a frame,
    ; 7% more on the usual inside line of a right angle, a third at the very inside of a
    ; hairpin.  (Holding the inside at speed means fighting the bend's push: that is the
    ; trade.)  The rivals are moved against this, not against the speed.
    push hl
    ld a, [wTurn]
    ld e, a
    ld a, [wTurn + 1]
    ld d, a
    ldh a, [hX + 1]
    call MulSigned              ; hl = turn * x
    REPT 4
        sra h
        rr l
    ENDR
    ld d, h
    ld e, l
    pop hl
    add hl, de
    ld a, l
    ld [wAdvance], a
    ld a, h
    ld [wAdvance + 1], a
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
    ld [wObjSlots], a
    ld [wObjSlots + 4], a
    ldh a, [hFadeTunnel]
    ldh [hTunnel], a
    or a
    jr z, .fadeLevel
    ldh a, [hPos + 2]           ; the tunnel is a short cut: we come out further on,
    ld hl, wTrkSkip
    add [hl]
    ldh [hPos + 2], a
    ld b, [hl]
    ld hl, wRivals + 2          ; which puts every rival that much less far ahead
    ld c, NUM_RIVALS
.shift
    ld a, [hl]
    sub b
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
    jp z, .sameChunk
    ld a, c
    ldh [hChunk], a
    ldh a, [hPractice]
    ld e, a
    ldh a, [hState]
    or e
    jr nz, .sameChunk           ; nothing counts in practice or once the race is over
    ld a, c
    or a
    jr nz, .spawn
    ldh a, [hLaps]              ; across the line
    ld e, a
    ldh a, [hLap]
    cp e
    jr c, .nextLap
    ld a, STATE_FINISHED
    ldh [hState], a
    jr .sameChunk
.nextLap
    push bc                     ; was this lap's place good enough?  (F-Zero's rank-out)
    call RankNeeded
    pop bc
    ld e, a
    ldh a, [hRank]
    dec a
    cp e
    jr c, .rankOk
    ld a, STATE_OUT
    ldh [hState], a
    ld a, SFX_BOOM
    call Sfx
    jp .sameChunk
.rankOk
    ldh a, [hLap]
    inc a
    ldh [hLap], a
    ld a, 120                   ; make something of it: the lap number flashes, with a sound
    ldh [hLapFlash], a
    ld a, SFX_BOOST
    call Sfx
    ldh a, [hBoosts]            ; a boost for every lap done
    cp BOOSTS_MAX
    jr nc, .lapBoosted
    inc a
    ldh [hBoosts], a
.lapBoosted
    xor a                       ; (things appear on crossing the line too)
.spawn
    ld e, a                     ; does something appear on the road ahead here?
    ld d, 0
    ld hl, wChunkSpawn
    add hl, de
    ld a, [hl]
    or a
    jr z, .notMouth
    ld e, a
    ld hl, wObjSlots            ; into whichever slot is free
    ld a, [hl]
    or a
    jr z, .slotFree
    ld hl, wObjSlots + 4
    ld a, [hl]
    or a
    jr nz, .notMouth
.slotFree
    ld a, 1
    ld [hl+], a
    ld a, e
    dec a
    ld [hl+], a                 ; 0 the tunnel mouth, 1-4 a barrier in that lane, 5-6 dirt
    ldh a, [hPos + 1]
    add LOW(SPAWN_DIST)
    ld [hl+], a
    ldh a, [hPos + 2]
    adc HIGH(SPAWN_DIST)
    ld [hl], a
    jr .sameChunk
.notMouth
    ld hl, wTrkExit
    ldh a, [hChunk]
    cp [hl]
    jr nz, .sameChunk
    ldh a, [hTunnel]
    or a
    jr z, .sameChunk
    xor a
    call StartFade              ; back up to the surface
.sameChunk



    ; --- where should the bend be heading?
    ldh a, [hPractice]
    or a
    jr nz, .byHand
    ld hl, wTrackBend
    ldh a, [hTunnel]
    or a
    jr z, .surface
    ld hl, wTunnelBend
.surface
    ldh a, [hPos + 1]           ; the chunk under the car (it is PLAYER_Z ahead of the camera)
    add PLAYER_Z
    ldh a, [hPos + 2]
    adc 0
    and CHUNK_MASK
    ld e, a
    ld d, 0
    add hl, de
    ld a, [hl]
    ld e, a
    and $7F
    ldh [hTarget], a
    ld a, e                     ; the top bit marks a corner that is tighter than it looks
    rlca
    and 1
    ld [wTight], a
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

    ; --- corners are short and seen coming: the car feels each one the moment it is in it
    ldh a, [hTarget]
    ldh [hBend], a

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
    ld a, l                     ; (kept for next frame's distance: the racing line)
    ld [wTurn], a
    ld a, h
    ld [wTurn + 1], a
    ld d, h
    ld e, l

    ; the skyline swings round by that much: a quarter of its width for every 90 degrees
    push hl
    add hl, hl
    add hl, hl
    ld d, h
    ld e, l
    pop hl
    ldh a, [hSkyX]
    add e
    ldh [hSkyX], a
    ldh a, [hSkyX + 1]
    adc d
    ldh [hSkyX + 1], a

    ; --- the push on the car in a bend goes with the SQUARE of the speed, so a corner that
    ; is easy at 5 is a wall at 8: brake for it, or skid-turn into it
    ldh a, [hSpeed]
    rlca
    rlca
    and 3
    ld e, a
    ldh a, [hSpeed + 1]
    add a
    add a
    or e
    ld e, a                     ; speed in quarter units
    ld d, 0
    ld a, [wPush]               ; (the car's own table)
    ld l, a
    ld a, [wPush + 1]
    ld h, a
    add hl, de
    ld c, [hl]
    ldh a, [hBend]
    sub BEND_LEVELS
    ldh [hTurnSign], a
    bit 7, a
    jr z, .bendAbs
    cpl
    inc a
.bendAbs
    ld hl, 0                    ; hl = |bend| * scale
    ld e, c
    ld d, h
    or a
    jr z, .pushReady
.pushMul
    srl a
    jr nc, .pushSkip
    add hl, de
.pushSkip
    sla e
    rl d
    or a
    jr nz, .pushMul
.pushReady
    srl h
    rr l
    ldh a, [hTurnSign]
    bit 7, a
    jr z, .pushSigned
    xor a
    sub l
    ld l, a
    sbc a
    sub h
    ld h, a
.pushSigned
    ld a, [wTight]              ; a "special tight" corner: half as hard again
    or a
    jr z, .notTight
    ld d, h
    ld e, l
    sra d
    rr e
    add hl, de
.notTight
    bit 1, b                    ; off the gas the car grips: three quarters of the push.  Lift
    jr nz, .onGas               ; for a corner and it holds the line, as in F-Zero
    ld d, h
    ld e, l
    sra d
    rr e
    sra d
    rr e
    ld a, l
    sub e
    ld l, a
    ld a, h
    sbc d
    ld h, a
.onGas
    ld d, h
    ld e, l

    ; --- the crosswind of this chunk, gusting: it pushes the car too (once it is moving)
    ldh a, [hSpeed + 1]
    or a
    jr z, .calm
    ldh a, [hChunk]
    add LOW(wWind)
    ld l, a
    ld h, HIGH(wWind)
    ld a, [hl]
    or a
    jr z, .calm
    ld l, a
    add a
    sbc a
    ld h, a
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                  ; 1/16 pixel -> 8.8
    ldh a, [hFrame]
    bit 6, a
    jr z, .steady
    push de                     ; a gust: half as much again for a second, every other second
    ld d, h
    ld e, l
    sra d
    rr e
    add hl, de
    pop de
    ldh a, [hFrame]
    and 15
    jr nz, .steady
    ld a, SFX_SKID              ; (and you can hear it)
    call Sfx
.steady
    ld a, e                     ; (the push is taken off x, so the wind is taken off the push)
    sub l
    ld e, a
    ld a, d
    sbc h
    ld d, a
.calm

    ; --- steering: ease sideways speed toward what the d-pad asks for
    ldh a, [hState]
    cp STATE_DEAD
    jr nz, .notWreck
    xor a                       ; a wreck goes nowhere
    ldh [hVX], a
    ld b, a
    ld d, a
    ld e, a
    jp .vxDone
.notWreck
    ldh a, [hAir]
    or a
    jr z, .onTheRoad
    ldh a, [hVX]                ; no grip in the air: keep drifting the way we were
    ld b, a
    jp .vxDone
.onTheRoad
    ldh a, [hState]             ; the race is over: the car steers itself to the middle of the
    or a                        ; road and coasts to a halt there (rather than drift from
    jr z, .grounded             ; rail to rail with nobody steering)
    ldh a, [hX + 1]
    ld b, 0
    add 4
    cp 9
    jr c, .grounded             ; within 4 pixels: straight on
    sub 4
    bit 7, a
    ld b, PADF_LEFT
    jr z, .grounded
    ld b, PADF_RIGHT
.grounded
    ; braking while steering at speed is a skid turn: far more steering, less speed
    xor a
    ldh [hSkid], a
    ld a, [wSteer]
    ld h, a
    ldh a, [hSpeed + 1]         ; (a hovercar cannot shuffle sideways at a standstill)
    or a
    jr nz, .moving
    ld h, a
.moving
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
    ld l, a                     ; (de is the bend's push: kept for below)
    ld a, [wSlide]              ; just landed from a ramp: a quarter of the grip
    or a
    jr z, .grip
    dec a
    ld [wSlide], a
    bit 7, l
    jr z, .slideUp
    dec b
    jr .vxSet
.slideUp
    inc b
    jr .vxSet
.grip
    ld a, l
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
    ldh a, [hRailCool]          ; (a second touch straight after the first does not hurt again)
    or a
    jr nz, .railHurt
    ld a, RAIL_COST             ; it costs health, never speed: only dirt slows the car
    call Damage
    ld a, SFX_HIT
    call Sfx
    ld a, RAIL_COOL
    ldh [hRailCool], a
.railHurt
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

    ; --- in the air: the shadow stays on the road
    ldh a, [hAir]
    or a
    jr nz, .inAir
    jr .onGround                ; (only jump plates and barriers put the car in the air)
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
    ld a, LAND_SLIDE            ; still sliding the way it was: steering takes hold slowly
    ld [wSlide], a
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
DEF STATE_OUT      EQU 3        ; ranked out: not in the place the lap asked for (it coasts)

DEF MOUTH    EQU 1              ; what a track's "things" table can name (tools/gen_tracks.py)
DEF BARRIER  EQU 2
DEF DIRT_L   EQU 6
DEF DIRT_R   EQU 7
DEF PAD_L    EQU 8
DEF PAD_R    EQU 9
DEF KIND_DIRT_L EQU DIRT_L - 1  ; (hObjKind is the table value less one)
DEF KIND_PAD_L  EQU PAD_L - 1
DEF HEAL_L   EQU 10             ; a recharge patch over the left half
DEF HEAL_R   EQU 11
DEF KIND_HEAL_L EQU HEAL_L - 1
DEF JUMP_L   EQU 12             ; a jump ramp over the left half
DEF JUMP_R   EQU 13
DEF KIND_JUMP_L EQU JUMP_L - 1

FadeLevels:                     ; darkness for each eighth of a fade
    db 1, 2, 3, 3, 3, 3, 2, 1

SpriteFade:                     ; OBP0 at each darkness
    db %11100000, %11110100, %11111000, %11111100

; Sprites for each size of tunnel mouth: count, then (x offset from the centre, tile, flip).
BarrierFar:
    db 1
    db 4, CAR4_TILE, 0
DirtSize1:
    db 2
    db 0, DIRT_TILE, 0
    db 8, DIRT_TILE, OAMF_XFLIP
DirtSize2:
    db 4
    db -8, DIRT_TILE + 2, 0
    db 0, DIRT_TILE + 2, OAMF_XFLIP
    db 8, DIRT_TILE + 2, 0
    db 16, DIRT_TILE + 2, OAMF_XFLIP
DirtSize3:                      ; (the ends one size smaller, so the patch tapers)
    db 5
    db -12, DIRT_TILE + 2, 0
    db -4, DIRT_TILE + 4, OAMF_XFLIP
    db 4, DIRT_TILE + 4, 0
    db 12, DIRT_TILE + 4, OAMF_XFLIP
    db 20, DIRT_TILE + 2, 0
PadSize3:                       ; a piece and its mirror image make each arrow
    db 4
    db -8, DIRT_TILE + 4, 0
    db 0, DIRT_TILE + 4, OAMF_XFLIP
    db 8, DIRT_TILE + 4, 0
    db 16, DIRT_TILE + 4, OAMF_XFLIP
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
BarrierSize2:                   ; the roadblock, 16 wide (gen_gfx.py barrier_image)
    db 2
    db 0, MOUTH_TILE + 6, 0
    db 8, MOUTH_TILE + 6, OAMF_XFLIP
BarrierSize3:                   ; ...and 32 wide, close to
    db 4
    db -8, MOUTH_TILE + 8, 0
    db 0, MOUTH_TILE + 10, 0
    db 8, MOUTH_TILE + 10, OAMF_XFLIP
    db 16, MOUTH_TILE + 8, OAMF_XFLIP

; Sprites for each size of rival: count, then (y offset, x offset, tile, attributes).
DEF RP EQU OAMF_PAL1
DEF RPX EQU OAMF_PAL1 | OAMF_XFLIP
RivalSize16:                    ; (one piece of shadow under the middle, to keep it to three)
    db 3
    db -2, 0, CAR_TILE, RP
    db -2, 8, CAR_TILE, RPX
    db 13, 4, SHADOW_TILE, RP
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
    RIVAL PLAYER_Z + 70, 22, 0, PAINT_A
    RIVAL PLAYER_Z + 110, 13, 3, PAINT_B
    GHOST PAINT_C, REMOTE
    GHOST PAINT_D, REMOTE
    GHOST PAINT_P, REMOTE | FREE_X
    GHOST PAINT_P, REMOTE
    GHOST PAINT_P, REMOTE
RivalsSlave:
    RIVAL PLAYER_Z + 150, 22, 1, PAINT_C
    RIVAL PLAYER_Z + 190, 13, 2, PAINT_D
    GHOST PAINT_A, REMOTE
    GHOST PAINT_B, REMOTE
    GHOST PAINT_P, REMOTE | FREE_X
    GHOST PAINT_P, REMOTE
    GHOST PAINT_P, REMOTE
RivalsAlone:
    REPT NUM_RIVALS
        GHOST PAINT_P, REMOTE
    ENDR

RivalStart:                     ; the grid: everyone starts ahead of the player, best at the front
    RIVAL PLAYER_Z + 40, 8, 1, %11100100   ; grey, black trim
    RIVAL PLAYER_Z + 80, 11, 2, %00101100   ; black, white trim
    RIVAL PLAYER_Z + 120, 14, 0, %01101100  ; black, grey trim
    RIVAL PLAYER_Z + 160, 17, 3, %01100000  ; white, grey trim
    RIVAL PLAYER_Z + 200, 20, 1, %00100100  ; grey, white trim
    RIVAL PLAYER_Z + 240, 23, 2, %11101000  ; dark, black trim: the two to beat
    RIVAL PLAYER_Z + 280, 26, 0, %00101000  ; dark, white trim

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
; Play the chosen track's song (unless it already is).
StartSong:
    ldh a, [hTrackNo]
    ld hl, wSongNow
    cp [hl]
    ret z
    ld [hl], a
    ld e, a
    add a
    add e
    ld e, a
    ld d, 0
    ld hl, Songs
    add hl, de
    ld a, [hl+]
    ld [wSongBank], a
    ld [rROMB0], a
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    jp hUGE_init

SongBank:
    ld a, [wSongBank]
    ld [rROMB0], a
    ret

MACRO SONG
    db BANK(\1)
    dw \1
ENDM
Songs:
    SONG race_song
    SONG ocean_song
    SONG wind_song
    SONG port_song

; hl = BGP page of a buffer (SCX and OBP1 pages follow it)
InitLines:
    ld de, wSkyBgp
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
    dec h                       ; the status bar's lines keep one palette for good
    ld l, HUD_LINE
    ld a, HUD_BGP
    REPT 8
        ld [hl+], a
    ENDR
    inc h
    ld l, 0
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
; ---------------------------------------------------------------------------------------
; Past the flag.  Your car speeds off up the road (Departing draws it) while the camera comes
; to a stop and the rivals cruise past; then your place (or OUT) is painted onto the road
; ahead, in perspective, for them to drive through, the skyline left as it is.  The letters
; go into the status bar's tiles (the bar is blank meanwhile) and into the patch's own ground
; tiles that are seen nowhere else; the patch of tilemap is pointed at them (gen_gfx.py
; result_scripts).  A piece a frame: staged here into wPaintBuf, copied by VBlank.  Unpaint
; puts it all back for the next race.
Finale:
    ldh a, [hState]
    cp STATE_FINISHED
    jr z, .finished
    cp STATE_OUT
    ret nz
    jr .paintOnceStopped
.finished
    ld a, [wGoneV]              ; your car: off at its speed at the flag (6 at least) ...
    or a
    jr nz, .going
    ldh a, [hSpeed + 1]
    cp 6
    jr nc, .setOff
    ld a, 6
.setOff
    ld [wGoneV], a
.going
    ld a, [wGone + 1]           ; (out of sight past 2048)
    cp 8
    jr nc, .paintOnceStopped
    ldh a, [hFrame]             ; ... and quicker every 8 frames, up to 12
    and 7
    jr nz, .pace
    ld a, [wGoneV]
    cp 12
    jr nc, .pace
    inc a
    ld [wGoneV], a
.pace
    ldh a, [hSpeed + 1]         ; on up the road, from the camera that is coming to a stop
    ld b, a
    ld a, [wGoneV]
    sub b
    jr c, .paintOnceStopped
    ld b, a
    ld a, [wGone]
    add b
    ld [wGone], a
    ld a, [wGone + 1]
    adc 0
    ld [wGone + 1], a
.paintOnceStopped
    ld a, [wPaintStep]
    cp PAINT_DONE
    ret z
    or a
    jr nz, .painting
    ldh a, [hSpeed + 1]         ; the camera still rolling: the road is not still yet
    ld b, a
    ldh a, [hSpeed]
    or b
    ret nz
    ldh a, [hState]             ; the words: the place, or OUT
    cp STATE_OUT
    ld a, RESULT_TEXTS - 1
    jr z, .words
    ldh a, [hRank]
    dec a
.words
    ld [wPaintText], a
    add a                       ; its script
    ld l, a
    ld h, 0
    ld de, ResultScripts
    add hl, de
    ld a, RESULT_BANK
    ld [rROMB0], a
    ld a, [hl+]
    ld h, [hl]
    ld l, a
    add hl, de
    ld a, l
    ld [wPaintPtr], a
    ld a, h
    ld [wPaintPtr + 1], a
    call SongBank
    ld a, 1
    ld [wPaintStep], a
    ld [wPainted], a
.painting
    ld a, [wPaintCount]         ; (VBlank has not taken the last piece yet)
    or a
    ret nz
    ld a, RESULT_BANK           ; the next piece: (address, length, bytes); 0 length ends it
    ld [rROMB0], a
    ld a, [wPaintPtr]
    ld l, a
    ld a, [wPaintPtr + 1]
    ld h, a
    ld a, [hl+]
    ld [wPaintDst], a
    ld a, [hl+]
    ld [wPaintDst + 1], a
    ld a, [hl+]
    or a
    jr z, .painted
    ld b, a
    ld c, a
    ld de, wPaintBuf
.copy
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copy
    ld a, l
    ld [wPaintPtr], a
    ld a, h
    ld [wPaintPtr + 1], a
    ld a, c
    ld [wPaintCount], a         ; (last: VBlank copies it once this is set)
    jp SongBank
.painted
    ld a, PAINT_DONE
    ld [wPaintStep], a
    jp SongBank

; Put the road and the status bar back after a painted place (the screen must be off).
Unpaint:
    ld a, [wPainted]
    or a
    ret z
    xor a
    ld [wPainted], a
    ld [wPaintStep], a
    ld [wPaintCount], a
    ld a, TILE_BANK
    ld [rROMB0], a
    ld de, Tiles9000            ; the bar's tiles, and the ground's painted where they were
    ld hl, _VRAM9000
    ld bc, Tiles9000.end - Tiles9000
    call Copy
    ld de, Tiles8800
    ld hl, _VRAM8800
    ld bc, Tiles8800.end - Tiles8800
    call Copy
    ld de, Tilemap + (RESULT_ROW - SKY_MAP_BYTES / 32) * 32 + RESULT_COL
    ld hl, _SCRN0 + RESULT_ROW * 32 + RESULT_COL
    ld c, RESULT_H
.row
    ld b, RESULT_W
.col
    ld a, [de]
    ld [hl+], a
    inc de
    dec b
    jr nz, .col
    ld a, e
    add 32 - RESULT_W
    ld e, a
    jr nc, .de
    inc d
.de
    ld a, l
    add 32 - RESULT_W
    ld l, a
    jr nc, .hl
    inc h
.hl
    dec c
    jr nz, .row
    ld hl, wHud                 ; the bar as it was
    ld de, _SCRN1
    ld b, 20
.hud
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .hud
    ret

; The car past the flag, wGone units on up the road: drawn as the rivals are at that distance
; (their smaller cars), in its own palette, until it is out of sight.  Then the speedometer.
Departing:
    ld hl, wOam
    ld a, [wGone]
    add PLAYER_Z
    ld e, a
    ld a, [wGone + 1]
    adc 0
    ld d, a
    cp 8
    jr nc, .gone
    srl d
    rr e
    srl d
    rr e
    srl d
    rr e
    ld d, HIGH(DistToLine)
    ld a, [de]
    cp RIVAL_D4
    jr c, .gone
    ld c, a                     ; c = its ground line
    push hl                     ; its x across the road, scaled down to that line as the
    ldh a, [hX + 1]             ; other player's car is (UpdateRivals)
    sra a
    add SHEAR_SPAN
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
    add 128
    ld b, a
    ldh a, [hBuiltScx]          ; and where the road has been slid to on that line
    ld h, a
    ld a, c
    add HORIZON - 1
    ld l, a
    ld a, b
    sub [hl]
    ld b, a                     ; b = screen x of its middle
    pop hl
    ld a, c
    add HORIZON
    ld d, a                     ; d = OAM y with its bottom row on that line
    ld a, c
    cp RIVAL_D16
    jr c, .size12
    ld a, d                     ; close: the car's two halves and its shadow
    sub 2
    ld e, HERO_TILE
    call .pair
    ld a, d
    add 13
    ld [hl+], a
    ld a, b
    add 4
    ld [hl+], a
    ld a, SHADOW_TILE
    ld [hl+], a
    xor a
    ld [hl+], a
    jr .hide1
.size12
    cp RIVAL_D12
    jr c, .size8
    ld a, d
    dec a
    ld e, CAR12_TILE
    call .pair
    jr .hide2
.size8
    cp RIVAL_D8
    ld e, CAR8_TILE
    jr nc, .one
    ld e, CAR4_TILE
.one
    ld a, d
    dec a
    ld [hl+], a
    ld a, b
    add 4
    ld [hl+], a
    ld a, e
    ld [hl+], a
    xor a
    ld [hl+], a
    jr .hide3
.gone
    xor a
    ld [hl], a
    ld l, LOW(wOam) + 4
.hide3
    xor a
    ld [hl], a
    ld a, l
    add 4
    ld l, a
.hide2
    xor a
    ld [hl], a
    ld a, l
    add 4
    ld l, a
.hide1
    xor a
    ld [hl], a
    jp PlayerSprites.speedo
.pair                           ; two halves at y a, tile e, x b and b + 8
    ld [hl+], a
    push af
    ld a, b
    ld [hl+], a
    ld a, e
    ld [hl+], a
    xor a
    ld [hl+], a
    pop af
    ld [hl+], a
    ld a, b
    add 8
    ld [hl+], a
    ld a, e
    ld [hl+], a
    ld a, OAMF_XFLIP
    ld [hl+], a
    ret

; A rival reaching a ramp on its side of the road (wRampLanes) takes off: its stun byte holds
; FLYING and RIVAL_AIR moves, with the ramp's boost (UpdateRivals .move), and its sprite is
; lifted (.hopOf) by this, with the moves left.
RivalHop:                       ; how high, by moves left in the air: a parabola
    FOR T, RIVAL_AIR + 1
        db (4 * RIVAL_LIFT * T * (RIVAL_AIR - T)) / (RIVAL_AIR * RIVAL_AIR)
    ENDR

; The car picked in the menu: its shape into the player's tiles (the screen must be off) and
; its numbers into wTop..wPush.
LoadCar:
    ld a, TILE_BANK
    ld [rROMB0], a
    ld a, [wCar]
    swap a
    add a                       ; 32 bytes each
    ld e, a
    ld d, 0
    ld hl, HeroTiles
    add hl, de
    ld d, h
    ld e, l
    ld hl, _VRAM8000 + HERO_TILE * 16
    ld bc, 32
    call Copy
    ld a, [wCar]
    ld l, a
    add a
    add a
    add a
    sub l                       ; 7 bytes each
    ld e, a
    ld d, 0
    ld hl, CarStats
    add hl, de
    ld d, h
    ld e, l
    ld hl, wTop
    ld bc, 7
    jp Copy

; What each car does (gen_gfx.py CARS has what it looks like; the menu, its name):
; top speed, the throttle's two numbers, steering, how hard a hit is taken (quarters), and
; how hard bends throw it.  ARROW is the all-rounder, and the game was tuned with it.
CarStats:
    db 8, 2, 3, 24, 4           ; ARROW
    dw PushScale72
    db 8, 3, 6, 28, 5           ; HORNET: quick off the mark and nimble, but fragile
    dw PushScale62
    db 8, 2, 3, 22, 2           ; BISON: heavy to steer and in a bend, but tough
    dw PushScale76
    db 9, 1, 2, 24, 4           ; COMET: the fastest, slow to get there, and at 9 a bend
    dw PushScale76              ; throws it 40% harder than ARROW at 8

; a = the place needed by the end of the lap being raced, F-Zero's rank requirement: in a
; race against rivals (not practice, not linked, not without rivals), 7th then 5th over
; three laps, 7th, 6th, 5th, 4th over five; none on the last lap (8).  Uses bc, hl.
RankNeeded:
    ldh a, [hMode]
    or a                        ; MODE_RACE
    jr nz, .none
    ldh a, [hLevel]
    or a
    jr z, .none
    ldh a, [hLaps]
    ld b, a
    ldh a, [hLap]
    cp b
    jr nc, .none
    ld c, a
    ld a, b
    cp 5
    ld hl, RankNeeded3 - 1
    jr c, .table
    ld hl, RankNeeded5 - 1
.table
    ld b, 0
    add hl, bc
    ld a, [hl]
    ret
.none
    ld a, NUM_RIVALS + 1
    ret
RankNeeded3:
    db 7, 5
RankNeeded5:
    db 7, 6, 5, 4

; hl = de * a, both signed (|a| small: one add per bit).  Keeps bc.
MulSigned:
    ld hl, 0
    bit 7, a
    jr z, .positive
    cpl
    inc a
    push af
    xor a
    sub e
    ld e, a
    sbc a
    sub d
    ld d, a
    pop af
.positive
    or a
    ret z
.bit
    srl a
    jr nc, .skip
    add hl, de
.skip
    sla e
    rl d
    or a
    jr nz, .bit
    ret

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
    FOR N, SHEAR_SPAN * 2 + 1
        dw ShearTables + N * GROUND_LINES
    ENDR

DEF TILE_RESTORE EQU 1
DEF TILE_BOOM    EQU 2
BoomTilePristine:               ; the small shadow's two tiles as they are in car.bin
    INCBIN "build/car.bin", 64, 32

; How hard a bend pushes at each speed (index: speed in quarter units): K at 8, with the
; square of the speed.  The push in pixels/256 per frame is this times the bend, halved.
; One for each car's K (CarStats); PUSH_K is ARROW's.
MACRO PUSH_SCALE                ; \1 = K
PushScale\1:
    FOR N, 48
        db (\1 * N * N + 512) / 1024
    ENDR
ENDM
    PUSH_SCALE 72
    PUSH_SCALE 62
    PUSH_SCALE 76
    ASSERT PUSH_K == 72

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

MACRO PAL_TABLE2                ; the same, in the second bank, under another name
SECTION "pal2 \1", ROMX, BANK[PAL_BANK2], ALIGN[8]
Pal\1:
    INCBIN "build/pal_\2.bin"
ENDM
    PAL_TABLE2 FNear0, fnear0
    PAL_TABLE2 FNear1, fnear1
    PAL_TABLE2 FNear2, fnear2
    PAL_TABLE2 FNear3, fnear3
    PAL_TABLE2 FFar, ffar
    PAL_TABLE2 2TNear0, tnear0
    PAL_TABLE2 2TNear1, tnear1
    PAL_TABLE2 2TNear2, tnear2
    PAL_TABLE2 2TNear3, tnear3
    PAL_TABLE2 2TFar, tfar
    PAL_TABLE2 2Near0, near0
    PAL_TABLE2 2Near1, near1
    PAL_TABLE2 2Near2, near2
    PAL_TABLE2 2Near3, near3
    PAL_TABLE2 2Far0, far0
    PAL_TABLE2 2Far1, far1
    PAL_TABLE2 2Far2, far2

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
    PAL_TABLE WNear0, wnear0
    PAL_TABLE WNear1, wnear1
    PAL_TABLE WNear2, wnear2
    PAL_TABLE WNear3, wnear3
    PAL_TABLE WFar, wfar

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
HeroTiles:                      ; each car in the menu: the left half (LoadCar)
    INCBIN "build/heroes.bin"
Tilemap:
    INCBIN "build/map.bin"
.end
MACRO SKY_DATA                  ; \1 = number, \2 = name
Sky\1Low:
    INCBIN "build/sky_\2_8000.bin"
.end
Sky\1High:
    INCBIN "build/sky_\2_8800.bin"
.end
Sky\1Map:
    INCBIN "build/sky_\2_map.bin"
.end
Sky\1Bgp:
    INCBIN "build/sky_\2_bgp.bin"
.end
ENDM
    SKY_DATA 0, future
    SKY_DATA 1, oldtown
    SKY_DATA 2, ocean
    SKY_DATA 3, plains
FontLow:
    INCBIN "build/font_8000.bin"
.end
FontHigh:
    INCBIN "build/font_8800.bin"
.end
    ALIGN 8
Tracks:                         ; 512 bytes each: see tools/gen_tracks.py
    INCBIN "build/tracks.bin"

SECTION "result scripts", ROMX, BANK[RESULT_BANK]
ResultScripts:                  ; for each of RESULT_TEXTS (gen_gfx.py result_scripts): an
    INCBIN "build/result.bin"   ; offset from here, then the scripts

SECTION "fzero line tables", ROMX, BANK[GFX_BANK]
BendTables:                     ; (BEND_LEVELS*2+1) x GROUND_LINES values of SCX
    INCBIN "build/bend.bin"
ShearTables:                    ; (SHEAR_SPAN*2+1) x GROUND_LINES amounts to add to SCX
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
    ds OBJ_SPRITES * 4 * OBJ_SLOTS  ; road objects
    ds 160 - 16 - OBJ_SPRITES * 4 * OBJ_SLOTS   ; rivals

SECTION "rivals", WRAM0[$C800]
wRivals: ds NUM_RIVALS * 8
wOrder:  ds NUM_RIVALS          ; rival numbers, far to near
wObjSlots: ds 4 * OBJ_SLOTS     ; road objects: on, kind, place along the track (2 bytes)
wHud:    ds 20                  ; the status bar's tiles
wMenuRow:   db
wMenuDirty: db
wSongNow:   db                  ; which track's song is playing
wSongBank:  db
wPalBank:   db                  ; bank of the track's palette tables
wTight:     db                  ; the chunk we are in is a "special tight" corner
wTurn:      ds 2                ; last frame's bend * speed (signed): how hard we were turning
wAdvance:   ds 2                ; how far the car went along the course this frame (8.8)
wShake:     db                  ; frames left of the jolt after a hit
wSlide:     db                  ; frames left of the slide after landing from a ramp
wRev:       db                  ; the engine note's rev above (or below) the speed's, signed
wGone:      ds 2                ; past the flag: how far your car has sped on up the road
wGoneV:     db                  ; ...and how fast (units a frame)
wPainted:   db                  ; the place is painted on the road (the status bar lent its tiles)
wPaintStep: db                  ; Finale's painting: 0, 1 under way, PAINT_DONE
wPaintText: db                  ; which words: 0-7 the place, 8 OUT
wPaintPtr:  ds 2                ; the next piece of its script (RESULT_BANK)
wCar:       db                  ; the car picked in the menu (CarStats); as it goes:
wTop:       db                  ; top speed (units a frame)
wGearK:     db                  ; the throttle: (top - speed) * this + wGrunt, /256 a frame
wGrunt:     db
wSteer:     db                  ; sideways speed, 1/16 pixel a frame
wArmor:     db                  ; a hit costs this many quarters of its health
wPush:      ds 2                ; its PushScale table: how hard bends throw it
wHop:       db                  ; how high the rival being drawn flies off a ramp (pixels)
wFlying:    db                  ; how many rivals are in the air (0: none of that work at all)
wRampChunk: db                  ; the chunk the track's ramp sits in ($FF: none)...
wRampLanes: db                  ; ...and the lanes that take off from it (bits)
wPaintCount: db                 ; bytes in wPaintBuf for VBlank to copy (0: none waiting)
wPaintDst:  ds 2                ; ...to where
wPaintBuf:  ds 32
wScenePages: ds 21              ; palette table pages: 3 sceneries x 7 distance bands
wSkyBgp:    ds HORIZON * 3      ; the sky's palettes, and two darker copies
wSkyFlash:  ds HORIZON * 2      ; two brighter ones for the boost flash

SECTION "track", WRAM0[$CA00]   ; the chosen track, copied here (see tools/gen_tracks.py)
wTrack:
wTrackBend:    ds 64
wTunnelBend:   ds 64
wSpeedProfile: ds 64
wChunkSpawn:   ds 64
wSceneOfChunk: ds 64
wWind:         ds 64
wTrkSkyline:   db
wTrkPalSet:    db
wTrkExit:      db
wTrkSkip:      db
wFeatures:     ds 512 - 388
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
hBend:        db    ; the bend the car feels: 0 hard left .. 32 straight .. 64 hard right
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
hLevel:       db    ; difficulty, 1..LEVELS
hMenu:        db    ; in the menu
hTrackNo:     db    ; which track
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
hObjKind:     db    ; road object: 0 tunnel mouth, 1-4 barrier in lane 0-3, 5-6 dirt
hObjOam:      db    ; low byte of the slot's OAM entries in wOam
hEngine:      db    ; engine note on
hCarTile:     db
hDirt:        db    ; frames of dirt drag left
hBoom:        db    ; frames since the car was wrecked
hTileJob:     db    ; VBlank work on the explosion tile: TILE_RESTORE, TILE_BOOM
hRand:        db
hTurnSign:    db
hNear:        db    ; the bend the car is in, and the next one up the road
hFar:         db
hFarLines:    db    ; how many ground lines, from the horizon down, show the far one
hRailCool:    db    ; frames until the rail can hurt again
hLapFlash:    db    ; frames the lap count flashes for after crossing the line
hObjAttr:     db
hUnder:       db    ; the road object being placed is a patch under the player's car
hSortAt:      db    ; which pair of wOrder gets compared this frame
hBandBase:    ds 7  ; high byte of each distance band's palette table, far band first
hRoof:        db    ; under a roof: no sky
hFlash:       db    ; frames of sky flash left after a boost starts
hKick:        db    ; the car's surge up the screen after a boost starts
hBrake:       db    ; braking at speed this frame
hYOff:        db
hBoostSeen:   db    ; hBoost as last seen, to catch it starting
hEngineMode:  db    ; engine voice: 0 coasting, 1 on the gas, 2 boosting
hScriptTimer: db
hCarY:        db
hCurKeys:     db
hNewKeys:     db
hLoad:        db
