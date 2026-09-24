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
| Shift + C (while sprinting) | slide: fast, low and noisy; Space jumps out of it |
| C / Ctrl | crouch (slow, quiet, harder for T to see) |
| Space | jump -- or, facing a ledge, **mantle** up (desks, crates, boxes, ledges up to ~2 m); sprinting at something waist-high, **vault** it |
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
least 55% of the longest walk away (tested over thousands of seeds: never
closer than ~40 steps, about 80 m of walking, in the real Beacom, which is
the smallest building; ~50 in generated ones), so no seed spawn-camps you.

### The pause menu (custom runs)

Esc opens a menu with every knob in the game, saved to `beacom_settings.cfg`:

* **Custom run** — building (**the real Beacom** researched from DSU's own descriptions, **generated from the seed**, or the original game map),
  generated layout (**maze / classic / open**),
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

### Achievements

18 of them, from **PACIFIST** (win without firing a single deauth packet) and
**GHOST PROTOCOL** (win without T ever seeing you) to **STAGE FRIGHT** (stand
on the grand staircase stage while T chases you), **KING OF THE CRATES**,
**THINKING WITH PORTALS**, **LOST IN THE MAZE** and a couple of secrets.
Unlocking one pops a gold banner with a fanfare. They're saved to
`beacom_achievements.cfg` (delete it to start over), listed at the bottom of
the Esc menu, and the end screen in the terminal shows what that run earned.

### Generated Beacom

Set *Building* to **GENERATED FROM THE SEED** and restart: the seed now
builds the whole building — corridors, stairwells, classrooms, server labs,
gyms, offices, a safe room per floor, Y's cage — so every seed is a new
night. The same seed always gives the same building on every platform. The
atrium, the 2nd-floor server room and B's library are kept as landmarks,
and a flood fill guarantees every spot is reachable from the start.

### The real Beacom

The default building is the **Beacom Institute of Technology** at Dakota State
University, rebuilt from what DSU, its architect and its builder have
published. No public floor plan exists, so the room-by-room layout is a
reconstruction around those facts (`tools/beacom_map.js` builds the maps and
documents every choice):

| From the sources | In the game |
| --- | --- |
| Two storeys, ~31,300 sq ft, a long rectangle running north-south, east of Washington Ave between Emry Hall and Girton House | The building runs north-south (row 0 = north), 36 m x 58 m inside -- about 1.4x the real floor area, for room to play |
| The entry is surrounded by glass and opens onto a large collaboration space | A glass west wall (facing Washington Ave) onto a two-storey collaboration space; you start just inside it |
| A media wall of 25 55-inch TVs (5 x 5) that work separately or as one huge screen | A 5 x 5 wall of screens facing the entry, all showing one huge scrolling Wireshark capture |
| A grand staircase at the south end of the collaboration space with bleachers built in, wrapped in repurposed wood; a stage halfway up so the stairs act as bleachers for performances | 16 m of wooden bleacher-steps from the 1st floor up to a stage halfway, then on up to the 2nd floor -- solid, climbable, and T walks them |
| 2nd floor: collaboration pods and the "cyber ops room" float over the collaboration space; labs are visible from the hallways | The collaboration space is open to the 2nd floor; the cyber ops room is a glass box on a bridge over the void, pods jut out from the balconies; labs have glass fronts (T can see you through glass) |
| The Academic Server Room (13 x 26 ft, glass-walled, real servers and network gear) between two large classrooms, on the raised-floor north end of the 2nd floor | Classroom 231, the glass server room (2 x 4 cells = 4 m x 8 m, racks), classroom 233, across the north end of the 2nd floor |
| Rooms 112, 114, 117 (117 hosts presentations), 213, 231, 233, 235 (the conference room); the Beacom College offices; labs for game design, animation and network & security administration | All of these, signed at their doors; the college office is the 2nd floor's safe room |

Invented for the game: exact room positions and sizes, a restroom (the
1st floor's safe room), a back stair, the zipline down onto the stage, and the
entire **sub-level** -- the real building has no known basement; the game's
third storey is fiction: utility tunnels, a mechanical hall with Y's cage, an
electrical room (safe room), a storeroom of crates, and a maintenance ladder up
to a hatch in room 117.

Sources:
[DSU: The Beacom College](https://dsu.edu/academics/colleges/beacom-college/),
[TSP (architect)](https://teamtsp.com/portfolio-items/beacom-institute-technology/),
[Journey Construction](https://www.journeyconstruction.com/projects/dakota-state-university-beacom-institute-of-technology),
[SiouxFalls.Business](https://siouxfalls.business/have-you-seen-dsu-lately-prepare-to-be-amazed-by-the-changes/),
[The Trojan Times](https://trojan-times.com/dsu-campus-embraces-the-renovation-the-ongoing-projects-that-mark-the-first-major-campus-construction-since-the-1980s/),
[DSU Network & Security Admin program review (server room)](https://blogs.dsu.edu/wp-content/uploads/sites/15/2022/03/2021_NetSec_Program_Review_Final_Draft.pdf),
[DSU Computer Science program review (room 235)](https://blogs.dsu.edu/wp-content/uploads/sites/18/2024/06/DSU-MS-and-BS-CS-2024-PROGRAM-REVIEW-REPORT.pdf),
[DSU campus map](https://dsu.edu/Registration/DSU%20Campus%20Map.pdf).

The original game's map is still there: *Building* -> **THE ORIGINAL GAME MAP**
(generated buildings keep its atrium, server room and library as landmarks).

### Parkour

Desks, crates and cardboard boxes are solid now, and you can climb them.
Walk into a desk and it stops you; press **Space** facing it and you pull
yourself up onto it; sprint at it and press **Space** and you vault clean over.
Anything with room on top up to about 2 m above your feet can be mantled,
including in mid-air (jump, then catch the ledge). **Sprint + crouch** is a
slide. T can't mantle, vault or climb -- a desk between you is a real
obstacle for him, and in the pit under the atrium a crate and a tall crate
stack let you climb up onto the ground-floor balcony where he can't follow.

### Generated layouts

With *Building* set to generated, *Generated layout* picks the building's
character:

* **Maze** -- fewer rooms; the solid rock is carved into winding one-cell maze
  passages full of dead ends and corners. Tense and close: you hear T long
  before you see him.
* **Classic** -- rooms off corridors, like the real Beacom.
* **Open** -- bigger rooms with most walls knocked through, open halls with
  crates and pillars for cover, and **tall ceilings**: wherever solid rock sat
  above open floor it becomes air, so halls and corridors rise two or three
  storeys and the floors above turn into balconies and ledges. Tall crate
  stacks under the ledges let you climb up to the next floor (T can't).
  Long sightlines both ways: stealth is about breaking line of sight.

Every layout is checked the same way (every spot reachable, all stairwells,
no duplicate buildings, T starting far away) -- `BEACOM_GENSWEEP` runs the
sweep on all three.

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
| `worldgen.asm` | the seeded building generator (maze / classic / open layouts) |
| `achievements.asm` | the 18 achievements: rules, unlock banner, `beacom_achievements.cfg` |
| `parkour.asm` | mantling and vaulting; `player_ground` (the building plus boxes you can stand on) |
| `hands.asm` | your hands and arms: anatomical gripping hands, flashlight, portal gun, sleeve |
| `portal.asm` | the portal gun: wall portals, walking through, stencil-buffer views through each portal |
| `player.asm` | first-person controller: mouselook, movement, gravity, stairs, stamina, flashlight battery |
| `ai.asm` | T: BFS over the 3D nav graph, 3D sight, occluded hearing, wander / investigate / chase |
| `render.asm` | GLSL lighting shader, display lists built from the maps, fixtures and light pool, T, items, signs, jumpscare |
| `textures.asm` | every texture painted procedurally in assembly; T's face from `../T_Sprite.jpeg`; SDL_ttf text |
| `hud.asm` | HUD, message log, vignettes, film grain, pause screen, explored map |
| `audio.asm` | software synthesizer in the SDL audio callback: ambience, T's panned hum, footsteps, heartbeat, stingers |

### Maps

`maps/beacom/` is the real Beacom Institute of Technology (generated by
`node tools/beacom_map.js`); `maps/original/` is the original game's map
(`ground.txt` is `../board.txt` with stairwells carved in). Same 59×31
character format — edit them in any text editor:

```
' ' floor     S safe-room floor   # H C G L N  walls (concrete, hallway, classroom, gym, library, safe room)
d desk        R server rack       P pillar    Y Y's cage    B B
k crate       K tall crate stack  g glass     W media wall  b floor under the grand stair
u ladder foot (the cell above it upstairs is a '.' hatch)
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
