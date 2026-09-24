; =============================================================================
; worldgen.asm -- "synthetic Beacom": a new building generated from the seed.
;
; Pause menu -> Building: GENERATED FROM THE SEED. The same seed always
; builds the same building, on Linux and Windows alike (rng_next is ours).
;
;   1. everything starts as solid concrete '#'
;   2. the corridors the ziplines run along are always there (basement rows
;      2-4 and 26-28, ground floor rows 14-16, 2nd floor rows 2-4 and 15-16),
;      joined by north-south corridors at seeded positions
;   3. landmarks are copied from the real maps: the start room, the atrium
;      ("The Stack", so its ramps, bridge and zipline still work), the
;      2nd-floor server room and B's library
;   4. stairwells: two between each pair of storeys at seeded positions,
;      walled in so you can't wander into a shaft
;   5. rooms: rectangles of solid rock become classrooms, labs full of
;      server racks, gyms with pillars and offices, each with a door onto a
;      corridor. One small room per floor becomes a safe room; one basement
;      room gets Y's cage.
;   6. the layout setting (cfg_layout) reshapes what's left:
;        MAZE    fewer, smaller rooms; the leftover rock is carved into
;                winding one-cell maze passages (a depth-first maze) that
;                join the halls in several places
;        CLASSIC rooms off corridors, as above
;        OPEN    bigger rooms, open halls with crates and pillars for cover,
;                and many walls knocked through into open-plan space
;   7. a flood fill from the start walls up anything you couldn't reach, so
;      nothing can ever spawn somewhere unreachable.
; =============================================================================
%define MODULE_WORLDGEN
%include "common.inc"

global worldgen_generate
extern cfg_layout

extern classic_grid, compute_stairs

%define LAYOUT_MAZE    0
%define LAYOUT_CLASSIC 1
%define LAYOUT_OPEN    2
%define TH_PLAIN   0
%define TH_DESKS   1
%define TH_RACKS   2
%define TH_PILLARS 3
%define TH_SAFE    4

; FILL f, x0, y0, x1, y1, char     CLASSIC f, x0, y0, x1, y1
%macro FILL 6
    mov edi, %1
    mov esi, %2
    mov edx, %3
    mov ecx, %4
    mov r8d, %5
    mov r9d, %6
    call fill
%endmacro
%macro CLASSIC 5
    mov edi, %1
    mov esi, %2
    mov edx, %3
    mov ecx, %4
    mov r8d, %5
    call copy_classic
%endmacro

section .data
; north-south connectors: per floor 4 zones of x from, x to, y from, y to
zones:
    dd 4, 12, 5, 25,    16, 26, 5, 25,    44, 54, 5, 25,    0, 0, 0, 0     ; basement
    dd 8, 14, 2, 28,    18, 26, 2, 13,    46, 54, 2, 13,    18, 26, 17, 28 ; ground
    dd 6, 14, 5, 28,    20, 26, 5, 14,    48, 54, 5, 28,    0, 0, 0, 0     ; 2nd
; per layout (maze, classic, open): room attempts and room sizes
lay_tries   dd 1500, 5000, 5000
lay_wmin    dd 5, 5, 9
lay_wmax    dd 10, 15, 17
lay_hmin    dd 5, 5, 7
lay_hmax    dd 8, 11, 11
; flood fill directions
fdx         dd 1, -1, 0, 0
fdy         dd 0, 0, 1, -1

section .bss
alignb 4
reach       resb NCELLS
stk         resd NCELLS             ; maze carving stack (x | y << 8)
hall        resb NCELLS             ; 1 = floor of an open hall (open_halls)             ; flood fill: reached from the start
queue       resd NCELLS
dcand       resd 128                ; door candidates: x | y << 8
ndoor       resd 1
cur_f       resd 1
rx0         resd 1                  ; the room being placed (walls included)
ry0         resd 1
rx1         resd 1
ry1         resd 1
rwall       resd 1
rfloor      resd 1
rtheme      resd 1
safe_done   resd NF
cage_done   resd 1

section .text

; ---- small helpers -------------------------------------------------------------

; rand_range(edi=lo, esi=hi) -> eax in [lo, hi]
rand_range:
    PROLOGUE 16
    mov ebx, edi
    mov r12d, esi
    sub r12d, ebx
    inc r12d
    call rng_next
    xor edx, edx
    div r12d
    lea eax, [rbx+rdx]
    EPILOGUE

; gset(edi=f, esi=x, edx=y, ecx=char) -- in bounds only. leaf
gset:
    cmp esi, 0
    jl .no
    cmp esi, MAP_W
    jge .no
    cmp edx, 0
    jl .no
    cmp edx, MAP_H
    jge .no
    imul eax, edi, MAP_H
    add eax, edx
    imul eax, eax, MAP_W
    add eax, esi
    mov [grid+rax], cl
.no:
    ret

; fill(edi=f, esi=x0, edx=y0, ecx=x1, r8d=y1, r9d=char) -- inclusive rectangle
fill:
    PROLOGUE 32
    mov [rsp+0], edi
    mov [rsp+4], esi
    mov [rsp+8], ecx
    mov [rsp+12], r8d
    mov [rsp+16], r9d
    mov r13d, edx
.y:
    cmp r13d, [rsp+12]
    jg .done
    mov r12d, [rsp+4]
