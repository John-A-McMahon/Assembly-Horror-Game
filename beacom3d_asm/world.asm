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

section .data
map_name0   db "maps/basement.txt",0
map_name1   db "maps/ground.txt",0
map_name2   db "maps/second.txt",0
align 8
map_names   dq map_name0, map_name1, map_name2
mode_r      db "r",0
err_map     db "Could not open %s -- run the game from the beacom3d_asm directory.",10,0

c_step_bias dd 0.25       ; body starts this far above the feet (so stairs don't block)
c_fh_bias   dd 0.6        ; floor_of_height rounding bias
c_los_step  dd 0.5        ; line-of-sight sample spacing (world units)

section .bss
grid        resb NCELLS
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
    mov byte [rbx+'d'], CF_SIGHT            ; desks are low: you can see over them
    mov byte [rbx+'B'], CF_SIGHT

    call load_maps
    call compute_stairs

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
; load_maps() -- read maps/*.txt, 31 rows of 59 chars each. Line endings may be
; LF or CRLF (a Windows checkout converts them), so after each row we skip
; everything up to and including '\n' -- same trick as doom.asm.
; -----------------------------------------------------------------------------
load_maps:
    PROLOGUE 16
    xor r12d, r12d                      ; r12 = floor
.floor_loop:
    cmp r12d, NF
    jge .done
    mov rdi, [map_names+r12*8]
    lea rsi, [mode_r]
    call fopen
    test rax, rax
    jnz .opened
    lea rdi, [err_map]
    mov rsi, [map_names+r12*8]
    xor eax, eax
    call printf
    mov edi, 1
    call exit
.opened:
    mov r13, rax                        ; r13 = FILE*
    xor r14d, r14d                      ; r14 = row
.row_loop:
    cmp r14d, MAP_H
    jge .close
    ; dest = grid + (f*MAP_H + row)*MAP_W
    imul eax, r12d, MAP_H
    add eax, r14d
    imul eax, eax, MAP_W
    lea rdi, [grid]
    add rdi, rax
    mov esi, 1
    mov edx, MAP_W
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
    movss xmm0, [rsp+12]
    EPILOGUE

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
    PROLOGUE 32
    ; [rsp+0] f0  [rsp+4] f1  [rsp+8] x0 [rsp+12] x1 [rsp+16] y0 [rsp+20] y1
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

; -----------------------------------------------------------------------------
; node_center(edi=node id) -> xmm0=X, xmm1=Y, xmm2=Z  (world centre of a
; cell, with the ramp height if it is a stair)
; -----------------------------------------------------------------------------
node_center:
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

; -----------------------------------------------------------------------------
; node_at_pos(xmm0=X, xmm1=feetY, xmm2=Z) -> eax = node id under a body.
; If the storey computed from the feet is an open shaft, the body is really
; on the stair of the storey below.
; -----------------------------------------------------------------------------
node_at_pos:
    PROLOGUE 16
    mulss xmm0, [c_inv_cell]
    cvttss2si r13d, xmm0                ; gx
    mulss xmm2, [c_inv_cell]
    cvttss2si r14d, xmm2                ; gy
    movaps xmm0, xmm1
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
