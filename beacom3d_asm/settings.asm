; =============================================================================
; settings.asm -- every knob in the game, and the pause menu that turns them.
;
; The menu is a table (ROW below): each row points at the variable it edits
; (a plain dword the rest of the game reads), says what kind of value it is
; and its range, and has a short key for the settings file. The game code
; reads the cfg_* dwords directly -- percentages are integers (100 = normal).
;
;   ESC            pause / resume
;   UP/DOWN, W/S   choose a row          mouse: hover
;   LEFT/RIGHT,A/D change it             mouse: left click +, right click -
;   ENTER / SPACE  resume, restart, ...  mouse wheel: scroll
;
; The actions come first, then the custom run, so both are on screen the
; moment the menu opens. Rows marked * apply when you restart.
; Everything is saved to beacom_settings.cfg when you close the menu, and
; loaded again at start-up (not in --shot / --selftest runs).
; =============================================================================
%define MODULE_SETTINGS
%include "common.inc"

global settings_load, settings_save, settings_apply, menu_key, menu_mouse, menu_click
global menu_wheel, menu_draw, menu_reset
global cfg_building, cfg_t_speed, cfg_t_hear, cfg_t_vision, cfg_t_angry, cfg_t_ladders
global cfg_t_drops, cfg_safe, cfg_deauths, cfg_start_map, cfg_portal, cfg_stamina
global cfg_battery, cfg_walk, cfg_jump, cfg_zip, cfg_sens, cfg_crouch_toggle, cfg_fov
global cfg_bob, cfg_shake, cfg_bright, cfg_hands, cfg_heart, cfg_volume, cfg_grain, cfg_layout
global cfg_hookshot

extern invert_y, show_fps, shadows_on, shadows_ok, render_scale
extern draw_text, draw_rect, font_hud, font_small, font_big, tt_w, tt_h, glDeleteTextures
extern fwrite, ach_flag

%define T_HEADER 0
%define T_INT    1
%define T_PCT    2
%define T_CHOICE 3
%define T_ACTION 4
%define T_INFO   5              ; shown, not changed (achievements)

%define ROW_SIZE 48
%define R_LABEL  0
%define R_VALUE  8
%define R_TYPE   16
%define R_MIN    20
%define R_MAX    24
%define R_STEP   28
%define R_NAMES  32
%define R_KEY    40
; label, key (0 = not saved), value ptr, type, min, max, step, names (or 0)
%macro ROW 8
    dq %1, %3
    dd %4, %5, %6, %7
    dq %8, %2
%endmacro

%define RGBC(r,g,b) (0xFF000000 | ((b)<<16) | ((g)<<8) | (r))

section .data
; ---- the settings themselves (defaults) ----------------------------------------
align 4
cfg_building    dd 0            ; 0 the real Beacom maps, 1 generated from the seed
cfg_layout      dd 1            ; generated: 0 maze, 1 classic, 2 open
cfg_t_speed     dd 100
cfg_t_hear      dd 100
cfg_t_vision    dd 100
cfg_t_angry     dd 1            ; faster with every capture you take
cfg_t_drops     dd 1            ; follows you off ledges
cfg_t_ladders   dd 0            ; climbs ladders after you
cfg_safe        dd 1            ; safe rooms work
cfg_deauths     dd 3
cfg_start_map   dd 0
cfg_portal      dd 0            ; 0 somewhere in the building, 1 start with it, 2 none
cfg_hookshot    dd 0            ; (same)
cfg_stamina     dd 100
cfg_battery     dd 100
cfg_walk        dd 100
cfg_jump        dd 100
cfg_zip         dd 100
cfg_sens        dd 100
cfg_crouch_toggle dd 0
cfg_fov         dd 72           ; vertical, degrees
cfg_bob         dd 100
cfg_shake       dd 100
cfg_bright      dd 100
cfg_hands       dd 1
cfg_heart       dd 1
cfg_volume      dd 100
cfg_grain       dd 50           ; film grain over the whole picture

