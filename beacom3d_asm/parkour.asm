; =============================================================================
; parkour.asm -- mantling and vaulting (and the ground you can stand on).
;
; SPACE in front of something too tall to step onto:
;   * mantle -- a ledge up to 1.95 m above your feet with room to stand on
;     top: you pull yourself up and over (desks, crates, box stacks, the
;     atrium's balcony edge from the top of the crates in the pit below)
;   * vault  -- sprinting at something waist high (up to 1.2 m) with clear
;     floor right behind it: one hop over it, landing on the far side
; Both work from a standing start or in mid-air after a jump (catch the
; ledge). T can't do either: they are ways to put obstacles between you.
;
; While a move plays, traverse.asm's p_mode is MODE_MOVE and this module
; moves you along a scripted path: up then forward for a mantle, an arc for
; a vault. The slide (sprint + crouch) lives in player.asm.
; =============================================================================
%define MODULE_PARKOUR
%include "common.inc"

global parkour_try, parkour_update, player_ground, pk_kind

extern p_mode, p_vy, p_on_ground, p_sprint, trav_roll, props_top, snd_footstep

%define MODE_WALK 0
%define MODE_MOVE 3
%define PK_MANTLE 1
%define PK_VAULT  2

section .data
c_rise_min  dd 0.45                 ; below this it's a step or a jump
c_rise_max  dd 1.95                 ; the highest ledge you can pull up to
c_vault_max dd 1.2                  ; the highest thing you can vault
c_probe     dd 0.45, 0.7, 0.95      ; how far ahead to look for the edge
c_over      dd 0.3                  ; mantle: end this far past the edge
c_land      dd 1.3                  ; vault: land this far past the edge
c_radius    dd 0.32
c_thin      dd 0.22
c_body      dd 1.7
c_crouch_b  dd 1.1
c_clear     dd 0.95
c_apex      dd 0.35                 ; vault: clear the top by this much
c_drop_max  dd 1.3                  ; vault: don't vault into a deep drop
c_step_ok   dd 0.35
c_mdur0     dd 0.28                 ; mantle takes 0.28 s + 0.28 s per metre
c_mdur1     dd 0.28
c_vdur      dd 0.5
c_noise_m   dd 0.05
c_noise_v   dd 0.09
c_roll_m    dd 0.05
c_roll_v    dd -0.09

section .bss
alignb 4
pk_kind     resd 1                  ; 0 none, 1 mantle, 2 vault
mv_s        resd 3                  ; start / end of the move
mv_e        resd 3
mv_apex     resd 1
mv_t        resd 1
mv_dur      resd 1
fx          resd 1                  ; facing
fz          resd 1

section .text

; player_ground(xmm0=X, xmm1=Z, xmm2=feet, xmm3=step) -> xmm0: the highest
; thing under that point you could stand on, no higher than feet+step --
; the building (ground_height) or the top of a box (props_top)
player_ground:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    addss xmm2, xmm3
    movss [rsp+8], xmm2
    subss xmm2, xmm3
    call ground_height
    movss [rsp+12], xmm0
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+8]
    call props_top
    maxss xmm0, [rsp+12]
    EPILOGUE

; ahead(xmm0 = distance) -> xmm0 = X, xmm1 = Z that far in front of you. leaf
ahead:
    movaps xmm1, xmm0
    mulss xmm0, [fx]
    addss xmm0, [p_x]
    mulss xmm1, [fz]
    addss xmm1, [p_z]
    ret

; parkour_try() -> eax 1 if a mantle or vault started
parkour_try:
    PROLOGUE 64
    ; [rsp+0] ledge height [rsp+4] probe distance [rsp+8] Px [rsp+12] Pz
    ; [rsp+16] landing X [rsp+20] landing Z [rsp+24] landing height
    cmp dword [p_mode], MODE_WALK
    jne .no
    movss xmm0, [p_yaw]
    call sinf
    xorps xmm0, [c_sign_mask]
    movss [fx], xmm0                    ; forward = (-sin yaw, -cos yaw)
    movss xmm0, [p_yaw]
    call cosf
    xorps xmm0, [c_sign_mask]
    movss [fz], xmm0
    ; ---- find the edge: the first probe that is a climbable rise
    xor ebx, ebx