.x:
    cmp r12d, [rsp+8]
    jg .ny
    mov edi, [rsp+0]
    mov esi, r12d
    mov edx, r13d
    mov ecx, [rsp+16]
    call gset
    inc r12d
    jmp .x
.ny:
    inc r13d
    jmp .y
.done:
    EPILOGUE

; all_rock(edi=f, esi=x0, edx=y0, ecx=x1, r8d=y1) -> eax 1 if every cell is
; '#' and the rectangle keeps off the outer wall
all_rock:
    PROLOGUE 32
    mov [rsp+0], edi
    mov [rsp+4], esi
    mov [rsp+8], ecx
    mov [rsp+12], r8d
    cmp esi, 1
    jl .no
    cmp edx, 1
    jl .no
    cmp ecx, MAP_W-2
    jg .no
    cmp r8d, MAP_H-2
    jg .no
    mov r13d, edx
.y:
    cmp r13d, [rsp+12]
    jg .yes
    mov r12d, [rsp+4]
.x:
    cmp r12d, [rsp+8]
    jg .ny
    mov edi, [rsp+0]
    mov esi, r12d
    mov edx, r13d
    call cell_at
    cmp eax, '#'
    jne .no
    inc r12d
    jmp .x
.ny:
    inc r13d
    jmp .y
.yes:
    mov eax, 1
    EPILOGUE
.no:
    xor eax, eax
    EPILOGUE

; copy_classic(edi=f, esi=x0, edx=y0, ecx=x1, r8d=y1) -- a landmark from the
; real maps
copy_classic:
    PROLOGUE 32
    mov [rsp+0], edi
    mov [rsp+4], esi
    mov [rsp+8], ecx
    mov [rsp+12], r8d
    mov r13d, edx
.y:
    cmp r13d, [rsp+12]
    jg .done
    mov r12d, [rsp+4]
.x:
    cmp r12d, [rsp+8]
    jg .ny
    mov edi, [rsp+0]
    mov esi, r12d
    mov edx, r13d
    call cell_index
    movzx ecx, byte [classic_grid+rax]
    mov [grid+rax], cl
    inc r12d
    jmp .x
.ny:
    inc r13d
    jmp .y
.done:
    EPILOGUE

; ---- the generator ------------------------------------------------------------

; worldgen_generate(edi=seed) -- replace grid with a new building
worldgen_generate:
    PROLOGUE 32
    xor edi, 0x0BEAC0DE                 ; its own stream of random numbers
    call rng_seed
    lea rdi, [grid]
    mov esi, '#'
    mov edx, NCELLS
    call memset
    lea rdi, [hall]
    xor esi, esi
    mov edx, NCELLS
    call memset
    xor eax, eax
    mov [safe_done], eax
    mov [safe_done+4], eax
    mov [safe_done+8], eax
    mov [cage_done], eax

    ; ---- the zipline corridors
    FILL 0, 2, 2, 56, 4, ' '
    FILL 0, 2, 26, 56, 28, ' '
    FILL 1, 1, 14, 57, 16, ' '
    FILL 2, 2, 2, 56, 4, ' '
    FILL 2, 2, 15, 56, 16, ' '
    ; north-south connectors at seeded positions
    xor r12d, r12d                      ; floor
.zf:
    cmp r12d, NF
    jge .zones_done
    xor r13d, r13d                      ; zone
.zz:
    cmp r13d, 4
    jge .zfn
    imul eax, r12d, 4
    add eax, r13d
    shl eax, 4
    lea r14, [zones+rax]
    cmp dword [r14+4], 0
    je .zzn
    mov edi, [r14+0]
    mov esi, [r14+4]
    call rand_range
    mov r15d, eax
    mov edi, r12d
    mov esi, r15d
    mov edx, [r14+8]
    lea ecx, [r15d+1]
    mov r8d, [r14+12]
    mov r9d, ' '
    call fill
.zzn:
    inc r13d
    jmp .zz
.zfn:
    inc r12d
    jmp .zf
.zones_done:

    ; ---- landmarks from the real Beacom
    FILL 1, 1, 1, 6, 3, ' '             ; the room you start in...
    FILL 1, 2, 4, 3, 13, ' '            ; ...and its hallway to the main corridor
    CLASSIC 0, 30, 17, 38, 25           ; under the atrium: the pillar hall
    FILL 0, 30, 16, 38, 16, '#'
    CLASSIC 1, 30, 17, 37, 24           ; ground-floor balconies
    CLASSIC 2, 30, 17, 45, 29           ; the server room with the hole in it
    CLASSIC 1, 42, 17, 57, 29           ; B's library

    ; ---- stairwells
    xor edi, edi
    call place_stairs
    xor edi, edi
    call place_stairs
    mov edi, 1
    call place_stairs
    mov edi, 1
    call place_stairs

    ; ---- maze layout: the rock becomes maze first, rooms take what is left
    cmp dword [cfg_layout], LAYOUT_MAZE
    jne .rooms
    call carve_mazes
.rooms:
    ; ---- rooms
    xor r12d, r12d
.rf:
    cmp r12d, NF
    jge .rooms_done
    mov [cur_f], r12d
    mov eax, [cfg_layout]
    mov r13d, [lay_tries+rax*4]
.rt:
    call try_room
    dec r13d
    jnz .rt
    inc r12d
    jmp .rf
