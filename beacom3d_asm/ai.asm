; =============================================================================
; ai.asm -- T, the thing that hunts the halls.
;
; Same brain as game.asm / doom.asm (goal seeking on the grid, random
; wandering, a "hunch" that drifts toward you when you're close,
; safe rooms are off limits, noises draw him in, deauth packets stun him),
; living in one continuous 3D building:
;
;   * He walks a 3D navigation graph (world.asm): every map cell is a node,
;     id = (f*MAP_H + y)*MAP_W + x, plus free waypoints at any height (the
;     atrium ramps and bridge), each with a world XYZ in nav_x/y/z.
;   * T may stand on ' ' floor and on stairs -- never S (safe rooms).
;   * The top cell of a stair connects to the landing on the storey above,
;     and a landing next to an open shaft connects back down to that stair.
;     Links add the rest: ramps, platforms, and drops off ledges into the
;     storey below (he will follow you down the atrium). Ladders are links
;     too, but nav_t_mask keeps him off them for now.
;   * He sees along real 3D rays (through the atrium, down stairwells) and
;     hears through the building: floor slabs muffle a lot, walls some.
;   * Path finding is a breadth-first search (the original used a recursive
;     DFS flood fill; BFS gives shortest paths without deep recursion).
;
; T's states:  WANDER -> (noise) INVESTIGATE -> (sees you) CHASE
; =============================================================================
%define MODULE_AI
%include "common.inc"

global find_path, enemy_reset, enemy_update, enemy_hear, enemy_deauth, random_node
global t_dew, enemy_lure, find_next, t_goal
global t_build, bld_on, bld_ax, bld_ay, bld_az, bld_bx, bld_by, bld_bz, bld_prog
global build_break, build_deauth, build_hit_point, enemy_portal_follow, director_reset
global dir_calm, dir_relax, t_camp, t_por_on, bld_cd, t_node
extern snd_build, snd_portal_enter, sinf, cosf
global t_x, t_y, t_z, t_state, t_stun, t_sees, t_speed_bonus, t_caught, t_dist, t_same_storey
global t_anim_phase, t_moving, path_len, t_hear_d, seen, stamp
global far_spawn_node, spawn_dist, spawn_maxd

extern on_t_spotted                     ; main.asm: "T HAS SEEN YOU. RUN."

%define MAX_NB 16                       ; most neighbours one node can have

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
c_stun_time     dd 5.0
c_anim_chase    dd 9.0
c_anim_walk     dd 5.0
c_away_prob     dd 0.8
c_t_eye         dd 1.75                 ; T's eyes above his feet
c_torso         dd 0.9                  ; he can also spot your body
c_hunch_r       dd 40.0                 ; hunch range (world units, 3D)...
c_hunch_y       dd 2.5                  ; ...height difference counts extra
c_dew_speed     dd 1.4                  ; T on Diet Mountain Dew: faster...
c_dew_sense     dd 1.4                  ; ...sees and hears further
; the director: T's pressure rises while you're comfortable, eases after a
; close call
c_dir_push      dd 40.0                 ; this long with no chase: T is nudged your way
c_dir_again     dd 25.0                 ; (and again 15 s later)
c_dir_relax     dd 12.0                 ; after a close call he backs off this long
c_dir_close     dd 8.0                  ; a chase that got this close was a close call
c_dir_away      dd 25                   ; backing off: wander at least this far away
; building up to a perch he can't path to
c_bld_rng       dd 6.5                  ; you're this close (flat)...
c_bld_dy0       dd 0.5                  ; ...and this much higher than him
c_bld_dy1       dd 4.8
c_bld_climb     dd 3.0                  ; climbing speed
c_bld_life      dd 20.0                 ; the stairs fall apart after this
c_bld_cd        dd 6.0                  ; before he builds again
c_bld_cd_broken dd 8.0
c_bld_wait      dd 4.0                  ; up top, waiting for you
c_bld_leave     dd 2.5                  ; you got this far from the top: down he goes
c_bld_back      dd 0.3                  ; the top stops this short of you
c_bld_stun      dd 1.5                  ; knocked off his stairs
c_bld_hit       dd 0.2025               ; (0.45 m)^2: a hookshot bites the stairs
c_bld_aim       dd 0.9
c_bld_reach     dd 15.0
; after you through a portal
c_por_life      dd 25.0
c_por_near      dd 0.8
c_por_any       dd 30.0                 ; (nemesis) follows from this close even un-chasing
c_por_front     dd 0.6
c_big_d         dd 1.0e9
m_build         db "*hammering* T is BUILDING his way up to you!",0
m_bld_break     db "T's crate stairs come crashing down -- and T with them!",0
m_bld_gone      db "T's stairs fall apart.",0
m_t_portal      db "T steps out of your portal after you!",0

