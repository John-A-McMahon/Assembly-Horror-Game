; =============================================================================
; ai.asm -- T, the thing that hunts the halls.
;
; Same brain as game.asm / doom.asm (goal seeking on the grid, random
; wandering, a "hunch" that drifts toward you when you're within CHASE_RADIUS,
; safe rooms are off limits, noises draw him in, deauth packets stun him),
; extended to three storeys:
;
;   * Every map cell is a graph node: id = (f*MAP_H + y)*MAP_W + x.
;   * T may stand on ' ' floor and on stairs -- never S (safe rooms).
;   * The top cell of a stair connects to the landing on the storey above,
;     and a landing next to an open shaft connects back down to that stair.
;   * Path finding is a breadth-first search (the original used a recursive
;     DFS flood fill; BFS gives shortest paths without deep recursion over
;     5487 nodes).
;
; T's states:  WANDER -> (noise) INVESTIGATE -> (sees you) CHASE
; =============================================================================
%define MODULE_AI
%include "common.inc"

global find_path, enemy_reset, enemy_update, enemy_hear, enemy_deauth, random_node
global t_x, t_y, t_z, t_state, t_stun, t_sees, t_speed_bonus, t_caught, t_dist, t_same_storey
global t_anim_phase, t_moving, path_len

extern on_t_spotted                     ; main.asm: "T HAS SEEN YOU. RUN."

%define CHASE_RADIUS 20                 ; cells, same constant as doom.asm

section .data
; the four grid directions
dir_dx      dd 1, -1, 0, 0
dir_dy      dd 0, 0, 1, -1
; walking speed per state (world units / second): wander, investigate, chase
t_speeds    dd 1.9, 3.1, 4.4
c_sight_flash   dd 26.0                 ; how far T sees you with the flashlight on
c_sight_dark    dd 11.0                 ; ...with it off
c_sight_crouch  dd 6.0                  ; ...crouching in the dark
c_same_storey   dd 1.4
c_lost_track    dd 2.5                  ; he keeps tracking you around corners this long
c_lost_give_up  dd 6.0
c_lost_arrived  dd 3.0
c_hunch_prob    dd 0.35
c_prefer_floor  dd 0.6
c_repath_chase  dd 0.25
c_repath_other  dd 0.8
c_step_chase    dd 0.33
c_step_invest   dd 0.5
c_step_wander   dd 0.75
c_catch_r       dd 0.95
c_catch_h       dd 1.2
c_dist_y        dd 1.5
c_hear_y        dd 2.5
c_stun_time     dd 5.0
c_anim_chase    dd 9.0
c_anim_walk     dd 5.0
c_away_prob     dd 0.8

section .bss
alignb 4
prev        resd NCELLS                 ; BFS back-pointers
seen        resd NCELLS                 ; BFS visit stamps (avoids clearing)
queue       resd NCELLS
stamp       resd 1
path        resd NCELLS                 ; current path: path[0] = start ... goal
path_len    resd 1
path_pos    resd 1                      ; next index of path[] to walk to
nb          resd 4                      ; neighbour scratch
tmp_path    resd NCELLS

t_x         resd 1                      ; world position (feet)
t_y         resd 1
t_z         resd 1
t_node      resd 1                      ; node T last stood on
t_next      resd 1                      ; node T is walking toward
t_goal      resd 1
t_state     resd 1
t_stun      resd 1                      ; float seconds left of deauth stun
t_repath    resd 1                      ; float seconds until next path search
t_lost      resd 1                      ; float seconds since he last saw you
t_step      resd 1                      ; float footstep timer
t_sees      resd 1
t_last_known resd 1                     ; node where he last saw you (-1 none)
t_speed_bonus resd 1                    ; float, grows with every capture you take
t_caught    resd 1                      ; out: 1 = you're dead
t_dist      resd 1                      ; out: float distance to player
t_same_storey resd 1                    ; out
t_anim_phase resd 1                     ; float, drives arm swing in render.asm
t_moving    resd 1

section .text

