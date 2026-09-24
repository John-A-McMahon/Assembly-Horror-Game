# Beacom at 2am -- 3D assembly edition
# x86-64 NASM + SDL2 (window, input, audio) + SDL2_image + SDL2_ttf + OpenGL + libm
#
#   make            Linux build  -> ./beacom3d
#   make windows    Windows build (MinGW cross-compile) -> beacom3d.exe + SDL DLLs
#   make shots      render test screenshots into shots/ (needs xvfb)

NAME = beacom3d
SRCS = main.asm world.asm ai.asm player.asm render.asm textures.asm hud.asm audio.asm noise.asm physics.asm traverse.asm portal.asm settings.asm worldgen.asm hands.asm parkour.asm achievements.asm
OBJS = $(SRCS:.asm=.o)

all: $(NAME)

%.o: %.asm common.inc
	nasm -f elf64 -g -F dwarf -o $@ $<

$(NAME): $(OBJS)
	gcc -no-pie -g -o $@ $(OBJS) -lSDL2 -lSDL2_image -lSDL2_ttf -lGL -lm

# ---- Windows ---------------------------------------------------------------------
# The same sources assembled with -DWIN64: every external call goes through the
# System V -> Microsoft x64 thunks in win64_thunks.asm (regenerate them with
# `node tools/gen_win64_thunks.js` after adding a new external function).
# The image is based below 2GB because the code uses 32-bit absolute addresses
# for table lookups (like -no-pie on Linux).
SDL_WIN   ?= /opt/sdl
SDL_DIRS   = $(SDL_WIN)/SDL2-2.30.9/x86_64-w64-mingw32 $(SDL_WIN)/SDL2_image-2.8.2/x86_64-w64-mingw32 $(SDL_WIN)/SDL2_ttf-2.22.0/x86_64-w64-mingw32
WIN_EXE   ?= $(NAME).exe
WIN_OBJS   = $(addprefix build-win/,$(SRCS:.asm=.obj)) build-win/win64_thunks.obj

build-win/%.obj: %.asm common.inc win64_names.inc
	@mkdir -p build-win
	nasm -f win64 -DWIN64 -o $@ $<

windows: $(WIN_OBJS)
	x86_64-w64-mingw32-gcc -mconsole -o $(WIN_EXE) $(WIN_OBJS) $(addprefix -L,$(addsuffix /lib,$(SDL_DIRS))) \
	    -lmingw32 -lSDL2main -lSDL2 -lSDL2_image -lSDL2_ttf -lopengl32 \
	    -Wl,--image-base=0x400000 -Wl,--disable-dynamicbase -Wl,--disable-high-entropy-va
	-cp -u $(addsuffix /bin/*.dll,$(SDL_DIRS)) . 2>/dev/null
	-x86_64-w64-mingw32-strip --strip-unneeded *.dll 2>/dev/null

# render test screenshots into shots/ without a real display (needs xvfb)
shots: $(NAME)
	SDL_AUDIODRIVER=dummy xvfb-run -a -s "-screen 0 1280x720x24" ./$(NAME) --shot

clean:
	rm -f $(OBJS) $(NAME) $(NAME).exe $(NAME)_dev.exe *.dll
	-rm -rf shots build-win

.PHONY: all clean shots windows