section .bss
alignb 4
prev        resd NNODES                 ; BFS back-pointers
seen        resd NNODES                 ; BFS visit stamps (avoids clearing)
queue       resd NNODES
stamp       resd 1
path        resd NNODES                 ; current path: path[0] = start ... goal
path_len    resd 1
path_pos    resd 1                      ; next index of path[] to walk to
nb          resd MAX_NB                 ; neighbour scratch
tmp_path    resd NNODES
bfs_dist    resd NNODES                 ; far_spawn_node: steps from the start
spawn_dist  resd 1                      ; out: how far T's spawn is (steps)
spawn_maxd  resd 1                      ; out: the farthest reachable spot

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
t_dew       resd 1                      ; seconds of Diet Mountain Dew buzz left
t_speed_bonus resd 1                    ; float, grows with every capture you take
t_caught    resd 1                      ; out: 1 = you're dead
t_dist      resd 1                      ; out: float distance to player
t_same_storey resd 1                    ; out
t_anim_phase resd 1                     ; float, drives arm swing in render.asm
t_moving    resd 1
t_hear_d    resd 1                      ; out: how far your noise has to carry to reach T
; the director
dir_calm    resd 1                      ; seconds since T last chased you
dir_relax   resd 1                      ; seconds T keeps backing off
chase_min   resd 1                      ; closest he got during this chase
prev_state  resd 1
t_camp      resd 1                      ; seconds he waits outside your safe room
; building
t_build     resd 1                      ; 0 no, 1 building, 2 up, 3 on top, 4 down
bld_on      resd 1                      ; the stairs are standing
bld_ax      resd 1                      ; bottom (where he stood)...
bld_ay      resd 1
bld_az      resd 1
bld_bx      resd 1                      ; ...top (your perch)
bld_by      resd 1
bld_bz      resd 1
bld_prog    resd 1                      ; 0..1 built (for drawing)
bld_total   resd 1
bld_timer   resd 1
bld_life    resd 1
bld_cd      resd 1
; following you through a portal
t_por_on    resd 1
t_por_node  resd 1
t_por_life  resd 1
t_por_ex    resd 1                      ; the entry, in front of it
t_por_ey    resd 1
t_por_ez    resd 1
t_por_xx    resd 1                      ; the exit
t_por_xy    resd 1
t_por_xz    resd 1

section .text

; -----------------------------------------------------------------------------
; neighbours(edi=id) -> eax = count, node ids in nb[]
; -----------------------------------------------------------------------------
neighbours:
    PROLOGUE 32
    ; [rsp+0] f [rsp+4] x [rsp+8] y [rsp+12] here-class [rsp+16] count
    ;  [rsp+20] dir [rsp+24] id
    mov [rsp+24], edi
    mov dword [rsp+16], 0
    cmp edi, NCELLS
    jae .done                           ; a free waypoint: links only
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
    ; ---- links: ramps, platforms, drops off ledges (and ladders, if T may)
    mov eax, [rsp+24]
    mov ecx, [link_head+rax*4]
.link:
    test ecx, ecx
    js .links_done
    mov edx, [link_type+rcx*4]
    bt dword [nav_t_mask], edx
    jnc .link_next
    mov eax, [rsp+16]
    cmp eax, MAX_NB
    jge .links_done
    mov edx, [link_to+rcx*4]
    mov [nb+rax*4], edx
    inc dword [rsp+16]
.link_next:
    mov ecx, [link_next+rcx*4]
    jmp .link
.links_done:
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
    mov edi, r12d
    mov esi, r13d
    call bfs_search
    test eax, eax
    jz .not_found
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
; bfs_search(edi=from, esi=to) -> eax 1 if found; prev[] then leads from `to`
; back to `from`
; -----------------------------------------------------------------------------
bfs_search:
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
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
    mov eax, 1
    EPILOGUE
.not_found:
    xor eax, eax
    EPILOGUE

; -----------------------------------------------------------------------------
; find_next(edi=from, esi=to) -> eax = the next node on the way (to itself if
; already there), -1 if there's no way. Leaves T's path alone (bottom feeders).
; -----------------------------------------------------------------------------
find_next:
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov eax, r13d
    cmp r12d, r13d
    je .done
    call bfs_search
    test eax, eax
    jz .none
    mov eax, r13d
.back:
    mov ecx, [prev+rax*4]
    cmp ecx, r12d
    je .done
    mov eax, ecx
    jmp .back
.none:
    mov eax, -1
