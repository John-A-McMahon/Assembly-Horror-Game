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
global special, have_hookshot, add_item
global have_grod, tyler_armed, tyler_x, tyler_y, tyler_z, grod_beam, beam_x, beam_y, beam_z

extern sign_count, glDeleteLists, t_speed_bonus, keys_down, p_crouch, p_step_event
extern traverse_reset, traverse_update, traverse_try_grab, trav_prompt, p_mode
extern p_on_ground, snd_can, snd_can_t, p_vy, feeder_put, por_on, portal_reset
extern build_deauth, director_reset, t_build, bld_on, t_goal, dir_calm, dir_relax, t_camp
extern t_por_on, build_break, enemy_portal_follow, bld_ay, bld_by, bld_ax, bld_bx, bld_az, bld_bz
extern bld_cd, build_hit_point, t_node, p_eye
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
st_oob_fling db "[selftest] hookshot at the ceiling + fling: floor %d -> floor %d, head reached y=%.2f (expect <= 6.40: no popping into the room above)",10,0
st_oob_floor db "[selftest] hookshot at the floor: floor %d -> floor %d, feet got down to y=%.2f (expect >= 3.20: not dragged through it)",10,0
st_oob_roof db "[selftest] hookshot fling on the top floor: head reached y=%.2f (expect <= 9.60: not out through the roof)",10,0
st_oob_none db "[selftest] hookshot out-of-bounds: no open spot found on floor %d -- FAIL",10,0
st_fd_steal db "[selftest] bottom feeder: robbed you after %.1fs (expect < 5): captures 2 -> %d (expect 1), it carries %d (expect 1)",10,0
st_fd_stash db "[selftest] bottom feeder: stashed it after %.1fs, %.0f m from you (expect > 20), carrying %d (expect 0), a new capture lies there=%d (expect 1)",10,0
st_fd_back db "[selftest] bottom feeder: you caught the thief: captures %d (expect 2), OUT-FED=%d (expect 1)",10,0
st_fd_away db "[selftest] deauth fired away from the feeder: hit it=%d (expect 0: the packet goes to T), gone=%d (expect 0)",10,0
st_fd_deauth db "[selftest] deauth aimed at the thief: hit it=%d (expect 1), gone for good=%d (expect 1), carrying %d (expect 0), capture dropped=%d (expect 1)",10,0
st_grod_pick db "[selftest] Grod: picked up the packet weapon=%d (expect 1), it is not a special item you can fire: special=%d (expect 0)",10,0
st_grod_arm db "[selftest] Grod: gave it to Tyler: armed=%d (expect 1), still carrying=%d (expect 0), WORTHY=%d (expect 1)",10,0
st_grod_fire db "[selftest] Grod: T walked up to Tyler: blasted=%d (expect 1), now %.0f m from Tyler (expect > 20), recharging %.0fs (expect 20)",10,0
st_grod_cd db "[selftest] Grod: T back at once: blasted again=%d (expect 0 while it recharges)",10,0
st_fd_ignore db "[selftest] bottom feeder: with no captures on you it left you alone for 5s: captures %d (expect 0), chased=%d (expect 0)",10,0
st_dir_push db "[selftest] director: comfortable for 41s -> T investigating=%d (expect 1), heading for your spot=%d (expect 1)",10,0
st_dir_relax db "[selftest] director: after a close call T backs off to a spot %d cells from you (expect >= 25)",10,0
st_bld db "[selftest] T builds: you on a crate stack (y=%.2f), T below: built=%d climbed=%d (expect 1 1), caught you=%d (expect 1) after %.1fs",10,0
st_bld_brk db "[selftest] T's stairs knocked down mid-climb: T back on the floor=%d (expect 1), stunned=%d (expect 1), stairs gone=%d (expect 1)",10,0
st_bld_aim db "[selftest] T's stairs: deauth aimed at them=%d (expect 1); hook point on them=%d, 3 m off=%d (expect 1 0)",10,0
st_por_t db "[selftest] T follows you through your portal: came out of the exit=%d (expect 1) after %.1fs",10,0
st_por_safe db "[selftest] portal at a safe-room wall: placed=%d (expect 0 -- no portals in safe rooms)",10,0
st_hook_hear db "[selftest] hookshot bite heard: T investigating=%d (expect 1)",10,0
st_nem db "[selftest] nemesis: 3 hookshot escapes -> hears it from %.0f m (expect 33); 3 perches -> builds in %.2fs (expect 1.05); next night it's forgotten: %.0f m (expect 22)",10,0
st_dew_you db "[selftest] Diet Mountain Dew: %.1fs of it (expect 10.0), stamina %.2f after sprinting on empty (expect 1.00)",10,0
st_dew_t db "[selftest] T sniffed out a can %d cells away and drank it after %.1fs (expect < 15): wired for %.1fs (expect > 0), can gone=%d (expect 1)",10,0
st_hook_across db "[selftest] hookshot across the collaboration space: pulled to x=%.2f (the media wall is at x=70; expect > 67)",10,0
st_hook_up db "[selftest] hookshot up to the balcony: ended at y=%.2f on floor %d (expect floor 2), SPIDER-BEACOM=%d (expect 1)",10,0
st_hook_t db "[selftest] hookshot hits T: stunned for %.2fs (expect > 0), GET OVER HERE=%d (expect 1)",10,0
st_hook_slot db "[selftest] one special item: portal gun held=%d, hookshot left at your feet=%d (expect 1 1); holding %d (3=hookshot) after dropping a stack of %d deauths (expect 3)",10,0
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
m_controls  db "ESC: menu + CUSTOM RUN settings - WASD move - mouse or arrow keys look - SHIFT sprint - C crouch (sprint+C slide) - SPACE jump / mantle / vault - F flashlight - E grab - LMB/Q use item (deauth, portal, hookshot) - RMB orange portal - M map - I invert mouse - F3 fps - F4 render scale - F5 shadows",0
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
m_got_portal db "You got the PORTAL GUN! Left click (or Q): blue portal, right click: orange portal.",0
m_got_hook  db "You got the HOOKSHOT! Left click (or Q) at a wall, a ceiling, a ledge: it bites and yanks you there. SPACE mid-pull flings you.",0
m_dropped   db "You can only carry one special item -- you leave the %s where you stand.",0
m_full      db "You can't carry more than 3 deauth packets.",0
m_dew_you   db "*kssht* DIET MOUNTAIN DEW. Unlimited stamina for 10 seconds -- run.",0
m_dew_off   db "The Dew wears off.",0
m_dew_t     db "*kssht* ...somewhere, T just cracked open a Diet Mountain Dew. He's WIRED: faster, sharper, for 15 seconds.",0
c_dew_you   dd 10.0
c_dew_t     dd 15.0
c_dew_sip   dd 0.9                      ; T drinks a can this close
c_dew_sniff dd 14.0                     ; ...and wanders over to one this close
c_noise_can dd 0.1                      ; cracking a can open is not quiet
m_grod      db "You lift an ancient packet weapon, humming with power. A voice BOOMS: 'YOU ARE NOT WORTHY.' ...but maybe Tyler is. Find him -- he hangs around the %s.",0
grod_fl0    db "basement",0
grod_fl1    db "ground floor",0
grod_fl2    db "second floor",0
align 8
grod_fls    dq grod_fl0, grod_fl1, grod_fl2
m_unworthy  db "The packet of Grod won't fire for you. 'YOU ARE NOT WORTHY.' Take it to Tyler.",0
m_worthy    db "TYLER IS WORTHY. He raises the packet of Grod and it becomes the DAUTH CANNON OF GROD! Lure T past him...",0
m_grod_fire db "The DAUTH CANNON OF GROD roars -- T is blasted clean across the building!",0
c_grod_r    dd 16.0                     ; the cannon's reach
c_grod_cd   dd 20.0                     ; ...and its recharge
c_grod_beam dd 0.5
c_give_d    dd 2.6                      ; close enough to hand Tyler something
m_nothing   db "You're not holding a special item (deauth packet, portal gun or hookshot).",0
sp_name1    db "deauth packets",0
sp_name2    db "portal gun",0
sp_name3    db "hookshot",0
align 8
sp_names    dq 0, sp_name1, sp_name2, sp_name3
sp_items    dd -1, IT_WEAPON, IT_PORTAL, IT_HOOKSHOT
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
sh_learn db "shots/43_t_learns.bmp",0
sh_build db "shots/42_t_builds_stairs.bmp",0
sh_grod db "shots/40_packet_of_grod.bmp",0
sh_tyler db "shots/41_dauth_cannon_of_grod.bmp",0
sh_feeders db "shots/39_bottom_feeders.bmp",0
sh_dew db "shots/38_diet_mountain_dew.bmp",0
sh_hook_hand db "shots/36_hookshot_in_hand.bmp",0
sh_hook_chain db "shots/37_hookshot_chain.bmp",0
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
dew_count   resd 1                      ; cans you drank this run
have_grod   resd 1                      ; carrying the packet of Grod
tyler_armed resd 1                      ; Tyler is the DAUTH CANNON OF GROD
tyler_item  resd 1                      ; Tyler's slot in items[]
tyler_x     resd 1
tyler_y     resd 1
tyler_z     resd 1
grod_cd     resd 1                      ; seconds until it can fire again
grod_beam   resd 1                      ; seconds of bolt left on screen
beam_x      resd 1                      ; where the bolt hit T
beam_y      resd 1
beam_z      resd 1
fo_x        resd 1                      ; find_open's answer
fo_y        resd 1
fo_f        resd 1
bld_max     resd 1                      ; (self-tests) furthest T's build got
hr_maxy     resd 1                      ; hook_run: highest / lowest feet
hr_miny     resd 1
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
have_hookshot resd 1
special     resd 1                  ; SP_: the one special item you carry
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
    jge .reuse
    inc dword [item_count]
    jmp .slot
