; =============================================================================
; world.asm -- the grid world: loading the three floor maps, classifying map
; characters, stair ramps, ground height, collision and line of sight.
;
; The map is stored as one flat byte array:
;     grid[(f*MAP_H + y)*MAP_W + x]
; and that same index doubles as T's path-finding node id (see ai.asm).
;
; Map legend (same as board.txt, plus the 3D additions):
;   ' ' floor      S safe-room floor (T can never enter)
;   d  desk (waist high: stand on it, vault it)
;   k  crate, K  tall crate stack (climb them: mantle up)
;   #  concrete    H hallway block   C classroom wall   G gym wall
;   L  library     N safe-room wall  d desk   R server rack   P pillar
;   Y  Y's cage    B B, the lord of networking
;   ^ v < >  stairs -- the arrow points in the direction the stair RISES
;   .  open shaft (no floor) above a stair on the floor below
; =============================================================================
%define MODULE_WORLD
%include "common.inc"

global grid, char_class, world_init, cell_at, cell_index, ground_height, collides
global floor_of_height, line_of_sight, stair_t, open_cells, open_count
global node_center, node_at_pos, st_dx, st_dy, st_len, st_top, st_edge, rand01
global rng_seed, rng_next
global nav_x, nav_y, nav_z, nav_count, link_head, link_next, link_to, link_type, nav_t_mask
global node_walkable, line_of_sight_3d, sound_occlusion, dist3, link_count
global classic_grid, compute_stairs, world_select, real_grid, cur_set
global start_f, start_x, start_y, start_yaw
global w_nf, w_w, w_h, w_w1, w_w2, w_w3, w_w7, w_h1, w_h2, w_h3, w_nf1, set_dims
extern sign_set_cur
extern worldgen_generate, worldgen_custom, cfg_floors, cfg_width, cfg_depth
global plat_count, plat_x0, plat_x1, plat_z0, plat_z1, plat_ya, plat_yb, plat_axis, plat_thick
global plat_style, plat_inside, plat_height, slab_cross

%define NODE(f,x,y) (((f)*MAP_H + (y))*MAP_W + (x))
%define XN(i) (NCELLS + (i))

section .data
; -----------------------------------------------------------------------------
; "The Stack" -- the three-storey atrium. Over the basement pillar hall the
; ground and 2nd floors are open ('.' at grid x 33..35, y 18..22, which is
; world X 66..72, Z 36..46), so you can look down two storeys. Inside it:
;   ramp A   along the west edge, ground-floor balcony (y 3.2) up to...
;   the bridge across the void at half-storey height (y 4.8), and
;   ramp B   along the east edge, up to the 2nd-floor server room (y 6.4).
; Walk off any edge and you land in the basement (loudly).
;
; platform: x0, x1, z0, z1, height at the low end, height at the high end,
;           slope axis (0 flat, 1 along X, 2 along Z), slab thickness, style
plat_def:
    dd 66.0, 67.4, 40.0, 46.0, 4.8, 3.2, 2, 0.2, PS_CONCRETE    ; ramp A
    dd 66.0, 72.0, 38.6, 40.0, 4.8, 4.8, 0, 0.2, PS_CONCRETE    ; the bridge
    dd 70.6, 72.0, 40.0, 46.0, 4.8, 6.4, 2, 0.2, PS_CONCRETE    ; ramp B
%define NPLAT_DEF 3

; free waypoints (world X, feet Y, Z): node ids XN(0), XN(1), ...
xnode_def:
    dd 66.7, 3.733, 44.0                ; 0 ramp A, low
    dd 66.7, 4.267, 42.0                ; 1 ramp A, high
    dd 66.7, 4.8,   39.3                ; 2 bridge, west end
    dd 69.0, 4.8,   39.3                ; 3 bridge, middle
    dd 71.3, 4.8,   39.3                ; 4 bridge, east end
    dd 71.3, 5.333, 42.0                ; 5 ramp B, low
    dd 71.3, 5.867, 44.0                ; 6 ramp B, high
%define NXNODE_DEF 7
; authored links: from, to, type (walk and ladder links go both ways)
xlink_def:
    dd NODE(1,33,23), XN(0), LK_WALK    ; south balcony -> ramp A
    dd XN(0), XN(1), LK_WALK
    dd XN(1), XN(2), LK_WALK
    dd XN(2), XN(3), LK_WALK
    dd XN(3), XN(4), LK_WALK
    dd XN(4), XN(5), LK_WALK
    dd XN(5), XN(6), LK_WALK
    dd XN(6), NODE(2,35,23), LK_WALK    ; ramp B -> server room
    dd XN(3), NODE(0,34,19), LK_DROP    ; off the bridge into the basement
%define NXLINK_DEF 9

; blocks standing in grid cells: char, half width X, half depth Z, height, style
block_kinds:
    dd 'd', 0.75, 0.40, 0.77, PS_HIDDEN     ; desk (render.asm draws the desk itself)
    dd 'k', 0.80, 0.80, 1.00, PS_CRATE      ; crate
    dd 'K', 0.80, 0.80, 1.90, PS_CRATE      ; tall crate stack
%define NBLOCK_KINDS 3

; -----------------------------------------------------------------------------
; The real Beacom Institute of Technology (maps/beacom/, tools/beacom_map.js)
;
; The grand staircase at the south end of the collaboration space: wide
; wooden steps that double as bleachers, rising south from the 1st floor
; (y 3.2) to a stage halfway up (y 4.8), then on up to the 2nd floor (y 6.4)
; at the south corridor (z 46). 16 m wide (world X 48..64 = grid x 24..31).
; Every step is solid down to the floor; the floor cells under it are 'b'.
plat_real:
    dd 48.0, 64.0, 40.0, 40.5, 3.6, 3.6, 0, 0.4, PS_CRATE    ; steps up to the stage
    dd 48.0, 64.0, 40.5, 41.0, 4.0, 4.0, 0, 0.8, PS_CRATE
    dd 48.0, 64.0, 41.0, 41.5, 4.4, 4.4, 0, 1.2, PS_CRATE
    dd 48.0, 64.0, 41.5, 42.0, 4.8, 4.8, 0, 1.6, PS_CRATE
    dd 48.0, 64.0, 42.0, 44.0, 4.8, 4.8, 0, 1.6, PS_CRATE    ; the stage, halfway up
    dd 48.0, 64.0, 44.0, 44.5, 5.2, 5.2, 0, 2.0, PS_CRATE    ; on up to the 2nd floor
    dd 48.0, 64.0, 44.5, 45.0, 5.6, 5.6, 0, 2.4, PS_CRATE
    dd 48.0, 64.0, 45.0, 45.5, 6.0, 6.0, 0, 2.8, PS_CRATE
    dd 48.0, 64.0, 45.5, 46.0, 6.4, 6.4, 0, 3.2, PS_CRATE
%define NPLAT_REAL 9

; T's way up the grand staircase: five lanes across it (so wherever you are
; on the steps, a waypoint is near you), each foot -> low steps -> stage ->
; high steps -> 2nd floor, and the stage joins the lanes sideways
%macro STAIR_LANE 1   ; world X
    dd %1, 4.0, 40.75                   ; the low steps
    dd %1, 4.8, 43.0                    ; the stage
    dd %1, 5.6, 44.75                   ; the high steps
%endmacro
xnode_real:
    STAIR_LANE 49.0
    STAIR_LANE 53.0
    STAIR_LANE 57.0
    STAIR_LANE 61.0
    STAIR_LANE 63.0
%define NXNODE_REAL 15
%macro LANE_LINKS 2   ; grid x, first waypoint
    dd NODE(1,%1,19), XN(%2), LK_WALK
    dd XN(%2), XN(%2+1), LK_WALK
    dd XN(%2+1), XN(%2+2), LK_WALK
    dd XN(%2+2), NODE(2,%1,23), LK_WALK