.done:
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
; far_spawn_node(edi = where you start) -> eax = where T starts.
; A breadth-first flood of T's own graph measures how many steps every
; reachable spot is from you. T starts at a random spot at least 55% of the
; farthest walk away -- the far side of the building, whatever the seed --
; or, if somehow nothing qualifies, at the single farthest spot.
; -----------------------------------------------------------------------------
far_spawn_node:
    PROLOGUE 32
    mov [rsp+0], edi
    inc dword [stamp]
    mov r15d, [stamp]
    mov [seen+rdi*4], r15d
    mov dword [bfs_dist+rdi*4], 0
    mov [queue], edi
    xor r14d, r14d                      ; head
    mov ebx, 1                          ; tail
    xor r12d, r12d                      ; farthest distance
    mov r13d, edi                       ; farthest node
.bfs:
    cmp r14d, ebx
    jge .measured
    mov eax, [queue+r14*4]
    inc r14d
    mov [rsp+4], eax
    mov edi, eax
    call neighbours
    mov [rsp+8], eax
    mov dword [rsp+12], 0
.nb:
    mov ecx, [rsp+12]
    cmp ecx, [rsp+8]
    jge .bfs
    inc dword [rsp+12]
    mov edx, [nb+rcx*4]
    cmp [seen+rdx*4], r15d
    je .nb
    mov [seen+rdx*4], r15d
    mov eax, [rsp+4]
    mov eax, [bfs_dist+rax*4]
    inc eax
    mov [bfs_dist+rdx*4], eax
    mov [queue+rbx*4], edx
    inc ebx
    ; the farthest plain floor cell (where T could reasonably stand)
    cmp eax, r12d
    jle .nb
    cmp edx, NCELLS
    jae .nb
    cmp byte [grid+rdx], ' '
    jne .nb
    mov r12d, eax
    mov r13d, edx
    jmp .nb
.measured:
    mov [spawn_maxd], r12d
    imul eax, r12d, 55
    add eax, 99                         ; (rounded up)
    xor edx, edx
    mov ecx, 100
    div ecx
    mov [rsp+16], eax                   ; the minimum distance
    mov ebx, 3000
.pick:
    dec ebx
    js .farthest
    call rng_next
    xor edx, edx
    div dword [open_count]
    mov eax, [open_cells+rdx*4]
    cmp [seen+rax*4], r15d
    jne .pick                           ; can't walk there from you
    mov ecx, [bfs_dist+rax*4]
    cmp ecx, [rsp+16]
    jl .pick
    mov [spawn_dist], ecx
    EPILOGUE
.farthest:
    mov [spawn_dist], r12d
    mov eax, r13d
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
    mov dword [t_dew], 0
    mov dword [t_build], 0
    mov dword [t_por_on], 0
    mov dword [t_camp], 0
    mov dword [prev_state], T_WANDER
    mov eax, [c_big_d]
    mov [chase_min], eax
    mov dword [t_sees], 0
    mov dword [t_last_known], -1
    mov dword [t_caught], 0
    EPILOGUE

; director_reset -- a new night: nobody's comfortable yet
director_reset:
    xor eax, eax
    mov [dir_calm], eax
    mov [dir_relax], eax
    mov [bld_on], eax
    mov [bld_cd], eax
    mov [t_build], eax
    ret

; ai_timers(xmm0 = dt) -- the director's, the stairs', the portal chase's
ai_timers:
    PROLOGUE 16
    movss [rsp+0], xmm0
    movss xmm1, [dir_relax]
    subss xmm1, xmm0
    maxss xmm1, [c_zero]
    movss [dir_relax], xmm1
    movss xmm1, [t_camp]
    subss xmm1, xmm0
    maxss xmm1, [c_zero]
    movss [t_camp], xmm1
    movss xmm1, [bld_cd]
    subss xmm1, xmm0
    maxss xmm1, [c_zero]
    movss [bld_cd], xmm1
    movss xmm1, [t_por_life]
    subss xmm1, xmm0
    movss [t_por_life], xmm1
    comiss xmm1, [c_zero]
    ja .por_ok
    mov dword [t_por_on], 0
.por_ok:
    cmp dword [bld_on], 0
    je .done
    movss xmm1, [bld_life]
    subss xmm1, [rsp+0]
    movss [bld_life], xmm1
    comiss xmm1, [c_zero]
    ja .done
    xor edi, edi                        ; worn out: down it comes
    call build_break
.done:
    EPILOGUE

