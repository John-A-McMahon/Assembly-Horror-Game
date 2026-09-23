NAME=game

all: game doom

clean:
	rm -rf game game.o doom doom.o

game: game.asm
	nasm -f elf game.asm
	gcc -no-pie -g -m32 -o game game.o

doom: doom.asm
	nasm -f elf64 doom.asm
	gcc -no-pie -g -o doom doom.o -lSDL2 -lSDL2_image -lm



#gcc -no-pie -g -m32 -o game game.o /usr/local/share/csc314/driver.c /usr/local/share/csc314/asm_io.o