%endmacro
xlink_real:
    LANE_LINKS 24, 0
    LANE_LINKS 26, 3
    LANE_LINKS 28, 6
    LANE_LINKS 30, 9
    LANE_LINKS 31, 12
    dd XN(1), XN(4), LK_WALK            ; across the stage
    dd XN(4), XN(7), LK_WALK
    dd XN(7), XN(10), LK_WALK
    dd XN(10), XN(13), LK_WALK
%define NXLINK_REAL 24

; ziplines: A (x, y, z) -> B, high end first
zip_original:
    dd 111.0, 2.95, 53.0,   7.0, 2.55, 53.0     ; basement corridor
    dd 7.0, 6.15, 29.0,     111.0, 5.75, 29.0   ; ground-floor corridor
    dd 7.0, 9.35, 5.0,      111.0, 8.95, 5.0    ; 2nd-floor corridor
    dd 85.0, 9.35, 37.0,    63.0, 5.75, 37.0    ; down across the atrium
zip_real:
    ; from the 2nd-floor north balcony, down across the collaboration space
    ; to the stage on the grand staircase (not real -- but it should be)
    dd 45.0, 9.35, 17.0,    50.0, 7.35, 43.0

; where you start: storey, grid x, grid y, facing (yaw)
;   original: the first room; real: inside the glass entry, facing the media wall
set_start   dd 1, 1, 1, -2.3561945
            dd 1, 22, 15, -1.5707963
            dd 1, 1, 1, -2.3561945          ; custom: the start room, like the original

; per building set (SET_ORIGINAL, SET_REAL)
align 8
set_plat    dq plat_def, plat_real, plat_def
set_xnode   dq xnode_def, xnode_real, xnode_def
set_xlink   dq xlink_def, xlink_real, xlink_def
set_zip     dq zip_original, zip_real, zip_original
set_plat_n  dd NPLAT_DEF, NPLAT_REAL, 0
set_xnode_n dd NXNODE_DEF, NXNODE_REAL, 0
set_xlink_n dd NXLINK_DEF, NXLINK_REAL, 0
set_zip_n   dd 4, 1, 0

c_hear_slab dd 6.0        ; a floor/ceiling slab muffles sound like 6m of air
c_hear_wall dd 0.75       ; ...each half metre of solid wall like 0.75m
c_los3_step dd 0.25
c_snd_step  dd 0.5
c_xn_reach  dd 2.1        ; how close (horizontally) you must be to a waypoint
c_xn_dy     dd 0.9
; the four grid directions, in ladder_dir order: +x, -x, +y, -y
dir4_dx     dd 1, -1, 0, 0
dir4_dy     dd 0, 0, 1, -1
map_name0   db "maps/original/basement.txt",0
map_name1   db "maps/original/ground.txt",0
map_name2   db "maps/original/second.txt",0
map_real0   db "maps/beacom/basement.txt",0
map_real1   db "maps/beacom/ground.txt",0
map_real2   db "maps/beacom/second.txt",0
align 8
map_names   dq map_name0, map_name1, map_name2
map_names_real dq map_real0, map_real1, map_real2
mode_r      db "r",0
err_map     db "Could not open %s -- run the game from the beacom3d_asm directory.",10,0

