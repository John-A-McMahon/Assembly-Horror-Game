# Beacom at 2am — 3D assembly edition

A true 3D, multi-storey rewrite of the Assembly Horror Game, still written in
**x86-64 assembly** (NASM). Instead of the raycaster in `../doom.asm`, it
renders real polygons with **OpenGL**: full mouselook, three stacked floors
joined by walkable stairwells, per-pixel lighting with bump-mapped surfaces and
glossy floors, a flashlight that casts real shadows (T's silhouette included),
flickering ceiling lights, fog, 4x antialiasing, and synthesized audio.
The same source builds for **Linux** and natively for **Windows**.

It's the same game: find **3 wireshark packet captures** (one on every floor)
and bring them to **B** in the library to free **Y**, while **T** hunts you.

## How to play

You build the game from source (one command, in a container) and run it
**from the `beacom3d_asm` folder** -- it reads `maps/` and the story files in
`../`. When it starts, the intro plays in the terminal: answer `1` to embark,
then type a seed (any number, or `-1` for a random one). The same seed always
gives the same night.

### Windows

1. Install **Docker Desktop** and start it. Install **Git for Windows** (for
   Git Bash) if you don't have it.
2. Get the code (in Git Bash or PowerShell):
   ```sh
   git clone https://github.com/John-A-McMahon/Assembly-Horror-Game.git
   cd Assembly-Horror-Game
   git checkout beacom3d-asm
   ```
3. Build `beacom3d.exe` (in **Git Bash**, from the repository root). The first
   build also makes the build image, which takes a few minutes:
   ```sh
   beacom3d_asm/tools/dbuild.sh win
   ```
   Or in **PowerShell**, without Git Bash:
   ```powershell
   docker build -t beacom3d-win -f beacom3d_asm/Dockerfile.windows .
   docker run --rm -v "${PWD}:/game" -w /game/beacom3d_asm beacom3d-win make windows
   ```
4. Play:
   ```powershell
   cd beacom3d_asm
   .\beacom3d.exe
   ```
   (or double-click `beacom3d.exe` in that folder). It needs the
   `SDL2*.dll` files the build put next to it -- keep them together if you copy
   the game somewhere else, along with `maps/` and the `.txt` files one folder up.

### Linux

**Native** (Debian/Ubuntu package names):

```sh
sudo apt install nasm gcc make libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev     libgl1-mesa-dev fonts-dejavu-core
git clone https://github.com/John-A-McMahon/Assembly-Horror-Game.git
cd Assembly-Horror-Game && git checkout beacom3d-asm
cd beacom3d_asm
make
./beacom3d
```

**In a container** (Docker or Podman; builds the image the first time):

```sh
beacom3d_asm/tools/dbuild.sh linux     # -> beacom3d_asm/beacom3d
cd beacom3d_asm && ./beacom3d          # needs SDL2 + GL installed to run natively
```

To also *play* inside the container, see "Docker on Linux" below.

### Checking it works

```sh
beacom3d_asm/tools/dbuild.sh test      # build + run every self-test headless
```

The self-test walks the stairs, ramps and ladders, rides the ziplines, checks
T's path finding, sight and hearing, builds 12 generated buildings and checks
every spot is reachable. `BEACOM_GENSWEEP=20000` adds a sweep over 20000 seeds
(stairwells, reachability, unique layouts, how far T starts from you). On
Windows: `set BEACOM_GENSWEEP=20000` then `beacom3d.exe --selftest`.

### Your settings

Everything in the Esc menu is saved to `beacom_settings.cfg` next to the game
when you close the menu. Delete that file to go back to the defaults.

### Docker on Linux

Build from the **repository root**:

```sh
docker build -t beacom3d -f beacom3d_asm/Dockerfile .
xhost +local:docker   # allow the container to open a window (Linux/X11)
docker run -it --rm -e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix \
    --device /dev/snd beacom3d ./beacom3d
```

### Docker on Windows

The container needs an X server on Windows to open its window:

1. Install VcXsrv once: `winget install marha.VcXsrv`
2. Start **XLaunch**: *Multiple windows*, display `0` → *Start no client* →
   tick **Disable access control** (leave *Native opengl* unticked) → Finish.
3. In PowerShell, from the **repository root**:

```powershell
docker build -t beacom3d -f beacom3d_asm/Dockerfile .
docker run -it --rm -e DISPLAY=host.docker.internal:0.0 -e LIBGL_ALWAYS_SOFTWARE=1 -e SDL_AUDIODRIVER=dummy beacom3d ./beacom3d
```

Rendering runs on the CPU inside the container and there is no sound this
way. For sound, build and run it inside WSL instead (`make && ./beacom3d`),
though WSL can't fully lock the mouse pointer.

Test modes (no display needed, uses `xvfb-run`):

```sh
make shots                                    # renders test screenshots into shots/
SDL_AUDIODRIVER=dummy xvfb-run -a ./beacom3d --selftest   # physics, AI, 3D nav/sight/sound checks
```

Or from any host with Docker (Git Bash on Windows works):

```sh
tools/dbuild.sh test     # Linux build + self-test
tools/dbuild.sh win      # Windows beacom3d.exe
```

## Controls

| Key | Action |
| --- | --- |
| WASD (or up/down arrows) | move |
| Mouse (or left/right arrows) | look / turn |
| I | invert vertical mouse look |
| Shift | sprint (drains stamina, loud) |
| C / Ctrl | crouch (slow, quiet, harder for T to see) |
| Space | jump |
| F | flashlight (battery drains; T sees it from far away) |
| E | pick up / talk to B / grab a zipline |
| Q / right mouse | fire a deauth packet (stuns T and teleports him away) |
| Left / right mouse (with the portal gun) | blue / orange portal (Q still fires deauths) |
| M / Tab | explored map of the current floor |
| Esc | pause menu: settings, custom run, restart (arrows/WASD + Enter, or the mouse) |
| F3 / F4 / F5 | FPS counter / render resolution (1/1, 1/2, 1/3) / flashlight shadows |

Environment overrides: `BEACOM_SCALE=1..3`, `BEACOM_SHADOWS=0|1`,
`BEACOM_MSAA=0|2|4|8`, `BEACOM_MOUSE=edge|relative`. When OpenGL runs in
software (e.g. Docker), the game drops to half resolution and turns shadows,
bump mapping and antialiasing off automatically.

Blue rooms are **safe rooms** — T can never enter them.

T always starts on the far side of the building from you: a flood of his own
path-finding graph measures the real walking distance, and he spawns at
least 55% of the longest walk away (never closer than ~55 steps in 20000
tested seeds), so no seed spawn-camps you.

### The pause menu (custom runs)

Esc opens a menu with every knob in the game, saved to `beacom_settings.cfg`:

* **Custom run** — building (the real Beacom or **generated from the seed**),
  T's speed / hearing / vision, whether he speeds up with each capture,
  follows you off ledges, or **climbs ladders**, safe rooms on/off, how many
  deauth packets, start with the map + compass, portal gun hidden / in hand / off
* **You** — sprint stamina drain, flashlight battery drain, walk speed, jump
  height, zipline speed
* **Controls** — mouse sensitivity, invert Y, crouch hold/toggle
* **Comfort** — field of view, head bob, camera shake + zipline sway,
  brightness, show hands, heartbeat, master volume
* **Graphics** — render resolution, flashlight shadows, FPS counter, film grain
* **Restart this run**, **restart with a new seed**, quit

Rows marked * apply when you restart.

### Generated Beacom

Set *Building* to **GENERATED FROM THE SEED** and restart: the seed now
builds the whole building — corridors, stairwells, classrooms, server labs,
gyms, offices, a safe room per floor, Y's cage — so every seed is a new
night. The same seed always gives the same building on every platform. The
atrium, the 2nd-floor server room and B's library are kept as landmarks,
and a flood fill guarantees every spot is reachable from the start.

### The Stack (the atrium)

Off the main ground-floor hallway, a door opens onto balconies around a
three-storey void over the basement pillar hall. Ramp A climbs to a bridge at
half-storey height; ramp B carries on up into the 2nd-floor server room; a
zipline drops from the server room across the void to the ground balcony.
Walk off any edge and you land in the basement — loudly.

The building is one continuous 3D space: T sees along real 3D rays (he can
spot you from the basement if you stand at the 2nd-floor rail with your
flashlight on — and you can watch him down there), hears through the
building (floor slabs muffle a lot, walls some, the open atrium nothing),
and walks a 3D navigation graph with ramps, bridges and ledge drops. He will
follow you down into the atrium. He still can't climb ladders.

## How it's put together

| File | What it does |
| --- | --- |
| `common.inc` | constants, the `PROLOGUE`/`EPILOGUE` frame macros, imports, cross-module symbols |
| `win64_thunks.asm` | Windows only: System V -> Microsoft x64 calling-convention thunks (generated by `tools/gen_win64_thunks.js`) |
| `main.asm` | terminal intro/seed prompt/lolcat endings, window, input, game loop, items, B, easter eggs, `--shot`/`--selftest` |
| `world.asm` | loads `maps/*.txt`, character classes, stair ramps, platforms/ramps, ground height, collision, 3D line of sight, sound occlusion, the 3D nav graph (node XYZ table + walk/drop/ladder links) |
| `settings.asm` | all settings, the pause menu, `beacom_settings.cfg` |
| `worldgen.asm` | the seeded building generator |
| `portal.asm` | the portal gun: wall portals, walking through, stencil-buffer views through each portal |
| `player.asm` | first-person controller: mouselook, movement, gravity, stairs, stamina, flashlight battery |
| `ai.asm` | T: BFS over the 3D nav graph, 3D sight, occluded hearing, wander / investigate / chase |
| `render.asm` | GLSL lighting shader, display lists built from the maps, fixtures and light pool, T, items, signs, jumpscare |
| `textures.asm` | every texture painted procedurally in assembly; T's face from `../T_Sprite.jpeg`; SDL_ttf text |
| `hud.asm` | HUD, message log, vignettes, film grain, pause screen, explored map |
| `audio.asm` | software synthesizer in the SDL audio callback: ambience, T's panned hum, footsteps, heartbeat, stingers |

### Maps

`maps/ground.txt` is the original `../board.txt` with stairwells carved in;
`maps/basement.txt` and `maps/second.txt` are new. Same 59×31 character
format — edit them in any text editor:

```
' ' floor     S safe-room floor   # H C G L N  walls (concrete, hallway, classroom, gym, library, safe room)
d desk        R server rack       P pillar    Y Y's cage    B B
^ v < >       stairs (the arrow points the way the stair RISES)
.             open shaft above a stair on the floor below
```

A stair's top cell must lead onto an open cell of the floor above, and the
cells above the rest of the run must be `.`.

### One source, two operating systems

All the game code calls functions the Linux (System V) way. For Windows every
external call goes through a small generated thunk that moves the arguments
into the Microsoft x64 registers; `printf`'s thunk even reads the format
string to know which arguments are floating point. Random numbers come from
the game's own generator, so a seed plays out identically on both systems.

### Differences from the browser (Three.js) version

* Adds bump-mapped walls/floors and specular highlights the web version lacks.
* Audio is stereo-panned toward T with distance falloff rather than full HRTF.
