main.gb: main.asm $(wildcard include/*) $(wildcard *.asm)
	rgbasm -I include -o main.o main.asm
	rgbasm -o hUGEDriver.o hUGEDriver.asm
	rgbasm -I include -o menumusic.o menumusic.asm
	rgbasm -I include -o level2music.o level2music.asm
	rgbasm -I include -o level3music.o level3music.asm
	rgbasm -I include -o level4music.o level4music.asm
	rgblink -o main.gb main.o hUGEDriver.o level4music.o level3music.o level2music.o menumusic.o 
	rgbfix -v -p 0xFF -m MBC5 main.gb
	rgblink -n main.sym main.o hUGEDriver.o level4music.o level3music.o level2music.o menumusic.o 

# F-Zero style city proof of concept (separate ROM, shares the sound driver and songs)
FZERO_OBJS = fzero.o hUGEDriver.o level4music.o level3music.o level2music.o menumusic.o
fzero.gb: fzero.asm fzero_gfx.py $(wildcard include/*) hUGEDriver.asm $(wildcard *music.asm)
	python3 fzero_gfx.py fzero_gfx
	rgbasm -I include -o fzero.o fzero.asm
	rgbasm -o hUGEDriver.o hUGEDriver.asm
	rgbasm -I include -o menumusic.o menumusic.asm
	rgbasm -I include -o level2music.o level2music.asm
	rgbasm -I include -o level3music.o level3music.asm
	rgbasm -I include -o level4music.o level4music.asm
	rgblink -o fzero.gb -n fzero.sym $(FZERO_OBJS)
	rgbfix -v -p 0xFF -m MBC5 -t FZEROCITY fzero.gb