c_step_bias dd 0.25       ; body starts this far above the feet (so stairs don't block)
c_fh_bias   dd 0.6        ; floor_of_height rounding bias
c_los_step  dd 0.5        ; line-of-sight sample spacing (world units)

section .bss
grid        resb NCELLS
classic_grid resb NCELLS  ; the original game's map (maps/original/)
real_grid   resb NCELLS   ; the real Beacom Institute of Technology (maps/beacom/)
cur_set     resd 1        ; SET_ORIGINAL / SET_REAL / SET_CUSTOM: whose platforms, nav, zips...
w_nf        resd 1        ; this building: storeys...
w_w         resd 1        ; ...width and depth in cells
w_h         resd 1
w_w1        resd 1        ; (w_w - 1 ... handy bounds for the generators)
w_w2        resd 1
w_w3        resd 1
w_w7        resd 1
w_h1        resd 1
w_h2        resd 1
w_h3        resd 1
w_nf1       resd 1
start_f     resd 1        ; where you start in this building
start_x     resd 1
start_y     resd 1
start_yaw   resd 1
char_class  resb 256
; per-cell stair info (only meaningful where the cell is a stair)
st_dx       resb NCELLS   ; signed direction the stair rises (+1/-1/0)
st_dy       resb NCELLS
st_len      resb NCELLS   ; number of cells in this run
st_top      resb NCELLS   ; 1 if this is the top cell of its run
alignb 4
st_edge     resd NCELLS   ; world coordinate (X or Z) where the ramp height is 0
open_cells  resd NCELLS   ; node ids of every plain ' ' floor cell
open_count  resd 1
rng_state   resd 1
; the navigation graph
nav_x       resd NNODES   ; world position of every node (feet height)
nav_y       resd NNODES
nav_z       resd NNODES
nav_count   resd 1        ; NCELLS + free waypoints in use
link_head   resd NNODES   ; first link leaving each node, -1 none
link_next   resd MAX_LINKS
link_to     resd MAX_LINKS
link_type   resd MAX_LINKS
link_count  resd 1
nav_t_mask  resd 1        ; bit per LK_ type that T may use
; walkable platforms and ramps
plat_count  resd 1
plat_x0     resd MAX_PLAT
plat_x1     resd MAX_PLAT
plat_z0     resd MAX_PLAT
plat_z1     resd MAX_PLAT
plat_ya     resd MAX_PLAT
plat_yb     resd MAX_PLAT
plat_axis   resd MAX_PLAT
plat_thick  resd MAX_PLAT
plat_style  resd MAX_PLAT

section .text

; -----------------------------------------------------------------------------
; The game's own random numbers (xorshift32). The original used libc
; srand/rand; ours behaves the same on Linux and Windows (whose rand() only
; goes up to 32767), so a seed replays the same game everywhere.
; rng_seed(edi=seed)   rng_next() -> eax in 0 .. 2^31-1   (both leaf)
; -----------------------------------------------------------------------------
rng_seed:
    imul edi, edi, 0x9E3779B1           ; spread small seeds over all bits
    add edi, 0x6D2B79F5
    jnz .ok
    inc edi                             ; xorshift must never be 0
.ok:
    mov [rng_state], edi
    ret

rng_next:
    mov eax, [rng_state]
    mov ecx, eax
    shl ecx, 13
    xor eax, ecx
    mov ecx, eax
    shr ecx, 17
    xor eax, ecx
    mov ecx, eax
    shl ecx, 5
    xor eax, ecx
    mov [rng_state], eax
    shr eax, 1
    ret

; -----------------------------------------------------------------------------
; rand01() -> xmm0 = uniform float in [0,1)
; -----------------------------------------------------------------------------
rand01:
    sub rsp, 8
    call rng_next
    cvtsi2ss xmm0, eax
    mulss xmm0, [c_inv_rand]
    add rsp, 8
    ret

; -----------------------------------------------------------------------------
; cell_index(edi=f, esi=x, edx=y) -> eax = flat index (no bounds check). leaf.
; -----------------------------------------------------------------------------
cell_index:
    imul eax, edi, MAP_H
    add eax, edx
    imul eax, eax, MAP_W
    add eax, esi
    ret

; -----------------------------------------------------------------------------
; cell_at(edi=f, esi=x, edx=y) -> eax = map character, '#' when out of bounds.
; leaf; clobbers only eax.
; -----------------------------------------------------------------------------
cell_at:
    cmp edi, 0
    jl .oob
    cmp edi, NF
    jge .oob
    cmp esi, 0
    jl .oob
    cmp esi, MAP_W
    jge .oob
    cmp edx, 0
    jl .oob
    cmp edx, MAP_H
    jge .oob
    imul eax, edi, MAP_H
    add eax, edx
    imul eax, eax, MAP_W
    add eax, esi
    movzx eax, byte [grid+rax]
    ret
.oob:
    mov eax, '#'
    ret

; -----------------------------------------------------------------------------
; world_init() -- build the char class table, load the maps, analyse stairs,
; and collect the list of open floor cells used for random spawning.
; -----------------------------------------------------------------------------
world_init:
    PROLOGUE 16
    ; ---- character classes
    lea rdi, [char_class]
    xor esi, esi
    mov edx, 256
    call memset
    lea rbx, [char_class]
    mov byte [rbx+'#'], CF_WALL
    mov byte [rbx+'H'], CF_WALL
    mov byte [rbx+'C'], CF_WALL
    mov byte [rbx+'G'], CF_WALL
    mov byte [rbx+'L'], CF_WALL
    mov byte [rbx+'N'], CF_WALL
    mov byte [rbx+' '], CF_OPEN | CF_TWALK | CF_FLAT | CF_SIGHT
    mov byte [rbx+'S'], CF_OPEN | CF_FLAT | CF_SIGHT
    mov byte [rbx+'.'], CF_OPEN | CF_SIGHT
    mov byte [rbx+'^'], CF_STAIR | CF_OPEN | CF_TWALK | CF_SIGHT
    mov byte [rbx+'v'], CF_STAIR | CF_OPEN | CF_TWALK | CF_SIGHT
    mov byte [rbx+'<'], CF_STAIR | CF_OPEN | CF_TWALK | CF_SIGHT
    mov byte [rbx+'>'], CF_STAIR | CF_OPEN | CF_TWALK | CF_SIGHT
    ; desks and crates: floor you can walk round, with a solid block on it
    ; (grid_platforms) that you can stand on, mantle onto and vault over
    mov byte [rbx+'d'], CF_OPEN | CF_FLAT | CF_SIGHT
    mov byte [rbx+'k'], CF_OPEN | CF_FLAT | CF_SIGHT
    mov byte [rbx+'K'], CF_OPEN | CF_FLAT | CF_SIGHT
    mov byte [rbx+'B'], CF_SIGHT
    mov byte [rbx+'u'], CF_OPEN | CF_TWALK | CF_FLAT | CF_SIGHT   ; foot of a ladder

    ; glass: a wall you can see through; the media wall; the floor under the
    ; grand staircase (solid steps sit on it: nothing spawns there)
    mov byte [rbx+'g'], CF_WALL | CF_SIGHT
    mov byte [rbx+'W'], CF_WALL
    mov byte [rbx+'b'], CF_OPEN | CF_FLAT | CF_SIGHT

    lea rdi, [map_names_real]
    call load_maps
    lea rdi, [real_grid]
    lea rsi, [grid]
    mov edx, NCELLS
    call memcpy
    lea rdi, [map_names]
    call load_maps
    lea rdi, [classic_grid]
    lea rsi, [grid]
    mov edx, NCELLS
    call memcpy
    mov edi, BLD_ORIGINAL
    xor esi, esi
    call world_select
    EPILOGUE

; -----------------------------------------------------------------------------
; world_select(edi = BLD_REAL / BLD_GENERATED / BLD_ORIGINAL, esi = seed) --
; put that building in grid and re-derive everything from it: its stairs,
; platforms, nav graph, spawn list, ziplines, start and signs
; -----------------------------------------------------------------------------
world_select:
    PROLOGUE 16
    mov ebx, edi
    mov r12d, esi
    mov edi, FILE_NF                    ; the hand-made size...
    mov esi, FILE_W
    mov edx, FILE_H
    call set_dims
    mov dword [cur_set], SET_ORIGINAL   ; generated buildings keep its landmarks
    cmp ebx, BLD_CUSTOM
    je .custom
    mov esi, r12d
    cmp ebx, BLD_GENERATED
    je .generate
    lea rsi, [classic_grid]
    cmp ebx, BLD_REAL
    jne .copy
    mov dword [cur_set], SET_REAL
    lea rsi, [real_grid]
.copy:
    lea rdi, [grid]
    mov edx, NCELLS
    call memcpy
    jmp .analyse
.generate:
    mov edi, esi
    call worldgen_generate
    jmp .analyse
.custom:
    ; ...or whatever size the custom run asks for
    mov dword [cur_set], SET_CUSTOM
    mov edi, [cfg_floors]
    mov esi, [cfg_width]
    mov edx, [cfg_depth]
    call set_dims
    mov edi, r12d
    call worldgen_custom
.analyse:
    call world_analyse
    ; this building's ziplines, start and signs
    mov eax, [cur_set]
    mov ecx, [set_zip_n+rax*4]
    mov [zip_count], ecx
    mov rsi, [set_zip+rax*8]
    xor edx, edx
.zip:
    cmp edx, ecx
    jge .zips_done
    imul r8d, edx, 24
    mov r9d, [rsi+r8+0]
    mov [zip_ax+rdx*4], r9d
    mov r9d, [rsi+r8+4]
    mov [zip_ay+rdx*4], r9d
    mov r9d, [rsi+r8+8]
    mov [zip_az+rdx*4], r9d
    mov r9d, [rsi+r8+12]
    mov [zip_bx+rdx*4], r9d
    mov r9d, [rsi+r8+16]
    mov [zip_by+rdx*4], r9d
    mov r9d, [rsi+r8+20]
    mov [zip_bz+rdx*4], r9d
    inc edx
    jmp .zip
.zips_done:
    imul ecx, eax, 16
    lea rsi, [set_start+rcx]
    mov edx, [rsi+0]
    mov [start_f], edx
    mov edx, [rsi+4]
    mov [start_x], edx
    mov edx, [rsi+8]
    mov [start_y], edx
    mov edx, [rsi+12]
    mov [start_yaw], edx
    mov [sign_set_cur], eax             ; its room signs...
    cmp ebx, BLD_GENERATED
    je .no_signs
    cmp ebx, BLD_CUSTOM
    jne .signs
.no_signs:
    mov dword [sign_set_cur], -1        ; ...a generated building has none
.signs:
    EPILOGUE

; set_dims(edi = storeys, esi = width, edx = depth) -- this building's size
; (clamped to the grid)
set_dims:
    cmp edi, 2
    jge .f1
    mov edi, 2
.f1:
    cmp edi, NF
    jle .f2
    mov edi, NF
.f2:
    cmp esi, 20
    jge .w1
    mov esi, 20
.w1:
    cmp esi, MAP_W
    jle .w2
    mov esi, MAP_W
.w2:
    cmp edx, 16
    jge .h1
    mov edx, 16
.h1:
    cmp edx, MAP_H
    jle .h2
    mov edx, MAP_H
.h2:
    mov [w_nf], edi
    lea eax, [rdi-1]
    mov [w_nf1], eax
    mov [w_w], esi
    lea eax, [rsi-1]
    mov [w_w1], eax
    lea eax, [rsi-2]
    mov [w_w2], eax
    lea eax, [rsi-3]
    mov [w_w3], eax
    lea eax, [rsi-7]
    mov [w_w7], eax
    mov [w_h], edx
    lea eax, [rdx-1]
    mov [w_h1], eax
    lea eax, [rdx-2]
    mov [w_h2], eax
    lea eax, [rdx-3]
    mov [w_h3], eax
    ret

; world_analyse -- stairs, platforms, the nav graph and the spawn list
world_analyse:
    PROLOGUE 16
    call compute_stairs
    call load_platforms
    call grid_platforms
    call build_nav

    ; ---- open_cells = every ' ' cell (spawn points for items and T)
    xor ecx, ecx
    xor edx, edx
.oc_loop:
    cmp ecx, NCELLS
    jge .oc_done
    cmp byte [grid+rcx], ' '
    jne .oc_next
    mov [open_cells+rdx*4], ecx
    inc edx
.oc_next:
    inc ecx
    jmp .oc_loop
.oc_done:
    mov [open_count], edx
    EPILOGUE

; -----------------------------------------------------------------------------
; load_maps(rdi = file names) -- read 3 map files, 31 rows of 59 chars each. Line endings may be
; LF or CRLF (a Windows checkout converts them), so after each row we skip
; everything up to and including '\n' -- same trick as doom.asm.
; -----------------------------------------------------------------------------
load_maps:
    PROLOGUE 16
    mov r15, rdi                        ; r15 = the three file names
    lea rdi, [grid]                     ; (outside the map: solid rock)
    mov esi, '#'
    mov edx, NCELLS
    call memset
    xor r12d, r12d                      ; r12 = floor
.floor_loop:
    cmp r12d, FILE_NF
    jge .done
    mov rdi, [r15+r12*8]
    lea rsi, [mode_r]
    call fopen
    test rax, rax
    jnz .opened
    lea rdi, [err_map]
    mov rsi, [r15+r12*8]
    xor eax, eax
    call printf
    mov edi, 1
    call exit
.opened:
    mov r13, rax                        ; r13 = FILE*
    xor r14d, r14d                      ; r14 = row
.row_loop:
    cmp r14d, FILE_H
    jge .close
    ; dest = grid + (f*MAP_H + row)*MAP_W
    imul eax, r12d, MAP_H
    add eax, r14d
    imul eax, eax, MAP_W
    lea rdi, [grid]
    add rdi, rax
    mov esi, 1
    mov edx, FILE_W
    mov rcx, r13
    call fread
.eol:
    mov rdi, r13
    call fgetc
    cmp eax, 10
    je .eol_done
    cmp eax, -1
    je .eol_done
    jmp .eol
.eol_done:
    inc r14d
    jmp .row_loop
.close:
    mov rdi, r13
    call fclose
    inc r12d
    jmp .floor_loop
.done:
    EPILOGUE

; -----------------------------------------------------------------------------
; compute_stairs() -- for every stair cell find its run (the contiguous line of
; the same arrow character along the rise direction) and remember
;   st_dx/st_dy  direction of rise
;   st_len       run length in cells
;   st_edge      world X or Z of the bottom edge of the run (height 0 there)
;   st_top       1 for the last cell of the run (connects to the floor above)
; -----------------------------------------------------------------------------
compute_stairs:
    PROLOGUE 32
    ; locals: [rsp+0] dx, [rsp+4] dy, [rsp+8] char, [rsp+12] bx, [rsp+16] by
    ;         [rsp+20] len, [rsp+24] tx, [rsp+28] ty
    xor r12d, r12d                      ; f
.f_loop:
    cmp r12d, NF
    jge .done
    xor r14d, r14d                      ; y
.y_loop:
    cmp r14d, MAP_H
    jge .f_next
    xor r13d, r13d                      ; x
.x_loop:
    cmp r13d, MAP_W
    jge .y_next
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_at
    mov [rsp+8], eax
    movzx ecx, byte [char_class+rax]
    test ecx, CF_STAIR
    jz .x_next
    ; direction from the arrow
    mov dword [rsp+0], 0
    mov dword [rsp+4], 0
    cmp eax, '^'
    jne .n1
    mov dword [rsp+4], -1
.n1:
    cmp eax, 'v'
    jne .n2
    mov dword [rsp+4], 1
.n2:
    cmp eax, '<'
    jne .n3
    mov dword [rsp+0], -1
.n3:
    cmp eax, '>'
    jne .n4
    mov dword [rsp+0], 1
.n4:
    ; walk back to the bottom of the run
    mov [rsp+12], r13d
    mov [rsp+16], r14d
.back:
    mov esi, [rsp+12]
    sub esi, [rsp+0]
    mov edx, [rsp+16]
    sub edx, [rsp+4]
    mov edi, r12d
    call cell_at
    cmp eax, [rsp+8]
    jne .back_done
    mov eax, [rsp+0]
    sub [rsp+12], eax
    mov eax, [rsp+4]
    sub [rsp+16], eax
    jmp .back
.back_done:
    ; walk forward counting the run
    mov dword [rsp+20], 0
    mov eax, [rsp+12]
    mov [rsp+24], eax
    mov eax, [rsp+16]
    mov [rsp+28], eax
.fwd:
    mov edi, r12d
    mov esi, [rsp+24]
    mov edx, [rsp+28]
    call cell_at
    cmp eax, [rsp+8]
    jne .fwd_done
    inc dword [rsp+20]
    mov eax, [rsp+0]
    add [rsp+24], eax
    mov eax, [rsp+4]
    add [rsp+28], eax
    jmp .fwd
.fwd_done:
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_index
    mov ebx, eax                        ; ebx = this cell's index
    mov ecx, [rsp+0]
    mov [st_dx+rbx], cl
    mov ecx, [rsp+4]
    mov [st_dy+rbx], cl
    mov ecx, [rsp+20]
    mov [st_len+rbx], cl
    ; top cell?  (tx-dx == x && ty-dy == y)
    mov byte [st_top+rbx], 0
    mov eax, [rsp+24]
    sub eax, [rsp+0]
    cmp eax, r13d
    jne .not_top
    mov eax, [rsp+28]
    sub eax, [rsp+4]
    cmp eax, r14d
    jne .not_top
    mov byte [st_top+rbx], 1
.not_top:
    ; bottom edge in world units
    cmp dword [rsp+0], 1
    jne .e1
    mov eax, [rsp+12]                   ; +x: edge = bx*CELL
    jmp .edge_set
.e1:
    cmp dword [rsp+0], -1
    jne .e2
    mov eax, [rsp+12]                   ; -x: edge = (bx+1)*CELL
    inc eax
    jmp .edge_set
.e2:
    cmp dword [rsp+4], 1
    jne .e3
    mov eax, [rsp+16]                   ; +y: edge = by*CELL
    jmp .edge_set
.e3:
    mov eax, [rsp+16]                   ; -y: edge = (by+1)*CELL
    inc eax
.edge_set:
    cvtsi2ss xmm0, eax
    mulss xmm0, [c_cell]
    movss [st_edge+rbx*4], xmm0
.x_next:
    inc r13d
    jmp .x_loop
.y_next:
    inc r14d
    jmp .y_loop
.f_next:
    inc r12d
    jmp .f_loop
.done:
    EPILOGUE

; -----------------------------------------------------------------------------
; stair_t(edi=cell index, xmm0=X, xmm1=Z) -> xmm0 = 0..1, how far up the stair
; the point is. Heights on a stair are a smooth ramp. leaf.
; -----------------------------------------------------------------------------
stair_t:
    movsx ecx, byte [st_dx+rdi]
    movsx edx, byte [st_dy+rdi]
    movss xmm2, [st_edge+rdi*4]
    cmp ecx, 1
    jne .a
    subss xmm0, xmm2                    ; X - edge
    jmp .have
.a:
    cmp ecx, -1
    jne .b
    subss xmm2, xmm0                    ; edge - X
    movaps xmm0, xmm2
    jmp .have
.b:
    cmp edx, 1
    jne .c
    subss xmm1, xmm2                    ; Z - edge
    movaps xmm0, xmm1
    jmp .have
.c:
    subss xmm2, xmm1                    ; edge - Z
    movaps xmm0, xmm2
.have:
    movzx ecx, byte [st_len+rdi]
    cvtsi2ss xmm3, ecx
    mulss xmm3, [c_cell]                ; run length in world units
    divss xmm0, xmm3
    maxss xmm0, [c_zero]
    minss xmm0, [c_one]
    ret

; -----------------------------------------------------------------------------
; ground_height(xmm0=X, xmm1=Z, xmm2=feetY, xmm3=step) -> xmm0
; Height of the highest walkable surface under (X,Z) that is not more than
; `step` above the feet: flat floors of every storey and stair ramps.
; Returns -1e30 if there is nothing (never happens inside the building).
; -----------------------------------------------------------------------------
ground_height:
    PROLOGUE 32
    ; [rsp+0] X  [rsp+4] Z  [rsp+8] limit  [rsp+12] best
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    addss xmm2, xmm3
    movss [rsp+8], xmm2
    movss xmm4, [c_neg_big]
    movss [rsp+12], xmm4
    mulss xmm0, [c_inv_cell]
    cvttss2si r12d, xmm0                ; gx
    mulss xmm1, [c_inv_cell]
    cvttss2si r13d, xmm1                ; gy
    xor ebx, ebx                        ; f
.loop:
    cmp ebx, NF
    jge .done
    mov edi, ebx
    mov esi, r12d
    mov edx, r13d
    call cell_at
    movzx ecx, byte [char_class+rax]
    test ecx, CF_FLAT
    jz .not_flat
    cvtsi2ss xmm0, ebx
    mulss xmm0, [c_fh]                  ; h = f*FH
    jmp .candidate
.not_flat:
    test ecx, CF_STAIR
    jz .next
    mov edi, ebx
    mov esi, r12d
    mov edx, r13d
    call cell_index
    mov edi, eax
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    call stair_t
    mulss xmm0, [c_fh]
    cvtsi2ss xmm1, ebx
    mulss xmm1, [c_fh]
    addss xmm0, xmm1                    ; h = f*FH + FH*t
.candidate:
    comiss xmm0, [rsp+8]
    ja .next                            ; too high to step onto
    comiss xmm0, [rsp+12]
    jbe .next
    movss [rsp+12], xmm0                ; new best
.next:
    inc ebx
    jmp .loop
.done:
    ; ramps and platforms (anything off the grid)
    xor ebx, ebx
.plat:
    cmp ebx, [plat_count]
    jge .plats_done
    mov ecx, ebx
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    xorps xmm2, xmm2
    call plat_inside
    test eax, eax
    jz .pnext
    mov ecx, ebx
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    call plat_height
    comiss xmm0, [rsp+8]
    ja .pnext
    comiss xmm0, [rsp+12]
    jbe .pnext
    movss [rsp+12], xmm0
.pnext:
    inc ebx
    jmp .plat
.plats_done:
    movss xmm0, [rsp+12]
    EPILOGUE

; -----------------------------------------------------------------------------
; plat_inside(ecx=platform, xmm0=X, xmm1=Z, xmm2=margin) -> eax 1 if the
; point is over it (its rectangle grown by margin). leaf.
; plat_height(ecx=platform, xmm0=X, xmm1=Z) -> xmm0 = walking surface height
; there (a ramp is a straight slope; outside it the end height). leaf.
; -----------------------------------------------------------------------------
plat_inside:
    xor eax, eax
    movss xmm3, xmm0
    addss xmm3, xmm2
    comiss xmm3, [plat_x0+rcx*4]
    jbe .no
    movss xmm3, xmm0
    subss xmm3, xmm2
    comiss xmm3, [plat_x1+rcx*4]
    jae .no
    movss xmm3, xmm1
    addss xmm3, xmm2
    comiss xmm3, [plat_z0+rcx*4]
    jbe .no
    movss xmm3, xmm1
    subss xmm3, xmm2
    comiss xmm3, [plat_z1+rcx*4]
    jae .no
    mov eax, 1
.no:
    ret

plat_height:
    movss xmm2, [plat_ya+rcx*4]
    mov eax, [plat_axis+rcx*4]
    test eax, eax
    jz .flat
    cmp eax, 1
    jne .along_z
    subss xmm0, [plat_x0+rcx*4]
    movss xmm3, [plat_x1+rcx*4]
    subss xmm3, [plat_x0+rcx*4]
    jmp .lerp
.along_z:
    movaps xmm0, xmm1
    subss xmm0, [plat_z0+rcx*4]
    movss xmm3, [plat_z1+rcx*4]
    subss xmm3, [plat_z0+rcx*4]
.lerp:
    divss xmm0, xmm3
    maxss xmm0, [c_zero]
    minss xmm0, [c_one]
    movss xmm3, [plat_yb+rcx*4]
    subss xmm3, xmm2
    mulss xmm0, xmm3
    addss xmm0, xmm2
    ret
.flat:
    movaps xmm0, xmm2
    ret

; grid_platforms() -- every desk and crate in the maps becomes a solid block
; standing on the floor of its cell (see block_kinds)
grid_platforms:
    PROLOGUE 32
    xor r12d, r12d                      ; f
.f:
    cmp r12d, NF
    jge .done
    xor r14d, r14d                      ; y
.y:
    cmp r14d, MAP_H
    jge .fn
    xor r13d, r13d                      ; x
.x:
    cmp r13d, MAP_W
    jge .yn
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_at
    xor ebx, ebx
.kind:
    cmp ebx, NBLOCK_KINDS
    jge .next
    imul ecx, ebx, 20
    cmp eax, [block_kinds+rcx]
    je .found
    inc ebx
    jmp .kind
.found:
    mov ecx, [plat_count]
    cmp ecx, MAX_PLAT
    jge .done
    imul eax, ebx, 20
    lea rsi, [block_kinds+rax]
    cvtsi2ss xmm0, r13d
    addss xmm0, [c_half]
    mulss xmm0, [c_cell]                ; centre X
    movaps xmm1, xmm0
    subss xmm0, [rsi+4]
    movss [plat_x0+rcx*4], xmm0
    addss xmm1, [rsi+4]
    movss [plat_x1+rcx*4], xmm1
    cvtsi2ss xmm0, r14d
    addss xmm0, [c_half]
    mulss xmm0, [c_cell]                ; centre Z
    movaps xmm1, xmm0
    subss xmm0, [rsi+8]
    movss [plat_z0+rcx*4], xmm0
    addss xmm1, [rsi+8]
    movss [plat_z1+rcx*4], xmm1
    cvtsi2ss xmm0, r12d
    mulss xmm0, [c_fh]
    addss xmm0, [rsi+12]                ; top
    movss [plat_ya+rcx*4], xmm0
    movss [plat_yb+rcx*4], xmm0
    mov dword [plat_axis+rcx*4], 0
    mov eax, [rsi+12]
    mov [plat_thick+rcx*4], eax
    mov eax, [rsi+16]
    mov [plat_style+rcx*4], eax
    inc dword [plat_count]
.next:
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

; load_platforms() -- copy the building's authored platforms into the arrays
load_platforms:
    mov eax, [cur_set]
    mov rdx, [set_plat+rax*8]
    mov r8d, [set_plat_n+rax*4]
    xor ecx, ecx
.p:
    cmp ecx, r8d
    jge .done
    mov eax, [rdx+0]
    mov [plat_x0+rcx*4], eax
    mov eax, [rdx+4]
    mov [plat_x1+rcx*4], eax
    mov eax, [rdx+8]
    mov [plat_z0+rcx*4], eax
    mov eax, [rdx+12]
    mov [plat_z1+rcx*4], eax
    mov eax, [rdx+16]
    mov [plat_ya+rcx*4], eax
    mov eax, [rdx+20]
    mov [plat_yb+rcx*4], eax
    mov eax, [rdx+24]
    mov [plat_axis+rcx*4], eax
    mov eax, [rdx+28]
    mov [plat_thick+rcx*4], eax
    mov eax, [rdx+32]
    mov [plat_style+rcx*4], eax
    add rdx, 36
    inc ecx
    jmp .p
.done:
    mov [plat_count], ecx
    ret

; -----------------------------------------------------------------------------
; floor_of_height(xmm0=y) -> eax = storey index 0..NF-1. leaf.
; -----------------------------------------------------------------------------
floor_of_height:
    addss xmm0, [c_fh_bias]
    divss xmm0, [c_fh]
    cvttss2si eax, xmm0
    cmp eax, 0
    jge .lo_ok
    xor eax, eax
.lo_ok:
    cmp eax, NF-1
    jle .hi_ok
    mov eax, NF-1
.hi_ok:
    ret

; -----------------------------------------------------------------------------
; collides(xmm0=X, xmm1=Z, xmm2=feetY, xmm3=radius, xmm4=bodyHeight) -> eax
; 1 if a body (square footprint of half-size `radius`) spanning
; [feet+0.25, feet+bodyHeight] overlaps any non-open cell on any storey
; that the body reaches into. The 0.25 bias lets you walk onto stairs.
; -----------------------------------------------------------------------------
collides:
    PROLOGUE 64
    ; [rsp+0] f0  [rsp+4] f1  [rsp+8] x0 [rsp+12] x1 [rsp+16] y0 [rsp+20] y1
    ; [rsp+32] X [rsp+36] Z [rsp+40] feet [rsp+44] radius [rsp+48] body
    movss [rsp+32], xmm0
    movss [rsp+36], xmm1
    movss [rsp+40], xmm2
    movss [rsp+44], xmm3
    movss [rsp+48], xmm4
    ; ---- platform slabs: solid from (surface - thickness) up to the surface
    xor ebx, ebx
.plat:
    cmp ebx, [plat_count]
    jge .grid
    mov ecx, ebx
    movss xmm0, [rsp+32]
    movss xmm1, [rsp+36]
    movss xmm2, [rsp+44]
    call plat_inside
    test eax, eax
    jz .pnext
    mov ecx, ebx
    movss xmm0, [rsp+32]
    movss xmm1, [rsp+36]
    call plat_height                    ; surface under the body's centre
    movss xmm1, [rsp+40]
    addss xmm1, [c_step_bias]
    comiss xmm1, xmm0                   ; body bottom at/above the surface: clear
    jae .pnext
    subss xmm0, [plat_thick+rbx*4]
    movss xmm1, [rsp+40]
    addss xmm1, [rsp+48]
    comiss xmm1, xmm0                   ; body top under the slab: clear
    jbe .pnext
    jmp .hit
.pnext:
    inc ebx
    jmp .plat
.grid:
    movss xmm0, [rsp+32]
    movss xmm1, [rsp+36]
    movss xmm2, [rsp+40]
    movss xmm3, [rsp+44]
    movss xmm4, [rsp+48]
    movaps xmm5, xmm2
    addss xmm5, [c_step_bias]
    divss xmm5, [c_fh]
    cvttss2si eax, xmm5
    cmp eax, 0
    jge .f0ok
    xor eax, eax
.f0ok:
    mov [rsp+0], eax
    addss xmm2, xmm4
    divss xmm2, [c_fh]
    cvttss2si eax, xmm2
    cmp eax, NF-1
    jle .f1ok
    mov eax, NF-1
.f1ok:
    mov [rsp+4], eax
    ; footprint in cells
    movaps xmm5, xmm0
    subss xmm5, xmm3
    mulss xmm5, [c_inv_cell]
    cvttss2si eax, xmm5
    mov [rsp+8], eax
    movaps xmm5, xmm0
    addss xmm5, xmm3
    mulss xmm5, [c_inv_cell]
    cvttss2si eax, xmm5
    mov [rsp+12], eax
    movaps xmm5, xmm1
    subss xmm5, xmm3
    mulss xmm5, [c_inv_cell]
    cvttss2si eax, xmm5
    mov [rsp+16], eax
    movaps xmm5, xmm1
    addss xmm5, xmm3
    mulss xmm5, [c_inv_cell]
    cvttss2si eax, xmm5
    mov [rsp+20], eax

    mov r12d, [rsp+0]                   ; f
.f_loop:
    cmp r12d, [rsp+4]
    jg .clear
    mov r14d, [rsp+16]                  ; gy
.y_loop:
    cmp r14d, [rsp+20]
    jg .f_next
    mov r13d, [rsp+8]                   ; gx
.x_loop:
    cmp r13d, [rsp+12]
    jg .y_next
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_at
    test byte [char_class+rax], CF_OPEN
    jz .hit
    inc r13d
    jmp .x_loop
.y_next:
    inc r14d
    jmp .y_loop
.f_next:
    inc r12d
    jmp .f_loop
.clear:
    xor eax, eax
    EPILOGUE
.hit:
    mov eax, 1
    EPILOGUE

; -----------------------------------------------------------------------------
; slab_cross(xmm0=x, xmm1=z, xmm2=feet from, xmm3=feet to, xmm4=radius,
;            xmm5=body height) -> eax 1 if that vertical move takes the body
; through a floor/ceiling slab: the head rising through a ceiling, or the feet
; sinking through a floor. A slab is only missing over an open shaft ('.');
; the roof and the basement floor are always there. (collides() only looks
; at the cells the body is in, so a fast rise -- a hookshot fling -- could
; otherwise pop you into the room above or out onto the roof.)
; -----------------------------------------------------------------------------
slab_cross:
    PROLOGUE 48
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    movss [rsp+16], xmm4
    movss [rsp+20], xmm5
    xor r12d, r12d                      ; k: the slab at k*FH
.k:
    cmp r12d, NF
    jg .clear
    cvtsi2ss xmm0, r12d
    mulss xmm0, [c_fh]
    movss xmm1, [rsp+12]
    comiss xmm1, [rsp+8]
    jbe .down
    ; rising: the head goes from at/under the slab to above it
    movss xmm1, [rsp+8]
    addss xmm1, [rsp+20]
    comiss xmm1, xmm0
    ja .next
    movss xmm1, [rsp+12]
    addss xmm1, [rsp+20]
    comiss xmm1, xmm0
    jbe .next
    jmp .slab
.down:
    ; sinking: the feet go from on/over the slab to under it
    movss xmm1, [rsp+8]
    comiss xmm1, xmm0
    jb .next
    movss xmm1, [rsp+12]
    comiss xmm1, xmm0
    jae .next
.slab:
    cmp r12d, 0
    je .hit
    cmp r12d, NF
    jge .hit
    ; over storey k's cells under the four corners: open shaft everywhere?
    xor r13d, r13d
.c:
    cmp r13d, 4
    jge .next
    movss xmm0, [rsp+16]
    test r13d, 1
    jnz .cx
    xorps xmm0, [c_sign_mask]
.cx:
    addss xmm0, [rsp+0]
    mulss xmm0, [c_inv_cell]
    cvttss2si esi, xmm0
    movss xmm0, [rsp+16]
    test r13d, 2
    jnz .cz
    xorps xmm0, [c_sign_mask]
.cz:
    addss xmm0, [rsp+4]
    mulss xmm0, [c_inv_cell]
    cvttss2si edx, xmm0
    mov edi, r12d
    call cell_at
    cmp eax, '.'
    jne .hit
    inc r13d
    jmp .c
.next:
    inc r12d
    jmp .k
.clear:
    xor eax, eax
    EPILOGUE
.hit:
    mov eax, 1
    EPILOGUE

; -----------------------------------------------------------------------------
; line_of_sight(edi=f, xmm0=ax, xmm1=az, xmm2=bx, xmm3=bz) -> eax 1 if clear.
; Samples the straight line every half unit on storey f; walls, racks and
; pillars block sight, desks don't.
; -----------------------------------------------------------------------------
line_of_sight:
    PROLOGUE 32
    ; [rsp+0] ax [rsp+4] az [rsp+8] dx [rsp+12] dz [rsp+16] steps(float)
    mov r15d, edi
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    subss xmm2, xmm0
    subss xmm3, xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    mulss xmm2, xmm2
    mulss xmm3, xmm3
    addss xmm2, xmm3
    sqrtss xmm2, xmm2
    divss xmm2, [c_los_step]
    cvttss2si r12d, xmm2
    inc r12d                            ; steps = ceil-ish(dist/0.5)
    cvtsi2ss xmm0, r12d
    movss [rsp+16], xmm0
    mov ebx, 1                          ; i
.loop:
    cmp ebx, r12d
    jge .clear
    cvtsi2ss xmm0, ebx
    divss xmm0, [rsp+16]                ; t
    movss xmm1, [rsp+8]
    mulss xmm1, xmm0
    addss xmm1, [rsp+0]
    mulss xmm1, [c_inv_cell]
    cvttss2si esi, xmm1
    movss xmm1, [rsp+12]
    mulss xmm1, xmm0
    addss xmm1, [rsp+4]
    mulss xmm1, [c_inv_cell]
    cvttss2si edx, xmm1
    mov edi, r15d
    call cell_at
    test byte [char_class+rax], CF_SIGHT
    jz .blocked
    inc ebx
    jmp .loop
.clear:
    mov eax, 1
    EPILOGUE
.blocked:
    xor eax, eax
    EPILOGUE

; =============================================================================
; The 3D navigation graph
; =============================================================================

; grid_node_pos(edi=grid node id) -> xmm0=X, xmm1=Y, xmm2=Z  (world centre of
; a cell, with the ramp height if it is a stair)
grid_node_pos:
    PROLOGUE 16
    mov ebx, edi
    ; decompose id -> f, y, x
    mov eax, edi
    xor edx, edx
    mov ecx, MAP_W
    div ecx                             ; eax = f*MAP_H + y, edx = x
    mov r13d, edx                       ; x
    xor edx, edx
    mov ecx, MAP_H
    div ecx                             ; eax = f, edx = y
    mov r12d, eax                       ; f
    mov r14d, edx                       ; y
    cvtsi2ss xmm0, r13d
    addss xmm0, [c_half]
    mulss xmm0, [c_cell]
    movss [rsp+0], xmm0                 ; X
    cvtsi2ss xmm1, r14d
    addss xmm1, [c_half]
    mulss xmm1, [c_cell]
    movss [rsp+4], xmm1                 ; Z
    cvtsi2ss xmm2, r12d
    mulss xmm2, [c_fh]
    movss [rsp+8], xmm2                 ; Y = f*FH
    movzx eax, byte [grid+rbx]
    test byte [char_class+rax], CF_STAIR
    jz .flat
    mov edi, ebx
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    call stair_t
    mulss xmm0, [c_fh]
    addss xmm0, [rsp+8]
    movss [rsp+8], xmm0
.flat:
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+8]
    movss xmm2, [rsp+4]
    EPILOGUE

