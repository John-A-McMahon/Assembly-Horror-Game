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
| Left mouse | fire your **gadget** (no gadget yet: a deauth packet). Hold it on a zipline with a HOOKSHOT to winch |
| Right mouse | the gadget's second use: the portal gun's orange portal (everything else fires as with the left button) |
| Q | fire a deauth packet (stuns T and teleports him away) if you have any, else the gadget |
| E on a gadget part | fit it -- the frame, module or firing type it replaces is left lying in its place |
| V | with the DRONE frame: send the drone off along your aim / call it back |
| G | the gadget bench: A/D pick base, module or firing type, T transmutes (in a safe room), G closes. It's also the catalog of every gadget you've made |
| Space (while a hook pulls you) | let go and fling yourself onwards with the momentum |
| M / Tab | explored map of the current floor |
| Esc | pause menu: settings, custom run, restart (arrows/WASD + Enter, or the mouse) |
| F3 / F4 / F5 | FPS counter / render resolution (1/1, 1/2, 1/3) / flashlight shadows |

Environment overrides: `BEACOM_SCALE=1..3`, `BEACOM_SHADOWS=0|1`,
`BEACOM_MSAA=0|2|4|8`, `BEACOM_MOUSE=edge|relative`, `BEACOM_NOVSYNC=1`
(no vsync: lets the self-test benchmark measure past the refresh rate). When OpenGL runs in
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

* **Loadout** — bring a **module** and/or a **firing type** into the night:
  it's in your hand from the first second (bring LINE + HOOK and you start
  with the zipline gun), and that part isn't hidden in the building tonight.
  Each part you bring costs 15% of the night's score -- travel light and
  score more. Bringing nothing leaves the seed's night exactly as it was.