.rooms_done:

    ; ---- the layout
    cmp dword [cfg_layout], LAYOUT_MAZE
    jne .not_maze
    mov edi, 12                         ; maze pockets join the halls here and there
    xor esi, esi
    call punch
    jmp .laid_out
.not_maze:
    cmp dword [cfg_layout], LAYOUT_OPEN
    jne .laid_out
    call open_halls
    mov edi, 40                         ; halls open onto everything around them
    xor esi, esi
    call punch
    mov edi, 70                         ; and room walls come down
    mov esi, 1
    call punch
    call raise_ceilings                 ; and the ceilings go up
.laid_out:

    ; ---- nothing unreachable
    call compute_stairs
    call flood_from_start
    EPILOGUE

; place_stairs(edi = lower storey 0 or 1) -- a walled stairwell rising north
; out of a corridor on this storey into a short passage that leads to a
; corridor on the storey above. 60 tries at seeded positions; if none fits,
; every position left to right, so a stairwell is only missing when the
; building has no room for one at all.
place_stairs:
    PROLOGUE 48
    ; [rsp+0] f  [rsp+4] top step row  [rsp+8] passage top row
    mov [rsp+0], edi
    mov dword [rsp+4], 20               ; basement: steps rows 20..25, from row 26
    mov dword [rsp+8], 17               ; ground: passage rows 17..19 to row 16
    test edi, edi
    jz .rows
    mov dword [rsp+4], 8                ; ground: steps rows 8..13, from row 14
    mov dword [rsp+8], 5                ; 2nd: passage rows 5..7 to row 4
.rows:
    mov ebx, 60
    mov r15d, 3                         ; where the fallback scan is up to
.try:
    dec ebx
    js .scan
    mov edi, 3
    mov esi, MAP_W-7
    call rand_range
    mov r12d, eax                       ; x: the stairwell is x..x+3
    jmp .check
.scan:
    cmp r15d, MAP_W-7
    jg .done
    mov r12d, r15d
    inc r15d
.check:
    mov r13d, [rsp+4]                   ; y
    ; this storey: rock from the wall behind the top down to the bottom step
    mov edi, [rsp+0]
    mov esi, r12d
    lea edx, [r13d-1]
    lea ecx, [r12d+3]
    lea r8d, [r13d+5]
    call all_rock
    test eax, eax
    jz .try
    ; ...and corridor to walk up from
    mov edi, [rsp+0]
    lea esi, [r12d+1]
    lea edx, [r13d+6]
    call cell_at
    cmp eax, ' '
    jne .try
    mov edi, [rsp+0]
    lea esi, [r12d+2]
    lea edx, [r13d+6]
    call cell_at
    cmp eax, ' '
    jne .try
    ; the storey above: rock for the passage, the shaft and a wall south of
    ; it, and corridor where the passage comes out
    mov edi, [rsp+0]
    inc edi
    mov esi, r12d
    mov edx, [rsp+8]
    lea ecx, [r12d+3]
    lea r8d, [r13d+6]
    call all_rock
    test eax, eax
    jz .try
    mov edi, [rsp+0]
    inc edi
    lea esi, [r12d+1]
    mov edx, [rsp+8]
    dec edx
    call cell_at
    cmp eax, ' '
    jne .try
    mov edi, [rsp+0]
    inc edi
    lea esi, [r12d+2]
    mov edx, [rsp+8]
    dec edx
    call cell_at
    cmp eax, ' '
    jne .try
    ; carve: steps, shaft, passage
    mov edi, [rsp+0]
    lea esi, [r12d+1]
    mov edx, r13d
    lea ecx, [r12d+2]
    lea r8d, [r13d+5]
    mov r9d, '^'
    call fill
    mov edi, [rsp+0]
    inc edi
    lea esi, [r12d+1]
    mov edx, r13d
    lea ecx, [r12d+2]
    lea r8d, [r13d+5]
    mov r9d, '.'
    call fill
    mov edi, [rsp+0]
    inc edi
    lea esi, [r12d+1]
    mov edx, [rsp+8]
    lea ecx, [r12d+2]
    lea r8d, [r13d-1]
    mov r9d, ' '
    call fill
.done:
    EPILOGUE

; try_room() -- one attempt at a room somewhere in the rock of storey cur_f
try_room:
    PROLOGUE 32
    ; [rsp+0] w  [rsp+4] h
    mov ebx, [cfg_layout]
    mov edi, [lay_wmin+rbx*4]
    mov esi, [lay_wmax+rbx*4]
    call rand_range
    mov [rsp+0], eax
    mov ebx, [cfg_layout]
    mov edi, [lay_hmin+rbx*4]
    mov esi, [lay_hmax+rbx*4]
    call rand_range
    mov [rsp+4], eax
    mov edi, 1
    mov esi, MAP_W-1
    sub esi, [rsp+0]
    call rand_range
    mov [rx0], eax
    add eax, [rsp+0]
    dec eax
    mov [rx1], eax
    mov edi, 1
    mov esi, MAP_H-1
    sub esi, [rsp+4]
    call rand_range
    mov [ry0], eax
    add eax, [rsp+4]
    dec eax
    mov [ry1], eax
    mov edi, [cur_f]
    mov esi, [rx0]
    mov edx, [ry0]
    mov ecx, [rx1]
    mov r8d, [ry1]
    call all_rock
    test eax, eax
    jz .done
    ; door candidates: wall cells (not corners) with corridor just outside
    mov dword [ndoor], 0
    mov r12d, [rx0]
    inc r12d