; node_center(edi=node id) -> xmm0=X, xmm1=Y (feet), xmm2=Z. leaf.
; Works for grid cells and free waypoints alike.
node_center:
    movss xmm0, [nav_x+rdi*4]
    movss xmm1, [nav_y+rdi*4]
    movss xmm2, [nav_z+rdi*4]
    ret

; node_walkable(edi=node id) -> eax 1 if T may stand there. leaf.
node_walkable:
    mov eax, 1
    cmp edi, NCELLS
    jae .done                           ; waypoints are always walkable
    movzx eax, byte [grid+rdi]
    movzx eax, byte [char_class+rax]
    and eax, CF_TWALK
    shr eax, 3
.done:
    ret

; add_link(edi=from, esi=to, edx=type) -- one directed edge. leaf.
add_link:
    mov eax, [link_count]
    cmp eax, MAX_LINKS
    jge .full
    mov [link_to+rax*4], esi
    mov [link_type+rax*4], edx
    mov ecx, [link_head+rdi*4]
    mov [link_next+rax*4], ecx
    mov [link_head+rdi*4], eax
    inc dword [link_count]
.full:
    ret

; build_nav() -- node positions, waypoints, authored + automatic links
build_nav:
    PROLOGUE 16
    xor ebx, ebx
.grid:
    cmp ebx, NCELLS
    jge .grid_done
    mov edi, ebx
    call grid_node_pos
    movss [nav_x+rbx*4], xmm0
    movss [nav_y+rbx*4], xmm1
    movss [nav_z+rbx*4], xmm2
    inc ebx
    jmp .grid