; -----------------------------------------------------------------------------
; neighbours(edi=id) -> eax = count, node ids in nb[]
; -----------------------------------------------------------------------------
neighbours:
    PROLOGUE 32
    ; [rsp+0] f [rsp+4] x [rsp+8] y [rsp+12] here-class [rsp+16] count
    ;  [rsp+20] dir [rsp+24] id
    mov [rsp+24], edi
    mov eax, edi
    xor edx, edx
    mov ecx, MAP_W
    div ecx
    mov [rsp+4], edx                    ; x
    xor edx, edx
    mov ecx, MAP_H
    div ecx
    mov [rsp+0], eax                    ; f
    mov [rsp+8], edx                    ; y
    movzx eax, byte [grid+rdi]
    movzx eax, byte [char_class+rax]
    mov [rsp+12], eax
    mov dword [rsp+16], 0
    xor ebx, ebx                        ; direction index
.dir_loop:
    cmp ebx, 4
    jge .done
    mov r12d, [rsp+4]
    add r12d, [dir_dx+rbx*4]            ; nx
    mov r13d, [rsp+8]
    add r13d, [dir_dy+rbx*4]            ; ny
    mov edi, [rsp+0]
    mov esi, r12d
    mov edx, r13d
    call cell_at
    mov r14d, eax                       ; neighbour char
    test byte [char_class+rax], CF_TWALK
    jz .not_plain
    mov edi, [rsp+0]
    mov esi, r12d
    mov edx, r13d
    call cell_index
    jmp .push
.not_plain:
    ; top of a stair -> landing on the storey above
    test dword [rsp+12], CF_STAIR
    jz .try_down
    mov ecx, [rsp+24]
    cmp byte [st_top+rcx], 1
    jne .try_down
    movsx eax, byte [st_dx+rcx]
    cmp eax, [dir_dx+rbx*4]
    jne .try_down
    movsx eax, byte [st_dy+rcx]
    cmp eax, [dir_dy+rbx*4]
    jne .try_down
    mov edi, [rsp+0]
    inc edi
    mov esi, r12d
    mov edx, r13d
    call cell_at
    test byte [char_class+rax], CF_TWALK
    jz .try_down
    mov edi, [rsp+0]
    inc edi
    mov esi, r12d
    mov edx, r13d
    call cell_index
    jmp .push
.try_down:
    ; open shaft -> top cell of the stair underneath, if it rises toward us
    cmp r14d, '.'
    jne .next
    mov edi, [rsp+0]
    dec edi
    mov esi, r12d
    mov edx, r13d
    call cell_at
    test byte [char_class+rax], CF_STAIR
    jz .next
    mov edi, [rsp+0]
    dec edi
    mov esi, r12d
    mov edx, r13d
    call cell_index
    mov ecx, eax
    cmp byte [st_top+rcx], 1
    jne .next
    movsx edx, byte [st_dx+rcx]
    neg edx
    cmp edx, [dir_dx+rbx*4]
    jne .next
    movsx edx, byte [st_dy+rcx]
    neg edx
    cmp edx, [dir_dy+rbx*4]
    jne .next
.push:
    mov ecx, [rsp+16]
    mov [nb+rcx*4], eax
    inc dword [rsp+16]
.next:
    inc ebx
    jmp .dir_loop
.done:
    mov eax, [rsp+16]
    EPILOGUE

; -----------------------------------------------------------------------------
; find_path(edi=from, esi=to) -> eax 1 if found. The path (from..to inclusive)
; is left in path[0..path_len).
; -----------------------------------------------------------------------------
find_path:
    PROLOGUE 16
    mov r12d, edi                       ; from
    mov r13d, esi                       ; to
    cmp r12d, r13d
    jne .search
    mov [path], r12d
    mov dword [path_len], 1
    mov eax, 1
    EPILOGUE
.search:
    inc dword [stamp]
    mov r15d, [stamp]
    xor r14d, r14d                      ; queue head
    xor ebx, ebx                        ; queue tail
    mov [queue], r12d
    inc ebx
    mov [seen+r12*4], r15d
.bfs:
    cmp r14d, ebx
    jge .not_found
    mov eax, [queue+r14*4]
    inc r14d
    mov [rsp+0], eax                    ; current node
    mov edi, eax
    call neighbours
    mov [rsp+4], eax                    ; neighbour count
    mov dword [rsp+8], 0
.nb_loop:
    mov ecx, [rsp+8]
    cmp ecx, [rsp+4]
    jge .bfs
    inc dword [rsp+8]
    mov edx, [nb+rcx*4]
    cmp [seen+rdx*4], r15d
    je .nb_loop
    mov [seen+rdx*4], r15d
    mov eax, [rsp+0]
    mov [prev+rdx*4], eax
    cmp edx, r13d
    je .found
    mov [queue+rbx*4], edx
    inc ebx
    jmp .nb_loop