; start_build -- stairs from where T stands up to just short of you
start_build:
    PROLOGUE 16
    mov eax, [t_x]
    mov [bld_ax], eax
    mov eax, [t_y]
    mov [bld_ay], eax
    mov eax, [t_z]
    mov [bld_az], eax
    ; the top: your perch, pulled back toward him a little
    movss xmm0, [t_x]
    subss xmm0, [p_x]
    movss xmm1, [t_z]
    subss xmm1, [p_z]
    movaps xmm2, xmm0
    mulss xmm2, xmm2
    movaps xmm3, xmm1
    mulss xmm3, xmm3
    addss xmm2, xmm3
    sqrtss xmm2, xmm2
    FLD xmm3, 0.01
    maxss xmm2, xmm3
    divss xmm0, xmm2
    divss xmm1, xmm2
    mulss xmm0, [c_bld_back]
    mulss xmm1, [c_bld_back]
    addss xmm0, [p_x]
    addss xmm1, [p_z]
    movss [bld_bx], xmm0
    movss [bld_bz], xmm1
    mov eax, [p_y]
    mov [bld_by], eax
    mov eax, [nm_build_time]
    mov [bld_total], eax
    mov [bld_timer], eax
    mov dword [bld_prog], 0
    mov dword [bld_on], 1
    mov eax, [c_bld_life]
    mov [bld_life], eax
    mov dword [t_build], 1
    lea rdi, [m_build]
    mov esi, 0xFF3B3BFF
    xor edx, edx
    call hud_message
    call snd_build
    mov edi, 3                          ; (nemesis: you escaped by climbing)
    call nemesis_note
    EPILOGUE

; t_move_to(xmm0..2 = point, xmm3 = step) -> eax 1 when T is there. leaf-ish
t_move_to:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    subss xmm0, [t_x]
    subss xmm1, [t_y]
    subss xmm2, [t_z]
    movaps xmm4, xmm0
    mulss xmm4, xmm4
    movaps xmm5, xmm1
    mulss xmm5, xmm5
    addss xmm4, xmm5
    movaps xmm5, xmm2
    mulss xmm5, xmm5
    addss xmm4, xmm5
    sqrtss xmm4, xmm4
    comiss xmm4, xmm3
    ja .part
    mov eax, [rsp+0]
    mov [t_x], eax
    mov eax, [rsp+4]
    mov [t_y], eax
    mov eax, [rsp+8]
    mov [t_z], eax
    mov eax, 1
    EPILOGUE
.part:
    divss xmm3, xmm4
    mulss xmm0, xmm3
    addss xmm0, [t_x]
    movss [t_x], xmm0
    mulss xmm1, xmm3
    addss xmm1, [t_y]
    movss [t_y], xmm1
    mulss xmm2, xmm3
    addss xmm2, [t_z]
    movss [t_z], xmm2
    xor eax, eax
    EPILOGUE

; build_update(xmm0 = dt) -- building, climbing up, waiting, climbing down
build_update:
    PROLOGUE 16
    movss [rsp+0], xmm0
    mov dword [t_moving], 0
    mov eax, [t_build]
    cmp eax, 1
    je .build
    cmp eax, 2
    je .up
    cmp eax, 3
    je .top
    ; 4: back down to where he started
    movss xmm3, [c_bld_climb]
    mulss xmm3, [rsp+0]
    movss xmm0, [bld_ax]
    movss xmm1, [bld_ay]
    movss xmm2, [bld_az]
    call t_move_to
    mov dword [t_moving], 1
    test eax, eax
    jz .anim
    mov dword [t_build], 0
    mov eax, [c_bld_cd]
    mov [bld_cd], eax
    mov dword [t_repath], 0
    jmp .anim
.build:
    movss xmm0, [bld_timer]
    subss xmm0, [rsp+0]
    movss [bld_timer], xmm0
    divss xmm0, [bld_total]
    movss xmm1, [c_one]
    subss xmm1, xmm0
    minss xmm1, [c_one]
    movss [bld_prog], xmm1
    movss xmm0, [bld_timer]
    comiss xmm0, [c_zero]
    ja .done
    mov eax, [c_one]
    mov [bld_prog], eax
    mov dword [t_build], 2
    jmp .done
.up:
    movss xmm3, [c_bld_climb]
    mulss xmm3, [rsp+0]
    movss xmm0, [bld_bx]
    movss xmm1, [bld_by]
    movss xmm2, [bld_bz]
    call t_move_to
    mov dword [t_moving], 1
    test eax, eax
    jz .anim
    mov dword [t_build], 3
    mov eax, [c_bld_wait]
    mov [bld_timer], eax
    jmp .anim