.grid_done:
    mov eax, [cur_set]
    mov rdx, [set_xnode+rax*8]
    mov r9d, [set_xnode_n+rax*4]
    xor ecx, ecx
.xn:
    cmp ecx, r9d
    jge .xn_done
    lea eax, [rcx+NCELLS]
    mov r8d, [rdx]
    mov [nav_x+rax*4], r8d
    mov r8d, [rdx+4]
    mov [nav_y+rax*4], r8d
    mov r8d, [rdx+8]
    mov [nav_z+rax*4], r8d
    add rdx, 12
    inc ecx
    jmp .xn
.xn_done:
    lea eax, [r9d+NCELLS]
    mov [nav_count], eax
    lea rdi, [link_head]
    mov ecx, NNODES
    mov eax, -1
    rep stosd
    mov dword [link_count], 0
    mov dword [nav_t_mask], (1 << LK_WALK) | (1 << LK_DROP)   ; T can't climb (yet)
    mov eax, [cur_set]
    mov r13, [set_xlink+rax*8]
    mov r14d, [set_xlink_n+rax*4]
    xor ebx, ebx
.xl:
    cmp ebx, r14d
    jge .xl_done
    imul eax, ebx, 12
    lea r12, [r13+rax]
    mov edi, [r12]
    mov esi, [r12+4]
    mov edx, [r12+8]
    call add_link
    cmp dword [r12+8], LK_DROP
    je .xl_next
    mov edi, [r12+4]                    ; walk / ladder links go both ways
    mov esi, [r12]
    mov edx, [r12+8]
    call add_link
