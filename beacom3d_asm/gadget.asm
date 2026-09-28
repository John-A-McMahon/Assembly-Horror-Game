; =============================================================================
; gadget.asm -- the gadget system: every gadget is BASE + MODULE + FIRING TYPE.
;
; You don't find a portal gun or a hookshot any more. You carry a gun frame
; (the BASE) and find parts: MODULES (what phenomenon it controls) and
; FIRING TYPES (how that's delivered, and who it acts on). Snap any module
; into any firing type and you have a gadget. You carry ONE module and ONE
; firing type: pick up another part and the one it replaces is left lying
; where the new one was, so changing gadgets means deciding what to leave
; behind (and walking back for it). G opens the bench (and the catalog of
; what you've made).
;
;   bases         GUN     fires from your hand
;                 DRONE   fires from wherever you send it (V), the way you look
;   modules       PORTAL  bends space        ROD    a rigid rod
;                 LINE    a line that stays  SMOKE  smoke nobody sees through
;   firing types  LASER   straight, instant, precise
;                 ORB     lobbed in an arc; bounces, then goes off
;                 HOOK    bites the world and moves YOU
;                 GRABBER latches on to things and moves THEM
;
; The grammar is the code: each firing type is a DELIVERY (deliver_laser,
; deliver_orb, deliver_hook -> hookshot.asm, deliver_grab) that ends in an
; event -- a laser hit, an orb impact, a hook biting the world, a grabber
; latching on -- described by the hit record (hr_*: where, the surface
; normal, and what was hit: the world, T, a bottom feeder, an item, a prop,
; T's stairs). The event goes to the module's handler for that firing type
; (mod_handlers: one row of four per module). A module can take over a
; delivery completely (mod_deliver) when it needs to -- the remote grabber
; and the capture line do. So a new module is one row of handlers, and it
; immediately works with every firing type; a missing handler falls back to
; a generic one, so no combination is ever "invalid".
;
; What they make, the world keeps: lines (ziplines you can ride -- downhill,
; or winched up with a HOOKSHOT -- capture lines, tripwires, snares), smoke
; clouds (line_of_sight_3d asks smoke_blocks, so T, the bottom feeders and
; your own aim all go blind in it), pegs (platforms you can mantle onto).
; The rest of the game asks gd_caps (CAP_PORTAL, CAP_GRAPPLE, ...) instead of
; checking for a particular gadget.
;
; Runs: a hidden handful of parts per night (Custom run: how many of each),
; chosen by the seed. A safe room's networking magic lets you TRANSMUTE one
; part into one you haven't got, so a bad roll never ruins a night.
; =============================================================================
%define MODULE_GADGET
%include "common.inc"

global gadget_reset, gadget_new_run, gadget_update, gadget_fire, gadget_take, gadget_key
global gadget_wheel, gadget_hook_attach, gadget_draw, gadget_draw_glow, gadget_hud
global gadget_part_tex, gadget_init, gadget_load, gadget_select, gadget_give_all
global gadget_draw_smoke, smoke_blocks, gadget_line, gadget_smoke, gadget_count_known
global gd_have, gd_base, gd_mod, gd_fire, gd_caps, gd_bag_mod, gd_bag_fire, gd_known
global gd_bench, gd_fire_held, gd_roll_n, gd_roll_kind, gd_roll_id, gd_view, gd_tip_col
global gd_cool, gd_orb_on, gd_orb_x, gd_orb_y, gd_orb_z, gd_tt_state, gd_charge
global sm_count, ln_type, gd_last_combo, ln_ax, ln_ay, ln_az, ln_bx, ln_by, ln_bz
global gadget_transmute, fd_line, peg_n, rg_hits, dr_state, dr_x, dr_y, dr_z, gd_bag_base

extern p_vy, p_on_ground, parkour_try
extern build_hit_point, build_break
extern portal_fire, snd_hook_fire, snd_hook_hit, snd_hook_miss, snd_portal_open
extern snd_portal_fizzle, snd_portal_enter, snd_smoke, snd_gadget, snd_laser, snd_orb
extern snd_clank, snd_fanfare
extern phys_nb, px, py, pz, body_type, body_p0, body_np, body_active, physics_push
extern physics_move
extern make_plaque, font_label, bind, cbox, emit_tube, draw_text, draw_rect
extern fwrite, cam_x, cam_y, cam_z
extern font_hud, font_small, tt_w, tt_h
extern hookshot_fire_at, portal_fire_from

%define RGBC(r,g,b) (0xFF000000 | ((b)<<16) | ((g)<<8) | (r))
%define RGB(r,g,b) (0xFF000000 | ((b)<<16) | ((g)<<8) | (r))
%define COL_GOLD RGBC(255,215,90)
%define COL_INFO RGBC(216,212,200)
%define COL_WARN RGBC(255,179,71)
%define COL_GOOD RGBC(143,227,143)

; call a GL function that takes 4 float literals (as in render.asm)
%macro GLF4 5
    FLD xmm0, %2
    FLD xmm1, %3
    FLD xmm2, %4
    FLD xmm3, %5
    call %1
%endmacro

%define NFEED   4                       ; (feeders.asm)
%define FD_DEAD 4
%define MODE_WALK 0
%define MODE_ZIP  2
; the tether a GRABBER throws
%define TT_IDLE 0
%define TT_FLY  1
%define TT_REEL 2
%define TT_BACK 3
; what a trace / impact hit (hr_kind)
%define HT_NONE   0                     ; nothing in range
%define HT_WORLD  1                     ; a wall, floor, ceiling, desk...
%define HT_T      2
%define HT_FEEDER 3                     ; hr_idx = which
%define HT_ITEM   4                     ; hr_idx = byte offset into items
%define HT_PROP   5                     ; hr_idx = physics body
%define HT_STAIRS 6                     ; T's crate stairs
; trace flags
%define TR_CREATURES 1                  ; stop at T, feeders, T's stairs
%define TR_THINGS    2                  ; stop at items and props
; world objects
%define LN_FREE    0
%define LN_ZIP     1                    ; ride it (traverse.asm), zip_* slot
%define LN_CAPTURE 2                    ; snags feeders and items; they slide down it
%define LN_TRIP    3                    ; knee-high wire: trips and tells you
%define LN_SNARE   4                    ; a bola that missed: a loop on the floor
%define MAXLN   8
%define MAXSM   24
%define MAXPEG  6
%define MAXHELD 4
%define NPARTS  (NBASES+NMODS+NFIRES)
%define MAXROLL 12                      ; parts a night can hide

section .data
align 4
c_step      dd 0.1                      ; trace resolution
c_laser_r   dd 40.0
c_tether_r  dd 22.0
c_rg_r      dd 30.0                     ; remote grabber: where you can open a window
c_rg_reach  dd 6.0                      ; ...and how far the hand reaches out of it
c_cap_r     dd 25.0                     ; capture line
c_trip_max  dd 14.0                     ; tripwire: each way from you
c_fly       dd 45.0                     ; the grabber's head, out
c_reel      dd 12.0                     ; ...hauling something back
c_back      dd 60.0                     ; ...empty
c_orb_v     dd 13.0
c_orb_up    dd 1.5
c_orb_g     dd -14.0
c_orb_fuse  dd 2.5
c_orb_rest  dd 0.45
c_orb_fric  dd 0.75
c_orb_still dd 1.6
c_t_r2      dd 0.36                     ; (0.6 m)^2 round T's middle
c_t_h       dd 2.0
c_near_r2   dd 0.3                      ; feeders, items, props: ~0.55 m
c_fd_mid    dd 0.3
c_it_mid    dd 0.9
c_eye       dd 1.55
c_radius    dd 0.3
c_body      dd 1.7
c_knee      dd 0.35
c_hand_y    dd 0.35                     ; lines leave your hand this far below your eyes
c_zip_top   dd 2.7                      ; a zipline's top end, above your feet
c_zip_low   dd 2.3                      ; its low end at least this high off the floor
c_ceil_gap  dd 0.25
c_downhill  dd 0.3
c_line_life dd 30.0
c_forever   dd 1.0e9
c_snare_life dd 60.0
c_catch_fd  dd 0.9
c_catch_it  dd 0.8
c_snap_t    dd 0.8
c_trip_d    dd 0.6
c_snare_d   dd 0.9
c_slide     dd 2.5
c_hang_fd   dd 0.35
c_hang_it   dd 1.2
c_arrive    dd 1.0
c_stun_rod  dd 0.9
c_stun_heavy dd 1.4
c_stun_bola dd 2.5
c_stun_trip dd 1.6
c_stun_snare dd 3.0
c_stun_peg  dd 0.8
c_stun_slap dd 1.2
c_fd_knock  dd 3.0
c_fd_bola   dd 6.0
c_fd_haul   dd 3.0
c_fd_rg     dd 4.0
c_clank_r   dd 26.0                     ; T hears the knocker's clank this far
c_orb_heard dd 9.0                      ; ...and an orb landing
c_bola_r    dd 2.5
c_smoke_g   dd 3.2                      ; grenade
c_smoke_gl  dd 14.0
c_smoke_w   dd 1.5                      ; a puff of a smoke wall
c_smoke_wl  dd 10.0
c_smoke_w0  dd 1.5
c_smoke_ws  dd 1.8
c_smoke_h   dd 1.3                      ; the hood (follows its target)
c_smoke_hl  dd 7.0
c_smoke_t   dd 2.4                      ; smoke trail
c_smoke_tl  dd 11.0
c_smoke_x   dd 2.0                      ; smoke on nothing
c_smoke_xl  dd 9.0
c_grow      dd 0.6                      ; a cloud takes this long to bloom
c_fade      dd 1.5
c_block     dd 0.85                     ; a cloud blocks sight within this much of its radius
c_peg_out   dd 0.8
c_peg_half  dd 0.5
c_peg_thick dd 0.12
c_post_half dd 0.3
c_post_h    dd 1.0
c_rg_show   dd 1.2
c_rg_arm    dd 0.4
c_beam_t    dd 0.12
c_noise_fire dd 0.05
c_noise_orb dd 0.08
c_noise_blink dd 0.1
c_pull_push dd 8.0
c_dr_fwd    dd 1.0                      ; the drone at your shoulder: ahead,
c_dr_side   dd 0.62                     ; ...to the right,
c_dr_up     dd 0.42                     ; ...and up, at the corner of your eye
c_dr_range  dd 20.0                     ; how far you can send it
c_dr_short  dd 0.8                      ; it stops this far short of a wall
c_dr_min    dd 1.0
c_dr_speed  dd 14.0
c_dr_back   dd 18.0
c_dr_fall   dd 6.0
c_dr_swat2  dd 2.25                     ; (1.5 m)^2: T's reach
c_dr_swat_h dd 2.6
c_dr_down   dd 8.0                      ; rebooting
c_dr_rest   dd 0.05
c_dr_heard  dd 7.0                      ; T hears a shot from the drone this far
c_knock_v   dd 9.0
c_lift      dd 2.0

; ---- the parts ------------------------------------------------------------------
pb0         db "GUN",0
pb1         db "DRONE",0
pm0         db "PORTAL",0
pm1         db "ROD",0
pm2         db "LINE",0
pm3         db "SMOKE",0
pf0         db "LASER",0
pf1         db "ORB",0
pf2         db "HOOK",0
pf3         db "GRABBER",0
align 8
part_names  dq pb0, pb1, pm0, pm1, pm2, pm3, pf0, pf1, pf2, pf3
bdesc0      db "GUN frame: it fires from your hand.",0
bdesc1      db "DRONE frame: V sends it off to hover; it fires the way you look, from wherever it is.",0
align 8
base_desc   dq bdesc0, bdesc1
base_col    dd 0x9AA0A8, 0x58C8E0
; what a part means, said when you find it
mdesc0      db "PORTAL module: it bends space. Whatever carries it moves things through it.",0
mdesc1      db "ROD module: a rigid rod. It rams, props, pins and hauls.",0
mdesc2      db "LINE module: a line that stays wherever you string it.",0
mdesc3      db "SMOKE module: smoke that nothing can see through -- not T, not the feeders.",0
fdesc0      db "LASER firing type: dead straight, instant, precise.",0
fdesc1      db "ORB firing type: lobbed in an arc. It bounces, then goes off.",0
fdesc2      db "HOOK firing type: bites into the world and moves YOU.",0
fdesc3      db "GRABBER firing type: latches on to things and moves THEM.",0
align 8
mod_desc    dq mdesc0, mdesc1, mdesc2, mdesc3
fire_desc   dq fdesc0, fdesc1, fdesc2, fdesc3
; colours (0xRRGGBB): a module tints the gadget, a firing type its plaque
mod_col     dd 0x40A0FF, 0xC9A94A, 0xE8402C, 0xB8B8B8
fire_col    dd 0xFF4868, 0x70F0A0, 0x80C050, 0xFFB030
; an orb carrying this module sticks where it first hits (a rod digs in)
mod_sticky  dd 0, 1, 0, 0
; capabilities: from the module, from the firing type, and from the pair
mod_caps    dd CAP_PORTAL, 0, CAP_LINE, CAP_SMOKE
fire_caps   dd 0, 0, CAP_GRAPPLE, CAP_REMOTE
;               laser       orb           hook          grab
combo_caps  dd 0,          CAP_TELEPORT, CAP_TELEPORT, 0            ; portal
            dd CAP_REMOTE, 0,            CAP_WINCH,    0            ; rod
            dd 0,          0,            0,            0            ; line
            dd 0,          0,            0,            0            ; smoke
; seconds between shots
combo_cd    dd 0.25, 3.0, 2.5, 5.0
            dd 1.2,  1.0, 0.3, 0.8
            dd 1.0,  2.0, 1.0, 1.5
            dd 4.0,  2.5, 3.0, 4.0
c_cd_default dd 1.0

; ---- the catalog: curated names for the gun's combinations -------------------
cn00 db "PORTAL GUN",0
cn01 db "ENDER ORB",0
cn02 db "BLINK HOOK",0
cn03 db "REMOTE GRABBER",0
cn10 db "KNOCKER",0
cn11 db "PEG LAUNCHER",0
cn12 db "HOOKSHOT",0
cn13 db "GRAPPLER",0
cn20 db "TRIPWIRE",0
cn21 db "BOLA",0
cn22 db "ZIPLINE GUN",0
cn23 db "CAPTURE LINE",0
cn30 db "SMOKE WALL",0
cn31 db "SMOKE GRENADE",0
cn32 db "SMOKE TRAIL",0
cn33 db "SMOKE HOOD",0
cd00 db "Laser-straight portals on walls: left click blue, right click orange. Walk in one, out the other.",0
cd01 db "Lob it. Wherever it comes to rest, that's where you are.",0
cd02 db "Hook a surface and blink straight to it -- no haul, no chain to follow.",0
cd03 db "Opens a window on any surface in sight and reaches out of it for whatever's within 6 m.",0
cd10 db "A rod rams out: it staggers T and flattens feeders -- and a clank off a far wall draws T there.",0
cd11 db "Lobbed rods dig into walls and floors: instant ledges and steps to climb. T can't.",0
cd12 db "Bites and hauls you there. SPACE mid-pull flings you. On any zipline, hold fire to winch -- even uphill.",0
cd13 db "Latches on to things and hauls them to you: items, feeders, boxes. T is too heavy -- he just staggers.",0
cd20 db "Strings a knee-high wire wall to wall along your aim. It trips whatever crosses it and tells you.",0
cd21 db "Tangles whatever it lands by. A miss leaves a snare on the floor.",0
cd22 db "Strings a zipline from over your head to where it bites. Gravity rides it downhill; uphill needs a winch.",0
cd23 db "A line that snags feeders and items it passes -- they slide down it to its low end. T snaps it.",0
cd30 db "Lays a wall of smoke along the beam. Nothing sees through smoke.",0
cd31 db "Lob it: a cloud nobody can see into or out of.",0
cd32 db "Haul yourself out, leaving a trail of smoke behind you.",0
cd33 db "Wraps whatever it grabs in smoke that follows it. A hooded T only has his ears.",0
; ...and the drone's
dn00 db "PORTAL DRONE",0
dn01 db "ENDER DRONE",0
dn02 db "BLINK BEACON",0
dn03 db "WINDOW DRONE",0
dn10 db "KNOCKER DRONE",0
dn11 db "PEG BOMBER",0
dn12 db "TOW DRONE",0
dn13 db "FETCH DRONE",0
dn20 db "WIRE DRONE",0
dn21 db "BOLA BOMBER",0
dn22 db "SKYLINE",0
dn23 db "TRAWLER",0
dn30 db "SMOKESCREEN DRONE",0
dn31 db "CROP DUSTER",0
dn32 db "SMOKE TOW",0
dn33 db "HOODWINKER",0
dd00 db "Send it off (V), then click: portals the way you're looking, from wherever it hovers -- round corners, down the atrium.",0
dd01 db "It lobs the orb from where it hovers. You're wherever the orb comes to rest.",0
dd02 db "Park it anywhere (V). Fire, and you blink straight to it -- walls or no walls.",0
dd03 db "Opens a window where the drone is looking and reaches out of it for whatever's within 6 m.",0
dd10 db "Rams from where it hovers. T hears the clank -- and the drone -- not you. A lure you can aim.",0
dd11 db "Drops rods from above: ledges and steps wherever the drone can get to.",0
dd12 db "Park it (V) and fire: it hauls you to itself, as long as you can see it.",0
dd13 db "Latches on to things in front of the drone and reels them in to it. Items it reaches are yours.",0
dd20 db "Strings a tripwire through where the drone hovers, wall to wall the way you're facing.",0
dd21 db "Drops bolas from the drone: tangle T from somewhere he isn't looking.",0
dd22 db "Strings a zipline from over your head to the drone. Park it low and ride.",0
dd23 db "A capture line from the drone to where it's looking -- it snags feeders far from you.",0
dd30 db "Lays a smoke wall from the drone along your aim: cover where you aren't yet.",0
dd31 db "Lobs smoke from the drone: blind T from across the building.",0
dd32 db "Hauls you to the drone, leaving a trail of smoke behind you.",0
dd33 db "Hoods whatever the drone grabs in smoke that follows it.",0
align 8
combo_name  dq cn00, cn01, cn02, cn03, cn10, cn11, cn12, cn13
            dq cn20, cn21, cn22, cn23, cn30, cn31, cn32, cn33
            dq dn00, dn01, dn02, dn03, dn10, dn11, dn12, dn13
            dq dn20, dn21, dn22, dn23, dn30, dn31, dn32, dn33
combo_desc  dq cd00, cd01, cd02, cd03, cd10, cd11, cd12, cd13
            dq cd20, cd21, cd22, cd23, cd30, cd31, cd32, cd33
            dq dd00, dd01, dd02, dd03, dd10, dd11, dd12, dd13
            dq dd20, dd21, dd22, dd23, dd30, dd31, dd32, dd33
; generated wording for combinations nobody named (future modules/bases)
gv0 db "fires a beam that",0
gv1 db "lobs an orb that",0
gv2 db "bites the world and",0
gv3 db "grabs something and",0
ge0 db "bends space there",0
ge1 db "rams a rod into it",0
ge2 db "strings a line to it",0
ge3 db "smokes it out",0
align 8
gen_verb    dq gv0, gv1, gv2, gv3
gen_effect  dq ge0, ge1, ge2, ge3
fmt_gen_name db "%s %s",0
fmt_gen_desc db "It %s %s.",0

; ---- messages -------------------------------------------------------------------
fmt_found   db "Found a gadget part: %s",0
fmt_swap_m  db "%s  Your %s module is left lying here -- E to swap back.",0
fmt_swap_f  db "%s  Your %s firing type is left lying here -- E to swap back.",0
m_one_part  db "One frame, one module and one firing type at a time -- to change, swap yours for a part lying in the building (E).",0
fmt_swap_b  db "%s  Your %s frame is left lying here -- E to swap back.",0
m_dr_out    db "Drone out. It fires the way you're looking, from where it hovers -- and T hears it, not you. V calls it back.",0
m_dr_room   db "No room to send the drone that way.",0
m_dr_down   db "Your drone is rebooting on the floor -- give it a few seconds.",0
m_dr_swat   db "T swats your drone out of the air!",0
m_dr_sight  db "You can't see the drone -- the hook has nothing to bite.",0
fmt_new     db "NEW GADGET: %s -- %s",0
fmt_gadget  db "GADGET: %s",0
m_incomplete db "Your gun frame needs a MODULE and a FIRING TYPE -- find parts, then G for the bench.",0
m_no_parts  db "You haven't found a part to swap in yet.",0
m_charge    db "The safe room's networking magic hums over your gadget: open the bench (G) and press T to TRANSMUTE a part.",0
fmt_trans   db "TRANSMUTED: your %s became %s.",0
m_trans_none db "You already have every part of that kind.",0
m_trans_no  db "Transmuting needs a safe room's networking magic -- find one first.",0
m_heavy     db "T is too heavy to haul -- the grabber just yanks him off balance.",0
m_rod_t     db "The rod slams into T -- he reels back.",0
m_rod_fd    db "The rod flattens a bottom feeder.",0
m_clank     db "*CLANK* -- the sound carries from where the rod hit, not from you.",0
m_bola_t    db "The bola wraps round T's legs -- he's tangled!",0
m_bola_fd   db "The bola ties up a bottom feeder.",0
m_snare_set db "The bola misses -- it lies open on the floor as a snare.",0
m_snare_t   db "T stepped in your snare!",0
m_snare_fd  db "A bottom feeder stepped in your snare.",0
fmt_trip_t  db "*TWANG* -- T just tripped your wire on the %s!",0
fmt_trip_fd db "*twang* -- something small tripped your wire on the %s.",0
fmt_trip_set db "Tripwire strung, %d m wall to wall. You'll hear it if anything crosses.",0
m_trip_none db "Nothing within reach to tie the wire to -- aim along a hallway or across a room.",0
m_cap_t     db "T walks straight through your capture line and snaps it.",0
m_cap_fd    db "Your capture line snags a bottom feeder!",0
m_cap_none  db "Nothing to tie the line to.",0
m_zip_up    db "The line's strung -- but it runs uphill from here. Ride it from the top, or winch up it with a HOOKSHOT.",0
m_zip_bad   db "The line would cut through a wall -- no zipline.",0
m_safe_no   db "The safe room's networking magic scrambles it -- no portals in (or into) safe rooms.",0
m_blink_no  db "No room to blink there.",0
m_ender_no  db "The orb fizzles -- nowhere to stand there.",0
m_rg_none   db "The window opens -- nothing within reach of it.",0
m_rg_t      db "A hand shoots out of the wall and slaps T -- he staggers!",0
m_rg_fd     db "The grabber drags a bottom feeder through the window and drops it at your feet!",0
m_rg_no     db "Nothing there to open a window on.",0
m_hood_t    db "Smoke wraps round T's head -- he can't see a thing. He can still hear you.",0
m_grab_fd   db "The grabber latches on to a bottom feeder -- it drops what it was carrying.",0
m_grab_home db "The bottom feeder lands at your feet, dazed.",0
m_peg_no    db "The rod can't dig in there.",0
file_name   db "beacom_gadgets.cfg",0
mode_w      db "w",0
mode_r      db "r",0
fmt_save    db "known=%u",10,0
key_save    db "known="
; the bench
s_title     db "GADGET BENCH       BASE  +  MODULE  +  FIRING TYPE",0
s_col0      db "BASE",0
s_col1      db "MODULE",0
s_col2      db "FIRING TYPE",0
s_foot      db "A/D column   T transmute   G close        one of each kind: pick up a part (E) to swap it for yours",0
s_tm_on     db "A safe room's magic is on your gadget: T transmutes the selected part into one you don't have.",0
s_tm_off    db "Transmuting a part needs a safe room's networking magic.",0
s_unknown   db "? ? ?",0
s_incomplete db "GADGET: gun frame (needs parts -- G)",0
s_none_yet  db "(empty)",0
fmt_cat     db "CATALOG  %d of %d found -- a record of your experiments",0
s_hint_hud  db "E on a part: swap   G: bench",0
s_hint_drone db "V: send / call back the drone   E on a part: swap   G: bench",0

align 8
; handlers: per module, one per firing type -- the event its delivery raises
mod_handlers:
    dq portal_laser, portal_orb, portal_hook, portal_grab       ; PORTAL
    dq rod_laser,    rod_orb,    rod_hook,    rod_grab          ; ROD
    dq line_laser,   line_orb,   line_hook,   line_grab         ; LINE
    dq smoke_laser,  smoke_orb,  smoke_hook,  smoke_grab        ; SMOKE
; a module that takes over a delivery completely (0 = the usual delivery)
mod_deliver:
    dq portal_laser, 0,          0,           portal_grab
    dq 0,            0,          0,           0
    dq line_laser,   0,          0,           line_grab
    dq 0,            0,          0,           0
fire_delivery dq deliver_laser, deliver_orb, deliver_hook, deliver_grab
; generic handlers, for a module that has none for a firing type
fire_generic  dq generic_hit, generic_hit, generic_hook, generic_hit

section .bss
alignb 4
gd_have     resd 1                      ; you carry a base (the gun frame)
gd_base     resd 1
gd_mod      resd 1                      ; -1 = empty slot
gd_fire     resd 1
gd_caps     resd 1                      ; CAP_ bits of what's assembled
gd_bag_base resd 1                      ; bit per part you carry
gd_bag_mod  resd 1
gd_bag_fire resd 1
gd_known    resd 1                      ; the catalog: bit per combination, ever
gd_bench    resd 1                      ; the bench is open
gd_col      resd 1                      ; its column: 0 base, 1 module, 2 firing
gd_fire_held resd 1                     ; fire button held (winching)
gd_cool     resd 1
gd_charge   resd 1                      ; transmutations on offer (safe rooms)
gd_was_safe resd 1
gd_view     resd 1                      ; hands: 0 none, 1 gun, 2 hook shape
gd_tip_col  resd 1                      ; 0xRRGGBB of the gadget's glow
gd_last_combo resd 1                    ; -1, or the combination assembled
gd_told     resd 1                      ; one-off hints given this night (bits)
gd_clock    resd 1
gd_roll_n   resd 1                      ; parts new_game hides this night
gd_roll_kind resd MAXROLL
gd_roll_id  resd MAXROLL
; the drone
dr_state    resd 1
dr_x        resd 1
dr_y        resd 1
dr_z        resd 1
dr_tx       resd 1                      ; where it's flying (DOWN: the floor)
dr_ty       resd 1
dr_tz       resd 1
dr_hx       resd 1                      ; its spot at your shoulder
dr_hy       resd 1
dr_hz       resd 1
dr_t        resd 1                      ; rebooting
dr_told     resd 1
; where the base stands (your feet, or the floor under the drone)
gs_x        resd 1
gs_y        resd 1
gs_z        resd 1
; the hit record every delivery fills in
hr_x        resd 1
hr_y        resd 1
hr_z        resd 1
hr_nx       resd 1                      ; surface normal (axis aligned), 0 if none
hr_ny       resd 1
hr_nz       resd 1
hr_kind     resd 1
hr_idx      resd 1
hr_dist     resd 1
hr_button   resd 1
; aim: origin and direction
ao_x        resd 1
ao_y        resd 1
ao_z        resd 1
ad_x        resd 1
ad_y        resd 1
ad_z        resd 1
; your hand (where lines, beams and tethers start)
hd_x        resd 1
hd_y        resd 1
hd_z        resd 1
; the orb in flight
gd_orb_on   resd 1
gd_orb_x    resd 1
gd_orb_y    resd 1
gd_orb_z    resd 1
orb_vx      resd 1
orb_vy      resd 1
orb_vz      resd 1
orb_fuse    resd 1
orb_bounce  resd 1
orb_mod     resd 1
orb_nx      resd 1
orb_ny      resd 1
orb_nz      resd 1
; the grabber's tether
gd_tt_state resd 1
tt_hx       resd 1                      ; head
tt_hy       resd 1
tt_hz       resd 1
tt_sx       resd 1                      ; where it was thrown from
tt_sy       resd 1
tt_sz       resd 1
tt_dx       resd 1
tt_dy       resd 1
tt_dz       resd 1
tt_len      resd 1
tt_target   resd 1                      ; distance to what it'll latch on to
tt_kind     resd 1
tt_idx      resd 1
tt_mod      resd 1
tt_time     resd 1
; lines
ln_type     resd MAXLN
ln_ax       resd MAXLN
ln_ay       resd MAXLN
ln_az       resd MAXLN
ln_bx       resd MAXLN
ln_by       resd MAXLN
ln_bz       resd MAXLN
ln_life     resd MAXLN
ln_birth    resd MAXLN
ln_slot     resd MAXLN                  ; LN_ZIP: which of your zip slots
fd_line     resd NFEED                  ; feeder held on a capture line (-1)
fd_lt       resd NFEED                  ; ...and how far along it
hi_n        resd 1                      ; items held on capture lines
hi_item     resd MAXHELD
hi_line     resd MAXHELD
hi_t        resd MAXHELD
; smoke
sm_count    resd 1
sm_x        resd MAXSM
sm_y        resd MAXSM
sm_z        resd MAXSM
sm_r        resd MAXSM
sm_life     resd MAXSM
sm_life0    resd MAXSM
sm_att      resd MAXSM                  ; -1 still, 0 follows T, 1+i feeder i
; pegs
peg_n       resd 1
peg_next    resd 1
peg_plat    resd MAXPEG
; the remote grabber's window and arm, the laser's beam (for drawing)
rg_t        resd 1
rg_x        resd 1
rg_y        resd 1
rg_z        resd 1
rg_nx       resd 1
rg_ny       resd 1
rg_nz       resd 1
rg_arm      resd 1
rg_tx       resd 1
rg_ty       resd 1
rg_tz       resd 1
rg_hits     resd 1                      ; (self-tests) things the grabber took
lz_t        resd 1
lz_ax       resd 1
lz_ay       resd 1
lz_az       resd 1
lz_bx       resd 1
lz_by       resd 1
lz_bz       resd 1
lz_col      resd 1
; text for the bench and the HUD
part_tex    resd NPARTS
part_w      resd NPARTS
part_h      resd NPARTS
cn_tex      resd NCOMBOS                ; names (HUD font)
cn_w        resd NCOMBOS
cn_h        resd NCOMBOS
cs_tex      resd NCOMBOS                ; names (small, the catalog)
cs_w        resd NCOMBOS
cs_h        resd NCOMBOS
cd_tex      resd NCOMBOS                ; descriptions (wrapped)
cd_w        resd NCOMBOS
cd_h        resd NCOMBOS
gl_tex      resd NCOMBOS+1              ; "GADGET: NAME" (last: incomplete)
gl_w        resd NCOMBOS+1
gl_h        resd NCOMBOS+1
fx_tex      resd 10                     ; title, headers, footer, transmute, ???, hint
fx_w        resd 10
fx_h        resd 10
cat_tex     resd 1
cat_w       resd 1
cat_h       resd 1
cat_shown   resd 1
plq_tex     resd NMODS+NFIRES+NBASES    ; item plaques
name_buf    resb 64
desc_buf    resb 256
msg_buf     resb 512
file_buf    resb 64

section .text

; =============================================================================
; the grammar: names, capabilities, assembly
; =============================================================================

; combo_id -> eax = the combination assembled (or -1 if a slot's empty). leaf
combo_id:
    mov eax, -1
    cmp dword [gd_have], 0
    je .no
    mov ecx, [gd_mod]
    test ecx, ecx
    js .no
    mov edx, [gd_fire]
    test edx, edx
    js .no
    mov eax, [gd_base]
    imul eax, eax, NMODS
    add eax, ecx
    imul eax, eax, NFIRES
    add eax, edx
.no:
    ret

; combo_text(edi = combination) -> rax = name, rdx = description. The gun's
; combinations are named in the catalog tables; anything else (a base or
; module added later without a curated name) gets its name built from its
; parts: "SMOKE LASER" -- "It fires a beam that smokes it out."
combo_text:
    PROLOGUE 16
    mov ebx, edi
    cmp ebx, NCOMBOS
    jae .generate
    mov rax, [combo_name+rbx*8]
    test rax, rax
    jz .generate
    mov rdx, [combo_desc+rbx*8]
    EPILOGUE
.generate:
    mov eax, ebx
    xor edx, edx
    mov ecx, NFIRES
    div ecx
    mov r12d, edx                       ; firing type
    xor edx, edx
    mov ecx, NMODS
    div ecx
    mov r13d, edx                       ; module
    lea rdi, [name_buf]
    mov esi, 64
    lea rdx, [fmt_gen_name]
    mov rcx, [part_names+(NBASES)*8+r13*8]
    mov r8, [part_names+(NBASES+NMODS)*8+r12*8]
    xor eax, eax
    call snprintf
    lea rdi, [desc_buf]
    mov esi, 256
    lea rdx, [fmt_gen_desc]
    mov rcx, [gen_verb+r12*8]
    mov r8, [gen_effect+r13*8]
    xor eax, eax
    call snprintf
    lea rax, [name_buf]
    lea rdx, [desc_buf]
    EPILOGUE

; refresh -- work out what's assembled: capabilities, the hands' shape, the glow
refresh:
    call combo_id
    mov [gd_last_combo], eax
    xor ecx, ecx
    mov dword [gd_view], 0
    cmp dword [gd_have], 0
    je .caps
    mov dword [gd_view], 1
    mov dword [gd_tip_col], 0x505050    ; an empty frame: dull
    mov edx, [gd_mod]
    test edx, edx
    js .no_mod
    or ecx, [mod_caps+rdx*4]
    mov eax, [mod_col+rdx*4]
    mov [gd_tip_col], eax
.no_mod:
    mov edx, [gd_fire]
    test edx, edx
    js .caps
    or ecx, [fire_caps+rdx*4]
    cmp edx, GF_HOOK
    je .hook_shape
    cmp edx, GF_GRAB
    jne .combo
.hook_shape:
    mov dword [gd_view], 2
.combo:
    mov eax, [gd_last_combo]
    test eax, eax
    js .caps
    and eax, NMODS*NFIRES-1             ; (the same pair on any base)
    or ecx, [combo_caps+rax*4]
.caps:
    mov [gd_caps], ecx
    cmp dword [gd_base], GB_DRONE
    jne .ret
    mov dword [gd_view], 0              ; (a drone: nothing in your hands)
.ret:
    ret

; gadget_select(edi = module or -1, esi = firing type or -1) -- assemble.
; The first time a combination is made it goes in the catalog (and the save
; file) with its name and what it does; after that you just see its name.
gadget_select:
    PROLOGUE 16
    mov [gd_mod], edi
    mov [gd_fire], esi
    call refresh
    call snd_gadget
    mov ebx, [gd_last_combo]
    test ebx, ebx
    js .done
    cmp ebx, 32
    jae .done
    bt dword [gd_known], ebx
    jc .known
    bts dword [gd_known], ebx
    mov edi, ebx
    call combo_text
    mov rcx, rax
    mov r8, rdx
    lea rdi, [msg_buf]
    mov esi, 512
    lea rdx, [fmt_new]
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, COL_GOLD
    xor edx, edx
    call hud_message
    call snd_fanfare
    call gadget_save
    call gadget_count_known
    cmp eax, 8
    jl .done
    mov edi, ACH_TINKER
    call ach_unlock
    jmp .done
.known:
    mov edi, ebx
    call combo_text
    mov rcx, rax
    lea rdi, [msg_buf]
    mov esi, 512
    lea rdx, [fmt_gadget]
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, COL_INFO
    xor edx, edx
    call hud_message
.done:
    EPILOGUE

; gadget_count_known -> eax = combinations in the catalog
gadget_count_known:
    mov eax, [gd_known]
    popcnt eax, eax
    ret

; next_part(edi = mask, esi = current (-1 none), edx = count, ecx = +1/-1)
; -> eax = the next part in the mask after the current one, wrapping (the
; current one if it's the only one, -1 if the mask is empty). leaf
next_part:
    mov eax, -1
    test edi, edi
    jz .out
    mov r8d, esi
    mov r9d, edx                        ; tries left
.l:
    add r8d, ecx
    cmp r8d, edx
    jl .lo
    xor r8d, r8d
.lo:
    test r8d, r8d
    jns .hi
    lea r8d, [edx-1]
.hi:
    bt edi, r8d
    jc .got
    dec r9d
    jnz .l
    jmp .out
.got:
    mov eax, r8d
.out:
    ret

; set_base(edi = base) -- change frames, keeping the module and firing type
; (a drone that was out is simply packed away)
set_base:
    sub rsp, 8
    mov [gd_base], edi
    mov dword [dr_state], DR_HOME
    mov edi, [gd_mod]
    mov esi, [gd_fire]
    call gadget_select
    add rsp, 8
    ret

; cycle(edi = 0 base / 1 module / 2 firing type, esi = +1/-1) -- swap in the
; next part of that kind you carry
cycle:
    PROLOGUE 16
    mov ebx, edi
    mov ecx, esi
    cmp ebx, 1
    je .mod
    cmp ebx, 2
    je .fire
    mov edi, [gd_bag_base]
    mov esi, [gd_base]
    mov edx, NBASES
    call next_part
    test eax, eax
    js .none
    cmp eax, [gd_base]
    je .one
    mov edi, eax
    call set_base
    EPILOGUE
.mod:
    mov edi, [gd_bag_mod]
    mov esi, [gd_mod]
    mov edx, NMODS
    call next_part
    test eax, eax
    js .none
    cmp eax, [gd_mod]
    je .one
    mov edi, eax
    mov esi, [gd_fire]
    call gadget_select
    EPILOGUE
.fire:
    mov edi, [gd_bag_fire]
    mov esi, [gd_fire]
    mov edx, NFIRES
    call next_part
    test eax, eax
    js .none
    cmp eax, [gd_fire]
    je .one
    mov esi, eax
    mov edi, [gd_mod]
    call gadget_select
    EPILOGUE
.one:
    lea rdi, [m_one_part]
    jmp .say
.none:
    lea rdi, [m_no_parts]
.say:
    mov esi, COL_WARN
    xor edx, edx
    call hud_message
.done:
    EPILOGUE

; gadget_wheel(edi = wheel clicks, + or -) -- in play: the firing type; with
; the bench open: the selected column
gadget_wheel:
    PROLOGUE 16
    cmp dword [gd_have], 0
    je .done
    mov esi, 1
    test edi, edi
    jg .dir
    mov esi, -1
.dir:
    mov edi, 2
    cmp dword [gd_bench], 0
    je .go
    mov edi, [gd_col]
    test edi, edi
    jz .done
.go:
    call cycle
.done:
    EPILOGUE

; gadget_key(edi = scancode) -> eax 1 if the gadget used the key.
; V: the drone.  R: next module.  G: the bench.  With the bench open: A/D (or arrows) pick a
; column, W/S swap the part in it, T transmutes, G / Enter close it.
gadget_key:
    PROLOGUE 16
    mov ebx, edi
    cmp dword [gd_have], 0
    je .no
    cmp dword [gd_bench], 0
    jne .bench
    cmp ebx, 25                         ; V: send / call back the drone
    jne .not_v
    cmp dword [gd_base], GB_DRONE
    jne .no
    call drone_key
    jmp .yes
.not_v:
    cmp ebx, 21                         ; R
    jne .not_r
    mov edi, 1
    mov esi, 1
    call cycle
    jmp .yes
.not_r:
    cmp ebx, 10                         ; G
    jne .no
    mov dword [gd_bench], 1
    mov dword [gd_col], 1
    call snd_gadget
    jmp .yes
.bench:
    cmp ebx, 10                         ; G, Enter: close
    je .close
    cmp ebx, SC_RETURN
    je .close
    cmp ebx, SC_ESC
    je .close
    cmp ebx, SC_A
    je .left
    cmp ebx, SC_LEFT
    je .left
    cmp ebx, SC_D
    je .right
    cmp ebx, SC_RIGHT
    je .right
    cmp ebx, SC_W
    je .up
    cmp ebx, SC_UP
    je .up
    cmp ebx, SC_S
    je .down
    cmp ebx, SC_DOWN
    je .down
    cmp ebx, 23                         ; T
    jne .yes                            ; (the bench swallows the rest)
    call gadget_transmute
    jmp .yes
.close:
    mov dword [gd_bench], 0
    jmp .yes
.left:
    mov eax, [gd_col]
    dec eax
    jns .setcol
    mov eax, 2
    jmp .setcol
.right:
    mov eax, [gd_col]
    inc eax
    cmp eax, 3
    jl .setcol
    xor eax, eax
.setcol:
    mov [gd_col], eax
    jmp .yes
.up:
    mov esi, -1
    jmp .swap
.down:
    mov esi, 1
.swap:
    mov edi, [gd_col]
    call cycle
.yes:
    mov eax, 1
    EPILOGUE
.no:
    xor eax, eax
    EPILOGUE

; gadget_transmute -- (a safe room's gift) turn the selected column's part
; into a random one of that kind you don't have
gadget_transmute:
    PROLOGUE 32
    cmp dword [gd_charge], 0
    jne .have
    lea rdi, [m_trans_no]
    jmp .say
.have:
    ; r12 = bag, r13 = count, r14 = current
    mov eax, [gd_col]
    test eax, eax
    jnz .kind
    mov r12d, [gd_bag_base]
    mov r13d, NBASES
    mov r14d, [gd_base]
    jmp .pick
.kind:
    cmp eax, 1
    jne .fires
    mov r12d, [gd_bag_mod]
    mov r13d, NMODS
    mov r14d, [gd_mod]
    jmp .pick
.fires:
    mov r12d, [gd_bag_fire]
    mov r13d, NFIRES
    mov r14d, [gd_fire]
.pick:
    ; how many are missing?
    mov ecx, r13d
    mov eax, 1
    shl eax, cl
    dec eax
    mov r15d, eax
    xor r15d, r12d                      ; missing parts
    jnz .some
    lea rdi, [m_trans_none]
    jmp .say
.some:
    popcnt eax, r15d
    mov [rsp+0], eax
    call rng_next
    xor edx, edx
    div dword [rsp+0]                   ; edx = which missing one
    xor ebx, ebx                        ; part id
.find:
    bt r15d, ebx
    jnc .fn
    test edx, edx
    jz .found
    dec edx
.fn:
    inc ebx
    jmp .find
.found:
    ; the old part goes (if there was one in the slot), the new one comes
    mov dword [gd_charge], 0
    bts r12d, ebx
    test r14d, r14d
    js .no_old
    btr r12d, r14d
.no_old:
    mov [rsp+4], r14d
    cmp dword [gd_col], 0
    jne .not_base
    mov [gd_bag_base], r12d
    mov edi, ebx
    call set_base
    xor eax, eax
    jmp .told
.not_base:
    cmp dword [gd_col], 1
    jne .set_fire
    mov [gd_bag_mod], r12d
    mov edi, ebx
    mov esi, [gd_fire]
    call gadget_select
    mov eax, NBASES
    jmp .told
.set_fire:
    mov [gd_bag_fire], r12d
    mov edi, [gd_mod]
    mov esi, ebx
    call gadget_select
    mov eax, NBASES+NMODS
.told:
    lea rcx, [s_none_yet]
    mov r14d, [rsp+4]
    test r14d, r14d
    js .old_named
    lea edx, [eax+r14d]
    mov rcx, [part_names+rdx*8]
.old_named:
    add eax, ebx
    mov r8, [part_names+rax*8]
    lea rdi, [msg_buf]
    mov esi, 512
    lea rdx, [fmt_trans]
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, COL_GOLD
    xor edx, edx
    call hud_message
    call snd_fanfare
    EPILOGUE
.say:
    mov esi, COL_WARN
    xor edx, edx
    call hud_message
    EPILOGUE

; gadget_take(edi = IT_MODULE / IT_FIRING, esi = which) -> eax = the part of
; that kind you put down for it (-1: that slot was empty; a frame comes back
; with PART_BASE set, as it lies in the world). You carry one frame, one
; module and one firing type: the new part goes straight into the gadget and
; the old one is left where the new one lay (main.asm's take_item re-lays
; the item), so switching gadgets is a choice about what to leave behind.
gadget_take:
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, -1                        ; (no frame yet: none to leave)
    cmp dword [gd_have], 0
    je .framed
    mov r14d, [gd_base]
.framed:
    mov dword [gd_have], 1              ; (a part without a frame: take the frame too)
    or dword [gd_bag_base], 1
    call snd_gadget
    ; r14 = the part it replaces, r15 = its name's index in part_names
    cmp r12d, IT_MODULE
    jne .is_fire
    test r13d, PART_BASE
    jz .is_mod
    and r13d, PART_BASE-1               ; a frame
    xor r15d, r15d
    lea rax, [base_desc]
    lea rdx, [fmt_swap_b]
    jmp .d
.is_mod:
    mov r14d, [gd_mod]
    mov r15d, NBASES
    lea rax, [mod_desc]
    lea rdx, [fmt_swap_m]
    jmp .d
.is_fire:
    mov r14d, [gd_fire]
    mov r15d, NBASES+NMODS
    lea rax, [fire_desc]
    lea rdx, [fmt_swap_f]
.d:
    cmp r14d, r13d
    jne .old_ok
    mov r14d, -1                        ; (the same part again: nothing to leave)
.old_ok:
    ; "Found a gadget part: SMOKE module: ..." / "SMOKE module: ...  Your
    ; PORTAL module is left lying here -- E to swap back."
    mov rcx, [rax+r13*8]
    test r14d, r14d
    jns .swap_msg
    lea rdx, [fmt_found]
    jmp .msg
.swap_msg:
    lea eax, [r15d+r14d]
    mov r8, [part_names+rax*8]
.msg:
    lea rdi, [msg_buf]
    mov esi, 512
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, COL_GOOD
    xor edx, edx
    call hud_message
    ; the new part is the only one of its kind you carry, and it's fitted
    mov eax, 1
    mov ecx, r13d
    shl eax, cl
    cmp r12d, IT_MODULE
    jne .fire
    test r15d, r15d
    jnz .mod
    mov [gd_bag_base], eax
    mov edi, r13d
    call set_base
    test r14d, r14d
    js .out
    or r14d, PART_BASE                  ; (what you leave is a frame)
    jmp .out
.mod:
    mov [gd_bag_mod], eax
    mov edi, r13d
    mov esi, [gd_fire]
    call gadget_select
    jmp .out
.fire:
    mov [gd_bag_fire], eax
    mov edi, [gd_mod]
    mov esi, r13d
    call gadget_select
.out:
    mov eax, r14d
    EPILOGUE

; gadget_give_all -- (custom run / self-tests) every part in your bag
gadget_give_all:
    mov dword [gd_have], 1
    mov dword [gd_base], GB_GUN
    mov dword [gd_bag_base], (1<<NBASES)-1
    mov dword [gd_bag_mod], (1<<NMODS)-1
    mov dword [gd_bag_fire], (1<<NFIRES)-1
    ret

; gadget_reset -- a new night: nothing strung, smoked, pegged or in flight
gadget_reset:
    PROLOGUE 16
    xor eax, eax
    mov [gd_bench], eax
    mov [gd_cool], eax
    mov [gd_charge], eax
    mov [gd_was_safe], eax
    mov [gd_orb_on], eax
    mov [gd_tt_state], eax
    mov [gd_fire_held], eax
    mov [gd_told], eax
    mov [gd_clock], eax
    mov [sm_count], eax
    mov [hi_n], eax
    mov [rg_t], eax
    mov [rg_arm], eax
    mov [lz_t], eax
    mov [peg_n], eax
    mov [peg_next], eax
    mov [gd_roll_n], eax
    mov [dr_state], eax                 ; (DR_HOME)
    mov [dr_told], eax
    mov dword [hk_mod], GM_ROD
    xor ebx, ebx
.ln:
    mov dword [ln_type+rbx*4], LN_FREE
    inc ebx
    cmp ebx, MAXLN
    jl .ln
    xor ebx, ebx
.fl:
    mov dword [fd_line+rbx*4], -1
    inc ebx
    cmp ebx, NFEED
    jl .fl
    ; your zipline slots come after the building's own, parked out of sight
    mov eax, [zip_static]
    add eax, NGZIP
    mov [zip_count], eax
    xor ebx, ebx
.zs:
    mov edi, ebx
    call park_slot
    inc ebx
    cmp ebx, NGZIP
    jl .zs
    ; pegs from last night: they're the platforms at the end of the list
.peg:
    mov eax, [plat_count]
    test eax, eax
    jz .pegs_gone
    cmp dword [plat_style+rax*4-4], PS_GADGET
    jne .pegs_gone
    dec dword [plat_count]
    jmp .peg
.pegs_gone:
    EPILOGUE

; park_slot(edi = zip slot k) -- nothing strung there (out of sight and reach)
park_slot:
    mov eax, [zip_static]
    add eax, edi
    mov dword [zip_grav+rax*4], 1
    xor ecx, ecx
    mov [zip_ax+rax*4], ecx
    mov [zip_az+rax*4], ecx
    mov [zip_bx+rax*4], ecx
    mov [zip_bz+rax*4], ecx
    mov dword [zip_ay+rax*4], __float32__(-100.0)
    mov dword [zip_by+rax*4], __float32__(-100.0)
    ret

; gadget_new_run -- what you start the night with and which parts are hidden
; (cfg_gparts: 0 a few hidden, 1 all in hand, 2 none; cfg_gcount of each
; kind hidden, chosen by the seed, plus the drone frame). Call after gadget_reset, with the seed's
; random numbers running.
gadget_new_run:
    PROLOGUE 48
    xor eax, eax
    mov [gd_have], eax
    mov [gd_bag_base], eax
    mov [gd_bag_mod], eax
    mov [gd_bag_fire], eax
    mov [gd_base], eax
    mov dword [gd_mod], -1
    mov dword [gd_fire], -1
    mov eax, [cfg_gparts]
    cmp eax, 2
    je .done
    cmp eax, 1
    jne .hidden
    call gadget_give_all
    mov dword [gd_mod], GM_ROD          ; the classic: a hookshot in hand
    mov dword [gd_fire], GF_HOOK
    jmp .done
.hidden:
    mov dword [gd_have], 1              ; you always have the gun frame
    mov dword [gd_bag_base], 1
    ; a shuffled pick of cfg_gcount modules, then of firing types
    mov r12d, IT_MODULE
    mov r13d, NMODS
    call .roll
    mov r12d, IT_FIRING
    mov r13d, NFIRES
    call .roll
    ; ...and the drone frame, somewhere (take it and you leave the gun)
    mov eax, [gd_roll_n]
    cmp eax, MAXROLL
    jge .done
    mov dword [gd_roll_kind+rax*4], IT_MODULE
    mov dword [gd_roll_id+rax*4], PART_BASE|GB_DRONE
    inc dword [gd_roll_n]
.done:
    call refresh
    EPILOGUE
; roll r12 = kind, r13 = how many of that kind exist: shuffle 0..n-1, take
; the first cfg_gcount
.roll:
    sub rsp, 8
    xor ecx, ecx
.init:
    mov [rsp+16+rcx*4], ecx             ; (the frame's locals, above the return address)
    inc ecx
    cmp ecx, r13d
    jl .init
    mov r14d, r13d
.shuffle:
    cmp r14d, 1
    jle .shuffled
    call rng_next
    xor edx, edx
    div r14d                            ; edx = 0..i-1
    dec r14d
    mov eax, [rsp+16+r14*4]
    mov ecx, [rsp+16+rdx*4]
    mov [rsp+16+r14*4], ecx
    mov [rsp+16+rdx*4], eax
    jmp .shuffle
.shuffled:
    mov r15d, [cfg_gcount]
    cmp r15d, r13d
    jle .n_ok
    mov r15d, r13d
.n_ok:
    xor r14d, r14d
.take:
    cmp r14d, r15d
    jge .rolled
    mov eax, [gd_roll_n]
    cmp eax, MAXROLL
    jge .rolled
    mov [gd_roll_kind+rax*4], r12d
    mov ecx, [rsp+16+r14*4]
    mov [gd_roll_id+rax*4], ecx
    inc dword [gd_roll_n]
    inc r14d
    jmp .take
.rolled:
    add rsp, 8
    ret

; gadget_fire(edi = 0 primary / 1 secondary) -> eax 1 if the gadget took the
; click (0: no gadget -- main.asm tries your deauth packets)
gadget_fire:
    PROLOGUE 16
    mov ebx, edi
    xor eax, eax
    cmp dword [gd_have], 0
    je .out
    cmp dword [gd_bench], 0
    jne .took
    call combo_id
    test eax, eax
    jns .complete
    lea rdi, [m_incomplete]
    mov esi, COL_WARN
    xor edx, edx
    call hud_message
    jmp .took
.complete:
    mov r12d, eax
    cmp dword [gd_base], GB_DRONE
    jne .up
    cmp dword [dr_state], DR_DOWN
    jne .up
    lea rdi, [m_dr_down]
    mov esi, COL_WARN
    xor edx, edx
    call hud_message
    jmp .took
.up:
    movss xmm0, [gd_cool]
    comiss xmm0, [c_zero]
    ja .took
    cmp dword [p_mode], MODE_WALK
    jne .took
    ; cooldown for this combination
    mov eax, r12d
    and eax, NMODS*NFIRES-1             ; (the same pair on any base)
    mov eax, [combo_cd+rax*4]
    mov [gd_cool], eax
    mov [hr_button], ebx
    call aim_from_view
    ; the shot's heard where it's fired from: you, or the drone
    call drone_away
    test eax, eax
    jnz .drone_noise
    movss xmm0, [c_noise_fire]
    call noise_add
    jmp .noised
.drone_noise:
    movss xmm0, [dr_x]
    movss xmm1, [gs_y]
    movss xmm2, [dr_z]
    movss xmm3, [c_dr_heard]
    call enemy_hear
.noised:
    ; the module's own delivery, or the firing type's
    mov eax, [gd_mod]
    imul eax, eax, NFIRES
    add eax, [gd_fire]
    mov rax, [mod_deliver+rax*8]
    test rax, rax
    jnz .go
    mov eax, [gd_fire]
    mov rax, [fire_delivery+rax*8]
.go:
    call rax
.took:
    mov eax, 1
.out:
    EPILOGUE

; dispatch(edi = module, esi = firing type) -- the module's handler for the
; event that firing type raised (the hit record says what happened); a
; module with no handler for it gets the firing type's generic one
dispatch:
    sub rsp, 8
    cmp edi, NMODS
    jae .generic
    imul eax, edi, NFIRES
    add eax, esi
    mov rax, [mod_handlers+rax*8]
    test rax, rax
    jz .generic
    call rax
    add rsp, 8
    ret
.generic:
    mov eax, esi
    mov rax, [fire_generic+rax*8]
    call rax
    add rsp, 8
    ret

; generic_hit -- a module that doesn't know this firing type still does
; something: a knock on whatever it hit (T hears where)
generic_hit:
    PROLOGUE 16
    call snd_clank
    movss xmm0, [hr_x]
    movss xmm1, [hr_y]
    movss xmm2, [hr_z]
    movss xmm3, [c_orb_heard]
    call enemy_hear
    EPILOGUE

; generic_hook -> eax 1: just haul the player (like the rod)
generic_hook:
    mov eax, 1
    ret

; =============================================================================
; aiming and tracing
; =============================================================================

; aim_from_view -- ao = your eye, ad = where you're looking; hd = your hand;
; gs = where you stand. With the drone out, ao, hd and gs are the drone's
; (it fires the way you look, from where it is).
aim_from_view:
    PROLOGUE 32
    mov eax, [p_x]
    mov [ao_x], eax
    mov eax, [p_eye_y]
    mov [ao_y], eax
    mov eax, [p_z]
    mov [ao_z], eax
    movss xmm0, [p_pitch]
    call cosf
    movss [rsp+0], xmm0
    movss xmm0, [p_pitch]
    call sinf
    movss [ad_y], xmm0
    movss xmm0, [p_yaw]
    call sinf
    movss [rsp+4], xmm0
    mulss xmm0, [rsp+0]
    xorps xmm0, [c_sign_mask]
    movss [ad_x], xmm0
    movss xmm0, [p_yaw]
    call cosf
    movss [rsp+8], xmm0
    mulss xmm0, [rsp+0]
    xorps xmm0, [c_sign_mask]
    movss [ad_z], xmm0
    ; hand: eye + forward*0.45 - right*0.2 - 0.2 down (right = (cos, 0, -sin))
    movss xmm0, [rsp+4]
    FLD xmm1, -0.45
    mulss xmm0, xmm1
    movss xmm1, [rsp+8]
    FLD xmm2, 0.2
    mulss xmm1, xmm2
    addss xmm0, xmm1
    addss xmm0, [p_x]
    movss [hd_x], xmm0
    movss xmm0, [p_eye_y]
    FLD xmm1, 0.2
    subss xmm0, xmm1
    movss [hd_y], xmm0
    movss xmm0, [rsp+8]
    FLD xmm1, -0.45
    mulss xmm0, xmm1
    movss xmm1, [rsp+4]
    FLD xmm2, -0.2
    mulss xmm1, xmm2
    addss xmm0, xmm1
    addss xmm0, [p_z]
    movss [hd_z], xmm0
    mov eax, [p_x]
    mov [gs_x], eax
    mov eax, [p_y]
    mov [gs_y], eax
    mov eax, [p_z]
    mov [gs_z], eax
    call drone_away
    test eax, eax
    jz .done
    mov eax, [dr_x]
    mov [ao_x], eax
    mov [hd_x], eax
    mov [gs_x], eax
    mov eax, [dr_y]
    mov [ao_y], eax
    mov [hd_y], eax
    mov eax, [dr_z]
    mov [ao_z], eax
    mov [hd_z], eax
    mov [gs_z], eax
    movss xmm0, [dr_x]
    movss xmm1, [dr_y]
    movss xmm2, [dr_z]
    call floor_under
    comiss xmm0, [c_neg_big]
    ja .gy
    movss xmm0, [dr_y]
    subss xmm0, [c_eye]
.gy:
    movss [gs_y], xmm0
.done:
    EPILOGUE

; hit_t(xmm0..2 = point) -> eax 1 if it's inside T. leaf
hit_t:
    subss xmm0, [t_x]
    mulss xmm0, xmm0
    subss xmm2, [t_z]
    mulss xmm2, xmm2
    addss xmm0, xmm2
    xor eax, eax
    comiss xmm0, [c_t_r2]
    jae .no
    subss xmm1, [t_y]
    comiss xmm1, [c_zero]
    jb .no
    comiss xmm1, [c_t_h]
    ja .no
    mov eax, 1
.no:
    ret

; hit_feeder(xmm0..2 = point) -> eax = the bottom feeder there, or -1. leaf
hit_feeder:
    xor ecx, ecx
.f:
    cmp ecx, [fd_count]
    jge .none
    cmp dword [fd_state+rcx*4], FD_DEAD
    je .n
    movss xmm3, xmm0
    subss xmm3, [fd_x+rcx*4]
    mulss xmm3, xmm3
    movss xmm4, xmm1
    subss xmm4, [fd_y+rcx*4]
    subss xmm4, [c_fd_mid]
    mulss xmm4, xmm4
    addss xmm3, xmm4
    movss xmm4, xmm2
    subss xmm4, [fd_z+rcx*4]
    mulss xmm4, xmm4
    addss xmm3, xmm4
    comiss xmm3, [c_near_r2]
    jb .got
.n:
    inc ecx
    jmp .f
.got:
    mov eax, ecx
    ret
.none:
    mov eax, -1
    ret

; hit_item(xmm0..2 = point) -> eax = byte offset of a pickup there, or -1. leaf
hit_item:
    xor ecx, ecx
.i:
    cmp ecx, [item_count]
    jge .none
    imul edx, ecx, ITEM_SIZE
    cmp dword [items+rdx+ITEM_ACTIVE], 0
    je .n
    cmp dword [items+rdx+ITEM_KIND], IT_TYLER
    jge .n
    movss xmm3, xmm0
    subss xmm3, [items+rdx+ITEM_X]
    mulss xmm3, xmm3
    movss xmm4, xmm1
    subss xmm4, [items+rdx+ITEM_Y]
    subss xmm4, [c_it_mid]
    mulss xmm4, xmm4
    addss xmm3, xmm4
    movss xmm4, xmm2
    subss xmm4, [items+rdx+ITEM_Z]
    mulss xmm4, xmm4
    addss xmm3, xmm4
    comiss xmm3, [c_near_r2]
    jb .got
.n:
    inc ecx
    jmp .i
.got:
    mov eax, edx
    ret
.none:
    mov eax, -1
    ret

; body_centre(edi = physics body) -> xmm0..2 = the middle of its particles. leaf
body_centre:
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    xorps xmm2, xmm2
    mov ecx, [body_p0+rdi*4]
    mov edx, [body_np+rdi*4]
    test edx, edx
    jz .out
    lea r8d, [ecx+edx]
.p:
    addss xmm0, [px+rcx*4]
    addss xmm1, [py+rcx*4]
    addss xmm2, [pz+rcx*4]
    inc ecx
    cmp ecx, r8d
    jl .p
    cvtsi2ss xmm3, edx
    divss xmm0, xmm3
    divss xmm1, xmm3
    divss xmm2, xmm3
.out:
    ret

; hit_prop(xmm0..2 = point) -> eax = a box or sign there, or -1 (not T's
; ragdoll). Keeps xmm0..2.
hit_prop:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    xor ebx, ebx
.b:
    cmp ebx, [phys_nb]
    jge .none
    cmp dword [body_active+rbx*4], 0
    je .n
    cmp dword [body_type+rbx*4], 2      ; (the ragdoll is T)
    je .n
    mov edi, ebx
    call body_centre
    subss xmm0, [rsp+0]
    mulss xmm0, xmm0
    subss xmm1, [rsp+4]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    subss xmm2, [rsp+8]
    mulss xmm2, xmm2
    addss xmm0, xmm2
    comiss xmm0, [c_near_r2]
    jb .got
.n:
    inc ebx
    jmp .b
.got:
    mov eax, ebx
    jmp .out
.none:
    mov eax, -1
.out:
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+8]
    EPILOGUE

; set_normal(rsp-frame of gd_trace: [rsp+12..20] previous point, [rsp+24..32]
; the solid one) -- which face the trace came through: a floor/ceiling if it
; changed storey, else the grid face it crossed, else (a desk, a crate) the
; face against the main direction of travel. Writes hr_nx/ny/nz.
set_normal:
    xor eax, eax
    mov [hr_nx], eax
    mov [hr_ny], eax
    mov [hr_nz], eax
    movss xmm0, [rsp+8+16]              ; (the caller's frame, past our return address)
    divss xmm0, [c_fh]
    roundss xmm0, xmm0, 1
    movss xmm1, [rsp+8+28]
    divss xmm1, [c_fh]
    roundss xmm1, xmm1, 1
    comiss xmm0, xmm1
    je .same_storey
    mov dword [hr_ny], __float32__(1.0) ; went down into a floor: it faces up
    jb .ceiling
    ret
.ceiling:
    mov dword [hr_ny], __float32__(-1.0)
    ret
.same_storey:
    movss xmm0, [rsp+8+12]
    mulss xmm0, [c_inv_cell]
    roundss xmm0, xmm0, 1
    movss xmm1, [rsp+8+24]
    mulss xmm1, [c_inv_cell]
    roundss xmm1, xmm1, 1
    comiss xmm0, xmm1
    je .z
    mov dword [hr_nx], __float32__(-1.0)
    jb .x_done
    mov dword [hr_nx], __float32__(1.0)
.x_done:
    ret
.z:
    movss xmm0, [rsp+8+20]
    mulss xmm0, [c_inv_cell]
    roundss xmm0, xmm0, 1
    movss xmm1, [rsp+8+32]
    mulss xmm1, [c_inv_cell]
    roundss xmm1, xmm1, 1
    comiss xmm0, xmm1
    je .main_axis
    mov dword [hr_nz], __float32__(-1.0)
    jb .z_done
    mov dword [hr_nz], __float32__(1.0)
.z_done:
    ret
.main_axis:
    ; a platform: whichever way the trace was mostly going
    movss xmm0, [ad_x]
    andps xmm0, [c_abs_mask]
    movss xmm1, [ad_y]
    andps xmm1, [c_abs_mask]
    movss xmm2, [ad_z]
    andps xmm2, [c_abs_mask]
    comiss xmm1, xmm0
    jb .not_y
    comiss xmm1, xmm2
    jb .not_y
    mov dword [hr_ny], __float32__(1.0)
    ret
.not_y:
    comiss xmm0, xmm2
    jb .nz
    mov eax, [ad_x]
    xor eax, 0x80000000
    and eax, 0x80000000
    or eax, __float32__(1.0)
    mov [hr_nx], eax
    ret
.nz:
    mov eax, [ad_z]
    xor eax, 0x80000000
    and eax, 0x80000000
    or eax, __float32__(1.0)
    mov [hr_nz], eax
    ret

; gd_trace(xmm0 = range, edi = TR_ flags) -> eax = hr_kind, hit record set.
; Steps along ao + ad*t: creatures and things (by flag) are hit where the
; trace passes through them; the world where it first goes solid (the point
; recorded is the last free one, a step short).
gd_trace:
    PROLOGUE 64
    ; [rsp+0] range [rsp+4] flags [rsp+8] t [rsp+12..20] prev [rsp+24..32] point
    movss [rsp+0], xmm0
    mov [rsp+4], edi
    mov dword [rsp+8], 0
    mov eax, [ao_x]
    mov [rsp+12], eax
    mov eax, [ao_y]
    mov [rsp+16], eax
    mov eax, [ao_z]
    mov [rsp+20], eax
    xor eax, eax
    mov [hr_nx], eax
    mov [hr_ny], eax
    mov [hr_nz], eax
    mov dword [hr_idx], -1
.step:
    movss xmm0, [rsp+8]
    addss xmm0, [c_step]
    comiss xmm0, [rsp+0]
    ja .miss
    movss [rsp+8], xmm0
    movss xmm1, [ad_x]
    mulss xmm1, xmm0
    addss xmm1, [ao_x]
    movss [rsp+24], xmm1
    movss xmm1, [ad_y]
    mulss xmm1, xmm0
    addss xmm1, [ao_y]
    movss [rsp+28], xmm1
    movss xmm1, [ad_z]
    mulss xmm1, xmm0
    addss xmm1, [ao_z]
    movss [rsp+32], xmm1
    test dword [rsp+4], TR_CREATURES
    jz .things
    movss xmm0, [rsp+24]
    movss xmm1, [rsp+28]
    movss xmm2, [rsp+32]
    call hit_t
    test eax, eax
    jz .no_t
    mov dword [hr_kind], HT_T
    jmp .at_point
.no_t:
    movss xmm0, [rsp+24]
    movss xmm1, [rsp+28]
    movss xmm2, [rsp+32]
    call hit_feeder
    test eax, eax
    js .no_fd
    mov [hr_idx], eax
    mov dword [hr_kind], HT_FEEDER
    jmp .at_point
.no_fd:
    movss xmm0, [rsp+24]
    movss xmm1, [rsp+28]
    movss xmm2, [rsp+32]
    call build_hit_point
    test eax, eax
    jz .things
    mov dword [hr_kind], HT_STAIRS
    jmp .at_point
.things:
    test dword [rsp+4], TR_THINGS
    jz .world
    movss xmm0, [rsp+24]
    movss xmm1, [rsp+28]
    movss xmm2, [rsp+32]
    call hit_item
    test eax, eax
    js .no_item
    mov [hr_idx], eax
    mov dword [hr_kind], HT_ITEM
    jmp .at_point
.no_item:
    movss xmm0, [rsp+24]
    movss xmm1, [rsp+28]
    movss xmm2, [rsp+32]
    call hit_prop
    test eax, eax
    js .world
    mov [hr_idx], eax
    mov dword [hr_kind], HT_PROP
    jmp .at_point
.world:
    movss xmm0, [rsp+24]
    movss xmm1, [rsp+28]
    movss xmm2, [rsp+32]
    movss xmm3, [rsp+16]
    call solid_point
    test eax, eax
    jnz .solid
    mov eax, [rsp+24]
    mov [rsp+12], eax
    mov eax, [rsp+28]
    mov [rsp+16], eax
    mov eax, [rsp+32]
    mov [rsp+20], eax
    jmp .step
.solid:
    call set_normal
    mov dword [hr_kind], HT_WORLD
    mov eax, [rsp+12]
    mov [hr_x], eax
    mov eax, [rsp+16]
    mov [hr_y], eax
    mov eax, [rsp+20]
    mov [hr_z], eax
    movss xmm0, [rsp+8]
    subss xmm0, [c_step]
    movss [hr_dist], xmm0
    jmp .out
.at_point:
    mov eax, [rsp+24]
    mov [hr_x], eax
    mov eax, [rsp+28]
    mov [hr_y], eax
    mov eax, [rsp+32]
    mov [hr_z], eax
    mov eax, [rsp+8]
    mov [hr_dist], eax
    jmp .out
.miss:
    mov dword [hr_kind], HT_NONE
    mov eax, [rsp+12]
    mov [hr_x], eax
    mov eax, [rsp+16]
    mov [hr_y], eax
    mov eax, [rsp+20]
    mov [hr_z], eax
    mov eax, [rsp+0]
    mov [hr_dist], eax
.out:
    mov eax, [hr_kind]
    EPILOGUE

; =============================================================================
; deliveries: how each firing type gets the module's effect somewhere
; =============================================================================

; deliver_laser -- instant and straight: whatever's first along your aim
deliver_laser:
    PROLOGUE 16
    movss xmm0, [c_laser_r]
    mov edi, TR_CREATURES|TR_THINGS
    call gd_trace
    call beam_to_hit
    call snd_laser
    mov edi, [gd_mod]
    mov esi, GF_LASER
    call dispatch
    EPILOGUE

; beam_to_hit -- flash a beam from your hand to the hit (module colour)
beam_to_hit:
    mov eax, [c_beam_t]
    mov [lz_t], eax
    mov eax, [hd_x]
    mov [lz_ax], eax
    mov eax, [hd_y]
    mov [lz_ay], eax
    mov eax, [hd_z]
    mov [lz_az], eax
    mov eax, [hr_x]
    mov [lz_bx], eax
    mov eax, [hr_y]
    mov [lz_by], eax
    mov eax, [hr_z]
    mov [lz_bz], eax
    mov eax, [gd_tip_col]
    mov [lz_col], eax
    ret

; deliver_orb -- lob it: an arc, bounces, then it goes off (orb_update).
; One in the air at a time.
deliver_orb:
    PROLOGUE 16
    cmp dword [gd_orb_on], 0
    jne .done
    mov eax, [gd_mod]
    mov [orb_mod], eax
    movss xmm0, [ad_x]
    FLD xmm1, 0.4
    mulss xmm0, xmm1
    addss xmm0, [ao_x]
    movss [gd_orb_x], xmm0
    movss xmm0, [ad_y]
    mulss xmm0, xmm1
    addss xmm0, [ao_y]
    movss [gd_orb_y], xmm0
    movss xmm0, [ad_z]
    mulss xmm0, xmm1
    addss xmm0, [ao_z]
    movss [gd_orb_z], xmm0
    movss xmm0, [ad_x]
    mulss xmm0, [c_orb_v]
    movss [orb_vx], xmm0
    movss xmm0, [ad_y]
    mulss xmm0, [c_orb_v]
    addss xmm0, [c_orb_up]
    movss [orb_vy], xmm0
    movss xmm0, [ad_z]
    mulss xmm0, [c_orb_v]
    movss [orb_vz], xmm0
    mov eax, [c_orb_fuse]
    mov [orb_fuse], eax
    xor eax, eax
    mov [orb_bounce], eax
    mov [orb_nx], eax
    mov [orb_ny], eax
    mov [orb_nz], eax
    mov dword [gd_orb_on], 1
    call snd_orb
    call drone_away                     ; (from the drone: T heard the drone)
    test eax, eax
    jnz .done
    movss xmm0, [c_noise_orb]
    call noise_add
.done:
    EPILOGUE

; deliver_hook -- the hook (hookshot.asm) carries whatever module is in: it
; bites, then gadget_hook_attach asks the module what happens
deliver_hook:
    PROLOGUE 16
    mov eax, [gd_mod]
    mov [hk_mod], eax
    call drone_away
    test eax, eax
    jnz .to_drone
    call hookshot_fire
    EPILOGUE
.to_drone:
    ; from a drone the hook bites the drone itself
    mov eax, [dr_x]
    mov [hr_x], eax
    mov eax, [dr_y]
    mov [hr_y], eax
    mov eax, [dr_z]
    mov [hr_z], eax
    mov dword [hr_kind], HT_WORLD
    cmp dword [gd_mod], GM_PORTAL
    jne .line
    ; a blink has no line to follow: straight to it, wherever it is
    mov ebx, [p_x]
    mov edi, GM_PORTAL
    mov esi, GF_HOOK
    call dispatch
    cmp ebx, [p_x]
    je .out
    mov dword [dr_state], DR_HOME       ; (you're where it was: it docks)
    EPILOGUE
.line:
    movss xmm0, [p_x]
    movss xmm1, [p_eye_y]
    movss xmm2, [p_z]
    movss xmm3, [dr_x]
    movss xmm4, [dr_y]
    movss xmm5, [dr_z]
    call line_of_sight_3d
    test eax, eax
    jz .unseen
    movss xmm0, [dr_x]
    movss xmm1, [dr_y]
    movss xmm2, [dr_z]
    call hookshot_fire_at
.out:
    EPILOGUE
.unseen:
    call snd_hook_miss
    lea rdi, [m_dr_sight]
    mov esi, COL_WARN
    call say
    EPILOGUE

; deliver_grab -- throw the grabber: it flies to the first thing (or wall)
; along your aim; tether_update latches it on and asks the module
deliver_grab:
    PROLOGUE 16
    cmp dword [gd_tt_state], TT_IDLE
    jne .done
    movss xmm0, [c_tether_r]
    mov edi, TR_CREATURES|TR_THINGS
    call gd_trace
    mov eax, [hr_dist]
    mov [tt_target], eax
    mov eax, [hr_kind]
    mov [tt_kind], eax
    mov eax, [hr_idx]
    mov [tt_idx], eax
    mov eax, [gd_mod]
    mov [tt_mod], eax
    mov eax, [hd_x]
    mov [tt_sx], eax
    mov [tt_hx], eax
    mov eax, [hd_y]
    mov [tt_sy], eax
    mov [tt_hy], eax
    mov eax, [hd_z]
    mov [tt_sz], eax
    mov [tt_hz], eax
    mov eax, [ad_x]
    mov [tt_dx], eax
    mov eax, [ad_y]
    mov [tt_dy], eax
    mov eax, [ad_z]
    mov [tt_dz], eax
    mov dword [tt_len], 0
    mov dword [tt_time], 0
    mov dword [gd_tt_state], TT_FLY
    call snd_hook_fire
.done:
    EPILOGUE

; gadget_hook_attach -> eax 1: haul the player to the hook as usual; 0: the
; module dealt with it (hookshot.asm reels the hook back in). Called by
; hookshot.asm the moment the hook bites the world (hk_hx.. = where).
gadget_hook_attach:
    PROLOGUE 16
    mov eax, [hk_hx]
    mov [hr_x], eax
    mov eax, [hk_hy]
    mov [hr_y], eax
    mov eax, [hk_hz]
    mov [hr_z], eax
    mov dword [hr_kind], HT_WORLD
    call aim_from_view
    mov edi, [hk_mod]
    mov esi, GF_HOOK
    call dispatch
    EPILOGUE

; ---- the orb in flight ----------------------------------------------------------

; orb_solid(xmm0..2 = point) -> eax 1 if solid (xmm3 = the orb's current y)
orb_solid:
    sub rsp, 8
    movss xmm3, [gd_orb_y]
    call solid_point
    add rsp, 8
    ret

; orb_update(xmm0 = dt) -- four substeps of flight: gravity, creatures (it
; goes off on them), props (it knocks them), the world (it bounces -- or,
; carrying a rod, sticks), and a fuse
orb_update:
    PROLOGUE 64
    cmp dword [gd_orb_on], 0
    je .done
    FLD xmm1, 0.25
    mulss xmm0, xmm1
    movss [rsp+0], xmm0                 ; substep
    mov r12d, 4
.sub:
    movss xmm0, [orb_vy]
    movss xmm1, [c_orb_g]
    mulss xmm1, [rsp+0]
    addss xmm0, xmm1
    movss [orb_vy], xmm0
    ; the next point
    movss xmm0, [orb_vx]
    mulss xmm0, [rsp+0]
    addss xmm0, [gd_orb_x]
    movss [rsp+4], xmm0
    movss xmm0, [orb_vy]
    mulss xmm0, [rsp+0]
    addss xmm0, [gd_orb_y]
    movss [rsp+8], xmm0
    movss xmm0, [orb_vz]
    mulss xmm0, [rsp+0]
    addss xmm0, [gd_orb_z]
    movss [rsp+12], xmm0
    ; T? a feeder?
    movss xmm0, [rsp+4]
    movss xmm1, [rsp+8]
    movss xmm2, [rsp+12]
    call hit_t
    test eax, eax
    jz .no_t
    mov dword [hr_kind], HT_T
    jmp .go_off_here
.no_t:
    movss xmm0, [rsp+4]
    movss xmm1, [rsp+8]
    movss xmm2, [rsp+12]
    call hit_feeder
    test eax, eax
    js .no_fd
    mov [hr_idx], eax
    mov dword [hr_kind], HT_FEEDER
    jmp .go_off_here
.no_fd:
    ; a box in the way: knock it (and lose some speed)
    movss xmm0, [rsp+4]
    movss xmm1, [rsp+8]
    movss xmm2, [rsp+12]
    call hit_prop
    test eax, eax
    js .no_prop
    mov edi, eax
    movss xmm0, [orb_vx]
    movss xmm1, [orb_vy]
    movss xmm2, [orb_vz]
    call physics_push
    movss xmm0, [c_half]
    movss xmm1, [orb_vx]
    mulss xmm1, xmm0
    movss [orb_vx], xmm1
    movss xmm1, [orb_vz]
    mulss xmm1, xmm0
    movss [orb_vz], xmm1
.no_prop:
    movss xmm0, [rsp+4]
    movss xmm1, [rsp+8]
    movss xmm2, [rsp+12]
    call orb_solid
    test eax, eax
    jnz .bounce
    mov eax, [rsp+4]
    mov [gd_orb_x], eax
    mov eax, [rsp+8]
    mov [gd_orb_y], eax
    mov eax, [rsp+12]
    mov [gd_orb_z], eax
    jmp .fuse
.bounce:
    ; which way was solid? test each axis on its own
    xor r13d, r13d                      ; bit 0 x, 1 y, 2 z
    movss xmm0, [rsp+4]
    movss xmm1, [gd_orb_y]
    movss xmm2, [gd_orb_z]
    call orb_solid
    test eax, eax
    jz .by
    or r13d, 1
.by:
    movss xmm0, [gd_orb_x]
    movss xmm1, [rsp+8]
    movss xmm2, [gd_orb_z]
    call orb_solid
    test eax, eax
    jz .bz
    or r13d, 2
.bz:
    movss xmm0, [gd_orb_x]
    movss xmm1, [gd_orb_y]
    movss xmm2, [rsp+12]
    call orb_solid
    test eax, eax
    jz .axes
    or r13d, 4
.axes:
    test r13d, r13d
    jnz .reflect
    mov r13d, 7                         ; a corner: back off every way
.reflect:
    xor eax, eax
    mov [orb_nx], eax
    mov [orb_ny], eax
    mov [orb_nz], eax
    test r13d, 1
    jz .ry
    mov eax, [orb_vx]
    xor eax, 0x80000000
    and eax, 0x80000000
    or eax, __float32__(1.0)
    mov [orb_nx], eax
    movss xmm0, [orb_vx]
    mulss xmm0, [c_orb_rest]
    xorps xmm0, [c_sign_mask]
    movss [orb_vx], xmm0
    jmp .ry2
.ry:
    movss xmm0, [orb_vx]
    mulss xmm0, [c_orb_fric]
    movss [orb_vx], xmm0
.ry2:
    test r13d, 2
    jz .rz
    mov eax, [orb_vy]
    xor eax, 0x80000000
    and eax, 0x80000000
    or eax, __float32__(1.0)
    mov [orb_ny], eax
    movss xmm0, [orb_vy]
    mulss xmm0, [c_orb_rest]
    xorps xmm0, [c_sign_mask]
    movss [orb_vy], xmm0
    jmp .rz2
.rz:
.rz2:
    test r13d, 4
    jz .rx
    mov eax, [orb_vz]
    xor eax, 0x80000000
    and eax, 0x80000000
    or eax, __float32__(1.0)
    mov [orb_nz], eax
    movss xmm0, [orb_vz]
    mulss xmm0, [c_orb_rest]
    xorps xmm0, [c_sign_mask]
    movss [orb_vz], xmm0
    jmp .settle
.rx:
    movss xmm0, [orb_vz]
    mulss xmm0, [c_orb_fric]
    movss [orb_vz], xmm0
.settle:
    inc dword [orb_bounce]
    call orb_clatter
    ; a rod digs in where it lands
    mov eax, [orb_mod]
    cmp eax, NMODS
    jae .rolling
    cmp dword [mod_sticky+rax*4], 0
    jne .go_off_world
.rolling:
    cmp dword [orb_bounce], 4
    jge .go_off_world
    movss xmm0, [orb_vx]
    mulss xmm0, xmm0
    movss xmm1, [orb_vy]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [orb_vz]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    comiss xmm0, [c_orb_still]
    jb .go_off_world
.fuse:
    movss xmm0, [orb_fuse]
    subss xmm0, [rsp+0]
    movss [orb_fuse], xmm0
    comiss xmm0, [c_zero]
    jbe .go_off_air
    dec r12d
    jnz .sub
    EPILOGUE
.go_off_here:
    mov eax, [rsp+4]
    mov [gd_orb_x], eax
    mov eax, [rsp+8]
    mov [gd_orb_y], eax
    mov eax, [rsp+12]
    mov [gd_orb_z], eax
    jmp .go_off
.go_off_air:
    mov dword [hr_kind], HT_NONE
    xor eax, eax
    mov [orb_nx], eax
    mov [orb_ny], eax
    mov [orb_nz], eax
    jmp .go_off
.go_off_world:
    mov dword [hr_kind], HT_WORLD
.go_off:
    mov dword [gd_orb_on], 0
    mov eax, [gd_orb_x]
    mov [hr_x], eax
    mov eax, [gd_orb_y]
    mov [hr_y], eax
    mov eax, [gd_orb_z]
    mov [hr_z], eax
    mov eax, [orb_nx]
    mov [hr_nx], eax
    mov eax, [orb_ny]
    mov [hr_ny], eax
    mov eax, [orb_nz]
    mov [hr_nz], eax
    ; the direction it was travelling (for backing off)
    mov eax, [orb_vx]
    mov [ad_x], eax
    mov eax, [orb_vy]
    mov [ad_y], eax
    mov eax, [orb_vz]
    mov [ad_z], eax
    mov edi, [orb_mod]
    mov esi, GF_ORB
    call dispatch
.done:
    EPILOGUE

; orb_clatter -- every bounce: a clack that T can hear (orbs are decoys too)
orb_clatter:
    PROLOGUE 16
    cmp dword [orb_bounce], 1
    jne .quiet
    call snd_clank
    movss xmm0, [gd_orb_x]
    movss xmm1, [gd_orb_y]
    movss xmm2, [gd_orb_z]
    movss xmm3, [c_orb_heard]
    call enemy_hear
.quiet:
    EPILOGUE

; ---- the grabber's tether -------------------------------------------------------

; tt_head_along -- head = start + dir * len. leaf
tt_head_along:
    movss xmm0, [tt_len]
    movss xmm1, [tt_dx]
    mulss xmm1, xmm0
    addss xmm1, [tt_sx]
    movss [tt_hx], xmm1
    movss xmm1, [tt_dy]
    mulss xmm1, xmm0
    addss xmm1, [tt_sy]
    movss [tt_hy], xmm1
    movss xmm1, [tt_dz]
    mulss xmm1, xmm0
    addss xmm1, [tt_sz]
    movss [tt_hz], xmm1
    ret

; tt_toward_hand(xmm0 = distance) -> eax 1 if the head reached your hand
; (moves the head that far towards it)
tt_toward_hand:
    PROLOGUE 32
    movss [rsp+0], xmm0
    call aim_from_view                  ; (your hand, where you are now)
    movss xmm0, [hd_x]
    subss xmm0, [tt_hx]
    movss xmm1, [hd_y]
    subss xmm1, [tt_hy]
    movss xmm2, [hd_z]
    subss xmm2, [tt_hz]
    movss [rsp+4], xmm0
    movss [rsp+8], xmm1
    movss [rsp+12], xmm2
    mulss xmm0, xmm0
    mulss xmm1, xmm1
    addss xmm0, xmm1
    mulss xmm2, xmm2
    addss xmm0, xmm2
    sqrtss xmm0, xmm0
    comiss xmm0, [c_arrive]
    jb .there
    movss xmm1, [rsp+0]
    minss xmm1, xmm0
    divss xmm1, xmm0
    movss xmm0, [rsp+4]
    mulss xmm0, xmm1
    addss xmm0, [tt_hx]
    movss [tt_hx], xmm0
    movss xmm0, [rsp+8]
    mulss xmm0, xmm1
    addss xmm0, [tt_hy]
    movss [tt_hy], xmm0
    movss xmm0, [rsp+12]
    mulss xmm0, xmm1
    addss xmm0, [tt_hz]
    movss [tt_hz], xmm0
    xor eax, eax
    EPILOGUE
.there:
    mov eax, 1
    EPILOGUE

; tether_update(xmm0 = dt)
tether_update:
    PROLOGUE 32
    movss [rsp+0], xmm0
    mov eax, [gd_tt_state]
    cmp eax, TT_FLY
    je .fly
    cmp eax, TT_REEL
    je .reel
    cmp eax, TT_BACK
    je .back
    EPILOGUE
.fly:
    movss xmm0, [c_fly]
    mulss xmm0, [rsp+0]
    addss xmm0, [tt_len]
    movss [tt_len], xmm0
    comiss xmm0, [tt_target]
    jb .fly_on
    mov eax, [tt_target]
    mov [tt_len], eax
    call tt_head_along
    ; latched (or on a wall, or nothing at all): the module decides
    mov eax, [tt_hx]
    mov [hr_x], eax
    mov eax, [tt_hy]
    mov [hr_y], eax
    mov eax, [tt_hz]
    mov [hr_z], eax
    mov eax, [tt_kind]
    mov [hr_kind], eax
    mov eax, [tt_idx]
    mov [hr_idx], eax
    mov dword [gd_tt_state], TT_BACK    ; (unless the module reels something in)
    mov edi, [tt_mod]
    mov esi, GF_GRAB
    call dispatch
    EPILOGUE
.fly_on:
    call tt_head_along
    EPILOGUE
.reel:
    ; haul whatever's on the end with the head
    movss xmm0, [tt_time]
    addss xmm0, [rsp+0]
    movss [tt_time], xmm0
    movss xmm0, [c_reel]
    mulss xmm0, [rsp+0]
    call tt_toward_hand
    mov r12d, eax
    mov eax, [tt_kind]
    cmp eax, HT_ITEM
    je .reel_item
    cmp eax, HT_FEEDER
    je .reel_feeder
    cmp eax, HT_PROP
    je .reel_prop
    jmp .reel_done
.reel_item:
    mov ebx, [tt_idx]
    cmp dword [items+rbx+ITEM_ACTIVE], 0
    je .drop                            ; (somebody got it first)
    mov eax, [tt_hx]
    mov [items+rbx+ITEM_X], eax
    movss xmm0, [tt_hy]
    subss xmm0, [c_it_mid]
    movss [items+rbx+ITEM_Y], xmm0
    mov eax, [tt_hz]
    mov [items+rbx+ITEM_Z], eax
    test r12d, r12d
    jz .reel_done
    lea rdi, [items+rbx]
    call take_item
    jmp .drop
.reel_feeder:
    mov ebx, [tt_idx]
    mov eax, [tt_hx]
    mov [fd_x+rbx*4], eax
    movss xmm0, [tt_hy]
    subss xmm0, [c_hang_fd]
    movss [fd_y+rbx*4], xmm0
    mov eax, [tt_hz]
    mov [fd_z+rbx*4], eax
    mov edi, ebx
    movss xmm0, [c_half]
    call feeder_stun
    test r12d, r12d
    jz .reel_done
    ; dropped at your feet (or the drone's), dazed
    movss xmm0, [gs_x]
    movss xmm1, [gs_y]
    movss xmm2, [gs_z]
    call node_at_pos
    mov edi, ebx
    mov esi, eax
    call feeder_put
    mov edi, ebx
    movss xmm0, [c_fd_haul]
    call feeder_stun
    lea rdi, [m_grab_home]
    mov esi, COL_GOOD
    xor edx, edx
    call hud_message
    jmp .drop
.reel_prop:
    ; boxes come by themselves, pushed along the line to you
    mov edi, [tt_idx]
    call body_centre
    movss xmm3, [hd_x]                  ; (your hand, or the drone)
    subss xmm3, xmm0
    movss xmm4, [hd_y]
    subss xmm4, xmm1
    movss xmm5, [hd_z]
    subss xmm5, xmm2
    movss [rsp+4], xmm3
    movss [rsp+8], xmm4
    movss [rsp+12], xmm5
    mulss xmm3, xmm3
    mulss xmm4, xmm4
    addss xmm3, xmm4
    mulss xmm5, xmm5
    addss xmm3, xmm5
    sqrtss xmm3, xmm3
    FLD xmm4, 1.6
    comiss xmm3, xmm4
    jb .drop
    movss xmm4, [c_pull_push]
    divss xmm4, xmm3
    movss xmm0, [rsp+4]
    mulss xmm0, xmm4
    movss xmm1, [rsp+8]
    mulss xmm1, xmm4
    addss xmm1, [c_lift]
    movss xmm2, [rsp+12]
    mulss xmm2, xmm4
    mov edi, [tt_idx]
    call physics_push
    ; the head rides on the box
    mov edi, [tt_idx]
    call body_centre
    movss [tt_hx], xmm0
    movss [tt_hy], xmm1
    movss [tt_hz], xmm2
    movss xmm0, [tt_time]
    FLD xmm1, 2.0
    comiss xmm0, xmm1
    ja .drop
.reel_done:
    test r12d, r12d
    jz .out
.drop:
    mov dword [gd_tt_state], TT_BACK
.out:
    EPILOGUE
.back:
    movss xmm0, [c_back]
    mulss xmm0, [rsp+0]
    call tt_toward_hand
    test eax, eax
    jz .out
    mov dword [gd_tt_state], TT_IDLE
    EPILOGUE

; =============================================================================
; module handlers -- read the hit record, do the thing
; =============================================================================

; ---- shared bits ------------------------------------------------------------------

; stun_t(xmm0 = seconds) -- T staggers for at least that long
stun_t:
    maxss xmm0, [t_stun]
    movss [t_stun], xmm0
    ret

; say(rdi = text, esi = colour)
say:
    sub rsp, 8
    xor edx, edx
    call hud_message
    add rsp, 8
    ret

; cell_char(xmm0 = x, xmm1 = y, xmm2 = z) -> eax = the map character there
cell_char:
    PROLOGUE 16
    movss [rsp+0], xmm0
    movss [rsp+4], xmm2
    movaps xmm0, xmm1
    call floor_of_height
    mov edi, eax
    movss xmm0, [rsp+0]
    mulss xmm0, [c_inv_cell]
    cvttss2si esi, xmm0
    movss xmm0, [rsp+4]
    mulss xmm0, [c_inv_cell]
    cvttss2si edx, xmm0
    call cell_at
    EPILOGUE

; in_safe_at(xmm0..2) -> eax 1 if that spot (or where you stand) is a safe
; room: nothing that bends space works in or into one
in_safe_at:
    PROLOGUE 16
    call cell_char
    cmp eax, 'S'
    je .yes
    call player_in_safe
    EPILOGUE
.yes:
    mov eax, 1
    EPILOGUE

; place_player(xmm0 = x, xmm1 = feet y, xmm2 = z) -> eax 1 if you fit there
; (and you're there); else backs off along -ad, up to 3 m, trying again
place_player:
    PROLOGUE 48
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    ; the way back, flat
    movss xmm0, [ad_x]
    movss xmm1, [ad_z]
    movaps xmm2, xmm0
    mulss xmm2, xmm2
    movaps xmm3, xmm1
    mulss xmm3, xmm3
    addss xmm2, xmm3
    sqrtss xmm2, xmm2
    FLD xmm3, 0.001
    maxss xmm2, xmm3
    FLD xmm3, -0.25
    divss xmm3, xmm2
    mulss xmm0, xmm3
    mulss xmm1, xmm3
    movss [rsp+12], xmm0
    movss [rsp+16], xmm1
    mov r12d, 13
.try:
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+8]
    movss xmm2, [rsp+4]
    movss xmm3, [c_radius]
    movss xmm4, [c_body]
    call collides
    test eax, eax
    jz .fits
    movss xmm0, [rsp+0]
    addss xmm0, [rsp+12]
    movss [rsp+0], xmm0
    movss xmm0, [rsp+8]
    addss xmm0, [rsp+16]
    movss [rsp+8], xmm0
    dec r12d
    jnz .try
    xor eax, eax
    EPILOGUE
.fits:
    mov eax, [rsp+0]
    mov [p_x], eax
    mov eax, [rsp+4]
    mov [p_y], eax
    mov eax, [rsp+8]
    mov [p_z], eax
    mov dword [p_vy], 0
    mov dword [p_on_ground], 0
    mov eax, 1
    EPILOGUE

; floor_under(xmm0 = x, xmm1 = y, xmm2 = z) -> xmm0 = the walkable surface
; at or below that point (within a storey)
floor_under:
    sub rsp, 8
    movaps xmm4, xmm1
    movaps xmm1, xmm2
    movaps xmm2, xmm4
    FLD xmm3, 0.3
    call ground_height
    add rsp, 8
    ret

; ---- PORTAL: bends space ------------------------------------------------------------

; LASER: the classic portal gun (it aims its own shot)
portal_laser:
    PROLOGUE 16
    call drone_away
    test eax, eax
    jnz .drone
    mov edi, [hr_button]
    call portal_fire
    EPILOGUE
.drone:
    mov edi, [hr_button]
    movss xmm0, [ao_x]
    movss xmm1, [ao_y]
    movss xmm2, [ao_z]
    movss xmm3, [ad_x]
    movss xmm4, [ad_y]
    movss xmm5, [ad_z]
    call portal_fire_from
    EPILOGUE

; ORB: the ender orb -- you're wherever it comes to rest
portal_orb:
    PROLOGUE 32
    movss xmm0, [hr_x]
    movss xmm1, [hr_y]
    movss xmm2, [hr_z]
    call in_safe_at
    test eax, eax
    jnz .safe
    movss xmm0, [hr_x]
    movss xmm1, [hr_y]
    FLD xmm3, 0.3
    addss xmm1, xmm3
    movss xmm2, [hr_z]
    call floor_under
    movss [rsp+0], xmm0
    comiss xmm0, [c_neg_big]
    jbe .nowhere
    movss xmm0, [hr_x]
    movss xmm1, [rsp+0]
    movss xmm2, [hr_z]
    call place_player
    test eax, eax
    jz .nowhere
    call arrived
    EPILOGUE
.safe:
    call snd_portal_fizzle
    lea rdi, [m_safe_no]
    mov esi, COL_WARN
    call say
    EPILOGUE
.nowhere:
    call snd_portal_fizzle
    lea rdi, [m_ender_no]
    mov esi, COL_WARN
    call say
    EPILOGUE

; arrived -- you just moved through space: the pop, and T notes the trick
arrived:
    PROLOGUE 16
    call snd_portal_enter
    movss xmm0, [c_noise_blink]
    call noise_add
    mov edi, 1                          ; (nemesis: a portal trick)
    call nemesis_note
    EPILOGUE

; HOOK: the blink hook -- straight to where it bit
portal_hook:
    PROLOGUE 32
    ; where your eyes go: just short of the bite
    movss xmm0, [ad_x]
    FLD xmm3, 0.45
    mulss xmm0, xmm3
    movss xmm1, [hr_x]
    subss xmm1, xmm0
    movss [rsp+0], xmm1
    movss xmm0, [ad_z]
    mulss xmm0, xmm3
    movss xmm1, [hr_z]
    subss xmm1, xmm0
    movss [rsp+8], xmm1
    movss xmm0, [ad_y]
    mulss xmm0, xmm3
    movss xmm1, [hr_y]
    subss xmm1, xmm0
    movss [rsp+4], xmm1                 ; eye height there
    movss xmm0, [rsp+0]
    movss xmm2, [rsp+8]
    call in_safe_at
    test eax, eax
    jnz .safe
    ; feet: on the floor under it if that's within your height, else hanging
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+8]
    call floor_under
    movss xmm1, [rsp+4]
    subss xmm1, [c_eye]
    maxss xmm0, xmm1
    movaps xmm1, xmm0
    movss xmm0, [rsp+0]
    movss xmm2, [rsp+8]
    call place_player
    test eax, eax
    jz .nowhere
    call arrived
    call parkour_try                    ; a ledge in front? up you go
    xor eax, eax
    EPILOGUE
.safe:
    call snd_portal_fizzle
    lea rdi, [m_safe_no]
    mov esi, COL_WARN
    call say
    xor eax, eax
    EPILOGUE
.nowhere:
    call snd_portal_fizzle
    lea rdi, [m_blink_no]
    mov esi, COL_WARN
    call say
    xor eax, eax
    EPILOGUE

; GRABBER: the remote grabber (takes over the delivery) -- a window opens on
; the surface you aim at, and a hand reaches out of it for the nearest thing
; within reach that it can see from there
portal_grab:
    PROLOGUE 64
    movss xmm0, [c_rg_r]
    xor edi, edi                        ; (the world only: it opens on a surface)
    call gd_trace
    cmp eax, HT_NONE
    je .nothing
    call beam_to_hit
    movss xmm0, [hr_x]
    movss xmm1, [hr_y]
    movss xmm2, [hr_z]
    call in_safe_at
    test eax, eax
    jnz .safe
    ; the window
    mov eax, [c_rg_show]
    mov [rg_t], eax
    movss xmm0, [hr_x]
    movss [rg_x], xmm0
    movss xmm0, [hr_y]
    movss [rg_y], xmm0
    movss xmm0, [hr_z]
    movss [rg_z], xmm0
    mov eax, [hr_nx]
    mov [rg_nx], eax
    mov eax, [hr_ny]
    mov [rg_ny], eax
    mov eax, [hr_nz]
    mov [rg_nz], eax
    xor edi, edi
    call snd_portal_open
    ; the nearest thing: [rsp+0] best distance, r12 kind, r13 index
    mov eax, [c_rg_reach]
    mov [rg_best], eax
    xor r12d, r12d
    mov r13d, -1
    ; T
    movss xmm0, [t_x]
    movss xmm1, [t_y]
    FLD xmm3, 1.2
    addss xmm1, xmm3
    movss xmm2, [t_z]
    call rg_consider
    test eax, eax
    jz .items
    mov r12d, HT_T
.items:
    xor ebx, ebx
.it:
    cmp ebx, [item_count]
    jge .feeders
    imul r14d, ebx, ITEM_SIZE
    cmp dword [items+r14+ITEM_ACTIVE], 0
    je .it_n
    cmp dword [items+r14+ITEM_KIND], IT_TYLER
    jge .it_n
    movss xmm0, [items+r14+ITEM_X]
    movss xmm1, [items+r14+ITEM_Y]
    addss xmm1, [c_it_mid]
    movss xmm2, [items+r14+ITEM_Z]
    call rg_consider
    test eax, eax
    jz .it_n
    mov r12d, HT_ITEM
    mov r13d, r14d
.it_n:
    inc ebx
    jmp .it
.feeders:
    xor ebx, ebx
.fd:
    cmp ebx, [fd_count]
    jge .props
    cmp dword [fd_state+rbx*4], FD_DEAD
    je .fd_n
    movss xmm0, [fd_x+rbx*4]
    movss xmm1, [fd_y+rbx*4]
    addss xmm1, [c_fd_mid]
    movss xmm2, [fd_z+rbx*4]
    call rg_consider
    test eax, eax
    jz .fd_n
    mov r12d, HT_FEEDER
    mov r13d, ebx
.fd_n:
    inc ebx
    jmp .fd
.props:
    xor ebx, ebx
.pr:
    cmp ebx, [phys_nb]
    jge .chosen
    cmp dword [body_active+rbx*4], 0
    je .pr_n
    cmp dword [body_type+rbx*4], 2
    je .pr_n
    mov edi, ebx
    call body_centre
    call rg_consider
    test eax, eax
    jz .pr_n
    mov r12d, HT_PROP
    mov r13d, ebx
.pr_n:
    inc ebx
    jmp .pr
.chosen:
    test r12d, r12d
    jz .none
    mov eax, [c_rg_arm]
    mov [rg_arm], eax
    inc dword [rg_hits]
    cmp r12d, HT_T
    je .slap
    cmp r12d, HT_ITEM
    je .fetch
    cmp r12d, HT_FEEDER
    je .drag
    ; a box: it comes through and lands in front of you
    mov edi, r13d
    call body_centre
    movss [rg_tx], xmm0
    movss [rg_ty], xmm1
    movss [rg_tz], xmm2
    movss xmm3, [ad_x]
    addss xmm3, [gs_x]
    subss xmm3, xmm0
    movss xmm4, [gs_y]
    FLD xmm5, 0.5
    addss xmm4, xmm5
    subss xmm4, xmm1
    movss xmm5, [ad_z]
    addss xmm5, [gs_z]
    subss xmm5, xmm2
    movaps xmm0, xmm3
    movaps xmm1, xmm4
    movaps xmm2, xmm5
    mov edi, r13d
    call physics_move
    call snd_hook_hit
    EPILOGUE
.slap:
    mov eax, [t_x]
    mov [rg_tx], eax
    movss xmm0, [t_y]
    FLD xmm1, 1.2
    addss xmm0, xmm1
    movss [rg_ty], xmm0
    mov eax, [t_z]
    mov [rg_tz], eax
    movss xmm0, [c_stun_slap]
    call stun_t
    call snd_hook_hit
    lea rdi, [m_rg_t]
    mov esi, COL_GOOD
    call say
    EPILOGUE
.fetch:
    mov eax, [items+r13+ITEM_X]
    mov [rg_tx], eax
    mov eax, [items+r13+ITEM_Y]
    mov [rg_ty], eax
    mov eax, [items+r13+ITEM_Z]
    mov [rg_tz], eax
    lea rdi, [items+r13]
    call take_item
    EPILOGUE
.drag:
    mov eax, [fd_x+r13*4]
    mov [rg_tx], eax
    mov eax, [fd_y+r13*4]
    mov [rg_ty], eax
    mov eax, [fd_z+r13*4]
    mov [rg_tz], eax
    mov edi, r13d                       ; (a thief drops what it carried)
    movss xmm0, [c_fd_rg]
    call feeder_stun
    movss xmm0, [gs_x]
    movss xmm1, [gs_y]
    movss xmm2, [gs_z]
    call node_at_pos
    mov edi, r13d
    mov esi, eax
    call feeder_put
    mov edi, r13d
    movss xmm0, [c_fd_rg]
    call feeder_stun
    lea rdi, [m_rg_fd]
    mov esi, COL_WARN
    call say
    EPILOGUE
.none:
    lea rdi, [m_rg_none]
    mov esi, COL_INFO
    call say
    EPILOGUE
.safe:
    call snd_portal_fizzle
    lea rdi, [m_safe_no]
    mov esi, COL_WARN
    call say
    EPILOGUE
.nothing:
    call snd_portal_fizzle
    lea rdi, [m_rg_no]
    mov esi, COL_INFO
    call say
    EPILOGUE

; rg_consider(xmm0..2 = a thing) -> eax 1 if it's nearer the window than
; the best so far (rg_best), in front of it and in its
; sight (and then it's the best so far)
rg_consider:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    subss xmm0, [rg_x]
    subss xmm1, [rg_y]
    subss xmm2, [rg_z]
    movaps xmm3, xmm0
    mulss xmm3, [rg_nx]
    movaps xmm4, xmm1
    mulss xmm4, [rg_ny]
    addss xmm3, xmm4
    movaps xmm4, xmm2
    mulss xmm4, [rg_nz]
    addss xmm3, xmm4
    FLD xmm4, -0.3
    comiss xmm3, xmm4
    jb .no                              ; behind the surface
    mulss xmm0, xmm0
    mulss xmm1, xmm1
    addss xmm0, xmm1
    mulss xmm2, xmm2
    addss xmm0, xmm2
    sqrtss xmm0, xmm0
    movss [rsp+12], xmm0
    comiss xmm0, [rg_best]
    jae .no
    ; seen from just in front of the window
    movss xmm0, [rg_nx]
    FLD xmm3, 0.3
    mulss xmm0, xmm3
    addss xmm0, [rg_x]
    movss xmm1, [rg_ny]
    mulss xmm1, xmm3
    addss xmm1, [rg_y]
    movss xmm2, [rg_nz]
    mulss xmm2, xmm3
    addss xmm2, [rg_z]
    movss xmm3, [rsp+0]
    movss xmm4, [rsp+4]
    movss xmm5, [rsp+8]
    call line_of_sight_3d
    test eax, eax
    jz .no
    mov eax, [rsp+12]
    mov [rg_best], eax
    mov eax, 1
    EPILOGUE
.no:
    xor eax, eax
    EPILOGUE

; ---- ROD: a rigid rod ------------------------------------------------------------------

; LASER: the knocker -- rams whatever's there; off a wall, the clank carries
; from the far end (T goes to look)
rod_laser:
    PROLOGUE 16
    mov eax, [hr_kind]
    cmp eax, HT_T
    je .t
    cmp eax, HT_FEEDER
    je .fd
    cmp eax, HT_PROP
    je .prop
    cmp eax, HT_STAIRS
    je .stairs
    cmp eax, HT_NONE
    je .done
    ; the world (or an item): a clank, heard from there
    call snd_clank
    movss xmm0, [hr_x]
    movss xmm1, [hr_y]
    movss xmm2, [hr_z]
    movss xmm3, [c_clank_r]
    call enemy_hear
    bts dword [gd_told], 0
    jc .done
    lea rdi, [m_clank]
    mov esi, COL_INFO
    call say
    EPILOGUE
.t:
    movss xmm0, [c_stun_rod]
    call stun_t
    call snd_hook_hit
    lea rdi, [m_rod_t]
    mov esi, COL_GOOD
    call say
    EPILOGUE
.fd:
    mov edi, [hr_idx]
    movss xmm0, [c_fd_knock]
    call feeder_stun
    call snd_hook_hit
    lea rdi, [m_rod_fd]
    mov esi, COL_GOOD
    call say
    EPILOGUE
.prop:
    movss xmm0, [ad_x]
    mulss xmm0, [c_knock_v]
    movss xmm1, [ad_y]
    mulss xmm1, [c_knock_v]
    addss xmm1, [c_lift]
    movss xmm2, [ad_z]
    mulss xmm2, [c_knock_v]
    mov edi, [hr_idx]
    call physics_push
    call snd_hook_hit
    EPILOGUE
.stairs:
    call snd_hook_hit
    mov edi, 1
    call build_break
.done:
    EPILOGUE

; ORB: the peg launcher -- the rod digs in: a ledge out of a wall, a post
; out of a floor. On a creature it just thumps it.
rod_orb:
    PROLOGUE 16
    mov eax, [hr_kind]
    cmp eax, HT_T
    je .t
    cmp eax, HT_FEEDER
    je .fd
    call peg_add
    EPILOGUE
.t:
    movss xmm0, [c_stun_peg]
    call stun_t
    call snd_hook_hit
    EPILOGUE
.fd:
    mov edi, [hr_idx]
    movss xmm0, [c_fd_knock]
    call feeder_stun
    call snd_hook_hit
    EPILOGUE

; HOOK: the hookshot -- haul away
rod_hook:
    mov eax, 1
    ret

; GRABBER: the grappler -- latch on and haul it in; T's too heavy
rod_grab:
    PROLOGUE 16
    mov eax, [hr_kind]
    cmp eax, HT_T
    je .t
    cmp eax, HT_STAIRS
    je .stairs
    cmp eax, HT_ITEM
    je .reel
    cmp eax, HT_PROP
    je .reel
    cmp eax, HT_FEEDER
    jne .miss
    mov edi, [hr_idx]                   ; a thief lets go of what it carried
    movss xmm0, [c_half]
    call feeder_stun
    lea rdi, [m_grab_fd]
    mov esi, COL_GOOD
    call say
.reel:
    call snd_hook_hit
    mov dword [gd_tt_state], TT_REEL
    mov dword [tt_time], 0
    EPILOGUE
.t:
    movss xmm0, [c_stun_heavy]
    call stun_t
    call snd_hook_hit
    mov edi, ACH_HOOK_T
    call ach_unlock
    lea rdi, [m_heavy]
    mov esi, COL_GOOD
    call say
    EPILOGUE
.stairs:
    call snd_hook_hit
    mov edi, 1
    call build_break
    EPILOGUE
.miss:
    call snd_hook_miss
    EPILOGUE

; ---- LINE: a line that stays ---------------------------------------------------------

; LASER: the tripwire (its own aim): knee high, wall to wall along your aim,
; through where you stand
line_laser:
    PROLOGUE 64
    ; the flat direction you're facing
    movss xmm0, [p_yaw]
    call sinf
    xorps xmm0, [c_sign_mask]
    movss [rsp+0], xmm0                 ; fx
    movss [wr_fx], xmm0
    movss xmm0, [p_yaw]
    call cosf
    xorps xmm0, [c_sign_mask]
    movss [rsp+4], xmm0                 ; fz
    movss [wr_fz], xmm0
    movss xmm0, [gs_y]
    addss xmm0, [c_knee]
    movss [rsp+8], xmm0                 ; height
    movss [wr_h], xmm0
    movss xmm0, [c_one]
    call wire_reach
    movss [rsp+12], xmm0                ; forwards
    movss xmm0, [c_neg_one]
    call wire_reach
    movss [rsp+16], xmm0                ; backwards
    movss xmm0, [rsp+12]
    comiss xmm0, [c_trip_max]
    jae .nothing
    movss xmm0, [rsp+16]
    comiss xmm0, [c_trip_max]
    jae .nothing
    movss xmm0, [rsp+12]
    addss xmm0, [rsp+16]
    comiss xmm0, [c_one]
    jb .nothing
    movss [rsp+20], xmm0
    ; A behind you, B ahead
    movss xmm0, [rsp+0]
    mulss xmm0, [rsp+16]
    movss xmm1, [gs_x]
    subss xmm1, xmm0
    movss [nl_ax], xmm1
    movss xmm0, [rsp+4]
    mulss xmm0, [rsp+16]
    movss xmm1, [gs_z]
    subss xmm1, xmm0
    movss [nl_az], xmm1
    movss xmm0, [rsp+0]
    mulss xmm0, [rsp+12]
    addss xmm0, [gs_x]
    movss [nl_bx], xmm0
    movss xmm0, [rsp+4]
    mulss xmm0, [rsp+12]
    addss xmm0, [gs_z]
    movss [nl_bz], xmm0
    mov eax, [rsp+8]
    mov [nl_ay], eax
    mov [nl_by], eax
    mov edi, LN_TRIP
    movss xmm0, [c_forever]
    call line_add
    call snd_hook_hit
    lea rdi, [msg_buf]
    mov esi, 512
    lea rdx, [fmt_trip_set]
    cvttss2si ecx, [rsp+20]
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, COL_INFO
    call say
    EPILOGUE
.nothing:
    call snd_hook_miss
    lea rdi, [m_trip_none]
    mov esi, COL_WARN
    call say
    EPILOGUE

; wire_reach(xmm0 = +1 ahead / -1 behind) -> xmm0 = how far the wire runs
; that way before something solid (c_trip_max if nothing), along wr_fx/fz
; at height wr_h.
wire_reach:
    PROLOGUE 32
    movss [rsp+0], xmm0
    mov dword [rsp+4], 0
.s:
    movss xmm0, [rsp+4]
    addss xmm0, [c_step]
    comiss xmm0, [c_trip_max]
    jae .max
    movss [rsp+4], xmm0
    mulss xmm0, [rsp+0]
    movss xmm1, [wr_fx]
    mulss xmm1, xmm0
    addss xmm1, [gs_x]
    movss xmm2, [wr_fz]
    mulss xmm2, xmm0
    addss xmm2, [gs_z]
    movaps xmm0, xmm1
    movss xmm1, [wr_h]
    movss xmm3, xmm1
    call solid_point
    test eax, eax
    jz .s
    movss xmm0, [rsp+4]
    subss xmm0, [c_step]
    EPILOGUE
.max:
    movss xmm0, [c_trip_max]
    EPILOGUE

; ORB: the bola -- tangles the nearest creature where it lands; a miss lies
; open on the floor as a snare
line_orb:
    PROLOGUE 32
    ; T close by?
    movss xmm0, [t_x]
    subss xmm0, [hr_x]
    mulss xmm0, xmm0
    movss xmm1, [t_z]
    subss xmm1, [hr_z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    comiss xmm0, [c_bola_r]
    jae .feeders
    movss xmm0, [t_y]
    subss xmm0, [hr_y]
    andps xmm0, [c_abs_mask]
    comiss xmm0, [c_t_h]
    jae .feeders
    movss xmm0, [c_stun_bola]
    call stun_t
    call snd_hook_hit
    lea rdi, [m_bola_t]
    mov esi, COL_GOOD
    call say
    EPILOGUE
.feeders:
    xor ebx, ebx
.f:
    cmp ebx, [fd_count]
    jge .snare
    cmp dword [fd_state+rbx*4], FD_DEAD
    je .n
    movss xmm0, [fd_x+rbx*4]
    subss xmm0, [hr_x]
    mulss xmm0, xmm0
    movss xmm1, [fd_y+rbx*4]
    subss xmm1, [hr_y]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [fd_z+rbx*4]
    subss xmm1, [hr_z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    comiss xmm0, [c_bola_r]
    jae .n
    mov edi, ebx
    movss xmm0, [c_fd_bola]
    call feeder_stun
    call snd_hook_hit
    lea rdi, [m_bola_fd]
    mov esi, COL_GOOD
    call say
    EPILOGUE
.n:
    inc ebx
    jmp .f
.snare:
    movss xmm0, [hr_x]
    movss xmm1, [hr_y]
    movss xmm2, [hr_z]
    call floor_under
    comiss xmm0, [c_neg_big]
    jbe .gone
    movss [nl_ay], xmm0
    movss [nl_by], xmm0
    mov eax, [hr_x]
    mov [nl_ax], eax
    mov [nl_bx], eax
    mov eax, [hr_z]
    mov [nl_az], eax
    mov [nl_bz], eax
    mov edi, LN_SNARE
    movss xmm0, [c_snare_life]
    call line_add
    lea rdi, [m_snare_set]
    mov esi, COL_INFO
    call say
.gone:
    EPILOGUE

; HOOK: the zipline gun -- a cable from over your head to where the hook
; bit. If it runs downhill from you, you're on it. -> eax 0 (no haul)
line_hook:
    PROLOGUE 48
    ; your end: well over your head, but under the ceiling
    movss xmm0, [p_y]
    call floor_of_height
    inc eax
    cvtsi2ss xmm0, eax
    mulss xmm0, [c_fh]
    subss xmm0, [c_ceil_gap]
    movss xmm1, [p_y]
    addss xmm1, [c_zip_top]
    minss xmm0, xmm1
    movss [rsp+4], xmm0
    mov eax, [p_x]
    mov [rsp+0], eax
    mov eax, [p_z]
    mov [rsp+8], eax
    ; the far end: where it bit, but high enough to hang from
    movss xmm0, [hr_x]
    movss xmm1, [hr_y]
    movss xmm2, [hr_z]
    call floor_under
    addss xmm0, [c_zip_low]
    maxss xmm0, [hr_y]
    movss [rsp+16], xmm0
    mov eax, [hr_x]
    mov [rsp+12], eax
    mov eax, [hr_z]
    mov [rsp+20], eax
    ; ...and not through a wall
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+8]
    movss xmm3, [rsp+12]
    movss xmm4, [rsp+16]
    movss xmm5, [rsp+20]
    call line_of_sight_3d
    test eax, eax
    jz .blocked
    ; the high end is A
    movss xmm0, [rsp+4]
    subss xmm0, [rsp+16]
    comiss xmm0, [c_downhill]
    jb .uphill
    mov eax, [rsp+0]
    mov [nl_ax], eax
    mov eax, [rsp+4]
    mov [nl_ay], eax
    mov eax, [rsp+8]
    mov [nl_az], eax
    mov eax, [rsp+12]
    mov [nl_bx], eax
    mov eax, [rsp+16]
    mov [nl_by], eax
    mov eax, [rsp+20]
    mov [nl_bz], eax
    mov edi, LN_ZIP
    movss xmm0, [c_forever]
    call line_add
    test eax, eax
    js .done
    ; and you're riding it
    mov eax, [ln_slot+rax*4]
    add eax, [zip_static]
    mov [zip_active], eax
    mov dword [zip_t], 0
    mov dword [zip_speed], __float32__(3.0)
    mov dword [p_mode], MODE_ZIP
    xor eax, eax
    EPILOGUE
.uphill:
    mov eax, [rsp+12]
    mov [nl_ax], eax
    mov eax, [rsp+16]
    mov [nl_ay], eax
    mov eax, [rsp+20]
    mov [nl_az], eax
    mov eax, [rsp+0]
    mov [nl_bx], eax
    mov eax, [rsp+4]
    mov [nl_by], eax
    mov eax, [rsp+8]
    mov [nl_bz], eax
    mov edi, LN_ZIP
    movss xmm0, [c_forever]
    call line_add
    lea rdi, [m_zip_up]
    mov esi, COL_INFO
    call say
    jmp .done
.blocked:
    lea rdi, [m_zip_bad]
    mov esi, COL_WARN
    call say
.done:
    xor eax, eax
    EPILOGUE

; GRABBER: the capture line (its own delivery) -- strung straight from your
; hand to the first surface; it snags what it passes (lines_update)
line_grab:
    PROLOGUE 16
    movss xmm0, [c_cap_r]
    xor edi, edi
    call gd_trace
    cmp eax, HT_NONE
    je .nothing
    mov eax, [hd_x]
    mov [nl_ax], eax
    mov eax, [hd_y]
    mov [nl_ay], eax
    mov eax, [hd_z]
    mov [nl_az], eax
    mov eax, [hr_x]
    mov [nl_bx], eax
    mov eax, [hr_y]
    mov [nl_by], eax
    mov eax, [hr_z]
    mov [nl_bz], eax
    mov edi, LN_CAPTURE
    movss xmm0, [c_line_life]
    call line_add
    call snd_hook_hit
    EPILOGUE
.nothing:
    call snd_hook_miss
    lea rdi, [m_cap_none]
    mov esi, COL_WARN
    call say
    EPILOGUE

; ---- SMOKE: nobody sees through it -------------------------------------------------

; smoke_here(xmm0..2 = where, xmm3 = radius, xmm4 = life, edi = attached)
; -- and T learns about smoke if it gets you away
smoke_here:
    PROLOGUE 16
    call gadget_smoke
    call snd_smoke
    mov edi, 5                          ; (nemesis: smoke)
    call nemesis_note
    EPILOGUE

; LASER: a smoke wall along the beam
smoke_laser:
    PROLOGUE 32
    movss xmm0, [c_smoke_w0]
    movss [rsp+0], xmm0                 ; distance of the next puff
    mov r12d, 8
.puff:
    movss xmm0, [rsp+0]
    comiss xmm0, [hr_dist]
    ja .last
    movss xmm0, [ad_x]
    mulss xmm0, [rsp+0]
    addss xmm0, [ao_x]
    movss xmm1, [ad_y]
    mulss xmm1, [rsp+0]
    addss xmm1, [ao_y]
    movss xmm2, [ad_z]
    mulss xmm2, [rsp+0]
    addss xmm2, [ao_z]
    movss xmm3, [c_smoke_w]
    movss xmm4, [c_smoke_wl]
    mov edi, -1
    call smoke_here
    movss xmm0, [rsp+0]
    addss xmm0, [c_smoke_ws]
    movss [rsp+0], xmm0
    dec r12d
    jnz .puff
    EPILOGUE
.last:
    cmp r12d, 8
    jne .done
    movss xmm0, [hr_x]                  ; (point blank: one puff where it hit)
    movss xmm1, [hr_y]
    movss xmm2, [hr_z]
    movss xmm3, [c_smoke_w]
    movss xmm4, [c_smoke_wl]
    mov edi, -1
    call smoke_here
.done:
    EPILOGUE

; ORB: the smoke grenade
smoke_orb:
    PROLOGUE 16
    movss xmm0, [hr_x]
    movss xmm1, [hr_y]
    movss xmm2, [hr_z]
    movss xmm3, [c_smoke_g]
    movss xmm4, [c_smoke_gl]
    mov edi, -1
    call smoke_here
    EPILOGUE

; HOOK: the smoke trail -- haul yourself out, smoke where you were and on
; the way. -> eax 1 (haul)
smoke_hook:
    PROLOGUE 16
    movss xmm0, [p_x]
    movss xmm1, [p_y]
    addss xmm1, [c_one]
    movss xmm2, [p_z]
    movss xmm3, [c_smoke_t]
    movss xmm4, [c_smoke_tl]
    mov edi, -1
    call smoke_here
    movss xmm0, [hr_x]                  ; ...and halfway
    addss xmm0, [p_x]
    mulss xmm0, [c_half]
    movss xmm1, [hr_y]
    addss xmm1, [p_y]
    mulss xmm1, [c_half]
    movss xmm2, [hr_z]
    addss xmm2, [p_z]
    mulss xmm2, [c_half]
    movss xmm3, [c_smoke_t]
    movss xmm4, [c_smoke_tl]
    mov edi, -1
    call smoke_here
    mov eax, 1
    EPILOGUE

; GRABBER: the smoke hood -- smoke that follows what it grabbed
smoke_grab:
    PROLOGUE 16
    mov eax, [hr_kind]
    cmp eax, HT_T
    je .t
    cmp eax, HT_FEEDER
    je .fd
    movss xmm0, [hr_x]
    movss xmm1, [hr_y]
    movss xmm2, [hr_z]
    movss xmm3, [c_smoke_x]
    movss xmm4, [c_smoke_xl]
    mov edi, -1
    call smoke_here
    EPILOGUE
.t:
    movss xmm0, [t_x]
    movss xmm1, [t_y]
    movss xmm2, [t_z]
    movss xmm3, [c_smoke_h]
    movss xmm4, [c_smoke_hl]
    xor edi, edi
    call smoke_here
    lea rdi, [m_hood_t]
    mov esi, COL_GOOD
    call say
    EPILOGUE
.fd:
    mov edi, [hr_idx]
    movss xmm0, [fd_x+rdi*4]
    movss xmm1, [fd_y+rdi*4]
    movss xmm2, [fd_z+rdi*4]
    movss xmm3, [c_smoke_h]
    movss xmm4, [c_smoke_hl]
    inc edi
    call smoke_here
    EPILOGUE

; =============================================================================
; what gadgets leave in the world: lines, smoke, pegs
; =============================================================================

section .bss
alignb 4
nl_ax       resd 1                      ; the ends of the next line_add
nl_ay       resd 1
nl_az       resd 1
nl_bx       resd 1
nl_by       resd 1
nl_bz       resd 1
rg_best     resd 1                      ; portal_grab: nearest so far
wr_fx       resd 1                      ; line_laser: the wire's direction...
wr_fz       resd 1
wr_h        resd 1                      ; ...and height
section .text

; ridden(ebx = line) -> eax 1 if you're riding it right now. leaf
ridden:
    xor eax, eax
    cmp dword [ln_type+rbx*4], LN_ZIP
    jne .no
    cmp dword [p_mode], MODE_ZIP
    jne .no
    mov ecx, [ln_slot+rbx*4]
    add ecx, [zip_static]
    cmp ecx, [zip_active]
    jne .no
    mov eax, 1
.no:
    ret

; oldest(edi = type, or -1 any) -> eax = the oldest such line you're not on
; (-1 none)
oldest:
    PROLOGUE 16
    mov r12d, edi
    mov r13d, -1
    movss xmm0, [c_big]
    movss [rsp+0], xmm0
    xor ebx, ebx
.l:
    cmp ebx, MAXLN
    jge .done
    cmp dword [ln_type+rbx*4], LN_FREE
    je .n
    test r12d, r12d
    js .any
    cmp [ln_type+rbx*4], r12d
    jne .n
.any:
    call ridden
    test eax, eax
    jnz .n
    movss xmm0, [ln_birth+rbx*4]
    comiss xmm0, [rsp+0]
    jae .n
    movss [rsp+0], xmm0
    mov r13d, ebx
.n:
    inc ebx
    jmp .l
.done:
    mov eax, r13d
    EPILOGUE

; line_add(edi = LN_ type, xmm0 = life) -> eax = the line (nl_* its ends).
; Full up: the oldest one goes. A zipline needs one of your NGZIP slots too.
line_add:
    PROLOGUE 32
    mov r12d, edi
    movss [rsp+0], xmm0
    xor ebx, ebx
.free:
    cmp dword [ln_type+rbx*4], LN_FREE
    je .have_line
    inc ebx
    cmp ebx, MAXLN
    jl .free
    mov edi, -1
    call oldest
    test eax, eax
    js .fail
    mov ebx, eax
    mov edi, ebx
    call line_free
.have_line:
    mov r13d, -1
    cmp r12d, LN_ZIP
    jne .fill
    ; a zip slot nobody's using
    xor r14d, r14d
.slot:
    xor ecx, ecx
.used:
    cmp ecx, MAXLN
    jge .got_slot
    cmp dword [ln_type+rcx*4], LN_ZIP
    jne .un
    cmp [ln_slot+rcx*4], r14d
    je .taken
.un:
    inc ecx
    jmp .used
.taken:
    inc r14d
    cmp r14d, NGZIP
    jl .slot
    ; all three strung: the oldest zipline goes
    mov edi, LN_ZIP
    call oldest
    test eax, eax
    js .fail
    mov r14d, [ln_slot+rax*4]
    mov edi, eax
    call line_free
.got_slot:
    mov r13d, r14d
.fill:
    mov [ln_type+rbx*4], r12d
    mov eax, [nl_ax]
    mov [ln_ax+rbx*4], eax
    mov eax, [nl_ay]
    mov [ln_ay+rbx*4], eax
    mov eax, [nl_az]
    mov [ln_az+rbx*4], eax
    mov eax, [nl_bx]
    mov [ln_bx+rbx*4], eax
    mov eax, [nl_by]
    mov [ln_by+rbx*4], eax
    mov eax, [nl_bz]
    mov [ln_bz+rbx*4], eax
    mov eax, [rsp+0]
    mov [ln_life+rbx*4], eax
    mov eax, [gd_clock]
    mov [ln_birth+rbx*4], eax
    mov [ln_slot+rbx*4], r13d
    test r13d, r13d
    js .done
    ; your zipline goes in the traverse tables: riding and drawing it
    mov eax, [zip_static]
    add eax, r13d
    mov dword [zip_grav+rax*4], 1
    mov ecx, [nl_ax]
    mov [zip_ax+rax*4], ecx
    mov ecx, [nl_ay]
    mov [zip_ay+rax*4], ecx
    mov ecx, [nl_az]
    mov [zip_az+rax*4], ecx
    mov ecx, [nl_bx]
    mov [zip_bx+rax*4], ecx
    mov ecx, [nl_by]
    mov [zip_by+rax*4], ecx
    mov ecx, [nl_bz]
    mov [zip_bz+rax*4], ecx
.done:
    mov eax, ebx
    EPILOGUE
.fail:
    mov eax, -1
    EPILOGUE

; line_free(edi = line) -- take it down; whatever it held drops
line_free:
    PROLOGUE 32
    mov ebx, edi
    mov eax, [ln_type+rbx*4]
    cmp eax, LN_FREE
    je .done
    cmp eax, LN_ZIP
    jne .held
    call ridden
    test eax, eax
    jz .park
    mov dword [p_mode], MODE_WALK
    mov dword [zip_active], -1
    mov dword [p_on_ground], 0
.park:
    mov edi, [ln_slot+rbx*4]
    call park_slot
    jmp .gone
.held:
    ; feeders on it fall off, dazed
    xor r12d, r12d
.f:
    cmp r12d, NFEED
    jge .items
    cmp [fd_line+r12*4], ebx
    jne .fn
    mov dword [fd_line+r12*4], -1
    movss xmm0, [fd_x+r12*4]
    movss xmm1, [fd_y+r12*4]
    movss xmm2, [fd_z+r12*4]
    call floor_under
    movaps xmm1, xmm0
    movss xmm0, [fd_x+r12*4]
    movss xmm2, [fd_z+r12*4]
    call node_at_pos
    mov edi, r12d
    mov esi, eax
    call feeder_put
    mov edi, r12d
    movss xmm0, [c_two]
    call feeder_stun
.fn:
    inc r12d
    jmp .f
.items:
    ; items drop to the floor
    xor r12d, r12d
.i:
    cmp r12d, [hi_n]
    jge .gone
    cmp [hi_line+r12*4], ebx
    jne .in
    mov r13d, [hi_item+r12*4]
    movss xmm0, [items+r13+ITEM_X]
    movss xmm1, [items+r13+ITEM_Y]
    addss xmm1, [c_hang_it]
    movss xmm2, [items+r13+ITEM_Z]
    call floor_under
    comiss xmm0, [c_neg_big]
    jbe .unhold
    movss [items+r13+ITEM_Y], xmm0
.unhold:
    mov eax, [hi_n]
    dec eax
    mov [hi_n], eax
    mov ecx, [hi_item+rax*4]
    mov [hi_item+r12*4], ecx
    mov ecx, [hi_line+rax*4]
    mov [hi_line+r12*4], ecx
    mov ecx, [hi_t+rax*4]
    mov [hi_t+r12*4], ecx
    jmp .i
.in:
    inc r12d
    jmp .i
.gone:
    mov dword [ln_type+rbx*4], LN_FREE
.done:
    EPILOGUE

; seg_closest(edi = line, xmm0..2 = point) -> xmm0 = distance to the line,
; xmm1 = how far along it (0 at A, 1 at B). leaf
seg_closest:
    movss xmm3, [ln_bx+rdi*4]
    subss xmm3, [ln_ax+rdi*4]
    movss xmm4, [ln_by+rdi*4]
    subss xmm4, [ln_ay+rdi*4]
    movss xmm5, [ln_bz+rdi*4]
    subss xmm5, [ln_az+rdi*4]
    subss xmm0, [ln_ax+rdi*4]
    subss xmm1, [ln_ay+rdi*4]
    subss xmm2, [ln_az+rdi*4]
    movaps xmm6, xmm0
    mulss xmm6, xmm3
    movaps xmm7, xmm1
    mulss xmm7, xmm4
    addss xmm6, xmm7
    movaps xmm7, xmm2
    mulss xmm7, xmm5
    addss xmm6, xmm7                    ; w.d
    movaps xmm7, xmm3
    mulss xmm7, xmm3
    movss [seg_tmp], xmm7
    movaps xmm7, xmm4
    mulss xmm7, xmm4
    addss xmm7, [seg_tmp]
    movss [seg_tmp], xmm7
    movaps xmm7, xmm5
    mulss xmm7, xmm5
    addss xmm7, [seg_tmp]               ; d.d
    maxss xmm7, [c_tiny_g]
    divss xmm6, xmm7
    maxss xmm6, [c_zero]
    minss xmm6, [c_one]                 ; t
    mulss xmm3, xmm6
    mulss xmm4, xmm6
    mulss xmm5, xmm6
    subss xmm0, xmm3
    subss xmm1, xmm4
    subss xmm2, xmm5
    mulss xmm0, xmm0
    mulss xmm1, xmm1
    addss xmm0, xmm1
    mulss xmm2, xmm2
    addss xmm0, xmm2
    sqrtss xmm0, xmm0
    movaps xmm1, xmm6
    ret

; line_point(edi = line, xmm0 = t) -> xmm0..2 = the point that far along it. leaf
line_point:
    movaps xmm3, xmm0
    movss xmm0, [ln_bx+rdi*4]
    subss xmm0, [ln_ax+rdi*4]
    mulss xmm0, xmm3
    addss xmm0, [ln_ax+rdi*4]
    movss xmm1, [ln_by+rdi*4]
    subss xmm1, [ln_ay+rdi*4]
    mulss xmm1, xmm3
    addss xmm1, [ln_ay+rdi*4]
    movss xmm2, [ln_bz+rdi*4]
    subss xmm2, [ln_az+rdi*4]
    mulss xmm2, xmm3
    addss xmm2, [ln_az+rdi*4]
    ret

; slide(edi = line, xmm0 = t, xmm1 = dt) -> xmm0 = t after sliding downhill
; along it for dt (a level line holds things where they are). leaf-ish
slide:
    movss xmm2, [ln_ay+rdi*4]
    subss xmm2, [ln_by+rdi*4]           ; > 0: B is lower
    movss xmm3, xmm2
    andps xmm3, [c_abs_mask]
    FLD xmm4, 0.2
    comiss xmm3, xmm4
    jb .level
    ; length
    movss xmm3, [ln_bx+rdi*4]
    subss xmm3, [ln_ax+rdi*4]
    mulss xmm3, xmm3
    movss xmm4, [ln_bz+rdi*4]
    subss xmm4, [ln_az+rdi*4]
    mulss xmm4, xmm4
    addss xmm3, xmm4
    sqrtss xmm3, xmm3
    maxss xmm3, [c_one]
    movss xmm4, [c_slide]
    mulss xmm4, xmm1
    divss xmm4, xmm3                    ; t per dt
    comiss xmm2, [c_zero]
    ja .down
    xorps xmm4, [c_sign_mask]
.down:
    addss xmm0, xmm4
    maxss xmm0, [c_zero]
    minss xmm0, [c_one]
.level:
    ret

; alarm(rdi = format with a %s for the floor, xmm0 = height it happened at)
alarm:
    PROLOGUE 16
    mov r12, rdi
    call floor_of_height
    mov edi, eax
    call floor_name
    mov rcx, rax
    lea rdi, [msg_buf]
    mov esi, 512
    mov rdx, r12
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, COL_WARN
    call say
    call snd_hook_hit
    EPILOGUE

; lines_update(xmm0 = dt) -- lines age; capture lines snag and carry;
; tripwires and snares go off (and tell you)
lines_update:
    PROLOGUE 48
    movss [rsp+0], xmm0
    xor ebx, ebx
.l:
    cmp ebx, MAXLN
    jge .held
    mov eax, [ln_type+rbx*4]
    cmp eax, LN_FREE
    je .n
    movss xmm0, [ln_life+rbx*4]
    subss xmm0, [rsp+0]
    movss [ln_life+rbx*4], xmm0
    comiss xmm0, [c_zero]
    ja .alive
    mov edi, ebx
    call line_free
    jmp .n
.alive:
    cmp eax, LN_CAPTURE
    je .capture
    cmp eax, LN_TRIP
    je .trip
    cmp eax, LN_SNARE
    je .snare
    jmp .n
.capture:
    ; T walks through it
    movss xmm0, [t_stun]
    comiss xmm0, [c_zero]
    ja .cap_feeders
    mov edi, ebx
    movss xmm0, [t_x]
    movss xmm1, [t_y]
    addss xmm1, [c_one]
    movss xmm2, [t_z]
    call seg_closest
    comiss xmm0, [c_snap_t]
    jae .cap_feeders
    movss xmm0, [c_snap_t]
    call stun_t
    lea rdi, [m_cap_t]
    mov esi, COL_WARN
    call say
    mov edi, ebx
    call line_free
    jmp .n
.cap_feeders:
    xor r12d, r12d
.cf:
    cmp r12d, [fd_count]
    jge .cap_items
    cmp dword [fd_line+r12*4], 0
    jge .cfn
    cmp dword [fd_state+r12*4], FD_DEAD
    je .cfn
    mov edi, ebx
    movss xmm0, [fd_x+r12*4]
    movss xmm1, [fd_y+r12*4]
    addss xmm1, [c_fd_mid]
    movss xmm2, [fd_z+r12*4]
    call seg_closest
    comiss xmm0, [c_catch_fd]
    jae .cfn
    mov [fd_line+r12*4], ebx
    movss [fd_lt+r12*4], xmm1
    mov edi, r12d
    movss xmm0, [c_one]
    call feeder_stun
    lea rdi, [m_cap_fd]
    mov esi, COL_GOOD
    call say
    mov edi, ACH_CONVEYOR
    call ach_unlock
.cfn:
    inc r12d
    jmp .cf
.cap_items:
    xor r12d, r12d
.ci:
    cmp r12d, [item_count]
    jge .n
    cmp dword [hi_n], MAXHELD
    jge .n
    imul r13d, r12d, ITEM_SIZE
    cmp dword [items+r13+ITEM_ACTIVE], 0
    je .cin
    cmp dword [items+r13+ITEM_KIND], IT_TYLER
    jge .cin
    ; not already on a line
    xor ecx, ecx
.already:
    cmp ecx, [hi_n]
    jge .loose
    cmp [hi_item+rcx*4], r13d
    je .cin
    inc ecx
    jmp .already
.loose:
    mov edi, ebx
    movss xmm0, [items+r13+ITEM_X]
    movss xmm1, [items+r13+ITEM_Y]
    addss xmm1, [c_half]
    movss xmm2, [items+r13+ITEM_Z]
    call seg_closest
    comiss xmm0, [c_catch_it]
    jae .cin
    mov eax, [hi_n]
    mov [hi_item+rax*4], r13d
    mov [hi_line+rax*4], ebx
    movss [hi_t+rax*4], xmm1
    inc dword [hi_n]
.cin:
    inc r12d
    jmp .ci
.trip:
    movss xmm0, [t_stun]
    comiss xmm0, [c_zero]
    ja .trip_feeders
    mov edi, ebx
    movss xmm0, [t_x]
    movss xmm1, [t_y]
    addss xmm1, [c_knee]
    movss xmm2, [t_z]
    call seg_closest
    comiss xmm0, [c_trip_d]
    jae .trip_feeders
    movss xmm0, [c_stun_trip]
    call stun_t
    lea rdi, [fmt_trip_t]
    movss xmm0, [t_y]
    call alarm
    mov edi, ebx
    call line_free
    jmp .n
.trip_feeders:
    xor r12d, r12d
.tf:
    cmp r12d, [fd_count]
    jge .n
    cmp dword [fd_state+r12*4], FD_DEAD
    je .tfn
    cmp dword [fd_line+r12*4], 0
    jge .tfn
    mov edi, ebx
    movss xmm0, [fd_x+r12*4]
    movss xmm1, [fd_y+r12*4]
    addss xmm1, [c_fd_mid]
    movss xmm2, [fd_z+r12*4]
    call seg_closest
    comiss xmm0, [c_trip_d]
    jae .tfn
    mov edi, r12d
    movss xmm0, [c_fd_knock]
    call feeder_stun
    lea rdi, [fmt_trip_fd]
    movss xmm0, [fd_y+r12*4]
    call alarm
    mov edi, ebx
    call line_free
    jmp .n
.tfn:
    inc r12d
    jmp .tf
.snare:
    movss xmm0, [t_stun]
    comiss xmm0, [c_zero]
    ja .snare_feeders
    mov edi, ebx
    movss xmm0, [t_x]
    movss xmm1, [t_y]
    movss xmm2, [t_z]
    call seg_closest
    comiss xmm0, [c_snare_d]
    jae .snare_feeders
    movss xmm0, [c_stun_snare]
    call stun_t
    call snd_hook_hit
    lea rdi, [m_snare_t]
    mov esi, COL_GOOD
    call say
    mov edi, ebx
    call line_free
    jmp .n
.snare_feeders:
    xor r12d, r12d
.sf:
    cmp r12d, [fd_count]
    jge .n
    cmp dword [fd_state+r12*4], FD_DEAD
    je .sfn
    mov edi, ebx
    movss xmm0, [fd_x+r12*4]
    movss xmm1, [fd_y+r12*4]
    movss xmm2, [fd_z+r12*4]
    call seg_closest
    comiss xmm0, [c_snare_d]
    jae .sfn
    mov edi, r12d
    movss xmm0, [c_fd_bola]
    call feeder_stun
    lea rdi, [m_snare_fd]
    mov esi, COL_GOOD
    call say
    mov edi, ebx
    call line_free
    jmp .n
.sfn:
    inc r12d
    jmp .sf
.n:
    inc ebx
    jmp .l
.held:
    ; feeders on capture lines slide down them, hanging, dazed
    xor ebx, ebx
.hf:
    cmp ebx, NFEED
    jge .hi
    mov r12d, [fd_line+rbx*4]
    test r12d, r12d
    js .hfn
    cmp dword [ln_type+r12*4], LN_CAPTURE
    je .hf_on
    mov dword [fd_line+rbx*4], -1
    jmp .hfn
.hf_on:
    mov edi, r12d
    movss xmm0, [fd_lt+rbx*4]
    movss xmm1, [rsp+0]
    call slide
    movss [fd_lt+rbx*4], xmm0
    mov edi, r12d
    call line_point
    movss [rsp+4], xmm0
    movss [rsp+8], xmm1
    movss [rsp+12], xmm2
    call floor_under
    movss xmm1, [rsp+8]
    subss xmm1, [c_hang_fd]
    maxss xmm1, xmm0
    movss [fd_y+rbx*4], xmm1
    mov eax, [rsp+4]
    mov [fd_x+rbx*4], eax
    mov eax, [rsp+12]
    mov [fd_z+rbx*4], eax
    mov edi, ebx
    movss xmm0, [c_half]
    call feeder_stun
.hfn:
    inc ebx
    jmp .hf
.hi:
    ; ...and so do items
    xor ebx, ebx
.hl:
    cmp ebx, [hi_n]
    jge .done
    mov r13d, [hi_item+rbx*4]
    mov r12d, [hi_line+rbx*4]
    cmp dword [items+r13+ITEM_ACTIVE], 0
    je .unhold
    cmp dword [ln_type+r12*4], LN_CAPTURE
    jne .unhold
    mov edi, r12d
    movss xmm0, [hi_t+rbx*4]
    movss xmm1, [rsp+0]
    call slide
    movss [hi_t+rbx*4], xmm0
    mov edi, r12d
    call line_point
    movss [rsp+4], xmm0
    movss [rsp+8], xmm1
    movss [rsp+12], xmm2
    call floor_under
    movss xmm1, [rsp+8]
    subss xmm1, [c_hang_it]
    maxss xmm1, xmm0
    movss [items+r13+ITEM_Y], xmm1
    mov eax, [rsp+4]
    mov [items+r13+ITEM_X], eax
    mov eax, [rsp+12]
    mov [items+r13+ITEM_Z], eax
    movaps xmm0, xmm1
    call floor_of_height
    mov [items+r13+ITEM_F], eax
    inc ebx
    jmp .hl
.unhold:
    mov eax, [hi_n]
    dec eax
    mov [hi_n], eax
    mov ecx, [hi_item+rax*4]
    mov [hi_item+rbx*4], ecx
    mov ecx, [hi_line+rax*4]
    mov [hi_line+rbx*4], ecx
    mov ecx, [hi_t+rax*4]
    mov [hi_t+rbx*4], ecx
    jmp .hl
.done:
    EPILOGUE

; gadget_line(edi = LN_ type) -> eax = how many are strung. leaf
gadget_line:
    xor eax, eax
    xor ecx, ecx
.l:
    cmp [ln_type+rcx*4], edi
    jne .n
    inc eax
.n:
    inc ecx
    cmp ecx, MAXLN
    jl .l
    ret

; ---- smoke ------------------------------------------------------------------------

; gadget_smoke(xmm0..2 = centre, xmm3 = radius, xmm4 = life, edi = -1 still /
; 0 follows T / 1+i follows feeder i) -- a cloud (full up: the thinnest goes)
gadget_smoke:
    mov eax, [sm_count]
    cmp eax, MAXSM
    jl .new
    ; replace the one closest to fading away
    xor eax, eax
    xor ecx, ecx
    movss xmm5, [c_big]
.min:
    comiss xmm5, [sm_life+rcx*4]
    jbe .mn
    movss xmm5, [sm_life+rcx*4]
    mov eax, ecx
.mn:
    inc ecx
    cmp ecx, MAXSM
    jl .min
    jmp .set
.new:
    inc dword [sm_count]
.set:
    movss [sm_x+rax*4], xmm0
    movss [sm_y+rax*4], xmm1
    movss [sm_z+rax*4], xmm2
    movss [sm_r+rax*4], xmm3
    movss [sm_life+rax*4], xmm4
    movss [sm_life0+rax*4], xmm4
    mov [sm_att+rax*4], edi
    ret

; smoke_r(ecx = cloud) -> xmm0 = its radius now: it blooms, then thins. leaf
smoke_r:
    movss xmm0, [sm_life0+rcx*4]
    subss xmm0, [sm_life+rcx*4]
    divss xmm0, [c_grow]
    minss xmm0, [c_one]
    FLD xmm1, 0.6
    mulss xmm0, xmm1
    FLD xmm1, 0.4
    addss xmm0, xmm1
    movss xmm1, [sm_life+rcx*4]
    divss xmm1, [c_fade]
    minss xmm1, [c_one]
    mulss xmm0, xmm1
    mulss xmm0, [sm_r+rcx*4]
    ret

; smoke_update(xmm0 = dt) -- clouds thin out; hoods follow their wearer
smoke_update:
    PROLOGUE 16
    movss [rsp+0], xmm0
    xor ebx, ebx
.c:
    cmp ebx, [sm_count]
    jge .done
    movss xmm0, [sm_life+rbx*4]
    subss xmm0, [rsp+0]
    movss [sm_life+rbx*4], xmm0
    comiss xmm0, [c_zero]
    ja .alive
    ; gone: the last one takes its place
    mov eax, [sm_count]
    dec eax
    mov [sm_count], eax
    mov ecx, [sm_x+rax*4]
    mov [sm_x+rbx*4], ecx
    mov ecx, [sm_y+rax*4]
    mov [sm_y+rbx*4], ecx
    mov ecx, [sm_z+rax*4]
    mov [sm_z+rbx*4], ecx
    mov ecx, [sm_r+rax*4]
    mov [sm_r+rbx*4], ecx
    mov ecx, [sm_life+rax*4]
    mov [sm_life+rbx*4], ecx
    mov ecx, [sm_life0+rax*4]
    mov [sm_life0+rbx*4], ecx
    mov ecx, [sm_att+rax*4]
    mov [sm_att+rbx*4], ecx
    jmp .c
.alive:
    mov eax, [sm_att+rbx*4]
    test eax, eax
    js .next
    jnz .feeder
    mov ecx, [t_x]
    mov [sm_x+rbx*4], ecx
    movss xmm0, [t_y]
    FLD xmm1, 1.6
    addss xmm0, xmm1
    movss [sm_y+rbx*4], xmm0
    mov ecx, [t_z]
    mov [sm_z+rbx*4], ecx
    jmp .next
.feeder:
    dec eax
    cmp dword [fd_state+rax*4], FD_DEAD
    jne .follow
    mov dword [sm_att+rbx*4], -1
    jmp .next
.follow:
    mov ecx, [fd_x+rax*4]
    mov [sm_x+rbx*4], ecx
    movss xmm0, [fd_y+rax*4]
    addss xmm0, [c_fd_mid]
    movss [sm_y+rbx*4], xmm0
    mov ecx, [fd_z+rax*4]
    mov [sm_z+rbx*4], ecx
.next:
    inc ebx
    jmp .c
.done:
    EPILOGUE

; smoke_blocks(xmm0..2 = A, xmm3..5 = B) -> eax 1 if smoke hides B from A.
; Called by line_of_sight_3d, so every sight line in the game -- T's, the
; feeders', your aim -- goes blind through smoke. (Once T has learned your
; smoke, it doesn't hide you from him up close: nm_smoke_see.)
smoke_blocks:
    xor eax, eax
    cmp dword [sm_count], 0
    je .out
    push rbx
    subss xmm3, xmm0                    ; d = B - A
    subss xmm4, xmm1
    subss xmm5, xmm2
    movss [sb_ax], xmm0
    movss [sb_ay], xmm1
    movss [sb_az], xmm2
    movss [sb_dx], xmm3
    movss [sb_dy], xmm4
    movss [sb_dz], xmm5
    mulss xmm3, xmm3
    mulss xmm4, xmm4
    addss xmm3, xmm4
    mulss xmm5, xmm5
    addss xmm3, xmm5
    movss [sb_dd], xmm3
    sqrtss xmm3, xmm3
    comiss xmm3, [nm_smoke_see]
    jb .clear
    movss xmm3, [sb_dd]
    maxss xmm3, [c_tiny_g]
    movss [sb_dd], xmm3
    xor ebx, ebx
.c:
    cmp ebx, [sm_count]
    jge .clear
    mov ecx, ebx
    call smoke_r
    mulss xmm0, [c_block]
    mulss xmm0, xmm0
    movss [sb_r2], xmm0
    ; closest point of the segment to the centre
    movss xmm0, [sm_x+rbx*4]
    subss xmm0, [sb_ax]
    movss xmm1, [sm_y+rbx*4]
    subss xmm1, [sb_ay]
    movss xmm2, [sm_z+rbx*4]
    subss xmm2, [sb_az]
    movaps xmm3, xmm0
    mulss xmm3, [sb_dx]
    movaps xmm4, xmm1
    mulss xmm4, [sb_dy]
    addss xmm3, xmm4
    movaps xmm4, xmm2
    mulss xmm4, [sb_dz]
    addss xmm3, xmm4
    divss xmm3, [sb_dd]
    maxss xmm3, [c_zero]
    minss xmm3, [c_one]
    movss xmm4, [sb_dx]
    mulss xmm4, xmm3
    subss xmm0, xmm4
    movss xmm4, [sb_dy]
    mulss xmm4, xmm3
    subss xmm1, xmm4
    movss xmm4, [sb_dz]
    mulss xmm4, xmm3
    subss xmm2, xmm4
    mulss xmm0, xmm0
    mulss xmm1, xmm1
    addss xmm0, xmm1
    mulss xmm2, xmm2
    addss xmm0, xmm2
    comiss xmm0, [sb_r2]
    jb .blocked
    inc ebx
    jmp .c
.blocked:
    mov eax, 1
    pop rbx
    ret
.clear:
    xor eax, eax
    pop rbx
.out:
    ret

; ---- pegs -------------------------------------------------------------------------

; peg_add -- the rod digs in at the hit: out of a wall, a ledge you can
; mantle onto (up to 2.3 m off the floor); out of a floor, a 1 m post, a step.
; They're platforms like the desks (plat_*), so everything that stands on or
; bumps into those knows them; T can't climb them.
peg_add:
    PROLOGUE 48
    mov eax, [hr_nx]
    or eax, [hr_nz]
    and eax, 0x7fffffff
    jz .post
    ; a ledge out of the wall
    movss xmm0, [hr_x]
    movss xmm1, [hr_y]
    movss xmm2, [hr_z]
    call floor_under
    comiss xmm0, [c_neg_big]
    jbe .fail
    movss [rsp+0], xmm0                 ; floor
    movss xmm1, [hr_y]
    FLD xmm2, 0.4
    addss xmm0, xmm2
    maxss xmm1, xmm0
    movss xmm0, [rsp+0]
    FLD xmm2, 2.3
    addss xmm0, xmm2
    minss xmm1, xmm0
    movss [rsp+4], xmm1                 ; top
    mov eax, [c_peg_thick]
    mov [rsp+8], eax
    ; out from the wall along the normal, a metre along it
    movss xmm0, [hr_x]
    movss xmm1, [hr_nx]
    mulss xmm1, [c_peg_out]
    addss xmm1, xmm0
    movss xmm2, [hr_z]
    movss xmm3, [hr_nz]
    mulss xmm3, [c_peg_out]
    addss xmm3, xmm2
    mov eax, [hr_nx]
    and eax, 0x7fffffff
    jz .along_x
    ; (x runs out from the wall, z along it)
    movss [rsp+12], xmm0
    movss [rsp+16], xmm1
    movss xmm0, [hr_z]
    subss xmm0, [c_peg_half]
    movss [rsp+20], xmm0
    movss xmm0, [hr_z]
    addss xmm0, [c_peg_half]
    movss [rsp+24], xmm0
    jmp .sort
.along_x:
    movss [rsp+20], xmm2
    movss [rsp+24], xmm3
    movss xmm0, [hr_x]
    subss xmm0, [c_peg_half]
    movss [rsp+12], xmm0
    movss xmm0, [hr_x]
    addss xmm0, [c_peg_half]
    movss [rsp+16], xmm0
    jmp .sort
.post:
    movss xmm0, [hr_x]
    movss xmm1, [hr_y]
    FLD xmm3, 0.3
    addss xmm1, xmm3
    movss xmm2, [hr_z]
    call floor_under
    comiss xmm0, [c_neg_big]
    jbe .fail
    addss xmm0, [c_post_h]
    movss [rsp+4], xmm0
    mov eax, [c_post_h]
    mov [rsp+8], eax
    movss xmm0, [hr_x]
    subss xmm0, [c_post_half]
    movss [rsp+12], xmm0
    movss xmm0, [hr_x]
    addss xmm0, [c_post_half]
    movss [rsp+16], xmm0
    movss xmm0, [hr_z]
    subss xmm0, [c_post_half]
    movss [rsp+20], xmm0
    movss xmm0, [hr_z]
    addss xmm0, [c_post_half]
    movss [rsp+24], xmm0
    ; not on top of you
    movss xmm0, [p_x]
    subss xmm0, [hr_x]
    andps xmm0, [c_abs_mask]
    FLD xmm1, 0.7
    comiss xmm0, xmm1
    jae .sort
    movss xmm0, [p_z]
    subss xmm0, [hr_z]
    andps xmm0, [c_abs_mask]
    comiss xmm0, xmm1
    jb .fail
.sort:
    movss xmm0, [rsp+12]
    movss xmm1, [rsp+16]
    movaps xmm2, xmm0
    minss xmm0, xmm1
    maxss xmm1, xmm2
    movss [rsp+12], xmm0
    movss [rsp+16], xmm1
    movss xmm0, [rsp+20]
    movss xmm1, [rsp+24]
    movaps xmm2, xmm0
    minss xmm0, xmm1
    maxss xmm1, xmm2
    movss [rsp+20], xmm0
    movss [rsp+24], xmm1
    ; which platform slot
    mov eax, [peg_n]
    cmp eax, MAXPEG
    jge .reuse
    mov ecx, [plat_count]
    cmp ecx, MAX_PLAT
    jge .reuse
    inc dword [plat_count]
    mov [peg_plat+rax*4], ecx
    inc dword [peg_n]
    jmp .fill
.reuse:
    mov eax, [peg_n]
    test eax, eax
    jz .fail
    mov eax, [peg_next]
    mov ecx, [peg_plat+rax*4]
    inc eax
    xor edx, edx
    div dword [peg_n]
    mov [peg_next], edx
.fill:
    mov eax, [rsp+12]
    mov [plat_x0+rcx*4], eax
    mov eax, [rsp+16]
    mov [plat_x1+rcx*4], eax
    mov eax, [rsp+20]
    mov [plat_z0+rcx*4], eax
    mov eax, [rsp+24]
    mov [plat_z1+rcx*4], eax
    mov eax, [rsp+4]
    mov [plat_ya+rcx*4], eax
    mov [plat_yb+rcx*4], eax
    mov dword [plat_axis+rcx*4], 0
    mov eax, [rsp+8]
    mov [plat_thick+rcx*4], eax
    mov dword [plat_style+rcx*4], PS_GADGET
    call snd_hook_hit
    EPILOGUE
.fail:
    call snd_hook_miss
    lea rdi, [m_peg_no]
    mov esi, COL_INFO
    call say
    EPILOGUE

; =============================================================================
; every frame
; =============================================================================

; gadget_update(xmm0 = dt)
gadget_update:
    PROLOGUE 16
    movss [rsp+0], xmm0
    movss xmm1, [gd_clock]
    addss xmm1, xmm0
    movss [gd_clock], xmm1
    lea rdi, [gd_cool]
    call tick_down
    lea rdi, [lz_t]
    call tick_down
    lea rdi, [rg_t]
    call tick_down
    lea rdi, [rg_arm]
    call tick_down
    ; a safe room offers you a transmutation
    call player_in_safe
    mov ebx, eax
    test eax, eax
    jz .not_safe
    cmp dword [gd_was_safe], 0
    jne .not_safe
    cmp dword [gd_have], 0
    je .not_safe
    cmp dword [gd_charge], 0
    jne .not_safe
    mov dword [gd_charge], 1
    lea rdi, [m_charge]
    mov esi, COL_GOLD
    call say
.not_safe:
    mov [gd_was_safe], ebx
    movss xmm0, [rsp+0]
    call orb_update
    movss xmm0, [rsp+0]
    call tether_update
    movss xmm0, [rsp+0]
    call lines_update
    movss xmm0, [rsp+0]
    call smoke_update
    movss xmm0, [rsp+0]
    call drone_update
    EPILOGUE

; tick_down(rdi = &timer, xmm0 = dt) -- count it down to 0. leaf
tick_down:
    movss xmm1, [rdi]
    subss xmm1, xmm0
    maxss xmm1, [c_zero]
    movss [rdi], xmm1
    ret

; =============================================================================
; the DRONE base
; =============================================================================
; A gun fires from your hand; the drone fires from wherever it is. At your
; shoulder it's just a gun. Send it off (V) and it flies along your aim and
; hovers short of whatever it met: then every shot leaves the drone, the way
; YOU are looking -- round a corner, down the atrium, from behind T -- and T
; hears the drone, not you. A hook can't bite the world from a drone, so it
; bites the drone (you're hauled, blinked or zipped to it); a grabber reels
; things in to the drone. T swats a drone that comes within his reach: it
; reboots on the floor for a while, then flies home.

; drone_away -> eax 1 if the drone's off your shoulder (its shots leave it). leaf
drone_away:
    xor eax, eax
    cmp dword [gd_have], 0
    je .no
    cmp dword [gd_base], GB_DRONE
    jne .no
    mov ecx, [dr_state]
    cmp ecx, DR_OUT
    je .yes
    cmp ecx, DR_PARK
    je .yes
    cmp ecx, DR_BACK
    jne .no
.yes:
    mov eax, 1
.no:
    ret

; drone_home -- dr_h = its spot at your shoulder (level: it doesn't swing
; with your pitch). forward = (-sin yaw, 0, -cos yaw), right = (cos, 0, -sin)
drone_home:
    PROLOGUE 16
    movss xmm0, [p_yaw]
    call sinf
    movss [rsp+0], xmm0
    movss xmm0, [p_yaw]
    call cosf
    movss [rsp+4], xmm0
    movss xmm0, [rsp+0]
    mulss xmm0, [c_dr_fwd]
    movss xmm1, [p_x]
    subss xmm1, xmm0
    movss xmm0, [rsp+4]
    mulss xmm0, [c_dr_side]
    addss xmm1, xmm0
    movss [dr_hx], xmm1
    movss xmm0, [rsp+4]
    mulss xmm0, [c_dr_fwd]
    movss xmm1, [p_z]
    subss xmm1, xmm0
    movss xmm0, [rsp+0]
    mulss xmm0, [c_dr_side]
    subss xmm1, xmm0
    movss [dr_hz], xmm1
    movss xmm0, [p_eye_y]
    addss xmm0, [c_dr_up]
    movss [dr_hy], xmm0
    EPILOGUE

; drone_toward(xmm0 = how far this frame, xmm1..3 = a point) -> eax 1 if it
; got there (it moves that far towards it)
drone_toward:
    PROLOGUE 32
    movss [rsp+0], xmm0
    subss xmm1, [dr_x]
    subss xmm2, [dr_y]
    subss xmm3, [dr_z]
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    mulss xmm1, xmm1
    mulss xmm2, xmm2
    addss xmm1, xmm2
    mulss xmm3, xmm3
    addss xmm1, xmm3
    sqrtss xmm1, xmm1
    movss xmm0, [c_one]                 ; (all the way)
    mov eax, 1
    comiss xmm1, [rsp+0]
    jbe .move
    movss xmm0, [rsp+0]
    divss xmm0, xmm1
    xor eax, eax
.move:
    movss xmm1, [rsp+4]
    mulss xmm1, xmm0
    addss xmm1, [dr_x]
    movss [dr_x], xmm1
    movss xmm1, [rsp+8]
    mulss xmm1, xmm0
    addss xmm1, [dr_y]
    movss [dr_y], xmm1
    movss xmm1, [rsp+12]
    mulss xmm1, xmm0
    addss xmm1, [dr_z]
    movss [dr_z], xmm1
    EPILOGUE

; drone_update(xmm0 = dt) -- fly it, and T's swat
drone_update:
    PROLOGUE 32
    movss [rsp+0], xmm0
    call drone_home
    cmp dword [gd_have], 0
    je .home
    cmp dword [gd_base], GB_DRONE
    jne .home
    mov eax, [dr_state]
    cmp eax, DR_OUT
    je .out
    cmp eax, DR_PARK
    je .swat
    cmp eax, DR_BACK
    je .back
    cmp eax, DR_DOWN
    je .down
.home:
    mov dword [dr_state], DR_HOME
    mov eax, [dr_hx]
    mov [dr_x], eax
    mov eax, [dr_hy]
    mov [dr_y], eax
    mov eax, [dr_hz]
    mov [dr_z], eax
    EPILOGUE
.out:
    movss xmm0, [c_dr_speed]
    mulss xmm0, [rsp+0]
    movss xmm1, [dr_tx]
    movss xmm2, [dr_ty]
    movss xmm3, [dr_tz]
    call drone_toward
    test eax, eax
    jz .swat
    mov dword [dr_state], DR_PARK
    jmp .swat
.back:
    movss xmm0, [c_dr_back]
    mulss xmm0, [rsp+0]
    movss xmm1, [dr_hx]
    movss xmm2, [dr_hy]
    movss xmm3, [dr_hz]
    call drone_toward
    test eax, eax
    jnz .home
    EPILOGUE
.down:
    movss xmm0, [dr_t]
    subss xmm0, [rsp+0]
    movss [dr_t], xmm0
    comiss xmm0, [c_zero]
    ja .fall
    call drone_recall
    EPILOGUE
.fall:
    movss xmm0, [c_dr_fall]
    mulss xmm0, [rsp+0]
    movss xmm1, [dr_y]
    subss xmm1, xmm0
    maxss xmm1, [dr_ty]                 ; (the floor it fell to)
    movss [dr_y], xmm1
    EPILOGUE
.swat:
    ; T swats a drone within his reach
    movss xmm0, [t_stun]
    comiss xmm0, [c_zero]
    ja .done
    movss xmm0, [t_x]
    subss xmm0, [dr_x]
    mulss xmm0, xmm0
    movss xmm1, [t_z]
    subss xmm1, [dr_z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    comiss xmm0, [c_dr_swat2]
    jae .done
    movss xmm0, [dr_y]
    subss xmm0, [t_y]
    comiss xmm0, [c_zero]
    jb .done
    comiss xmm0, [c_dr_swat_h]
    ja .done
    call drone_swatted
.done:
    EPILOGUE

; drone_swatted -- down it goes, to reboot on the floor
drone_swatted:
    PROLOGUE 16
    mov dword [dr_state], DR_DOWN
    mov eax, [c_dr_down]
    mov [dr_t], eax
    movss xmm0, [dr_x]
    movss xmm1, [dr_y]
    movss xmm2, [dr_z]
    call floor_under
    comiss xmm0, [c_neg_big]
    ja .floor
    movss xmm0, [dr_y]
    subss xmm0, [c_eye]
.floor:
    addss xmm0, [c_dr_rest]
    movss [dr_ty], xmm0
    call snd_clank
    lea rdi, [m_dr_swat]
    mov esi, COL_WARN
    call say
    EPILOGUE

; drone_recall -- home: straight back if it can see you, or (round the
; houses) it's simply back
drone_recall:
    PROLOGUE 16
    call drone_home
    movss xmm0, [p_x]
    movss xmm1, [p_eye_y]
    movss xmm2, [p_z]
    movss xmm3, [dr_x]
    movss xmm4, [dr_y]
    movss xmm5, [dr_z]
    call line_of_sight_3d
    mov dword [dr_state], DR_BACK
    test eax, eax
    jnz .done
    mov dword [dr_state], DR_HOME
    mov eax, [dr_hx]
    mov [dr_x], eax
    mov eax, [dr_hy]
    mov [dr_y], eax
    mov eax, [dr_hz]
    mov [dr_z], eax
.done:
    EPILOGUE

; drone_send -- off along your aim, to hover short of whatever it meets
drone_send:
    PROLOGUE 16
    mov dword [dr_state], DR_HOME       ; (aim from your eye; it flies from where it is)
    call aim_from_view
    movss xmm0, [c_dr_range]
    xor edi, edi                        ; (the world only)
    call gd_trace
    movss xmm0, [hr_dist]
    cmp eax, HT_NONE
    je .open
    subss xmm0, [c_dr_short]
.open:
    comiss xmm0, [c_dr_min]
    jb .no_room
    movss [rsp+0], xmm0
    movss xmm1, [ad_x]
    mulss xmm1, xmm0
    addss xmm1, [ao_x]
    movss [dr_tx], xmm1
    movss xmm1, [ad_y]
    mulss xmm1, xmm0
    addss xmm1, [ao_y]
    movss [dr_ty], xmm1
    movss xmm1, [ad_z]
    mulss xmm1, xmm0
    addss xmm1, [ao_z]
    movss [dr_tz], xmm1
    mov dword [dr_state], DR_OUT
    call snd_gadget
    bts dword [dr_told], 0
    jc .done
    lea rdi, [m_dr_out]
    mov esi, COL_INFO
    call say
.done:
    EPILOGUE
.no_room:
    lea rdi, [m_dr_room]
    mov esi, COL_WARN
    call say
    EPILOGUE

; drone_key -- V: send it off, or call it back
drone_key:
    PROLOGUE 16
    mov eax, [dr_state]
    cmp eax, DR_DOWN
    je .down
    cmp eax, DR_OUT
    je .recall
    cmp eax, DR_PARK
    je .recall
    call drone_send
    EPILOGUE
.recall:
    call snd_gadget
    call drone_recall
    EPILOGUE
.down:
    lea rdi, [m_dr_down]
    mov esi, COL_WARN
    call say
    EPILOGUE

; draw_drone -- (inside gadget_draw's quads) a little quadcopter, its eye
; glowing in the module's colour
draw_drone:
    PROLOGUE 32
    cmp dword [gd_have], 0
    je .out
    cmp dword [gd_base], GB_DRONE
    jne .out
    movss xmm0, [gd_clock]
    FLD xmm1, 3.0
    mulss xmm0, xmm1
    call sinf
    FLD xmm1, 0.03
    mulss xmm0, xmm1
    cmp dword [dr_state], DR_DOWN
    jne .bob
    xorps xmm0, xmm0
.bob:
    addss xmm0, [dr_y]
    movss [rsp+0], xmm0                 ; the body's underside
    movss xmm0, [dr_x]
    movss xmm1, [rsp+0]
    movss xmm2, [dr_z]
    FLD xmm3, 0.075
    FLD xmm4, 0.045
    FLD xmm5, 0.075
    mov edi, 0x2C3036
    call cbox
    movss xmm0, [dr_x]
    movss xmm1, [rsp+0]
    FLD xmm2, 0.028
    subss xmm1, xmm2
    movss xmm2, [dr_z]
    FLD xmm3, 0.028
    FLD xmm4, 0.028
    FLD xmm5, 0.028
    mov edi, [gd_tip_col]
    call cbox
    xor ebx, ebx
.rotor:
    FLD xmm0, 0.105
    test ebx, 1
    jz .rx
    xorps xmm0, [c_sign_mask]
.rx:
    addss xmm0, [dr_x]
    movss [rsp+4], xmm0
    FLD xmm2, 0.105
    test ebx, 2
    jz .rz
    xorps xmm2, [c_sign_mask]
.rz:
    addss xmm2, [dr_z]
    movss xmm0, [rsp+4]
    movss xmm1, [rsp+0]
    FLD xmm3, 0.035
    addss xmm1, xmm3
    FLD xmm3, 0.05
    FLD xmm4, 0.01
    FLD xmm5, 0.05
    mov edi, 0x8A929C
    call cbox
    inc ebx
    cmp ebx, 4
    jl .rotor
.out:
    EPILOGUE

; =============================================================================
; drawing
; =============================================================================

; colour(edi = 0xRRGGBB, xmm3 = alpha) -- glColor4f. Keeps edi.
colour:
    PROLOGUE 16
    mov ebx, edi
    movss [rsp+0], xmm3
    FLD xmm4, 255.0
    mov eax, ebx
    shr eax, 16
    and eax, 255
    cvtsi2ss xmm0, eax
    divss xmm0, xmm4
    mov eax, ebx
    shr eax, 8
    and eax, 255
    cvtsi2ss xmm1, eax
    divss xmm1, xmm4
    mov eax, ebx
    and eax, 255
    cvtsi2ss xmm2, eax
    divss xmm2, xmm4
    movss xmm3, [rsp+0]
    call glColor4f
    mov edi, ebx
    EPILOGUE

; tube(xmm0..2 = A, xmm3..5 = B, xmm6 = half width) -- emit_tube from values
tube:
    PROLOGUE 48
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+16], xmm3
    movss [rsp+20], xmm4
    movss [rsp+24], xmm5
    movaps xmm0, xmm6
    lea rdi, [rsp+0]
    lea rsi, [rsp+16]
    call emit_tube
    EPILOGUE

; gadget_draw -- lit pass: pegs, lines, the grabber, the orb, the hand
; reaching out of a window. (Your ziplines are drawn with the building's.)
gadget_draw:
    PROLOGUE 48
    mov edi, [white_tex]
    call bind
    mov edi, GL_QUADS
    call glBegin
    ; pegs
    xor ebx, ebx
.peg:
    cmp ebx, [peg_n]
    jge .lines
    mov ecx, [peg_plat+rbx*4]
    movss xmm0, [plat_x0+rcx*4]
    addss xmm0, [plat_x1+rcx*4]
    mulss xmm0, [c_half]
    movss xmm3, [plat_x1+rcx*4]
    subss xmm3, [plat_x0+rcx*4]
    mulss xmm3, [c_half]
    movss xmm2, [plat_z0+rcx*4]
    addss xmm2, [plat_z1+rcx*4]
    mulss xmm2, [c_half]
    movss xmm5, [plat_z1+rcx*4]
    subss xmm5, [plat_z0+rcx*4]
    mulss xmm5, [c_half]
    movss xmm4, [plat_thick+rcx*4]
    mulss xmm4, [c_half]
    movss xmm1, [plat_ya+rcx*4]
    subss xmm1, xmm4
    mov edi, 0x8A7446
    call cbox
    inc ebx
    jmp .peg
.lines:
    xor ebx, ebx
.ln:
    cmp ebx, MAXLN
    jge .tether
    mov eax, [ln_type+rbx*4]
    cmp eax, LN_CAPTURE
    je .capture
    cmp eax, LN_TRIP
    je .trip
    cmp eax, LN_SNARE
    je .snare
    jmp .lnn
.capture:
    mov edi, 0xE8902C
    FLD xmm6, 0.014
    jmp .strung
.trip:
    mov edi, 0xD02020
    FLD xmm6, 0.006
.strung:
    movss [rsp+0], xmm6
    movss xmm3, [c_one]
    call colour
    movss xmm0, [ln_ax+rbx*4]
    movss xmm1, [ln_ay+rbx*4]
    movss xmm2, [ln_az+rbx*4]
    movss xmm3, [ln_bx+rbx*4]
    movss xmm4, [ln_by+rbx*4]
    movss xmm5, [ln_bz+rbx*4]
    movss xmm6, [rsp+0]
    call tube
    ; little anchors
    movss xmm0, [ln_bx+rbx*4]
    movss xmm1, [ln_by+rbx*4]
    movss xmm2, [ln_bz+rbx*4]
    FLD xmm3, 0.04
    movaps xmm4, xmm3
    movaps xmm5, xmm3
    mov edi, 0x404448
    call cbox
    jmp .lnn
.snare:
    ; a loop of rope lying on the floor
    mov edi, 0xC08040
    movss xmm3, [c_one]
    call colour
    xor r12d, r12d
.loop:
    cmp r12d, 8
    jge .lnn
    cvtsi2ss xmm0, r12d
    FLD xmm1, 0.785398
    mulss xmm0, xmm1
    movss [rsp+0], xmm0
    call cosf
    movss [rsp+4], xmm0
    movss xmm0, [rsp+0]
    call sinf
    movss [rsp+8], xmm0
    movss xmm0, [rsp+0]
    FLD xmm1, 0.785398
    addss xmm0, xmm1
    movss [rsp+0], xmm0
    call cosf
    movss [rsp+12], xmm0
    movss xmm0, [rsp+0]
    call sinf
    movaps xmm5, xmm0
    FLD xmm6, 0.5
    mulss xmm5, xmm6
    addss xmm5, [ln_az+rbx*4]
    movss xmm3, [rsp+12]
    mulss xmm3, xmm6
    addss xmm3, [ln_ax+rbx*4]
    movss xmm0, [rsp+4]
    mulss xmm0, xmm6
    addss xmm0, [ln_ax+rbx*4]
    movss xmm2, [rsp+8]
    mulss xmm2, xmm6
    addss xmm2, [ln_az+rbx*4]
    movss xmm1, [ln_ay+rbx*4]
    FLD xmm4, 0.03
    addss xmm1, xmm4
    movaps xmm4, xmm1
    FLD xmm6, 0.02
    call tube
    inc r12d
    jmp .loop
.lnn:
    inc ebx
    jmp .ln
.tether:
    cmp dword [gd_tt_state], TT_IDLE
    je .orb
    call aim_from_view
    mov edi, 0x9A8A6A
    movss xmm3, [c_one]
    call colour
    movss xmm0, [hd_x]
    movss xmm1, [hd_y]
    movss xmm2, [hd_z]
    movss xmm3, [tt_hx]
    movss xmm4, [tt_hy]
    movss xmm5, [tt_hz]
    FLD xmm6, 0.012
    call tube
    mov eax, [tt_mod]
    and eax, 3
    mov edi, [mod_col+rax*4]
    movss xmm0, [tt_hx]
    movss xmm1, [tt_hy]
    movss xmm2, [tt_hz]
    FLD xmm3, 0.07
    movaps xmm4, xmm3
    movaps xmm5, xmm3
    call cbox
.orb:
    cmp dword [gd_orb_on], 0
    je .arm
    mov eax, [orb_mod]
    and eax, 3
    mov edi, [mod_col+rax*4]
    movss xmm0, [gd_orb_x]
    movss xmm1, [gd_orb_y]
    movss xmm2, [gd_orb_z]
    FLD xmm3, 0.09
    movaps xmm4, xmm3
    movaps xmm5, xmm3
    call cbox
.arm:
    movss xmm0, [rg_arm]
    comiss xmm0, [c_zero]
    jbe .done
    mov edi, 0xC89878
    movss xmm3, [c_one]
    call colour
    movss xmm0, [rg_x]
    movss xmm1, [rg_y]
    movss xmm2, [rg_z]
    movss xmm3, [rg_tx]
    movss xmm4, [rg_ty]
    movss xmm5, [rg_tz]
    FLD xmm6, 0.045
    call tube
    movss xmm0, [rg_tx]
    movss xmm1, [rg_ty]
    movss xmm2, [rg_tz]
    FLD xmm3, 0.09
    FLD xmm4, 0.05
    FLD xmm5, 0.09
    mov edi, 0xC89878
    call cbox
.done:
    call draw_drone
    call glEnd
    GLF4 glColor4f, 1.0, 1.0, 1.0, 1.0
    EPILOGUE

; gadget_draw_glow -- unlit pass (blending on): the laser's beam, the
; remote grabber's window
gadget_draw_glow:
    PROLOGUE 48
    mov edi, [white_tex]
    call bind
    mov edi, GL_QUADS
    call glBegin
    movss xmm0, [lz_t]
    comiss xmm0, [c_zero]
    jbe .window
    divss xmm0, [c_beam_t]
    movaps xmm3, xmm0
    mov edi, [lz_col]
    call colour
    movss xmm0, [lz_ax]
    movss xmm1, [lz_ay]
    movss xmm2, [lz_az]
    movss xmm3, [lz_bx]
    movss xmm4, [lz_by]
    movss xmm5, [lz_bz]
    FLD xmm6, 0.018
    call tube
.window:
    movss xmm0, [rg_t]
    comiss xmm0, [c_zero]
    jbe .done
    divss xmm0, [c_rg_show]
    FLD xmm1, 0.8
    mulss xmm0, xmm1
    movaps xmm3, xmm0
    mov edi, 0x40A0FF
    call colour
    ; two tangents of the surface: (u, v)
    xorps xmm0, xmm0
    movss [rsp+0], xmm0                 ; u
    movss [rsp+4], xmm0
    movss [rsp+8], xmm0
    movss [rsp+12], xmm0                ; v
    movss [rsp+16], xmm0
    movss [rsp+20], xmm0
    mov eax, [rg_ny]
    and eax, 0x7fffffff
    jz .wall
    mov dword [rsp+0], __float32__(0.6)
    mov dword [rsp+20], __float32__(0.6)
    jmp .quad
.wall:
    mov dword [rsp+16], __float32__(0.8)
    mov eax, [rg_nx]
    and eax, 0x7fffffff
    jz .znorm
    mov dword [rsp+8], __float32__(0.55)
    jmp .quad
.znorm:
    mov dword [rsp+0], __float32__(0.55)
.quad:
    ; centre, a hair off the surface
    movss xmm0, [rg_nx]
    FLD xmm3, 0.03
    mulss xmm0, xmm3
    addss xmm0, [rg_x]
    movss [rsp+24], xmm0
    movss xmm0, [rg_ny]
    mulss xmm0, xmm3
    addss xmm0, [rg_y]
    movss [rsp+28], xmm0
    movss xmm0, [rg_nz]
    mulss xmm0, xmm3
    addss xmm0, [rg_z]
    movss [rsp+32], xmm0
    ; corners c -u -v, c +u -v, c +u +v, c -u +v
    mov r12d, 0
.corner:
    cmp r12d, 4
    jge .done
    movss xmm6, [c_neg_one]             ; su
    movss xmm7, [c_neg_one]             ; sv
    cmp r12d, 1
    je .su
    cmp r12d, 2
    jne .sv
    movss xmm7, [c_one]
.su:
    movss xmm6, [c_one]
    jmp .emit
.sv:
    cmp r12d, 3
    jne .emit
    movss xmm7, [c_one]
.emit:
    movss xmm0, [rsp+0]
    mulss xmm0, xmm6
    movss xmm3, [rsp+12]
    mulss xmm3, xmm7
    addss xmm0, xmm3
    addss xmm0, [rsp+24]
    movss xmm1, [rsp+4]
    mulss xmm1, xmm6
    movss xmm3, [rsp+16]
    mulss xmm3, xmm7
    addss xmm1, xmm3
    addss xmm1, [rsp+28]
    movss xmm2, [rsp+8]
    mulss xmm2, xmm6
    movss xmm3, [rsp+20]
    mulss xmm3, xmm7
    addss xmm2, xmm3
    addss xmm2, [rsp+32]
    call glVertex3f
    inc r12d
    jmp .corner
.done:
    call glEnd
    GLF4 glColor4f, 1.0, 1.0, 1.0, 1.0
    EPILOGUE

; gadget_draw_smoke -- the clouds: soft grey puffs facing you (blending on;
; call with depth writes off)
gadget_draw_smoke:
    PROLOGUE 64
    cmp dword [sm_count], 0
    je .none
    movss xmm0, [p_yaw]
    call cosf
    movss [rsp+0], xmm0                 ; right = (cos, 0, -sin)
    movss xmm0, [p_yaw]
    call sinf
    xorps xmm0, [c_sign_mask]
    movss [rsp+4], xmm0
    mov edi, [radial_tex]
    call bind
    mov edi, GL_QUADS
    call glBegin
    xor ebx, ebx
.c:
    cmp ebx, [sm_count]
    jge .done
    mov ecx, ebx
    call smoke_r
    movss [rsp+8], xmm0                 ; radius now
    ; how thick: fades out at the end
    movss xmm3, [sm_life+rbx*4]
    divss xmm3, [c_fade]
    minss xmm3, [c_one]
    FLD xmm1, 0.5
    mulss xmm3, xmm1
    FLD xmm0, 0.6
    FLD xmm1, 0.61
    FLD xmm2, 0.6
    call glColor4f
    ; five puffs: the middle one and four round it
    xor r12d, r12d
.puff:
    cmp r12d, 5
    jge .cn
    cvtsi2ss xmm0, r12d
    FLD xmm1, 1.3
    mulss xmm0, xmm1
    addss xmm0, [sm_life0+rbx*4]        ; (each cloud its own pattern)
    movss [rsp+12], xmm0
    call cosf
    movss [rsp+16], xmm0
    movss xmm0, [rsp+12]
    call sinf
    movss [rsp+20], xmm0
    xorps xmm4, xmm4                    ; offset scale: 0 for the middle one
    test r12d, r12d
    jz .mid
    movss xmm4, [rsp+8]
    FLD xmm5, 0.45
    mulss xmm4, xmm5
.mid:
    ; centre = cloud + right*cos*off + up*sin*off*0.6
    movss xmm0, [rsp+16]
    mulss xmm0, xmm4
    movss [rsp+24], xmm0                ; along right
    movss xmm0, [rsp+20]
    mulss xmm0, xmm4
    FLD xmm5, 0.6
    mulss xmm0, xmm5
    addss xmm0, [sm_y+rbx*4]
    movss [rsp+28], xmm0                ; y
    movss xmm0, [rsp+0]
    mulss xmm0, [rsp+24]
    addss xmm0, [sm_x+rbx*4]
    movss [rsp+32], xmm0                ; x
    movss xmm0, [rsp+4]
    mulss xmm0, [rsp+24]
    addss xmm0, [sm_z+rbx*4]
    movss [rsp+36], xmm0                ; z
    movss xmm0, [rsp+8]
    FLD xmm5, 0.85
    mulss xmm0, xmm5
    movss [rsp+40], xmm0                ; half size
    mov r13d, 0
.v:
    cmp r13d, 4
    jge .pn
    ; corner signs: (-,-) (+,-) (+,+) (-,+)
    movss xmm6, [c_neg_one]
    movss xmm7, [c_neg_one]
    cmp r13d, 1
    jne .v2
    movss xmm6, [c_one]
.v2:
    cmp r13d, 2
    jne .v3
    movss xmm6, [c_one]
    movss xmm7, [c_one]
.v3:
    cmp r13d, 3
    jne .v4
    movss xmm7, [c_one]
.v4:
    movss [rsp+44], xmm6
    movss [rsp+48], xmm7
    movaps xmm0, xmm6
    addss xmm0, [c_one]
    mulss xmm0, [c_half]
    movaps xmm1, xmm7
    addss xmm1, [c_one]
    mulss xmm1, [c_half]
    call glTexCoord2f
    movss xmm6, [rsp+44]
    mulss xmm6, [rsp+40]
    movss xmm7, [rsp+48]
    mulss xmm7, [rsp+40]
    movss xmm0, [rsp+0]
    mulss xmm0, xmm6
    addss xmm0, [rsp+32]
    movss xmm1, [rsp+28]
    addss xmm1, xmm7
    movss xmm2, [rsp+4]
    mulss xmm2, xmm6
    addss xmm2, [rsp+36]
    call glVertex3f
    inc r13d
    jmp .v
.pn:
    inc r12d
    jmp .puff
.cn:
    inc ebx
    jmp .c
.done:
    call glEnd
    GLF4 glColor4f, 1.0, 1.0, 1.0, 1.0
.none:
    EPILOGUE

; =============================================================================
; the HUD: your gadget, smoke in your eyes, the bench and its catalog
; =============================================================================

; gadget_hud(edi = screen width, esi = height) -- 2D, after the rest of the HUD
gadget_hud:
    PROLOGUE 64
    mov [hud_sw], edi
    mov [hud_sh], esi
    mov [rsp+0], edi
    mov [rsp+4], esi
    cvtsi2ss xmm0, edi
    movss [rsp+8], xmm0
    cvtsi2ss xmm0, esi
    movss [rsp+12], xmm0
    ; ---- smoke in your eyes
    xor ebx, ebx
    xorps xmm7, xmm7
    movss [rsp+16], xmm7                ; thickest
.eyes:
    cmp ebx, [sm_count]
    jge .eyes_done
    mov ecx, ebx
    call smoke_r
    movss xmm1, [cam_x]
    subss xmm1, [sm_x+rbx*4]
    mulss xmm1, xmm1
    movss xmm2, [cam_y]
    subss xmm2, [sm_y+rbx*4]
    mulss xmm2, xmm2
    addss xmm1, xmm2
    movss xmm2, [cam_z]
    subss xmm2, [sm_z+rbx*4]
    mulss xmm2, xmm2
    addss xmm1, xmm2
    sqrtss xmm1, xmm1
    divss xmm1, xmm0
    movss xmm0, [c_one]
    subss xmm0, xmm1                    ; 1 in the middle, 0 at the edge
    maxss xmm0, [rsp+16]
    movss [rsp+16], xmm0
    inc ebx
    jmp .eyes
.eyes_done:
    movss xmm7, [rsp+16]
    comiss xmm7, [c_zero]
    jbe .no_smoke
    FLD xmm0, 1.6
    mulss xmm7, xmm0
    minss xmm7, [c_one]
    FLD xmm0, 0.85
    mulss xmm7, xmm0
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    movss xmm2, [rsp+8]
    movss xmm3, [rsp+12]
    FLD xmm4, 0.55
    FLD xmm5, 0.56
    FLD xmm6, 0.55
    call draw_rect
.no_smoke:
    cmp dword [gd_have], 0
    je .done
    ; ---- your gadget, next to the bars
    mov eax, [gd_last_combo]
    test eax, eax
    jns .named
    mov eax, NCOMBOS
.named:
    mov edi, [gl_tex+rax*4]
    mov esi, [gl_w+rax*4]
    mov edx, [gl_h+rax*4]
    FLD xmm0, 240.0
    movss xmm1, [rsp+12]
    FLD xmm2, 96.0
    subss xmm1, xmm2
    movss xmm2, [c_one]
    call draw_text
    mov eax, 9
    cmp dword [gd_base], GB_DRONE
    jne .hint
    mov eax, 8                          ; (the drone's keys)
.hint:
    mov edi, [fx_tex+rax*4]
    mov esi, [fx_w+rax*4]
    mov edx, [fx_h+rax*4]
    FLD xmm0, 240.0
    movss xmm1, [rsp+12]
    FLD xmm2, 72.0
    subss xmm1, xmm2
    FLD xmm2, 0.55
    call draw_text
    cmp dword [gd_bench], 0
    je .done
    call draw_bench
.done:
    EPILOGUE

; draw_bench -- the bench and the catalog, centred on the screen
draw_bench:
    PROLOGUE 64
    ; the panel, centred
    movss xmm0, [bench_w]
    movss xmm1, [bench_h]
    call bench_origin                   ; -> [bx0], [by0]
    movss xmm0, [bx0]
    movss xmm1, [by0]
    movss xmm2, [bench_w]
    movss xmm3, [bench_h]
    FLD xmm4, 0.04
    FLD xmm5, 0.04
    FLD xmm6, 0.05
    FLD xmm7, 0.88
    call draw_rect
    ; title
    xor ebx, ebx
    mov edi, [fx_tex]
    mov esi, [fx_w]
    mov edx, [fx_h]
    movss xmm0, [bx0]
    FLD xmm2, 20.0
    addss xmm0, xmm2
    movss xmm1, [by0]
    FLD xmm2, 14.0
    addss xmm1, xmm2
    movss xmm2, [c_one]
    call draw_text
    ; three columns: base (1 entry), modules, firing types
    xor r12d, r12d                      ; column
.col:
    cmp r12d, 3
    jge .cols_done
    cvtsi2ss xmm0, r12d
    FLD xmm1, 190.0
    mulss xmm0, xmm1
    addss xmm0, [bx0]
    FLD xmm1, 20.0
    addss xmm0, xmm1
    movss [rsp+0], xmm0                 ; column x
    ; selected column: a faint box
    cmp r12d, [gd_col]
    jne .header
    FLD xmm1, 8.0
    subss xmm0, xmm1
    movss xmm1, [by0]
    FLD xmm2, 52.0
    addss xmm1, xmm2
    FLD xmm2, 175.0
    FLD xmm3, 142.0
    FLD xmm4, 1.0
    FLD xmm5, 0.85
    FLD xmm6, 0.4
    FLD xmm7, 0.1
    call draw_rect
.header:
    lea eax, [r12d+1]
    mov edi, [fx_tex+rax*4]
    mov esi, [fx_w+rax*4]
    mov edx, [fx_h+rax*4]
    movss xmm0, [rsp+0]
    movss xmm1, [by0]
    FLD xmm2, 58.0
    addss xmm1, xmm2
    FLD xmm2, 0.7
    call draw_text
    ; its parts: r13 first part index, r14 count, r15 bag, [rsp+4] equipped
    cmp r12d, 0
    jne .c1
    xor r13d, r13d
    mov r14d, NBASES
    mov r15d, [gd_bag_base]
    mov eax, [gd_base]
    jmp .parts
.c1:
    cmp r12d, 1
    jne .c2
    mov r13d, NBASES
    mov r14d, NMODS
    mov r15d, [gd_bag_mod]
    mov eax, [gd_mod]
    jmp .parts
.c2:
    mov r13d, NBASES+NMODS
    mov r14d, NFIRES
    mov r15d, [gd_bag_fire]
    mov eax, [gd_fire]
.parts:
    mov [rsp+4], eax
    xor ebx, ebx
.part:
    cmp ebx, r14d
    jge .col_n
    cvtsi2ss xmm1, ebx
    FLD xmm2, 26.0
    mulss xmm1, xmm2
    addss xmm1, [by0]
    FLD xmm2, 84.0
    addss xmm1, xmm2
    movss [rsp+8], xmm1                 ; row y
    ; the equipped one: a bar in its colour
    cmp ebx, [rsp+4]
    jne .dim
    movss xmm0, [rsp+0]
    FLD xmm2, 6.0
    subss xmm0, xmm2
    FLD xmm2, 2.0
    subss xmm1, xmm2
    FLD xmm2, 160.0
    FLD xmm3, 24.0
    FLD xmm4, 0.9
    FLD xmm5, 0.7
    FLD xmm6, 0.25
    FLD xmm7, 0.35
    call draw_rect
.dim:
    FLD xmm2, 1.0
    bt r15d, ebx
    jc .owned
    FLD xmm2, 0.22
.owned:
    lea eax, [r13d+ebx]
    mov edi, [part_tex+rax*4]
    mov esi, [part_w+rax*4]
    mov edx, [part_h+rax*4]
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+8]
    call draw_text
    inc ebx
    jmp .part
.col_n:
    inc r12d
    jmp .col
.cols_done:
    ; what you've got: name and description
    mov eax, [gd_last_combo]
    test eax, eax
    js .no_combo
    mov ebx, eax
    mov edi, [cn_tex+rbx*4]
    mov esi, [cn_w+rbx*4]
    mov edx, [cn_h+rbx*4]
    movss xmm0, [bx0]
    FLD xmm2, 20.0
    addss xmm0, xmm2
    movss xmm1, [by0]
    FLD xmm2, 200.0
    addss xmm1, xmm2
    movss xmm2, [c_one]
    call draw_text
    mov edi, [cd_tex+rbx*4]
    mov esi, [cd_w+rbx*4]
    mov edx, [cd_h+rbx*4]
    movss xmm0, [bx0]
    FLD xmm2, 20.0
    addss xmm0, xmm2
    movss xmm1, [by0]
    FLD xmm2, 230.0
    addss xmm1, xmm2
    FLD xmm2, 0.9
    call draw_text
.no_combo:
    ; the catalog
    call gadget_count_known
    cmp eax, [cat_shown]
    je .cat_ok
    mov [cat_shown], eax
    mov r12d, eax
    lea rsi, [cat_tex]
    mov edi, 1
    call glDeleteTextures
    lea rdi, [msg_buf]
    mov esi, 512
    lea rdx, [fmt_cat]
    mov ecx, r12d
    mov r8d, NCOMBOS
    xor eax, eax
    call snprintf
    mov rdi, [font_small]
    lea rsi, [msg_buf]
    mov edx, RGBC(255,215,90)
    call mk
    mov [cat_tex], eax
    mov [cat_w], ecx
    mov [cat_h], r8d
.cat_ok:
    mov edi, [cat_tex]
    mov esi, [cat_w]
    mov edx, [cat_h]
    movss xmm0, [bx0]
    FLD xmm2, 20.0
    addss xmm0, xmm2
    movss xmm1, [by0]
    FLD xmm2, 292.0
    addss xmm1, xmm2
    movss xmm2, [c_one]
    call draw_text
    xor ebx, ebx
.cat:
    cmp ebx, NCOMBOS
    jge .cat_done
    cmp ebx, 32
    jae .cat_done
    ; 4 columns of names
    mov eax, ebx
    and eax, 3
    cvtsi2ss xmm0, eax
    FLD xmm1, 190.0
    mulss xmm0, xmm1
    addss xmm0, [bx0]
    FLD xmm1, 20.0
    addss xmm0, xmm1
    movss [rsp+0], xmm0
    mov eax, ebx
    shr eax, 2
    cvtsi2ss xmm1, eax
    FLD xmm2, 22.0
    mulss xmm1, xmm2
    addss xmm1, [by0]
    FLD xmm2, 318.0
    addss xmm1, xmm2
    movss [rsp+8], xmm1
    bt dword [gd_known], ebx
    jnc .unknown
    mov edi, [cs_tex+rbx*4]
    mov esi, [cs_w+rbx*4]
    mov edx, [cs_h+rbx*4]
    movss xmm2, [c_one]
    cmp ebx, [gd_last_combo]
    je .cat_draw
    FLD xmm2, 0.75
    jmp .cat_draw
.unknown:
    mov edi, [fx_tex+7*4]
    mov esi, [fx_w+7*4]
    mov edx, [fx_h+7*4]
    FLD xmm2, 0.3
.cat_draw:
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+8]
    call draw_text
    inc ebx
    jmp .cat
.cat_done:
    ; transmuting, and the keys
    mov eax, 6
    cmp dword [gd_charge], 0
    je .tm
    mov eax, 5
.tm:
    mov edi, [fx_tex+rax*4]
    mov esi, [fx_w+rax*4]
    mov edx, [fx_h+rax*4]
    movss xmm0, [bx0]
    FLD xmm2, 20.0
    addss xmm0, xmm2
    movss xmm1, [by0]
    FLD xmm2, 510.0
    addss xmm1, xmm2
    movss xmm2, [c_one]
    call draw_text
    mov edi, [fx_tex+4*4]
    mov esi, [fx_w+4*4]
    mov edx, [fx_h+4*4]
    movss xmm0, [bx0]
    FLD xmm2, 20.0
    addss xmm0, xmm2
    movss xmm1, [by0]
    FLD xmm2, 548.0
    addss xmm1, xmm2
    FLD xmm2, 0.7
    call draw_text
    EPILOGUE

; bench_origin(xmm0 = panel w, xmm1 = h) -- centre it on the screen (win_w/h)
bench_origin:
    cvtsi2ss xmm2, dword [hud_sw]
    subss xmm2, xmm0
    mulss xmm2, [c_half]
    maxss xmm2, [c_zero]
    movss [bx0], xmm2
    cvtsi2ss xmm2, dword [hud_sh]
    subss xmm2, xmm1
    mulss xmm2, [c_half]
    maxss xmm2, [c_zero]
    movss [by0], xmm2
    ret

; =============================================================================
; set-up, the catalog file, item plaques
; =============================================================================

; mk(rdi = font, rsi = text, edx = colour) -> eax tex, ecx w, r8d h
mk:
    PROLOGUE 16
    xor ecx, ecx
    call make_text_texture
    mov ecx, [tt_w]
    mov r8d, [tt_h]
    EPILOGUE

; abgr(edi = 0xRRGGBB) -> eax = opaque 0xAABBGGRR. leaf
abgr:
    mov eax, edi
    bswap eax                           ; BB GG RR 00 -> reversed
    shr eax, 8
    or eax, 0xFF000000
    ret

; gadget_init -- (after the fonts and textures) every name, description and
; plaque the bench, the HUD and the parts on the floor will need
gadget_init:
    PROLOGUE 32
    xor ebx, ebx
.parts:
    mov rdi, [font_hud]
    mov rsi, [part_names+rbx*8]
    mov edx, RGBC(240,236,224)
    call mk
    mov [part_tex+rbx*4], eax
    mov [part_w+rbx*4], ecx
    mov [part_h+rbx*4], r8d
    inc ebx
    cmp ebx, NPARTS
    jl .parts
    xor ebx, ebx
.combos:
    mov edi, ebx
    call combo_text
    mov r12, rax
    mov r13, rdx
    mov rdi, [font_hud]
    mov rsi, r12
    mov edx, RGBC(255,215,90)
    call mk
    mov [cn_tex+rbx*4], eax
    mov [cn_w+rbx*4], ecx
    mov [cn_h+rbx*4], r8d
    mov rdi, [font_small]
    mov rsi, r12
    mov edx, RGBC(232,226,210)
    call mk
    mov [cs_tex+rbx*4], eax
    mov [cs_w+rbx*4], ecx
    mov [cs_h+rbx*4], r8d
    mov rdi, [font_small]
    mov rsi, r13
    mov edx, RGBC(205,200,190)
    mov ecx, 740
    call make_text_texture
    mov [cd_tex+rbx*4], eax
    mov eax, [tt_w]
    mov [cd_w+rbx*4], eax
    mov eax, [tt_h]
    mov [cd_h+rbx*4], eax
    lea rdi, [msg_buf]
    mov esi, 512
    lea rdx, [fmt_gadget]
    mov rcx, r12
    xor eax, eax
    call snprintf
    mov rdi, [font_hud]
    lea rsi, [msg_buf]
    mov edx, RGBC(255,200,120)
    call mk
    mov [gl_tex+rbx*4], eax
    mov [gl_w+rbx*4], ecx
    mov [gl_h+rbx*4], r8d
    inc ebx
    cmp ebx, NCOMBOS
    jl .combos
    mov rdi, [font_hud]
    lea rsi, [s_incomplete]
    mov edx, RGBC(170,160,150)
    call mk
    mov [gl_tex+NCOMBOS*4], eax
    mov [gl_w+NCOMBOS*4], ecx
    mov [gl_h+NCOMBOS*4], r8d
    ; the bench's fixed text
    xor ebx, ebx
.fx:
    mov rdi, [font_small]
    mov rsi, [fx_strs+rbx*8]
    test rsi, rsi
    jz .fx_n
    mov edx, [fx_cols+rbx*4]
    cmp ebx, 0
    jne .fx_mk
    mov rdi, [font_hud]
.fx_mk:
    call mk
    mov [fx_tex+rbx*4], eax
    mov [fx_w+rbx*4], ecx
    mov [fx_h+rbx*4], r8d
.fx_n:
    inc ebx
    cmp ebx, 10
    jl .fx
    mov dword [cat_shown], -1
    mov dword [cat_tex], 0
    ; plaques for the parts lying around: the part's name on its colour
    xor ebx, ebx
.plq:
    mov eax, ebx
    cmp eax, NMODS
    jl .pm
    sub eax, NMODS
    cmp eax, NFIRES
    jl .pf
    sub eax, NFIRES                     ; (the frames, after the firing types)
    mov edi, [base_col+rax*4]
    mov esi, eax
    jmp .pmk
.pf:
    mov edi, [fire_col+rax*4]
    lea rsi, [NBASES+NMODS+rax]
    jmp .pmk
.pm:
    mov edi, [mod_col+rax*4]
    lea rsi, [NBASES+rax]
.pmk:
    mov r12, rsi
    call abgr
    mov r8d, eax                        ; background
    mov rdi, [part_names+r12*8]
    mov esi, 128
    mov edx, 128
    mov ecx, RGB(20,20,24)
    mov r9, [font_label]
    call make_plaque
    mov [plq_tex+rbx*4], eax
    inc ebx
    cmp ebx, NMODS+NFIRES+NBASES
    jl .plq
    EPILOGUE

; gadget_part_tex(edi = item kind, esi = which part; PART_BASE|base for a
; frame) -> eax = its plaque
gadget_part_tex:
    mov eax, [label_tex+rdi*4]
    cmp edi, IT_MODULE
    jne .fire
    test esi, PART_BASE
    jnz .base
    cmp esi, NMODS
    jae .out
    mov eax, [plq_tex+rsi*4]
    ret
.fire:
    cmp edi, IT_FIRING
    jne .out
    cmp esi, NFIRES
    jae .out
    mov eax, [plq_tex+NMODS*4+rsi*4]
.out:
    ret
.base:
    and esi, PART_BASE-1
    cmp esi, NBASES
    jae .out
    mov eax, [plq_tex+(NMODS+NFIRES)*4+rsi*4]
    ret

; gadget_save -- the catalog outlives the night (beacom_gadgets.cfg; only
; when the game saves things -- not in test runs)
gadget_save:
    PROLOGUE 16
    cmp dword [ach_persist], 0
    je .done
    lea rdi, [file_name]
    lea rsi, [mode_w]
    call fopen
    test rax, rax
    jz .done
    mov r12, rax
    lea rdi, [file_buf]
    mov esi, 64
    lea rdx, [fmt_save]
    mov ecx, [gd_known]
    xor eax, eax
    call snprintf
    lea rdi, [file_buf]
    call strlen
    lea rdi, [file_buf]
    mov esi, 1
    mov rdx, rax
    mov rcx, r12
    call fwrite
    mov rdi, r12
    call fclose
.done:
    EPILOGUE

; gadget_load -- read the catalog back
gadget_load:
    PROLOGUE 16
    lea rdi, [file_name]
    lea rsi, [mode_r]
    call fopen
    test rax, rax
    jz .done
    mov r12, rax
    lea rdi, [file_buf]
    mov esi, 1
    mov edx, 63
    mov rcx, r12
    call fread
    mov byte [file_buf+rax], 0
    mov rdi, r12
    call fclose
    xor ecx, ecx
.k:
    cmp ecx, 6
    jge .num
    mov al, [file_buf+rcx]
    cmp al, [key_save+rcx]
    jne .done
    inc ecx
    jmp .k
.num:
    lea rsi, [file_buf+6]
    xor ebx, ebx
.d:
    movzx eax, byte [rsi]
    sub eax, '0'
    cmp eax, 9
    ja .have
    imul ebx, ebx, 10
    add ebx, eax
    inc rsi
    jmp .d
.have:
    mov [gd_known], ebx
.done:
    EPILOGUE

section .data
align 4
bench_w     dd 780.0
bench_h     dd 590.0
c_tiny_g    dd 0.000001
fx_cols     dd RGBC(255,215,90), RGBC(170,165,150), RGBC(170,165,150), RGBC(170,165,150)
            dd RGBC(170,165,150), RGBC(255,215,90), RGBC(150,145,135), RGBC(150,145,135)
            dd RGBC(200,195,180), RGBC(200,195,180)
align 8
fx_strs     dq s_title, s_col0, s_col1, s_col2, s_foot, s_tm_on, s_tm_off, s_unknown, s_hint_drone, s_hint_hud

section .bss
alignb 4
bx0         resd 1
by0         resd 1
seg_tmp     resd 1
sb_ax       resd 1
sb_ay       resd 1
sb_az       resd 1
sb_dx       resd 1
sb_dy       resd 1
sb_dz       resd 1
sb_dd       resd 1
sb_r2       resd 1
hud_sw      resd 1
hud_sh      resd 1