.found:
    ; walk the back-pointers from `to` to `from` into tmp_path, then reverse
    xor ecx, ecx
    mov eax, r13d
.back:
    mov [tmp_path+rcx*4], eax
    inc ecx
    cmp eax, r12d
    je .reverse
    mov eax, [prev+rax*4]
    jmp .back
.reverse:
    mov [path_len], ecx
    xor edx, edx                        ; out index
.rev_loop:
    dec ecx
    js .rev_done
    mov eax, [tmp_path+rcx*4]
    mov [path+rdx*4], eax
    inc edx
    jmp .rev_loop
.rev_done:
    mov eax, 1
    EPILOGUE
.not_found:
    xor eax, eax
    EPILOGUE

; -----------------------------------------------------------------------------
; random_node(edi=preferFloor or -1, esi=use_away, edx=away f, ecx=away x,
;             r8d=away y, r9d=min distance in cells) -> eax = random open node
; Tries up to 400 random open cells; with a preferred floor, 80% of picks on
; other floors are rejected. "away" rejects cells within min Manhattan
; distance (storeys count as 12 cells apart).
; -----------------------------------------------------------------------------
random_node:
    PROLOGUE 32
    mov [rsp+0], edi
    mov [rsp+4], esi
    mov [rsp+8], edx
    mov [rsp+12], ecx
    mov [rsp+16], r8d
    mov [rsp+20], r9d
    mov r15d, 400
.try:
    dec r15d
    js .fallback
    call rng_next
    xor edx, edx
    div dword [open_count]
    mov r12d, [open_cells+rdx*4]        ; candidate id
    ; decompose into f, y, x
    mov eax, r12d
    xor edx, edx
    mov ecx, MAP_W
    div ecx
    mov r13d, edx                       ; x
    xor edx, edx
    mov ecx, MAP_H
    div ecx
    mov ebx, eax                        ; f
    mov r14d, edx                       ; y
    ; preferred floor?
    cmp dword [rsp+0], 0
    jl .pref_ok
    cmp ebx, [rsp+0]
    je .pref_ok
    call rand01
    comiss xmm0, [c_away_prob]
    jb .try
.pref_ok:
    cmp dword [rsp+4], 0
    je .accept
    mov eax, r13d
    sub eax, [rsp+12]
    mov ecx, eax
    neg ecx
    cmovl ecx, eax                      ; |x - ax|
    mov eax, r14d
    sub eax, [rsp+16]
    mov edx, eax
    neg edx
    cmovl edx, eax                      ; |y - ay|
    add ecx, edx
    mov eax, ebx
    sub eax, [rsp+8]
    mov edx, eax
    neg edx
    cmovl edx, eax                      ; |f - af|
    imul edx, edx, 12
    add ecx, edx
    cmp ecx, [rsp+20]
    jl .try
.accept:
    mov eax, r12d
    EPILOGUE
.fallback:
    call rng_next
    xor edx, edx
    div dword [open_count]
    mov eax, [open_cells+rdx*4]
    EPILOGUE

; -----------------------------------------------------------------------------
; enemy_reset(edi=node) -- put T on a node, standing still, wandering.
; -----------------------------------------------------------------------------
enemy_reset:
    PROLOGUE 16
    mov ebx, edi
    call node_center
    movss [t_x], xmm0
    movss [t_y], xmm1
    movss [t_z], xmm2
    mov [t_node], ebx
    mov [t_next], ebx
    mov [t_goal], ebx
    mov dword [path_len], 0
    mov dword [path_pos], 0
    mov dword [t_state], T_WANDER
    mov dword [t_repath], 0
    mov dword [t_lost], 0
    mov dword [t_stun], 0
    mov dword [t_sees], 0
    mov dword [t_last_known], -1
    mov dword [t_caught], 0
    EPILOGUE

; set_goal(edi=node) -- change target; forces a re-path unless unchanged
set_goal:
    cmp edi, [t_goal]
    jne .change
    mov eax, [path_pos]
    cmp eax, [path_len]
    jl .same
.change:
    mov [t_goal], edi
    mov dword [t_repath], 0
.same:
    ret

