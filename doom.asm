; Doom/Wolfenstein-style raycaster conversion of the original ASCII game.
; x86-64 NASM, SysV calling convention, linked against SDL2 + libm.
; Reuses board.txt as the wall map and keeps the grid-based DFS chase AI
; from the original game.asm, ported to register-arg calling convention.

%define MAP_W 59
%define MAP_H 31
%define FB_W 320
%define FB_H 200
%define WIN_SCALE 3
%define WIN_W (FB_W*WIN_SCALE)
%define WIN_H (FB_H*WIN_SCALE)

%define T_MOVE_INTERVAL 24
%define CHASE_RADIUS 20
%define SPAWN_MIN_DIST 15
%define INFINITY_D 0x7fffffff
%define UNREACHABLE_D 0x7ffffffe

%define SDL_INIT_VIDEO 0x20
%define SDL_WINDOWPOS_UNDEFINED 0x1fff0000
%define SDL_TEXTUREACCESS_STREAMING 1
%define SDL_PIXELFORMAT_ARGB8888 0x16362004
%define SDL_QUIT_EVENT 0x100
%define SDL_KEYDOWN 0x300
%define SDL_KEYUP 0x301
%define SDLK_ESCAPE 27
%define SDLK_w 119
%define SDLK_a 97
%define SDLK_s 115
%define SDLK_d 100
%define SDL_SCANCODE_A 4
%define SDL_SCANCODE_D 7
%define SDL_SCANCODE_S 22
%define SDL_SCANCODE_W 26
%define SDL_SCANCODE_ESCAPE 41
%define SDL_SCANCODE_SPACE 44
%define STUN_FRAMES 90
%define NUM_WEAPONS 2
%define IMG_INIT_JPG 1

; SDL_Surface field offsets (64-bit build, confirmed via offsetof())
%define SURF_W 16
%define SURF_H 20
%define SURF_PITCH 24
%define SURF_PIXELS 32

segment .data

board_file      db 'board.txt',0
mode_r          db 'r',0

win_title       db 'Beacom at 2am',0
t_sprite_file   db 'T_Sprite.jpeg',0

intro_lore      db "cat intro.txt | while read line; do echo $line | lolcat && sleep 1; done;", 0
question        db "DO YOU WISH TO EMBARK ON THIS JOURNEY? (YES=1, NO=0)",10,0
omniman         db "cat rusure.txt | lolcat", 0
usure           db "Are you sure? (YES=1, NO=0)",10,0
prompt_seed     db `Please enter your game seed (-1 for random):`,0
int_format      db `%d`,0
img_err_fmt     db "Could not load T sprite: %s",10,0
msg_weapon_pickup db "You grabbed a deauth packet! Press SPACE to fire it and scramble T's tracking.",10,0
msg_weapon_use  db 10,"*** DEAUTH PACKET FIRED - T's connection drops! ***",10,0
msg_weapon_none db "You have no deauth packets.",10,0
msg_safe_enter  db 10,"You feel a comforting aura here. T cannot follow you inside.",10,0
msg_safe_exit   db "You step back out into the dark...",10,0

dir_ahead_str   db "straight ahead",0
dir_behind_str  db "behind you",0
msg_prox_medium db 10,"You think you hear something moving in the halls...",10,0
msg_prox_close_fmt db 10,"Footsteps are getting louder -- %s!",10,0
msg_prox_danger_fmt db 10,"*** T IS RIGHT ON TOP OF YOU -- %s! COVER IS BLOWN! ***",10,0

msg_see_key     db "You see a wireshark packet capture flicker in the dark...",10,0
msg_caught      db 10,"T has found you.",10,0
msg_won         db 10,"You dragged Y out of the dark. You survived Beacom.",10,0

game_over_cmd   db "cat T.txt | lolcat",0
game_won_cmd    db "cat W.txt | lolcat",0

; ---- float constants ----
f_one           dd 1.0
f_neg_one       dd -1.0
f_half          dd 0.5
f_two           dd 2.0
f_big           dd 1.0e30
f_epsilon       dd 0.0001
f_move_speed    dd 0.06
f_rot_speed     dd 0.045
f_plane_len     dd 0.66
f_radius        dd 0.20
f_fbw           dd 320.0
f_fbh           dd 200.0
f_halffbw       dd 160.0
f_halffbh       dd 100.0
f_fog_k         dd 0.05
f_fog_min       dd 0.20
f_start_x       dd 1.5
f_start_y       dd 1.5
f_catch_radius_sq dd 0.25          ; 0.5 units, squared
f_vign_step     dd 0.18
f_vign_pulse_speed dd 0.15
f_vign_pulse_amp dd 0.20
f_vign_tint_r   dd 40.0

rot_cos         dd 0.0
rot_sin         dd 0.0

segment .bss

board           resb MAP_W*MAP_H
pathmem         resd MAP_W*MAP_H
zbuffer         resd FB_W
framebuf        resd FB_W*FB_H

window_ptr      resq 1
t_surface       resq 1
t_has_texture   resb 1
renderer_ptr    resq 1
texture_ptr     resq 1
event_buf       resb 64

INPUT           resd 1

player_x        resd 1
player_y        resd 1
dir_x           resd 1
dir_y           resd 1
plane_x         resd 1
plane_y         resd 1

t_x             resd 1
t_y             resd 1
t_goal_x        resd 1
t_goal_y        resd 1

goal_x          resd 1
goal_y          resd 1
start_x_i       resd 1
start_y_i       resd 1

item_gx         resd 3
item_gy         resd 3
item_active     resb 3

weapon_gx       resd NUM_WEAPONS
weapon_gy       resd NUM_WEAPONS
weapon_active   resb NUM_WEAPONS
weapon_count    resd 1
t_stun_timer    resd 1
was_in_safe_room resb 1
last_proximity_band resd 1
key_space       resb 1
space_prev      resb 1

inventory       resd 1
game_state      resd 1          ; 0 = playing, 1 = lost, 2 = won
frame_count     resd 1

key_w           resb 1
key_a           resb 1
key_s           resb 1
key_d           resb 1
running         resb 1

rand_open_y     resd 1
scratch_up      resd 1
scratch_down    resd 1
t_unreachable_flag resd 1

segment .text

global main
extern printf
extern scanf
extern system
extern sleep
extern srand
extern rand
extern time
extern fopen
extern fread
extern fgetc
extern fclose
extern sinf
extern cosf
extern SDL_Init
extern SDL_CreateWindow
extern SDL_CreateRenderer
extern SDL_CreateTexture
extern SDL_UpdateTexture
extern SDL_RenderClear
extern SDL_RenderCopy
extern SDL_RenderPresent
extern SDL_PollEvent
extern SDL_GetKeyboardState
extern SDL_Delay
extern SDL_DestroyTexture
extern SDL_DestroyRenderer
extern SDL_DestroyWindow
extern SDL_Quit
extern SDL_ConvertSurfaceFormat
extern SDL_FreeSurface
extern IMG_Init
extern IMG_Load
extern IMG_Quit
extern SDL_GetError

; ============================================================
; helpers with no external calls inside (safe to use any scratch reg)
; ============================================================

; is_wall(x=edi, y=esi) -> eax = 1 if wall/out-of-bounds, else 0
is_wall:
    push rbp
    mov rbp, rsp
    cmp esi, 0
    jl .wall
    cmp esi, MAP_H
    jge .wall
    cmp edi, 0
    jl .wall
    cmp edi, MAP_W
    jge .wall
    mov eax, esi
    imul eax, MAP_W
    add eax, edi
    lea r8, [rel board]
    movzx ecx, byte [r8+rax]
    cmp cl, ' '
    je .open
    cmp cl, 'S'
    je .open
    cmp cl, 'B'
    je .open
    jmp .wall
.open:
    xor eax, eax
    jmp .done
.wall:
    mov eax, 1
.done:
    mov rsp, rbp
    pop rbp
    ret

; dist_manhattan(x1=edi,y1=esi,x2=edx,y2=ecx) -> eax
dist_manhattan:
    push rbp
    mov rbp, rsp
    mov eax, edi
    sub eax, edx
    cmp eax, 0
    jge .xok
    neg eax
.xok:
    mov r8d, esi
    sub r8d, ecx
    cmp r8d, 0
    jge .yok
    neg r8d