.probe:
    cmp ebx, 3
    jge .no
    movss xmm0, [c_probe+rbx*4]
    movss [rsp+4], xmm0
    call ahead
    movss [rsp+8], xmm0
    movss [rsp+12], xmm1
    movss xmm2, [p_y]
    movss xmm3, [c_rise_max]
    call player_ground
    movss [rsp+0], xmm0
    subss xmm0, [p_y]
    comiss xmm0, [c_rise_min]
    jb .next_probe
    ; room to stand up there (crouched at least), and no ceiling above you
    movss xmm0, [rsp+8]
    movss xmm1, [rsp+12]
    movss xmm2, [rsp+0]
    movss xmm3, [c_thin]
    movss xmm4, [c_crouch_b]
    call collides
    test eax, eax
    jnz .no
    movss xmm0, [p_x]
    movss xmm1, [p_z]
    movss xmm2, [rsp+0]
    movss xmm3, [c_thin]
    movss xmm4, [c_crouch_b]
    call collides
    test eax, eax
    jnz .no
    jmp .edge
.next_probe:
    inc ebx
    jmp .probe
.edge:
    ; ---- vault? sprinting, low enough, and clear floor right behind it
    cmp dword [p_sprint], 0
    je .mantle
    movss xmm0, [rsp+0]
    subss xmm0, [p_y]
    comiss xmm0, [c_vault_max]
    ja .mantle
    movss xmm0, [rsp+4]
    addss xmm0, [c_land]
    call ahead
    movss [rsp+16], xmm0
    movss [rsp+20], xmm1
    movss xmm2, [p_y]
    movss xmm3, [c_step_ok]
    call player_ground
    movss [rsp+24], xmm0
    movss xmm1, [p_y]
    subss xmm1, xmm0
    comiss xmm1, [c_drop_max]           ; a big drop behind: mantle instead
    ja .mantle
    movss xmm0, [rsp+16]                ; somewhere to land
    movss xmm1, [rsp+20]
    movss xmm2, [rsp+24]
    movss xmm3, [c_radius]
    movss xmm4, [c_body]
    call collides
    test eax, eax
    jnz .mantle
    movss xmm0, [rsp+4]                 ; and nothing in the way over the top
    addss xmm0, [c_over]
    call ahead
    movss xmm2, [rsp+0]
    addss xmm2, [c_step_ok]
    movss xmm3, [c_thin]
    movss xmm4, [c_clear]
    call collides
    test eax, eax
    jnz .mantle
    ; go: an arc over it
    mov dword [pk_kind], PK_VAULT
    mov eax, [rsp+16]
    mov [mv_e+0], eax
    mov eax, [rsp+24]
    mov [mv_e+4], eax
    mov eax, [rsp+20]
    mov [mv_e+8], eax
    movss xmm0, [rsp+0]
    addss xmm0, [c_apex]
    movss [mv_apex], xmm0
    mov eax, [c_vdur]
    mov [mv_dur], eax
    movss xmm0, [c_noise_v]
    jmp .start
