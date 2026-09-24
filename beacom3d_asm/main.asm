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
global on_t_spotted, have_map, have_compass, have_portal, invert_y, show_fps

extern sign_count, glDeleteLists, t_speed_bonus, keys_down, p_crouch, p_step_event
extern traverse_reset, traverse_update, traverse_try_grab, trav_prompt, p_mode
extern p_on_ground
extern portal_reset, portal_fire, portal_check_teleport, world_select, render_rebuild_world
extern add_box, snd_fanfare, map_floor, dump_shadow_map, glFinish, p_eye_y, getenv, SDL_SetHint, hud_fps, render_cycle_scale, render_toggle_shadows


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
st_n_lad1   db "climb ladder ground->2nd (office 201)",0
st_n_lad2   db "climb ladder basement->ground (gym)",0
st_n_ramp_a db "atrium: up ramp A onto the bridge (y 4.8)",0
st_n_ramp_b db "atrium: bridge + ramp B -> 2nd floor",0
st_n_drop   db "atrium: walk off the balcony -> basement",0
st_zip2_fmt db "[selftest] atrium zipline: grabbed=%d, ended on floor %d at x=%.1f y=%.2f (expect floor 1, x~63)",10,0
st_los_fmt  db "[selftest] 3D sight from the basement: up the atrium=%d (expect 1), through a solid floor=%d (expect 0)",10,0
st_snd_fmt  db "[selftest] sound occlusion over 2 storeys: open atrium=%.1f (expect 0), two slabs=%.1f (expect 12)",10,0
st_nav_up   db "[selftest] nav ground balcony -> 2nd floor via ramps: found=%d, %d nodes (expect <= 10)",10,0
st_nav_drop db "[selftest] nav 2nd floor -> basement off the ledge: found=%d, %d nodes (expect <= 5)",10,0
st_bridge_ok db "[selftest] T came up the ramps and caught you on the bridge after %.1fs (T at y=%.2f) -- PASS",10,0
st_bridge_fail db "[selftest] T never reached you on the bridge -- FAIL",10,0
st_gen_fmt  db "[selftest] generated Beacom, seed %2d: %4d open cells, %2d stair cells, %d/40 random spots unreachable (expect 0)",10,0
st_pk_desk  db "parkour: walk into a desk (blocked, z~15.7)",0
st_pk_mantle db "parkour: mantle onto the desk (y~7.17)",0
st_pk_vault db "parkour: sprint-vault the desk (z<14.6)",0
st_pk_slide db "[selftest] parkour: a slide covered %.2f m in 0.85 s (crouch-walking: 1.45 m)",10,0
st_pk_crates db "parkour: up the crates in the pit (y~1.9)",0
st_pk_balcony db "parkour: mantle onto the balcony (y 3.2)",0
st_pk_box   db "parkour: stand on a cardboard box (y~3.7)",0
st_layout_fmt db "[selftest] ---- generated layout: %s ----",10,0
lay_n0      db "MAZE",0
lay_n1      db "CLASSIC",0
lay_n2      db "OPEN",0
align 8
layout_names dq lay_n0, lay_n1, lay_n2
st_real_reach db "[selftest] real Beacom: %d open cells, %d that T cannot reach from the entry (expect 0)",10,0
st_real_grand db "real Beacom: up the grand staircase (fl 2)",0
st_real_back db "real Beacom: up the back stair (fl 2)",0
st_real_down db "real Beacom: down to the sub-level (fl 0)",0
st_real_ladder db "real Beacom: ladder up into room 117",0
st_real_zip db "[selftest] real Beacom zipline: grabbed=%d, landed at y=%.2f z=%.1f (expect the stage: y 4.8, z 42..44)",10,0
st_real_glass db "[selftest] real Beacom: T sees into the server room through glass=%d (expect 1), through a solid wall=%d (expect 0)",10,0
st_real_hunt db "[selftest] real Beacom: T came up from the sub-level and caught you in room 213 after %.1fs -- PASS",10,0
st_real_lost db "[selftest] real Beacom: T never reached you in room 213 -- FAIL",10,0
st_ach_fmt  db "[selftest] achievements, clean win: PACIFIST=%d GHOST=%d SPEEDRUN=%d (expect 1 1 0); after a deauth and being seen: PACIFIST=%d FULL CAPTURE=%d (expect 0 1)",10,0
st_ach_fmt2 db "[selftest] achievements: KING OF THE CRATES on the tall crate stack=%d (expect 1)",10,0
st_row_fmt  db "%.59s",10,0
env_gensweep db "BEACOM_GENSWEEP",0
st_sweep_fmt db "[selftest] seed sweep 1..%d: seeds missing a stairwell %d, storeys without open floor %d, seeds with unreachable spots %d (%d cells)",10,0
st_sweep_fmt3 db "[selftest] T's spawn, generated buildings: never closer than %d steps from you, never under %d%% of the longest walk (expect >= 55)",10,0
st_sweep_fmt4 db "[selftest] T's spawn, the real Beacom, seeds 1..2000: never closer than %d steps, never under %d%% of the longest walk (expect >= 55)",10,0
st_sweep_fmt2 db "[selftest] seed sweep: duplicate layouts %d, open cells per building %d..%d",10,0
env_gendump db "BEACOM_GENDUMP",0
st_zip_fmt  db "[selftest] zipline: grabbed=%d, ended on floor %d at x=%.1f y=%.2f (cable ends x=111)",10,0
st_path_fmt db "[selftest] path basement(3,3) -> 2nd floor(5,3): found=%d, %d cells",10,0
st_t_fmt    db "[selftest] t=%5.1fs  T on floor %d at (%d,%d)  state=%d  dist=%.1f",10,0
st_caught   db "[selftest] T reached the player after %.1f simulated seconds -- PASS",10,0
st_notcaught db "[selftest] T did not reach the player -- FAIL",10,0
st_fps_fmt  db "[selftest] render benchmark: %.1f frames per second at %dx%d",10,0
st_rag_fmt  db "[selftest] ragdoll after 2s: head y=%.2f pelvis y=%.2f (floor is 3.20)",10,0
st_safe_fmt db "[selftest] player hiding in the 2nd-floor safe room: caught=%d after 60s (expect 0)",10,0
%ifdef WIN64
mkdir_shots db "if not exist shots mkdir shots",0
%else
mkdir_shots db "mkdir -p shots",0
%endif

; ---- in-game messages (strings carried over from the originals) ----
m_seed      db "Seed %d. Find 3 wireshark packet captures -- one on every floor -- and bring them to B.",0
m_generated db "This is not the Beacom you know. Seed %d built it tonight -- the atrium, the server room and B's library are the only places that stayed put. (Esc -> Generated layout: maze / classic / open.)",0
m_controls  db "ESC: menu + CUSTOM RUN settings - WASD move - mouse or arrow keys look - SHIFT sprint - C crouch (sprint+C slide) - SPACE jump / mantle / vault - F flashlight - E grab - Q deauth - M map - I invert mouse - F3 fps - F4 render scale - F5 shadows",0
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
m_got_map   db "You got the MAP! Press M to see every floor -- [ and ] page through them.",0
m_got_compass db "You got the COMPASS! The map now shows the captures, B... and where T is.",0
m_got_portal db "You got the PORTAL GUN! Left click: blue portal, right click: orange portal.",0
m_got_key   db "Packet capture acquired (%d/3). Bring them to B.",0
m_all_keys  db "That's all three. Get back to B in the library -- ground floor.",0
m_see_b     db "Lord of networking: 'Pull up wireshark and get a capture going! This Beacom building is very dangerous! Mr. T lurks the halls. Mr. Y has gone missing -- you must find 3 wireshark packet captures before it is too late. If you are ever scared, I have used my networking magic to secure some rooms. T cannot enter them! Good luck on your quest!'",0
m_have      db "You have %d/3 captures.",0
m_safe_in   db "You feel a comforting aura here. T cannot follow you inside.",0
m_safe_out  db "You step back out into the dark...",0
m_weapon    db "You grabbed a deauth packet! Press Q to fire it and scramble T's tracking.",0
m_fired     db "*** DEAUTH PACKET FIRED -- T's connection drops! ***",0
m_no_weapon db "You have no deauth packets.",0
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
sh_n10 db "shots/11_ragdoll_props.bmp",0
sh_n11 db "shots/12_atrium_down.bmp",0
sh_n12 db "shots/13_atrium_up.bmp",0
sh_menu db "shots/14_pause_menu.bmp",0
sh_n13 db "shots/13b_crates_in_the_pit.bmp",0
sh_maze_map db "shots/22_maze_layout_map.bmp",0
sh_open_map db "shots/23_open_layout_map.bmp",0
sh_maze_view db "shots/24_maze_layout_view.bmp",0
sh_gen_map db "shots/15_generated_map_ground.bmp",0
sh_gen_map0 db "shots/16_generated_map_basement.bmp",0
sh_gen_map2 db "shots/17_generated_map_2nd.bmp",0
sh_gen_view db "shots/18_generated_hallway.bmp",0
sh_menu_ach db "shots/14b_pause_menu_achievements.bmp",0
sh_ach_toast db "shots/35_achievement_unlocked.bmp",0
sh_r0 db "shots/30_beacom_entry_media_wall.bmp",0
sh_r1 db "shots/31_beacom_balcony_over_collab.bmp",0
sh_r2 db "shots/32_beacom_grand_staircase.bmp",0
sh_r3 db "shots/33_beacom_server_room.bmp",0
sh_r4 db "shots/34_beacom_sublevel.bmp",0
align 8
real_shots:   ; storey, x, y, yaw, pitch, file
    dd 1, 22, 15, __float32__(-1.5708), __float32__(0.08)
    dq sh_r0
    dd 2, 24, 8, __float32__(2.8), __float32__(-0.38)
    dq sh_r1
    dd 1, 28, 17, __float32__(3.1416), __float32__(0.18)
    dq sh_r2
    dd 2, 30, 7, __float32__(0.0), __float32__(-0.05)
    dq sh_r3
    dd 0, 30, 24, __float32__(-1.5708), __float32__(0.0)
    dq sh_r4