.reuse:
    ; full: reuse the slot of something already picked up
    xor eax, eax
.free:
    cmp eax, MAX_ITEMS
    jge .full
    imul ecx, eax, ITEM_SIZE
    cmp dword [items+rcx+ITEM_ACTIVE], 0
    je .slot
    inc eax
    jmp .free
.slot:
    imul ecx, eax, ITEM_SIZE
    lea rbx, [items+rcx]
    mov [rbx+ITEM_KIND], r12d
    mov dword [rbx+ITEM_ACTIVE], 1
    mov dword [rbx+ITEM_SEEN], 0
    mov dword [rbx+ITEM_CHARGES], 1
    movss [rbx+ITEM_X], xmm0
    movss [rbx+ITEM_Y], xmm1
    movss [rbx+ITEM_Z], xmm2
    movaps xmm0, xmm1
    call floor_of_height
    mov [rbx+ITEM_F], eax
.full:
    EPILOGUE

new_game:
    PROLOGUE 16
    mov edi, [seed_val]
    call rng_seed
    xor eax, eax
    mov [inventory], eax
    mov [deauths], eax
    mov [dew_count], eax
    mov [have_grod], eax
    mov [tyler_armed], eax
    mov [grod_cd], eax
    mov [grod_beam], eax
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
    call hookshot_reset
    call ach_new_run
    mov dword [crouch_latch], 0
    xor edi, edi
    call snd_mute                       ; (volume setting)
    xor eax, eax
    mov [have_map], eax
    mov [have_compass], eax
    mov [have_portal], eax
    mov [have_hookshot], eax
    mov [special], eax
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
    mov edi, SP_PORTAL
    call give_special
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
    ; ...and the hookshot (hidden / in your hands / none)
    cmp dword [cfg_hookshot], 1
    jne .hook_hidden
    mov edi, SP_HOOK
    call give_special                   ; (both in hand? the portal gun lands at your feet)
.hook_hidden:
    cmp dword [cfg_hookshot], 0
    jne .hook_done
    mov edi, -1
    xor esi, esi
    xor edx, edx
    call random_cell
    mov esi, eax
    mov edi, IT_HOOKSHOT
    call add_item
.hook_done:
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
    mov eax, [item_count]
    dec eax
    mov [tyler_item], eax
    imul eax, eax, ITEM_SIZE
    mov ecx, [items+rax+ITEM_X]
    mov [tyler_x], ecx
    mov ecx, [items+rax+ITEM_Y]
    mov [tyler_y], ecx
    mov ecx, [items+rax+ITEM_Z]
    mov [tyler_z], ecx
    ; the ancient packet weapon, deep in the basement
    xor edi, edi
    xor esi, esi
    xor edx, edx
    call random_cell
    mov esi, eax
    mov edi, IT_GROD
    call add_item
    mov edi, 1
    mov esi, 10
    mov edx, 18
    call random_cell
    mov esi, eax
    mov edi, IT_JOCKEY
    call add_item
    ; cans of Diet Mountain Dew, for whoever gets there first
    mov ebx, [cfg_dew]
    test ebx, ebx
    jz .dew_done
.dew:
    mov edi, -1
    xor esi, esi
    xor edx, edx
    call random_cell
    mov esi, eax
    mov edi, IT_DEW
    call add_item
    dec ebx
    jnz .dew
.dew_done:

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
    call feeders_reset                  ; ...and the bottom feeders, away from you
    call director_reset
    call nemesis_new_night              ; T starts the night knowing nothing

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
    call near_tyler
    test eax, eax
    jz .no_tyler
    cmp dword [have_grod], 0
    je .no_tyler
    mov dword [have_grod], 0
    mov dword [tyler_armed], 1
    call snd_fanfare
    lea rdi, [m_worthy]
    mov esi, COL_GOOD
    call msg
    mov edi, ACH_WORTHY
    call ach_unlock
    EPILOGUE
.no_tyler:
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
    jne .dew
    jmp .deauth
.dew:
    cmp dword [rbx+ITEM_KIND], IT_GROD
    jne .not_grod
    mov dword [have_grod], 1
    call snd_fanfare
    movss xmm0, [tyler_y]
    call floor_of_height
    cmp eax, 2
    jle .grod_fl
    mov eax, 2
.grod_fl:
    lea rcx, [grod_fls]
    mov rcx, [rcx+rax*8]
    lea rdi, [msg_buf]
    mov esi, 512
    lea rdx, [m_grod]
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    call lore
    jmp .done
.not_grod:
    cmp dword [rbx+ITEM_KIND], IT_DEW
    jne .zelda
    call snd_can
    movss xmm0, [c_noise_can]
    call noise_add
    mov eax, [c_dew_you]
    mov [p_dew], eax
    inc dword [dew_count]
    cmp dword [dew_count], 3
    jl .dew_msg
    mov edi, ACH_DEW
    call ach_unlock
.dew_msg:
    lea rdi, [m_dew_you]
    mov esi, COL_GOOD
    call msg
    jmp .done
.deauth:
    mov r12d, [rbx+ITEM_CHARGES]        ; (a dropped stack can hold several)
    cmp r12d, 1
    jge .charges
    mov r12d, 1
.charges:
    cmp dword [special], SP_DEAUTH
    jne .new_stack
    mov eax, [deauths]
    add eax, r12d
    cmp eax, MAX_DEAUTHS
    jle .stack
    ; full: leave it where it is
    mov dword [rbx+ITEM_ACTIVE], 1
    lea rdi, [m_full]
    mov esi, COL_WARN
    call msg
    jmp .done
.stack:
    mov [deauths], eax
    jmp .got_deauth
.new_stack:
    mov edi, SP_DEAUTH
    call give_special
    mov [deauths], r12d
.got_deauth:
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
    jne .not_portal
    mov edi, SP_PORTAL
    call give_special
    lea rdi, [m_got_portal]
    mov esi, COL_GOOD
    call msg
    jmp .done
.not_portal:
    cmp eax, IT_HOOKSHOT
    jne .done
    mov edi, SP_HOOK
    call give_special
    lea rdi, [m_got_hook]
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

; use_special(edi = 0 primary / 1 secondary) -- whatever you carry
use_special:
    PROLOGUE 16
    mov ebx, edi
    mov eax, [special]
    cmp eax, SP_DEAUTH
    je .deauth
    cmp eax, SP_PORTAL
    je .portal
    cmp eax, SP_HOOK
    je .hook
    lea rdi, [m_nothing]
    cmp dword [have_grod], 0
    je .say
    lea rdi, [m_unworthy]
.say:
    mov esi, COL_WARN
    call msg
    EPILOGUE
.deauth:
    call fire_deauth
    EPILOGUE
.portal:
    mov edi, ebx                        ; blue / orange
    call portal_fire
    EPILOGUE
.hook:
    call hookshot_fire
    EPILOGUE

; give_special(edi = SP_) -- hold this one; whatever you held (if it was a
; different kind) is left on the floor where you stand, deauth stack and all
give_special:
    PROLOGUE 16
    mov ebx, edi
    mov eax, [special]
    cmp eax, SP_NONE
    je .take
    cmp eax, ebx
    je .take
    ; drop it: an item at your feet
    mov r12d, eax
    mov edi, [sp_items+r12*4]
    call drop_item
    mov ecx, [deauths]
    cmp r12d, SP_DEAUTH
    je .count
    mov ecx, 1
.count:
    mov [rax+ITEM_CHARGES], ecx
    mov dword [deauths], 0
    lea rdi, [msg_buf]
    mov esi, 512
    lea rdx, [m_dropped]
    mov rcx, [sp_names+r12*8]
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, COL_INFO
    call msg
