; =============================================================================
; main.asm -- "Beacom at 2am", 3D assembly edition. Entry point and game loop.
;
; Flow (same shape as game.asm / doom.asm):
;   1. terminal: intro lore through lolcat, "DO YOU WISH TO EMBARK?" (the
;      coward loop with rusure.txt), then the game seed prompt
;   2. an OpenGL window: find 3 wireshark packet captures (one per storey)
;      and bring them to B in the library while T hunts you
;   3. terminal again: T.txt (caught), chicken_jockey.txt (the secret) or
;      W.txt (you won) through lolcat, then "play again?"
;
; Run it from the beacom3d_asm directory (it reads maps/ and ../*.txt).
;   ./beacom3d          play
;   ./beacom3d --shot   render a set of test screenshots into shots/ and exit
; =============================================================================
%define MODULE_MAIN
%include "common.inc"

global main, items, item_count, inventory, deauths, game_state, elapsed_time, win_w, win_h
global on_t_spotted

extern sign_count, glDeleteLists, t_speed_bonus, keys_down, p_crouch, p_step_event
extern dump_shadow_map, glFinish, p_eye_y, getenv, SDL_SetHint, hud_fps, render_cycle_scale, render_toggle_shadows

%define START_F 1                   ; STARTX/STARTY from game.asm
%define START_X 1
%define START_Y 1

; keys_down slots (player.asm)
%define K_FWD    0
%define K_BACK   1
%define K_LEFT   2
%define K_RIGHT  3
%define K_SPRINT 4
%define K_CROUCH 5
%define K_JUMP   6
%define K_TURN_L 7
%define K_TURN_R 8

%define RGBC(r,g,b) (0xFF000000 | ((b)<<16) | ((g)<<8) | (r))
%define COL_INFO   RGBC(216,212,200)
%define COL_WARN   RGBC(255,179,71)
%define COL_DANGER RGBC(255,59,59)
%define COL_GOOD   RGBC(143,227,143)
%define COL_LORE   RGBC(159,220,255)

section .data
; ---- terminal text (from game.asm / doom.asm) ----
; the terminal screens are printed by print_rainbow (our own lolcat)
intro_file  db "../intro.txt",0
question    db 10,"DO YOU WISH TO EMBARK ON THIS JOURNEY? (YES=1, NO=0)",10,0
omniman     db "../rusure.txt",0
usure       db "YOU COWARD! Are you sure? (YES=1, NO=0)",10,0
prompt_seed db "Please enter your game seed (-1 for random): ",0
int_format  db "%d",0
game_over_cmd db "../T.txt",0
jockey_cmd  db "../chicken_jockey.txt",0
game_won_cmd db "../W.txt",0
rb_fmt      db 27,"[38;2;%d;%d;%dm%c",0
rb_reset    db 27,"[0m",10,0
rb_reset0   db 27,"[0m",0
mode_rt     db "r",0
stats_fmt   db 10,"%s",10,"seed %d  -  %dm %02ds  -  %d/3 captures",10,0
again_q     db 10,"Play again? (1 = same seed, 2 = new seed, 0 = quit): ",0
bye         db "The halls of Beacom fall silent...",10,0
err_sdl     db "SDL error: %s",10
            db "(No window could be opened. Is DISPLAY set to a running X server?",10
            db " On Windows + Docker: start VcXsrv and pass -e DISPLAY=host.docker.internal:0.0 -- see README.md)",10,0
title       db "Beacom at 2am",0
shot_flag   db "--shot",0
st_walk_fmt db "[selftest] %-38s floor %d   x=%6.2f y=%5.2f z=%6.2f",10,0
st_n_up     db "walk up stairs A (ground->2nd)",0
st_n_c      db "walk up stairs C (ground->2nd)",0
st_n_down   db "walk down stairs B (ground->basement)",0
st_n_d      db "walk up stairs D (basement->ground)",0
st_n_desc   db "walk down from the 2nd floor landing",0
st_n_wall   db "walk into the start room wall",0
st_path_fmt db "[selftest] path basement(3,3) -> 2nd floor(5,3): found=%d, %d cells",10,0
st_t_fmt    db "[selftest] t=%5.1fs  T on floor %d at (%d,%d)  state=%d  dist=%.1f",10,0
st_caught   db "[selftest] T reached the player after %.1f simulated seconds -- PASS",10,0
st_notcaught db "[selftest] T did not reach the player -- FAIL",10,0
st_fps_fmt  db "[selftest] render benchmark: %.1f frames per second at %dx%d",10,0
st_safe_fmt db "[selftest] player hiding in the 2nd-floor safe room: caught=%d after 60s (expect 0)",10,0
%ifdef WIN64
mkdir_shots db "if not exist shots mkdir shots",0
%else
mkdir_shots db "mkdir -p shots",0
%endif

; ---- in-game messages (strings carried over from the originals) ----
m_seed      db "Seed %d. Find 3 wireshark packet captures -- one on every floor -- and bring them to B.",0
m_controls  db "WASD move - mouse or arrow keys look - SHIFT sprint - C crouch - SPACE jump - F flashlight - E grab - Q deauth - M map - I invert mouse - F3 fps - F4 render scale - F5 shadows",0
m_inv_on    db "Mouse look: vertical inverted.",0
m_inv_off   db "Mouse look: normal.",0
env_wsl     db "WSL_DISTRO_NAME",0
env_soft    db "LIBGL_ALWAYS_SOFTWARE",0
env_msaa    db "BEACOM_MSAA",0
env_dump    db "BEACOM_DUMP_SHADOW",0
dump_name   db "shots/shadow.bmp",0
env_mouse   db "BEACOM_MOUSE",0
hint_warp   db "SDL_MOUSE_RELATIVE_MODE_WARP",0
hint_one    db "1",0
m_see_key   db "You see a wireshark packet capture flicker in the dark...",0
m_got_key   db "Packet capture acquired (%d/3). Bring them to B.",0
m_all_keys  db "That's all three. Get back to B in the library -- ground floor.",0
m_see_b     db "Lord of networking: 'Pull up wireshark and get a capture going! This Beacom building is very dangerous! Mr. T lurks the halls. Mr. Y has gone missing -- you must find 3 wireshark packet captures before it is too late. If you are ever scared, I have used my networking magic to secure some rooms. T cannot enter them! Good luck on your quest!'",0
m_have      db "You have %d/3 captures.",0
m_safe_in   db "You feel a comforting aura here. T cannot follow you inside.",0
m_safe_out  db "You step back out into the dark...",0
m_weapon    db "You grabbed a deauth packet! Press Q to fire it and scramble T's tracking.",0
m_fired     db "*** DEAUTH PACKET FIRED -- T's connection drops! ***",0
m_no_weapon db "You have no deauth packets.",0
m_noise     db "shh! You made a noise!",0
m_prox1     db "You think you hear something moving in the halls...",0
m_prox2     db "Footsteps are getting louder -- %s!",0
m_prox3     db "*** T IS RIGHT ON TOP OF YOU -- %s! COVER IS BLOWN! ***",0
m_spotted   db "T HAS SEEN YOU. RUN.",0
m_caught    db "T has found you.",0
m_won       db "You dragged Y out of the dark. You survived Beacom.",0
m_jockey    db "CHICKEN JOCKEY!",0
m_tyler     db "YOU: HI TYLER    TYLER: 'HI I AM TYLER'",0
m_cage      db "Y is locked in a cage. B will know how to open it.",0
d_ahead     db "straight ahead",0
d_behind    db "behind you",0
d_above     db "above you",0
d_below     db "below you",0

; ---- test screenshots: storey, grid x, grid y, yaw, pitch, T in view?, map?
%macro SHOT 8
    dd %1, %2, %3, __float32__(%4), __float32__(%5), %6, %7
    dq %8
%endmacro
sh_n0 db "shots/01_start.bmp",0
sh_n1 db "shots/02_hallway.bmp",0
sh_n2 db "shots/03_stairs_up.bmp",0
sh_n3 db "shots/04_shaft_down.bmp",0
sh_n4 db "shots/05_server_room.bmp",0
sh_n5 db "shots/06_library_B.bmp",0
sh_n6 db "shots/07_T.bmp",0
sh_n7 db "shots/08_cyber_lab.bmp",0
sh_n8 db "shots/09_safe_room.bmp",0
sh_n9 db "shots/10_map_hud.bmp",0
align 8
shots:
    SHOT 1,  1,  1, -2.356,  0.0,  0, 0, sh_n0
    SHOT 1,  8, 15, -1.5708, 0.0,  0, 0, sh_n1
    SHOT 1, 19, 13,  0.0,    0.3,  0, 0, sh_n2
    SHOT 2, 19,  5,  3.1416, -1.0, 0, 0, sh_n3
    SHOT 0,  7, 15, -1.5708, 0.0,  0, 0, sh_n4
    SHOT 1, 52, 20,  3.1416, 0.0,  0, 0, sh_n5
    SHOT 1, 30, 15, -1.5708, 0.1,  1, 0, sh_n6
    SHOT 2, 23,  8, -1.5708, -0.15, 0, 0, sh_n7
    SHOT 1, 56,  9,  1.5708, 0.0,  0, 0, sh_n8
    SHOT 1, 14, 15, -1.5708, 0.0,  0, 1, sh_n9
%define NSHOTS 10
%define SHOT_SIZE 36

c_dt_shot   dd 0.016
c_reach     dd 1.9
c_b_reach   dd 2.6
c_same      dd 1.4
c_see_dist  dd 7.0
c_tyler_d   dd 2.4
c_jockey_d  dd 0.9
c_cage_d    dd 5.0
c_max_dt    dd 0.05
c_sens_walk dd 7.0
c_sens_run  dd 22.0
c_noise_r   dd 26.0
c_noise_p   dd 45                    ; 1 in 45 steps makes a noise (int)
c_bonus     dd 0.3
c_b_talk_cd dd 8.0
c_hb_3      dd 0.42
c_hb_2      dd 0.65
c_hb_1      dd 0.95
c_three     dd 3.0
c_thunder_min dd 25.0
c_thunder_rng dd 40.0
c_light_decay dd 2.2
c_strobe    dd 0.6
c_strobe_lo dd 0.2
c_sixty     dd 60.0
c_flash_decay dd 1.6
c_vig_speed dd 5.0
c_hum_chase dd 0.5
c_hum_idle  dd 0.22
c_att_pow   dd 1.4
c_nine      dd 9.0
c_band_3    dd 2.5
c_band_2    dd 5.0
c_band_1    dd 9.0
c_band_far  dd 6.0
c_vert      dd 1.5
c_jump_time dd 1.3

section .bss
alignb 8
window      resq 1
glctx       resq 1
event       resb 64
items       resb ITEM_SIZE*MAX_ITEMS
item_count  resd 1
inventory   resd 1
deauths     resd 1
game_state  resd 1
elapsed_time resd 1
win_w       resd 1
win_h       resd 1
seed_val    resd 1
input_val   resd 1
last_band   resd 1
was_safe    resd 1
tyler_said  resd 1
cage_hint   resd 1
b_cooldown  resd 1
heart_t     resd 1
next_thunder resd 1
light_t     resd 1
perf_freq   resq 1
perf_last   resq 1
shot_mode   resd 1
msg_buf     resb 512
start_ticks resd 1
jump_t      resd 1
mouse_last_x resd 1
mouse_last_y resd 1
mouse_have_last resd 1
warp_x      resd 1
warp_y      resd 1
warp_pending resd 1
invert_y    resd 1
mouse_edge_mode resd 1
show_fps    resd 1
fps_frames  resd 1
fps_time    resd 1

section .text

; msg(rdi=text, esi=colour) / lore(rdi=text)
msg:
    xor edx, edx
    jmp hud_message
lore:
    mov esi, COL_LORE
    mov edx, 1
    jmp hud_message

; =============================================================================
; terminal part (identical in spirit to the assembly originals)
; =============================================================================

; print_rainbow(rdi=file, esi=ms to wait after each line) -- print a text file
; in lolcat-style rainbow colours with 24-bit ANSI escape codes. Doing it
; ourselves means no lolcat install is needed and it works on Windows too.
; Colour of a character: v = 0.1*(line + column/3),
;   r,g,b = sin(v), sin(v + 2pi/3), sin(v + 4pi/3) scaled to 1..255
print_rainbow:
    PROLOGUE 32
    mov r15d, esi
    lea rsi, [mode_rt]
    call fopen
    test rax, rax
    jz .done
    mov r12, rax
    xor r13d, r13d                      ; line
    xor r14d, r14d                      ; column
.next:
    mov rdi, r12
    call fgetc
    cmp eax, -1
    je .eof
    cmp eax, 13
    je .next
    cmp eax, 10
    je .newline
    mov ebx, eax
    inc r14d
    cmp ebx, ' '
    jne .colour
    mov edi, ' '                        ; spaces need no colour
    call putchar
    jmp .next
.colour:
    cvtsi2ss xmm0, r14d
    FLD xmm1, 0.33333
    mulss xmm0, xmm1
    cvtsi2ss xmm1, r13d
    addss xmm0, xmm1
    FLD xmm1, 0.1
    mulss xmm0, xmm1
    movss [rsp+0], xmm0
    call rb_channel
    mov [rsp+4], eax
    movss xmm0, [rsp+0]
    FLD xmm1, 2.0944
    addss xmm0, xmm1
    call rb_channel
    mov [rsp+8], eax
    movss xmm0, [rsp+0]
    FLD xmm1, 4.1888
    addss xmm0, xmm1
    call rb_channel
    mov ecx, eax
    lea rdi, [rb_fmt]
    mov esi, [rsp+4]
    mov edx, [rsp+8]
    mov r8d, ebx
    xor eax, eax
    call printf
    jmp .next
.newline:
    lea rdi, [rb_reset]
    xor eax, eax
    call printf
    xor edi, edi
    call fflush
    inc r13d
    xor r14d, r14d
    test r15d, r15d
    jz .next
    mov edi, r15d
    call SDL_Delay
    jmp .next
.eof:
    lea rdi, [rb_reset0]
    xor eax, eax
    call printf
    mov rdi, r12
    call fclose
.done:
    EPILOGUE

; rb_channel(xmm0=v) -> eax = sin(v)*127 + 128
rb_channel:
    sub rsp, 8
    call sinf
    FLD xmm1, 127.0
    mulss xmm0, xmm1
    FLD xmm1, 128.0
    addss xmm0, xmm1
    cvttss2si eax, xmm0
    add rsp, 8
    ret

%ifdef WIN64
; enable_vt -- let the Windows console understand ANSI colour codes
enable_vt:
    PROLOGUE 16
    mov edi, -11                        ; STD_OUTPUT_HANDLE
    call GetStdHandle
    mov rbx, rax
    mov rdi, rax
    lea rsi, [rsp+0]
    call GetConsoleMode
    mov esi, [rsp+0]
    or esi, 5                           ; PROCESSED_OUTPUT | VIRTUAL_TERMINAL_PROCESSING
    mov rdi, rbx
    call SetConsoleMode
    EPILOGUE
extern GetStdHandle, GetConsoleMode, SetConsoleMode
%endif
terminal_intro:
    PROLOGUE 16
%ifdef WIN64
    call enable_vt
%endif
    lea rdi, [intro_file]
    mov esi, 1000                       ; one line per second, like intro.sh
    call print_rainbow
.ask:
    lea rdi, [question]
    xor eax, eax
    call printf
.read:
    lea rdi, [int_format]
    lea rsi, [input_val]
    xor eax, eax
    call scanf
    cmp eax, 1
    jne .eof
    cmp dword [input_val], 0
    jne .journey
    ; the coward loop
    lea rdi, [omniman]
    xor esi, esi
    call print_rainbow
    lea rdi, [usure]
    xor eax, eax
    call printf
    mov edi, 1000
    call SDL_Delay
    jmp .read
.journey:
    call ask_seed
    mov eax, 1
    EPILOGUE
.eof:
    xor eax, eax
    EPILOGUE

; ask_seed -- "Please enter your game seed (-1 for random)"
ask_seed:
    PROLOGUE 16
    lea rdi, [prompt_seed]
    xor eax, eax
    call printf
    xor edi, edi                        ; fflush(NULL): every stream
    call fflush
    mov dword [input_val], -1
    lea rdi, [int_format]
    lea rsi, [input_val]
    xor eax, eax
    call scanf
    mov eax, [input_val]
    cmp eax, -1
    jne .have
    xor edi, edi
    call time
.have:
    and eax, 0x7fffffff
    mov [seed_val], eax
    EPILOGUE


; =============================================================================
; game setup
; =============================================================================

; random_cell(edi=required floor or -1, esi=max x or 0, edx=min y or 0)
; -> eax node id of a random open floor cell far from the start
random_cell:
    PROLOGUE 32
    mov [rsp+0], edi
    mov [rsp+4], esi
    mov [rsp+8], edx
    mov r15d, 5000
.try:
    dec r15d
    js .give_up
    call rng_next
    xor edx, edx
    div dword [open_count]
    mov r12d, [open_cells+rdx*4]
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
    cmp dword [rsp+0], 0
    jl .f_ok
    cmp ebx, [rsp+0]
    jne .try
.f_ok:
    cmp dword [rsp+4], 0
    je .x_ok
    cmp r13d, [rsp+4]
    jge .try
.x_ok:
    cmp r14d, [rsp+8]
    jl .try
    ; far from the start: |x-1| + |y-1| + 15*|f-1| > 12
    mov eax, r13d
    sub eax, START_X
    mov ecx, eax
    neg ecx
    cmovl ecx, eax
    mov eax, r14d
    sub eax, START_Y
    mov edx, eax
    neg edx
    cmovl edx, eax
    add ecx, edx
    mov eax, ebx
    sub eax, START_F
    mov edx, eax
    neg edx
    cmovl edx, eax
    imul edx, edx, 15
    add ecx, edx
    cmp ecx, 12
    jle .try
.give_up:
    mov eax, r12d
    EPILOGUE

; add_item(edi=kind, esi=node id)
add_item:
    PROLOGUE 16
    mov r12d, edi
    mov edi, esi
    call node_center
    mov eax, [item_count]
    cmp eax, MAX_ITEMS
    jge .full
    imul ecx, eax, ITEM_SIZE
    lea rbx, [items+rcx]
    mov [rbx+ITEM_KIND], r12d
    mov dword [rbx+ITEM_ACTIVE], 1
    mov dword [rbx+ITEM_SEEN], 0
    movss [rbx+ITEM_X], xmm0
    movss [rbx+ITEM_Y], xmm1
    movss [rbx+ITEM_Z], xmm2
    movaps xmm0, xmm1
    call floor_of_height
    mov [rbx+ITEM_F], eax
    inc dword [item_count]
.full:
    EPILOGUE

new_game:
    PROLOGUE 16
    mov edi, [seed_val]
    call rng_seed
    xor eax, eax
    mov [inventory], eax
    mov [deauths], eax
    mov [elapsed_time], eax
    mov [item_count], eax
    mov [last_band], eax
    mov [was_safe], eax
    mov [tyler_said], eax
    mov [cage_hint], eax
    mov [b_cooldown], eax
    mov [heart_t], eax
    mov [light_t], eax
    mov [lightning], eax
    mov [hud_flash], eax
    mov [hud_vignette], eax
    mov [hud_safe_tint], eax
    mov [map_visible], eax
    mov [hud_paused], eax
    mov [t_speed_bonus], eax
    mov dword [next_thunder], __float32__(20.0)
    mov dword [game_state], GS_PLAYING
    lea rdi, [explored]
    xor esi, esi
    mov edx, NCELLS
    call memset
    call hud_clear_messages
    mov edi, START_F
    mov esi, START_X
    mov edx, START_Y
    call player_spawn

    ; one wireshark capture per storey, so you have to go everywhere
    xor ebx, ebx
.keys:
    cmp ebx, NF
    jge .keys_done
    mov edi, ebx
    xor esi, esi
    xor edx, edx
    call random_cell
    mov esi, eax
    mov edi, IT_KEY
    call add_item
    inc ebx
    jmp .keys
.keys_done:
    ; three deauth packets anywhere
    mov ebx, 3
.weap:
    mov edi, -1
    xor esi, esi
    xor edx, edx
    call random_cell
    mov esi, eax
    mov edi, IT_WEAPON
    call add_item
    dec ebx
    jnz .weap
    ; Tyler in the second-floor faculty lounge, the chicken jockey in the gym
    mov edi, 2
    mov esi, 12
    mov edx, 18
    call random_cell
    mov esi, eax
    mov edi, IT_TYLER
    call add_item
    mov edi, 1
    mov esi, 10
    mov edx, 18
    call random_cell
    mov esi, eax
    mov edi, IT_JOCKEY
    call add_item

    ; T starts far away (SPAWN_MIN_DIST was 15 in the asm; storeys count 12)
    mov edi, -1
    mov esi, 1
    mov edx, START_F
    mov ecx, START_X
    mov r8d, START_Y
    mov r9d, 22
    call random_node
    mov edi, eax
    call enemy_reset

    ; welcome messages
    lea rdi, [msg_buf]
    mov esi, 512
    lea rdx, [m_seed]
    mov ecx, [seed_val]
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, COL_INFO
    call msg
    lea rdi, [m_controls]
    mov esi, COL_INFO
    call msg
    call SDL_GetTicks
    mov [start_ticks], eax
    EPILOGUE

; =============================================================================
; interaction
; =============================================================================

; nearest_item(xmm0=reach, edi=1 to include NPCs) -> rax item ptr or 0
nearest_item:
    PROLOGUE 32
    movss [rsp+0], xmm0                 ; best distance so far
    mov [rsp+4], edi
    xor r12, r12
    xor ebx, ebx
.it:
    cmp ebx, [item_count]
    jge .done
    imul eax, ebx, ITEM_SIZE
    lea r13, [items+rax]
    cmp dword [r13+ITEM_ACTIVE], 0
    je .n
    cmp dword [rsp+4], 0
    jne .kind_ok
    cmp dword [r13+ITEM_KIND], IT_TYLER
    jge .n
.kind_ok:
    movss xmm0, [r13+ITEM_Y]
    subss xmm0, [p_y]
    andps xmm0, [c_abs_mask]
    comiss xmm0, [c_same]
    jae .n
    movss xmm0, [r13+ITEM_X]
    subss xmm0, [p_x]
    mulss xmm0, xmm0
    movss xmm1, [r13+ITEM_Z]
    subss xmm1, [p_z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    comiss xmm0, [rsp+0]
    jae .n
    movss [rsp+0], xmm0
    mov r12, r13
.n:
    inc ebx
    jmp .it
.done:
    mov rax, r12
    EPILOGUE

; near_b() -> eax 1 if B is within talking distance
near_b:
    PROLOGUE 16
    call player_floor
    cmp eax, [b_floor]
    jne .no
    movss xmm0, [b_pos_x]
    subss xmm0, [p_x]
    mulss xmm0, xmm0
    movss xmm1, [b_pos_z]
    subss xmm1, [p_z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    comiss xmm0, [c_b_reach]
    jae .no
    mov eax, 1
    EPILOGUE
.no:
    xor eax, eax
    EPILOGUE

; interact -- E: pick up the nearest item, or talk to B
interact:
    PROLOGUE 16
    movss xmm0, [c_reach]
    xor edi, edi
    call nearest_item
    test rax, rax
    jz .try_b
    mov rbx, rax
    mov dword [rbx+ITEM_ACTIVE], 0
    call snd_pickup
    cmp dword [rbx+ITEM_KIND], IT_KEY
    jne .weapon
    inc dword [inventory]
    ; T gets angrier with every capture
    cvtsi2ss xmm0, dword [inventory]
    mulss xmm0, [c_bonus]
    movss [t_speed_bonus], xmm0
    lea rdi, [msg_buf]
    mov esi, 512
    lea rdx, [m_got_key]
    mov ecx, [inventory]
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, COL_GOOD
    call msg
    cmp dword [inventory], 3
    jne .done
    lea rdi, [m_all_keys]
    mov esi, COL_GOOD
    call msg
    jmp .done
.weapon:
    inc dword [deauths]
    lea rdi, [m_weapon]
    mov esi, COL_GOOD
    call msg
    jmp .done
.try_b:
    call near_b
    test eax, eax
    jz .done
    cmp dword [inventory], 3
    jl .talk
    mov dword [game_state], GS_WON
    jmp .done
.talk:
    movss xmm0, [b_cooldown]
    comiss xmm0, [c_zero]
    ja .done
    lea rdi, [m_see_b]
    call lore
    lea rdi, [msg_buf]
    mov esi, 512
    lea rdx, [m_have]
    mov ecx, [inventory]
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, COL_INFO
    call msg
    mov eax, [c_b_talk_cd]
    mov [b_cooldown], eax
.done:
    EPILOGUE

; fire_deauth -- Q / right mouse button
fire_deauth:
    PROLOGUE 16
    cmp dword [deauths], 0
    jg .have
    lea rdi, [m_no_weapon]
    mov esi, COL_WARN
    call msg
    EPILOGUE
.have:
    dec dword [deauths]
    call snd_deauth
    lea rdi, [m_fired]
    mov esi, COL_GOOD
    call msg
    mov eax, [c_one]
    mov [hud_flash], eax
    call player_floor
    mov edi, eax
    movss xmm0, [p_x]
    mulss xmm0, [c_inv_cell]
    cvttss2si esi, xmm0
    movss xmm0, [p_z]
    mulss xmm0, [c_inv_cell]
    cvttss2si edx, xmm0
    call enemy_deauth
    EPILOGUE

; called by ai.asm the moment T starts chasing you
on_t_spotted:
    PROLOGUE 16
    call snd_spotted
    lea rdi, [m_spotted]
    mov esi, COL_DANGER
    call msg
    EPILOGUE

; set_paused(edi=1/0)
set_paused:
    PROLOGUE 16
    mov ebx, edi
    mov [hud_paused], ebx
    mov eax, GS_PLAYING
    test ebx, ebx
    jz .s
    mov eax, GS_PAUSED
.s:
    mov [game_state], eax
    mov edi, ebx
    call snd_mute
    mov edi, ebx
    xor edi, 1
    call mouse_capture
    call SDL_GetPerformanceCounter
    mov [perf_last], rax
    EPILOGUE

; -----------------------------------------------------------------------------
; Mouse look without SDL's relative mode.
;
; SDL's relative mode can't truly lock the pointer under WSLg (Windows sends
; absolute positions over RDP and ignores warps), and SDL then computes
; deltas against a centre the cursor never went to -- jumpy, "inverted"
; turning. So we do what old FPS games did: confine and hide the cursor,
; turn by how far it really moved since the last event, and warp it back to
; the centre when it drifts near an edge. The motion event our own warp
; produces is recognised and ignored. If a system ignores warps, turning
; simply stops at the window edge (the arrow keys still turn) -- it never
; jumps backwards.
; -----------------------------------------------------------------------------

; request_msaa -- 4x multisample antialiasing, unless we are rendering in
; software (LIBGL_ALWAYS_SOFTWARE, e.g. Docker) where it costs too much.
; BEACOM_MSAA=0/2/4/8 overrides.
request_msaa:
    PROLOGUE 16
    mov ebx, 4
    lea rdi, [env_soft]
    call getenv
    test rax, rax
    jz .env
    xor ebx, ebx
.env:
    lea rdi, [env_msaa]
    call getenv
    test rax, rax
    jz .set
    movzx ebx, byte [rax]
    sub ebx, 0x30
    and ebx, 15
.set:
    test ebx, ebx
    jz .done
    mov edi, SDL_GL_MULTISAMPLEBUFFERS
    mov esi, 1
    call SDL_GL_SetAttribute
    mov edi, SDL_GL_MULTISAMPLESAMPLES
    mov esi, ebx
    call SDL_GL_SetAttribute
.done:
    EPILOGUE

; choose_mouse_mode -- WSLg can't warp the pointer, so it gets the edge mode;
; everything else uses SDL relative mode in "warp" flavour (works on any real
; X server, including VcXsrv over the network, unlike XInput2 raw motion).
; BEACOM_MOUSE=edge / BEACOM_MOUSE=relative overrides the guess.
choose_mouse_mode:
    PROLOGUE 16
    mov dword [mouse_edge_mode], 0
    lea rdi, [env_wsl]
    call getenv
    test rax, rax
    jz .no_wsl
    mov dword [mouse_edge_mode], 1
.no_wsl:
    lea rdi, [env_mouse]
    call getenv
    test rax, rax
    jz .decided
    cmp byte [rax], 'e'
    jne .not_edge
    mov dword [mouse_edge_mode], 1
    jmp .decided
.not_edge:
    cmp byte [rax], 'r'
    jne .decided
    mov dword [mouse_edge_mode], 0
.decided:
    cmp dword [mouse_edge_mode], 0
    jne .done
    lea rdi, [hint_warp]
    lea rsi, [hint_one]
    call SDL_SetHint
.done:
    EPILOGUE

; mouse_capture(edi=1 capture / 0 release)
; Two modes, picked at start-up (see choose_mouse_mode):
;   relative -- SDL's own relative mode: cursor hidden and warped back to the
;               centre after every movement. Right for real X servers
;               (native Linux, VcXsrv for Docker on Windows).
;   edge     -- the fallback described above, for WSLg where warps are ignored.
mouse_capture:
    PROLOGUE 16
    cmp dword [mouse_edge_mode], 0
    jne .edge
    call SDL_SetRelativeMouseMode       ; edi = on/off
    EPILOGUE
.edge:
    mov ebx, edi
    mov rdi, [window]
    mov esi, ebx
    call SDL_SetWindowGrab
    mov edi, ebx
    xor edi, 1                          ; SDL_ShowCursor(0) hides it
    call SDL_ShowCursor
    mov dword [mouse_have_last], 0
    test ebx, ebx
    jz .done
    call recenter_mouse
.done:
    EPILOGUE

; recenter_mouse -- warp the cursor to the middle of the window
recenter_mouse:
    PROLOGUE 16
    mov rdi, [window]
    lea rsi, [win_w]
    lea rdx, [win_h]
    call SDL_GetWindowSize
    mov esi, [win_w]
    shr esi, 1
    mov edx, [win_h]
    shr edx, 1
    mov [warp_x], esi
    mov [warp_y], edx
    mov dword [warp_pending], 1
    mov rdi, [window]
    call SDL_WarpMouseInWindow
    EPILOGUE

; mouse_moved(edi=x, esi=y) -- absolute cursor position from a motion event
mouse_moved:
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    ; the echo of our own warp: just resync, no turning
    cmp dword [warp_pending], 0
    je .real
    cmp r12d, [warp_x]
    jne .real
    cmp r13d, [warp_y]
    jne .real
    mov dword [warp_pending], 0
    jmp .set_last
.real:
    cmp dword [mouse_have_last], 0
    je .set_last
    cmp dword [game_state], GS_PLAYING
    jne .set_last
    mov edi, r12d
    sub edi, [mouse_last_x]
    mov esi, r13d
    sub esi, [mouse_last_y]
    cmp dword [invert_y], 0
    je .look
    neg esi
.look:
    call player_look
.set_last:
    mov [mouse_last_x], r12d
    mov [mouse_last_y], r13d
    mov dword [mouse_have_last], 1
    cmp dword [game_state], GS_PLAYING
    jne .done
    ; drifted into the outer quarter of the window? pull it back to the centre
    mov eax, [win_w]
    shr eax, 2
    cmp r12d, eax
    jl .recentre
    imul eax, 3
    cmp r12d, eax
    jg .recentre
    mov eax, [win_h]
    shr eax, 2
    cmp r13d, eax
    jl .recentre
    imul eax, 3
    cmp r13d, eax
    jg .recentre
    jmp .done
.recentre:
    call recenter_mouse
.done:
    EPILOGUE

; =============================================================================
; input
; =============================================================================
handle_events:
    PROLOGUE 16
.poll:
    lea rdi, [event]
    call SDL_PollEvent
    test eax, eax
    jz .done
    mov eax, [event]
    cmp eax, SDL_QUIT_EV
    jne .not_quit
    mov dword [game_state], GS_QUIT
    jmp .poll
.not_quit:
    cmp eax, SDL_WINDOWEVENT
    jne .not_win
    cmp byte [event+12], SDL_WINDOWEVENT_FOCUS_LOST
    jne .poll
    cmp dword [game_state], GS_PLAYING
    jne .poll
    cmp dword [shot_mode], 0
    jne .poll
    mov edi, 1
    call set_paused
    jmp .poll
.not_win:
    cmp eax, SDL_MOUSEMOTION
    jne .not_motion
    cmp dword [game_state], GS_PLAYING
    jne .poll
    cmp dword [shot_mode], 0
    jne .poll
    cmp dword [mouse_edge_mode], 0
    jne .edge_motion
    ; relative mode: SDL already gives us clean deltas
    cmp dword [game_state], GS_PLAYING
    jne .poll
    mov edi, [event+28]                 ; xrel
    mov esi, [event+32]                 ; yrel
    cmp dword [invert_y], 0
    je .rel_look
    neg esi
.rel_look:
    call player_look
    jmp .poll
.edge_motion:
    mov edi, [event+20]                 ; absolute x (see mouse_moved)
    mov esi, [event+24]                 ; absolute y
    call mouse_moved
    jmp .poll
.not_motion:
    cmp eax, SDL_MOUSEBUTTONDOWN
    jne .not_button
    movzx ecx, byte [event+16]
    cmp dword [game_state], GS_PAUSED
    jne .btn_play
    cmp ecx, 1
    jne .poll
    xor edi, edi
    call set_paused
    jmp .poll
.btn_play:
    cmp dword [game_state], GS_PLAYING
    jne .poll
    cmp ecx, 3
    jne .poll
    call fire_deauth
    jmp .poll
.not_button:
    cmp eax, SDL_KEYDOWN
    jne .poll
    cmp byte [event+13], 0              ; ignore key repeat
    jne .poll
    mov ecx, [event+16]                 ; scancode
    cmp ecx, SC_ESC
    jne .not_esc
    xor edi, edi
    cmp dword [game_state], GS_PLAYING
    jne .toggle
    mov edi, 1
.toggle:
    call set_paused
    jmp .poll
.not_esc:
    cmp dword [game_state], GS_PLAYING
    jne .poll
    cmp ecx, SC_F
    jne .k1
    ; flashlight (won't turn on with a flat battery)
    cmp dword [p_flash_on], 0
    jne .flash_off
    movss xmm0, [p_battery]
    FLD xmm1, 0.03
    comiss xmm0, xmm1
    jb .poll
    mov dword [p_flash_on], 1
    xor edi, edi
    call snd_footstep                   ; click
    jmp .poll
.flash_off:
    mov dword [p_flash_on], 0
    xor edi, edi
    call snd_footstep
    jmp .poll
.k1:
    cmp ecx, SC_E
    jne .k2
    call interact
    jmp .poll
.k2:
    cmp ecx, SC_Q
    jne .k3
    call fire_deauth
    jmp .poll
.k3:
    cmp ecx, SC_I
    jne .k4
    ; I: invert vertical mouse look
    xor dword [invert_y], 1
    lea rdi, [m_inv_off]
    cmp dword [invert_y], 0
    je .inv_msg
    lea rdi, [m_inv_on]
.inv_msg:
    mov esi, COL_INFO
    call msg
    jmp .poll
.k4:
    cmp ecx, SC_F3
    jne .k5
    ; F3: frames-per-second counter
    xor dword [show_fps], 1
    mov dword [hud_fps], -1
    jmp .poll
.k5:
    cmp ecx, SC_F4
    jne .k6
    call render_cycle_scale                ; F4: render resolution 1/1, 1/2, 1/3
    jmp .poll
.k6:
    cmp ecx, SC_F5
    jne .k7
    call render_toggle_shadows          ; F5: flashlight shadows on/off
    jmp .poll
.k7:
    cmp ecx, SC_M
    je .map
    cmp ecx, SC_TAB
    jne .poll
.map:
    xor dword [map_visible], 1
    jmp .poll
.done:
    ; held keys straight from SDL's keyboard state
    xor edi, edi
    call SDL_GetKeyboardState
    mov rbx, rax
    xor eax, eax
    or al, [rbx+SC_W]
    or al, [rbx+SC_UP]
    mov [keys_down+K_FWD], al
    xor eax, eax
    or al, [rbx+SC_S]
    or al, [rbx+SC_DOWN]
    mov [keys_down+K_BACK], al
    mov al, [rbx+SC_A]
    mov [keys_down+K_LEFT], al
    mov al, [rbx+SC_D]
    mov [keys_down+K_RIGHT], al
    ; left/right arrows turn (a backup for when the mouse can't be captured)
    mov al, [rbx+SC_LEFT]
    mov [keys_down+K_TURN_L], al
    mov al, [rbx+SC_RIGHT]
    mov [keys_down+K_TURN_R], al
    xor eax, eax
    or al, [rbx+SC_LSHIFT]
    or al, [rbx+SC_RSHIFT]
    mov [keys_down+K_SPRINT], al
    xor eax, eax
    or al, [rbx+SC_C]
    or al, [rbx+SC_LCTRL]
    mov [keys_down+K_CROUCH], al
    mov al, [rbx+SC_SPACE]
    mov [keys_down+K_JUMP], al
    EPILOGUE

; =============================================================================
; per-frame game logic
; =============================================================================

; footstep noise: walking has the original 1-in-N chance to make a noise,
; sprinting and hard landings always carry
step_noise:
    PROLOGUE 16
    mov eax, [p_step_event]
    test eax, eax
    jz .done
    cmp eax, 1                          ; crouching: silent
    je .done
    movss xmm3, [c_sens_run]
    cmp eax, 3
    je .hear
    movss xmm3, [c_sens_walk]
    movss [rsp+0], xmm3
    call rng_next
    xor edx, edx
    div dword [c_noise_p]
    movss xmm3, [rsp+0]
    test edx, edx
    jnz .hear
    lea rdi, [m_noise]
    mov esi, COL_WARN
    call msg
    call snd_noise_alert
    movss xmm3, [c_noise_r]
.hear:
    movss xmm0, [p_x]
    movss xmm1, [p_y]
    movss xmm2, [p_z]
    call enemy_hear
.done:
    EPILOGUE

; items: notice captures, Tyler says hi, the chicken jockey gets you
update_items:
    PROLOGUE 16
    xor ebx, ebx
.it:
    cmp ebx, [item_count]
    jge .done
    imul eax, ebx, ITEM_SIZE
    lea r12, [items+rax]
    cmp dword [r12+ITEM_ACTIVE], 0
    je .n
    movss xmm0, [r12+ITEM_Y]
    subss xmm0, [p_y]
    andps xmm0, [c_abs_mask]
    comiss xmm0, [c_same]
    jae .n
    movss xmm0, [r12+ITEM_X]
    subss xmm0, [p_x]
    mulss xmm0, xmm0
    movss xmm1, [r12+ITEM_Z]
    subss xmm1, [p_z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    mov eax, [r12+ITEM_KIND]
    cmp eax, IT_KEY
    jne .tyler
    cmp dword [r12+ITEM_SEEN], 0
    jne .n
    comiss xmm0, [c_see_dist]
    jae .n
    mov dword [r12+ITEM_SEEN], 1
    lea rdi, [m_see_key]
    mov esi, COL_INFO
    call msg
    jmp .n
.tyler:
    cmp eax, IT_TYLER
    jne .jockey
    cmp dword [tyler_said], 0
    jne .n
    comiss xmm0, [c_tyler_d]
    jae .n
    mov dword [tyler_said], 1
    lea rdi, [m_tyler]
    mov esi, COL_DANGER
    call msg
    jmp .n
.jockey:
    cmp eax, IT_JOCKEY
    jne .n
    comiss xmm0, [c_jockey_d]
    jae .n
    mov dword [game_state], GS_SECRET
.n:
    inc ebx
    jmp .it
.done:
    EPILOGUE

; proximity bands -- same distances as check_proximity in doom.asm; returns
; eax = band 0..3 and prints a warning when the band goes up
proximity:
    PROLOGUE 32
    movss xmm0, [t_dist]
    mulss xmm0, [c_inv_cell]            ; in cells
    xor ebx, ebx
    cmp dword [t_same_storey], 0
    jne .same
    movss xmm1, [c_three]
    comiss xmm0, xmm1
    jbe .same
    comiss xmm0, [c_band_far]
    jae .have
    mov ebx, 1
    jmp .have
.same:
    mov ebx, 3
    comiss xmm0, [c_band_3]
    jbe .have
    mov ebx, 2
    comiss xmm0, [c_band_2]
    jbe .have
    mov ebx, 1
    comiss xmm0, [c_band_1]
    jbe .have
    xor ebx, ebx
.have:
    cmp ebx, [last_band]
    jle .store
    ; which way? above/below, else ahead/behind the way you face
    lea r12, [d_ahead]
    movss xmm0, [p_yaw]
    call sinf
    movss [rsp+0], xmm0
    movss xmm0, [p_yaw]
    call cosf
    ; forward = (-sin, -cos); dot with (T - player)
    movss xmm1, [t_x]
    subss xmm1, [p_x]
    mulss xmm1, [rsp+0]
    movss xmm2, [t_z]
    subss xmm2, [p_z]
    mulss xmm2, xmm0
    addss xmm1, xmm2
    comiss xmm1, [c_zero]
    jbe .dir_done
    lea r12, [d_behind]
.dir_done:
    movss xmm0, [t_y]
    subss xmm0, [p_y]
    comiss xmm0, [c_vert]
    jbe .not_above
    lea r12, [d_above]
.not_above:
    xorps xmm0, [c_sign_mask]
    comiss xmm0, [c_vert]
    jbe .fmt
    lea r12, [d_below]
.fmt:
    cmp ebx, 1
    jne .b2
    lea rdi, [m_prox1]
    mov esi, COL_WARN
    call msg
    jmp .store
.b2:
    lea rdx, [m_prox2]
    mov r13d, COL_WARN
    cmp ebx, 3
    jne .b3
    lea rdx, [m_prox3]
    mov r13d, COL_DANGER
.b3:
    lea rdi, [msg_buf]
    mov esi, 512
    mov rcx, r12
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, r13d
    call msg
.store:
    mov [last_band], ebx
    mov eax, ebx
    EPILOGUE

; update_threat(xmm0=dt, edi=band) -- vignette, heartbeat, T's hum/panning
update_threat:
    PROLOGUE 32
    movss [rsp+0], xmm0
    mov ebx, edi
    ; vignette target
    xorps xmm1, xmm1
    test ebx, ebx
    jz .vt
    cvtsi2ss xmm1, ebx
    FLD xmm2, 0.25
    mulss xmm1, xmm2
    FLD xmm2, 0.2
    addss xmm1, xmm2
    cmp ebx, 3
    jne .vt
    movss [rsp+4], xmm1
    movss xmm0, [elapsed_time]
    mulss xmm0, [c_nine]
    call sinf
    FLD xmm1, 0.15
    mulss xmm0, xmm1
    movss xmm1, [rsp+4]
    addss xmm1, xmm0
.vt:
    minss xmm1, [c_one]
    ; ease toward the target
    subss xmm1, [hud_vignette]
    movss xmm2, [rsp+0]
    mulss xmm2, [c_vig_speed]
    minss xmm2, [c_one]
    mulss xmm1, xmm2
    addss xmm1, [hud_vignette]
    movss [hud_vignette], xmm1
    ; safe-room tint
    call player_in_safe
    cvtsi2ss xmm1, eax
    subss xmm1, [hud_safe_tint]
    movss xmm2, [rsp+0]
    mulss xmm2, [c_two]
    minss xmm2, [c_one]
    mulss xmm1, xmm2
    addss xmm1, [hud_safe_tint]
    movss [hud_safe_tint], xmm1
    ; deauth flash fades
    movss xmm1, [hud_flash]
    movss xmm2, [rsp+0]
    mulss xmm2, [c_flash_decay]
    subss xmm1, xmm2
    maxss xmm1, [c_zero]
    movss [hud_flash], xmm1
    ; heartbeat
    movss xmm0, [heart_t]
    subss xmm0, [rsp+0]
    movss [heart_t], xmm0
    test ebx, ebx
    jz .no_heart
    comiss xmm0, [c_zero]
    ja .no_heart
    mov eax, [c_hb_1]
    cmp ebx, 2
    jne .h2
    mov eax, [c_hb_2]
.h2:
    cmp ebx, 3
    jne .h3
    mov eax, [c_hb_3]
.h3:
    mov [heart_t], eax
    cvtsi2ss xmm0, ebx
    divss xmm0, [c_three]
    call snd_heartbeat
.no_heart:
    ; T's hum: pan = dot(right, dir to T), right = (cos yaw, 0, -sin yaw)
    movss xmm0, [p_yaw]
    call cosf
    movss [rsp+8], xmm0
    movss xmm0, [p_yaw]
    call sinf
    movss [rsp+12], xmm0
    movss xmm1, [t_x]
    subss xmm1, [p_x]
    movss xmm2, [t_z]
    subss xmm2, [p_z]
    movaps xmm3, xmm1
    mulss xmm3, xmm3
    movaps xmm4, xmm2
    mulss xmm4, xmm4
    addss xmm3, xmm4
    sqrtss xmm3, xmm3
    FLD xmm4, 0.01
    maxss xmm3, xmm4
    movss [rsp+16], xmm3                ; flat distance
    mulss xmm1, [rsp+8]
    mulss xmm2, [rsp+12]
    subss xmm1, xmm2
    divss xmm1, xmm3
    movss [rsp+20], xmm1                ; pan
    ; attenuation = min(1, 2/d)^1.4 over the true 3D distance
    movss xmm0, [t_dist]
    maxss xmm0, [c_two]
    movss xmm1, [c_two]
    divss xmm1, xmm0
    movaps xmm0, xmm1
    movss xmm1, [c_att_pow]
    call powf
    movss [rsp+24], xmm0
    movss xmm2, [c_hum_idle]
    cmp dword [t_state], T_CHASE
    jne .hl
    movss xmm2, [c_hum_chase]
.hl:
    movss xmm0, [t_stun]
    comiss xmm0, [c_zero]
    jbe .not_stunned
    xorps xmm2, xmm2
.not_stunned:
    movss xmm0, [rsp+20]
    movss xmm1, [rsp+24]
    call snd_set_t
    EPILOGUE

; lightning through the windows (not in the basement)
update_weather:
    PROLOGUE 16
    movss [rsp+0], xmm0
    movss xmm1, [next_thunder]
    subss xmm1, xmm0
    movss [next_thunder], xmm1
    comiss xmm1, [c_zero]
    ja .no_new
    call rand01
    mulss xmm0, [c_thunder_rng]
    addss xmm0, [c_thunder_min]
    movss [next_thunder], xmm0
    call player_floor
    test eax, eax
    jz .no_new
    mov eax, [c_one]
    mov [light_t], eax
    call snd_thunder
.no_new:
    ; strobe while bright, then fade
    xorps xmm0, xmm0
    movss xmm1, [light_t]
    comiss xmm1, [c_zero]
    jbe .set
    movss xmm2, [rsp+0]
    mulss xmm2, [c_light_decay]
    subss xmm1, xmm2
    movss [light_t], xmm1
    movaps xmm0, xmm1
    comiss xmm1, [c_strobe]
    jbe .set
    movss xmm0, [elapsed_time]
    mulss xmm0, [c_sixty]
    call sinf
    movaps xmm1, xmm0
    movss xmm0, [c_one]
    comiss xmm1, [c_zero]
    ja .set
    movss xmm0, [c_strobe_lo]
.set:
    maxss xmm0, [c_zero]
    movss [lightning], xmm0
    EPILOGUE

; which interaction prompt to show
update_prompt:
    PROLOGUE 16
    mov dword [hud_prompt], -1
    movss xmm0, [c_reach]
    xor edi, edi
    call nearest_item
    test rax, rax
    jz .b
    mov ecx, [rax+ITEM_KIND]
    mov [hud_prompt], ecx               ; 0 capture, 1 deauth
    EPILOGUE
.b:
    call near_b
    test eax, eax
    jz .done
    mov dword [hud_prompt], 2
    cmp dword [inventory], 3
    jl .done
    mov dword [hud_prompt], 3
.done:
    EPILOGUE

; the whole frame of gameplay (xmm0 = dt)
game_tick:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss xmm1, [elapsed_time]
    addss xmm1, xmm0
    movss [elapsed_time], xmm1
    movss xmm1, [b_cooldown]
    subss xmm1, xmm0
    movss [b_cooldown], xmm1

    movss xmm0, [rsp+0]
    movss xmm1, [elapsed_time]
    call player_update
    call step_noise
    movss xmm0, [rsp+0]
    call enemy_update
    movss xmm0, [rsp+0]
    movss xmm1, [elapsed_time]
    call world_lights_update
    call update_items

    ; Y's cage
    cmp dword [cage_hint], 0
    jne .no_cage
    call player_floor
    test eax, eax
    jnz .no_cage
    movss xmm0, [y_pos_x]
    subss xmm0, [p_x]
    mulss xmm0, xmm0
    movss xmm1, [y_pos_z]
    subss xmm1, [p_z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    comiss xmm0, [c_cage_d]
    jae .no_cage
    mov dword [cage_hint], 1
    lea rdi, [m_cage]
    call lore
.no_cage:
    ; safe room enter / leave
    call player_in_safe
    cmp eax, [was_safe]
    je .safe_same
    mov [was_safe], eax
    lea rdi, [m_safe_out]
    mov esi, COL_INFO
    test eax, eax
    jz .safe_msg
    lea rdi, [m_safe_in]
    mov esi, COL_GOOD
.safe_msg:
    call msg
.safe_same:
    call proximity
    mov edi, eax
    movss xmm0, [rsp+0]
    call update_threat
    movss xmm0, [rsp+0]
    call update_weather
    call player_floor
    mov edi, eax
    call snd_set_floor
    ; caught?
    cmp dword [t_caught], 0
    je .alive
    mov dword [game_state], GS_LOST
.alive:
    call update_prompt
    call hud_update_explored
    EPILOGUE

; draw the frame and present it (xmm0 = dt for the HUD)
present:
    PROLOGUE 16
    movss [rsp+0], xmm0
    ; frames-per-second counter (F3), refreshed once a second
    inc dword [fps_frames]
    addss xmm0, [fps_time]
    movss [fps_time], xmm0
    comiss xmm0, [c_one]
    jb .fps_done
    subss xmm0, [c_one]
    movss [fps_time], xmm0
    mov eax, -1
    cmp dword [show_fps], 0
    je .fps_set
    mov eax, [fps_frames]
.fps_set:
    mov [hud_fps], eax
    mov dword [fps_frames], 0
.fps_done:
    mov rdi, [window]
    lea rsi, [win_w]
    lea rdx, [win_h]
    call SDL_GetWindowSize
    mov edi, [win_w]
    mov esi, [win_h]
    movss xmm0, [elapsed_time]
    call render_frame
    mov edi, [win_w]
    mov esi, [win_h]
    movss xmm0, [rsp+0]
    movss xmm1, [elapsed_time]
    call hud_draw
    mov rdi, [window]
    call SDL_GL_SwapWindow
    EPILOGUE

; frame_dt() -> xmm0 seconds since the last call (capped)
frame_dt:
    PROLOGUE 16
    call SDL_GetPerformanceCounter
    mov rcx, rax
    sub rax, [perf_last]
    mov [perf_last], rcx
    cvtsi2ss xmm0, rax
    cvtsi2ss xmm1, qword [perf_freq]
    divss xmm0, xmm1
    minss xmm0, [c_max_dt]
    EPILOGUE

; play_round -- runs until caught, won, secret or quit. Returns game_state.
play_round:
    PROLOGUE 16
    call new_game
    mov edi, 1
    call mouse_capture
    call SDL_GetPerformanceCounter
    mov [perf_last], rax
.loop:
    call handle_events
    call frame_dt
    movss [rsp+0], xmm0
    mov eax, [game_state]
    cmp eax, GS_PAUSED
    je .draw
    cmp eax, GS_PLAYING
    jne .over
    movss xmm0, [rsp+0]
    call game_tick
.draw:
    movss xmm0, [rsp+0]
    call present
    jmp .loop
.over:
    ; the jumpscare: T's face fills the screen, shaking, for 1.3 seconds
    cmp eax, GS_LOST
    je .scare
    cmp eax, GS_SECRET
    jne .no_scare
.scare:
    call snd_jumpscare
    mov dword [jump_t], 0
.scare_loop:
    call frame_dt
    addss xmm0, [jump_t]
    movss [jump_t], xmm0
    comiss xmm0, [c_jump_time]
    jae .no_scare
    mov rdi, [window]
    lea rsi, [win_w]
    lea rdx, [win_h]
    call SDL_GetWindowSize
    mov edi, [win_w]
    mov esi, [win_h]
    movss xmm0, [jump_t]
    call render_jumpscare
    mov rdi, [window]
    call SDL_GL_SwapWindow
    lea rdi, [event]
    call SDL_PollEvent
    jmp .scare_loop
.no_scare:
    cmp dword [game_state], GS_WON
    jne .not_won
    call snd_win
.not_won:
    xor edi, edi
    call mouse_capture
    mov eax, [game_state]
    EPILOGUE

; end_screen(edi=state) -- lolcat art + stats in the terminal
end_screen:
    PROLOGUE 16
    mov ebx, edi
    mov rdi, [window]
    call SDL_HideWindow
    lea rdi, [game_over_cmd]
    lea r12, [m_caught]
    cmp ebx, GS_SECRET
    jne .e1
    lea rdi, [jockey_cmd]
    lea r12, [m_jockey]
.e1:
    cmp ebx, GS_WON
    jne .e2
    lea rdi, [game_won_cmd]
    lea r12, [m_won]
.e2:
    xor esi, esi
    call print_rainbow
    ; seed - time - captures
    call SDL_GetTicks
    sub eax, [start_ticks]
    xor edx, edx
    mov ecx, 1000
    div ecx
    xor edx, edx
    mov ecx, 60
    div ecx                             ; eax = minutes, edx = seconds
    lea rdi, [stats_fmt]
    mov rsi, r12
    mov r8d, edx
    mov ecx, eax
    mov edx, [seed_val]
    mov r9d, [inventory]
    xor eax, eax
    call printf
    EPILOGUE

; =============================================================================
; --shot: render test screenshots from fixed spots, then exit
; =============================================================================
shot_mode_run:
    PROLOGUE 32
    lea rdi, [mkdir_shots]
    call system
    mov dword [seed_val], 42
    call new_game
    lea rdi, [m_see_b]
    call lore
    xor r12d, r12d
.shot:
    cmp r12d, NSHOTS
    jge .done
    imul eax, r12d, SHOT_SIZE
    lea r13, [shots+rax]
    mov edi, [r13+0]
    mov esi, [r13+4]
    mov edx, [r13+8]
    call player_spawn
    mov eax, [r13+12]
    mov [p_yaw], eax
    mov eax, [r13+16]
    mov [p_pitch], eax
    mov eax, [r13+24]
    mov [map_visible], eax
    ; freeze T somewhere far unless this shot is about him
    mov dword [t_stun], __float32__(100.0)
    mov dword [t_x], __float32__(1000.0)
    mov dword [t_z], __float32__(1000.0)
    cmp dword [r13+20], 0
    je .no_t
    ; T 3.5 units in front of the camera, chasing
    mov dword [t_stun], 0
    mov dword [t_state], T_CHASE
    movss xmm0, [p_yaw]
    call sinf
    FLD xmm1, -3.5
    mulss xmm0, xmm1
    addss xmm0, [p_x]
    movss [t_x], xmm0
    movss xmm0, [p_yaw]
    call cosf
    FLD xmm1, -3.5
    mulss xmm0, xmm1
    addss xmm0, [p_z]
    movss [t_z], xmm0
    mov eax, [p_y]
    mov [t_y], eax
.no_t:
    ; settle the camera and the light pool for a few frames
    mov ebx, 20
.settle:
    movss xmm0, [c_dt_shot]
    movss xmm1, [elapsed_time]
    call player_update
    movss xmm0, [c_dt_shot]
    movss xmm1, [elapsed_time]
    call world_lights_update
    call hud_update_explored
    movss xmm0, [elapsed_time]
    addss xmm0, [c_dt_shot]
    movss [elapsed_time], xmm0
    dec ebx
    jnz .settle
    call update_prompt
    movss xmm0, [c_dt_shot]
    call present
    ; present swapped buffers: draw again and read before swapping
    mov edi, [win_w]
    mov esi, [win_h]
    movss xmm0, [elapsed_time]
    call render_frame
    mov edi, [win_w]
    mov esi, [win_h]
    movss xmm0, [c_dt_shot]
    movss xmm1, [elapsed_time]
    call hud_draw
    mov rdi, [r13+28]
    mov esi, [win_w]
    mov edx, [win_h]
    call save_screenshot
    ; BEACOM_DUMP_SHADOW=1: also save the flashlight depth map (shadow.bmp)
    lea rdi, [env_dump]
    call getenv
    test rax, rax
    jz .no_dump
    cmp r12d, 6                         ; the shot with T in it
    jne .no_dump
    lea rdi, [dump_name]
    call dump_shadow_map
.no_dump:
    mov rdi, [window]
    call SDL_GL_SwapWindow
    inc r12d
    jmp .shot
.done:
    EPILOGUE

; =============================================================================
; --selftest: drive the real physics and AI code and print what happens
; =============================================================================

; walk_test(rdi=name, esi=f, edx=x, ecx=y, xmm0=yaw, xmm1=seconds)
; spawn in a cell, face `yaw`, hold W, report where we ended up
walk_test:
    PROLOGUE 32
    mov [rsp+16], rdi
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    mov edi, esi
    mov esi, edx
    mov edx, ecx
    call player_spawn
    mov eax, [rsp+0]
    mov [p_yaw], eax
    mov byte [keys_down+K_FWD], 1
    movss xmm0, [rsp+4]
    FLD xmm1, 60.0
    mulss xmm0, xmm1
    cvttss2si ebx, xmm0                 ; frames at 60 fps
.step:
    movss xmm0, [c_dt_shot]
    movss xmm1, [elapsed_time]
    call player_update
    dec ebx
    jnz .step
    mov byte [keys_down+K_FWD], 0
    call player_floor
    mov edx, eax
    lea rdi, [st_walk_fmt]
    mov rsi, [rsp+16]
    cvtss2sd xmm0, [p_x]
    cvtss2sd xmm1, [p_y]
    cvtss2sd xmm2, [p_z]
    mov eax, 3
    call printf
    EPILOGUE

%define NODE(f,x,y) (((f)*MAP_H + (y))*MAP_W + (x))
extern path_len

selftest:
    PROLOGUE 32
    mov dword [seed_val], 42
    call new_game
    mov dword [t_stun], __float32__(10000.0)   ; T frozen for the walking tests

    lea rdi, [st_n_up]
    mov esi, 1
    mov edx, 19
    mov ecx, 13
    FLD xmm0, 0.0                       ; north
    FLD xmm1, 5.0
    call walk_test
    lea rdi, [st_n_c]
    mov esi, 1
    mov edx, 27
    mov ecx, 19
    FLD xmm0, 1.5708                    ; west (the long way round: 8s)
    FLD xmm1, 8.0
    call walk_test
    lea rdi, [st_n_down]
    mov esi, 1
    mov edx, 42
    mov ecx, 13
    FLD xmm0, 0.0                       ; north, into the shaft
    FLD xmm1, 6.0
    call walk_test
    lea rdi, [st_n_d]
    xor esi, esi
    mov edx, 40
    mov ecx, 27
    FLD xmm0, 0.0                       ; north
    FLD xmm1, 6.0
    call walk_test
    lea rdi, [st_n_desc]
    mov esi, 2
    mov edx, 19
    mov ecx, 5
    FLD xmm0, 3.1416                    ; south, down the stairs
    FLD xmm1, 5.0
    call walk_test
    lea rdi, [st_n_wall]
    mov esi, 1
    mov edx, 1
    mov ecx, 1
    FLD xmm0, 1.5708                    ; west, straight into the wall
    FLD xmm1, 2.0
    call walk_test

    ; path finding across three storeys
    mov edi, NODE(0,3,3)
    mov esi, NODE(2,5,3)
    call find_path
    mov esi, eax
    mov edx, [path_len]
    lea rdi, [st_path_fmt]
    xor eax, eax
    call printf

    ; T hunts a player standing still on the 2nd floor, starting in the basement
    mov edi, 2
    mov esi, 5
    mov edx, 3
    call player_spawn
    mov dword [p_flash_on], 0
    mov edi, NODE(0,3,3)
    call enemy_reset
    xor ebx, ebx                        ; frame
.hunt:
    cmp ebx, 60*200
    jge .not_caught
    ; every second he "hears" the player again, so he stays on target
    mov eax, ebx
    xor edx, edx
    mov ecx, 60
    div ecx
    test edx, edx
    jnz .no_hear
    movss xmm0, [p_x]
    movss xmm1, [p_y]
    movss xmm2, [p_z]
    FLD xmm3, 1000.0
    call enemy_hear
    ; progress report every 10 s
    mov eax, ebx
    xor edx, edx
    mov ecx, 600
    div ecx
    test edx, edx
    jnz .no_hear
    call report_t
.no_hear:
    movss xmm0, [c_dt_shot]
    call enemy_update
    cmp dword [t_caught], 0
    jne .caught
    inc ebx
    jmp .hunt
.caught:
    call report_t
    cvtsi2sd xmm0, ebx
    mov rax, __float64__(60.0)
    movq xmm1, rax
    divsd xmm0, xmm1
    lea rdi, [st_caught]
    mov eax, 1
    call printf
    jmp .safe_test
.not_caught:
    lea rdi, [st_notcaught]
    xor eax, eax
    call printf

.safe_test:
    ; the player hides in the 2nd-floor safe room: T must never get in
    mov edi, 2
    mov esi, 50
    mov edx, 8
    call player_spawn
    mov edi, NODE(2,30,15)
    call enemy_reset
    mov dword [t_state], T_CHASE
    mov ebx, 60*60
.hide:
    movss xmm0, [c_dt_shot]
    call enemy_update
    cmp dword [t_caught], 0
    jne .hide_done
    dec ebx
    jnz .hide
.hide_done:
    lea rdi, [st_safe_fmt]
    mov esi, [t_caught]
    xor eax, eax
    call printf

    ; render benchmark: 120 frames looking down the main hallway
    mov edi, 1
    mov esi, 8
    mov edx, 15
    call player_spawn
    mov dword [p_yaw], __float32__(-1.5708)
    mov dword [t_stun], __float32__(10000.0)
    call SDL_SetWindowSize_default
    ; warm up (first frames pay for shader/texture setup in the driver)
    mov ebx, 30
.warm:
    movss xmm0, [c_dt_shot]
    call present
    dec ebx
    jnz .warm
    call glFinish
    call SDL_GetPerformanceCounter
    mov [rsp+0], rax
    mov ebx, 120
.bench:
    movss xmm0, [c_dt_shot]
    movss xmm1, [elapsed_time]
    call player_update
    movss xmm0, [c_dt_shot]
    movss xmm1, [elapsed_time]
    call world_lights_update
    movss xmm0, [c_dt_shot]
    call present
    dec ebx
    jnz .bench
    call glFinish
    call SDL_GetPerformanceCounter
    sub rax, [rsp+0]
    cvtsi2sd xmm1, rax
    cvtsi2sd xmm2, qword [perf_freq]
    divsd xmm1, xmm2                    ; seconds for 120 frames
    mov rax, __float64__(120.0)
    movq xmm0, rax
    divsd xmm0, xmm1
    mov esi, [win_w]
    mov edx, [win_h]
    lea rdi, [st_fps_fmt]
    mov eax, 1
    call printf
    EPILOGUE

; the benchmark uses whatever size the window currently is
SDL_SetWindowSize_default:
    ret

; report_t(ebx=frame) -- where is T?
report_t:
    PROLOGUE 16
    movss xmm0, [t_x]
    movss xmm1, [t_y]
    movss xmm2, [t_z]
    call node_at_pos
    xor edx, edx
    mov r8d, MAP_W
    div r8d
    mov r12d, edx                       ; x
    xor edx, edx
    mov r8d, MAP_H
    div r8d
    mov r13d, eax                       ; f
    mov r14d, edx                       ; y
    cvtsi2sd xmm0, ebx
    mov rax, __float64__(60.0)
    movq xmm2, rax
    divsd xmm0, xmm2
    cvtss2sd xmm1, [t_dist]
    lea rdi, [st_t_fmt]
    mov esi, r13d
    mov edx, r12d
    mov ecx, r14d
    mov r8d, [t_state]
    mov eax, 2
    call printf
    EPILOGUE

; =============================================================================
; main
; =============================================================================
main:
    PROLOGUE 32
    mov [rsp+0], edi                    ; argc
    mov [rsp+8], rsi                    ; argv
    ; --shot?
    cmp edi, 2
    jl .normal
    mov rax, [rsi+8]
    mov rax, [rax]
    ; "--shot" (shot_mode 1) or "--selftest" (shot_mode 2)?
    cmp ax, 0x2d2d                      ; starts with "--"
    jne .normal
    mov dword [shot_mode], 1
    shr rax, 24
    cmp al, 'h'                         ; "--sh..." -> --shot, "--se..." -> --selftest
    je .sdl
    mov dword [shot_mode], 2
    jmp .sdl
.normal:
    call terminal_intro
    test eax, eax
    jz .quit_now
.sdl:
    call choose_mouse_mode
    mov edi, SDL_INIT_VIDEO | SDL_INIT_AUDIO
    call SDL_Init
    test eax, eax
    jz .sdl_ok
    call SDL_GetError
    lea rdi, [err_sdl]
    mov rsi, rax
    xor eax, eax
    call printf
    jmp .quit_now
.sdl_ok:
    mov edi, 2                          ; IMG_INIT_PNG | IMG_INIT_JPG
    mov edi, 1
    call IMG_Init
    mov edi, SDL_GL_DOUBLEBUFFER
    mov esi, 1
    call SDL_GL_SetAttribute
    mov edi, SDL_GL_DEPTH_SIZE
    mov esi, 24
    call SDL_GL_SetAttribute
    call request_msaa
    lea rdi, [title]
    mov esi, SDL_WINDOWPOS_CENTERED
    mov edx, SDL_WINDOWPOS_CENTERED
    mov ecx, 1280
    mov r8d, 720
    mov r9d, SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE
    call SDL_CreateWindow
    test rax, rax
    jnz .win_ok
    ; no multisampling available? try again without it
    mov edi, SDL_GL_MULTISAMPLEBUFFERS
    xor esi, esi
    call SDL_GL_SetAttribute
    mov edi, SDL_GL_MULTISAMPLESAMPLES
    xor esi, esi
    call SDL_GL_SetAttribute
    lea rdi, [title]
    mov esi, SDL_WINDOWPOS_CENTERED
    mov edx, SDL_WINDOWPOS_CENTERED
    mov ecx, 1280
    mov r8d, 720
    mov r9d, SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE
    call SDL_CreateWindow
    test rax, rax
    jnz .win_ok
    call SDL_GetError
    lea rdi, [err_sdl]
    mov rsi, rax
    xor eax, eax
    call printf
    jmp .quit_now
.win_ok:
    mov [window], rax
    mov rdi, rax
    call SDL_GL_CreateContext
    mov [glctx], rax
    mov edi, 1
    call SDL_GL_SetSwapInterval
    mov dword [win_w], 1280
    mov dword [win_h], 720
    call SDL_GetPerformanceFrequency
    mov [perf_freq], rax

    call world_init
    call render_init
    call hud_init
    call audio_init

    cmp dword [shot_mode], 0
    je .play
    cmp dword [shot_mode], 2
    je .selftest
    call shot_mode_run
    jmp .shutdown
.selftest:
    call selftest
    jmp .shutdown
.play:
    call play_round
    cmp eax, GS_QUIT
    je .shutdown
    mov edi, eax
    call end_screen
.again:
    lea rdi, [again_q]
    xor eax, eax
    call printf
    xor edi, edi                        ; fflush(NULL): every stream
    call fflush
    mov dword [input_val], 0
    lea rdi, [int_format]
    lea rsi, [input_val]
    xor eax, eax
    call scanf
    cmp eax, 1
    jne .shutdown
    mov eax, [input_val]
    cmp eax, 1
    je .restart
    cmp eax, 2
    jne .shutdown
    call ask_seed
.restart:
    mov rdi, [window]
    call SDL_ShowWindow
    mov rdi, [window]
    call SDL_RaiseWindow
    jmp .play
.shutdown:
    lea rdi, [bye]
    xor eax, eax
    call printf
    call SDL_Quit
.quit_now:
    xor eax, eax
    EPILOGUE