; -----------------------------------------------------------------------------
; enemy_hear(xmm0=X, xmm1=Y, xmm2=Z, xmm3=radius) -- a noise at a point.
; Vertical distance counts extra (sound through floors is muffled).
; -----------------------------------------------------------------------------
enemy_hear:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    cmp dword [t_state], T_CHASE
    je .ignore
    movss xmm4, [t_stun]
    comiss xmm4, [c_zero]
    ja .ignore
    ; d = hypot(dx, dz) + |dy| * 2.5
    subss xmm0, [t_x]
    mulss xmm0, xmm0
    subss xmm2, [t_z]
    mulss xmm2, xmm2
    addss xmm0, xmm2
    sqrtss xmm0, xmm0
    subss xmm1, [t_y]
    andps xmm1, [c_abs_mask]
    mulss xmm1, [c_hear_y]
    addss xmm0, xmm1
    comiss xmm0, [rsp+12]
    ja .ignore
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+8]
    call node_at_pos
    mov ebx, eax
    movzx ecx, byte [grid+rbx]
    test byte [char_class+rcx], CF_TWALK
    jz .ignore
    mov dword [t_state], T_INVESTIGATE
    mov edi, ebx
    call set_goal
.ignore:
    EPILOGUE

; -----------------------------------------------------------------------------
; enemy_deauth(edi=player f, esi=player x, edx=player y) -- like use_weapon in
; doom.asm: T's connection drops, he reappears far away and is frozen.
; -----------------------------------------------------------------------------
enemy_deauth:
    PROLOGUE 16
    mov r8d, edx
    mov ecx, esi
    mov edx, edi
    mov edi, -1
    mov esi, 1
    mov r9d, 18
    call random_node
    mov edi, eax
    call enemy_reset
    mov eax, [c_stun_time]
    mov [t_stun], eax
    EPILOGUE

; -----------------------------------------------------------------------------
; enemy_update(xmm0=dt) -- perception, goal logic, path following, footsteps.
; Outputs t_caught, t_dist, t_same_storey for main.asm.
; -----------------------------------------------------------------------------
enemy_update:
    PROLOGUE 64
    ; locals:
    ;  [rsp+0] dt          [rsp+4] pNode      [rsp+8] pF   [rsp+12] pX  [rsp+16] pY
    ;  [rsp+20] pReach     [rsp+24] flat dist [rsp+28] safe
    ;  [rsp+32] remaining  [rsp+36] target X  [rsp+40] target Y [rsp+44] target Z
    ;  [rsp+48] speed
    movss [rsp+0], xmm0
    mov dword [t_caught], 0

    ; ---- where is the player on the node graph?
    movss xmm0, [p_x]
    movss xmm1, [p_y]
    movss xmm2, [p_z]
    call node_at_pos
    mov [rsp+4], eax
    mov ecx, eax
    movzx edx, byte [grid+rcx]
    movzx edx, byte [char_class+rdx]
    and edx, CF_TWALK
    mov [rsp+20], edx
    xor edx, edx
    mov ecx, MAP_W
    div ecx
    mov [rsp+12], edx
    xor edx, edx
    mov ecx, MAP_H
    div ecx
    mov [rsp+8], eax
    mov [rsp+16], edx

    call player_in_safe
    mov [rsp+28], eax

    ; ---- stunned: nothing else happens
    movss xmm0, [t_stun]
    comiss xmm0, [c_zero]
    jbe .not_stunned
    subss xmm0, [rsp+0]
    movss [t_stun], xmm0
    mov dword [t_moving], 0
    mov eax, [c_big]
    mov [t_dist], eax
    EPILOGUE