.take:
    mov [special], ebx
    xor eax, eax
    cmp ebx, SP_PORTAL
    sete al
    mov [have_portal], eax
    xor eax, eax
    cmp ebx, SP_HOOK
    sete al
    mov [have_hookshot], eax
    EPILOGUE

; drop_item(edi = item kind) -> rax = the new item, lying where you stand
; (reuses a picked-up slot when the list is full)
drop_item:
    PROLOGUE 16
    mov r12d, edi
    mov eax, [item_count]
    cmp eax, MAX_ITEMS
    jl .append
    xor ecx, ecx                        ; full: take a slot that's been picked up
.find:
    cmp ecx, MAX_ITEMS
    jge .last
    imul eax, ecx, ITEM_SIZE
    cmp dword [items+rax+ITEM_ACTIVE], 0
    je .slot
    inc ecx
    jmp .find
.last:
    mov ecx, MAX_ITEMS-1
.slot:
    imul eax, ecx, ITEM_SIZE
    jmp .fill
.append:
    imul eax, eax, ITEM_SIZE
    inc dword [item_count]
.fill:
    lea rbx, [items+rax]
    mov [rbx+ITEM_KIND], r12d
    mov dword [rbx+ITEM_ACTIVE], 1
    mov dword [rbx+ITEM_SEEN], 1
    mov dword [rbx+ITEM_CHARGES], 1
    mov eax, [p_x]
    mov [rbx+ITEM_X], eax
    mov eax, [p_y]
    mov [rbx+ITEM_Y], eax
    mov eax, [p_z]
    mov [rbx+ITEM_Z], eax
    call player_floor
    mov [rbx+ITEM_F], eax
    mov rax, rbx
    EPILOGUE

; fire_deauth -- a deauth packet (use_special)
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
    jnz .more_left
    mov dword [special], SP_NONE
.more_left:
    inc dword [run_deauths]             ; (no PACIFIST this run)
    ; aimed at a bottom feeder? it's gone for good -- and T is untouched.
    ; At T's stairs? they come down (with him). Otherwise it's T's.
    call feeders_deauth
    test eax, eax
    jnz .spent
    call build_deauth
    test eax, eax
    jz .at_t
.spent:
    call snd_deauth
    movss xmm0, [c_noise_deauth]
    call noise_add
    mov eax, [c_one]
    mov [hud_flash], eax
    EPILOGUE
.at_t:
    mov edi, 4                          ; (nemesis: you got away with a deauth)
    call nemesis_note
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
    ; your special item: left click uses it, right click is its other use
    ; (the orange portal; the same as left for everything else)
    xor edi, edi
    cmp ecx, 1
    je .use
    cmp ecx, 3
    jne .poll
    mov edi, 1
.use:
    call use_special
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
    xor edi, edi
    call use_special
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
    call near_tyler                     ; Tyler: hand him the packet / his title
    test eax, eax
    jz .items
    cmp dword [have_grod], 0
    je .title
    mov dword [hud_prompt], 12
    EPILOGUE
.title:
    cmp dword [tyler_armed], 0
    je .items
    mov dword [hud_prompt], 13
.items:
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
    mov dword [hud_prompt], 8
    cmp dword [inventory], 3
    jl .done
    mov dword [hud_prompt], 9
.done:
    EPILOGUE

; near_tyler -> eax 1 if you're right beside Tyler
near_tyler:
    PROLOGUE 16
    movss xmm0, [tyler_x]
    movss xmm1, [tyler_y]
    movss xmm2, [tyler_z]
    call dist_to_player
    xor eax, eax
    comiss xmm0, [c_give_d]
    jae .no
    mov eax, 1
.no:
    EPILOGUE