; ---- labels -----------------------------------------------------------------
h_run       db "CUSTOM RUN   (rows marked * apply when you pick RESTART above)",0
l_building  db "Building *",0
l_layout    db "Generated layout *",0
l_t_speed   db "T speed",0
l_t_hear    db "T hearing",0
l_t_vision  db "T vision",0
l_t_angry   db "T speeds up with every capture",0
l_t_drops   db "T drops off ledges after you",0
l_t_ladders db "T climbs ladders after you",0
l_safe      db "Safe rooms",0
l_deauths   db "Deauth packets in the building *",0
l_start_map db "Map + compass *",0
l_portal    db "Portal gun *",0
l_hookshot  db "Hookshot *",0
h_you       db "YOU",0
l_stamina   db "Sprint stamina drain",0
l_battery   db "Flashlight battery drain",0
l_walk      db "Walk speed",0
l_jump      db "Jump height",0
l_zip       db "Zipline speed",0
h_controls  db "CONTROLS",0
l_sens      db "Mouse sensitivity",0
l_invert    db "Invert mouse Y",0
l_crouch    db "Crouch",0
h_comfort   db "COMFORT & ACCESSIBILITY",0
l_fov       db "Field of view (degrees)",0
l_bob       db "Head bob",0
l_shake     db "Camera shake + zipline sway",0
l_bright    db "Brightness",0
l_hands     db "Show hands",0
l_heart     db "Heartbeat",0
l_volume    db "Master volume",0
h_graphics  db "GRAPHICS",0
l_scale     db "Render resolution",0
l_shadows   db "Flashlight shadows",0
l_fps       db "FPS counter",0
l_grain     db "Film grain",0
a_resume    db "> RESUME",0
h_ach       db "ACHIEVEMENTS",0
l_ach0     db "PACKET SNIFFER - collect a wireshark capture",0
l_ach1     db "FULL CAPTURE - bring all three to B and free Y",0
l_ach2     db "PACIFIST - win without firing a deauth packet",0
l_ach3     db "GHOST PROTOCOL - win without T ever seeing you",0
l_ach4     db "SPEEDRUN.EXE - win in under 5 minutes",0
l_ach5     db "SILENT RUNNING - win without a single shh!",0
l_ach6     db "ARCHITECT - win in a generated building",0
l_ach7     db "LOST IN THE MAZE - win a generated maze",0
l_ach8     db "POINT BLANK - deauth T from under 4 m away",0
l_ach9     db "FREE RUNNER - 10 mantles or vaults in one run",0
l_ach10     db "ZIPLINE ZOOMER - ride a zipline to the very end",0
l_ach11     db "THINKING WITH PORTALS - step through a portal",0
l_ach12     db "SAFE AND SOUND - reach a safe room while chased",0
l_ach13     db "STAGE FRIGHT - stand on the stage while chased",0
l_ach14     db "KING OF THE CRATES - stand on a tall crate stack",0
l_ach15     db "HI I AM TYLER - meet Tyler",0
l_ach16     db "CHICKEN JOCKEY - find the chicken jockey",0
l_ach17     db "NETWORKING - talk to B",0
l_ach18     db "GET OVER HERE - hit T with the hookshot",0
l_ach19     db "SPIDER-BEACOM - hookshot yourself 2.5 m up",0
s_locked    db "locked",0
s_unlocked  db "UNLOCKED",0
fmt_info    db "%s",0
a_restart   db "> RESTART THIS RUN (same seed)",0
a_newseed   db "> RESTART WITH A NEW SEED",0
a_quit      db "> QUIT TO THE TERMINAL",0

; ---- keys in the settings file ------------------------------------------------
k_building  db "building",0
k_layout    db "layout",0
k_t_speed   db "t_speed",0
k_t_hear    db "t_hearing",0
k_t_vision  db "t_vision",0
k_t_angry   db "t_angry",0
k_t_drops   db "t_drops",0
k_t_ladders db "t_ladders",0
k_safe      db "safe_rooms",0
k_deauths   db "deauths",0
k_start_map db "start_with_map",0
k_portal    db "portal_gun",0
k_hookshot  db "hookshot",0
k_stamina   db "stamina_drain",0
k_battery   db "battery_drain",0
k_walk      db "walk_speed",0
k_jump      db "jump_height",0
k_zip       db "zipline_speed",0
k_sens      db "mouse_sensitivity",0
k_invert    db "invert_y",0
k_crouch    db "crouch_toggle",0
k_fov       db "fov",0
k_bob       db "head_bob",0
k_shake     db "camera_shake",0
k_bright    db "brightness",0
k_hands     db "show_hands",0
k_heart     db "heartbeat",0
k_volume    db "volume",0
k_scale     db "render_scale",0
k_shadows   db "shadows",0
k_fps       db "fps_counter",0
k_grain     db "film_grain",0