.not_stunned:

    ; ---- perception
    movss xmm0, [p_x]
    subss xmm0, [t_x]
    mulss xmm0, xmm0
    movss xmm1, [p_z]
    subss xmm1, [t_z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    movss [rsp+24], xmm0                ; flat distance

    movss xmm0, [p_y]
    subss xmm0, [t_y]
    andps xmm0, [c_abs_mask]
    xor eax, eax
    comiss xmm0, [c_same_storey]
    setb al
    mov [t_same_storey], eax

    mov dword [t_sees], 0
    cmp dword [rsp+28], 0               ; in a safe room: invisible
    jne .perceived
    cmp dword [t_same_storey], 0
    je .perceived
    movss xmm1, [c_sight_flash]
    cmp dword [p_flash_on], 0
    jne .have_range
    movss xmm1, [c_sight_dark]
    cmp dword [p_crouch], 0
    je .have_range
    movss xmm1, [c_sight_crouch]
.have_range:
    movss xmm0, [rsp+24]
    comiss xmm0, xmm1
    jae .perceived
    movss xmm0, [t_y]
    call floor_of_height
    mov edi, eax
    movss xmm0, [t_x]
    movss xmm1, [t_z]
    movss xmm2, [p_x]
    movss xmm3, [p_z]
    call line_of_sight
    mov [t_sees], eax
.perceived:
    cmp dword [t_sees], 0
    je .no_sight
    cmp dword [t_state], T_CHASE
    je .already
    call on_t_spotted
.already:
    mov dword [t_state], T_CHASE
    mov dword [t_lost], 0
    cmp dword [rsp+20], 0
    je .no_sight
    mov eax, [rsp+4]
    mov [t_last_known], eax
.no_sight:

    ; ---- goal logic (t_goal_logic from the assembly original, extended)
    cmp dword [t_state], T_CHASE
    jne .not_chasing
    cmp dword [t_sees], 0
    jne .chase_goal
    movss xmm0, [t_lost]
    addss xmm0, [rsp+0]
    movss [t_lost], xmm0
    comiss xmm0, [c_lost_track]
    jae .no_track
    cmp dword [rsp+20], 0
    je .no_track
    cmp dword [rsp+28], 0
    jne .no_track
    mov eax, [rsp+4]
    mov [t_last_known], eax
.no_track:
    movss xmm0, [t_lost]
    comiss xmm0, [c_lost_give_up]
    jbe .chase_goal
    mov dword [t_state], T_INVESTIGATE
.chase_goal:
    mov edi, [t_last_known]
    cmp edi, 0
    jl .not_chasing
    call set_goal
.not_chasing:

    ; arrived = node == goal && next == node
    mov eax, [t_node]
    cmp eax, [t_goal]
    jne .not_arrived
    cmp eax, [t_next]
    jne .not_arrived
    cmp dword [t_state], T_CHASE
    je .arrived_chase
    ; manhattan distance from T's node to the player (same storey only)
    mov eax, [t_node]
    xor edx, edx
    mov ecx, MAP_W
    div ecx
    mov r12d, edx                       ; T x
    xor edx, edx
    mov ecx, MAP_H
    div ecx
    mov r13d, eax                       ; T f
    mov r14d, edx                       ; T y
    cmp dword [t_state], T_INVESTIGATE
    jne .hunch
    mov dword [t_state], T_WANDER
.hunch:
    cmp dword [rsp+20], 0
    je .wander_goal
    cmp r13d, [rsp+8]
    jne .wander_goal
    mov eax, r12d
    sub eax, [rsp+12]
    mov ecx, eax
    neg ecx
    cmovl ecx, eax
    mov eax, r14d
    sub eax, [rsp+16]
    mov edx, eax
    neg edx
    cmovl edx, eax
    add ecx, edx
    cmp ecx, CHASE_RADIUS
    jg .wander_goal
    call rand01
    comiss xmm0, [c_hunch_prob]
    jae .wander_goal
    ; a "hunch" -- he drifts toward where you are
    mov dword [t_state], T_INVESTIGATE
    mov edi, [rsp+4]
    call set_goal
    jmp .not_arrived
.wander_goal:
    call rand01
    mov edi, -1
    comiss xmm0, [c_prefer_floor]
    jae .any_floor
    mov edi, [rsp+8]
.any_floor:
    xor esi, esi
    call random_node
    mov edi, eax
    call set_goal
    jmp .not_arrived
.arrived_chase:
    cmp dword [t_sees], 0
    jne .not_arrived
    movss xmm0, [t_lost]
    comiss xmm0, [c_lost_arrived]
    jbe .not_arrived
    mov dword [t_state], T_WANDER
.not_arrived:

    ; ---- path search, a few times a second
    movss xmm0, [t_repath]
    subss xmm0, [rsp+0]
    movss [t_repath], xmm0
    comiss xmm0, [c_zero]
    ja .no_repath
    mov eax, [c_repath_other]
    cmp dword [t_state], T_CHASE
    jne .rp
    mov eax, [c_repath_chase]
.rp:
    mov [t_repath], eax
    mov edi, [t_next]
    mov esi, [t_goal]
    call find_path
    test eax, eax
    jz .no_path
    mov dword [path_pos], 1             ; path[0] is t_next itself
    jmp .no_repath
.no_path:
    mov dword [t_state], T_WANDER
    mov dword [path_len], 0
    mov dword [path_pos], 0
    mov edi, -1
    xor esi, esi
    call random_node
    mov edi, eax
    call set_goal
.no_repath:

    ; ---- walk along the path
    mov eax, [t_state]
    movss xmm0, [t_speeds+rax*4]
    addss xmm0, [t_speed_bonus]
    mulss xmm0, [rsp+0]
    movss [rsp+32], xmm0                ; remaining distance this frame
.walk:
    movss xmm0, [rsp+32]
    comiss xmm0, [c_zero]
    jbe .walk_done
    mov edi, [t_next]
    call node_center
    movss [rsp+36], xmm0
    movss [rsp+40], xmm1
    movss [rsp+44], xmm2
    subss xmm0, [t_x]
    subss xmm2, [t_z]
    movaps xmm3, xmm0
    mulss xmm3, xmm3
    movaps xmm4, xmm2
    mulss xmm4, xmm4
    addss xmm3, xmm4
    sqrtss xmm3, xmm3                   ; d
    comiss xmm3, [rsp+32]
    ja .partial
    ; reach the node
    movss xmm4, [rsp+32]
    subss xmm4, xmm3
    movss [rsp+32], xmm4
    mov eax, [rsp+36]
    mov [t_x], eax
    mov eax, [rsp+40]
    mov [t_y], eax
    mov eax, [rsp+44]
    mov [t_z], eax
    mov eax, [t_next]
    mov [t_node], eax
    mov ecx, [path_pos]
    cmp ecx, [path_len]
    jge .walk_done
    mov eax, [path+rcx*4]
    mov [t_next], eax
    inc dword [path_pos]
    jmp .walk
.partial:
    ; move `remaining` along the direction, height proportional
    movss xmm4, [rsp+32]
    divss xmm4, xmm3                    ; fraction of the way
    mulss xmm0, xmm4
    addss xmm0, [t_x]
    movss [t_x], xmm0
    mulss xmm2, xmm4
    addss xmm2, [t_z]
    movss [t_z], xmm2
    movss xmm1, [rsp+40]
    subss xmm1, [t_y]
    mulss xmm1, xmm4
    addss xmm1, [t_y]
    movss [t_y], xmm1
.walk_done:

    ; moving = next != node || more path left
    xor eax, eax
    mov ecx, [t_next]
    cmp ecx, [t_node]
    setne al
    mov ecx, [path_pos]
    cmp ecx, [path_len]
    jge .mv
    mov eax, 1
.mv:
    mov [t_moving], eax

    ; ---- footsteps you can hear through the walls
    movss xmm0, [t_step]
    subss xmm0, [rsp+0]
    movss [t_step], xmm0
    cmp dword [t_moving], 0
    je .no_step
    comiss xmm0, [c_zero]
    ja .no_step
    mov eax, [c_step_wander]
    cmp dword [t_state], T_INVESTIGATE
    jne .s1
    mov eax, [c_step_invest]
.s1:
    cmp dword [t_state], T_CHASE
    jne .s2
    mov eax, [c_step_chase]
.s2:
    mov [t_step], eax
    call snd_tstep
.no_step:

    ; ---- arm-swing animation phase
    cmp dword [t_moving], 0
    je .no_anim
    movss xmm0, [c_anim_walk]
    cmp dword [t_state], T_CHASE
    jne .an
    movss xmm0, [c_anim_chase]
.an:
    mulss xmm0, [rsp+0]
    addss xmm0, [t_anim_phase]
    movss [t_anim_phase], xmm0
.no_anim:

    ; ---- outputs: distance and "caught"
    movss xmm1, [p_y]
    subss xmm1, [t_y]
    movaps xmm2, xmm1
    mulss xmm1, [c_dist_y]
    mulss xmm1, xmm1
    movss xmm0, [rsp+24]
    mulss xmm0, xmm0
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    movss [t_dist], xmm0
    cmp dword [rsp+28], 0
    jne .done
    movss xmm0, [rsp+24]
    comiss xmm0, [c_catch_r]
    jae .done
    andps xmm2, [c_abs_mask]
    comiss xmm2, [c_catch_h]
    jae .done
    mov dword [t_caught], 1
.done:
    EPILOGUE