.yok:
    add eax, r8d
    mov rsp, rbp
    pop rbp
    ret

; ============================================================
; board / world setup
; ============================================================

load_board:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    lea rdi, [rel board_file]
    lea rsi, [rel mode_r]
    call fopen
    mov [rbp-8], rax

    mov dword [rbp-16], 0
.read_loop:
    mov eax, [rbp-16]
    cmp eax, MAP_H
    je .read_loop_end

    mov eax, [rbp-16]
    imul eax, MAP_W
    lea r8, [rel board]
    add r8, rax

    mov rdi, r8
    mov esi, 1
    mov edx, MAP_W
    mov rcx, [rbp-8]
    call fread

    ; consume the rest of the line up to and including '\n', regardless of
    ; whether the file has LF or CRLF endings (Windows checkouts commonly
    ; convert board.txt to CRLF, and a single fgetc() only eats one byte of
    ; that, which shifts every subsequent row read by one character)
.slurp_eol:
    mov rdi, [rbp-8]
    call fgetc
    cmp eax, 10
    je .slurp_done
    cmp eax, -1
    je .slurp_done
    jmp .slurp_eol
.slurp_done:

    inc dword [rbp-16]
    jmp .read_loop
.read_loop_end:

    mov rdi, [rbp-8]
    call fclose

    mov rsp, rbp
    pop rbp
    ret

find_goal:
    push rbp
    mov rbp, rsp

    mov dword [rel goal_x], 1
    mov dword [rel goal_y], 1
    mov dword [rel start_x_i], 1
    mov dword [rel start_y_i], 1

    xor ecx, ecx
.scan:
    cmp ecx, MAP_W*MAP_H
    jge .done
    lea r8, [rel board]
    movzx edx, byte [r8+rcx]
    cmp dl, 'B'
    jne .next
    mov eax, ecx
    xor edx, edx
    mov r9d, MAP_W
    div r9d
    mov [rel goal_y], eax
    mov [rel goal_x], edx
    jmp .done
.next:
    inc ecx
    jmp .scan
.done:
    mov rsp, rbp
    pop rbp
    ret

; rand_open_cell() -> eax = x, [rand_open_y] = y  (a floor cell, i.e. board == ' ')
rand_open_cell:
    push rbp
    mov rbp, rsp
    sub rsp, 16
.retry:
    call rand
    xor edx, edx
    mov ecx, MAP_H
    div ecx
    mov [rbp-4], edx

    call rand
    xor edx, edx
    mov ecx, MAP_W
    div ecx
    mov [rbp-8], edx

    mov eax, [rbp-4]
    imul eax, MAP_W
    add eax, [rbp-8]
    lea r8, [rel board]
    movzx ecx, byte [r8+rax]
    cmp cl, ' '
    jne .retry

    mov eax, [rbp-4]
    mov [rel rand_open_y], eax
    mov eax, [rbp-8]

    mov rsp, rbp
    pop rbp
    ret

spawn_items:
    push rbp
    mov rbp, rsp
    push r12
    sub rsp, 8
    xor r12d, r12d
.loop:
    cmp r12d, 3
    jge .done
    call rand_open_cell
    mov r9d, eax
    mov r10d, [rel rand_open_y]
    lea rcx, [rel item_gx]
    mov [rcx+r12*4], r9d
    lea rcx, [rel item_gy]
    mov [rcx+r12*4], r10d
    lea rcx, [rel item_active]
    mov byte [rcx+r12], 1
    inc r12d
    jmp .loop
.done:
    add rsp, 8
    pop r12
    pop rbp
    ret

spawn_weapons:
    push rbp
    mov rbp, rsp
    push r12
    sub rsp, 8
    xor r12d, r12d
.loop:
    cmp r12d, NUM_WEAPONS
    jge .done
    call rand_open_cell
    mov r9d, eax
    mov r10d, [rel rand_open_y]
    lea rcx, [rel weapon_gx]
    mov [rcx+r12*4], r9d
    lea rcx, [rel weapon_gy]
    mov [rcx+r12*4], r10d
    lea rcx, [rel weapon_active]
    mov byte [rcx+r12], 1
    inc r12d
    jmp .loop
.done:
    add rsp, 8
    pop r12
    pop rbp
    ret

spawn_T:
    push rbp
    mov rbp, rsp
.retry:
    call rand_open_cell
    mov [rel t_x], eax
    mov eax, [rel rand_open_y]
    mov [rel t_y], eax

    mov edi, [rel t_x]
    mov esi, [rel t_y]
    mov edx, [rel start_x_i]
    mov ecx, [rel start_y_i]
    call dist_manhattan
    cmp eax, SPAWN_MIN_DIST
    jle .retry

    mov eax, [rel t_x]
    mov [rel t_goal_x], eax
    mov eax, [rel t_y]
    mov [rel t_goal_y], eax

    mov rsp, rbp
    pop rbp
    ret

; ============================================================
; chase AI: DFS flood fill from T's goal, then step T downhill
; ============================================================

; search_cell(steps=edi, y=esi, x=edx)
search_cell:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx

    cmp r13d, 0
    jl .ret
    cmp r13d, MAP_H
    jge .ret
    cmp r14d, 0
    jl .ret
    cmp r14d, MAP_W
    jge .ret

    mov eax, r13d
    imul eax, MAP_W
    add eax, r14d
    mov ecx, eax
    lea r8, [rel pathmem]
    mov edx, [r8+rcx*4]
    cmp edx, UNREACHABLE_D
    je .ret
    cmp r12d, edx
    jge .ret

    mov [r8+rcx*4], r12d

    lea edi, [r12+1]
    mov esi, r13d
    lea edx, [r14+1]
    call search_cell

    lea edi, [r12+1]
    mov esi, r13d
    lea edx, [r14-1]
    call search_cell

    lea edi, [r12+1]
    lea esi, [r13+1]
    mov edx, r14d
    call search_cell

    lea edi, [r12+1]
    lea esi, [r13-1]
    mov edx, r14d
    call search_cell

.ret:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbp
    ret

fill_pathmem:
    push rbp
    mov rbp, rsp
    xor ecx, ecx
.loop:
    cmp ecx, MAP_W*MAP_H
    jge .filled
    lea r8, [rel board]
    movzx eax, byte [r8+rcx]
    mov edx, UNREACHABLE_D
    cmp al, ' '
    je .open
    cmp al, 'B'
    jne .store
.open:
    mov edx, INFINITY_D
.store:
    lea r9, [rel pathmem]
    mov [r9+rcx*4], edx
    inc ecx
    jmp .loop
.filled:
    mov edi, 0
    mov esi, [rel t_goal_y]
    mov edx, [rel t_goal_x]
    call search_cell
    mov rsp, rbp
    pop rbp
    ret

; picks the neighbor of T with the smallest pathmem value and moves T there.
; returns eax=1 if T's own cell was never reached (goal unreachable), else 0.
t_step_toward_goal:
    push rbp
    mov rbp, rsp

    lea r8, [rel pathmem]

    mov eax, [rel t_y]
    imul eax, MAP_W
    add eax, [rel t_x]
    mov r9d, [r8+rax*4]
    cmp r9d, INFINITY_D
    jne .reachable
    mov eax, 1
    jmp .done
.reachable:
    mov eax, [rel t_y]
    imul eax, MAP_W
    mov ecx, [rel t_x]
    dec ecx
    add eax, ecx
    mov r10d, [r8+rax*4]

    mov eax, [rel t_y]
    imul eax, MAP_W
    mov ecx, [rel t_x]
    inc ecx
    add eax, ecx
    mov r11d, [r8+rax*4]

    mov eax, [rel t_y]
    dec eax
    imul eax, MAP_W
    add eax, [rel t_x]
    mov edx, [r8+rax*4]
    mov [rel scratch_up], edx

    mov eax, [rel t_y]
    inc eax
    imul eax, MAP_W
    add eax, [rel t_x]
    mov edx, [r8+rax*4]
    mov [rel scratch_down], edx

    mov eax, r10d
    mov ecx, 0
    cmp r11d, eax
    jge .chk_up
    mov eax, r11d
    mov ecx, 1
.chk_up:
    mov edx, [rel scratch_up]
    cmp edx, eax
    jge .chk_down
    mov eax, edx
    mov ecx, 2
