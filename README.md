# Assembly-Horror-Game

#2am BEACOM Institute of Technology Building

One man(or woman) must brave the darkend halls of beacom find 3 wireshark packet captures and bring them to B to free Y from his captivity but watch out T will chasing after you! Be careful he can't know you are here.

There the doors of beacom lie before you. You have no choice but to go into the depths to save Y. Many will try to stop you but none shall prevail...

Your journey starts now... 


## Assignment description:

Our group, Quentin, Carson and myself (John), have created a horror game in assembly. This game is meant to be similar to 'Granny' or 'Baldi's Basics' Where the player is being chased and you need to collect some objects to escape without being caught. The aim of this game is to collect 3 'wireshark packet captures' to free someone. The game features random seeds and pathfinding for replayability. This game demonstrates storing 2d arrays, functions, path finding (DFS/Dijkstra), and recursion in assembly.



## Two versions

- `game.asm` — the original terminal/ASCII version (32-bit, `make game` / `./game`).
- `doom.asm` — a first-person, raycast 3D version (Wolfenstein/early-Doom style), 64-bit NASM + SDL2 + libm. Same map (`board.txt`), same "collect 3 wireshark captures while T hunts you" loop, but rendered as a real 3D corridor view in an SDL window instead of ASCII art. WASD to move/turn, walk into an item to pick it up, ESC to quit.

## Commands to run using docker  (Linux commands)
use the dockerfile to build the image, run the image, and use make to build the game
```
sudo docker build -t assembly_game .
```

Since `doom` opens a real window, forward your X11 display to the container (on Linux with X11: `xhost +local:docker` first):
```
sudo docker run -it -e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix assembly_game /bin/bash
```
(If you just want the original terminal game, the plain `sudo docker run -it assembly_game /bin/bash` from before still works.)

Inside of container:

```
make
```

```
./game
```

```
./doom
```


To uninstall:


get container id
```
sudo doker ps -a
```

```
sudo docker rm <container ID>
```

```
sudo docker rmi assembly_game
```