.xl_next:
    inc ebx
    jmp .xl
.xl_done:
    call auto_links
    EPILOGUE

; auto_links() -- links the maps imply:
;   drop:   a floor cell next to an open shaft/void -> wherever you'd land
;           below (only onto flat floor: never onto a stair or into a wall)
;   ladder: a ladder foot 'u' <-> the cell you step off onto upstairs
auto_links:
    PROLOGUE 32
    ; [rsp+0] from node  [rsp+4] nx  [rsp+8] ny
    mov r12d, 1
.f:
    cmp r12d, NF
    jge .ladders
    xor r14d, r14d
.y:
    cmp r14d, MAP_H
    jge .fn
    xor r13d, r13d
.x:
    cmp r13d, MAP_W
    jge .yn
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_at
    movzx eax, byte [char_class+rax]
    and eax, CF_TWALK | CF_FLAT
    cmp eax, CF_TWALK | CF_FLAT
    jne .xnext
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_index
    mov [rsp+0], eax
    xor ebx, ebx
.d:
    cmp ebx, 4
    jge .xnext
    mov esi, r13d
    add esi, [dir4_dx+rbx*4]
    mov edx, r14d
    add edx, [dir4_dy+rbx*4]
    mov [rsp+4], esi
    mov [rsp+8], edx
    mov edi, r12d
    call cell_at
    cmp eax, '.'
    jne .dnext
    mov r15d, r12d                      ; fall down the shaft...