* **Custom run** — building (**the real Beacom** researched from DSU's own descriptions, **generated from the seed**, **generated at any size** -- 2 to 10 storeys, up to 89 x 47 cells each -- or the original game map),
  generated layout (**maze / classic / open**),
  T's speed / hearing / vision, whether he speeds up with each capture,
  follows you off ledges, or **climbs ladders**, safe rooms on/off, how many
  deauth packets, start with the map + compass, **gadget parts** (a few hidden
  -- the seed picks which -- / every part in hand / none) and how many of each
  kind are hidden (1-4), how many cans of Diet Mountain Dew (0-8), how many bottom feeders (0-4), whether T learns your tricks during the night
* **You** — sprint stamina drain, flashlight battery drain, walk speed, jump
  height, zipline speed
* **Controls** — mouse sensitivity, invert Y, crouch hold/toggle
* **Comfort** — field of view, head bob, camera shake + zipline sway,
  brightness, show hands, heartbeat, master volume
* **Graphics** — render resolution, flashlight shadows, FPS counter, film grain
* **Restart this run**, **restart with a new seed**, quit

Rows marked * apply when you restart.

### The report card

Every night ends with a report card over its last frame (Enter, Space, Esc
or a click to go on): the grade and score, your best on that kind of
building (`beacom_records.cfg`), and how the night went -- time, captures,
how often T spotted you, the **closest call** (the nearest he got while he
could see you), the **loudest moment** (the noise meter's peak), deauths,
gadget shots, mantles and vaults, how far you walked and how long you hid
in safe rooms, your loadout, and the sum the score came from:

| | |
| --- | --- |
| each capture you hold | +200 |
| bringing them to B | +1000 |
| a win: each second under 10 minutes | +1 |
| a win T never saw | +300 |
| each time T spotted you | -50 |
| each deauth fired | -25 |
| each part in your loadout | x0.85 |

Grades: **S** 2200+, **A** 1800+, **B** 1400+, **C** 1000+, **D** 500+, **F** below.
A perfect night -- all three, unseen, in five minutes, bringing nothing -- is
exactly an S.

### Achievements

25 of them, from **PACIFIST** (win without firing a single deauth packet) and
**GHOST PROTOCOL** (win without T ever seeing you) to **STAGE FRIGHT** (stand
on the grand staircase stage while T chases you), **KING OF THE CRATES**,
**THINKING WITH PORTALS**, **GET OVER HERE** (hook or grab T),
**SPIDER-BEACOM** (hook yourself 2.5 m up), **TINKERER** (discover 8
gadgets), **BOTTOM OF THE LINE** (snag a bottom feeder on a capture line), **DO THE DEW** (drink 3 Diet
Mountain Dews in one night), **OUT-FED** (snatch a capture back from a
bottom feeder), **WORTHY** (arm Tyler with the DAUTH CANNON OF GROD), **LOST IN THE MAZE** and a
couple of secrets.
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

### Any size, seeded, and proven completable

Set *Building* to **GENERATED: ANY SIZE** and pick *Custom size: storeys*
(2-10), *width* (20-89 cells) and *depth* (16-47 cells). A cell is 2 m, so
the biggest building is 178 m x 94 m and ten storeys tall. Like a Minecraft
world, the seed decides everything, and the same seed and size always build
the same building on every platform. It's generated around a skeleton that
scales:

* 2-wide corridors run the length of every storey every 10 cells, joined by
  north-south connectors (a different set on each storey)
* walled stairwells between every pair of storeys (2, plus one per 1500
  cells of floor)
* **atriums**: voids through 2-4 storeys with a balcony round the edge and
  now and then a bridge across. Look down, or jump
* classrooms, server labs, gyms, offices, a safe room on every storey, B's
  library on the ground floor, Y's cage in the basement, in the maze,
  classic or open layout

**Every run is proven completable before it starts.** Once the building and
the items are in place, a path-finder that moves as you do (walking, stairs,
ramps, drops, ladders, through safe rooms; no parkour, portals or hookshot,
so the proof never relies on a trick) checks that every packet capture can
be reached from where you start, and that from each one there's a way on to
B. The run opens with *"Seed N: PROVEN COMPLETABLE"*. If a generated seed
ever failed the proof, the game would move on to the next seed that passes
and tell you so. In testing, 360 buildings (40 seeds each of 2, 5 and 10
storeys in all three layouts) were all proven on their first seed, with
every storey reachable and no two alike. The three captures are spread from
the bottom storey to the top, so a tall building is a long night.

The map (M) scales to the building, [ and ] page through all its storeys,
and only the storeys within 3 of yours are drawn. Each storey is also cut
into 12 x 12-cell chunks, and chunks (and ceiling lights) more than 56 m
away, where the fog has swallowed them, are skipped: every screenshot is
byte-identical to drawing everything. (Test laptop, vsync off: a ten-storey
89 x 47 building went from about 70 to 92-104 fps with this; the real
Beacom draws at about 110.)

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

### Hiding under desks

Face a desk and press **E** ("[E] hide under the desk"): you squeeze under
it. You can't move, you see the room from under the desk top, and T can't
see you. **E** again and you climb back out where you went in.

* If T **saw you** duck under, he knows where you are: he comes to the desk
  and drags you out.
* If he didn't, he only finds you by **looking**. The first time he comes
  within about 3 m of your desk he looks under it -- once per visit; he has
  to walk 5 m off before he'll look again. The chance he finds you:
  15%, **+15% for every time you've already hidden tonight** (he learns),
  **+25% with your flashlight on**, **+40% if you're making noise**, at most 80%.

Hiding is a way to wait T out, not a place to live: every desk you use makes
the next one riskier.

### Parkour

Desks, crates and cardboard boxes are solid now, and you can climb them.
Walk into a desk and it stops you; press **Space** facing it and you pull
yourself up onto it; sprint at it and press **Space** and you vault clean over.
Anything with room on top up to about 2 m above your feet can be mantled,
including in mid-air (jump, then catch the ledge). **Sprint + crouch** is a
slide. T can't mantle, vault or climb -- a desk between you is a real
obstacle for him, and in the pit under the atrium a crate and a tall crate
stack let you climb up onto the ground-floor balcony where he can't follow.

### Gadgets: base + module + firing type

There's no portal gun or hookshot lying around any more. You carry a
**frame** (the *base*: a **gun**, or a **drone** if you find one) and find
**parts**: *modules* say what the gadget
controls, *firing types* say how it's delivered and what it acts on. Snap
any module into any firing type and you have a gadget -- every combination
does something, and a new part works with everything you already have.

| Part | What it means |
| --- | --- |
| **GUN** frame | fires from your hand |
| **DRONE** frame | fires from wherever the drone is -- see below |
| **PORTAL** module | bends space: moves things (or you) through it |
| **ROD** module | a rigid rod: rams, props things up, pins, hauls |
| **LINE** module | a line that stays wherever you string it |
| **SMOKE** module | smoke that nothing sees through -- not T, not the feeders, not your own aim |
| **LASER** firing | dead straight and instant, precise |
| **ORB** firing | lobbed in an arc; it bounces, then goes off (the landing clatters -- T hears it) |
| **HOOK** firing | bites into the world and moves **you** |
| **GRABBER** firing | latches on to things and moves **them** |

What the gun makes (the bench keeps a catalog of the ones you've found):

| | LASER | ORB | HOOK | GRABBER |
| --- | --- | --- | --- | --- |
| **PORTAL** | **portal gun**: blue/orange wall portals | **ender orb**: you're wherever it comes to rest | **blink hook**: straight to where it bit | **remote grabber**: a window opens on any surface in sight and a hand reaches 6 m out of it for the nearest thing |
| **ROD** | **knocker**: staggers T, flattens feeders (a thief drops its capture); off a wall, the *clank carries from there* -- T goes to look | **peg launcher**: rods dig in -- a ledge out of a wall, a 1 m post out of a floor (never through you: step back from the wall first). You can climb them, T can't | **hookshot**: hauls you there; Space flings you; on *any* zipline hold fire to **winch**, even uphill, on stamina | **grappler**: hauls items, feeders and boxes to you. T's too heavy -- he just staggers |
| **LINE** | **tripwire**: knee-high, wall to wall along your aim; trips whatever crosses it and tells you where | **bola**: tangles T (2.5 s) or a feeder where it lands; a miss becomes a snare on the floor | **zipline gun**: a cable from over your head to where it bites. Gravity rides it: downhill is easy, uphill you stop and slide back (winch it with a hookshot). It needs a few metres, and room for you to hang from it the whole way -- it won't string one that would drag you through a corner or a floor, and it stops short of the wall it bit | **capture line**: snags feeders and items it passes; they slide down it to the low end. T walks through and snaps it |
| **SMOKE** | **smoke wall** along the beam | **smoke grenade** | **smoke trail**: hauls you out, leaving smoke where you were | **smoke hood**: smoke that follows what it grabbed -- a hooded T only has his ears |

Every gadget is swept by the self-test: all 16 from 60 spots and angles
in the real Beacom must leave you standing somewhere sane (not in a wall,
not stuck mid-move, not under a floor), and the four LINE gadgets from 240
must never string anything through the building.

**The drone.** Every module and firing type works on the drone frame too,
so there are 32 gadgets, not 16. At your shoulder the drone is just a gun.
Press **V** and it flies off along your aim and hovers short of whatever it
meets (up to 20 m); **V** again calls it home. While it's out, every shot
leaves the *drone*, the way *you* are looking -- so you can fire round a
corner, down the atrium or from behind T, and T hears the drone, not you.
A hook can't bite the world from a drone, so it bites the drone; a grabber
reels things in to the drone. T swats a drone that gets within his reach,
and it spends 8 s rebooting on the floor.

| | LASER | ORB | HOOK | GRABBER |
| --- | --- | --- | --- | --- |
| **PORTAL** | **portal drone**: portals from where it hovers | **ender drone**: lobbed from the drone; you land where it rests | **blink beacon**: blink straight to the drone -- even through walls, even upstairs | **window drone**: a window where the drone looks |
| **ROD** | **knocker drone**: a clank you can place -- a lure | **peg bomber**: ledges wherever the drone can reach | **tow drone**: hauls you to the drone (you have to see it) | **fetch drone**: reels things in to itself; items it reaches are yours |
| **LINE** | **wire drone**: a tripwire through where it hovers | **bola bomber** | **skyline**: a zipline from over your head to the drone | **trawler**: a capture line from the drone |
| **SMOKE** | **smokescreen drone** | **crop duster**: smoke from across the building | **smoke tow**: hauled to the drone, trailing smoke | **hoodwinker**: hoods what the drone grabs |

The rules hold everywhere: anything that bends space won't work in (or into)
a safe room; smoke blocks every line of sight in the game (it's part of the
line-of-sight test itself), so a feeder can't see you through it either;
portals, the knocker's clank, orbs landing and the hook's bite are all
things T hears or follows. Hooks, grabbers and lasers hit T's crate stairs
too.

**Each night is different.** You start with the frame; the seed hides a few
modules and a few firing types in the building (the pause menu sets how
many of each: 1-4, default 3), so one night you're a smoke-and-portals
ghost and the next a zipline-and-grappler acrobat. Every night also hides a
**drone frame** somewhere. Parts lie around as what they are -- a portal
ring, a brass rod, a spool of red line, a smoke canister, a laser emitter,
an orb, a grappling hook, a claw, a gun frame, a folded drone -- and the
prompt names them ("[E] take the SMOKE module"). **You carry one frame, one module and one firing
type at a time.** Pick up a part and it snaps straight in;
the one it replaces is left lying where the new one was. So every part you
find is a choice -- keep the portal module, or trade it for smoke? the gun,
or the drone? -- and
changing your mind means walking back for what you left (with T between
you and it, as likely as not). The bench (**G**) shows what you're holding
and the catalog; your hands stay free while it's open, but T doesn't wait. A bad roll isn't the end: step into a **safe room** and
its networking magic lets you **transmute** one part (bench, **T**) into
one of that kind you haven't found.

Making a combination for the first time names it, says what it does and
adds it to the **catalog** (`beacom_gadgets.cfg` -- delete it to forget).
The pause menu's *Gadget parts* row can also put every part in your hand
from the start (you begin holding the hookshot), or take gadgets away.

Deauth packets are separate: you can carry up to 3 alongside your gadget
(Q fires them). The HUD shows your gadget next to the bars.

### Diet Mountain Dew

Four cans (set 0-8 in the pause menu) are scattered around the building.
Drink one (**E**) and you get **10 seconds of unlimited stamina**: the
stamina bar turns lime and counts down. Cracking a can open makes a little
noise.

T drinks them too. He drinks any can he walks past, and while he's
wandering he'll go out of his way for a can within about 14 m. When you
see *"T just cracked open a Diet Mountain Dew"*, he's **wired for 15
seconds**: 40% faster, and he sees and hears 40% further. Grabbing the
cans near his patrol is as much about denying them to him as drinking them
yourself.

### Bottom feeders

Two (0-4 in the pause menu) little scuttling scavengers live in the building.
They can't kill you. They **rob** you:

* While you carry no packet captures they ignore you (you'll still hear the
  tick-tick of their legs nearby).
* Carrying captures, one that sees you comes scuttling after you. It's
  faster than you walk but slower than you sprint.
* If it reaches you it snatches **one capture** and bolts, with the capture
  glowing on its back. The scuffle is loud enough that T may come to look.
* **Catch it** and you snatch the capture back. Otherwise it hides the
  capture somewhere far from you (the message says which floor; the compass
  shows it like any other capture) and calms down for a while.
* They can't enter safe rooms. The compass shows them as purple dots.

**A deauth packet is a choice.** Aim it at a bottom feeder (within 15 m,
in view, roughly in your sights) and that feeder is **gone for good**,
dropping anything it was carrying. But that packet doesn't touch T. Fire
anywhere else and the packet is T's: he's knocked away, but only for a
while. You carry at most 3.

### The DAUTH CANNON OF GROD (sidequest)

Somewhere in the basement lies an ancient **packet weapon** (a purple
plaque marked GROD). You can pick it up, but you can't use it: *"YOU ARE
NOT WORTHY."* It doesn't take your special-item slot. Take it to **Tyler**
(the pickup message tells you which floor he's on) and press **E**. Tyler
is worthy: he becomes the **DAUTH CANNON OF GROD**. From then on he stands
guard with a purple cannon on his shoulder, turning to track T. Whenever T
comes within 16 m in sight of him, a purple bolt blasts T clean across the
building. The cannon then needs 20 seconds to recharge. Lure T past Tyler.

### T fights back: the director, building, portals, learning your tricks

**The director.** T's pressure comes in waves. If he hasn't chased you for
40 s, he's nudged toward where you are (and again every 15 s after). When a
chase gets within 8 m of you and you still get away, he backs off for 12 s,
wandering somewhere at least 25 cells from you. So there's always a breather
after a close call, and never a long safe lull.

**T builds.** Up on a desk, a crate stack or anything else he can't walk to,
while he can see you? He hammers together a staircase of crates (you'll
hear it: about 1.5 s), climbs it and gets you. The stairs fall apart after
20 s. Knock them down first: aim a **deauth** at them, or **hook** them
(the hook yanks them down). If he's on them, he tumbles off and is stunned
for a moment. Like the bottom feeders, a deauth spent on his stairs doesn't
touch T himself.

**T follows you through portals.** Go through a portal while he's chasing
you and he walks to it and steps out of the other side after you. And no
more safe-room cheese: **portals can't be opened in (or into) a safe room**.

**Hooks are loud.** When a hook bites, T hears the clank (22 m) and
comes to look at where you'll land.

**T learns your tricks during the night.** Every chase you escape is put
down to the last trick you used: a hook, a portal trick (portals, the
ender orb, the blink hook), a safe room, a perch he had to build up to, a
deauth, or smoke. Get away the same way **twice**
and he adapts; **four** times and he adapts more:

| You keep escaping with... | T learns to... |
| --- | --- |
| hooks | hear the hook bite from 33 m, then 44 m |
| portal tricks | follow you through portals even when he wasn't chasing you |
| safe rooms | wait outside for 10 s, then 20 s, instead of wandering off |
| perches | build his stairs faster (1.05 s, then 0.6 s) |
| deauths | shake them off quicker (4 s, then 3 s of stun) |
| smoke | see through it when he's close: within 5 m, then 10 m |

You're always told what's going on: the night opens with *"T learns as the
night goes on..."*, each escape tells you *"T saw how you got away: the
hook. (1 of 2 -- then he adapts)"*, and when he adapts you get a red
*"T HAS LEARNED your hookshot: he hears the hook bite from 33 m away now."*
It's **per night**: every run starts with a T who knows nothing, and nothing
is saved. Switch it off in the pause menu if you like.

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
| `hide.asm` | hiding under desks: `hide_try` / `hide_leave` (E), p_mode 5, T's sight skipped while `hd_on`, `hide_update`: does T find you (saw you go in / one look per visit, chance grows per hide, light, noise) |
| `report.asm` | the report card: per-night stats (closest call, loudest moment, distance, safe-room time), the score and grade, best scores in `beacom_records.cfg`, the card drawn over the last frame |
| `achievements.asm` | the 25 achievements: rules, unlock banner, `beacom_achievements.cfg` |
| `parkour.asm` | mantling and vaulting; `player_ground` (the building plus boxes you can stand on) |
| `hands.asm` | your hands and arms: the sculpted hands, hoodie sleeves, flashlight and gadget from `assets/` (or the built-in primitive ones if those files are missing), the gadget's glow in its module's colour, the view-model lighting |
| `assets.asm` | loads the baked art in `assets/`: meshes (`.bmsh`) into display lists, albedo and normal/gloss maps into mipmapped textures; the building's surfaces replace the painted ones |
| `gadget.asm` | the gadget grammar: parts, assembly, the bench and catalog, the two frames (gun; the drone -- flight, T's swat, shots from where it is), the four deliveries (laser, orb, hook, grabber) and each module's handlers; the lines, smoke and pegs gadgets leave in the world |
| `portal.asm` | the portal module's laser: wall portals, walking through, stencil-buffer views through each portal |
| `feeders.asm` | the bottom feeders: wander / chase / steal / flee / stash, on T's nav graph |
| `nemesis.asm` | T learning how you escape him, over one night |
| `hookshot.asm` | the HOOK firing type: traces the throw, latches on, asks the module (the rod pulls you in: fling, auto-mantle), stuns T |
| `player.asm` | first-person controller: mouselook, movement, gravity, stairs, stamina, flashlight battery |
| `ai.asm` | T: BFS over the 3D nav graph, 3D sight, occluded hearing, wander / investigate / chase |
| `render.asm` | GLSL lighting shader (normal maps, skin and cloth lighting), display lists built from the maps (per storey x chunk x material; `call_world` skips chunks lost in the fog), fixtures and light pool, T, items, signs, jumpscare |
| `textures.asm` | the textures painted procedurally in assembly (the fallbacks for `assets/`, and everything else); T's face from `../T_Sprite.jpeg`; SDL_ttf text |
| `hud.asm` | HUD, message log, vignettes, film grain, pause screen, explored map |
| `audio.asm` | software synthesizer in the SDL audio callback: ambience, T's panned hum, footsteps, heartbeat, stingers |

### The art: sculpted in Blender, baked, loaded from `assets/`

Your hands, sleeves, flashlight and gadgets, and the building's walls, floors
and ceilings are real art assets. Scripts in `tools/blender/` drive
Blender 5 headless:

- **Hands and sleeves** are sculpted as signed distance fields: every finger
  is an elliptical cross-section swept along straight phalanges curled round
  the grip, with knuckles, fingertip pads that flatten where they press on
  the grip, nail plates in their folds, a thumb laid along the top, and a
  knit sleeve with a ribbed cuff and bunched folds. OpenVDB turns the field
  into a dense mesh (~1.7 million faces for the hand), fine detail (knuckle
  wrinkles, nail grooves, flexion creases) is displaced on that, and a light
  game mesh is decimated from it.
- **Flashlight and gadgets** are hard-surface: a lathed tactical light
  (knurled grip, finned head, steel bezel, clicky, pocket clip); the gadget
  frame (white polymer shell, panel seams, vents, a core seen through side
  windows, steel prongs); the hookshot (machined green barrel, brass spool
  with its chain, winch, three-claw hook).
- Cycles **bakes** colour (with ambient occlusion -- the fingers darken
  where they touch the flashlight), a tangent-space normal map (pores, skin
  lines, knit, knurling, brushed metal) and gloss from the dense model onto
  the game mesh.
- **The building's surfaces** (`make_world.py`) are height fields at real
  scale -- 400 x 200 mm painted cinderblock with tooled joints, chips and a
  red accent course; quarter-turned VCT floor tiles with heel marks and dirt
  in the seams (and blue and bare-concrete variants); tegular ceiling tiles
  with a water stain -- turned into normal maps and tiling seamlessly.

The shader reads the normal maps (the tangent frame comes from screen-space
derivatives, so the meshes need no tangents), lets red light wrap further
into the shadows on skin than green and blue (cheap subsurface scattering),
gives cloth an even wrap and a sheen, and takes each pixel's gloss from the
map. Your view model also gets a soft fill from the flashlight's light
bouncing round the room.

`.bmsh` is a tiny format: `"BMSH"`, a vertex count, then per vertex
position, normal and texture coordinate (8 floats), plain triangles. Every
asset is optional: if `assets/` is missing the game uses its procedural
stand-ins (the self-test checks both what loaded and that the loader turns
away a missing or bogus file).

To rebuild the art (Blender 5 on Windows; minutes each, the hand longest):

```sh
B="/c/Program Files/Blender Foundation/Blender 5.0/blender.exe"
"$B" -b --factory-startup --python tools/blender/make_hand.py      # hand.bmsh + textures
"$B" -b --factory-startup --python tools/blender/make_sleeve.py
"$B" -b --factory-startup --python tools/blender/make_torch.py
"$B" -b --factory-startup --python tools/blender/make_gadgets.py   # gun, hook, tip
"/c/Program Files/Blender Foundation/Blender 5.0/5.0/python/bin/python.exe" tools/blender/make_world.py
"$B" -b --factory-startup --python tools/blender/preview_asset.py -- out.png hand sleeve torch
```

(`preview_hand.py` renders the raw sculpt from several angles while you
shape it; `preview_asset.py` renders the exported game meshes.)

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