; grod_tick(xmm0 = dt) -- the DAUTH CANNON OF GROD: when T comes within reach
; and in sight of Tyler, it blasts him across the building (then recharges)
grod_tick:
    PROLOGUE 32
    movss xmm1, [grod_beam]
    subss xmm1, xmm0
    maxss xmm1, [c_zero]
    movss [grod_beam], xmm1
    cmp dword [tyler_armed], 0
    je .done
    movss xmm1, [grod_cd]
    subss xmm1, xmm0
    maxss xmm1, [c_zero]
    movss [grod_cd], xmm1
    comiss xmm1, [c_zero]
    ja .done
    movss xmm0, [t_stun]
    comiss xmm0, [c_zero]
    ja .done
    cmp dword [rag_active], 0
    jne .done
    movss xmm0, [t_x]
    subss xmm0, [tyler_x]
    mulss xmm0, xmm0
    movss xmm1, [t_z]
    subss xmm1, [tyler_z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [t_y]
    subss xmm1, [tyler_y]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    comiss xmm0, [c_grod_r]
    jae .done
    movss xmm0, [tyler_x]
    movss xmm1, [tyler_y]
    FLD xmm3, 1.05
    addss xmm1, xmm3
    movss xmm2, [tyler_z]
    movss xmm3, [t_x]
    movss xmm4, [t_y]
    FLD xmm5, 1.0
    addss xmm4, xmm5
    movss xmm5, [t_z]
    call line_of_sight_3d
    test eax, eax
    jz .done
    ; FIRE
    mov eax, [t_x]
    mov [beam_x], eax
    mov eax, [t_y]
    mov [beam_y], eax
    mov eax, [t_z]
    mov [beam_z], eax
    mov eax, [c_grod_beam]
    mov [grod_beam], eax
    mov eax, [c_grod_cd]
    mov [grod_cd], eax
    movss xmm0, [tyler_y]
    call floor_of_height
    mov edi, eax
    movss xmm0, [tyler_x]
    mulss xmm0, [c_inv_cell]
    cvttss2si esi, xmm0
    movss xmm0, [tyler_z]
    mulss xmm0, [c_inv_cell]
    cvttss2si edx, xmm0
    call enemy_deauth                   ; T: far away, and dazed
    call snd_deauth
    lea rdi, [m_grod_fire]
    mov esi, COL_GOOD
    call msg
.done:
    EPILOGUE

; dew_tick(xmm0 = dt) -- your Dew running out; T finding cans: he drinks any
; he walks past, and while wandering he sniffs out the nearest one
dew_tick:
    PROLOGUE 48
    movss [rsp+0], xmm0
    movss xmm1, [p_dew]
    comiss xmm1, [c_zero]
    jbe .t
    subss xmm1, xmm0
    maxss xmm1, [c_zero]
    movss [p_dew], xmm1
    comiss xmm1, [c_zero]
    ja .t
    lea rdi, [m_dew_off]
    mov esi, COL_WARN
    call msg
.t:
    movss xmm0, [t_stun]
    comiss xmm0, [c_zero]
    ja .done
    mov eax, [c_dew_sniff]
    mov [rsp+4], eax                    ; nearest can so far
    mov qword [rsp+8], 0
    xor ebx, ebx
.it:
    cmp ebx, [item_count]
    jge .lure
    imul eax, ebx, ITEM_SIZE
    lea r12, [items+rax]
    cmp dword [r12+ITEM_ACTIVE], 0
    je .n
    cmp dword [r12+ITEM_KIND], IT_DEW
    jne .n
    movss xmm0, [r12+ITEM_X]
    subss xmm0, [t_x]
    mulss xmm0, xmm0
    movss xmm1, [r12+ITEM_Z]
    subss xmm1, [t_z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [r12+ITEM_Y]
    subss xmm1, [t_y]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    comiss xmm0, [c_dew_sip]
    jb .drink
    comiss xmm0, [rsp+4]
    jae .n
    movss [rsp+4], xmm0
    mov [rsp+8], r12
.n:
    inc ebx
    jmp .it
.drink:
    mov dword [r12+ITEM_ACTIVE], 0
    mov eax, [c_dew_t]
    mov [t_dew], eax
    call snd_can_t
    lea rdi, [m_dew_t]
    mov esi, COL_DANGER
    call msg
    EPILOGUE
.lure:
    mov r12, [rsp+8]
    test r12, r12
    jz .done
    movss xmm0, [r12+ITEM_X]
    movss xmm1, [r12+ITEM_Y]
    movss xmm2, [r12+ITEM_Z]
    call node_at_pos
    mov edi, eax
    call enemy_lure
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
    call hookshot_update
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
    call dew_tick
    movss xmm0, [rsp+0]
    call feeders_update
    movss xmm0, [rsp+0]
    call grod_tick
    call nemesis_tick
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
    mov edi, SP_PORTAL
    call give_special
    lea rdi, [sh_hands_gun]
    call shot_now
    mov dword [special], SP_NONE
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
    ; the hookshot: in hand, then thrown across the collaboration space
    mov edi, 1
    mov esi, 26
    mov edx, 15
    call player_spawn
    mov dword [p_yaw], __float32__(-1.5708)
    mov dword [p_pitch], __float32__(0.05)
    mov edi, SP_HOOK
    call give_special
    lea rdi, [sh_hook_hand]
    call shot_now
    call hookshot_fire
    mov ebx, 12                         ; ~0.2 s: the head is on its way
.hk_fly:
    movss xmm0, [c_dt_shot]
    call hookshot_update
    dec ebx
    jnz .hk_fly
    lea rdi, [sh_hook_chain]
    call shot_now
    call hookshot_reset
    mov dword [p_mode], 0
    mov dword [special], SP_NONE
    mov dword [have_hookshot], 0
    ; a can of Diet Mountain Dew on the floor ahead
    mov edi, 1
    mov esi, 28
    mov edx, 15
    call cell_index
    mov esi, eax
    mov edi, IT_DEW
    call add_item
    mov edi, 1
    mov esi, 26
    mov edx, 15
    call player_spawn
    mov dword [p_yaw], __float32__(-1.5708)
    mov dword [p_pitch], __float32__(-0.35)
    lea rdi, [sh_dew]
    call shot_now
    mov eax, [item_count]
    dec eax
    imul eax, eax, ITEM_SIZE
    mov dword [items+rax+ITEM_ACTIVE], 0
    ; two bottom feeders: one coming at you, one making off with a capture
    mov dword [fd_count], 2
    mov edi, 1
    mov esi, 28
    mov edx, 15
    call cell_index
    mov esi, eax
    xor edi, edi
    call feeder_put
    mov dword [fd_yaw], __float32__(-1.5708)
    mov dword [fd_anim], __float32__(0.8)
    mov edi, 1
    mov esi, 29
    mov edx, 17
    call cell_index
    mov esi, eax
    mov edi, 1
    call feeder_put
    mov dword [fd_yaw+4], __float32__(0.6)
    mov dword [fd_anim+4], __float32__(2.3)
    mov dword [fd_carry+4], 1
    mov edi, 1
    mov esi, 26
    mov edx, 15
    call player_spawn
    mov dword [p_yaw], __float32__(-1.5708)
    mov dword [p_pitch], __float32__(-0.3)
    lea rdi, [sh_feeders]
    call shot_now
    mov dword [fd_count], 0
    ; the packet of Grod on the floor ahead
    mov edi, 1
    mov esi, 28
    mov edx, 15
    call cell_index
    mov esi, eax
    mov edi, IT_GROD
    call add_item
    lea rdi, [sh_grod]
    call shot_now
    mov eax, [item_count]
    dec eax
    imul eax, eax, ITEM_SIZE
    mov dword [items+rax+ITEM_ACTIVE], 0
    ; Tyler, armed: stand a few metres off him on open floor, looking at him
    mov dword [tyler_armed], 1
    xor r12d, r12d
.ty_try:
    cmp r12d, 4
    jge .ty_done
    movss xmm0, [tyler_x]
    movss xmm1, [tyler_z]
    FLD xmm2, 3.0
    cmp r12d, 1
    jne .t1
    FLD xmm2, -3.0
.t1:
    cmp r12d, 2
    jl .tx
    cmp r12d, 3
    jne .tz
    FLD xmm2, -3.0
.tz:
    addss xmm1, xmm2
    jmp .tp
.tx:
    addss xmm0, xmm2
.tp:
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss xmm0, [tyler_y]
    call floor_of_height
    mov edi, eax
    movss xmm0, [rsp+0]
    mulss xmm0, [c_inv_cell]
    cvttss2si esi, xmm0
    movss xmm0, [rsp+4]
    mulss xmm0, [c_inv_cell]
    cvttss2si edx, xmm0
    call cell_at
    cmp eax, ' '
    je .ty_ok
    inc r12d
    jmp .ty_try
.ty_ok:
    mov eax, [rsp+0]
    mov [p_x], eax
    mov eax, [tyler_y]
    mov [p_y], eax
    mov eax, [rsp+4]
    mov [p_z], eax
    ; T just off to the side, so the cannon turns to him, mid-blast
    movss xmm0, [tyler_x]
    subss xmm0, [p_x]
    movss xmm1, [tyler_z]
    subss xmm1, [p_z]
    xorps xmm0, [c_sign_mask]
    xorps xmm1, [c_sign_mask]
    call atan2f
    movss [p_yaw], xmm0
    mov dword [p_pitch], __float32__(0.05)
    lea rdi, [sh_tyler]
    call shot_now
.ty_done:
    mov dword [tyler_armed], 0
    ; T building his way up to you on a basement crate stack
    call perch_setup
    FLD xmm0, 12.0
    mov edi, 1
    call t_run
    mov ebx, 20                         ; a few steps up
.climb:
    movss xmm0, [c_dt_shot]
    call enemy_update
    dec ebx
    jnz .climb
    ; watch from the floor a few cells off, looking back at the stack
    mov edi, [fo_f]
    mov esi, [fo_x]
    add esi, 3
    mov edx, [fo_y]
    call player_spawn
    mov dword [p_yaw], __float32__(1.5708)
    mov dword [p_pitch], __float32__(0.12)
    lea rdi, [sh_build]
    call shot_now
    mov dword [bld_on], 0
    mov dword [t_build], 0
    ; T learning your tricks: what you are told
    call hud_clear_messages
    mov edi, 1
    mov esi, 26
    mov edx, 15
    call player_spawn
    mov dword [p_yaw], __float32__(-1.5708)
    call nemesis_new_night
    mov r12d, 2
.learn:
    mov dword [t_caught], 0
    mov dword [t_state], T_CHASE
    call nemesis_tick
    xor edi, edi
    call nemesis_note
    mov dword [t_state], T_WANDER
    call nemesis_tick
    dec r12d
    jnz .learn
    lea rdi, [sh_learn]
    call shot_now
    call nemesis_forget
    call hud_clear_messages
.ach_toast:
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

; hook_run(xmm0 = seconds) -- let the hookshot and you move for a while
hook_run:
    PROLOGUE 16
    FLD xmm1, 60.0
    mulss xmm0, xmm1
    cvttss2si ebx, xmm0
.f:
    movss xmm0, [hr_maxy]
    maxss xmm0, [p_y]
    movss [hr_maxy], xmm0
    movss xmm0, [hr_miny]
    minss xmm0, [p_y]
    movss [hr_miny], xmm0
    movss xmm0, [c_dt_shot]
    call hookshot_update
    movss xmm0, [c_dt_shot]
    call traverse_update
    movss xmm0, [c_dt_shot]
    movss xmm1, [elapsed_time]
    call player_update
    dec ebx
    jnz .f
    EPILOGUE

; hook_tests -- the hookshot and the one-special-item rule (real Beacom)
hook_tests:
    PROLOGUE 32
    mov dword [cfg_building], BLD_REAL
    call prepare_world
    call new_game
    mov dword [t_stun], __float32__(10000.0)
    lea rdi, [ach_flag]
    xor esi, esi
    mov edx, NACH*4
    call memset
    ; across the collaboration space to the media wall
    mov edi, 1
    mov esi, 26
    mov edx, 15
    call player_spawn
    mov dword [p_yaw], __float32__(-1.5708)
    mov dword [p_pitch], 0
    FLD xmm0, 0.05
    call hook_run
    call hookshot_fire
    FLD xmm0, 2.0
    call hook_run
    lea rdi, [st_hook_across]
    cvtss2sd xmm0, [p_x]
    mov eax, 1
    call printf
    ; up to the 2nd floor: aim high at the north balcony
    mov edi, 1
    mov esi, 28
    mov edx, 11
    call player_spawn
    mov dword [p_yaw], 0
    mov dword [p_pitch], __float32__(0.6)
    FLD xmm0, 0.05
    call hook_run
    call hookshot_fire
    FLD xmm0, 3.0
    call hook_run
    call player_floor
    mov esi, eax
    lea rdi, [st_hook_up]
    cvtss2sd xmm0, [p_y]
    mov edx, [ach_flag+ACH_SPIDER*4]
    mov eax, 1
    call printf
    ; hook T: he staggers
    mov edi, 1
    mov esi, 24
    mov edx, 15
    call player_spawn
    mov dword [p_yaw], __float32__(-1.5708)
    mov dword [p_pitch], 0
    mov edi, (1*MAP_H + 15)*MAP_W + 29
    call enemy_reset
    mov dword [t_stun], 0
    FLD xmm0, 0.05
    call hook_run
    call hookshot_fire
    FLD xmm0, 1.0
    call hook_run
    lea rdi, [st_hook_t]
    cvtss2sd xmm0, [t_stun]
    mov esi, [ach_flag+ACH_HOOK_T*4]
    mov eax, 1
    call printf
    ; one special item: picking up the portal gun leaves the hookshot behind
    mov dword [t_stun], __float32__(10000.0)
    mov dword [special], SP_NONE
    mov edi, SP_HOOK
    call give_special
    mov edi, SP_PORTAL
    call give_special
    mov r14d, [have_portal]
    xor r12d, r12d                      ; hookshots lying where you stand
    xor ebx, ebx
.it:
    cmp ebx, [item_count]
    jge .counted
    imul eax, ebx, ITEM_SIZE
    lea r13, [items+rax]
    cmp dword [r13+ITEM_ACTIVE], 0
    je .n
    cmp dword [r13+ITEM_KIND], IT_HOOKSHOT
    jne .n
    movss xmm0, [r13+ITEM_X]
    subss xmm0, [p_x]
    andps xmm0, [c_abs_mask]
    FLD xmm1, 0.1
    comiss xmm0, xmm1
    jae .n
    inc r12d
.n:
    inc ebx
    jmp .it
.counted:
    ; ...and a stack of 3 deauths is dropped as one item of 3
    mov edi, SP_DEAUTH
    call give_special
    mov dword [deauths], MAX_DEAUTHS
    mov edi, SP_HOOK
    call give_special
    mov eax, [item_count]
    dec eax
    imul eax, eax, ITEM_SIZE
    mov r8d, [items+rax+ITEM_CHARGES]
    lea rdi, [st_hook_slot]
    mov esi, r14d
    mov edx, r12d
    mov ecx, [special]
    xor eax, eax
    call printf
    lea rdi, [ach_flag]
    xor esi, esi
    mov edx, NACH*4
    call memset
    mov dword [special], SP_NONE
    mov dword [have_hookshot], 0
    mov dword [have_portal], 0
    EPILOGUE

; find_open(edi = floor, esi = 1: open floor under it too) -> eax 1 and
; fo_x/fo_y: a cell in the middle of a bit of open floor (3x3) with a slab
; over it (or the roof)
find_open:
    PROLOGUE 16
    mov r12d, edi
    mov r15d, esi
    mov r14d, 2
.y:
    cmp r14d, MAP_H-3
    jg .none
    mov r13d, 2
.x:
    cmp r13d, MAP_W-3
    jg .ny
    lea eax, [r12d+1]
    cmp eax, NF
    jge .roofed
    mov edi, eax
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, '.'
    je .nx
.roofed:
    test r15d, r15d
    jz .below_ok
    lea edi, [r12d-1]
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, ' '
    jne .nx
.below_ok:
    mov ebx, -1                         ; 3x3 of plain floor
.dy:
    cmp ebx, 1
    jg .found
    mov ecx, -1
.dx:
    cmp ecx, 1
    jg .ndy
    push rcx
    push rcx
    mov edi, r12d
    lea esi, [r13d+ecx]
    lea edx, [r14d+ebx]
    call cell_at
    pop rcx
    pop rcx
    cmp eax, ' '
    jne .nx
    inc ecx
    jmp .dx
.ndy:
    inc ebx
    jmp .dy
.found:
    mov [fo_x], r13d
    mov [fo_y], r14d
    mov eax, 1
    EPILOGUE
.nx:
    inc r13d
    jmp .x
.ny:
    inc r14d
    jmp .y
.none:
    xor eax, eax
    EPILOGUE

; hook_fling_up(edi = floor) -- stand on open floor, hook the ceiling, fling
hook_fling_up:
    PROLOGUE 16
    mov edx, [fo_y]
    mov esi, [fo_x]
    call player_spawn
    mov dword [p_yaw], 0
    mov dword [p_pitch], __float32__(1.5)
    FLD xmm0, 0.05
    call hook_run
    mov eax, [p_y]
    mov [hr_maxy], eax
    mov [hr_miny], eax
    call hookshot_fire
    mov byte [keys_down+K_JUMP], 1
    FLD xmm0, 0.1
    call hook_run
    mov byte [keys_down+K_JUMP], 0
    FLD xmm0, 2.0
    call hook_run
    EPILOGUE

; oob_tests -- the hookshot can't take you through floors, ceilings or the roof
oob_tests:
    PROLOGUE 16
    mov dword [cfg_building], BLD_REAL
    call prepare_world
    call new_game
    mov dword [t_stun], __float32__(10000.0)
    ; the ground floor: fling up at the ceiling
    mov edi, 1
    xor esi, esi
    call find_open
    test eax, eax
    jz .none1
    mov edi, 1
    call hook_fling_up
    call player_floor
    mov edx, eax
    lea rdi, [st_oob_fling]
    mov esi, 1
    movss xmm0, [hr_maxy]
    FLD xmm1, 1.7
    addss xmm0, xmm1
    cvtss2sd xmm0, xmm0
    mov eax, 1
    call printf
    ; ...and hook the floor at your feet, over open basement
    mov edi, 1
    mov esi, 1
    call find_open
    test eax, eax
    jz .none1
    mov edi, 1
    mov esi, [fo_x]
    mov edx, [fo_y]
    call player_spawn
    mov dword [p_yaw], 0
    mov dword [p_pitch], __float32__(-1.3)
    FLD xmm0, 0.05
    call hook_run
    mov eax, [p_y]
    mov [hr_maxy], eax
    mov [hr_miny], eax
    call hookshot_fire
    FLD xmm0, 2.0
    call hook_run
    call player_floor
    mov edx, eax
    lea rdi, [st_oob_floor]
    mov esi, 1
    cvtss2sd xmm0, [hr_miny]
    mov eax, 1
    call printf
    ; the top floor: fling up at the roof
    mov edi, NF-1
    xor esi, esi
    call find_open
    test eax, eax
    jz .none2
    mov edi, NF-1
    call hook_fling_up
    lea rdi, [st_oob_roof]
    movss xmm0, [hr_maxy]
    FLD xmm1, 1.7
    addss xmm0, xmm1
    cvtss2sd xmm0, xmm0
    mov eax, 1
    call printf
    jmp .done
.none1:
    mov esi, 1
    jmp .none
.none2:
    mov esi, NF-1
.none:
    lea rdi, [st_oob_none]
    xor eax, eax
    call printf
.done:
    call hookshot_reset
    mov dword [p_mode], 0
    EPILOGUE

; dew_tests -- a can for you, a can for T
dew_tests:
    PROLOGUE 32
    mov dword [cfg_building], BLD_REAL
    call prepare_world
    call new_game
    lea rdi, [ach_flag]
    xor esi, esi
    mov edx, NACH*4
    call memset
    ; you: drink one, then sprint on an empty tank
    mov edi, IT_DEW
    call drop_item
    call interact
    movss xmm0, [p_dew]
    movss [rsp+0], xmm0
    mov dword [p_stamina], __float32__(0.05)
    mov byte [keys_down+K_SPRINT], 1
    mov byte [keys_down+K_FWD], 1
    FLD xmm0, 1.0
    call hook_run
    mov byte [keys_down+K_SPRINT], 0
    mov byte [keys_down+K_FWD], 0
    lea rdi, [st_dew_you]
    cvtss2sd xmm0, [rsp+0]
    cvtss2sd xmm1, [p_stamina]
    mov eax, 2
    call printf
    ; T: blind and deaf for the test, a can a few cells from where he stands
    mov eax, [cfg_t_vision]
    mov [rsp+8], eax
    mov eax, [cfg_t_hear]
    mov [rsp+12], eax
    mov dword [cfg_t_vision], 0
    mov dword [cfg_t_hear], 0
    xor ebx, ebx                        ; no other cans
.off:
    cmp ebx, [item_count]
    jge .offed
    imul eax, ebx, ITEM_SIZE
    cmp dword [items+rax+ITEM_KIND], IT_DEW
    jne .offn
    mov dword [items+rax+ITEM_ACTIVE], 0
.offn:
    inc ebx
    jmp .off
.offed:
    ; you: out of the way (in the corner wall, where T can't get a hunch)
    mov dword [p_x], __float32__(1.0)
    mov dword [p_z], __float32__(1.0)
    call start_node
    mov edi, eax
    call enemy_reset
    mov dword [t_stun], 0
    ; the first plain floor cell 4..7 steps from the start (on its storey)
    mov r13d, -7
.cy:
    cmp r13d, 7
    jg .placed
    mov r12d, -7
.cx:
    cmp r12d, 7
    jg .ncy
    mov eax, r12d
    cdq
    xor eax, edx
    sub eax, edx
    mov ecx, eax
    mov eax, r13d
    cdq
    xor eax, edx
    sub eax, edx
    add ecx, eax                        ; |dx| + |dy|
    cmp ecx, 4
    jl .ncx
    cmp ecx, 7
    jg .ncx
    mov [rsp+16], ecx
    mov edi, [start_f]
    mov esi, [start_x]
    add esi, r12d
    mov edx, [start_y]
    add edx, r13d
    call cell_at
    cmp eax, ' '
    jne .ncx
    mov edi, [start_f]
    mov esi, [start_x]
    add esi, r12d
    mov edx, [start_y]
    add edx, r13d
    call cell_index
    mov esi, eax
    mov edi, IT_DEW
    call add_item
    jmp .placed
.ncx:
    inc r12d
    jmp .cx
.ncy:
    inc r13d
    jmp .cy
.placed:
    mov eax, [item_count]
    dec eax
    imul eax, eax, ITEM_SIZE
    lea r14, [items+rax]
    xor ebx, ebx
.walk:
    cmp ebx, 900
    jge .walked
    movss xmm0, [c_dt_shot]
    call enemy_update
    movss xmm0, [c_dt_shot]
    call dew_tick
    inc ebx
    movss xmm0, [t_dew]
    comiss xmm0, [c_zero]
    jbe .walk
.walked:
    cvtsi2ss xmm0, ebx
    mulss xmm0, [c_dt_shot]
    cvtss2sd xmm0, xmm0
    cvtss2sd xmm1, [t_dew]
    xor ecx, ecx
    cmp dword [r14+ITEM_ACTIVE], 0
    sete cl
    lea rdi, [st_dew_t]
    mov esi, [rsp+16]
    mov edx, ecx
    mov eax, 2
    call printf
    mov eax, [rsp+8]
    mov [cfg_t_vision], eax
    mov eax, [rsp+12]
    mov [cfg_t_hear], eax
    mov dword [p_dew], 0
    mov dword [t_dew], 0
    lea rdi, [ach_flag]
    xor esi, esi
    mov edx, NACH*4
    call memset
    EPILOGUE

; fd_run(xmm0 = seconds max, edi = stop when: 0 it robs you, 1 it's stashed)
; -> xmm0 = seconds it took
fd_run:
    PROLOGUE 16
    FLD xmm1, 60.0
    mulss xmm0, xmm1
    cvttss2si r12d, xmm0
    mov r13d, edi
    xor ebx, ebx
.f:
    cmp ebx, r12d
    jge .out
    movss xmm0, [c_dt_shot]
    call feeders_update
    inc ebx
    test r13d, r13d
    jnz .stash
    cmp dword [fd_carry], 0
    jne .out
    jmp .f
.stash:
    cmp dword [fd_carry], 0
    je .out
    jmp .f
.out:
    cvtsi2ss xmm0, ebx
    mulss xmm0, [c_dt_shot]
    EPILOGUE

; fd_setup -- you on open floor with 2 captures, one bottom feeder beside you
fd_setup:
    PROLOGUE 16
    mov edi, 1
    xor esi, esi
    call find_open
    mov edi, 1
    mov esi, [fo_x]
    mov edx, [fo_y]
    call player_spawn
    mov dword [inventory], 2
    mov dword [fd_count], 1
    mov edi, 1
    mov esi, [fo_x]
    inc esi
    mov edx, [fo_y]
    inc edx
    call cell_index
    mov esi, eax
    xor edi, edi
    call feeder_put
    EPILOGUE

; count_keys -> eax = capture items lying about
count_keys:
    xor eax, eax
    xor ecx, ecx
.k:
    cmp ecx, [item_count]
    jge .done
    imul edx, ecx, ITEM_SIZE
    cmp dword [items+rdx+ITEM_ACTIVE], 0
    je .n
    cmp dword [items+rdx+ITEM_KIND], IT_KEY
    jne .n
    inc eax
.n:
    inc ecx
    jmp .k
.done:
    ret

; feeder_tests -- robbed, the stash, catching the thief, the deauth, and
; being left alone when you carry nothing
feeder_tests:
    PROLOGUE 32
    mov dword [cfg_building], BLD_REAL
    call prepare_world
    call new_game
    mov dword [t_stun], __float32__(10000.0)
    lea rdi, [ach_flag]
    xor esi, esi
    mov edx, NACH*4
    call memset
    ; robbed
    call fd_setup
    call count_keys
    mov [rsp+8], eax
    FLD xmm0, 10.0
    xor edi, edi
    call fd_run
    cvtss2sd xmm0, xmm0
    lea rdi, [st_fd_steal]
    mov esi, [inventory]
    mov edx, [fd_carry]
    mov eax, 1
    call printf
    ; ...it runs off and hides it
    FLD xmm0, 90.0
    mov edi, 1
    call fd_run
    movss [rsp+0], xmm0
    movss xmm0, [fd_x]
    subss xmm0, [p_x]
    mulss xmm0, xmm0
    movss xmm1, [fd_z]
    subss xmm1, [p_z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [fd_y]
    subss xmm1, [p_y]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm1, xmm0
    call count_keys
    sub eax, [rsp+8]
    mov ecx, eax
    lea rdi, [st_fd_stash]
    cvtss2sd xmm0, [rsp+0]
    cvtss2sd xmm1, xmm1
    mov esi, [fd_carry]
    mov edx, ecx
    mov eax, 2
    call printf
    ; robbed again -- and you grab it before it gets away
    call fd_setup
    FLD xmm0, 10.0
    xor edi, edi
    call fd_run
    FLD xmm0, 1.0                       ; (it gets a moment's head start)
    mov edi, 1
    call fd_run
    mov eax, [fd_x]
    mov [p_x], eax
    mov eax, [fd_z]
    mov [p_z], eax
    movss xmm0, [c_dt_shot]
    call feeders_update
    lea rdi, [st_fd_back]
    mov esi, [inventory]
    mov edx, [ach_flag+ACH_OUTFED*4]
    xor eax, eax
    call printf
    ; robbed again -- and you deauth it
    call fd_setup
    FLD xmm0, 10.0
    xor edi, edi
    call fd_run
    call count_keys
    mov [rsp+8], eax
    ; aim: yaw = atan2(-dx, -dz), pitch = atan2(dy, flat)
    movss xmm0, [p_y]
    FLD xmm1, 1.55
    addss xmm0, xmm1
    movss [p_eye_y], xmm0
    movss xmm0, [fd_x]
    subss xmm0, [p_x]
    xorps xmm0, [c_sign_mask]
    movss xmm1, [fd_z]
    subss xmm1, [p_z]
    xorps xmm1, [c_sign_mask]
    movss [rsp+16], xmm0
    movss [rsp+20], xmm1
    call atan2f
    movss [rsp+24], xmm0                ; the yaw that looks at it
    movss xmm0, [rsp+16]
    mulss xmm0, xmm0
    movss xmm1, [rsp+20]
    mulss xmm1, xmm1
    addss xmm1, xmm0
    sqrtss xmm1, xmm1
    movss xmm0, [fd_y]
    FLD xmm2, 0.35
    addss xmm0, xmm2
    subss xmm0, [p_eye_y]
    call atan2f
    movss [p_pitch], xmm0
    ; first facing the other way: the packet would be T's
    movss xmm0, [rsp+24]
    FLD xmm1, 3.14159
    addss xmm0, xmm1
    movss [p_yaw], xmm0
    call feeders_deauth
    mov [rsp+28], eax
    lea rdi, [st_fd_away]
    mov esi, eax
    xor edx, edx
    cmp dword [fd_state], 4
    sete dl
    xor eax, eax
    call printf
    ; then right at it
    mov eax, [rsp+24]
    mov [p_yaw], eax
    call feeders_deauth
    mov [rsp+28], eax
    call count_keys
    sub eax, [rsp+8]
    mov r8d, eax
    xor edx, edx
    cmp dword [fd_state], 4
    sete dl
    lea rdi, [st_fd_deauth]
    mov esi, [rsp+28]
    mov ecx, [fd_carry]
    xor eax, eax
    call printf
    ; nothing on you: it doesn't care
    call fd_setup
    mov dword [inventory], 0
    xor r12d, r12d
    xor ebx, ebx
.calm:
    cmp ebx, 300
    jge .calmed
    movss xmm0, [c_dt_shot]
    call feeders_update
    cmp dword [fd_state], 1
    jne .nc
    mov r12d, 1
.nc:
    inc ebx
    jmp .calm
.calmed:
    lea rdi, [st_fd_ignore]
    mov esi, [inventory]
    mov edx, r12d
    xor eax, eax
    call printf
    lea rdi, [ach_flag]
    xor esi, esi
    mov edx, NACH*4
    call memset
    mov dword [fd_count], 0
    EPILOGUE

; grod_tests -- the packet of Grod, Tyler armed, the cannon firing at T
grod_tests:
    PROLOGUE 32
    mov dword [cfg_building], BLD_REAL
    call prepare_world
    call new_game
    lea rdi, [ach_flag]
    xor esi, esi
    mov edx, NACH*4
    call memset
    ; walk up to the packet weapon and take it
    xor ebx, ebx
.g:
    cmp ebx, [item_count]
    jge .found
    imul eax, ebx, ITEM_SIZE
    cmp dword [items+rax+ITEM_KIND], IT_GROD
    je .found
    inc ebx
    jmp .g
.found:
    imul eax, ebx, ITEM_SIZE
    mov ecx, [items+rax+ITEM_X]
    mov [p_x], ecx
    mov ecx, [items+rax+ITEM_Y]
    mov [p_y], ecx
    mov ecx, [items+rax+ITEM_Z]
    mov [p_z], ecx
    call interact
    xor edi, edi
    call use_special                    ; (not worthy)
    lea rdi, [st_grod_pick]
    mov esi, [have_grod]
    mov edx, [special]
    xor eax, eax
    call printf
    ; to Tyler
    movss xmm0, [tyler_x]
    FLD xmm1, 0.6
    addss xmm0, xmm1
    movss [p_x], xmm0
    mov eax, [tyler_y]
    mov [p_y], eax
    mov eax, [tyler_z]
    mov [p_z], eax
    call interact
    lea rdi, [st_grod_arm]
    mov esi, [tyler_armed]
    mov edx, [have_grod]
    mov ecx, [ach_flag+ACH_WORTHY*4]
    xor eax, eax
    call printf
    ; T comes by
    movss xmm0, [tyler_x]
    movss xmm1, [tyler_y]
    movss xmm2, [tyler_z]
    call node_at_pos
    mov [rsp+0], eax
    mov edi, eax
    call enemy_reset
    mov dword [t_stun], 0
    movss xmm0, [c_dt_shot]
    call grod_tick
    xor esi, esi
    movss xmm0, [t_stun]
    comiss xmm0, [c_zero]
    seta sil
    movss xmm0, [t_x]
    subss xmm0, [tyler_x]
    mulss xmm0, xmm0
    movss xmm1, [t_z]
    subss xmm1, [tyler_z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [t_y]
    subss xmm1, [tyler_y]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    cvtss2sd xmm0, xmm0
    cvtss2sd xmm1, [grod_cd]
    lea rdi, [st_grod_fire]
    mov eax, 2
    call printf
    ; straight back: still recharging
    mov edi, [rsp+0]
    call enemy_reset
    mov dword [t_stun], 0
    movss xmm0, [c_dt_shot]
    call grod_tick
    xor esi, esi
    movss xmm0, [t_stun]
    comiss xmm0, [c_zero]
    seta sil
    lea rdi, [st_grod_cd]
    xor eax, eax
    call printf
    lea rdi, [ach_flag]
    xor esi, esi
    mov edx, NACH*4
    call memset
    mov dword [tyler_armed], 0
    EPILOGUE

; cells_apart(edi = node a, esi = node b) -> eax = |dx|+|dy|+12|df| (grid nodes)
cells_apart:
    PROLOGUE 16
    mov eax, edi
    xor edx, edx
    mov ecx, MAP_W
    div ecx
    mov r12d, edx                       ; ax
    xor edx, edx
    mov ecx, MAP_H
    div ecx
    mov r13d, eax                       ; af
    mov r14d, edx                       ; ay
    mov eax, esi
    xor edx, edx
    mov ecx, MAP_W
    div ecx
    sub r12d, edx
    xor edx, edx
    mov ecx, MAP_H
    div ecx
    sub r13d, eax
    sub r14d, edx
    mov eax, r12d
    cdq
    xor eax, edx
    sub eax, edx
    mov ebx, eax
    mov eax, r14d
    cdq
    xor eax, edx
    sub eax, edx
    add ebx, eax
    mov eax, r13d
    cdq
    xor eax, edx
    sub eax, edx
    imul eax, eax, 12
    add eax, ebx
    EPILOGUE

; find_cell(edi = char, esi = neighbour char at x+1) -> eax 1, fo_f/fo_x/fo_y
find_cell:
    PROLOGUE 16
    mov [rsp+0], edi
    mov [rsp+4], esi
    xor r12d, r12d
.f:
    cmp r12d, NF
    jge .none
    xor r14d, r14d
.y:
    cmp r14d, MAP_H
    jge .nf
    xor r13d, r13d
.x:
    cmp r13d, MAP_W-1
    jge .ny
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, [rsp+0]
    jne .nx
    mov edi, r12d
    lea esi, [r13d+1]
    mov edx, r14d
    call cell_at
    cmp eax, [rsp+4]
    jne .nx
    mov [fo_f], r12d
    mov [fo_x], r13d
    mov [fo_y], r14d
    mov eax, 1
    EPILOGUE
.nx:
    inc r13d
    jmp .x
.ny:
    inc r14d
    jmp .y
.nf:
    inc r12d
    jmp .f
.none:
    xor eax, eax
    EPILOGUE

; t_run(xmm0 = seconds, edi = stop when: 0 caught, 1 t_build >= 2) -> xmm0
; seconds taken; r14d (callee's) = highest t_build seen -> [bld_max]
t_run:
    PROLOGUE 16
    FLD xmm1, 60.0
    mulss xmm0, xmm1
    cvttss2si r12d, xmm0
    mov r13d, edi
    xor ebx, ebx
.f:
    cmp ebx, r12d
    jge .out
    movss xmm0, [c_dt_shot]
    call enemy_update
    inc ebx
    mov eax, [t_build]
    cmp eax, [bld_max]
    jle .m
    mov [bld_max], eax
.m:
    test r13d, r13d
    jnz .up
    cmp dword [t_caught], 0
    jne .out
    jmp .f
.up:
    cmp dword [t_build], 2
    jge .out
    jmp .f
.out:
    cvtsi2ss xmm0, ebx
    mulss xmm0, [c_dt_shot]
    EPILOGUE

; perch_setup -- you on a tall crate stack in the basement, T chasing below
perch_setup:
    PROLOGUE 16
    call director_reset
    mov edi, 'K'
    mov esi, ' '
    call find_cell
    mov edi, [fo_f]
    mov esi, [fo_x]
    mov edx, [fo_y]
    call player_spawn
    movss xmm0, [p_y]
    FLD xmm1, 2.3
    addss xmm0, xmm1
    movss [p_y], xmm0
    FLD xmm0, 0.6                       ; drop onto the stack
    call hook_run
    mov edi, [fo_f]
    mov esi, [fo_x]
    inc esi
    mov edx, [fo_y]
    call cell_index
    mov edi, eax
    call enemy_reset
    mov dword [t_stun], 0
    mov dword [t_state], T_CHASE
    mov dword [bld_max], 0
    EPILOGUE

; balance_tests -- the director, T building, portals, the hookshot's clank,
; the nemesis
balance_tests:
    PROLOGUE 48
    mov dword [cfg_building], BLD_REAL
    call prepare_world
    call new_game
    call nemesis_forget
    mov dword [fd_count], 0
    mov eax, [cfg_t_vision]
    mov [rsp+32], eax
    mov eax, [cfg_t_hear]
    mov [rsp+36], eax
    ; ---- the director's nudge: blind, deaf T far off, you comfortable
    mov dword [cfg_t_vision], 0
    mov dword [cfg_t_hear], 0
    call start_node
    mov [rsp+0], eax
    mov edi, eax
    call far_spawn_node
    mov edi, eax
    call enemy_reset
    call director_reset
    mov dword [dir_calm], __float32__(41.0)
    movss xmm0, [c_dt_shot]
    call enemy_update
    movss xmm0, [p_x]
    movss xmm1, [p_y]
    movss xmm2, [p_z]
    call node_at_pos
    xor edx, edx
    cmp eax, [t_goal]
    sete dl
    xor esi, esi
    cmp dword [t_state], T_INVESTIGATE
    sete sil
    lea rdi, [st_dir_push]
    xor eax, eax
    call printf
    ; ---- ...and backing off after a close call: T right by you
    mov edi, [rsp+0]
    call enemy_reset
    call director_reset
    mov dword [dir_relax], __float32__(10.0)
    movss xmm0, [c_dt_shot]
    call enemy_update
    mov edi, [t_goal]
    mov esi, [rsp+0]
    call cells_apart
    lea rdi, [st_dir_relax]
    mov esi, eax
    xor eax, eax
    call printf
    mov eax, [rsp+32]
    mov [cfg_t_vision], eax
    mov eax, [rsp+36]
    mov [cfg_t_hear], eax
    ; ---- T builds up to your perch and gets you
    call perch_setup
    FLD xmm0, 12.0
    xor edi, edi
    call t_run
    movss [rsp+4], xmm0
    xor edx, edx
    cmp dword [bld_max], 1
    setge dl
    xor ecx, ecx
    cmp dword [bld_max], 2
    setge cl
    lea rdi, [st_bld]
    cvtss2sd xmm0, [p_y]
    mov esi, edx
    mov edx, ecx
    mov ecx, [t_caught]
    cvtss2sd xmm1, [rsp+4]
    mov eax, 2
    call printf
    ; ---- knock them down while he climbs
    call perch_setup
    FLD xmm0, 12.0
    mov edi, 1
    call t_run
    FLD xmm0, 0.2
    movss xmm0, [c_dt_shot]
    call enemy_update                   ; (a step up the stairs)
    mov edi, 1
    call build_break
    xor esi, esi
    movss xmm0, [t_y]
    ucomiss xmm0, [bld_ay]
    sete sil
    xor edx, edx
    movss xmm0, [t_stun]
    comiss xmm0, [c_zero]
    seta dl
    xor ecx, ecx
    cmp dword [bld_on], 0
    sete cl
    lea rdi, [st_bld_brk]
    xor eax, eax
    call printf
    ; ---- aim a deauth at the stairs; the hookshot's test point
    call perch_setup
    mov dword [bld_cd], 0
    movss xmm0, [c_dt_shot]
    call enemy_update                   ; (he starts building)
    ; stand back and look at the middle of the stairs
    movss xmm0, [bld_ax]
    addss xmm0, [bld_bx]
    mulss xmm0, [c_half]
    movss [rsp+8], xmm0
    movss xmm0, [bld_ay]
    addss xmm0, [bld_by]
    mulss xmm0, [c_half]
    movss [rsp+12], xmm0
    movss xmm0, [bld_az]
    addss xmm0, [bld_bz]
    mulss xmm0, [c_half]
    movss [rsp+16], xmm0
    movss xmm0, [rsp+8]
    movss xmm1, [rsp+12]
    movss xmm2, [rsp+16]
    call build_hit_point
    mov [rsp+20], eax
    movss xmm0, [rsp+8]
    FLD xmm3, 3.0
    addss xmm0, xmm3
    movss xmm1, [rsp+12]
    movss xmm2, [rsp+16]
    call build_hit_point
    mov [rsp+24], eax
    ; you: on the crate top already (perch_setup), crouched (a basement
    ; crate stack puts a standing head in the ceiling); look at the middle
    movss xmm0, [p_y]
    FLD xmm1, 1.0
    addss xmm0, xmm1
    movss [p_eye_y], xmm0
    movss xmm0, [rsp+8]
    subss xmm0, [p_x]
    xorps xmm0, [c_sign_mask]
    movss xmm1, [rsp+16]
    subss xmm1, [p_z]
    xorps xmm1, [c_sign_mask]
    movss [rsp+28], xmm0
    movss [rsp+40], xmm1
    call atan2f
    movss [p_yaw], xmm0
    movss xmm0, [rsp+28]
    mulss xmm0, xmm0
    movss xmm1, [rsp+40]
    mulss xmm1, xmm1
    addss xmm1, xmm0
    sqrtss xmm1, xmm1
    movss xmm0, [rsp+12]
    subss xmm0, [p_eye_y]
    call atan2f
    movss [p_pitch], xmm0
    call build_deauth
    lea rdi, [st_bld_aim]
    mov esi, eax
    mov edx, [rsp+20]
    mov ecx, [rsp+24]
    xor eax, eax
    call printf
    ; ---- T through a portal after you: entry a few cells from him, exit far
    mov dword [cfg_t_vision], 0
    mov edi, [rsp+0]
    call enemy_reset
    call director_reset
    mov dword [t_state], T_CHASE
    mov edi, [rsp+0]
    call far_spawn_node
    mov [rsp+4], eax
    mov edi, [start_f]
    mov esi, [start_x]
    mov edx, [start_y]
    call find_near_open
    mov edi, eax
    call node_center
    movss [rsp+8], xmm0
    movss [rsp+12], xmm1
    movss [rsp+16], xmm2
    mov edi, [rsp+4]
    call node_center
    movss [rsp+20], xmm0
    movss [rsp+24], xmm1
    movss [rsp+28], xmm2
    movaps xmm3, xmm0
    movaps xmm4, xmm1
    movaps xmm5, xmm2
    movss xmm0, [rsp+8]
    movss xmm1, [rsp+12]
    movss xmm2, [rsp+16]
    call enemy_portal_follow
    xor ebx, ebx
.por:
    cmp ebx, 600
    jge .por_done
    movss xmm0, [c_dt_shot]
    call enemy_update
    inc ebx
    mov eax, [t_node]
    cmp eax, [rsp+4]
    jne .por
.por_done:
    xor esi, esi
    mov eax, [t_node]
    cmp eax, [rsp+4]
    sete sil
    cvtsi2ss xmm0, ebx
    mulss xmm0, [c_dt_shot]
    cvtss2sd xmm0, xmm0
    lea rdi, [st_por_t]
    mov eax, 1
    call printf
    mov eax, [rsp+32]
    mov [cfg_t_vision], eax
    ; ---- no portals in safe rooms: stand in one, shoot its wall
    call portal_reset
    mov edi, 'S'
    mov esi, 'N'
    call find_cell
    mov edi, [fo_f]
    mov esi, [fo_x]
    mov edx, [fo_y]
    call player_spawn
    mov dword [p_yaw], __float32__(-1.5708)
    mov dword [p_pitch], 0
    FLD xmm0, 0.05
    call hook_run
    xor edi, edi
    call portal_fire
    lea rdi, [st_por_safe]
    mov esi, [por_on]
    xor eax, eax
    call printf
    ; ---- the hookshot's clank: T nearby but blind comes to look
    mov dword [cfg_t_vision], 0
    mov edi, 1
    mov esi, 26
    mov edx, 15
    call player_spawn
    mov dword [p_yaw], __float32__(-1.5708)
    mov dword [p_pitch], 0
    FLD xmm0, 0.05
    call hook_run
    mov edi, 1
    mov esi, 31
    mov edx, 13
    call find_near_open_at
    mov edi, eax
    call enemy_reset
    mov dword [p_mode], 0
    call hookshot_reset
    call hookshot_fire
    FLD xmm0, 0.3
    call hook_run
    xor esi, esi
    cmp dword [t_state], T_INVESTIGATE
    sete sil
    lea rdi, [st_hook_hear]
    xor eax, eax
    call printf
    call hookshot_reset
    mov dword [p_mode], 0
    mov eax, [rsp+32]
    mov [cfg_t_vision], eax
    ; ---- the nemesis learns
    call nemesis_forget
    mov r12d, 3
.esc:
    mov dword [t_caught], 0
    mov dword [t_state], T_CHASE
    call nemesis_tick
    xor edi, edi                        ; the hookshot...
    call nemesis_note
    mov dword [t_state], T_WANDER
    call nemesis_tick                   ; ...and he lost you
    mov dword [t_state], T_CHASE
    call nemesis_tick
    mov edi, 3                          ; a perch...
    call nemesis_note
    mov dword [t_state], T_WANDER
    call nemesis_tick
    dec r12d
    jnz .esc
    cvtss2sd xmm0, [nm_hook_hear]
    cvtss2sd xmm1, [nm_build_time]
    movsd [rsp+0], xmm0
    movsd [rsp+8], xmm1
    call nemesis_new_night              ; the next night: he's forgotten
    cvtss2sd xmm2, [nm_hook_hear]
    movsd xmm0, [rsp+0]
    movsd xmm1, [rsp+8]
    lea rdi, [st_nem]
    mov eax, 3
    call printf
    call nemesis_forget
    call director_reset
    EPILOGUE

; find_near_open(edi = f, esi = x, edx = y) -> eax = a plain-floor node 3..5
; cells from there (for the portal test) / find_near_open_at: the cell itself
; if it's plain floor, else the nearest one found the same way
find_near_open:
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov ebx, -5
.dy:
    cmp ebx, 5
    jg .fallback
    mov r15d, -5
.dx:
    cmp r15d, 5
    jg .ndy
    mov eax, ebx
    cdq
    xor eax, edx
    sub eax, edx
    mov ecx, eax
    mov eax, r15d
    cdq
    xor eax, edx
    sub eax, edx
    add ecx, eax
    cmp ecx, 3
    jl .ndx
    mov edi, r12d
    lea esi, [r13d+r15d]
    lea edx, [r14d+ebx]
    call cell_at
    cmp eax, ' '
    jne .ndx
    mov edi, r12d
    lea esi, [r13d+r15d]
    lea edx, [r14d+ebx]
    call cell_index
    EPILOGUE
.ndx:
    inc r15d
    jmp .dx
.ndy:
    inc ebx
    jmp .dy
.fallback:
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_index
    EPILOGUE
find_near_open_at:
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    call cell_at
    cmp eax, ' '
    jne .near
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_index
    EPILOGUE
.near:
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call find_near_open
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
    call hook_tests
    call oob_tests
    call dew_tests
    call feeder_tests
    call grod_tests
    call balance_tests
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