.down:
    dec r15d
    js .dnext
    mov edi, r15d
    mov esi, [rsp+4]
    mov edx, [rsp+8]
    call cell_at
    cmp eax, '.'
    je .down
    movzx eax, byte [char_class+rax]    ; ...and land on flat floor
    and eax, CF_TWALK | CF_FLAT
    cmp eax, CF_TWALK | CF_FLAT
    jne .dnext
    mov edi, r15d
    mov esi, [rsp+4]
    mov edx, [rsp+8]
    call cell_index
    mov esi, eax
    mov edi, [rsp+0]
    mov edx, LK_DROP
    call add_link
.dnext:
    inc ebx
    jmp .d
.xnext:
    inc r13d
    jmp .x
.yn:
    inc r14d
    jmp .y
.fn:
    inc r12d
    jmp .f
.ladders:
    xor r12d, r12d
.lf:
    cmp r12d, NF-1
    jge .done
    xor r14d, r14d
.ly:
    cmp r14d, MAP_H
    jge .lfn
    xor r13d, r13d
.lx:
    cmp r13d, MAP_W
    jge .lyn
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, 'u'
    jne .lxn
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call ladder_dir                     ; traverse.asm: which wall it's on
    cmp eax, 0
    jl .lxn
    mov ebx, eax
    lea edi, [r12d+1]
    mov esi, r13d
    add esi, [dir4_dx+rbx*4]
    mov edx, r14d
    add edx, [dir4_dy+rbx*4]
    call cell_index
    mov [rsp+4], eax                    ; top
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_index
    mov [rsp+0], eax                    ; foot
    mov edi, eax
    mov esi, [rsp+4]
    mov edx, LK_LADDER
    call add_link
    mov edi, [rsp+4]
    mov esi, [rsp+0]
    mov edx, LK_LADDER
    call add_link