.top:
    cmp r12d, [rx1]
    jge .sides
    mov r13d, [ry0]
    xor r14d, r14d
    mov r15d, -1
    call door_cand
    mov r13d, [ry1]
    xor r14d, r14d
    mov r15d, 1
    call door_cand
    inc r12d
    jmp .top
.sides:
    mov r13d, [ry0]
    inc r13d
.side:
    cmp r13d, [ry1]
    jge .chosen
    mov r12d, [rx0]
    mov r14d, -1
    xor r15d, r15d
    call door_cand
    mov r12d, [rx1]
    mov r14d, 1
    xor r15d, r15d
    call door_cand
    inc r13d
    jmp .side
.chosen:
    cmp dword [ndoor], 0
    je .done
    call pick_theme
    ; walls, floor, door
    mov edi, [cur_f]
    mov esi, [rx0]
    mov edx, [ry0]
    mov ecx, [rx1]
    mov r8d, [ry1]
    mov r9d, [rwall]
    call fill
    mov edi, [cur_f]
    mov esi, [rx0]
    inc esi
    mov edx, [ry0]
    inc edx
    mov ecx, [rx1]
    dec ecx
    mov r8d, [ry1]
    dec r8d
    mov r9d, [rfloor]
    call fill
    xor edi, edi
    mov esi, [ndoor]
    dec esi
    call rand_range
    mov eax, [dcand+rax*4]
    movzx esi, al
    shr eax, 8
    mov edx, eax
    mov edi, [cur_f]
    mov ecx, [rfloor]                   ; (a safe room's door is safe floor too)
    call gset
    ; often a second door: rooms you can run through make escape loops
    cmp dword [rtheme], TH_SAFE
    je .one_door
    cmp dword [ndoor], 4
    jl .one_door
    call rng_next
    test eax, 1
    jz .one_door
    xor edi, edi
    mov esi, [ndoor]
    dec esi
    call rand_range
    mov eax, [dcand+rax*4]
    movzx esi, al
    shr eax, 8
    mov edx, eax
    mov edi, [cur_f]
    mov ecx, ' '
    call gset
.one_door:
    call furnish
.done:
    EPILOGUE

; door_cand(r12d=x, r13d=y, r14d/r15d = outward dx/dy) -- remember this wall
; cell if plain corridor lies outside it
door_cand:
    PROLOGUE 16
    mov edi, [cur_f]
    lea esi, [r12d+r14d]
    lea edx, [r13d+r15d]
    call cell_at
    cmp eax, ' '
    jne .done
    mov eax, [ndoor]
    cmp eax, 128
    jge .done
    mov ecx, r13d
    shl ecx, 8
    or ecx, r12d
    mov [dcand+rax*4], ecx
    inc dword [ndoor]
.done:
    EPILOGUE

; pick_theme -- walls, floor and furniture for the room at rx0..ry1
pick_theme:
    PROLOGUE 16
    mov eax, [rx1]
    sub eax, [rx0]
    dec eax                             ; interior width
    mov ecx, [ry1]
    sub ecx, [ry0]
    dec ecx                             ; interior height
    imul eax, ecx
    mov r12d, eax                       ; interior area
    mov ebx, [cur_f]
    ; the first small room on each floor is a safe room
    cmp dword [safe_done+rbx*4], 0
    jne .normal
    cmp r12d, 45
    jg .normal
    mov dword [safe_done+rbx*4], 1
    mov dword [rwall], 'N'
    mov dword [rfloor], 'S'
    mov dword [rtheme], TH_SAFE
    EPILOGUE
.normal:
    mov dword [rfloor], ' '
    xor edi, edi
    mov esi, 99
    call rand_range
    mov r13d, eax
    cmp ebx, 0
    je .basement
    cmp ebx, 1
    je .ground
    ; 2nd floor: classrooms, offices, cyber labs
    cmp r13d, 50
    jl .classroom
    cmp r13d, 78
    jl .office
    jmp .lab
.basement:
    cmp r13d, 50
    jl .lab
    cmp r13d, 72
    jl .hall
    jmp .classroom
.ground:
    cmp r13d, 38
    jl .classroom
    cmp r13d, 58
    jl .gym
    cmp r13d, 82
    jl .office
    mov dword [rwall], 'L'              ; a reading room
    mov dword [rtheme], TH_DESKS
    EPILOGUE
.gym:
    cmp r12d, 50
    jl .classroom
    mov dword [rwall], 'G'
    mov dword [rtheme], TH_PILLARS
    EPILOGUE
.hall:
    mov dword [rwall], 'H'
    mov dword [rtheme], TH_PILLARS
    EPILOGUE
.classroom:
    mov dword [rwall], 'C'
    mov dword [rtheme], TH_DESKS
    EPILOGUE
.office:
    mov dword [rwall], 'H'
    mov dword [rtheme], TH_PLAIN
    EPILOGUE
.lab:
    mov dword [rwall], 'C'
    mov dword [rtheme], TH_RACKS
    EPILOGUE

; furnish -- furniture inside the room, always leaving a free ring along the
; walls so every part of it stays reachable from the door
furnish:
    PROLOGUE 32
    ; furniture area: [rsp+0] x0 [rsp+4] y0 [rsp+8] x1 [rsp+12] y1
    mov eax, [rx0]
    add eax, 2
    mov [rsp+0], eax
    mov eax, [ry0]
    add eax, 2
    mov [rsp+4], eax
    mov eax, [rx1]
    sub eax, 2
    mov [rsp+8], eax
    mov eax, [ry1]
    sub eax, 2
    mov [rsp+12], eax
    mov eax, [rsp+8]
    cmp eax, [rsp+0]
    jl .done
    mov eax, [rsp+12]
    cmp eax, [rsp+4]
    jl .done
    cmp dword [rtheme], TH_SAFE
    je .done
    ; Y's cage goes in the first roomy enough basement room
    cmp dword [cur_f], 0
    jne .furniture
    cmp dword [cage_done], 0
    jne .furniture
    mov eax, [rsp+8]
    sub eax, [rsp+0]
    cmp eax, 3
    jl .furniture
    mov dword [cage_done], 1
    mov edi, 0
    mov esi, [rsp+0]
    mov edx, [rsp+4]
    lea ecx, [rsi+3]
    mov r8d, edx
    mov r9d, 'Y'
    call fill
    EPILOGUE
.furniture:
    mov eax, [rtheme]
    cmp eax, TH_DESKS
    je .desks
    cmp eax, TH_RACKS
    je .racks
    cmp eax, TH_PILLARS
    je .pillars
    jmp .done
.desks:
    ; rows of three desks
    mov r13d, [rsp+4]
.dy:
    cmp r13d, [rsp+12]
    jg .done
    mov r12d, [rsp+0]
.dx:
    cmp r12d, [rsp+8]
    jg .dny
    mov ebx, 3
.d3:
    cmp r12d, [rsp+8]
    jg .dny
    mov edi, [cur_f]
    mov esi, r12d
    mov edx, r13d
    mov ecx, 'd'
    call gset
    inc r12d
    dec ebx
    jnz .d3
    inc r12d                            ; an aisle
    jmp .dx
.dny:
    add r13d, 2
    jmp .dy
.racks:
    ; columns of server racks
    mov r12d, [rsp+0]
.rx:
    cmp r12d, [rsp+8]
    jg .done
    mov edi, [cur_f]
    mov esi, r12d
    mov edx, [rsp+4]
    mov ecx, r12d
    mov r8d, [rsp+12]
    mov r9d, 'R'
    call fill
    add r12d, 3
    jmp .rx
.pillars:
    mov r13d, [rsp+4]
.py:
    cmp r13d, [rsp+12]
    jg .done
    mov r12d, [rsp+0]
.px:
    cmp r12d, [rsp+8]
    jg .pny
    mov edi, [cur_f]
    mov esi, r12d
    mov edx, r13d
    mov ecx, 'P'
    call gset
    add r12d, 3
    jmp .px
.pny:
    add r13d, 3
    jmp .py
.done:
    EPILOGUE

; ---- layouts --------------------------------------------------------------

; chance(edi = percent) -> eax 1 that often
chance:
    PROLOGUE 16
    mov ebx, edi
    xor edi, edi
    mov esi, 99
    call rand_range
    xor ecx, ecx
    cmp eax, ebx
    setl cl
    mov eax, ecx
    EPILOGUE

; rock_around(edi=f, esi=x, edx=y) -> eax 1 if the cell and all 8 around it
; are solid rock (and it keeps off the outer wall)
rock_around:
    PROLOGUE 16
    cmp esi, 2
    jl .no
    cmp esi, MAP_W-3
    jg .no
    cmp edx, 2
    jl .no
    cmp edx, MAP_H-3
    jg .no
    lea ecx, [rsi+1]
    lea r8d, [rdx+1]
    dec esi
    dec edx
    call all_rock
    EPILOGUE
.no:
    xor eax, eax
    EPILOGUE

; carve_mazes -- in every pocket of rock left over, a depth-first maze on the
; odd grid: passages one cell wide with rock between them (and a one-cell
; skin of rock round each pocket, which punch later opens in places)
carve_mazes:
    PROLOGUE 32
    xor r12d, r12d                      ; f
.f:
    cmp r12d, NF
    jge .done
    mov [cur_f], r12d
    mov r14d, 3                         ; y (odd)
.y:
    cmp r14d, MAP_H-3
    jg .fn
    mov r13d, 3                         ; x (odd)
.x:
    cmp r13d, MAP_W-3
    jg .yn
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call rock_around
    test eax, eax
    jz .xn
    mov edi, r13d
    mov esi, r14d
    call maze_from
.xn:
    add r13d, 2
    jmp .x
.yn:
    add r14d, 2
    jmp .y
.fn:
    inc r12d
    jmp .f
.done:
    EPILOGUE

; maze_from(edi=x, esi=y) -- carve one maze starting here (storey cur_f)
maze_from:
    PROLOGUE 32
    mov r12d, edi
    mov r13d, esi
    mov edi, [cur_f]
    mov esi, r12d
    mov edx, r13d
    mov ecx, ' '
    call gset
    mov ecx, r13d
    shl ecx, 8
    or ecx, r12d
    mov [stk], ecx
    mov r15d, 1                         ; stack depth
.top:
    test r15d, r15d
    jz .done
    mov eax, [stk+r15*4-4]
    movzx r12d, al                      ; x
    shr eax, 8
    mov r13d, eax                       ; y
    xor edi, edi
    mov esi, 3
    call rand_range
    mov r14d, eax                       ; first direction to try
    xor ebx, ebx
.dir:
    cmp ebx, 4
    jge .pop
    lea eax, [r14d+ebx]
    and eax, 3
    mov ecx, [fdx+rax*4]
    mov edx, [fdy+rax*4]
    mov [rsp+0], ecx
    mov [rsp+4], edx
    lea esi, [r12d+ecx*2]               ; two cells on
    lea edx, [r13d+edx*2]
    mov [rsp+8], esi
    mov [rsp+12], edx
    mov edi, [cur_f]
    call rock_around
    test eax, eax
    jz .ndir
    ; carve the cell between and the next one, and go on from there
    mov esi, r12d
    add esi, [rsp+0]
    mov edx, r13d
    add edx, [rsp+4]
    mov edi, [cur_f]
    mov ecx, ' '
    call gset
    mov edi, [cur_f]
    mov esi, [rsp+8]
    mov edx, [rsp+12]
    mov ecx, ' '
    call gset
    mov ecx, [rsp+12]
    shl ecx, 8
    or ecx, [rsp+8]
    cmp r15d, NCELLS
    jge .done
    mov [stk+r15*4], ecx
    inc r15d
    jmp .top
.ndir:
    inc ebx
    jmp .dir
.pop:
    dec r15d
    jmp .top
.done:
    EPILOGUE

; open_halls -- big rooms with no walls, cover scattered through them
open_halls:
    PROLOGUE 32
    xor r12d, r12d
.f:
    cmp r12d, NF
    jge .done
    mov [cur_f], r12d
    mov r13d, 600
.try:
    dec r13d
    js .fn
    mov edi, 7
    mov esi, 16
    call rand_range
    mov [rsp+0], eax
    mov edi, 6
    mov esi, 11
    call rand_range
    mov [rsp+4], eax
    mov edi, 1
    mov esi, MAP_W-1
    sub esi, [rsp+0]
    call rand_range
    mov [rx0], eax
    add eax, [rsp+0]
    dec eax
    mov [rx1], eax
    mov edi, 1
    mov esi, MAP_H-1
    sub esi, [rsp+4]
    call rand_range
    mov [ry0], eax
    add eax, [rsp+4]
    dec eax
    mov [ry1], eax
    mov edi, [cur_f]
    mov esi, [rx0]
    mov edx, [ry0]
    mov ecx, [rx1]
    mov r8d, [ry1]
    call all_rock
    test eax, eax
    jz .try
    ; the floor (a skin of rock stays round it until punch opens it)
    mov edi, [cur_f]
    mov esi, [rx0]
    inc esi
    mov edx, [ry0]
    inc edx
    mov ecx, [rx1]
    dec ecx
    mov r8d, [ry1]
    dec r8d
    mov r9d, ' '
    call fill
    call mark_hall
    ; cover: crates, tall crates and pillars, every other cell, clear of
    ; the edges -- there is always a way round
    mov r15d, [ry0]
    add r15d, 2
.cy:
    mov eax, [ry1]
    sub eax, 2
    cmp r15d, eax
    jg .try
    mov r14d, [rx0]
    add r14d, 2
.cx:
    mov eax, [rx1]
    sub eax, 2
    cmp r14d, eax
    jg .cny
    mov edi, 14
    call chance
    test eax, eax
    jz .cnx
    xor edi, edi
    mov esi, 9
    call rand_range
    mov ecx, 'k'
    cmp eax, 5
    jl .put
    mov ecx, 'K'
    cmp eax, 8
    jl .put
    mov ecx, 'P'
.put:
    mov edi, [cur_f]
    mov esi, r14d
    mov edx, r15d
    call gset
.cnx:
    add r14d, 2
    jmp .cx
.cny:
    add r15d, 2
    jmp .cy
.fn:
    inc r12d
    jmp .f
.done:
    EPILOGUE

; punch(edi = percent, esi = 0 rock / 1 room walls) -- knock through walls
; that have plain floor on both sides (never safe-room walls, never into a
; shaft or onto a stair)
punch:
    PROLOGUE 32
    mov [rsp+0], edi
    mov [rsp+4], esi
    xor r12d, r12d
.f:
    cmp r12d, NF
    jge .done
    mov r14d, 1
.y:
    cmp r14d, MAP_H-2
    jg .fn
    mov r13d, 1
.x:
    cmp r13d, MAP_W-2
    jg .yn
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp dword [rsp+4], 0
    jne .walls
    cmp eax, '#'
    jne .xn
    jmp .sides
.walls:
    cmp eax, 'C'
    je .sides
    cmp eax, 'H'
    je .sides
    cmp eax, 'G'
    je .sides
    cmp eax, 'L'
    jne .xn
.sides:
    ; floor left and right, or above and below?
    mov edi, r12d
    lea esi, [r13d-1]
    mov edx, r14d
    call cell_at
    cmp eax, ' '
    jne .vertical
    mov edi, r12d
    lea esi, [r13d+1]
    mov edx, r14d
    call cell_at
    cmp eax, ' '
    je .maybe
.vertical:
    mov edi, r12d
    mov esi, r13d
    lea edx, [r14d-1]
    call cell_at
    cmp eax, ' '
    jne .xn
    mov edi, r12d
    mov esi, r13d
    lea edx, [r14d+1]
    call cell_at
    cmp eax, ' '
    jne .xn
.maybe:
    mov edi, [rsp+0]
    call chance
    test eax, eax
    jz .xn
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, ' '
    call gset
.xn:
    inc r13d
    jmp .x
.yn:
    inc r14d
    jmp .y
.fn:
    inc r12d
    jmp .f
.done:
    EPILOGUE

; raise_ceilings -- OPEN layout: wherever solid rock sits on top of open
; floor, it becomes air instead, so halls and corridors are two or three
; storeys tall and the floors above turn into balconies and ledges over them.
; Under a ledge, sometimes a tall crate (and a step crate beside it) so you
; can climb up to the next floor -- something T can't do.
raise_ceilings:
    PROLOGUE 32
    xor r12d, r12d                      ; f (the floor being opened up)
.f:
    cmp r12d, NF-1
    jge .crates
    mov r14d, 1
.y:
    cmp r14d, MAP_H-2
    jg .fn
    mov r13d, 1
.x:
    cmp r13d, MAP_W-2
    jg .yn
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, ' '
    je .open
    cmp eax, '.'                        ; (already open to the floor below)
    je .open
    cmp eax, 'k'
    je .open
    cmp eax, 'K'
    jne .xn
.open:
    lea edi, [r12d+1]
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, '#'
    jne .xn
    lea edi, [r12d+1]
    mov esi, r13d
    mov edx, r14d
    mov ecx, '.'
    call gset
.xn:
    inc r13d
    jmp .x
.yn:
    inc r14d
    jmp .y
.fn:
    inc r12d
    jmp .f
.crates:
    ; climbing points: floor under a void, next to a ledge on the floor above
    xor r12d, r12d
.cf:
    cmp r12d, NF-1
    jge .done
    mov [cur_f], r12d
    mov r14d, 2
.cy:
    cmp r14d, MAP_H-3
    jg .cfn
    mov r13d, 2
.cx:
    cmp r13d, MAP_W-3
    jg .cyn
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, ' '
    jne .cxn
    mov edi, r12d                       ; only in the open halls
    mov esi, r13d
    mov edx, r14d
    call cell_index
    cmp byte [hall+rax], 0
    je .cxn
    lea edi, [r12d+1]
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, '.'
    jne .cxn
    ; open floor all round it -- crates stand alone, so there is always a
    ; way round them (never a plugged corridor)
    call open_neighbours
    cmp eax, 8
    jl .cxn
    ; a ledge beside it upstairs?
    xor ebx, ebx
.ld:
    cmp ebx, 4
    jge .cxn
    lea edi, [r12d+1]
    mov esi, r13d
    add esi, [fdx+rbx*4]
    mov edx, r14d
    add edx, [fdy+rbx*4]
    call cell_at
    cmp eax, ' '
    je .ledge
    inc ebx
    jmp .ld
.ledge:
    mov edi, 22
    call chance
    test eax, eax
    jz .cxn
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, 'K'
    call gset
    ; a step up to it, on the side away from the ledge
    mov esi, r13d
    sub esi, [fdx+rbx*4]
    mov edx, r14d
    sub edx, [fdy+rbx*4]
    mov [rsp+0], esi
    mov [rsp+4], edx
    mov edi, r12d
    call cell_at
    cmp eax, ' '
    jne .cxn
    push r13                            ; ...and it stands alone too (apart
    push r14                            ; from the tall crate it steps up to)
    mov r13d, [rsp+16]
    mov r14d, [rsp+20]
    call open_neighbours
    pop r14
    pop r13
    cmp eax, 7
    jl .cxn
    mov edi, r12d
    mov esi, [rsp+0]
    mov edx, [rsp+4]
    mov ecx, 'k'
    call gset
.cxn:
    inc r13d
    jmp .cx
.cyn:
    inc r14d
    jmp .cy
.cfn:
    inc r12d
    jmp .cf
.done:
    EPILOGUE

; mark_hall -- remember the floor of the hall at rx0..ry1 (storey cur_f)
mark_hall:
    PROLOGUE 16
    mov r14d, [ry0]
    inc r14d
.y:
    mov eax, [ry1]
    dec eax
    cmp r14d, eax
    jg .done
    mov r13d, [rx0]
    inc r13d
.x:
    mov eax, [rx1]
    dec eax
    cmp r13d, eax
    jg .ny
    mov edi, [cur_f]
    mov esi, r13d
    mov edx, r14d
    call cell_index
    mov byte [hall+rax], 1
    inc r13d
    jmp .x
.ny:
    inc r14d
    jmp .y
.done:
    EPILOGUE

; open_neighbours(r12d=f, r13d=x, r14d=y) -> eax = how many of the 8 cells
; around are plain floor
open_neighbours:
    PROLOGUE 16
    xor ebx, ebx                        ; count
    mov r15d, -1                        ; dy
.dy:
    cmp r15d, 1
    jg .done
    mov dword [rsp+0], -1               ; dx
.dx:
    cmp dword [rsp+0], 1
    jg .ndy
    mov edi, r12d
    mov esi, r13d
    add esi, [rsp+0]
    lea edx, [r14d+r15d]
    call cell_at
    cmp eax, ' '
    jne .ndx
    inc ebx
.ndx:
    inc dword [rsp+0]
    jmp .dx
.ndy:
    inc r15d
    jmp .dy
.done:
    mov eax, ebx
    EPILOGUE

; flood_from_start -- walk everywhere a person can from the start cell
; (same storey neighbours, and up/down stairs like T's path finding); open
; cells that were never reached become rock
flood_from_start:
    PROLOGUE 32
    lea rdi, [reach]
    xor esi, esi
    mov edx, NCELLS
    call memset
    mov eax, (1*MAP_H + 1)*MAP_W + 1    ; ground floor (1,1)
    mov byte [reach+rax], 1
    mov [queue], eax
    xor r14d, r14d                      ; head
    mov r15d, 1                         ; tail
.pop:
    cmp r14d, r15d
    jge .sweep
    mov eax, [queue+r14*4]
    inc r14d
    mov [rsp+0], eax                    ; id
    xor edx, edx
    mov ecx, MAP_W
    div ecx
    mov [rsp+4], edx                    ; x
    xor edx, edx
    mov ecx, MAP_H
    div ecx
    mov [rsp+8], eax                    ; f
    mov [rsp+12], edx                   ; y
    xor ebx, ebx
.dir:
    cmp ebx, 4
    jge .pop
    mov r12d, [rsp+4]
    add r12d, [fdx+rbx*4]
    mov r13d, [rsp+12]
    add r13d, [fdy+rbx*4]
    mov edi, [rsp+8]
    mov esi, r12d
    mov edx, r13d
    call cell_at
    cmp eax, '.'
    je .shaft_up
    test byte [char_class+rax], CF_OPEN
    jz .up
    call .solid_furniture               ; desks and crates: go round, like T
    jz .ndir
    mov edi, [rsp+8]
    mov esi, r12d
    mov edx, r13d
    call cell_index
    call .visit
    jmp .ndir
.up:
    ; the top step of a stair leads onto the storey above
    mov ecx, [rsp+0]
    movzx eax, byte [grid+rcx]
    test byte [char_class+rax], CF_STAIR
    jz .ndir
    cmp byte [st_top+rcx], 1
    jne .ndir
    movsx eax, byte [st_dx+rcx]
    cmp eax, [fdx+rbx*4]
    jne .ndir
    movsx eax, byte [st_dy+rcx]
    cmp eax, [fdy+rbx*4]
    jne .ndir
    mov edi, [rsp+8]
    inc edi
    mov esi, r12d
    mov edx, r13d
    call cell_at
    test byte [char_class+rax], CF_OPEN
    jz .ndir
    mov edi, [rsp+8]
    inc edi
    mov esi, r12d
    mov edx, r13d
    call cell_index
    call .visit
    jmp .ndir
.shaft_up:
    ; open air this way -- but a stair's top step still leads up past it
    ; (tall ceilings can leave a void right beside the top of a stair)
    mov ecx, [rsp+0]
    movzx eax, byte [grid+rcx]
    test byte [char_class+rax], CF_STAIR
    jz .shaft
    cmp byte [st_top+rcx], 1
    jne .shaft
    movsx eax, byte [st_dx+rcx]
    cmp eax, [fdx+rbx*4]
    jne .shaft
    movsx eax, byte [st_dy+rcx]
    cmp eax, [fdy+rbx*4]
    jne .shaft
    mov edi, [rsp+8]
    inc edi
    mov esi, r12d
    mov edx, r13d
    call cell_at
    test byte [char_class+rax], CF_OPEN
    jz .shaft
    mov edi, [rsp+8]
    inc edi
    mov esi, r12d
    mov edx, r13d
    call cell_index
    call .visit
.shaft:
    ; a landing beside a shaft leads down onto the top step below it
    mov edi, [rsp+8]
    dec edi
    mov esi, r12d
    mov edx, r13d
    call cell_at
    test byte [char_class+rax], CF_STAIR
    jz .ndir
    mov edi, [rsp+8]
    dec edi
    mov esi, r12d
    mov edx, r13d
    call cell_index
    cmp byte [st_top+rax], 1
    jne .ndir
    call .visit
.ndir:
    inc ebx
    jmp .dir
.sweep:
    ; seal what nobody can reach (keep shafts, they have nothing to stand on)
    xor ecx, ecx
.s:
    cmp ecx, NCELLS
    jge .done
    cmp byte [reach+rcx], 0
    jne .sn
    movzx eax, byte [grid+rcx]
    cmp eax, '.'
    je .sn
    call .solid_furniture               ; (keep the furniture itself)
    jz .sn
    test byte [char_class+rax], CF_OPEN
    jz .sn
    mov byte [grid+rcx], '#'
.sn:
    inc ecx
    jmp .s
.done:
    EPILOGUE
; .solid_furniture(eax=char) -> ZF set for a desk or crate. leaf
.solid_furniture:
    cmp eax, 'd'
    je .sf
    cmp eax, 'k'
    je .sf
    cmp eax, 'K'
.sf:
    ret
; .visit(eax=id) -- queue it if new (a local helper: uses r15, the tail)
.visit:
    cmp byte [reach+rax], 0
    jne .seen
    mov byte [reach+rax], 1
    mov [queue+r15*4], eax
    inc r15d
.seen:
    ret