.chk_down:
    mov edx, [rel scratch_down]
    cmp edx, eax
    jge .apply
    mov eax, edx
    mov ecx, 3
.apply:
    cmp eax, INFINITY_D
    jne .move
    mov eax, 1
    jmp .done
.move:
    cmp ecx, 0
    jne .not_left
    dec dword [rel t_x]
    jmp .moved
.not_left:
    cmp ecx, 1
    jne .not_right
    inc dword [rel t_x]
    jmp .moved
.not_right:
    cmp ecx, 2
    jne .not_up
    dec dword [rel t_y]
    jmp .moved
.not_up:
    inc dword [rel t_y]
.moved:
    xor eax, eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; t_goal_logic(unreachable=edi)
t_goal_logic:
    push rbp
    mov rbp, rsp

    cmp edi, 0
    jne .pick_random

    call rand
    and eax, 15
    cmp eax, 0
    jne .check_arrival
    cvttss2si eax, [rel player_x]
    mov [rel t_goal_x], eax
    cvttss2si eax, [rel player_y]
    mov [rel t_goal_y], eax
    jmp .done

.check_arrival:
    mov eax, [rel t_x]
    cmp eax, [rel t_goal_x]
    jne .done
    mov eax, [rel t_y]
    cmp eax, [rel t_goal_y]
    jne .done

    cvttss2si edi, [rel player_x]
    cvttss2si esi, [rel player_y]
    mov edx, [rel t_x]
    mov ecx, [rel t_y]
    call dist_manhattan
    cmp eax, CHASE_RADIUS
    jg .pick_random

    cvttss2si eax, [rel player_x]
    mov [rel t_goal_x], eax
    cvttss2si eax, [rel player_y]
    mov [rel t_goal_y], eax
    jmp .done

.pick_random:
    call rand_open_cell
    mov [rel t_goal_x], eax
    mov eax, [rel rand_open_y]
    mov [rel t_goal_y], eax

.done:
    mov rsp, rbp
    pop rbp
    ret

move_t_tick:
    push rbp
    mov rbp, rsp

    mov eax, [rel t_stun_timer]
    cmp eax, 0
    jle .not_stunned
    dec eax
    mov [rel t_stun_timer], eax
    jmp .done
.not_stunned:
    mov edi, [rel t_unreachable_flag]
    call t_goal_logic

    call fill_pathmem

    call t_step_toward_goal
    mov [rel t_unreachable_flag], eax
.done:
    mov rsp, rbp
    pop rbp
    ret

; consumes one deauth packet (if any): teleports T far from the player and
; freezes it for STUN_FRAMES ticks. t_goal_logic will naturally pick a fresh
; wander target once it unfreezes, since T will already be "at" its goal.
use_weapon:
    push rbp
    mov rbp, rsp

    mov eax, [rel weapon_count]
    cmp eax, 0
    jg .have_weapon
    lea rdi, [rel msg_weapon_none]
    xor eax, eax
    call printf
    jmp .done

.have_weapon:
    dec dword [rel weapon_count]
    lea rdi, [rel msg_weapon_use]
    xor eax, eax
    call printf

.retry:
    call rand_open_cell
    mov [rel t_x], eax
    mov eax, [rel rand_open_y]
    mov [rel t_y], eax

    mov edi, [rel t_x]
    mov esi, [rel t_y]
    cvttss2si edx, [rel player_x]
    cvttss2si ecx, [rel player_y]
    call dist_manhattan
    cmp eax, SPAWN_MIN_DIST
    jle .retry

    mov eax, [rel t_x]
    mov [rel t_goal_x], eax
    mov eax, [rel t_y]
    mov [rel t_goal_y], eax

    mov dword [rel t_stun_timer], STUN_FRAMES
.done:
    mov rsp, rbp
    pop rbp
    ret

; ============================================================
; input + movement
; ============================================================

; drains the event queue (only cares about the window-close 'X' button),
; then reads continuous key-held state directly from SDL so W/A/S/D can't
; get stuck off from a missed/raced KEYUP.
handle_events:
    push rbp
    mov rbp, rsp
.poll:
    lea rdi, [rel event_buf]
    call SDL_PollEvent
    cmp eax, 0
    je .poll_done
    mov ecx, [rel event_buf]
    cmp ecx, SDL_QUIT_EVENT
    jne .poll
    mov byte [rel running], 0
    jmp .poll
.poll_done:
    xor edi, edi
    call SDL_GetKeyboardState

    movzx ecx, byte [rax+SDL_SCANCODE_W]
    mov [rel key_w], cl
    movzx ecx, byte [rax+SDL_SCANCODE_A]
    mov [rel key_a], cl
    movzx ecx, byte [rax+SDL_SCANCODE_S]
    mov [rel key_s], cl
    movzx ecx, byte [rax+SDL_SCANCODE_D]
    mov [rel key_d], cl
    movzx ecx, byte [rax+SDL_SCANCODE_SPACE]
    mov [rel key_space], cl

    movzx ecx, byte [rax+SDL_SCANCODE_ESCAPE]
    cmp cl, 0
    je .done
    mov byte [rel running], 0
.done:
    mov rsp, rbp
    pop rbp
    ret

; rotates dir/plane vectors by the fixed per-frame step; xmm0 = signed sin (+ for CCW, - for CW)
apply_rotation:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    movss [rbp-4], xmm0

    movss xmm1, [rel rot_cos]

    movss xmm2, [rel dir_x]
    movss xmm3, [rel dir_y]
    movss xmm4, xmm2
    mulss xmm4, xmm1
    movss xmm5, xmm3
    mulss xmm5, [rbp-4]
    subss xmm4, xmm5
    movss xmm6, xmm2
    mulss xmm6, [rbp-4]
    movss xmm7, xmm3
    mulss xmm7, xmm1
    addss xmm6, xmm7
    movss [rel dir_x], xmm4
    movss [rel dir_y], xmm6

    movss xmm2, [rel plane_x]
    movss xmm3, [rel plane_y]
    movss xmm4, xmm2
    mulss xmm4, xmm1
    movss xmm5, xmm3
    mulss xmm5, [rbp-4]
    subss xmm4, xmm5
    movss xmm6, xmm2
    mulss xmm6, [rbp-4]
    movss xmm7, xmm3
    mulss xmm7, xmm1
    addss xmm6, xmm7
    movss [rel plane_x], xmm4
    movss [rel plane_y], xmm6

    mov rsp, rbp
    pop rbp
    ret

update_player:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    ; [rbp-4]=moveX [rbp-8]=moveY [rbp-12]=candX [rbp-16]=candY

    xorps xmm0, xmm0
    movss [rbp-4], xmm0
    movss [rbp-8], xmm0

    cmp byte [rel key_w], 0
    je .chk_s
    movss xmm0, [rel dir_x]
    mulss xmm0, [rel f_move_speed]
    movss xmm1, [rbp-4]
    addss xmm1, xmm0
    movss [rbp-4], xmm1
    movss xmm0, [rel dir_y]
    mulss xmm0, [rel f_move_speed]
    movss xmm1, [rbp-8]
    addss xmm1, xmm0
    movss [rbp-8], xmm1
.chk_s:
    cmp byte [rel key_s], 0
    je .do_x
    movss xmm0, [rel dir_x]
    mulss xmm0, [rel f_move_speed]
    movss xmm1, [rbp-4]
    subss xmm1, xmm0
    movss [rbp-4], xmm1
    movss xmm0, [rel dir_y]
    mulss xmm0, [rel f_move_speed]
    movss xmm1, [rbp-8]
    subss xmm1, xmm0
    movss [rbp-8], xmm1

.do_x:
    movss xmm0, [rel player_x]
    movss xmm1, [rbp-4]
    addss xmm0, xmm1
    movss [rbp-12], xmm0

    xorps xmm2, xmm2
    comiss xmm1, xmm2
    jae .x_pos
    movss xmm3, [rel f_radius]
    subss xmm0, xmm3
    jmp .x_test
.x_pos:
    addss xmm0, [rel f_radius]
.x_test:
    cvttss2si edi, xmm0
    cvttss2si esi, [rel player_y]
    call is_wall
    cmp eax, 1
    je .do_y
    movss xmm0, [rbp-12]
    movss [rel player_x], xmm0

