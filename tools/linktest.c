// Link-cable test: runs two copies of the ROM in SameBoy joined by an emulated cable,
// drives both with a simple autopilot, and prints what each console believes.
//
// Needs SameBoy built as a library (git clone https://github.com/LIJI32/SameBoy; make lib bootroms CC=gcc):
//   gcc -O2 -o linktest tools/linktest.c -I SameBoy SameBoy/build/lib/libsameboy.a -lm
//   ./linktest fzero.gb fzero.sym SameBoy/build/bin/BootROMs/dmg_boot.bin FRAMES CABLE [SHOT_FROM SHOT_TO]
// CABLE: 1 = linked two-player, 2 = two separate single-player races, 0 = link mode with no cable.
// SHOT_FROM..SHOT_TO writes both screens to link.rgba (160x144 RGBA, console 0 then 1, every 2nd frame).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include "Core/gb.h"
static GB_gameboy_t *gb[2];
static uint32_t px[2][160 * 144];
static bool bit_out[2] = {true, true};
static void start0(GB_gameboy_t *g, bool b) { bit_out[0] = b; }
static bool end0(GB_gameboy_t *g) { bool r = GB_serial_get_data_bit(gb[1]); GB_serial_set_data_bit(gb[1], bit_out[0]); return r; }
static void start1(GB_gameboy_t *g, bool b) { bit_out[1] = b; }
static bool end1(GB_gameboy_t *g) { bool r = GB_serial_get_data_bit(gb[0]); GB_serial_set_data_bit(gb[0], bit_out[1]); return r; }
static uint32_t rgb(GB_gameboy_t *g, uint8_t r, uint8_t gg, uint8_t b) { return 0xFF000000u | (b << 16) | (gg << 8) | r; }
static bool vb[2];
static void vblank0(GB_gameboy_t *g, GB_vblank_type_t t) { vb[0] = true; }
static void vblank1(GB_gameboy_t *g, GB_vblank_type_t t) { vb[1] = true; }
static int sym(const char *path, const char *name) {
    FILE *f = fopen(path, "r"); char line[256]; int addr = -1;
    while (fgets(line, sizeof line, f)) { unsigned a; char n[128]; if (sscanf(line, "00:%x %127s", &a, n) == 2 && !strcmp(n, name)) addr = a; }
    fclose(f); if (addr < 0) { fprintf(stderr, "no symbol %s\n", name); exit(1); } return addr;
}
#define RD(i, a) GB_safe_read_memory(gb[i], (a))
int main(int argc, char **argv) {
    const char *rom = argv[1], *symf = argv[2], *boot = argv[3]; int frames = atoi(argv[4]); int cable = atoi(argv[5]);
    int shot_from = argc > 6 ? atoi(argv[6]) : 1 << 30, shot_to = argc > 7 ? atoi(argv[7]) : 0;
    int hX = sym(symf, "hX"), hBend = sym(symf, "hBend"), hSpeed = sym(symf, "hSpeed"), hState = sym(symf, "hState"), hLinked = sym(symf, "hLinked"),
        hRank = sym(symf, "hRank"), hLap = sym(symf, "hLap"), hPos = sym(symf, "hPos"), wRivals = sym(symf, "wRivals"), hMode = sym(symf, "hMode"),
        hFrame = sym(symf, "hFrame"), hLoad = sym(symf, "hLoad"), hHealth = sym(symf, "hHealth"), hLinkStale = sym(symf, "hLinkStale");
    for (int i = 0; i < 2; i++) {
        gb[i] = GB_alloc(); GB_init(gb[i], GB_MODEL_DMG_B);
        if (GB_load_boot_rom(gb[i], boot)) { fprintf(stderr, "boot rom?\n"); return 1; }
        if (GB_load_rom(gb[i], rom)) { fprintf(stderr, "rom?\n"); return 1; }
        GB_set_pixels_output(gb[i], px[i]); GB_set_rgb_encode_callback(gb[i], rgb);
        GB_set_vblank_callback(gb[i], i ? vblank1 : vblank0);
        GB_set_sample_rate(gb[i], 0);
    }
    if (cable == 1) {
        GB_set_serial_transfer_bit_start_callback(gb[0], start0); GB_set_serial_transfer_bit_end_callback(gb[0], end0);
        GB_set_serial_transfer_bit_start_callback(gb[1], start1); GB_set_serial_transfer_bit_end_callback(gb[1], end1);
    }
    FILE *out = fopen("link.rgba", "wb"); char last[2][200] = {"", ""}; int drops[2] = {0, 0}, lastf[2] = {-1, -1}, maxload[2] = {0, 0}; long good = 0;
    for (int f = 0; f < frames; f++) {
        // keep the two consoles within a scanline of each other
        vb[0] = vb[1] = false; long t[2] = {0, 0};
        while (!vb[0] || !vb[1]) { int i = (!vb[0] && (vb[1] || t[0] <= t[1])) ? 0 : 1; t[i] += GB_run(gb[i]); }
        for (int i = 0; i < 2; i++) {
            int8_t x = RD(i, hX + 1); int bend = RD(i, hBend) - 32, spd = RD(i, hSpeed + 1), st = RD(i, hState), mode = RD(i, hMode), linked = RD(i, hLinked);
            bool chord = false, start = false;
            if (cable != 2 && f > 200 && mode != 2 && f % 40 < 10) chord = true;             // Select+Start until link mode
            if (i == 0 && f > 500 && mode == 2 && !linked && f % 60 < 5) start = true;  // console 0 calls
            if (st && f % 300 < 5 && i == 1) start = true;                       // console 1 restarts after the race
            int target = (i ? 14 : -14), want = abs(bend) > 20 ? 4 : abs(bend) > 8 ? 6 : (i ? 7 : 8);
            GB_set_key_state(gb[i], GB_KEY_SELECT, chord); GB_set_key_state(gb[i], GB_KEY_START, chord || start);
            GB_set_key_state(gb[i], GB_KEY_LEFT, x > target + 3); GB_set_key_state(gb[i], GB_KEY_RIGHT, x < target - 3);
            GB_set_key_state(gb[i], GB_KEY_B, (linked || cable == 2) && spd < want && !st); GB_set_key_state(gb[i], GB_KEY_DOWN, spd > want);
            int fr = RD(i, hFrame); if (f > 300 && lastf[i] >= 0 && ((fr - lastf[i]) & 255) != 1) { drops[i]++; printf("drop gb%d f%d load %d\n", i, f, RD(i, hLoad)); } lastf[i] = fr;
            int l = RD(i, hLoad); l = l >= 144 ? l - 144 : l + 10; if (f > 300 && l > maxload[i]) maxload[i] = l;
            char line[200]; sprintf(line, "mode%d linked%d lap%d rank%d st%d", mode, linked, RD(i, hLap), RD(i, hRank), st);
            if (strcmp(line, last[i])) { printf("f%d gb%d %s hp%d\n", f, i, line, RD(i, hHealth)); strcpy(last[i], line); }
        }
        if (f % 600 == 599 && RD(0, hLinked)) {   // does each console see the other where it really is?
            int p0 = RD(0, hPos + 1) | RD(0, hPos + 2) << 8, p1 = RD(1, hPos + 1) | RD(1, hPos + 2) << 8;
            int16_t seen01 = RD(0, wRivals + 33) | RD(0, wRivals + 34) << 8, seen10 = RD(1, wRivals + 33) | RD(1, wRivals + 34) << 8;
            printf("f%d truth: gb1 is %d ahead of gb0.  gb0 sees %d, gb1 sees %d (x %d / %d, really %d / %d)  stale %d/%d\n", f, (int16_t)(p1 - p0),
                   seen01 - 175, -(seen10 - 175), (int8_t)RD(0, wRivals + 35), (int8_t)RD(1, wRivals + 35), (int8_t)RD(1, hX + 1), (int8_t)RD(0, hX + 1), RD(0, hLinkStale), RD(1, hLinkStale));
            int16_t r0 = RD(0, wRivals + 1) | RD(0, wRivals + 2) << 8, r0seen = RD(1, wRivals + 17) | RD(1, wRivals + 18) << 8;
            printf("       gb0's first rival is %d ahead of gb0's camera; gb1 places it %d ahead of its own (expect %d)\n", r0, r0seen, r0 - (int16_t)(p1 - p0));
        }
        if (f >= shot_from && f < shot_to && f % 2 == 0) { fwrite(px[0], 4, 160 * 144, out); fwrite(px[1], 4, 160 * 144, out); }
    }
    printf("dropped frames %d / %d, max load %d%% / %d%%\n", drops[0], drops[1], maxload[0] * 100 / 154, maxload[1] * 100 / 154);
    fclose(out); return 0;
}