.top:
    ; you left the perch (or he's waited long enough): down again
    movss xmm0, [bld_timer]
    subss xmm0, [rsp+0]
    movss [bld_timer], xmm0
    comiss xmm0, [c_zero]
    jbe .down
    movss xmm0, [p_x]
    subss xmm0, [bld_bx]
    mulss xmm0, xmm0
    movss xmm1, [p_z]
    subss xmm1, [bld_bz]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    comiss xmm0, [c_bld_leave]
    ja .down
    movss xmm0, [p_y]
    subss xmm0, [bld_by]
    andps xmm0, [c_abs_mask]
    FLD xmm1, 1.5
    comiss xmm0, xmm1
    jbe .done
.down:
    mov dword [t_build], 4
    jmp .done
.anim:
    movss xmm0, [c_anim_chase]
    mulss xmm0, [rsp+0]
    addss xmm0, [t_anim_phase]
    movss [t_anim_phase], xmm0
.done:
    EPILOGUE

; build_break(edi = 1 knocked down / 0 worn out) -> eax 1 if there were
; stairs. T on them tumbles back to where he built them from.
build_break:
    PROLOGUE 16
    xor eax, eax
    cmp dword [bld_on], 0
    je .done
    mov ebx, edi
    mov dword [bld_on], 0
    mov eax, [c_bld_cd_broken]
    mov [bld_cd], eax
    cmp dword [t_build], 2
    jl .not_on
    mov eax, [bld_ax]
    mov [t_x], eax
    mov eax, [bld_ay]
    mov [t_y], eax
    mov eax, [bld_az]
    mov [t_z], eax
    mov eax, [c_bld_stun]
    mov [t_stun], eax
.not_on:
    mov dword [t_build], 0
    mov dword [t_repath], 0
    lea rdi, [m_bld_gone]
    test ebx, ebx
    jz .say
    lea rdi, [m_bld_break]
.say:
    mov esi, 0xFF8FE38F
    xor edx, edx
    call hud_message
    mov eax, 1
.done:
    EPILOGUE

; build_mid -> xmm0..2 = the middle of the stairs. leaf
build_mid:
    movss xmm0, [bld_ax]
    addss xmm0, [bld_bx]
    mulss xmm0, [c_half]
    movss xmm1, [bld_ay]
    addss xmm1, [bld_by]
    mulss xmm1, [c_half]
    movss xmm2, [bld_az]
    addss xmm2, [bld_bz]
    mulss xmm2, [c_half]
    ret

; build_deauth -> eax 1 if your deauth was aimed at T's stairs (and they're
; now down). Same aim rule as the bottom feeders: 15 m, ~25 degrees, in view.
build_deauth:
    PROLOGUE 48
    xor eax, eax
    cmp dword [bld_on], 0
    je .done
    call build_mid
    subss xmm0, [p_x]
    subss xmm1, [p_eye_y]
    subss xmm2, [p_z]
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    mulss xmm0, xmm0
    mulss xmm1, xmm1
    mulss xmm2, xmm2
    addss xmm0, xmm1
    addss xmm0, xmm2
    sqrtss xmm0, xmm0
    movss [rsp+12], xmm0
    xor eax, eax
    comiss xmm0, [c_bld_reach]
    jae .done
    ; forward . to-stairs >= 0.9 |to-stairs|
    movss xmm0, [p_pitch]
    call cosf
    movss [rsp+16], xmm0
    movss xmm0, [p_yaw]
    call sinf
    mulss xmm0, [rsp+16]
    mulss xmm0, [rsp+0]
    movss [rsp+20], xmm0                ; -(fx * dx)
    movss xmm0, [p_yaw]
    call cosf
    mulss xmm0, [rsp+16]
    mulss xmm0, [rsp+8]
    addss xmm0, [rsp+20]
    xorps xmm0, [c_sign_mask]           ; fx dx + fz dz
    movss [rsp+20], xmm0
    movss xmm0, [p_pitch]
    call sinf
    mulss xmm0, [rsp+4]
    addss xmm0, [rsp+20]
    movss xmm1, [c_bld_aim]
    mulss xmm1, [rsp+12]
    xor eax, eax
    comiss xmm0, xmm1
    jb .done
    call build_mid
    movaps xmm3, xmm0
    movaps xmm4, xmm1
    movaps xmm5, xmm2
    movss xmm0, [p_x]
    movss xmm1, [p_eye_y]
    movss xmm2, [p_z]
    call line_of_sight_3d
    test eax, eax
    jz .done
    mov edi, 1
    call build_break
.done:
    EPILOGUE