.do_y:
    movss xmm0, [rel player_y]
    movss xmm1, [rbp-8]
    addss xmm0, xmm1
    movss [rbp-16], xmm0

    xorps xmm2, xmm2
    comiss xmm1, xmm2
    jae .y_pos
    movss xmm3, [rel f_radius]
    subss xmm0, xmm3
    jmp .y_test
.y_pos:
    addss xmm0, [rel f_radius]
.y_test:
    cvttss2si edi, [rel player_x]
    cvttss2si esi, xmm0
    call is_wall
    cmp eax, 1
    je .do_rot
    movss xmm0, [rbp-16]
    movss [rel player_y], xmm0

.do_rot:
    cmp byte [rel key_a], 0
    je .chk_d
    xorps xmm0, xmm0
    subss xmm0, [rel rot_sin]
    call apply_rotation
.chk_d:
    cmp byte [rel key_d], 0
    je .finish
    movss xmm0, [rel rot_sin]
    call apply_rotation
.finish:
    add rsp, 32
    pop rbp
    ret

; ============================================================
; game-state checks
; ============================================================

check_pickups:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    sub rsp, 8

    cvttss2si r12d, [rel player_x]
    cvttss2si r13d, [rel player_y]
    xor r14d, r14d

.loop:
    cmp r14d, 3
    jge .done
    lea r10, [rel item_active]
    cmp byte [r10+r14], 0
    je .next
    lea r11, [rel item_gx]
    mov eax, [r11+r14*4]
    cmp eax, r12d
    jne .next
    lea r11, [rel item_gy]
    mov eax, [r11+r14*4]
    cmp eax, r13d
    jne .next
    mov byte [r10+r14], 0
    inc dword [rel inventory]
    lea rdi, [rel msg_see_key]
    xor eax, eax
    call printf
.next:
    inc r14d
    jmp .loop
.done:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbp
    ret

check_weapon_pickups:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    sub rsp, 8

    cvttss2si r12d, [rel player_x]
    cvttss2si r13d, [rel player_y]
    xor r14d, r14d

.loop:
    cmp r14d, NUM_WEAPONS
    jge .done
    lea r10, [rel weapon_active]
    cmp byte [r10+r14], 0
    je .next
    lea r11, [rel weapon_gx]
    mov eax, [r11+r14*4]
    cmp eax, r12d
    jne .next
    lea r11, [rel weapon_gy]
    mov eax, [r11+r14*4]
    cmp eax, r13d
    jne .next
    mov byte [r10+r14], 0
    inc dword [rel weapon_count]
    lea rdi, [rel msg_weapon_pickup]
    xor eax, eax
    call printf
.next:
    inc r14d
    jmp .loop
.done:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbp
    ret

; prints a one-shot message when the player steps into/out of a safe room
check_safe_room:
    push rbp
    mov rbp, rsp

    cvttss2si edi, [rel player_x]
    cvttss2si esi, [rel player_y]
    mov eax, esi
    imul eax, MAP_W
    add eax, edi
    lea r8, [rel board]
    movzx ecx, byte [r8+rax]
    cmp cl, 'S'
    je .in_safe

    cmp byte [rel was_in_safe_room], 0
    je .done
    mov byte [rel was_in_safe_room], 0
    lea rdi, [rel msg_safe_exit]
    xor eax, eax
    call printf
    jmp .done

.in_safe:
    cmp byte [rel was_in_safe_room], 1
    je .done
    mov byte [rel was_in_safe_room], 1
    lea rdi, [rel msg_safe_enter]
    xor eax, eax
    call printf
.done:
    mov rsp, rbp
    pop rbp
    ret