.lxn:
    inc r13d
    jmp .lx
.lyn:
    inc r14d
    jmp .ly
.lfn:
    inc r12d
    jmp .lf
.done:
    EPILOGUE

; node_at_pos(xmm0=X, xmm1=feetY, xmm2=Z) -> eax = node id under a body.
; Standing on a ramp or platform: the nearest free waypoint. Otherwise the
; grid cell -- and if the storey computed from the feet is an open shaft, the
; body is really on the stair of the storey below.
node_at_pos:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    mov r15d, -1
    movss xmm6, [c_xn_reach]
    mulss xmm6, xmm6                    ; best distance^2 so far
    mov ebx, NCELLS
.xn:
    cmp ebx, [nav_count]
    jge .xn_done
    movss xmm0, [nav_y+rbx*4]
    subss xmm0, [rsp+4]
    andps xmm0, [c_abs_mask]
    comiss xmm0, [c_xn_dy]
    jae .xn_next
    movss xmm0, [nav_x+rbx*4]
    subss xmm0, [rsp+0]
    mulss xmm0, xmm0
    movss xmm1, [nav_z+rbx*4]
    subss xmm1, [rsp+8]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    comiss xmm0, xmm6
    jae .xn_next
    movaps xmm6, xmm0
    mov r15d, ebx
.xn_next:
    inc ebx
    jmp .xn
.xn_done:
    test r15d, r15d
    js .grid
    mov eax, r15d
    EPILOGUE
.grid:
    movss xmm0, [rsp+0]
    mulss xmm0, [c_inv_cell]
    cvttss2si r13d, xmm0                ; gx
    movss xmm2, [rsp+8]
    mulss xmm2, [c_inv_cell]
    cvttss2si r14d, xmm2                ; gy
    movss xmm0, [rsp+4]
    call floor_of_height
    mov r12d, eax                       ; f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, '.'
    jne .ok
    test r12d, r12d
    jz .ok
    dec r12d
.ok:
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_index
    EPILOGUE

; dist3(xmm0..2 = a, xmm3..5 = b) -> xmm0 = |a - b|. leaf.
dist3:
    subss xmm0, xmm3
    mulss xmm0, xmm0
    subss xmm1, xmm4
    mulss xmm1, xmm1
    subss xmm2, xmm5
    mulss xmm2, xmm2
    addss xmm0, xmm1
    addss xmm0, xmm2
    sqrtss xmm0, xmm0
    ret

; storey_of(xmm0=y) -> eax = floor(y / FH), not clamped (-1 below the
; basement, NF above the roof). leaf.
storey_of:
    divss xmm0, [c_fh]
    roundss xmm0, xmm0, 1
    cvttss2si eax, xmm0
    ret

; line_of_sight_3d(xmm0..2 = eye A, xmm3..5 = point B) -> eax 1 if clear.
; The real 3D segment through the building: walls, racks and pillars block
; it, and it may only pass a floor/ceiling where that is open ('.' -- stair
; wells, hatches, the atrium). So you can look down the atrium at T.
line_of_sight_3d:
    xor edi, edi
    jmp ray_march

; sound_occlusion(xmm0..2 = source, xmm3..5 = listener) -> xmm0 = extra
; distance the sound travels "through" the building: each solid slab adds
; c_hear_slab, each half metre of wall c_hear_wall. Open shafts carry sound.
sound_occlusion:
    mov edi, 1
    jmp ray_march

; ray_march(xmm0..5 = A, B; edi = 0 sight / 1 sound)
ray_march:
    PROLOGUE 64
    ; [rsp+0..8] A  [rsp+12..20] B-A  [rsp+24] steps  [rsp+28] extra
    ; [rsp+32] mode  [rsp+36] t  [rsp+40] gy
    mov [rsp+32], edi
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    subss xmm3, xmm0
    movss [rsp+12], xmm3
    subss xmm4, xmm1
    movss [rsp+16], xmm4
    subss xmm5, xmm2
    movss [rsp+20], xmm5
    mulss xmm3, xmm3
    mulss xmm4, xmm4
    mulss xmm5, xmm5
    addss xmm3, xmm4
    addss xmm3, xmm5
    sqrtss xmm3, xmm3
    movss xmm0, [c_los3_step]
    test edi, edi
    jz .st
    movss xmm0, [c_snd_step]
.st:
    divss xmm3, xmm0
    cvttss2si r12d, xmm3
    inc r12d                            ; samples
    cvtsi2ss xmm0, r12d
    movss [rsp+24], xmm0
    mov dword [rsp+28], 0
    movss xmm0, [rsp+4]
    call storey_of
    mov r13d, eax                       ; storey of the previous sample
    mov ebx, 1
.loop:
    cmp ebx, r12d
    jge .end
    cvtsi2ss xmm0, ebx
    divss xmm0, [rsp+24]
    movss [rsp+36], xmm0
    movss xmm0, [rsp+16]
    mulss xmm0, [rsp+36]
    addss xmm0, [rsp+4]
    call storey_of
    mov r14d, eax
    movss xmm0, [rsp+12]
    mulss xmm0, [rsp+36]
    addss xmm0, [rsp+0]
    mulss xmm0, [c_inv_cell]
    cvttss2si r15d, xmm0                ; gx
    movss xmm0, [rsp+20]
    mulss xmm0, [rsp+36]
    addss xmm0, [rsp+8]
    mulss xmm0, [c_inv_cell]
    cvttss2si eax, xmm0
    mov [rsp+40], eax                   ; gy
    cmp r14d, r13d
    je .in_cell
    ; crossed a floor/ceiling: open only where the upper storey is '.' --
    ; checked at the exact point the ray passes that height
    mov edi, r14d
    cmp r13d, r14d
    cmovg edi, r13d
    mov [rsp+44], edi
    cvtsi2ss xmm0, edi
    mulss xmm0, [c_fh]
    subss xmm0, [rsp+4]
    divss xmm0, [rsp+16]                ; t where y = that floor's height
    movss xmm1, [rsp+12]
    mulss xmm1, xmm0
    addss xmm1, [rsp+0]
    mulss xmm1, [c_inv_cell]
    cvttss2si esi, xmm1
    movss xmm1, [rsp+20]
    mulss xmm1, xmm0
    addss xmm1, [rsp+8]
    mulss xmm1, [c_inv_cell]
    cvttss2si edx, xmm1
    call cell_at
    cmp eax, '.'
    je .crossed
    cmp dword [rsp+32], 0
    je .blocked
    movss xmm0, [rsp+28]
    addss xmm0, [c_hear_slab]
    movss [rsp+28], xmm0
.crossed:
    mov r13d, r14d
.in_cell:
    mov edi, r14d
    mov esi, r15d
    mov edx, [rsp+40]
    call cell_at                        ; outside the building reads as '#'
    movzx eax, byte [char_class+rax]
    cmp dword [rsp+32], 0
    jne .sound
    test eax, CF_SIGHT
    jz .blocked
    jmp .next
.sound:
    test eax, CF_WALL
    jz .next
    movss xmm0, [rsp+28]
    addss xmm0, [c_hear_wall]
    movss [rsp+28], xmm0
.next:
    inc ebx
    jmp .loop
.end:
    mov eax, 1
    movss xmm0, [rsp+28]
    EPILOGUE
.blocked:
    xor eax, eax
    EPILOGUE