%define NREAL_SHOTS 5
sh_hands_gun db "shots/19_hands_torch_gun.bmp",0
sh_hands_zip db "shots/20_hands_zipline.bmp",0
sh_hands_ladder db "shots/21_hands_ladder.bmp",0
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
    SHOT 1, 30, 15, -1.5708, -0.25, 2, 0, sh_n10
    SHOT 2, 36, 21,  1.5708, -0.95, 0, 0, sh_n11
    SHOT 0, 34, 16,  3.1416,  0.9,  0, 0, sh_n12
    SHOT 0, 34, 22,  -0.35,   0.25, 0, 0, sh_n13
%define NSHOTS 14
%define SHOT_SIZE 36

c_dt_shot   dd 0.016
c_reach     dd 1.9
c_b_reach   dd 2.6
c_see_dist  dd 7.0
c_tyler_d   dd 2.4
c_jockey_d  dd 0.9
c_cage_d    dd 5.0
c_max_dt    dd 0.05
step_noise_amt dd 0.0, 0.03, 0.10, 0.26, 0.12
c_noise_deauth dd 0.5
c_noise_click  dd 0.04
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
%define MAX_SWEEP 20000
sweep_hash  resd MAX_SWEEP
sw_min_pct  resd 1
gt_layout   resd 1
sw_min_steps resd 1
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
have_map    resd 1
have_compass resd 1
have_portal resd 1
mouse_edge_mode resd 1
show_fps    resd 1
fps_frames  resd 1
fps_time    resd 1
crouch_latch resd 1
restart_new resd 1                  ; the menu asked for a new seed
built_mode  resd 1                  ; which building is in grid (BLD_...), -1 none yet
built_seed  resd 1                  ; ...and from which seed
built_layout resd 1                 ; ...with which layout

section .text

; msg(rdi=text, esi=colour) / lore(rdi=text)
msg:
    xor edx, edx
    jmp hud_message
lore:
    mov esi, COL_LORE
    mov edx, 1
    jmp hud_message

; atoi_simple(rdi = digits) -> eax. leaf
atoi_simple:
    xor eax, eax