; warns the player textually as T approaches -- a stand-in for spatial audio
; (there's no sound engine here), based on Manhattan distance and whether T
; is roughly ahead of or behind the player's current facing.
check_proximity:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    ; -4 dist -8 band -12 relX -16 relY -24 dirStr(qword)

    cvttss2si edi, [rel player_x]
    cvttss2si esi, [rel player_y]
    mov edx, [rel t_x]
    mov ecx, [rel t_y]
    call dist_manhattan
    mov [rbp-4], eax

    cmp eax, 2
    jg .chk_close
    mov dword [rbp-8], 3
    jmp .band_done
.chk_close:
    cmp eax, 5
    jg .chk_med
    mov dword [rbp-8], 2
    jmp .band_done
.chk_med:
    cmp eax, 9
    jg .is_far
    mov dword [rbp-8], 1
    jmp .band_done
.is_far:
    mov dword [rbp-8], 0
.band_done:

    cmp dword [rbp-8], 2
    jl .no_dir

    cvtsi2ss xmm0, dword [rel t_x]
    addss xmm0, [rel f_half]
    subss xmm0, [rel player_x]
    movss [rbp-12], xmm0
    cvtsi2ss xmm0, dword [rel t_y]
    addss xmm0, [rel f_half]
    subss xmm0, [rel player_y]
    movss [rbp-16], xmm0

    movss xmm0, [rel dir_x]
    mulss xmm0, [rbp-12]
    movss xmm1, [rel dir_y]
    mulss xmm1, [rbp-16]
    addss xmm0, xmm1
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jae .dir_ahead
    lea rax, [rel dir_behind_str]
    jmp .dir_store
.dir_ahead:
    lea rax, [rel dir_ahead_str]
.dir_store:
    mov [rbp-24], rax
.no_dir:

    mov eax, [rbp-8]
    mov ecx, [rel last_proximity_band]
    cmp eax, ecx
    jg .print_now
    cmp eax, 3
    jne .skip_print
    mov eax, [rel frame_count]
    xor edx, edx
    mov ecx, 45
    div ecx
    cmp edx, 0
    jne .skip_print
    mov eax, 3
.print_now:
    cmp eax, 1
    jne .try2
    lea rdi, [rel msg_prox_medium]
    xor eax, eax
    call printf
    jmp .skip_print
.try2:
    cmp eax, 2
    jne .try3
    mov rsi, [rbp-24]
    lea rdi, [rel msg_prox_close_fmt]
    xor eax, eax
    call printf
    jmp .skip_print
.try3:
    cmp eax, 3
    jne .skip_print
    mov rsi, [rbp-24]
    lea rdi, [rel msg_prox_danger_fmt]
    xor eax, eax
    call printf
.skip_print:
    mov eax, [rbp-8]
    mov [rel last_proximity_band], eax

    mov rsp, rbp
    pop rbp
    ret

; catch test uses actual continuous distance to T's cell center rather than
; grid-cell adjacency, so the "hitbox" matches what's visually happening
; instead of triggering a cell early/late depending on which edge of a
; grid square the player happens to be standing on
check_defeated:
    push rbp
    mov rbp, rsp

    cvtsi2ss xmm0, dword [rel t_x]
    addss xmm0, [rel f_half]
    subss xmm0, [rel player_x]
    mulss xmm0, xmm0

    cvtsi2ss xmm1, dword [rel t_y]
    addss xmm1, [rel f_half]
    subss xmm1, [rel player_y]
    mulss xmm1, xmm1

    addss xmm0, xmm1
    comiss xmm0, [rel f_catch_radius_sq]
    ja .done
    mov dword [rel game_state], 1
.done:
    mov rsp, rbp
    pop rbp
    ret

check_win:
    push rbp
    mov rbp, rsp

    mov eax, [rel inventory]
    cmp eax, 3
    jl .done
    cvttss2si eax, [rel player_x]
    cmp eax, [rel goal_x]
    jne .done
    cvttss2si eax, [rel player_y]
    cmp eax, [rel goal_y]
    jne .done
    mov dword [rel game_state], 2
.done:
    mov rsp, rbp
    pop rbp
    ret

; loads T_Sprite.jpeg via SDL2_image and converts it to ARGB8888 so
; draw_sprite_textured can sample raw pixels directly. Leaves
; t_has_texture at 0 (flat-color fallback) if the file can't be loaded.
load_t_texture:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    mov byte [rel t_has_texture], 0

    mov edi, IMG_INIT_JPG
    call IMG_Init

    lea rdi, [rel t_sprite_file]
    call IMG_Load
    mov [rbp-8], rax
    cmp rax, 0
    jne .have_raw
    call SDL_GetError
    mov rsi, rax
    lea rdi, [rel img_err_fmt]
    xor eax, eax
    call printf
    jmp .done

.have_raw:
    mov rdi, [rbp-8]
    mov esi, SDL_PIXELFORMAT_ARGB8888
    xor edx, edx
    call SDL_ConvertSurfaceFormat
    mov [rbp-16], rax

    mov rdi, [rbp-8]
    call SDL_FreeSurface

    cmp qword [rbp-16], 0
    je .done

    mov rax, [rbp-16]
    mov [rel t_surface], rax
    mov byte [rel t_has_texture], 1

.done:
    mov rsp, rbp
    pop rbp
    ret

; ============================================================
; rendering
; ============================================================

cast_walls:
    push rbp
    mov rbp, rsp
    sub rsp, 112
    ; floats: -4 cameraX -8 rayDirX -12 rayDirY -16 deltaDistX -20 deltaDistY
    ;         -24 sideDistX -28 sideDistY -32 perpWallDist
    ; ints:   -36 x -40 mapX -44 mapY -48 stepX -52 stepY -56 side
    ;         -60 drawStart -64 drawEnd -68 iter
    ;         -72 colR/packed -76 colG -80 colB -84 outR -88 outG -92 outB
    ;         -96 hitChar (which wall/wing character the ray stopped on)

    mov dword [rbp-36], 0
.col_loop:
    mov eax, [rbp-36]
    cmp eax, FB_W
    jge .col_done

    cvtsi2ss xmm0, eax
    mulss xmm0, [rel f_two]
    divss xmm0, [rel f_fbw]
    subss xmm0, [rel f_one]
    movss [rbp-4], xmm0

    movss xmm1, [rel plane_x]
    mulss xmm1, xmm0
    addss xmm1, [rel dir_x]
    movss [rbp-8], xmm1

    movss xmm2, [rel plane_y]
    mulss xmm2, xmm0
    addss xmm2, [rel dir_y]
    movss [rbp-12], xmm2

    cvttss2si eax, [rel player_x]
    mov [rbp-40], eax
    cvttss2si eax, [rel player_y]
    mov [rbp-44], eax

    movd eax, xmm1
    and eax, 0x7fffffff
    cmp eax, 0
    jne .dx_ok
    movss xmm0, [rel f_big]
    jmp .dx_store
.dx_ok:
    movss xmm0, [rel f_one]
    divss xmm0, xmm1
    movd eax, xmm0
    and eax, 0x7fffffff
    movd xmm0, eax
.dx_store:
    movss [rbp-16], xmm0

    movd eax, xmm2
    and eax, 0x7fffffff
    cmp eax, 0
    jne .dy_ok
    movss xmm0, [rel f_big]
    jmp .dy_store
.dy_ok:
    movss xmm0, [rel f_one]
    divss xmm0, xmm2
    movd eax, xmm0
    and eax, 0x7fffffff
    movd xmm0, eax
.dy_store:
    movss [rbp-20], xmm0

    xorps xmm3, xmm3
    comiss xmm1, xmm3
    jb .stepx_neg
    mov dword [rbp-48], 1
    cvtsi2ss xmm4, dword [rbp-40]
    addss xmm4, [rel f_one]
    subss xmm4, [rel player_x]
    mulss xmm4, [rbp-16]
    movss [rbp-24], xmm4
    jmp .stepx_done
.stepx_neg:
    mov dword [rbp-48], -1
    cvtsi2ss xmm4, dword [rbp-40]
    movss xmm5, [rel player_x]
    subss xmm5, xmm4
    mulss xmm5, [rbp-16]
    movss [rbp-24], xmm5
.stepx_done:

    xorps xmm3, xmm3
    comiss xmm2, xmm3
    jb .stepy_neg
    mov dword [rbp-52], 1
    cvtsi2ss xmm4, dword [rbp-44]
    addss xmm4, [rel f_one]
    subss xmm4, [rel player_y]
    mulss xmm4, [rbp-20]
    movss [rbp-28], xmm4
    jmp .stepy_done
.stepy_neg:
    mov dword [rbp-52], -1
    cvtsi2ss xmm4, dword [rbp-44]
    movss xmm5, [rel player_y]
    subss xmm5, xmm4
    mulss xmm5, [rbp-20]
    movss [rbp-28], xmm5
.stepy_done:

    mov dword [rbp-56], 0
    mov dword [rbp-68], 0
    mov dword [rbp-96], '#'
.dda_loop:
    inc dword [rbp-68]
    mov eax, [rbp-68]
    cmp eax, 200
    jge .hit

    movss xmm0, [rbp-24]
    movss xmm1, [rbp-28]
    comiss xmm0, xmm1
    jae .step_y
    addss xmm0, [rbp-16]
    movss [rbp-24], xmm0
    mov eax, [rbp-40]
    add eax, [rbp-48]
    mov [rbp-40], eax
    mov dword [rbp-56], 0
    jmp .after_step
.step_y:
    addss xmm1, [rbp-20]
    movss [rbp-28], xmm1
    mov eax, [rbp-44]
    add eax, [rbp-52]
    mov [rbp-44], eax
    mov dword [rbp-56], 1
.after_step:

    mov eax, [rbp-40]
    cmp eax, 0
    jl .hit
    cmp eax, MAP_W
    jge .hit
    mov eax, [rbp-44]
    cmp eax, 0
    jl .hit
    cmp eax, MAP_H
    jge .hit

    mov eax, [rbp-44]
    imul eax, MAP_W
    add eax, [rbp-40]
    lea r8, [rel board]
    movzx ecx, byte [r8+rax]
    mov [rbp-96], ecx
    cmp cl, ' '
    je .dda_loop
    cmp cl, 'S'
    je .dda_loop
    cmp cl, 'B'
    je .dda_loop
.hit:

    mov eax, [rbp-56]
    cmp eax, 0
    jne .perp_y
    movss xmm0, [rbp-24]
    subss xmm0, [rbp-16]
    movss [rbp-32], xmm0
    jmp .perp_done
.perp_y:
    movss xmm0, [rbp-28]
    subss xmm0, [rbp-20]
    movss [rbp-32], xmm0
.perp_done:
    movss xmm0, [rbp-32]
    comiss xmm0, [rel f_epsilon]
    ja .dist_ok
    movss xmm0, [rel f_epsilon]
    movss [rbp-32], xmm0
.dist_ok:

    mov eax, [rbp-36]
    lea r8, [rel zbuffer]
    movss xmm0, [rbp-32]
    movss [r8+rax*4], xmm0

    movss xmm0, [rel f_fbh]
    divss xmm0, [rbp-32]
    cvttss2si eax, xmm0
    mov ecx, 2
    cdq
    idiv ecx
    mov ecx, eax
    mov eax, FB_H/2
    sub eax, ecx
    cmp eax, 0
    jge .ds_ok
    mov eax, 0
.ds_ok:
    cmp eax, FB_H-1
    jle .ds_ok2
    mov eax, FB_H-1
.ds_ok2:
    mov [rbp-60], eax

    mov eax, FB_H/2
    add eax, ecx
    cmp eax, 0
    jge .de_ok
    mov eax, 0
.de_ok:
    cmp eax, FB_H-1
    jle .de_ok2
    mov eax, FB_H-1
.de_ok2:
    mov [rbp-64], eax

    movss xmm0, [rbp-32]
    mulss xmm0, [rel f_fog_k]
    addss xmm0, [rel f_one]
    movss xmm1, [rel f_one]
    divss xmm1, xmm0
    comiss xmm1, [rel f_fog_min]
    jae .fog_ok
    movss xmm1, [rel f_fog_min]
.fog_ok:
    movss [rbp-16], xmm1

    ; base wall color depends on which wing/room character the ray stopped
    ; on, so different parts of the school read as visually distinct areas
    mov eax, [rbp-96]
    cmp eax, 'H'
    je .col_hallway
    cmp eax, 'C'
    je .col_classroom
    cmp eax, 'G'
    je .col_gym
    cmp eax, 'N'
    je .col_safe
    cmp eax, 'L'
    je .col_library
    mov dword [rbp-72], 150
    mov dword [rbp-76], 40
    mov dword [rbp-80], 40
    jmp .base_color_done
.col_hallway:
    mov dword [rbp-72], 170
    mov dword [rbp-76], 150
    mov dword [rbp-80], 100
    jmp .base_color_done
.col_classroom:
    mov dword [rbp-72], 60
    mov dword [rbp-76], 95
    mov dword [rbp-80], 175
    jmp .base_color_done
.col_gym:
    mov dword [rbp-72], 195
    mov dword [rbp-76], 115
    mov dword [rbp-80], 30
    jmp .base_color_done
.col_safe:
    mov dword [rbp-72], 60
    mov dword [rbp-76], 165
    mov dword [rbp-80], 150
    jmp .base_color_done
.col_library:
    mov dword [rbp-72], 110
    mov dword [rbp-76], 160
    mov dword [rbp-80], 70
.base_color_done:

    ; darken by 1/3 on the N/S-facing (as opposed to E/W-facing) side hits,
    ; same depth cue as before but now applied on top of any base color
    mov eax, [rbp-56]
    cmp eax, 0
    je .color_done
    mov eax, [rbp-72]
    imul eax, 2
    mov ecx, 3
    cdq
    idiv ecx
    mov [rbp-72], eax
    mov eax, [rbp-76]
    imul eax, 2
    mov ecx, 3
    cdq
    idiv ecx
    mov [rbp-76], eax
    mov eax, [rbp-80]
    imul eax, 2
    mov ecx, 3
    cdq
    idiv ecx
    mov [rbp-80], eax
.color_done:
    cvtsi2ss xmm0, dword [rbp-72]
    mulss xmm0, [rbp-16]
    cvttss2si eax, xmm0
    mov [rbp-84], eax
    cvtsi2ss xmm0, dword [rbp-76]
    mulss xmm0, [rbp-16]
    cvttss2si eax, xmm0
    mov [rbp-88], eax
    cvtsi2ss xmm0, dword [rbp-80]
    mulss xmm0, [rbp-16]
    cvttss2si eax, xmm0
    mov [rbp-92], eax

    mov eax, [rbp-84]
    shl eax, 16
    mov ecx, [rbp-88]
    shl ecx, 8
    or eax, ecx
    or eax, [rbp-92]
    or eax, 0xFF000000
    mov [rbp-72], eax

    mov eax, 0
.ceil_loop:
    cmp eax, [rbp-60]
    jge .ceil_done
    mov ecx, eax
    imul ecx, FB_W
    add ecx, [rbp-36]
    lea r9, [rel framebuf]
    mov dword [r9+rcx*4], 0xFF14141E
    inc eax
    jmp .ceil_loop
.ceil_done:

    mov eax, [rbp-60]
.wall_loop:
    cmp eax, [rbp-64]
    jg .wall_done
    mov ecx, eax
    imul ecx, FB_W
    add ecx, [rbp-36]
    lea r9, [rel framebuf]
    mov edx, [rbp-72]
    mov [r9+rcx*4], edx
    inc eax
    jmp .wall_loop
.wall_done:

    mov eax, [rbp-64]
    inc eax
.floor_loop:
    cmp eax, FB_H
    jge .floor_done
    mov ecx, eax
    imul ecx, FB_W
    add ecx, [rbp-36]
    lea r9, [rel framebuf]
    mov dword [r9+rcx*4], 0xFF231E19
    inc eax
    jmp .floor_loop
.floor_done:

    inc dword [rbp-36]
    jmp .col_loop
.col_done:
    mov rsp, rbp
    pop rbp
    ret

; draw_sprite(grid_x=edi, grid_y=esi, color=edx)
draw_sprite:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    ; -4 spriteX -8 spriteY -12 relX -16 relY -20 invDet -24 transformX -28 transformY
    ; -32 spriteScreenX -36 spriteSize -40 drawStartX -44 drawEndX -48 drawStartY -52 drawEndY
    ; -56 color -60 stripe

    mov [rbp-56], edx

    cvtsi2ss xmm0, edi
    addss xmm0, [rel f_half]
    movss [rbp-4], xmm0
    cvtsi2ss xmm0, esi
    addss xmm0, [rel f_half]
    movss [rbp-8], xmm0

    movss xmm0, [rbp-4]
    subss xmm0, [rel player_x]
    movss [rbp-12], xmm0
    movss xmm0, [rbp-8]
    subss xmm0, [rel player_y]
    movss [rbp-16], xmm0

    movss xmm0, [rel plane_x]
    mulss xmm0, [rel dir_y]
    movss xmm1, [rel dir_x]
    mulss xmm1, [rel plane_y]
    subss xmm0, xmm1
    movss xmm1, [rel f_one]
    divss xmm1, xmm0
    movss [rbp-20], xmm1

    movss xmm0, [rel dir_y]
    mulss xmm0, [rbp-12]
    movss xmm2, [rel dir_x]
    mulss xmm2, [rbp-16]
    subss xmm0, xmm2
    mulss xmm0, [rbp-20]
    movss [rbp-24], xmm0

    xorps xmm3, xmm3
    subss xmm3, [rel plane_y]
    mulss xmm3, [rbp-12]
    movss xmm4, [rel plane_x]
    mulss xmm4, [rbp-16]
    addss xmm3, xmm4
    mulss xmm3, [rbp-20]
    movss [rbp-28], xmm3

    comiss xmm3, [rel f_epsilon]
    jbe .done

    movss xmm0, [rbp-24]
    divss xmm0, xmm3
    addss xmm0, [rel f_one]
    mulss xmm0, [rel f_halffbw]
    movss [rbp-32], xmm0

    movss xmm0, [rel f_fbh]
    divss xmm0, xmm3
    movd eax, xmm0
    and eax, 0x7fffffff
    movd xmm0, eax
    cvttss2si eax, xmm0
    mov [rbp-36], eax

    mov eax, [rbp-36]
    mov ecx, 2
    cdq
    idiv ecx
    mov ecx, eax
    mov eax, FB_H/2
    sub eax, ecx
    mov [rbp-48], eax
    mov eax, FB_H/2
    add eax, ecx
    mov [rbp-52], eax

    cvttss2si eax, [rbp-32]
    mov edx, [rbp-36]
    push rax
    mov eax, edx
    mov ecx, 2
    cdq
    idiv ecx
    mov ecx, eax
    pop rax
    sub eax, ecx
    mov [rbp-40], eax
    add eax, [rbp-36]
    mov [rbp-44], eax

    cmp dword [rbp-40], 0
    jge .sx_ok
    mov dword [rbp-40], 0
.sx_ok:
    cmp dword [rbp-44], FB_W
    jl .ex_ok
    mov dword [rbp-44], FB_W-1
.ex_ok:
    cmp dword [rbp-48], 0
    jge .sy_ok
    mov dword [rbp-48], 0
.sy_ok:
    cmp dword [rbp-52], FB_H
    jl .ey_ok
    mov dword [rbp-52], FB_H-1
.ey_ok:

    mov eax, [rbp-40]
    mov [rbp-60], eax
.stripe_loop:
    mov eax, [rbp-60]
    cmp eax, [rbp-44]
    jg .done

    lea r8, [rel zbuffer]
    movss xmm0, [r8+rax*4]
    comiss xmm0, xmm3
    jbe .next_stripe

    mov ecx, [rbp-48]
.row_loop:
    cmp ecx, [rbp-52]
    jg .next_stripe
    mov edx, ecx
    imul edx, FB_W
    add edx, eax
    lea r9, [rel framebuf]
    mov r10d, [rbp-56]
    mov [r9+rdx*4], r10d
    inc ecx
    jmp .row_loop
.next_stripe:
    inc dword [rbp-60]
    jmp .stripe_loop
.done:
    mov rsp, rbp
    pop rbp
    ret

; draw_sprite_textured(grid_x=edi, grid_y=esi) -- same billboard projection as
; draw_sprite, but samples the loaded T texture instead of a flat color, and
; keeps the texture's own aspect ratio instead of forcing a square.
draw_sprite_textured:
    push rbp
    mov rbp, rsp
    sub rsp, 128
    ; -4 spriteX -8 spriteY -12 relX -16 relY -20 invDet -24 transformX -28 transformY
    ; -32 spriteScreenX -36 spriteHeight -40 spriteWidth
    ; -44 rawStartX -48 rawStartY -52 clampStartX -56 clampEndX -60 clampStartY -64 clampEndY
    ; -68 stripe -72 texW -76 texH -80 texPitch -96 texPixels(qword)
    ; -100 row -108 texX -112 texY

    cvtsi2ss xmm0, edi
    addss xmm0, [rel f_half]
    movss [rbp-4], xmm0
    cvtsi2ss xmm0, esi
    addss xmm0, [rel f_half]
    movss [rbp-8], xmm0

    movss xmm0, [rbp-4]
    subss xmm0, [rel player_x]
    movss [rbp-12], xmm0
    movss xmm0, [rbp-8]
    subss xmm0, [rel player_y]
    movss [rbp-16], xmm0

    movss xmm0, [rel plane_x]
    mulss xmm0, [rel dir_y]
    movss xmm1, [rel dir_x]
    mulss xmm1, [rel plane_y]
    subss xmm0, xmm1
    movss xmm1, [rel f_one]
    divss xmm1, xmm0
    movss [rbp-20], xmm1

    movss xmm0, [rel dir_y]
    mulss xmm0, [rbp-12]
    movss xmm2, [rel dir_x]
    mulss xmm2, [rbp-16]
    subss xmm0, xmm2
    mulss xmm0, [rbp-20]
    movss [rbp-24], xmm0

    xorps xmm3, xmm3
    subss xmm3, [rel plane_y]
    mulss xmm3, [rbp-12]
    movss xmm4, [rel plane_x]
    mulss xmm4, [rbp-16]
    addss xmm3, xmm4
    mulss xmm3, [rbp-20]
    movss [rbp-28], xmm3

    comiss xmm3, [rel f_epsilon]
    jbe .done

    movss xmm0, [rbp-24]
    divss xmm0, xmm3
    addss xmm0, [rel f_one]
    mulss xmm0, [rel f_halffbw]
    movss [rbp-32], xmm0

    movss xmm0, [rel f_fbh]
    divss xmm0, xmm3
    movd eax, xmm0
    and eax, 0x7fffffff
    movd xmm0, eax
    cvttss2si eax, xmm0
    mov [rbp-36], eax

    mov rax, [rel t_surface]
    mov ecx, [rax+SURF_W]
    mov [rbp-72], ecx
    mov ecx, [rax+SURF_H]
    mov [rbp-76], ecx
    mov ecx, [rax+SURF_PITCH]
    mov [rbp-80], ecx
    mov rax, [rax+SURF_PIXELS]
    mov [rbp-96], rax

    cvtsi2ss xmm0, dword [rbp-36]
    cvtsi2ss xmm1, dword [rbp-72]
    mulss xmm0, xmm1
    cvtsi2ss xmm1, dword [rbp-76]
    divss xmm0, xmm1
    cvttss2si eax, xmm0
    mov [rbp-40], eax

    mov eax, [rbp-36]
    mov ecx, 2
    cdq
    idiv ecx
    mov ecx, eax
    mov eax, FB_H/2
    sub eax, ecx
    mov [rbp-48], eax
    mov edx, eax
    add edx, [rbp-36]

    mov eax, [rbp-48]
    cmp eax, 0
    jge .csy_ok
    mov eax, 0
.csy_ok:
    mov [rbp-60], eax
    cmp edx, FB_H
    jl .cey_ok
    mov edx, FB_H-1
    jmp .cey_store
.cey_ok:
    dec edx
.cey_store:
    mov [rbp-64], edx

    cvttss2si eax, [rbp-32]
    mov edx, [rbp-40]
    push rax
    mov eax, edx
    mov ecx, 2
    cdq
    idiv ecx
    mov ecx, eax
    pop rax
    sub eax, ecx
    mov [rbp-44], eax
    mov edx, eax
    add edx, [rbp-40]

    mov eax, [rbp-44]
    cmp eax, 0
    jge .csx_ok
    mov eax, 0
.csx_ok:
    mov [rbp-52], eax
    cmp edx, FB_W
    jl .cex_ok
    mov edx, FB_W-1
    jmp .cex_store
.cex_ok:
    dec edx
.cex_store:
    mov [rbp-56], edx

    mov eax, [rbp-52]
    mov [rbp-68], eax
.stripe_loop:
    mov eax, [rbp-68]
    cmp eax, [rbp-56]
    jg .done

    lea r8, [rel zbuffer]
    movss xmm0, [r8+rax*4]
    comiss xmm0, xmm3
    jbe .next_stripe

    mov eax, [rbp-68]
    sub eax, [rbp-44]
    imul eax, [rbp-72]
    mov ecx, [rbp-40]
    cmp ecx, 0
    jne .txok
    mov ecx, 1
.txok:
    cdq
    idiv ecx
    cmp eax, 0
    jge .tx0
    xor eax, eax
.tx0:
    mov ecx, [rbp-72]
    dec ecx
    cmp eax, ecx
    jle .tx1
    mov eax, ecx
.tx1:
    mov [rbp-108], eax

    mov ecx, [rbp-60]
    mov [rbp-100], ecx
.row_loop:
    mov eax, [rbp-100]
    cmp eax, [rbp-64]
    jg .next_stripe

    mov eax, [rbp-100]
    sub eax, [rbp-48]
    imul eax, [rbp-76]
    mov ecx, [rbp-36]
    cmp ecx, 0
    jne .tyok
    mov ecx, 1
.tyok:
    cdq
    idiv ecx
    cmp eax, 0
    jge .ty0
    xor eax, eax
.ty0:
    mov ecx, [rbp-76]
    dec ecx
    cmp eax, ecx
    jle .ty1
    mov eax, ecx
.ty1:
    mov [rbp-112], eax

    mov rax, [rbp-96]
    mov ecx, [rbp-112]
    imul ecx, [rbp-80]
    add rax, rcx
    mov ecx, [rbp-108]
    shl ecx, 2
    add rax, rcx
    mov edx, [rax]
    or edx, 0xFF000000

    mov eax, [rbp-100]
    imul eax, FB_W
    add eax, [rbp-68]
    lea r9, [rel framebuf]
    mov [r9+rax*4], edx

    inc dword [rbp-100]
    jmp .row_loop
.next_stripe:
    inc dword [rbp-68]
    jmp .stripe_loop
.done:
    mov rsp, rbp
    pop rbp
    ret

; darkens/reddens the screen toward the edges as T gets close, pulsing at
; the highest danger band -- a visual stand-in for a heartbeat/tension cue
; since there's no audio engine here. Reads last_proximity_band, which
; check_proximity already refreshes once per frame before this runs.
apply_proximity_vignette:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    ; -4 strength -12 ny2 -16(unused) -20 amt -24(unused) -28 x -32 y

    mov eax, [rel last_proximity_band]
    cmp eax, 0
    je .done

    cvtsi2ss xmm0, eax
    mulss xmm0, [rel f_vign_step]
    movss [rbp-4], xmm0

    cmp eax, 3
    jne .no_pulse
    cvtsi2ss xmm0, dword [rel frame_count]
    mulss xmm0, [rel f_vign_pulse_speed]
    call sinf
    mulss xmm0, [rel f_half]
    addss xmm0, [rel f_half]
    mulss xmm0, [rel f_vign_pulse_amp]
    addss xmm0, [rbp-4]
    movss [rbp-4], xmm0
.no_pulse:

    mov dword [rbp-32], 0
.row_loop:
    mov eax, [rbp-32]
    cmp eax, FB_H
    jge .done
    cvtsi2ss xmm0, eax
    subss xmm0, [rel f_halffbh]
    divss xmm0, [rel f_halffbh]
    mulss xmm0, xmm0
    movss [rbp-12], xmm0

    mov dword [rbp-28], 0
.col_loop:
    mov eax, [rbp-28]
    cmp eax, FB_W
    jge .row_next
    cvtsi2ss xmm1, eax
    subss xmm1, [rel f_halffbw]
    divss xmm1, [rel f_halffbw]
    mulss xmm1, xmm1
    addss xmm1, [rbp-12]
    mulss xmm1, [rbp-4]
    comiss xmm1, [rel f_one]
    jbe .amt_ok
    movss xmm1, [rel f_one]
.amt_ok:
    movss [rbp-20], xmm1

    mov eax, [rbp-32]
    imul eax, FB_W
    add eax, [rbp-28]
    lea r8, [rel framebuf]
    mov edx, [r8+rax*4]

    mov ecx, edx
    shr ecx, 16
    and ecx, 0xFF
    mov r9d, edx
    shr r9d, 8
    and r9d, 0xFF
    mov r10d, edx
    and r10d, 0xFF

    cvtsi2ss xmm2, ecx
    cvtsi2ss xmm3, r9d
    cvtsi2ss xmm4, r10d

    movss xmm5, [rel f_one]
    subss xmm5, xmm1

    mulss xmm2, xmm5
    mulss xmm3, xmm5
    mulss xmm4, xmm5

    movss xmm6, [rel f_vign_tint_r]
    mulss xmm6, xmm1
    addss xmm2, xmm6

    cvttss2si ecx, xmm2
    cvttss2si r9d, xmm3
    cvttss2si r10d, xmm4

    shl ecx, 16
    shl r9d, 8
    or ecx, r9d
    or ecx, r10d
    or ecx, 0xFF000000
    mov [r8+rax*4], ecx

    inc dword [rbp-28]
    jmp .col_loop
.row_next:
    inc dword [rbp-32]
    jmp .row_loop
.done:
    mov rsp, rbp
    pop rbp
    ret

render_frame:
    push rbp
    mov rbp, rsp
    push r12
    sub rsp, 8

    call cast_walls

    mov r12d, 0
.item_loop:
    cmp r12d, 3
    jge .items_done
    lea r8, [rel item_active]
    cmp byte [r8+r12], 0
    je .item_next
    lea r8, [rel item_gx]
    mov edi, [r8+r12*4]
    lea r8, [rel item_gy]
    mov esi, [r8+r12*4]
    mov edx, 0xFF20D0E0
    call draw_sprite
.item_next:
    inc r12d
    jmp .item_loop
.items_done:

    mov r12d, 0
.weapon_loop:
    cmp r12d, NUM_WEAPONS
    jge .weapons_done
    lea r8, [rel weapon_active]
    cmp byte [r8+r12], 0
    je .weapon_next
    lea r8, [rel weapon_gx]
    mov edi, [r8+r12*4]
    lea r8, [rel weapon_gy]
    mov esi, [r8+r12*4]
    mov edx, 0xFFA020F0
    call draw_sprite
.weapon_next:
    inc r12d
    jmp .weapon_loop
.weapons_done:

    mov edi, [rel goal_x]
    mov esi, [rel goal_y]
    mov edx, 0xFFE0C000
    call draw_sprite

    mov edi, [rel t_x]
    mov esi, [rel t_y]
    cmp byte [rel t_has_texture], 0
    je .t_flat
    call draw_sprite_textured
    jmp .t_done
.t_flat:
    mov edx, 0xFFD01010
    call draw_sprite
.t_done:

    call apply_proximity_vignette

    mov rdi, [rel texture_ptr]
    xor esi, esi
    lea rdx, [rel framebuf]
    mov ecx, FB_W*4
    call SDL_UpdateTexture

    mov rdi, [rel renderer_ptr]
    call SDL_RenderClear

    mov rdi, [rel renderer_ptr]
    mov rsi, [rel texture_ptr]
    xor edx, edx
    xor ecx, ecx
    call SDL_RenderCopy

    mov rdi, [rel renderer_ptr]
    call SDL_RenderPresent

    add rsp, 8
    pop r12
    pop rbp
    ret

; ============================================================
; entry point
; ============================================================

main:
    push rbp
    mov rbp, rsp

    lea rdi, [rel intro_lore]
    call system

    lea rdi, [rel question]
    xor eax, eax
    call printf

.doom_loop:
    lea rdi, [rel int_format]
    lea rsi, [rel INPUT]
    xor eax, eax
    call scanf
    mov eax, [rel INPUT]
    cmp eax, 0
    jne .journey
    lea rdi, [rel omniman]
    call system
    lea rdi, [rel usure]
    xor eax, eax
    call printf
    mov edi, 1
    call sleep
    jmp .doom_loop

.journey:
    lea rdi, [rel prompt_seed]
    xor eax, eax
    call printf
    lea rdi, [rel int_format]
    lea rsi, [rel INPUT]
    xor eax, eax
    call scanf
    mov eax, [rel INPUT]
    cmp eax, -1
    jne .do_seed
    xor edi, edi
    call time
.do_seed:
    mov edi, eax
    call srand

    call load_board
    call find_goal

    movss xmm0, [rel f_rot_speed]
    call sinf
    movss [rel rot_sin], xmm0
    movss xmm0, [rel f_rot_speed]
    call cosf
    movss [rel rot_cos], xmm0

    movss xmm0, [rel f_start_x]
    movss [rel player_x], xmm0
    movss xmm0, [rel f_start_y]
    movss [rel player_y], xmm0
    movss xmm0, [rel f_one]
    movss [rel dir_x], xmm0
    xorps xmm0, xmm0
    movss [rel dir_y], xmm0
    movss [rel plane_x], xmm0
    movss xmm0, [rel f_plane_len]
    movss [rel plane_y], xmm0

    mov dword [rel inventory], 0
    mov dword [rel game_state], 0
    mov dword [rel frame_count], 0
    mov dword [rel t_unreachable_flag], 0
    mov dword [rel weapon_count], 0
    mov dword [rel t_stun_timer], 0
    mov byte [rel was_in_safe_room], 0
    mov dword [rel last_proximity_band], 0
    mov byte [rel space_prev], 0
    mov byte [rel key_w], 0
    mov byte [rel key_a], 0
    mov byte [rel key_s], 0
    mov byte [rel key_d], 0
    mov byte [rel running], 1

    call spawn_items
    call spawn_weapons
    call spawn_T

    mov edi, SDL_INIT_VIDEO
    call SDL_Init

    lea rdi, [rel win_title]
    mov esi, SDL_WINDOWPOS_UNDEFINED
    mov edx, SDL_WINDOWPOS_UNDEFINED
    mov ecx, WIN_W
    mov r8d, WIN_H
    mov r9d, 0
    call SDL_CreateWindow
    mov [rel window_ptr], rax

    mov rdi, rax
    mov esi, -1
    mov edx, 0
    call SDL_CreateRenderer
    mov [rel renderer_ptr], rax

    mov rdi, rax
    mov esi, SDL_PIXELFORMAT_ARGB8888
    mov edx, SDL_TEXTUREACCESS_STREAMING
    mov ecx, FB_W
    mov r8d, FB_H
    call SDL_CreateTexture
    mov [rel texture_ptr], rax

    call load_t_texture

.game_loop:
    call handle_events
    cmp byte [rel running], 0
    je .loop_end

    call update_player

    cmp byte [rel key_space], 0
    je .no_fire
    cmp byte [rel space_prev], 0
    jne .no_fire
    call use_weapon
.no_fire:
    mov al, [rel key_space]
    mov [rel space_prev], al

    inc dword [rel frame_count]
    mov eax, [rel frame_count]
    xor edx, edx
    mov ecx, T_MOVE_INTERVAL
    div ecx
    cmp edx, 0
    jne .skip_t_move
    call move_t_tick
.skip_t_move:

    call check_pickups
    call check_weapon_pickups
    call check_safe_room
    call check_proximity
    call check_defeated
    call check_win

    mov eax, [rel game_state]
    cmp eax, 0
    jne .loop_end

    call render_frame

    mov edi, 16
    call SDL_Delay

    jmp .game_loop

.loop_end:
    cmp byte [rel t_has_texture], 0
    je .no_tex_cleanup
    mov rdi, [rel t_surface]
    call SDL_FreeSurface
.no_tex_cleanup:
    call IMG_Quit

    mov rdi, [rel texture_ptr]
    call SDL_DestroyTexture
    mov rdi, [rel renderer_ptr]
    call SDL_DestroyRenderer
    mov rdi, [rel window_ptr]
    call SDL_DestroyWindow
    call SDL_Quit

    mov eax, [rel game_state]
    cmp eax, 1
    je .say_lost
    cmp eax, 2
    je .say_won
    jmp .done

.say_lost:
    lea rdi, [rel msg_caught]
    xor eax, eax
    call printf
    lea rdi, [rel game_over_cmd]
    call system
    jmp .done

.say_won:
    lea rdi, [rel msg_won]
    xor eax, eax
    call printf
    lea rdi, [rel game_won_cmd]
    call system

.done:
    xor eax, eax
    mov rsp, rbp
    pop rbp
    ret