; build_hit_point(xmm0..2 = a point) -> eax 1 if it's on T's stairs (for the
; hookshot: hook them and you yank them down)
build_hit_point:
    PROLOGUE 48
    xor eax, eax
    cmp dword [bld_on], 0
    je .done
    ; t = clamp(((p - a).(b - a)) / |b - a|^2, 0, 1)
    subss xmm0, [bld_ax]
    subss xmm1, [bld_ay]
    subss xmm2, [bld_az]
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss xmm3, [bld_bx]
    subss xmm3, [bld_ax]
    movss xmm4, [bld_by]
    subss xmm4, [bld_ay]
    movss xmm5, [bld_bz]
    subss xmm5, [bld_az]
    movss [rsp+12], xmm3
    movss [rsp+16], xmm4
    movss [rsp+20], xmm5
    mulss xmm0, xmm3
    mulss xmm1, xmm4
    mulss xmm2, xmm5
    addss xmm0, xmm1
    addss xmm0, xmm2
    mulss xmm3, xmm3
    mulss xmm4, xmm4
    mulss xmm5, xmm5
    addss xmm3, xmm4
    addss xmm3, xmm5
    FLD xmm4, 0.0001
    maxss xmm3, xmm4
    divss xmm0, xmm3
    maxss xmm0, [c_zero]
    minss xmm0, [c_one]
    ; distance^2 from the closest point
    movss xmm1, [rsp+12]
    mulss xmm1, xmm0
    subss xmm1, [rsp+0]
    mulss xmm1, xmm1
    movss xmm2, [rsp+16]
    mulss xmm2, xmm0
    subss xmm2, [rsp+4]
    mulss xmm2, xmm2
    addss xmm1, xmm2
    movss xmm2, [rsp+20]
    mulss xmm2, xmm0
    subss xmm2, [rsp+8]
    mulss xmm2, xmm2
    addss xmm1, xmm2
    xor eax, eax
    comiss xmm1, [c_bld_hit]
    jae .done
    mov eax, 1
.done:
    EPILOGUE

; enemy_portal_follow(xmm0..2 = in front of the entry, xmm3..5 = in front of
; the exit) -- you just went through. Chasing you, T goes after you (the
; nemesis may make him follow even when he only heard it).
enemy_portal_follow:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    movss [rsp+16], xmm4
    movss [rsp+20], xmm5
    cmp dword [t_state], T_CHASE
    je .follow
    cmp dword [nm_portal_any], 0
    je .done
    subss xmm0, [t_x]
    mulss xmm0, xmm0
    subss xmm2, [t_z]
    mulss xmm2, xmm2
    addss xmm0, xmm2
    subss xmm1, [t_y]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    comiss xmm0, [c_por_any]
    jae .done
.follow:
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+8]
    call node_at_pos
    mov ebx, eax
    mov edi, eax
    call node_walkable
    test eax, eax
    jz .done
    mov [t_por_node], ebx
    mov eax, [rsp+0]
    mov [t_por_ex], eax
    mov eax, [rsp+4]
    mov [t_por_ey], eax
    mov eax, [rsp+8]
    mov [t_por_ez], eax
    mov eax, [rsp+12]
    mov [t_por_xx], eax
    mov eax, [rsp+16]
    mov [t_por_xy], eax
    mov eax, [rsp+20]
    mov [t_por_xz], eax
    mov eax, [c_por_life]
    mov [t_por_life], eax
    mov dword [t_por_on], 1
    ; (you'd have got away through it)
    mov edi, 1
    call nemesis_note
.done:
    EPILOGUE

; t_through_portal -- T at the entry: out of the exit, still after you
t_through_portal:
    PROLOGUE 16
    mov dword [t_por_on], 0
    movss xmm0, [t_por_xx]
    movss xmm1, [t_por_xy]
    movss xmm2, [t_por_xz]
    call node_at_pos
    mov ebx, eax
    mov edi, eax
    call node_walkable
    test eax, eax
    jz .done
    mov edi, ebx
    call node_center
    movss [t_x], xmm0
    movss [t_y], xmm1
    movss [t_z], xmm2
    mov [t_node], ebx
    mov [t_next], ebx
    mov [t_goal], ebx
    mov [t_last_known], ebx
    mov dword [path_len], 0
    mov dword [path_pos], 0
    mov dword [t_repath], 0
    mov dword [t_lost], 0
    mov dword [t_state], T_CHASE
    mov edi, 2
    call snd_portal_enter
    lea rdi, [m_t_portal]
    mov esi, 0xFF3B3BFF
    xor edx, edx
    call hud_message
.done:
    EPILOGUE

; enemy_lure(edi=node) -- something T wants (a can of Dew) is there: if he's
; just wandering and could stand there, he heads for it
enemy_lure:
    PROLOGUE 16
    cmp dword [t_state], T_WANDER
    jne .no
    mov ebx, edi
    call node_walkable
    test eax, eax
    jz .no
    mov edi, ebx
    call set_goal
.no:
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
; enemy_hear(xmm0=X, xmm1=Y, xmm2=Z, xmm3=radius) -- a noise at a point
; (Y = the floor it happened on). T hears it if the path the sound takes --
; the straight 3D distance plus whatever it goes through (sound_occlusion:
; floor slabs muffle a lot, walls some, an open atrium or stairwell nothing)
; -- is within the radius.
; -----------------------------------------------------------------------------
enemy_hear:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    PCT xmm4, cfg_t_hear                ; custom run: T's hearing
    mulss xmm3, xmm4
    movss xmm4, [t_dew]
    comiss xmm4, [c_zero]
    jbe .flat_hear
    mulss xmm3, [c_dew_sense]
.flat_hear:
    movss [rsp+12], xmm3
    cmp dword [t_state], T_CHASE
    je .ignore
    movss xmm4, [t_stun]
    comiss xmm4, [c_zero]
    ja .ignore
    call hear_distance
    comiss xmm0, [rsp+12]
    ja .ignore
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+8]
    call node_at_pos
    mov ebx, eax
    mov edi, eax
    call node_walkable
    test eax, eax
    jz .ignore
    mov dword [t_state], T_INVESTIGATE
    mov edi, ebx
    call set_goal