.mantle:
    ; up, then over the edge (just to the edge if there's no room further in)
    mov dword [pk_kind], PK_MANTLE
    movss xmm0, [rsp+4]
    addss xmm0, [c_over]
    call ahead
    movss [rsp+16], xmm0
    movss [rsp+20], xmm1
    movss xmm2, [rsp+0]
    movss xmm3, [c_thin]
    movss xmm4, [c_crouch_b]
    call collides
    test eax, eax
    jz .far_ok
    mov eax, [rsp+8]
    mov [rsp+16], eax
    mov eax, [rsp+12]
    mov [rsp+20], eax
.far_ok:
    mov eax, [rsp+16]
    mov [mv_e+0], eax
    mov eax, [rsp+0]
    mov [mv_e+4], eax
    mov eax, [rsp+20]
    mov [mv_e+8], eax
    movss xmm0, [rsp+0]
    subss xmm0, [p_y]
    mulss xmm0, [c_mdur1]
    addss xmm0, [c_mdur0]
    movss [mv_dur], xmm0
    movss xmm0, [c_noise_m]
.start:
    call noise_add
    mov eax, [p_x]
    mov [mv_s+0], eax
    mov eax, [p_y]
    mov [mv_s+4], eax
    mov eax, [p_z]
    mov [mv_s+8], eax
    mov dword [mv_t], 0
    mov dword [p_vy], 0
    mov dword [p_mode], MODE_MOVE
    xor edi, edi
    call snd_footstep                   ; hands and shoes on the edge
    mov eax, 1
    EPILOGUE
.no:
    xor eax, eax
    EPILOGUE

; smooth(xmm0 = t in 0..1) -> 3t^2 - 2t^3. leaf
smooth:
    maxss xmm0, [c_zero]
    minss xmm0, [c_one]
    movaps xmm1, xmm0
    mulss xmm1, xmm0                    ; t^2
    movaps xmm2, xmm1
    mulss xmm2, xmm0                    ; t^3
    FLD xmm3, 3.0
    mulss xmm1, xmm3
    addss xmm2, xmm2
    subss xmm1, xmm2
    movaps xmm0, xmm1
    ret

; parkour_update(xmm0 = dt) -- play the move (traverse_update calls this
; while p_mode is MODE_MOVE)
parkour_update:
    PROLOGUE 32
    divss xmm0, [mv_dur]
    addss xmm0, [mv_t]
    minss xmm0, [c_one]
    movss [mv_t], xmm0
    cmp dword [pk_kind], PK_VAULT
    je .vault
    ; mantle: rise first (eased), move over the edge once you're mostly up
    movss xmm0, [mv_t]
    FLD xmm1, 1.8
    mulss xmm0, xmm1
    call smooth
    movss [rsp+0], xmm0                 ; height fraction
    movss xmm0, [mv_t]
    FLD xmm1, 0.35
    subss xmm0, xmm1
    FLD xmm1, 1.5385                    ; 1 / 0.65
    mulss xmm0, xmm1
    call smooth
    movss [rsp+4], xmm0                 ; forward fraction
    movss xmm0, [mv_e+4]
    subss xmm0, [mv_s+4]
    mulss xmm0, [rsp+0]
    addss xmm0, [mv_s+4]
    movss [p_y], xmm0
    movss xmm0, [c_roll_m]
    jmp .place
.vault:
    ; an arc: forward smoothly, up over the top and down the far side
    movss xmm0, [mv_t]
    call smooth
    movss [rsp+4], xmm0
    movss xmm0, [mv_t]
    mulss xmm0, [c_pi]
    call sinf
    movss [rsp+8], xmm0                 ; 0 -> 1 -> 0
    movss xmm1, [mv_e+4]
    subss xmm1, [mv_s+4]
    movss xmm2, xmm1
    mulss xmm2, [mv_t]
    addss xmm2, [mv_s+4]                ; straight line start -> end
    mulss xmm1, [c_half]
    addss xmm1, [mv_s+4]                ; its middle
    movss xmm3, [mv_apex]
    subss xmm3, xmm1
    maxss xmm3, [c_zero]
    mulss xmm3, [rsp+8]
    addss xmm2, xmm3
    movss [p_y], xmm2
    movss xmm0, [c_roll_v]
.place:
    movss [rsp+12], xmm0
    ; horizontal
    movss xmm0, [mv_e+0]
    subss xmm0, [mv_s+0]
    mulss xmm0, [rsp+4]
    addss xmm0, [mv_s+0]
    movss [p_x], xmm0
    movss xmm0, [mv_e+8]
    subss xmm0, [mv_s+8]
    mulss xmm0, [rsp+4]
    addss xmm0, [mv_s+8]
    movss [p_z], xmm0
    mov dword [p_vy], 0
    ; the camera leans into it
    movss xmm0, [mv_t]
    mulss xmm0, [c_pi]
    call sinf
    mulss xmm0, [rsp+12]
    movss [trav_roll], xmm0
    movss xmm0, [mv_t]
    comiss xmm0, [c_one]
    jb .done
    ; done: back on your feet
    mov dword [p_mode], MODE_WALK
    mov dword [p_on_ground], 1
    mov dword [trav_roll], 0
    mov dword [pk_kind], 0
    mov edi, 1
    call snd_footstep
    movss xmm0, [c_noise_m]
    call noise_add
.done:
    EPILOGUE