.d:
    movzx ecx, byte [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja .done
    imul eax, eax, 10
    add eax, ecx
    inc rdi
    jmp .d
.done:
    ret

; dist_to_player(xmm0..2 = a point on some floor) -> xmm0 = straight-line
; distance from your feet. leaf.
dist_to_player:
    movss xmm3, [p_x]
    movss xmm4, [p_y]
    movss xmm5, [p_z]
    jmp dist3

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
    sub eax, [start_x]
    mov ecx, eax
    neg ecx
    cmovl ecx, eax
    mov eax, r14d
    sub eax, [start_y]
    mov edx, eax
    neg edx
    cmovl edx, eax
    add ecx, edx
    mov eax, ebx
    sub eax, [start_f]
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
    call noise_reset
    call traverse_reset
    call portal_reset
    call ach_new_run
    mov dword [crouch_latch], 0
    xor edi, edi
    call snd_mute                       ; (volume setting)
    xor eax, eax
    mov [have_map], eax
    mov [have_compass], eax
    mov [have_portal], eax
    mov edi, [start_f]                  ; (each building has its own start)
    mov esi, [start_x]
    mov edx, [start_y]
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
    ; the Zelda map and compass, somewhere in the building
    mov edi, -1
    xor esi, esi
    xor edx, edx
    call random_cell
    mov esi, eax
    mov edi, IT_MAP
    call add_item
    mov edi, -1
    xor esi, esi
    xor edx, edx
    call random_cell
    mov esi, eax
    mov edi, IT_COMPASS
    call add_item
    ; ...and the portal gun (custom run: hidden / in your hands / none)
    cmp dword [cfg_portal], 1
    jne .portal_hidden
    mov dword [have_portal], 1
.portal_hidden:
    cmp dword [cfg_portal], 0
    jne .portal_done
    mov edi, -1
    xor esi, esi
    xor edx, edx
    call random_cell
    mov esi, eax
    mov edi, IT_PORTAL
    call add_item
.portal_done:
    cmp dword [cfg_start_map], 0
    je .map_hidden
    mov dword [have_map], 1
    mov dword [have_compass], 1
.map_hidden:
    ; deauth packets anywhere (3 unless the custom run says otherwise)
    mov ebx, [cfg_deauths]
    test ebx, ebx
    jz .weap_done
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
.weap_done:
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

    ; boxes and wet-floor signs to knock over
    call physics_reset
    call physics_spawn_props

    ; T starts on the far side of the building from you (whatever the seed:
    ; at least 55% of the longest walk away -- see far_spawn_node)
    call start_node
    mov edi, eax
    call far_spawn_node
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
    cmp dword [cfg_building], BLD_GENERATED
    jne .real_beacom
    lea rdi, [msg_buf]
    mov esi, 512
    lea rdx, [m_generated]
    mov ecx, [seed_val]
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    call lore
.real_beacom:
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
    movss xmm0, [r13+ITEM_X]            ; true 3D distance: an item on the
    movss xmm1, [r13+ITEM_Y]            ; floor above/below is out of reach,
    movss xmm2, [r13+ITEM_Z]            ; one on a ramp beside you isn't
    call dist_to_player
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
    movss xmm0, [b_pos_x]
    movss xmm1, [b_pos_y]
    movss xmm2, [b_pos_z]
    call dist_to_player
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
    mov edi, ACH_PACKET
    call ach_unlock
    inc dword [inventory]
    ; T gets angrier with every capture (unless the custom run says no)
    cmp dword [cfg_t_angry], 0
    je .not_angry
    cvtsi2ss xmm0, dword [inventory]
    mulss xmm0, [c_bonus]
    movss [t_speed_bonus], xmm0
.not_angry:
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
    cmp dword [rbx+ITEM_KIND], IT_WEAPON
    jne .zelda
    inc dword [deauths]
    lea rdi, [m_weapon]
    mov esi, COL_GOOD
    call msg
    jmp .done
.zelda:
    ; the dungeon items get a fanfare
    call snd_fanfare
    mov eax, [rbx+ITEM_KIND]
    cmp eax, IT_MAP
    jne .not_map
    mov dword [have_map], 1
    lea rdi, [m_got_map]
    mov esi, COL_GOOD
    call msg
    jmp .done
.not_map:
    cmp eax, IT_COMPASS
    jne .not_compass
    mov dword [have_compass], 1
    lea rdi, [m_got_compass]
    mov esi, COL_GOOD
    call msg
    jmp .done
.not_compass:
    cmp eax, IT_PORTAL
    jne .done
    mov dword [have_portal], 1
    lea rdi, [m_got_portal]
    mov esi, COL_GOOD
    call msg
    jmp .done
.try_b:
    call traverse_try_grab              ; a zipline overhead?
    test eax, eax
    jnz .done
    call near_b
    test eax, eax
    jz .done
    cmp dword [inventory], 3
    jl .talk
    mov dword [game_state], GS_WON
    call ach_won
    jmp .done
.talk:
    mov edi, ACH_NETWORKING
    call ach_unlock
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
    inc dword [run_deauths]             ; (no PACIFIST this run)
    movss xmm0, [t_dist]
    FLD xmm1, 4.0
    comiss xmm0, xmm1
    jae .not_close
    movss xmm0, [t_stun]
    comiss xmm0, [c_zero]
    ja .not_close
    mov edi, ACH_POINT_BLANK
    call ach_unlock
.not_close:
    call snd_deauth
    movss xmm0, [c_noise_deauth]        ; the zap is loud
    call noise_add
    lea rdi, [m_fired]
    mov esi, COL_GOOD
    call msg
    mov eax, [c_one]
    mov [hud_flash], eax
    ; close enough to see it? T collapses as a ragdoll first (physics.asm),
    ; and only vanishes when that ends
    cmp dword [rag_active], 0
    jne .teleport
    movss xmm0, [t_stun]
    comiss xmm0, [c_zero]
    ja .teleport
    movss xmm0, [t_dist]
    FLD xmm1, 30.0
    comiss xmm0, xmm1
    jae .teleport
    ; push him away from you
    movss xmm3, [t_x]
    subss xmm3, [p_x]
    movss xmm4, [t_z]
    subss xmm4, [p_z]
    movaps xmm0, xmm3
    mulss xmm0, xmm3
    movaps xmm1, xmm4
    mulss xmm1, xmm4
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    FLD xmm1, 0.01
    maxss xmm0, xmm1
    divss xmm3, xmm0
    divss xmm4, xmm0
    movss [rsp+0], xmm3
    movss [rsp+4], xmm4
    ; he faces you as he falls
    movss xmm0, [p_x]
    subss xmm0, [t_x]
    movss xmm1, [p_z]
    subss xmm1, [t_z]
    call atan2f
    movaps xmm5, xmm0
    movss xmm0, [t_x]
    movss xmm1, [t_y]
    movss xmm2, [t_z]
    movss xmm3, [rsp+0]
    movss xmm4, [rsp+4]
    call physics_ragdoll
    ; frozen until the ragdoll is done
    movss xmm0, [rag_time]
    FLD xmm1, 0.5
    addss xmm0, xmm1
    movss [t_stun], xmm0
    EPILOGUE
.teleport:
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
    inc dword [run_spotted]             ; (no GHOST PROTOCOL this run)
    call snd_spotted
    lea rdi, [m_spotted]
    mov esi, COL_DANGER
    call msg
    EPILOGUE

; menu_action(edi = -1 nothing, 0 resume, 1 restart, 2 new seed, 3 quit)
menu_action:
    PROLOGUE 16
    cmp edi, 0
    jl .done
    jne .not_resume
    xor edi, edi
    call set_paused
    jmp .done
.not_resume:
    cmp edi, 3
    jne .restart
    call settings_save
    mov dword [game_state], GS_QUIT
    jmp .done
.restart:
    xor eax, eax
    cmp edi, 2
    sete al
    mov [restart_new], eax
    mov dword [game_state], GS_RESTART
.done:
    EPILOGUE

; prepare_world -- the building this run needs: the real Beacom, or one
; generated from the seed (rebuilt only when that changes)
prepare_world:
    PROLOGUE 16
    mov eax, [cfg_building]
    cmp eax, [built_mode]
    jne .build
    test eax, eax
    jz .apply
    mov ecx, [seed_val]
    cmp ecx, [built_seed]
    jne .build
    mov ecx, [cfg_layout]
    cmp ecx, [built_layout]
    je .apply
.build:
    mov edi, [cfg_building]
    mov esi, [seed_val]
    call world_select
    call render_rebuild_world
    mov eax, [cfg_building]
    mov [built_mode], eax
    mov eax, [seed_val]
    mov [built_seed], eax
    mov eax, [cfg_layout]
    mov [built_layout], eax
.apply:
    call settings_apply                 ; (after build_nav, which resets T's links)
    EPILOGUE

; set_paused(edi=1/0)
set_paused:
    PROLOGUE 16
    mov ebx, edi
    test ebx, ebx
    jz .closing
    call menu_reset
    jmp .state
.closing:
    call settings_save
.state:
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
    cmp dword [game_state], GS_PAUSED
    jne .motion_play
    mov edi, [event+20]                 ; the menu follows the cursor
    mov esi, [event+24]
    call menu_mouse
    jmp .poll
.motion_play:
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
    mov edi, ecx
    mov esi, [event+20]
    mov edx, [event+24]
    call menu_click
    mov edi, eax
    call menu_action
    jmp .poll
.btn_play:
    cmp dword [game_state], GS_PLAYING
    jne .poll
    ; with the portal gun: left = blue, right = orange; otherwise right = deauth
    cmp dword [have_portal], 0
    je .btn_deauth
    cmp ecx, 1
    jne .btn_orange
    xor edi, edi
    call portal_fire
    jmp .poll
.btn_orange:
    cmp ecx, 3
    jne .poll
    mov edi, 1
    call portal_fire
    jmp .poll
.btn_deauth:
    cmp ecx, 3
    jne .poll
    call fire_deauth
    jmp .poll
.not_button:
    cmp eax, SDL_MOUSEWHEEL
    jne .not_wheel
    cmp dword [game_state], GS_PAUSED
    jne .poll
    mov edi, [event+20]
    call menu_wheel
    jmp .poll
.not_wheel:
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
    cmp dword [game_state], GS_PAUSED
    jne .key_play
    mov edi, ecx
    call menu_key
    mov edi, eax
    call menu_action
    jmp .poll
.key_play:
    cmp dword [game_state], GS_PLAYING
    jne .poll
    ; crouch in toggle mode: each press flips it
    cmp ecx, SC_C
    je .crouch_key
    cmp ecx, SC_LCTRL
    jne .not_crouch_key
.crouch_key:
    xor dword [crouch_latch], 1
    jmp .poll
.not_crouch_key:
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
    movss xmm0, [c_noise_click]
    call noise_add
    jmp .poll
.flash_off:
    mov dword [p_flash_on], 0
    xor edi, edi
    call snd_footstep
    movss xmm0, [c_noise_click]
    call noise_add
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
    jne .k8
.map:
    xor dword [map_visible], 1
    call player_floor
    mov [map_floor], eax                ; the map opens on your floor
    jmp .poll
.k8:
    ; [ / ] : page the map through the floors (needs the MAP)
    cmp dword [map_visible], 0
    je .poll
    cmp dword [have_map], 0
    je .poll
    mov eax, [map_floor]
    cmp ecx, SC_LBRACKET
    jne .page_up
    dec eax
    jmp .page
.page_up:
    cmp ecx, SC_RBRACKET
    jne .poll
    inc eax
.page:
    cmp eax, 0
    jl .poll
    cmp eax, NF
    jge .poll
    mov [map_floor], eax
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
    cmp dword [cfg_crouch_toggle], 0
    je .crouch_hold
    mov eax, [crouch_latch]
.crouch_hold:
    mov [keys_down+K_CROUCH], al
    mov al, [rbx+SC_SPACE]
    mov [keys_down+K_JUMP], al
    EPILOGUE

; =============================================================================
; per-frame game logic
; =============================================================================

; footsteps feed the noise meter (noise.asm): how loud depends on the step
; step_noise_amt[event]: 1 crouch step, 2 walk step, 3 sprint step / hard
; landing, 4 jump
step_noise:
    PROLOGUE 16
    mov eax, [p_step_event]
    test eax, eax
    jz .done
    cmp eax, 4
    ja .done
    movss xmm0, [step_noise_amt+rax*4]
    call noise_add
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
    movss xmm0, [r12+ITEM_X]
    movss xmm1, [r12+ITEM_Y]
    movss xmm2, [r12+ITEM_Z]
    call dist_to_player
    mov eax, [r12+ITEM_KIND]
    cmp eax, IT_KEY
    jne .tyler
    cmp dword [r12+ITEM_SEEN], 0
    jne .n
    comiss xmm0, [c_see_dist]
    jae .n
    ; you notice it only if you can actually see it (down the atrium counts)
    movss xmm0, [p_x]
    movss xmm1, [p_eye_y]
    movss xmm2, [p_z]
    movss xmm3, [r12+ITEM_X]
    movss xmm4, [r12+ITEM_Y]
    addss xmm4, [c_half]
    movss xmm5, [r12+ITEM_Z]
    call line_of_sight_3d
    test eax, eax
    jz .n
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
    mov edi, ACH_TYLER
    call ach_unlock
    lea rdi, [m_tyler]
    mov esi, COL_DANGER
    call msg
    jmp .n
.jockey:
    cmp eax, IT_JOCKEY
    jne .n
    comiss xmm0, [c_jockey_d]
    jae .n
    mov edi, ACH_JOCKEY
    call ach_unlock
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
    cmp dword [cfg_heart], 0
    je .no_heart
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
    mov eax, [trav_prompt]              ; ladder / zipline (items win below)
    mov [hud_prompt], eax
    movss xmm0, [c_reach]
    xor edi, edi
    call nearest_item
    test rax, rax
    jz .b
    cmp dword [p_mode], 0
    jne .done
    mov ecx, [rax+ITEM_KIND]
    mov [hud_prompt], ecx               ; pickups: the prompt index is the kind
    EPILOGUE
.b:
    cmp dword [p_mode], 0
    jne .done
    call near_b
    test eax, eax
    jz .done
    mov dword [hud_prompt], 5
    cmp dword [inventory], 3
    jl .done
    mov dword [hud_prompt], 6
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
    call traverse_update
    movss xmm0, [rsp+0]
    movss xmm1, [elapsed_time]
    call player_update
    movss xmm0, [rsp+0]
    call portal_check_teleport
    call step_noise
    movss xmm0, [rsp+0]
    call noise_update
    movss xmm0, [rsp+0]
    call physics_update
    movss xmm0, [rsp+0]
    call enemy_update
    movss xmm0, [rsp+0]
    movss xmm1, [elapsed_time]
    call world_lights_update
    call update_items

    ; Y's cage
    cmp dword [cage_hint], 0
    jne .no_cage
    movss xmm0, [y_pos_x]
    xorps xmm1, xmm1                    ; the cage stands on the basement floor
    movss xmm2, [y_pos_z]
    call dist_to_player
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
    call ach_tick
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
    call prepare_world
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
    cmp eax, GS_RESTART
    je .restart
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
.restart:
    ; from the pause menu: same seed, or a fresh one
    cmp dword [restart_new], 0
    je .same_seed
    xor edi, edi
    call time
    imul eax, eax, 1103515245           ; (so quick restarts still differ)
    add eax, [perf_last]
    and eax, 0x7fffffff
    mov [seed_val], eax
.same_seed:
    call prepare_world
    call new_game
    xor edi, edi
    call set_paused
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
    call ach_print_run
    EPILOGUE

; =============================================================================
; --shot: render test screenshots from fixed spots, then exit
; =============================================================================
shot_mode_run:
    PROLOGUE 32
    lea rdi, [mkdir_shots]
    call system
    mov dword [seed_val], 42
    mov dword [cfg_building], BLD_ORIGINAL
    call prepare_world
    call new_game
    mov dword [have_map], 1             ; show off the MAP + COMPASS in the shots
    mov dword [have_compass], 1
    mov dword [map_floor], 1
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
    cmp dword [r13+20], 2
    je .ragdoll_shot
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
    jmp .no_t
.ragdoll_shot:
    ; T collapses 3.5m ahead, next to a box and a wet-floor sign; let it fall
    call physics_reset
    movss xmm0, [p_x]
    FLD xmm1, 3.5
    addss xmm0, xmm1
    movss xmm1, [p_y]
    movss xmm2, [p_z]
    FLD xmm3, 1.0
    xorps xmm4, xmm4
    FLD xmm5, -1.5708
    call physics_ragdoll
    mov edi, 0
    movss xmm0, [p_x]
    FLD xmm1, 2.5
    addss xmm0, xmm1
    movss xmm1, [p_y]
    movss xmm2, [p_z]
    FLD xmm3, 1.3
    subss xmm2, xmm3
    FLD xmm3, 0.4
    call add_box
    mov edi, 1
    movss xmm0, [p_x]
    FLD xmm1, 2.2
    addss xmm0, xmm1
    movss xmm1, [p_y]
    movss xmm2, [p_z]
    FLD xmm3, 1.1
    addss xmm2, xmm3
    FLD xmm3, 1.5708
    call add_box
    mov ebx, 50
.fall:
    movss xmm0, [c_dt_shot]
    call physics_update
    dec ebx
    jnz .fall
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
    ; and the pause menu over the last view
    mov dword [hud_paused], 1
    call menu_reset
    mov ebx, 2
.menu_frames:                           ; (twice: the menu makes its textures lazily)
    mov edi, [win_w]
    mov esi, [win_h]
    movss xmm0, [elapsed_time]
    call render_frame
    mov edi, [win_w]
    mov esi, [win_h]
    movss xmm0, [c_dt_shot]
    movss xmm1, [elapsed_time]
    call hud_draw
    dec ebx
    jnz .menu_frames
    lea rdi, [sh_menu]
    mov esi, [win_w]
    mov edx, [win_h]
    call save_screenshot
    ; the achievements at the bottom of the menu (a few unlocked for show)
    mov dword [ach_flag+ACH_PACKET*4], 1
    mov dword [ach_flag+ACH_PACIFIST*4], 1
    mov dword [ach_flag+ACH_ZIPLINE*4], 1
    mov ebx, 60
.to_bottom:
    mov edi, SC_DOWN
    call menu_key
    dec ebx
    jnz .to_bottom
    lea rdi, [sh_menu_ach]
    call shot_now
    lea rdi, [ach_flag]
    xor esi, esi
    mov edx, NACH*4
    call memset
    ; a building generated from seed 42: its map, then the view from the start
    mov dword [hud_paused], 0
    mov dword [cfg_building], 1
    call prepare_world
    call new_game
    mov dword [have_map], 1
    mov dword [have_compass], 1
    mov dword [map_visible], 1
    mov dword [map_floor], 1
    lea rdi, [sh_gen_map]
    call shot_now
    mov dword [map_floor], 0
    lea rdi, [sh_gen_map0]
    call shot_now
    mov dword [map_floor], 2
    lea rdi, [sh_gen_map2]
    call shot_now
    mov dword [map_visible], 0
    mov edi, 1
    mov esi, 3
    mov edx, 15
    call player_spawn
    mov dword [p_yaw], __float32__(-1.5708)
    lea rdi, [sh_gen_view]
    call shot_now
    ; the maze and open layouts (seed 42): their maps, and inside the maze
    mov dword [cfg_layout], 0
    call prepare_world
    call new_game
    mov dword [have_map], 1
    mov dword [map_visible], 1
    mov dword [map_floor], 1
    lea rdi, [sh_maze_map]
    call shot_now
    mov dword [map_visible], 0
    call find_maze_spot
    lea rdi, [sh_maze_view]
    call shot_now
    mov dword [cfg_layout], 2
    call prepare_world
    call new_game
    mov dword [have_map], 1
    mov dword [map_visible], 1
    mov dword [map_floor], 1
    lea rdi, [sh_open_map]
    call shot_now
    mov dword [map_visible], 0
    mov dword [cfg_layout], 1
    ; the hands in every pose, in the original map's main hallway
    mov dword [cfg_building], BLD_ORIGINAL
    call prepare_world
    call new_game
    call hud_clear_messages
    mov edi, 1
    mov esi, 8
    mov edx, 15
    call player_spawn
    mov dword [p_yaw], __float32__(-1.5708)
    mov dword [p_pitch], __float32__(-0.12)
    mov dword [have_portal], 1
    lea rdi, [sh_hands_gun]
    call shot_now
    mov dword [have_portal], 0
    mov dword [p_mode], 2
    mov dword [p_pitch], __float32__(0.25)
    lea rdi, [sh_hands_zip]
    call shot_now
    mov dword [p_mode], 1
    mov dword [p_pitch], __float32__(0.0)
    lea rdi, [sh_hands_ladder]
    call shot_now
    mov dword [p_mode], 0
    ; the real Beacom Institute of Technology
    mov dword [cfg_building], BLD_REAL
    call prepare_world
    call new_game
    call hud_clear_messages
    xor ebx, ebx
.real_shot:
    cmp ebx, NREAL_SHOTS
    jge .real_done
    imul eax, ebx, 28
    lea r13, [real_shots+rax]
    mov edi, [r13+0]
    mov esi, [r13+4]
    mov edx, [r13+8]
    call player_spawn
    mov eax, [r13+12]
    mov [p_yaw], eax
    mov eax, [r13+16]
    mov [p_pitch], eax
    mov rdi, [r13+20]
    push rbx
    sub rsp, 8
    call shot_now
    add rsp, 8
    pop rbx
    inc ebx
    jmp .real_shot
.real_done:
    ; an achievement popping
    call hud_clear_messages
    mov edi, ACH_STAGE
    call ach_unlock
    mov edi, 1
    mov esi, 28
    mov edx, 17
    call player_spawn
    mov dword [p_yaw], __float32__(3.1416)
    lea rdi, [sh_ach_toast]
    call shot_now
    EPILOGUE

; find_maze_spot -- stand in a one-cell passage on the ground floor (open
; left and right or ahead and behind, walls to both sides), facing along it
find_maze_spot:
    PROLOGUE 16
    mov r14d, 3
.y:
    cmp r14d, 12
    jg .none
    mov r13d, 18
.x:
    cmp r13d, 40
    jg .ny
    mov edi, 1
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, ' '
    jne .nx
    mov edi, 1
    lea esi, [r13d-1]
    mov edx, r14d
    call cell_at
    cmp eax, '#'
    jne .nx
    mov edi, 1
    lea esi, [r13d+1]
    mov edx, r14d
    call cell_at
    cmp eax, '#'
    jne .nx
    mov edi, 1
    mov esi, r13d
    lea edx, [r14d-1]
    call cell_at
    cmp eax, ' '
    jne .nx
    mov edi, 1
    mov esi, r13d
    mov edx, r14d
    call player_spawn
    mov dword [p_yaw], 0                ; looking north along it
    EPILOGUE
.nx:
    inc r13d
    jmp .x
.ny:
    inc r14d
    jmp .y
.none:
    EPILOGUE

; shot_now(rdi=file) -- settle a few frames and save what's on screen
shot_now:
    PROLOGUE 16
    mov r12, rdi
    mov ebx, 10
.settle:
    movss xmm0, [c_dt_shot]
    movss xmm1, [elapsed_time]
    call player_update
    movss xmm0, [c_dt_shot]
    movss xmm1, [elapsed_time]
    call world_lights_update
    call hud_update_explored
    dec ebx
    jnz .settle
    mov edi, [win_w]
    mov esi, [win_h]
    movss xmm0, [elapsed_time]
    call render_frame
    mov edi, [win_w]
    mov esi, [win_h]
    movss xmm0, [c_dt_shot]
    movss xmm1, [elapsed_time]
    call hud_draw
    mov rdi, r12
    mov esi, [win_w]
    mov edx, [win_h]
    call save_screenshot
    mov rdi, [window]
    call SDL_GL_SwapWindow
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
    mov rdi, [rsp+16]
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    call walk_leg
    EPILOGUE

; walk_leg(rdi=name or 0 to stay quiet, xmm0=yaw, xmm1=seconds) -- carry on
; walking from wherever you are
walk_leg:
    PROLOGUE 32
    mov [rsp+16], rdi
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    mov eax, [rsp+0]
    mov [p_yaw], eax
    mov byte [keys_down+K_FWD], 1
    movss xmm0, [rsp+4]
    FLD xmm1, 60.0
    mulss xmm0, xmm1
    cvttss2si ebx, xmm0                 ; frames at 60 fps
    cmp ebx, 1
    jge .step
    mov ebx, 1                          ; (at least one)
.step:
    movss xmm0, [c_dt_shot]
    call traverse_update
    movss xmm0, [c_dt_shot]
    movss xmm1, [elapsed_time]
    call player_update
    dec ebx
    jnz .step
    mov byte [keys_down+K_FWD], 0
    cmp qword [rsp+16], 0
    je .quiet
    call player_floor
    mov edx, eax
    lea rdi, [st_walk_fmt]
    mov rsi, [rsp+16]
    cvtss2sd xmm0, [p_x]
    cvtss2sd xmm1, [p_y]
    cvtss2sd xmm2, [p_z]
    mov eax, 3
    call printf
.quiet:
    EPILOGUE

%define NODE(f,x,y) (((f)*MAP_H + (y))*MAP_W + (x))
%define XN(i) (NCELLS + (i))
extern path_len, path

; hold_test(rdi = name or 0, esi = keys held (bit per keys_down slot),
;           xmm0 = yaw, xmm1 = seconds) -- play with those keys held down
hold_test:
    PROLOGUE 32
    mov [rsp+16], rdi
    mov [rsp+8], esi
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    mov eax, [rsp+0]
    mov [p_yaw], eax
    xor ecx, ecx
.k:
    mov eax, [rsp+8]
    shr eax, cl
    and eax, 1
    mov [keys_down+rcx], al
    inc ecx
    cmp ecx, 9
    jl .k
    movss xmm0, [rsp+4]
    FLD xmm1, 60.0
    mulss xmm0, xmm1
    cvttss2si ebx, xmm0
    cmp ebx, 1
    jge .step
    mov ebx, 1
.step:
    movss xmm0, [c_dt_shot]
    call traverse_update
    movss xmm0, [c_dt_shot]
    movss xmm1, [elapsed_time]
    call player_update
    movss xmm0, [c_dt_shot]
    call physics_update
    dec ebx
    jnz .step
    lea rdi, [keys_down]
    xor esi, esi
    mov edx, 9
    call memset
    cmp qword [rsp+16], 0
    je .quiet
    call player_floor
    mov edx, eax
    lea rdi, [st_walk_fmt]
    mov rsi, [rsp+16]
    cvtss2sd xmm0, [p_x]
    cvtss2sd xmm1, [p_y]
    cvtss2sd xmm2, [p_z]
    mov eax, 3
    call printf
.quiet:
    EPILOGUE

; settle -- a second of doing nothing (a move in progress finishes)
settle:
    PROLOGUE 16
    xor edi, edi
    xor esi, esi
    mov eax, [p_yaw]
    movd xmm0, eax
    movss xmm1, [c_one]
    call hold_test
    EPILOGUE

%define KB_FWD    1
%define KB_SPRINT 16
%define KB_CROUCH 32
%define KB_JUMP   64

; parkour_tests -- desks, mantle, vault, slide, crates, boxes
parkour_tests:
    PROLOGUE 32
    mov dword [t_stun], __float32__(10000.0)
    call traverse_reset
    ; a desk is a real obstacle now...
    lea rdi, [st_pk_desk]
    mov esi, 2
    mov edx, 23
    mov ecx, 8
    FLD xmm0, 0.0
    FLD xmm1, 1.5
    call walk_test
    ; ...you can climb onto it...
    mov edi, 2
    mov esi, 23
    mov edx, 8
    call player_spawn
    xor edi, edi
    mov esi, KB_FWD | KB_JUMP
    FLD xmm0, 0.0
    FLD xmm1, 0.9
    call hold_test
    lea rdi, [st_pk_mantle]
    xor esi, esi
    FLD xmm0, 0.0
    FLD xmm1, 0.6
    call hold_test
    ; ...or sprint and vault it
    mov edi, 2
    mov esi, 23
    mov edx, 8
    call player_spawn
    xor edi, edi
    mov esi, KB_FWD | KB_SPRINT | KB_JUMP
    FLD xmm0, 0.0
    FLD xmm1, 0.9
    call hold_test
    lea rdi, [st_pk_vault]
    xor esi, esi
    FLD xmm0, 0.0
    FLD xmm1, 0.6
    call hold_test
    ; slide: sprint, then crouch
    mov edi, 1
    mov esi, 8
    mov edx, 15
    call player_spawn
    xor edi, edi
    mov esi, KB_FWD | KB_SPRINT
    FLD xmm0, -1.5708
    FLD xmm1, 0.5
    call hold_test
    mov eax, [p_x]
    mov [rsp+0], eax
    xor edi, edi
    mov esi, KB_FWD | KB_SPRINT | KB_CROUCH
    FLD xmm0, -1.5708
    FLD xmm1, 0.85
    call hold_test
    movss xmm0, [p_x]
    subss xmm0, [rsp+0]
    cvtss2sd xmm0, xmm0
    lea rdi, [st_pk_slide]
    mov eax, 1
    call printf
    ; the pit under the atrium: crate, tall crate, then up onto the balcony
    call traverse_reset
    mov edi, 0
    mov esi, 35
    mov edx, 21
    call player_spawn
    mov ebx, 240                        ; north, grabbing whatever's there...
.climb:
    push rbx
    sub rsp, 8
    xor edi, edi
    mov esi, KB_FWD | KB_JUMP
    FLD xmm0, 0.0
    FLD xmm1, 0.0167
    call hold_test
    add rsp, 8
    pop rbx
    cmp dword [p_mode], 0
    jne .climbing
    movss xmm0, [p_y]
    FLD xmm1, 1.85
    comiss xmm0, xmm1                   ; ...until you stand on the tall one
    jae .on_top
.climbing:
    dec ebx
    jnz .climb
.on_top:
    lea rdi, [st_pk_crates]
    xor esi, esi
    FLD xmm0, 0.0
    FLD xmm1, 0.02
    call hold_test
    xor edi, edi
    mov esi, KB_FWD | KB_JUMP
    FLD xmm0, -1.5708                   ; east, to the balcony edge
    FLD xmm1, 1.3
    call hold_test
    lea rdi, [st_pk_balcony]
    xor esi, esi
    FLD xmm0, -1.5708
    FLD xmm1, 0.8
    call hold_test
    ; a cardboard box: step or climb onto it
    call physics_reset
    mov edi, 1
    mov esi, 8
    mov edx, 15
    call player_spawn
    mov dword [p_yaw], __float32__(-1.5708)
    xor edi, edi                        ; B_BOX
    movss xmm0, [p_x]
    FLD xmm1, 1.6
    addss xmm0, xmm1
    movss xmm1, [p_y]
    movss xmm2, [p_z]
    xorps xmm3, xmm3
    call add_box
    call settle
    xor edi, edi
    mov esi, KB_FWD | KB_JUMP
    FLD xmm0, -1.5708
    FLD xmm1, 0.5
    call hold_test
    lea rdi, [st_pk_box]
    xor esi, esi
    FLD xmm0, -1.5708
    FLD xmm1, 0.8
    call hold_test
    call physics_reset
    call traverse_reset
    EPILOGUE

; gen_sweep(edi = N) -- BEACOM_GENSWEEP=N: build seeds 1..N and check each one
; completely: all four stairwells placed, open floor on every storey, every
; open cell reachable from the start (one flood over T's graph), and no two
; seeds giving the same building (FNV-1a hash of the whole grid)
extern seen, stamp
gen_sweep:
    PROLOGUE 64
    ; [rsp+0] N [rsp+4] stair fails [rsp+8] unreachable seeds [rsp+12] floor
    ; fails [rsp+16] duplicates [rsp+20] min open [rsp+24] max open
    ; [rsp+28] unreachable cells total
    mov [rsp+0], edi
    xor eax, eax
    mov [rsp+4], eax
    mov [rsp+8], eax
    mov [rsp+12], eax
    mov [rsp+16], eax
    mov [rsp+24], eax
    mov [rsp+28], eax
    mov dword [rsp+20], 0x7fffffff
    mov dword [sw_min_pct], 1000
    mov dword [sw_min_steps], 0x7fffffff
    mov dword [cfg_building], 1
    mov r12d, 1
.seed:
    cmp r12d, [rsp+0]
    jg .dups
    mov edi, 1
    mov esi, r12d
    call world_select
    ; stairwells + hash
    xor r13d, r13d                      ; '^' cells
    mov r14d, 0x811C9DC5                ; FNV-1a
    xor ecx, ecx
.cell:
    cmp ecx, NCELLS
    jge .cells_done
    movzx eax, byte [grid+rcx]
    cmp eax, '^'
    jne .h
    inc r13d
.h:
    xor r14d, eax
    imul r14d, r14d, 0x01000193
    inc ecx
    jmp .cell
.cells_done:
    lea eax, [r12d-1]
    mov [sweep_hash+rax*4], r14d
    cmp r13d, 48
    je .stairs_ok
    inc dword [rsp+4]
.stairs_ok:
    mov eax, [open_count]
    cmp eax, [rsp+20]
    jge .mn
    mov [rsp+20], eax
.mn:
    cmp eax, [rsp+24]
    jle .mx
    mov [rsp+24], eax
.mx:
    ; flood everything T can reach from the start (a target that can't exist)
    mov edi, NODE(1,1,1)
    mov esi, NNODES + 1
    call find_path
    mov r15d, [stamp]
    xor r13d, r13d                      ; unreachable cells this seed
    xor ebx, ebx                        ; storeys seen (bits)
    xor ecx, ecx
.oc:
    cmp ecx, [open_count]
    jge .oc_done
    mov eax, [open_cells+rcx*4]
    cmp [seen+rax*4], r15d
    je .reached
    cmp eax, NODE(1,1,1)
    je .reached
    inc r13d
.reached:
    xor edx, edx
    mov r8d, FLOOR_CELLS
    div r8d
    bts ebx, eax
    inc ecx
    jmp .oc
.oc_done:
    test r13d, r13d
    jz .all_reached
    inc dword [rsp+8]
    add [rsp+28], r13d
.all_reached:
    cmp ebx, 7
    je .floors_ok
    inc dword [rsp+12]
.floors_ok:
    ; where would T start? (far_spawn_node floods from your start)
    mov edi, r12d
    call rng_seed
    call spawn_check
    inc r12d
    jmp .seed
.dups:
    xor r12d, r12d
.di:
    lea eax, [r12d+1]
    cmp eax, [rsp+0]
    jge .report
    mov r13d, [sweep_hash+r12*4]
    lea r14d, [r12d+1]
.dj:
    cmp r14d, [rsp+0]
    jge .dnext
    cmp r13d, [sweep_hash+r14*4]
    jne .dn
    inc dword [rsp+16]
.dn:
    inc r14d
    jmp .dj
.dnext:
    inc r12d
    jmp .di
.report:
    ; (two lines: the Windows printf thunk takes up to 6 arguments)
    lea rdi, [st_sweep_fmt]
    mov esi, [rsp+0]
    mov edx, [rsp+4]
    mov ecx, [rsp+12]
    mov r8d, [rsp+8]
    mov r9d, [rsp+28]
    xor eax, eax
    call printf
    lea rdi, [st_sweep_fmt2]
    mov esi, [rsp+16]
    mov edx, [rsp+20]
    mov ecx, [rsp+24]
    xor eax, eax
    call printf
    lea rdi, [st_sweep_fmt3]
    mov esi, [sw_min_steps]
    mov edx, [sw_min_pct]
    xor eax, eax
    call printf
    ; the real Beacom too: T's start for the first 2000 seeds
    mov dword [cfg_building], BLD_REAL
    mov edi, BLD_REAL
    xor esi, esi
    call world_select
    mov dword [sw_min_pct], 1000
    mov dword [sw_min_steps], 0x7fffffff
    mov r12d, 1
.classic:
    cmp r12d, 2000
    jg .classic_done
    mov edi, r12d
    call rng_seed
    call spawn_check
    inc r12d
    jmp .classic
.classic_done:
    lea rdi, [st_sweep_fmt4]
    mov esi, [sw_min_steps]
    mov edx, [sw_min_pct]
    xor eax, eax
    call printf
    mov dword [cfg_building], BLD_ORIGINAL
    mov edi, BLD_ORIGINAL
    xor esi, esi
    call world_select
    EPILOGUE

; real_tests -- the real Beacom Institute of Technology (maps/beacom/)
real_tests:
    PROLOGUE 32
    mov dword [cfg_building], BLD_REAL
    call prepare_world
    call new_game
    mov dword [t_stun], __float32__(10000.0)
    call traverse_reset
    ; every open spot T can reach from the entry
    call start_node
    mov edi, eax
    mov esi, NNODES + 1                 ; (a target that can't exist: flood it all)
    call find_path
    mov r15d, [stamp]
    xor r13d, r13d
    xor ecx, ecx
.oc:
    cmp ecx, [open_count]
    jge .oc_done
    mov eax, [open_cells+rcx*4]
    cmp [seen+rax*4], r15d
    je .oc_ok
    inc r13d
.oc_ok:
    inc ecx
    jmp .oc
.oc_done:
    lea rdi, [st_real_reach]
    mov esi, [open_count]
    mov edx, r13d
    xor eax, eax
    call printf
    ; up the grand staircase, over the stage, to the 2nd floor
    lea rdi, [st_real_grand]
    mov esi, 1
    mov edx, 28
    mov ecx, 19
    FLD xmm0, 3.1416                    ; south
    FLD xmm1, 3.0
    call walk_test
    ; the back stair: round the corner at its foot, then up
    mov edi, 1
    mov esi, 35
    mov edx, 29
    call player_spawn
    xor edi, edi
    FLD xmm0, -1.5708                   ; east, onto its bottom step
    FLD xmm1, 1.1
    call walk_leg
    lea rdi, [st_real_back]
    FLD xmm0, 0.0                       ; north, up the stair
    FLD xmm1, 3.0
    call walk_leg
    ; down to the sub-level from the service landing
    lea rdi, [st_real_down]
    mov esi, 1
    mov edx, 37
    mov ecx, 13
    FLD xmm0, 3.1416
    FLD xmm1, 4.0
    call walk_test
    ; up the maintenance ladder into room 117
    call traverse_reset
    lea rdi, [st_real_ladder]
    xor esi, esi
    mov edx, 22
    mov ecx, 3
    FLD xmm0, 3.1416                    ; south, into the ladder's wall
    FLD xmm1, 4.0
    call walk_test
    call traverse_reset
    ; the zipline from the north balcony down onto the stage
    mov edi, 2
    mov esi, 22
    mov edx, 8
    call player_spawn
    movss xmm0, [c_dt_shot]
    call traverse_update
    call traverse_try_grab
    mov [rsp+0], eax
    mov ebx, 60*6
.ride:
    movss xmm0, [c_dt_shot]
    call traverse_update
    movss xmm0, [c_dt_shot]
    movss xmm1, [elapsed_time]
    call player_update
    dec ebx
    jnz .ride
    lea rdi, [st_real_zip]
    mov esi, [rsp+0]
    cvtss2sd xmm0, [p_y]
    cvtss2sd xmm1, [p_z]
    mov eax, 2
    call printf
    call traverse_reset
    ; glass: T sees into the server room from the lobby, not through a wall
    FLD xmm0, 61.0
    FLD xmm1, 8.0
    FLD xmm2, 15.0
    FLD xmm3, 61.0
    FLD xmm4, 8.0
    FLD xmm5, 7.0
    call line_of_sight_3d
    mov [rsp+0], eax
    FLD xmm0, 47.0
    FLD xmm1, 8.0
    FLD xmm2, 17.0
    FLD xmm3, 47.0
    FLD xmm4, 8.0
    FLD xmm5, 7.0
    call line_of_sight_3d
    mov edx, eax
    mov esi, [rsp+0]
    lea rdi, [st_real_glass]
    xor eax, eax
    call printf
    ; T comes up from the sub-level for you, hiding in room 213
    mov edi, 2
    mov esi, 23
    mov edx, 27
    call player_spawn
    mov dword [p_flash_on], 0
    mov edi, (0*MAP_H + 25)*MAP_W + 30
    call enemy_reset
    xor ebx, ebx
.hunt:
    cmp ebx, 60*200
    jge .lost
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
.no_hear:
    movss xmm0, [c_dt_shot]
    call enemy_update
    cmp dword [t_caught], 0
    jne .caught
    inc ebx
    jmp .hunt
.caught:
    cvtsi2sd xmm0, ebx
    mov rax, __float64__(60.0)
    movq xmm1, rax
    divsd xmm0, xmm1
    lea rdi, [st_real_hunt]
    mov eax, 1
    call printf
    jmp .done
.lost:
    lea rdi, [st_real_lost]
    xor eax, eax
    call printf
.done:
    call traverse_reset
    EPILOGUE

; ach_tests -- the achievement rules (nothing is saved in a test run)
ach_tests:
    PROLOGUE 32
    lea rdi, [ach_flag]
    xor esi, esi
    mov edx, NACH*4
    call memset
    call ach_new_run
    mov dword [elapsed_time], __float32__(1000.0)
    call ach_won                        ; a slow win, no deauths, never seen
    mov eax, [ach_flag+ACH_PACIFIST*4]
    mov [rsp+0], eax
    mov eax, [ach_flag+ACH_GHOST*4]
    mov [rsp+4], eax
    mov eax, [ach_flag+ACH_SPEEDRUN*4]
    mov [rsp+8], eax
    lea rdi, [ach_flag]
    xor esi, esi
    mov edx, NACH*4
    call memset
    call ach_new_run
    inc dword [run_deauths]             ; this time: fired one, got spotted
    inc dword [run_spotted]
    call ach_won
    mov eax, [ach_flag+ACH_PACIFIST*4]
    mov [rsp+12], eax
    mov eax, [ach_flag+ACH_FULL_CAPTURE*4]
    mov [rsp+16], eax
    ; standing on the tall crate stack in the atrium pit (original map)
    xor edi, edi
    mov esi, 35
    mov edx, 19
    call player_spawn
    mov dword [p_y], __float32__(1.9)
    mov dword [p_on_ground], 1
    mov dword [p_mode], 0
    call ach_tick
    lea rdi, [st_ach_fmt]
    mov esi, [rsp+0]
    mov edx, [rsp+4]
    mov ecx, [rsp+8]
    mov r8d, [rsp+12]
    mov r9d, [rsp+16]
    xor eax, eax
    call printf
    lea rdi, [st_ach_fmt2]
    mov esi, [ach_flag+ACH_CRATES*4]
    xor eax, eax
    call printf
    mov dword [elapsed_time], 0
    EPILOGUE

; start_node -> eax = the node you start on in this building
start_node:
    sub rsp, 8
    mov edi, [start_f]
    mov esi, [start_x]
    mov edx, [start_y]
    call cell_index
    add rsp, 8
    ret

; spawn_check -- run T's spawn choice and keep the closest it ever came
spawn_check:
    sub rsp, 8
    call start_node
    mov edi, eax
    call far_spawn_node
    mov eax, [spawn_dist]
    cmp eax, [sw_min_steps]
    jge .s
    mov [sw_min_steps], eax
.s:
    imul eax, eax, 100
    xor edx, edx
    mov ecx, [spawn_maxd]
    test ecx, ecx
    jz .done
    div ecx
    cmp eax, [sw_min_pct]
    jge .done
    mov [sw_min_pct], eax
.done:
    add rsp, 8
    ret

; gen_tests -- the seeded building generator: every spot reachable?
gen_tests:
    PROLOGUE 32
    mov dword [cfg_building], 1
    mov dword [gt_layout], 0
.layout:
    mov eax, [gt_layout]
    mov [cfg_layout], eax
    lea rdi, [st_layout_fmt]
    lea rcx, [layout_names]
    mov rsi, [rcx+rax*8]
    xor eax, eax
    call printf
    mov r12d, 1                         ; seed
.seed:
    cmp r12d, 12
    jg .done
    mov edi, 1
    mov esi, r12d
    call world_select
    ; how many stair cells did it build?
    xor r13d, r13d
    xor ecx, ecx
.st:
    cmp ecx, NCELLS
    jge .st_done
    cmp byte [grid+rcx], '^'
    jne .st_n
    inc r13d
.st_n:
    inc ecx
    jmp .st
.st_done:
    ; 40 random open spots: can T walk there from the start?
    xor r14d, r14d                      ; unreachable
    mov ebx, 40
.p:
    call rng_next
    xor edx, edx
    div dword [open_count]
    mov esi, [open_cells+rdx*4]
    mov edi, NODE(1,1,1)
    call find_path
    test eax, eax
    jnz .p_ok
    inc r14d
.p_ok:
    dec ebx
    jnz .p
    lea rdi, [st_gen_fmt]
    mov esi, r12d
    mov edx, [open_count]
    mov ecx, r13d
    mov r8d, r14d
    xor eax, eax
    call printf
    ; BEACOM_GENDUMP=1: print seed 1's floors
    cmp r12d, 1
    jne .no_dump
    lea rdi, [env_gendump]
    call getenv
    test rax, rax
    jz .no_dump
    xor ebx, ebx
.dump_row:
    cmp ebx, NCELLS
    jge .no_dump
    lea rsi, [grid+rbx]
    lea rdi, [st_row_fmt]
    xor eax, eax
    call printf
    add ebx, MAP_W
    jmp .dump_row
.no_dump:
    inc r12d
    jmp .seed
.done:
    inc dword [gt_layout]
    cmp dword [gt_layout], 3
    jl .layout
    mov dword [cfg_layout], 1
    mov dword [cfg_building], BLD_ORIGINAL
    mov edi, BLD_ORIGINAL
    xor esi, esi
    call world_select
    EPILOGUE

; atrium_tests -- Phase 1: the continuous 3D building
atrium_tests:
    PROLOGUE 64
    mov dword [t_stun], __float32__(10000.0)
    ; ramp A -> the bridge -> ramp B: ground floor to 2nd floor with no stairs
    call traverse_reset
    mov edi, 1
    mov esi, 33
    mov edx, 23
    call player_spawn
    xor edi, edi
    FLD xmm0, 0.0                       ; north, up ramp A
    FLD xmm1, 2.2
    call walk_leg
    lea rdi, [st_n_ramp_a]
    FLD xmm0, 0.0
    FLD xmm1, 0.01
    call walk_leg
    xor edi, edi
    FLD xmm0, -1.5708                   ; east along the bridge
    FLD xmm1, 1.25
    call walk_leg
    lea rdi, [st_n_ramp_b]
    FLD xmm0, 3.1416                    ; south, up ramp B
    FLD xmm1, 2.6
    call walk_leg
    ; walking off the balcony edge drops you into the basement
    lea rdi, [st_n_drop]
    mov esi, 1
    mov edx, 32
    mov ecx, 18
    FLD xmm0, -1.5708                   ; east, into the void
    FLD xmm1, 1.2
    call walk_test

    ; the atrium zipline: 2nd-floor server room down to the ground balcony
    call traverse_reset
    mov edi, 2
    mov esi, 42
    mov edx, 18
    call player_spawn
    movss xmm0, [c_dt_shot]
    call traverse_update
    call traverse_try_grab
    mov [rsp+0], eax
    mov ebx, 60*8
.ride:
    movss xmm0, [c_dt_shot]
    call traverse_update
    movss xmm0, [c_dt_shot]
    movss xmm1, [elapsed_time]
    call player_update
    dec ebx
    jnz .ride
    call player_floor
    mov edx, eax
    mov esi, [rsp+0]
    lea rdi, [st_zip2_fmt]
    cvtss2sd xmm0, [p_x]
    cvtss2sd xmm1, [p_y]
    mov eax, 2
    call printf
    call traverse_reset

    ; 3D line of sight: T in the basement looks up the atrium...
    FLD xmm0, 69.0
    FLD xmm1, 1.75
    FLD xmm2, 41.0
    FLD xmm3, 73.0                      ; ...at you on the 2nd-floor balcony
    FLD xmm4, 8.0
    FLD xmm5, 41.0
    call line_of_sight_3d
    mov [rsp+0], eax
    FLD xmm0, 69.0
    FLD xmm1, 1.75
    FLD xmm2, 41.0
    FLD xmm3, 81.0                      ; ...and at a spot behind a solid floor
    FLD xmm4, 8.0
    FLD xmm5, 41.0
    call line_of_sight_3d
    mov edx, eax
    mov esi, [rsp+0]
    lea rdi, [st_los_fmt]
    xor eax, eax
    call printf

    ; sound: up the open atrium vs through two solid floors
    FLD xmm0, 69.0
    FLD xmm1, 1.0
    FLD xmm2, 41.0
    FLD xmm3, 69.0
    FLD xmm4, 7.4
    FLD xmm5, 41.0
    call sound_occlusion
    movss [rsp+0], xmm0
    FLD xmm0, 17.0
    FLD xmm1, 1.0
    FLD xmm2, 41.0
    FLD xmm3, 17.0
    FLD xmm4, 7.4
    FLD xmm5, 41.0
    call sound_occlusion
    cvtss2sd xmm1, xmm0
    cvtss2sd xmm0, [rsp+0]
    lea rdi, [st_snd_fmt]
    mov eax, 2
    call printf

    ; the nav graph: up the ramps, and down off a ledge
    mov edi, NODE(1,33,23)
    mov esi, NODE(2,35,23)
    call find_path
    mov esi, eax
    mov edx, [path_len]
    lea rdi, [st_nav_up]
    xor eax, eax
    call printf
    mov edi, NODE(2,36,20)
    mov esi, NODE(0,34,20)
    call find_path
    mov esi, eax
    mov edx, [path_len]
    lea rdi, [st_nav_drop]
    xor eax, eax
    call printf

    ; T comes up the atrium for you while you stand on the bridge
    mov edi, NODE(0,34,26)
    call enemy_reset
    mov dword [p_x], __float32__(69.0)
    mov dword [p_y], __float32__(4.8)
    mov dword [p_z], __float32__(39.3)
    mov dword [p_mode], 0
    mov dword [p_flash_on], 0
    xor ebx, ebx
.hunt:
    cmp ebx, 60*120
    jge .lost
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
.no_hear:
    movss xmm0, [c_dt_shot]
    call enemy_update
    cmp dword [t_caught], 0
    jne .caught
    inc ebx
    jmp .hunt
.caught:
    cvtsi2sd xmm0, ebx
    mov rax, __float64__(60.0)
    movq xmm1, rax
    divsd xmm0, xmm1
    cvtss2sd xmm1, [t_y]
    lea rdi, [st_bridge_ok]
    mov eax, 2
    call printf
    jmp .done
.lost:
    lea rdi, [st_bridge_fail]
    xor eax, eax
    call printf
.done:
    mov dword [t_stun], __float32__(10000.0)
    call traverse_reset
    EPILOGUE

selftest:
    PROLOGUE 32
    mov dword [seed_val], 42
    call real_tests                     ; the real Beacom first...
    mov dword [cfg_building], BLD_ORIGINAL
    call prepare_world                  ; ...then the original map's tests
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
    call traverse_reset
    lea rdi, [st_n_lad1]
    mov esi, 1
    mov edx, 4
    mov ecx, 9
    FLD xmm0, 1.5708                    ; west, into the ladder
    FLD xmm1, 4.0
    call walk_test
    call traverse_reset
    lea rdi, [st_n_lad2]
    xor esi, esi
    mov edx, 2
    mov ecx, 22
    FLD xmm0, 1.5708
    FLD xmm1, 4.0
    call walk_test
    ; zipline: stand under the ground-floor cable, grab it, ride it
    call traverse_reset
    mov edi, 1
    mov esi, 4
    mov edx, 14
    call player_spawn
    movss xmm0, [c_dt_shot]
    call traverse_update
    call traverse_try_grab
    mov r12d, eax
    mov ebx, 60*14
.ride:
    movss xmm0, [c_dt_shot]
    call traverse_update
    movss xmm0, [c_dt_shot]
    movss xmm1, [elapsed_time]
    call player_update
    dec ebx
    jnz .ride
    call player_floor
    mov edx, eax
    lea rdi, [st_zip_fmt]
    mov esi, r12d
    cvtss2sd xmm0, [p_x]
    cvtss2sd xmm1, [p_y]
    mov eax, 2
    call printf
    call traverse_reset

    call atrium_tests
    call parkour_tests
    call gen_tests
    call ach_tests
    lea rdi, [env_gensweep]
    call getenv
    test rax, rax
    jz .no_sweep
    mov rdi, rax
    call atoi_simple
    cmp eax, 1
    jl .no_sweep
    cmp eax, MAX_SWEEP
    jle .sweep
    mov eax, MAX_SWEEP
.sweep:
    mov [rsp+0], eax
    mov dword [gt_layout], 0
.sweep_layout:
    mov eax, [gt_layout]
    mov [cfg_layout], eax
    lea rdi, [st_layout_fmt]
    lea rcx, [layout_names]
    mov rsi, [rcx+rax*8]
    xor eax, eax
    call printf
    mov edi, [rsp+0]
    call gen_sweep
    inc dword [gt_layout]
    cmp dword [gt_layout], 3
    jl .sweep_layout
    mov dword [cfg_layout], 1
.no_sweep:

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

    ; physics: T collapses in the ground-floor hall; after 2s he should be
    ; lying on the floor (y = 3.2), and a box dropped from 1.5m should rest on it
    call physics_reset
    FLD xmm0, 30.0
    FLD xmm1, 3.2
    FLD xmm2, 31.0
    FLD xmm3, 1.0
    xorps xmm4, xmm4
    xorps xmm5, xmm5
    call physics_ragdoll
    mov ebx, 120
.fall:
    movss xmm0, [c_dt_shot]
    call physics_update
    dec ebx
    jnz .fall
    extern py
    lea rdi, [st_rag_fmt]
    cvtss2sd xmm0, [py+0]               ; head
    cvtss2sd xmm1, [py+8]               ; pelvis
    mov eax, 2
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
    mov edi, SDL_GL_STENCIL_SIZE        ; the portals draw through the stencil buffer
    mov esi, 8
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

    ; your settings (not for the test modes: they must be reproducible)
    cmp dword [shot_mode], 0
    jne .no_cfg
    call settings_load
    call ach_load                       ; (and save them from now on)
.no_cfg:
    call world_init
    call render_init
    call hud_init
    call audio_init
    mov dword [built_mode], -1
    call prepare_world

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