.ignore:
    EPILOGUE

; t_eye_to_player -> xmm0..2 = T's eyes, xmm3/xmm5 = your x/z (caller sets xmm4)
t_eye_to_player:
    movss xmm0, [t_x]
    movss xmm1, [t_y]
    addss xmm1, [c_t_eye]
    movss xmm2, [t_z]
    movss xmm3, [p_x]
    movss xmm5, [p_z]
    ret

; hear_distance(xmm0=X, xmm1=Y, xmm2=Z of a sound on a floor) -> xmm0 = how
; far it effectively is from T's ears (both measured a metre above the floor)
hear_distance:
    PROLOGUE 32
    addss xmm1, [c_one]
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss xmm3, [t_x]
    movss xmm4, [t_y]
    addss xmm4, [c_one]
    movss xmm5, [t_z]
    call dist3
    movss [rsp+12], xmm0
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+8]
    movss xmm3, [t_x]
    movss xmm4, [t_y]
    addss xmm4, [c_one]
    movss xmm5, [t_z]
    call sound_occlusion
    addss xmm0, [rsp+12]
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
    mov eax, [nm_stun]
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
    ; the Dew wears off
    movss xmm1, [t_dew]
    subss xmm1, xmm0
    maxss xmm1, [c_zero]
    movss [t_dew], xmm1
    call ai_timers

    ; ---- where is the player on the node graph?
    movss xmm0, [p_x]
    movss xmm1, [p_y]
    movss xmm2, [p_z]
    call node_at_pos
    mov [rsp+4], eax
    mov edi, eax
    call node_walkable                  ; could T stand where you are?
    mov [rsp+20], eax
    call player_floor                   ; (floor/x/y only for "prefer this storey")
    mov [rsp+8], eax
    movss xmm0, [p_x]
    mulss xmm0, [c_inv_cell]
    cvttss2si eax, xmm0
    mov [rsp+12], eax
    movss xmm0, [p_z]
    mulss xmm0, [c_inv_cell]
    cvttss2si eax, xmm0
    mov [rsp+16], eax

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
    mov [t_hear_d], eax
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

    ; sight is a real 3D ray: across the atrium, down a stairwell, through a
    ; hatch -- not just "on the same storey"
    mov dword [t_sees], 0
    cmp dword [rsp+28], 0               ; in a safe room: invisible
    jne .perceived
    movss xmm1, [c_sight_flash]
    cmp dword [p_flash_on], 0
    jne .have_range
    movss xmm1, [c_sight_dark]
    cmp dword [p_crouch], 0
    je .have_range
    movss xmm1, [c_sight_crouch]
.have_range:
    PCT xmm2, cfg_t_vision              ; custom run: T's eyesight
    mulss xmm1, xmm2
    movss xmm2, [t_dew]
    comiss xmm2, [c_zero]
    jbe .flat_eyes
    mulss xmm1, [c_dew_sense]
.flat_eyes:
    movss [rsp+52], xmm1
    call t_eye_to_player
    movss xmm4, [p_eye_y]
    call dist3
    comiss xmm0, [rsp+52]
    jae .perceived
    call t_eye_to_player                ; your head...
    movss xmm4, [p_eye_y]
    call line_of_sight_3d
    test eax, eax
    jnz .seen
    call t_eye_to_player                ; ...or your body
    movss xmm4, [p_y]
    addss xmm4, [c_torso]
    call line_of_sight_3d
.seen:
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

    ; ---- the director: how comfortable are you?
    cmp dword [t_state], T_CHASE
    jne .dir_calm
    mov dword [dir_calm], 0
    movss xmm0, [chase_min]
    minss xmm0, [rsp+24]
    movss [chase_min], xmm0
    jmp .dir_done
.dir_calm:
    movss xmm0, [dir_calm]
    addss xmm0, [rsp+0]
    movss [dir_calm], xmm0
    cmp dword [prev_state], T_CHASE
    jne .dir_done
    ; a chase just ended: a close call? then he backs off for a bit
    movss xmm0, [chase_min]
    comiss xmm0, [c_dir_close]
    jae .not_close
    mov eax, [c_dir_relax]
    mov [dir_relax], eax
