; =============================================================================
; player.asm -- first-person controller.
;
;   * yaw/pitch mouselook (yaw 0 looks toward -Z, like OpenGL's default camera)
;   * WASD movement (up/down arrows too; left/right arrows turn), SHIFT sprint (drains stamina, loud), C/CTRL crouch
;     (slow, quiet, harder for T to see), SPACE jump
;   * gravity, ground following on stair ramps, falling down open shafts
;   * collision against the grid, one axis at a time in 5cm sub-steps so you
;     slide along walls and can't tunnel through them
;   * flashlight battery: drains while on, recharges while off, flickers low
; =============================================================================
%define MODULE_PLAYER
%include "common.inc"

global player_spawn, player_update, player_look, player_floor, player_in_safe
global p_x, p_y, p_z, p_yaw, p_pitch, p_stamina, p_battery, p_flash_on, p_crouch
global p_exhausted, p_eye_y, p_step_event, p_flash_level, keys_down, p_roll, p_sprint
global p_vy, p_on_ground, p_bob
extern p_mode, trav_roll, trav_shake

; keys_down[] slots, filled by main.asm from SDL_GetKeyboardState
%define K_FWD    0
%define K_BACK   1
%define K_LEFT   2
%define K_RIGHT  3
%define K_SPRINT 4
%define K_CROUCH 5
%define K_JUMP   6
%define K_TURN_L 7
%define K_TURN_R 8

section .data
c_radius     dd 0.32          ; player's half-width
c_walk       dd 3.4           ; units / second
c_sprint     dd 6.0
c_crouch_spd dd 1.7
c_eye        dd 1.62          ; standing eye height
c_eye_crouch dd 0.95
c_body       dd 1.7
c_body_crouch dd 1.1
c_gravity    dd 19.0
c_jump       dd 5.2
c_step_up    dd 0.7           ; max step height onto a surface
c_snap       dd 0.45          ; follow the ground down steps up to this far
c_hard_land  dd -9.0
c_substep    dd 0.05
c_stride_walk   dd 1.7
c_stride_sprint dd 2.1
c_stride_crouch dd 1.2
c_st_drain   dd -0.2          ; stamina per second
c_st_walk    dd 0.1
c_st_rest    dd 0.18
c_st_empty   dd 0.01
c_st_recover dd 0.35
c_bat_drain  dd 240.0         ; seconds of light on a full battery
c_bat_charge dd 90.0          ; seconds to recharge fully
c_bat_low    dd 0.15
c_flick_hi   dd 0.6
c_flick_amt  dd 0.15
c_f31        dd 31.0
c_f7         dd 7.0
c_f055       dd 0.55
c_f045       dd 0.45
c_f4         dd 4.0
c_eye_lerp   dd 10.0
c_bob_walk   dd 8.5
c_bob_sprint dd 13.0
c_bobamt_walk   dd 0.035
c_bobamt_sprint dd 0.07
c_roll_k     dd 0.3
c_sens       dd 0.0022        ; radians per mouse count
c_turn_speed dd 2.4           ; radians per second with the arrow keys
c_pitch_max  dd 1.5
c_pitch_min  dd -1.5
c_head_r     dd 0.16
c_head_extra dd 0.1
c_start_yaw  dd -2.3561945    ; -3/4 pi: face into the first room

section .bss
p_x          resd 1           ; feet position (world units)
p_y          resd 1
p_z          resd 1
p_vy         resd 1
p_yaw        resd 1
p_pitch      resd 1
p_on_ground  resd 1
p_stamina    resd 1
p_battery    resd 1
p_flash_on   resd 1
p_crouch     resd 1
p_sprint     resd 1
p_exhausted  resd 1
p_eye        resd 1           ; current (smoothed) eye height
p_bob        resd 1
p_step_acc   resd 1
p_moving     resd 1
p_eye_y      resd 1           ; out: camera height (includes bob)
p_roll       resd 1           ; out: camera roll from bob
p_step_event resd 1           ; out: 0 none, 1 quiet step, 2 step, 3 loud step, 4 jump
p_flash_level resd 1          ; out: 0..1 flashlight brightness
keys_down    resb 16

section .text

; -----------------------------------------------------------------------------
; player_spawn(edi=f, esi=x, edx=y) -- stand in the middle of a cell.
; -----------------------------------------------------------------------------
player_spawn:
    cvtsi2ss xmm0, esi
    addss xmm0, [c_half]
    mulss xmm0, [c_cell]
    movss [p_x], xmm0
    cvtsi2ss xmm0, edx
    addss xmm0, [c_half]
    mulss xmm0, [c_cell]
    movss [p_z], xmm0
    cvtsi2ss xmm0, edi
    mulss xmm0, [c_fh]
    movss [p_y], xmm0
    xor eax, eax
    mov [p_vy], eax
    mov [p_pitch], eax
    mov [p_bob], eax
    mov [p_step_acc], eax
    mov [p_exhausted], eax
    mov eax, [c_start_yaw]
    mov [p_yaw], eax
    mov eax, [c_one]
    mov [p_stamina], eax
    mov [p_battery], eax
    mov eax, [c_eye]
    mov [p_eye], eax
    mov dword [p_flash_on], 1
    mov dword [p_on_ground], 1
    ret

; -----------------------------------------------------------------------------
; player_look(edi=mouse dx, esi=mouse dy)
; -----------------------------------------------------------------------------
player_look:
    cvtsi2ss xmm0, edi
    mulss xmm0, [c_sens]
    PCT xmm2, cfg_sens
    mulss xmm0, xmm2
    movss xmm1, [p_yaw]
    subss xmm1, xmm0
    movss [p_yaw], xmm1
    cvtsi2ss xmm0, esi
    mulss xmm0, [c_sens]
    PCT xmm2, cfg_sens
    mulss xmm0, xmm2
    movss xmm1, [p_pitch]
    subss xmm1, xmm0
    maxss xmm1, [c_pitch_min]
    minss xmm1, [c_pitch_max]
    movss [p_pitch], xmm1
    ret

; player_floor() -> eax = storey the player is on
player_floor:
    sub rsp, 8
    movss xmm0, [p_y]
    call floor_of_height
    add rsp, 8
    ret

; player_in_safe() -> eax = 1 if standing on an S (safe room) cell
player_in_safe:
    xor eax, eax
    cmp dword [cfg_safe], 0             ; custom run: no safe rooms
    je .no_safe
    PROLOGUE 16
    call player_floor
    mov edi, eax
    movss xmm0, [p_x]
    mulss xmm0, [c_inv_cell]
    cvttss2si esi, xmm0
    movss xmm0, [p_z]
    mulss xmm0, [c_inv_cell]
    cvttss2si edx, xmm0
    call cell_at
    xor ecx, ecx
    cmp eax, 'S'
    sete cl
    mov eax, ecx
    EPILOGUE
.no_safe:
    ret

; -----------------------------------------------------------------------------
; body_height() -> xmm0 (crouching bodies are shorter). leaf.
; -----------------------------------------------------------------------------
body_height:
    movss xmm0, [c_body]
    cmp dword [p_crouch], 0
    je .s
    movss xmm0, [c_body_crouch]
.s:
    ret

; -----------------------------------------------------------------------------
; try_move(xmm0=newX, xmm1=newZ) -> eax 1 if the player fits there.
; Tests from the ground height at the target so walking onto stairs works.
; -----------------------------------------------------------------------------
try_move:
    PROLOGUE 16
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss xmm2, [p_y]
    movss xmm3, [c_step_up]
    call ground_height
    maxss xmm0, [p_y]                   ; feet = max(y, ground)
    movaps xmm2, xmm0
    call body_height
    movaps xmm4, xmm0
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    movss xmm3, [c_radius]
    call collides
    xor eax, 1
    EPILOGUE

; -----------------------------------------------------------------------------
; slide(xmm0=dx, xmm1=dz) -- move with collision, x and z separately.
; -----------------------------------------------------------------------------
slide:
    PROLOGUE 16
    ; n = ceil(max(|dx|,|dz|) / 0.05)
    movaps xmm2, xmm0
    andps xmm2, [c_abs_mask]
    movaps xmm3, xmm1
    andps xmm3, [c_abs_mask]
    maxss xmm2, xmm3
    divss xmm2, [c_substep]
    cvttss2si ebx, xmm2
    inc ebx
    cvtsi2ss xmm2, ebx
    divss xmm0, xmm2
    divss xmm1, xmm2
    movss [rsp+0], xmm0                 ; sx
    movss [rsp+4], xmm1                 ; sz
.loop:
    test ebx, ebx
    jz .done
    dec ebx
    movss xmm0, [p_x]
    addss xmm0, [rsp+0]
    movss xmm1, [p_z]
    call try_move
    test eax, eax
    jz .no_x
    movss xmm0, [p_x]
    addss xmm0, [rsp+0]
    movss [p_x], xmm0
.no_x:
    movss xmm0, [p_x]
    movss xmm1, [p_z]
    addss xmm1, [rsp+4]
    call try_move
    test eax, eax
    jz .loop
    movss xmm1, [p_z]
    addss xmm1, [rsp+4]
    movss [p_z], xmm1
    jmp .loop
.done:
    EPILOGUE

; -----------------------------------------------------------------------------
; player_update(xmm0=dt, xmm1=time)
; -----------------------------------------------------------------------------
player_update:
    PROLOGUE 64
    ; [rsp+0] dt [rsp+4] t [rsp+8] fx [rsp+12] fz [rsp+16] len [rsp+20] speed
    ; [rsp+24] wx [rsp+28] wz [rsp+32] new y [rsp+36] ground [rsp+40] sin [rsp+44] cos
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    mov dword [p_step_event], 0

    ; ---- arrow-key turning (left increases yaw = turn left)
    movzx eax, byte [keys_down+K_TURN_L]
    movzx ecx, byte [keys_down+K_TURN_R]
    sub eax, ecx
    cvtsi2ss xmm0, eax
    mulss xmm0, [c_turn_speed]
    mulss xmm0, [rsp+0]
    addss xmm0, [p_yaw]
    movss [p_yaw], xmm0

    ; ---- input direction (fx = strafe right, fz = back)
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    cmp byte [keys_down+K_FWD], 0
    je .k1
    subss xmm1, [c_one]
.k1:
    cmp byte [keys_down+K_BACK], 0
    je .k2
    addss xmm1, [c_one]
.k2:
    cmp byte [keys_down+K_LEFT], 0
    je .k3
    subss xmm0, [c_one]
.k3:
    cmp byte [keys_down+K_RIGHT], 0
    je .k4
    addss xmm0, [c_one]
.k4:
    movss [rsp+8], xmm0
    movss [rsp+12], xmm1
    mulss xmm0, xmm0
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    movss [rsp+16], xmm0
    xor eax, eax
    comiss xmm0, [c_zero]
    seta al
    mov [p_moving], eax

    ; ---- crouch / sprint / stamina
    movzx eax, byte [keys_down+K_CROUCH]
    mov [p_crouch], eax
    xor ecx, ecx                        ; ecx = wants to sprint
    cmp byte [keys_down+K_SPRINT], 0
    je .no_want
    cmp dword [p_moving], 0
    je .no_want
    cmp dword [p_crouch], 0
    jne .no_want
    movss xmm0, [rsp+12]
    comiss xmm0, [c_zero]
    jae .no_want                        ; only sprint while going forward
    mov ecx, 1
.no_want:
    movss xmm0, [p_stamina]
    comiss xmm0, [c_st_empty]
    ja .not_empty
    mov dword [p_exhausted], 1
.not_empty:
    cmp dword [p_exhausted], 0
    je .ex_ok
    comiss xmm0, [c_st_recover]
    jbe .ex_ok
    mov dword [p_exhausted], 0
.ex_ok:
    cmp dword [p_exhausted], 0
    je .sp
    xor ecx, ecx
.sp:
    mov [p_sprint], ecx
    movss xmm1, [c_st_rest]
    cmp dword [p_moving], 0
    je .st
    movss xmm1, [c_st_walk]
.st:
    test ecx, ecx
    jz .st2
    movss xmm1, [c_st_drain]
    PCT xmm2, cfg_stamina
    mulss xmm1, xmm2
.st2:
    mulss xmm1, [rsp+0]
    addss xmm0, xmm1
    maxss xmm0, [c_zero]
    minss xmm0, [c_one]
    movss [p_stamina], xmm0

    movss xmm0, [c_walk]
    cmp dword [p_sprint], 0
    je .spd1
    movss xmm0, [c_sprint]
.spd1:
    cmp dword [p_crouch], 0
    je .spd2
    movss xmm0, [c_crouch_spd]
.spd2:
    PCT xmm1, cfg_walk
    mulss xmm0, xmm1
    movss [rsp+20], xmm0

    ; on a ladder or a zipline, traverse.asm moves you instead
    cmp dword [p_mode], 0
    jne .battery

    ; ---- horizontal movement
    cmp dword [p_moving], 0
    je .no_move
    movss xmm0, [p_yaw]
    call sinf
    movss [rsp+40], xmm0
    movss xmm0, [p_yaw]
    call cosf
    movss [rsp+44], xmm0
    ; normalise input and scale by speed*dt
    movss xmm2, [rsp+20]
    mulss xmm2, [rsp+0]
    divss xmm2, [rsp+16]                ; k = speed*dt/len
    movss xmm0, [rsp+8]
    mulss xmm0, xmm2                    ; fx*k
    movss xmm1, [rsp+12]
    mulss xmm1, xmm2                    ; fz*k
    ; wx = fx*c + fz*s ; wz = -fx*s + fz*c
    movaps xmm3, xmm0
    mulss xmm3, [rsp+44]
    movaps xmm4, xmm1
    mulss xmm4, [rsp+40]
    addss xmm3, xmm4
    movss [rsp+24], xmm3
    movaps xmm3, xmm1
    mulss xmm3, [rsp+44]
    movaps xmm4, xmm0
    mulss xmm4, [rsp+40]
    subss xmm3, xmm4
    movss [rsp+28], xmm3
    movss xmm0, [rsp+24]
    movss xmm1, [rsp+28]
    call slide
    ; footsteps
    movss xmm0, [rsp+24]
    mulss xmm0, xmm0
    movss xmm1, [rsp+28]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    addss xmm0, [p_step_acc]
    movss [p_step_acc], xmm0
    movss xmm1, [c_stride_walk]
    cmp dword [p_sprint], 0
    je .str1
    movss xmm1, [c_stride_sprint]
.str1:
    cmp dword [p_crouch], 0
    je .str2
    movss xmm1, [c_stride_crouch]
.str2:
    comiss xmm0, xmm1
    jbe .no_move
    cmp dword [p_on_ground], 0
    je .no_move
    mov dword [p_step_acc], 0
    mov eax, 2
    cmp dword [p_crouch], 0
    je .ev1
    mov eax, 1
.ev1:
    cmp dword [p_sprint], 0
    je .ev2
    mov eax, 3
.ev2:
    mov [p_step_event], eax
    mov edi, [p_sprint]
    call snd_footstep
.no_move:

    ; ---- jump
    cmp byte [keys_down+K_JUMP], 0
    je .no_jump
    cmp dword [p_on_ground], 0
    je .no_jump
    cmp dword [p_crouch], 0
    jne .no_jump
    PCT xmm0, cfg_jump                  ; jump height scales with v^2
    sqrtss xmm0, xmm0
    mulss xmm0, [c_jump]
    movss [p_vy], xmm0
    mov dword [p_on_ground], 0
    mov dword [p_step_event], 4         ; jumping makes a little noise
.no_jump:

    ; ---- gravity and ground following
    movss xmm0, [c_gravity]
    mulss xmm0, [rsp+0]
    movss xmm1, [p_vy]
    subss xmm1, xmm0
    movss [p_vy], xmm1
    mulss xmm1, [rsp+0]
    addss xmm1, [p_y]
    movss [rsp+32], xmm1                ; ny
    movss xmm2, xmm1
    maxss xmm2, [p_y]
    movss xmm0, [p_x]
    movss xmm1, [p_z]
    movss xmm3, [c_step_up]
    call ground_height
    movss [rsp+36], xmm0                ; g
    movss xmm1, [rsp+32]
    comiss xmm1, xmm0
    ja .above
    ; landed (hard landings make a loud noise)
    cmp dword [p_on_ground], 0
    jne .land
    movss xmm2, [p_vy]
    comiss xmm2, [c_hard_land]
    jae .land
    mov dword [p_step_event], 3
.land:
    movss [rsp+32], xmm0
    mov dword [p_vy], 0
    mov dword [p_on_ground], 1
    jmp .ground_done
.above:
    cmp dword [p_on_ground], 0
    je .airborne
    movss xmm2, [p_vy]
    comiss xmm2, [c_zero]
    ja .airborne
    movss xmm2, [p_y]
    subss xmm2, xmm0
    comiss xmm2, [c_snap]
    jae .airborne
    movss [rsp+32], xmm0                ; snap down the step
    mov dword [p_vy], 0
    jmp .ground_done
.airborne:
    mov dword [p_on_ground], 0
.ground_done:
    ; bonk your head on the ceiling when jumping
    movss xmm0, [p_vy]
    comiss xmm0, [c_zero]
    jbe .no_bonk
    call body_height
    addss xmm0, [c_head_extra]
    movaps xmm4, xmm0
    movss xmm0, [p_x]
    movss xmm1, [p_z]
    movss xmm2, [rsp+32]
    movss xmm3, [c_head_r]
    call collides
    test eax, eax
    jz .no_bonk
    mov dword [p_vy], 0
    mov eax, [p_y]
    mov [rsp+32], eax
.no_bonk:
    mov eax, [rsp+32]
    mov [p_y], eax

    ; ---- flashlight battery
.battery:
    movss xmm0, [p_battery]
    cmp dword [p_flash_on], 0
    je .charging
    movss xmm1, [rsp+0]
    divss xmm1, [c_bat_drain]
    PCT xmm2, cfg_battery
    mulss xmm1, xmm2
    subss xmm0, xmm1
    comiss xmm0, [c_zero]
    ja .bat_store
    xorps xmm0, xmm0
    mov dword [p_flash_on], 0
    jmp .bat_store
.charging:
    movss xmm1, [rsp+0]
    divss xmm1, [c_bat_charge]
    addss xmm0, xmm1
    minss xmm0, [c_one]
.bat_store:
    movss [p_battery], xmm0
    ; brightness = on * flicker * (0.55 + 0.45*min(1, battery*4))
    xorps xmm0, xmm0
    movss [p_flash_level], xmm0
    cmp dword [p_flash_on], 0
    je .flash_done
    movss xmm0, [c_one]
    movss [rsp+48], xmm0                ; flicker factor
    movss xmm0, [p_battery]
    comiss xmm0, [c_bat_low]
    jae .no_flicker
    movss xmm0, [rsp+4]
    mulss xmm0, [c_f31]
    call sinf
    movss [rsp+52], xmm0
    movss xmm0, [rsp+4]
    mulss xmm0, [c_f7]
    call sinf
    mulss xmm0, [rsp+52]
    comiss xmm0, [c_flick_hi]
    jbe .no_flicker
    mov eax, [c_flick_amt]
    mov [rsp+48], eax
.no_flicker:
    movss xmm0, [p_battery]
    mulss xmm0, [c_f4]
    minss xmm0, [c_one]
    mulss xmm0, [c_f045]
    addss xmm0, [c_f055]
    mulss xmm0, [rsp+48]
    movss [p_flash_level], xmm0
.flash_done:

    ; ---- camera height: smoothed crouch + head bob
    movss xmm1, [c_eye]
    cmp dword [p_crouch], 0
    je .eye1
    movss xmm1, [c_eye_crouch]
.eye1:
    subss xmm1, [p_eye]
    movss xmm2, [rsp+0]
    mulss xmm2, [c_eye_lerp]
    minss xmm2, [c_one]
    mulss xmm1, xmm2
    addss xmm1, [p_eye]
    movss [p_eye], xmm1

    xorps xmm3, xmm3                    ; bob amount
    cmp dword [p_moving], 0
    je .bob_done
    cmp dword [p_on_ground], 0
    je .bob_done
    movss xmm0, [c_bob_walk]
    movss xmm3, [c_bobamt_walk]
    cmp dword [p_sprint], 0
    je .bob1
    movss xmm0, [c_bob_sprint]
    movss xmm3, [c_bobamt_sprint]
.bob1:
    mulss xmm0, [rsp+0]
    addss xmm0, [p_bob]
    movss [p_bob], xmm0
.bob_done:
    PCT xmm2, cfg_bob
    mulss xmm3, xmm2
    movss [rsp+56], xmm3
    movss xmm0, [p_bob]
    addss xmm0, xmm0
    call sinf
    mulss xmm0, [rsp+56]
    addss xmm0, [p_eye]
    addss xmm0, [p_y]
    movss xmm1, [trav_shake]            ; zipline speed shake
    PCT xmm2, cfg_shake
    mulss xmm1, xmm2
    addss xmm0, xmm1
    movss [p_eye_y], xmm0
    movss xmm0, [p_bob]
    call sinf
    mulss xmm0, [rsp+56]
    mulss xmm0, [c_roll_k]
    movss xmm1, [trav_roll]             ; zipline sway
    PCT xmm2, cfg_shake
    mulss xmm1, xmm2
    addss xmm0, xmm1
    movss [p_roll], xmm0
    EPILOGUE