; ---- choice names ---------------------------------------------------------------
s_off       db "OFF",0
s_on        db "ON",0
s_classic   db "THE REAL BEACOM (researched)",0
s_generated db "GENERATED FROM THE SEED",0
s_original  db "THE ORIGINAL GAME MAP",0
s_maze      db "MAZE (tight, twisty)",0
s_classic2  db "CLASSIC",0
s_open      db "OPEN (sightlines, cover)",0
s_hidden    db "HIDDEN IN THE BUILDING",0
s_start_w   db "START WITH THEM",0
s_start_it  db "START WITH IT",0
s_none      db "NONE",0
s_hold      db "HOLD",0
s_toggle    db "TOGGLE",0
s_full      db "FULL",0
s_half      db "1/2 (fast)",0
s_third     db "1/3 (fastest)",0
align 8
n_offon     dq s_off, s_on
n_ach       dq s_locked, s_unlocked
n_building  dq s_classic, s_generated, s_original
n_layout    dq s_maze, s_classic2, s_open
n_map       dq s_hidden, s_start_w
n_portal    dq s_hidden, s_start_it, s_none
n_crouch    dq s_hold, s_toggle
n_scale     dq s_full, s_half, s_third

rows:
    ROW a_resume,    0,           0,              T_ACTION, 0, 0, 0, 0
    ROW a_restart,   0,           0,              T_ACTION, 1, 0, 0, 0
    ROW a_newseed,   0,           0,              T_ACTION, 2, 0, 0, 0
    ROW a_quit,      0,           0,              T_ACTION, 3, 0, 0, 0
    ROW h_run,       0,           0,              T_HEADER, 0, 0, 0, 0
    ROW l_building,  k_building,  cfg_building,   T_CHOICE, 0, 2, 1, n_building
    ROW l_layout,    k_layout,    cfg_layout,     T_CHOICE, 0, 2, 1, n_layout
    ROW l_t_speed,   k_t_speed,   cfg_t_speed,    T_PCT,   40, 250, 10, 0
    ROW l_t_hear,    k_t_hear,    cfg_t_hear,     T_PCT,   25, 300, 25, 0
    ROW l_t_vision,  k_t_vision,  cfg_t_vision,   T_PCT,   25, 300, 25, 0
    ROW l_t_angry,   k_t_angry,   cfg_t_angry,    T_CHOICE, 0, 1, 1, n_offon
    ROW l_t_drops,   k_t_drops,   cfg_t_drops,    T_CHOICE, 0, 1, 1, n_offon
    ROW l_t_ladders, k_t_ladders, cfg_t_ladders,  T_CHOICE, 0, 1, 1, n_offon
    ROW l_safe,      k_safe,      cfg_safe,       T_CHOICE, 0, 1, 1, n_offon
    ROW l_deauths,   k_deauths,   cfg_deauths,    T_INT,    0, 9, 1, 0
    ROW l_start_map, k_start_map, cfg_start_map,  T_CHOICE, 0, 1, 1, n_map
    ROW l_portal,    k_portal,    cfg_portal,     T_CHOICE, 0, 2, 1, n_portal
    ROW l_hookshot,  k_hookshot,  cfg_hookshot,   T_CHOICE, 0, 2, 1, n_portal
    ROW h_you,       0,           0,              T_HEADER, 0, 0, 0, 0
    ROW l_stamina,   k_stamina,   cfg_stamina,    T_PCT,    0, 300, 25, 0
    ROW l_battery,   k_battery,   cfg_battery,    T_PCT,    0, 300, 25, 0
    ROW l_walk,      k_walk,      cfg_walk,       T_PCT,   50, 200, 10, 0
    ROW l_jump,      k_jump,      cfg_jump,       T_PCT,   50, 200, 10, 0
    ROW l_zip,       k_zip,       cfg_zip,        T_PCT,   50, 250, 10, 0
    ROW h_controls,  0,           0,              T_HEADER, 0, 0, 0, 0
    ROW l_sens,      k_sens,      cfg_sens,       T_PCT,   10, 400, 10, 0
    ROW l_invert,    k_invert,    invert_y,       T_CHOICE, 0, 1, 1, n_offon
    ROW l_crouch,    k_crouch,    cfg_crouch_toggle, T_CHOICE, 0, 1, 1, n_crouch
    ROW h_comfort,   0,           0,              T_HEADER, 0, 0, 0, 0
    ROW l_fov,       k_fov,       cfg_fov,        T_INT,   50, 110, 2, 0
    ROW l_bob,       k_bob,       cfg_bob,        T_PCT,    0, 200, 25, 0
    ROW l_shake,     k_shake,     cfg_shake,      T_PCT,    0, 200, 25, 0
    ROW l_bright,    k_bright,    cfg_bright,     T_PCT,   50, 300, 10, 0
    ROW l_hands,     k_hands,     cfg_hands,      T_CHOICE, 0, 1, 1, n_offon
    ROW l_heart,     k_heart,     cfg_heart,      T_CHOICE, 0, 1, 1, n_offon
    ROW l_volume,    k_volume,    cfg_volume,     T_PCT,    0, 100, 10, 0
    ROW h_graphics,  0,           0,              T_HEADER, 0, 0, 0, 0
    ROW l_scale,     k_scale,     render_scale,   T_CHOICE, 1, 3, 1, n_scale
    ROW l_shadows,   k_shadows,   shadows_on,     T_CHOICE, 0, 1, 1, n_offon
    ROW l_fps,       k_fps,       show_fps,       T_CHOICE, 0, 1, 1, n_offon
    ROW l_grain,     k_grain,     cfg_grain,      T_PCT,    0, 200, 25, 0
    ROW h_ach,       0,           0,              T_HEADER, 0, 0, 0, 0
    ROW l_ach0,     0,           ach_flag+0,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach1,     0,           ach_flag+4,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach2,     0,           ach_flag+8,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach3,     0,           ach_flag+12,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach4,     0,           ach_flag+16,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach5,     0,           ach_flag+20,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach6,     0,           ach_flag+24,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach7,     0,           ach_flag+28,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach8,     0,           ach_flag+32,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach9,     0,           ach_flag+36,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach10,     0,           ach_flag+40,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach11,     0,           ach_flag+44,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach12,     0,           ach_flag+48,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach13,     0,           ach_flag+52,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach14,     0,           ach_flag+56,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach15,     0,           ach_flag+60,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach16,     0,           ach_flag+64,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach17,     0,           ach_flag+68,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach18,     0,           ach_flag+72,     T_INFO,   0, 1, 1, n_ach
    ROW l_ach19,     0,           ach_flag+76,     T_INFO,   0, 1, 1, n_ach