.not_close:
    ; lost you into a safe room: (nemesis) he waits outside
    cmp dword [rsp+28], 0
    je .no_camp
    mov eax, [nm_camp_time]
    mov [t_camp], eax
.no_camp:
    mov eax, [c_big_d]
    mov [chase_min], eax
.dir_done:
    mov eax, [t_state]
    mov [prev_state], eax

    ; ---- up on something he can't walk to? he builds his way up
    cmp dword [t_build], 0
    jne .building
    cmp dword [bld_on], 0
    jne .no_build
    movss xmm0, [bld_cd]
    comiss xmm0, [c_zero]
    ja .no_build
    cmp dword [t_state], T_CHASE
    jne .no_build
    cmp dword [t_sees], 0
    je .no_build
    cmp dword [rsp+20], 0
    jne .no_build
    cmp dword [rsp+28], 0
    jne .no_build
    movss xmm0, [rsp+24]
    comiss xmm0, [c_bld_rng]
    jae .no_build
    movss xmm0, [p_y]
    subss xmm0, [t_y]
    comiss xmm0, [c_bld_dy0]
    jb .no_build
    comiss xmm0, [c_bld_dy1]
    ja .no_build
    call start_build
.building:
    movss xmm0, [rsp+0]
    call build_update
    jmp .outputs
.no_build:

    ; ---- after you through a portal
    cmp dword [t_por_on], 0
    je .no_portal
    cmp dword [t_sees], 0
    jne .no_portal
    movss xmm0, [t_x]
    subss xmm0, [t_por_ex]
    mulss xmm0, xmm0
    movss xmm1, [t_z]
    subss xmm1, [t_por_ez]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [t_y]
    subss xmm1, [t_por_ey]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    comiss xmm0, [c_por_near]
    jae .to_portal
    call t_through_portal
    jmp .outputs
.to_portal:
    mov dword [t_state], T_CHASE
    mov dword [t_lost], 0
    mov edi, [t_por_node]
    call set_goal
    jmp .not_arrived
.no_portal:

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
    cmp dword [t_state], T_INVESTIGATE
    jne .hunch
    mov dword [t_state], T_WANDER
.hunch:
    ; (nemesis) waiting outside the safe room you ran into
    movss xmm0, [t_camp]
    comiss xmm0, [c_zero]
    ja .not_arrived
    ; the director: backing off after a close call...
    movss xmm0, [dir_relax]
    comiss xmm0, [c_zero]
    jbe .no_relax
    mov edi, -1
    mov esi, 1
    mov edx, [rsp+8]
    mov ecx, [rsp+12]
    mov r8d, [rsp+16]
    mov r9d, [c_dir_away]
    call random_node
    mov edi, eax
    call set_goal
    jmp .not_arrived
.no_relax:
    ; ...or you've been comfortable too long: he's nudged your way
    movss xmm0, [dir_calm]
    comiss xmm0, [c_dir_push]
    jbe .no_push
    cmp dword [rsp+20], 0
    je .no_push
    cmp dword [rsp+28], 0
    jne .no_push
    mov eax, [c_dir_again]
    mov [dir_calm], eax
    mov dword [t_state], T_INVESTIGATE
    mov edi, [rsp+4]
    call set_goal
    jmp .not_arrived
.no_push:
    cmp dword [rsp+20], 0
    je .wander_goal
    ; near enough for a hunch? (3D; being a storey apart counts extra)
    movss xmm0, [p_y]
    subss xmm0, [t_y]
    andps xmm0, [c_abs_mask]
    mulss xmm0, [c_hunch_y]
    addss xmm0, [rsp+24]
    comiss xmm0, [c_hunch_r]
    ja .wander_goal
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
    PCT xmm1, cfg_t_speed               ; custom run: T's speed
    mulss xmm0, xmm1
    mulss xmm0, [nm_speed]              ; (nemesis: a grudge)
    movss xmm1, [t_dew]
    comiss xmm1, [c_zero]
    jbe .flat_legs
    mulss xmm0, [c_dew_speed]
.flat_legs:
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
    movaps xmm4, xmm1
    subss xmm4, [t_y]
    mulss xmm4, xmm4
    addss xmm3, xmm4
    sqrtss xmm3, xmm3                   ; d (3D: ramps, drops off ledges)
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

.outputs:
    ; ---- outputs: distance, hearing distance and "caught"
    movss xmm0, [p_x]
    movss xmm1, [p_y]
    movss xmm2, [p_z]
    call hear_distance
    movss [t_hear_d], xmm0
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