rows_end:
%define NROWS ((rows_end - rows) / ROW_SIZE)

s_title     db "PAUSED  -  T is waiting",0
s_help      db "UP/DOWN choose    LEFT/RIGHT change    ENTER select    ESC resume    (or mouse: hover, click, wheel)",0
fmt_int     db "<  %d  >",0
fmt_pct     db "<  %d%%  >",0
fmt_choice  db "<  %s  >",0
cfg_name    db "beacom_settings.cfg",0
mode_w      db "w",0
mode_r      db "r",0
fmt_line    db "%s=%d",10,0

c_row_h     dd 30.0
c_top       dd 110.0
c_panel_w   dd 860.0

section .bss
alignb 4
menu_sel    resd 1
menu_first  resd 1              ; first row on screen
menu_vis    resd 1              ; rows that fit
menu_x0     resd 1              ; panel left edge (float), for the mouse
menu_y0     resd 1              ; first row's top (float)
lbl_tex     resd NROWS
lbl_w       resd NROWS
lbl_h       resd NROWS
val_tex     resd NROWS
val_w       resd NROWS
val_h       resd NROWS
val_shown   resd NROWS          ; the value val_tex shows (so it's redrawn on change)
title_tex   resd 3              ; title, help
title_w     resd 3
title_h     resd 3
made        resd 1
fmt_buf2    resb 128
file_buf    resb 4096

section .text

; row_ptr(edi=row) -> rax. leaf
row_ptr:
    imul eax, edi, ROW_SIZE
    lea rax, [rows+rax]
    ret

; menu_reset -- open at the top: RESUME, with the custom run right below
menu_reset:
    mov dword [menu_sel], 0
    mov dword [menu_first], 0
    ret

; selectable(edi=row) -> eax 1 unless it's a header. leaf
selectable:
    call row_ptr
    xor ecx, ecx
    cmp dword [rax+R_TYPE], T_HEADER    ; (achievements can be scrolled to,
    je .no                              ; just not changed)
    inc ecx
.no:
    mov eax, ecx
    ret

; move_sel(edi=+1/-1) -- next selectable row that way (stops at the ends)
move_sel:
    PROLOGUE 16
    mov r12d, edi
    mov ebx, [menu_sel]
.step:
    add ebx, r12d
    cmp ebx, 0
    jl .done
    cmp ebx, NROWS
    jge .done
    mov edi, ebx
    call selectable
    test eax, eax
    jz .step
    mov [menu_sel], ebx
.done:
    EPILOGUE

; change(edi=row, esi=+1/-1) -> eax = action id if the row is an action
; (and it was "pressed"), else -1. Values wrap around at their ends.
change:
    PROLOGUE 16
    mov r12d, esi
    call row_ptr
    mov rbx, rax
    mov eax, [rbx+R_TYPE]
    cmp eax, T_ACTION
    jne .value
    mov eax, -1
    cmp r12d, 0
    jl .out                             ; right click on an action: nothing
    mov eax, [rbx+R_MIN]
    EPILOGUE
.value:
    cmp eax, T_HEADER
    je .none
    cmp eax, T_INFO
    je .none
    mov rdx, [rbx+R_VALUE]
    mov eax, [rdx]
    mov ecx, [rbx+R_STEP]
    imul ecx, r12d
    add eax, ecx
    cmp eax, [rbx+R_MAX]
    jle .lo
    mov eax, [rbx+R_MIN]                ; wrap
    jmp .set
.lo:
    cmp eax, [rbx+R_MIN]
    jge .set
    mov eax, [rbx+R_MAX]
.set:
    mov [rdx], eax
    call settings_apply
.none:
    mov eax, -1
.out:
    EPILOGUE

; menu_key(edi=scancode) -> eax = action (0 resume 1 restart 2 new seed
; 3 quit) or -1
menu_key:
    PROLOGUE 16
    mov ebx, edi
    cmp ebx, SC_UP
    je .up
    cmp ebx, SC_W
    je .up
    cmp ebx, SC_DOWN
    je .down
    cmp ebx, SC_S
    je .down
    cmp ebx, SC_LEFT
    je .left
    cmp ebx, SC_A
    je .left
    cmp ebx, SC_RIGHT
    je .right
    cmp ebx, SC_D
    je .right
    cmp ebx, SC_RETURN
    je .enter
    cmp ebx, SC_SPACE
    je .enter
    mov eax, -1
    EPILOGUE
.up:
    mov edi, -1
    call move_sel
    mov eax, -1
    EPILOGUE
.down:
    mov edi, 1
    call move_sel
    mov eax, -1
    EPILOGUE
.left:
    mov edi, [menu_sel]
    mov esi, -1
    call change
    mov eax, -1                         ; LEFT never fires an action
    EPILOGUE
.right:
    mov edi, [menu_sel]
    mov esi, 1
    call change
    EPILOGUE
.enter:
    mov edi, [menu_sel]
    mov esi, 1
    call change
    EPILOGUE

; row_at(edi=x, esi=y) -> eax = row under the cursor, or -1. leaf-ish
row_at:
    cvtsi2ss xmm0, edi
    comiss xmm0, [menu_x0]
    jb .none
    movss xmm1, [menu_x0]
    addss xmm1, [c_panel_w]
    comiss xmm0, xmm1
    ja .none
    cvtsi2ss xmm0, esi
    subss xmm0, [menu_y0]
    comiss xmm0, [c_zero]
    jb .none
    divss xmm0, [c_row_h]
    cvttss2si eax, xmm0
    cmp eax, [menu_vis]
    jge .none
    add eax, [menu_first]
    cmp eax, NROWS
    jge .none
    ret
.none:
    mov eax, -1
    ret

; menu_mouse(edi=x, esi=y) -- hovering picks the row
menu_mouse:
    PROLOGUE 16
    call row_at
    cmp eax, 0
    jl .done
    mov ebx, eax
    mov edi, eax
    call selectable
    test eax, eax
    jz .done
    mov [menu_sel], ebx
.done:
    EPILOGUE

; menu_click(edi=button 1 left / 3 right, esi=x, edx=y) -> eax action or -1
menu_click:
    PROLOGUE 16
    mov r12d, edi
    mov edi, esi
    mov esi, edx
    call row_at
    cmp eax, 0
    jl .none
    mov ebx, eax
    mov edi, eax
    call selectable
    test eax, eax
    jz .none
    mov [menu_sel], ebx
    mov edi, ebx
    mov esi, 1
    cmp r12d, 3
    jne .go
    mov esi, -1
.go:
    call change
    EPILOGUE
.none:
    mov eax, -1
    EPILOGUE

; menu_wheel(edi=+1 up / -1 down)
menu_wheel:
    PROLOGUE 16
    neg edi
    call move_sel
    EPILOGUE

; settings_apply -- push settings that live in other modules' state
settings_apply:
    mov eax, 1 << LK_WALK
    cmp dword [cfg_t_drops], 0
    je .no_drop
    or eax, 1 << LK_DROP
.no_drop:
    cmp dword [cfg_t_ladders], 0
    je .no_ladder
    or eax, 1 << LK_LADDER
.no_ladder:
    mov [nav_t_mask], eax
    ; safe rooms off: T may walk into them
    and byte [char_class+'S'], ~CF_TWALK
    cmp dword [cfg_safe], 0
    jne .safe_on
    or byte [char_class+'S'], CF_TWALK
.safe_on:
    cmp dword [shadows_ok], 0
    jne .sh
    mov dword [shadows_on], 0           ; no shadow framebuffer on this GPU
.sh:
    ret

; ---- drawing ------------------------------------------------------------------

; text(rdi=font, rsi=text, edx=colour) -> eax tex, ecx w, r8d h
text:
    PROLOGUE 16
    xor ecx, ecx
    call make_text_texture
    mov ecx, [tt_w]
    mov r8d, [tt_h]
    EPILOGUE

; make_static -- the labels and title, once
make_static:
    PROLOGUE 16
    xor ebx, ebx
.r:
    cmp ebx, NROWS
    jge .rows_done
    mov edi, ebx
    call row_ptr
    mov r12, rax
    mov rdi, [font_hud]
    mov edx, RGBC(216,212,200)
    cmp dword [r12+R_TYPE], T_HEADER
    jne .lbl
    mov edx, RGBC(255,179,71)
.lbl:
    cmp dword [r12+R_TYPE], T_ACTION
    jne .lbl2
    mov edx, RGBC(143,227,143)
.lbl2:
    cmp dword [r12+R_TYPE], T_INFO
    jne .lbl3
    mov edx, RGBC(190,184,150)
.lbl3:
    mov rsi, [r12+R_LABEL]
    call text
    mov [lbl_tex+rbx*4], eax
    mov [lbl_w+rbx*4], ecx
    mov [lbl_h+rbx*4], r8d
    mov dword [val_shown+rbx*4], 0x80000000
    mov dword [val_tex+rbx*4], 0
    inc ebx
    jmp .r
.rows_done:
    mov rdi, [font_big]
    lea rsi, [s_title]
    mov edx, RGBC(176,20,26)
    call text
    mov [title_tex], eax
    mov [title_w], ecx
    mov [title_h], r8d
    mov rdi, [font_small]
    lea rsi, [s_help]
    mov edx, RGBC(150,150,150)
    call text
    mov [title_tex+4], eax
    mov [title_w+4], ecx
    mov [title_h+4], r8d
    mov dword [made], 1
    EPILOGUE

; refresh_value(ebx=row) -- re-render the value text if it changed
refresh_value:
    PROLOGUE 16
    mov edi, ebx
    call row_ptr
    mov r12, rax
    mov eax, [r12+R_TYPE]
    cmp eax, T_INT
    jl .done
    cmp eax, T_ACTION
    je .done
    mov rdx, [r12+R_VALUE]
    mov r13d, [rdx]
    cmp r13d, [val_shown+rbx*4]
    je .done
    mov [val_shown+rbx*4], r13d
    cmp dword [val_tex+rbx*4], 0
    je .fmt
    mov edi, 1
    lea rsi, [val_tex+rbx*4]
    call glDeleteTextures
.fmt:
    lea rdi, [fmt_buf2]
    mov esi, 128
    mov ecx, r13d
    lea rdx, [fmt_int]
    cmp dword [r12+R_TYPE], T_PCT
    jne .not_pct
    lea rdx, [fmt_pct]
.not_pct:
    cmp dword [r12+R_TYPE], T_INFO
    jne .not_info
    lea rdx, [fmt_info]
    jmp .named
.not_info:
    cmp dword [r12+R_TYPE], T_CHOICE
    jne .print
    lea rdx, [fmt_choice]
.named:
    mov eax, r13d
    sub eax, [r12+R_MIN]
    mov rcx, [r12+R_NAMES]
    mov rcx, [rcx+rax*8]
.print:
    xor eax, eax
    call snprintf
    mov rdi, [font_hud]
    lea rsi, [fmt_buf2]
    mov edx, RGBC(159,220,255)
    call text
    mov [val_tex+rbx*4], eax
    mov [val_w+rbx*4], ecx
    mov [val_h+rbx*4], r8d
.done:
    EPILOGUE

; menu_draw(edi=screen w, esi=screen h) -- called by hud_draw while paused
menu_draw:
    PROLOGUE 64
    mov [rsp+0], edi
    mov [rsp+4], esi
    cmp dword [made], 0
    jne .have
    call make_static
.have:
    ; dim the world
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    cvtsi2ss xmm2, dword [rsp+0]
    cvtsi2ss xmm3, dword [rsp+4]
    xorps xmm4, xmm4
    xorps xmm5, xmm5
    xorps xmm6, xmm6
    FLD xmm7, 0.86
    call draw_rect
    ; panel position
    cvtsi2ss xmm0, dword [rsp+0]
    subss xmm0, [c_panel_w]
    mulss xmm0, [c_half]
    maxss xmm0, [c_zero]
    movss [menu_x0], xmm0
    mov eax, [c_top]
    mov [menu_y0], eax
    ; how many rows fit, and scroll so the selection is visible
    cvtsi2ss xmm0, dword [rsp+4]
    subss xmm0, [c_top]
    FLD xmm1, 50.0
    subss xmm0, xmm1
    divss xmm0, [c_row_h]
    cvttss2si eax, xmm0
    cmp eax, 3
    jge .vis
    mov eax, 3
.vis:
    mov [menu_vis], eax
    mov ecx, [menu_sel]
    cmp ecx, [menu_first]
    jge .not_above
    mov [menu_first], ecx
.not_above:
    mov edx, [menu_first]
    add edx, eax
    cmp ecx, edx
    jl .not_below
    sub ecx, eax
    inc ecx
    mov [menu_first], ecx
.not_below:
    ; a solid panel behind the rows
    movss xmm0, [menu_x0]
    movss xmm1, [c_top]
    FLD xmm2, 6.0
    subss xmm1, xmm2
    movss xmm2, [c_panel_w]
    cvtsi2ss xmm3, dword [menu_vis]
    mulss xmm3, [c_row_h]
    FLD xmm4, 12.0
    addss xmm3, xmm4
    FLD xmm4, 0.03
    FLD xmm5, 0.03
    FLD xmm6, 0.045
    FLD xmm7, 0.97
    call draw_rect
    ; title and help
    mov edi, [title_tex]
    mov esi, [title_w]
    mov edx, [title_h]
    cvtsi2ss xmm0, dword [rsp+0]
    cvtsi2ss xmm1, esi
    subss xmm0, xmm1
    mulss xmm0, [c_half]
    FLD xmm1, 26.0
    movss xmm2, [c_one]
    call draw_text
    mov edi, [title_tex+4]
    mov esi, [title_w+4]
    mov edx, [title_h+4]
    cvtsi2ss xmm0, dword [rsp+0]
    cvtsi2ss xmm1, esi
    subss xmm0, xmm1
    mulss xmm0, [c_half]
    FLD xmm1, 78.0
    movss xmm2, [c_one]
    call draw_text
    ; the rows
    xor r12d, r12d                      ; screen slot
.row:
    cmp r12d, [menu_vis]
    jge .rows_done
    mov ebx, [menu_first]
    add ebx, r12d
    cmp ebx, NROWS
    jge .rows_done
    cvtsi2ss xmm0, r12d
    mulss xmm0, [c_row_h]
    addss xmm0, [c_top]
    movss [rsp+8], xmm0                 ; row top
    ; highlight
    cmp ebx, [menu_sel]
    jne .no_hl
    movss xmm0, [menu_x0]
    movss xmm1, [rsp+8]
    movss xmm2, [c_panel_w]
    movss xmm3, [c_row_h]
    FLD xmm4, 0.55
    FLD xmm5, 0.08
    FLD xmm6, 0.1
    FLD xmm7, 0.55
    call draw_rect
.no_hl:
    ; label
    mov edi, ebx
    call row_ptr
    mov r13, rax
    mov edi, [lbl_tex+rbx*4]
    mov esi, [lbl_w+rbx*4]
    mov edx, [lbl_h+rbx*4]
    movss xmm0, [menu_x0]
    FLD xmm1, 16.0
    addss xmm0, xmm1
    cmp dword [r13+R_TYPE], T_HEADER
    jne .indent
    FLD xmm1, -8.0
    addss xmm0, xmm1
.indent:
    movss xmm1, [rsp+8]
    movss xmm2, [c_one]
    call draw_text
    ; value, right aligned
    call refresh_value
    cmp dword [r13+R_TYPE], T_INT
    jl .next
    cmp dword [r13+R_TYPE], T_ACTION
    je .next
    mov edi, [val_tex+rbx*4]
    mov esi, [val_w+rbx*4]
    mov edx, [val_h+rbx*4]
    movss xmm0, [menu_x0]
    addss xmm0, [c_panel_w]
    cvtsi2ss xmm1, esi
    subss xmm0, xmm1
    FLD xmm1, 16.0
    subss xmm0, xmm1
    movss xmm1, [rsp+8]
    movss xmm2, [c_one]
    call draw_text
.next:
    inc r12d
    jmp .row
.rows_done:
    EPILOGUE

; ---- the settings file -----------------------------------------------------------

; settings_save -- key=value per line
settings_save:
    PROLOGUE 32
    lea rdi, [cfg_name]
    lea rsi, [mode_w]
    call fopen
    test rax, rax
    jz .done
    mov r14, rax
    xor ebx, ebx
.r:
    cmp ebx, NROWS
    jge .close
    mov edi, ebx
    call row_ptr
    mov r12, rax
    cmp qword [r12+R_KEY], 0
    je .n
    lea rdi, [fmt_buf2]
    mov esi, 128
    lea rdx, [fmt_line]
    mov rcx, [r12+R_KEY]
    mov r8, [r12+R_VALUE]
    mov r8d, [r8]
    xor eax, eax
    call snprintf
    lea rdi, [fmt_buf2]
    call strlen
    lea rdi, [fmt_buf2]
    mov esi, 1
    mov edx, eax
    mov rcx, r14
    call fwrite
.n:
    inc ebx
    jmp .r
.close:
    mov rdi, r14
    call fclose
.done:
    EPILOGUE

; settings_load -- read beacom_settings.cfg if there is one; unknown keys
; and out-of-range values are ignored / clamped
settings_load:
    PROLOGUE 32
    lea rdi, [cfg_name]
    lea rsi, [mode_r]
    call fopen
    test rax, rax
    jz .apply
    mov r14, rax
    lea rdi, [file_buf]
    mov esi, 1
    mov edx, 4095
    mov rcx, r14
    call fread
    mov byte [file_buf+rax], 0
    mov rdi, r14
    call fclose
    lea r12, [file_buf]                 ; line start
.line:
    cmp byte [r12], 0
    je .apply
    ; find '=' and the end of the line
    mov r13, r12
.find:
    movzx eax, byte [r13]
    test eax, eax
    jz .apply
    cmp eax, 10
    je .skip_line
    cmp eax, '='
    je .eq
    inc r13
    jmp .find
.eq:
    ; which key? compare [r12, r13) with each row's key
    xor ebx, ebx
.k:
    cmp ebx, NROWS
    jge .skip_line
    mov edi, ebx
    call row_ptr
    mov r15, rax
    mov rsi, [r15+R_KEY]
    test rsi, rsi
    jz .kn
    mov rdi, r12
.cmp:
    cmp rdi, r13
    je .key_end
    mov al, [rdi]
    cmp al, [rsi]
    jne .kn
    inc rdi
    inc rsi
    jmp .cmp
.key_end:
    cmp byte [rsi], 0
    jne .kn
    ; parse a signed integer after '='
    lea rdi, [r13+1]
    xor eax, eax
    xor ecx, ecx                        ; negative?
    cmp byte [rdi], '-'
    jne .digits
    mov ecx, 1
    inc rdi
.digits:
    movzx edx, byte [rdi]
    sub edx, '0'
    cmp edx, 9
    ja .num_done
    imul eax, eax, 10
    add eax, edx
    inc rdi
    jmp .digits
.num_done:
    test ecx, ecx
    jz .pos
    neg eax
.pos:
    cmp eax, [r15+R_MIN]
    jge .lo_ok
    mov eax, [r15+R_MIN]
.lo_ok:
    cmp eax, [r15+R_MAX]
    jle .hi_ok
    mov eax, [r15+R_MAX]
.hi_ok:
    mov rdx, [r15+R_VALUE]
    mov [rdx], eax
    jmp .skip_line
.kn:
    inc ebx
    jmp .k
.skip_line:
    movzx eax, byte [r12]
    test eax, eax
    jz .apply
    inc r12
    cmp eax, 10
    jne .skip_line
    jmp .line
.apply:
    call settings_apply
    EPILOGUE
