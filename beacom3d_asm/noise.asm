; =============================================================================
; noise.asm -- the noise meter. Replaces the original "1 in N steps makes a
; noise" dice roll: every sound you make adds to a meter that drains while
; you're quiet, and how far away T can hear you depends on how full it is.
;
;   crouch step 0.03   walk step 0.10   sprint step 0.26   jump 0.12
;   hard landing 0.45  ladder rung 0.07 flashlight click 0.04
;   deauth 0.5         portal shot 0.2  knocking a box over 0.3
;
; T hears you when  meter * NOISE_RANGE  >  distance (vertical counts extra,
; see enemy_hear in ai.asm). The HUD bar marks that line for T's current
; distance, so detection is something you can see and control.
; =============================================================================
%define MODULE_NOISE
%include "common.inc"

global noise_level, noise_add, noise_update, noise_reset, noise_range

section .data
noise_range     dd 40.0             ; a full meter carries this far (world units)
c_decay_still   dd 0.30             ; per second, standing still
c_decay_moving  dd 0.18             ; walking
c_decay_crouch  dd 0.45             ; crouching drains it fastest
c_emit_period   dd 0.5              ; ongoing noise re-alerts T this often
c_emit_min      dd 0.12
c_warn_on       dd 0.75             ; "shh! You made a noise!"
c_warn_off      dd 0.45
m_noise         db "shh! You made a noise!",0

section .bss
noise_level     resd 1              ; 0..1
emit_timer      resd 1
warned          resd 1

section .text

noise_reset:
    xor eax, eax
    mov [noise_level], eax
    mov [emit_timer], eax
    mov [warned], eax
    ret

; noise_add(xmm0=amount) -- a sound happened; T may hear it right away
noise_add:
    PROLOGUE 16
    addss xmm0, [noise_level]
    minss xmm0, [c_one]
    movss [noise_level], xmm0
    call emit
    call check_warning
    EPILOGUE

; emit -- tell T about the current noise at the player's position
emit:
    PROLOGUE 16
    movss xmm3, [noise_level]
    mulss xmm3, [noise_range]
    movss xmm0, [p_x]
    movss xmm1, [p_y]
    movss xmm2, [p_z]
    call enemy_hear
    EPILOGUE

check_warning:
    PROLOGUE 16
    movss xmm0, [noise_level]
    cmp dword [warned], 0
    jne .armed
    comiss xmm0, [c_warn_on]
    jb .done
    mov dword [warned], 1
    inc dword [run_warned]              ; (no SILENT RUNNING this run)
    lea rdi, [m_noise]
    mov esi, 0xFF47B3FF                 ; warning orange (ABGR)
    xor edx, edx
    call hud_message
    call snd_noise_alert
    jmp .done
.armed:
    comiss xmm0, [c_warn_off]
    ja .done
    mov dword [warned], 0               ; quiet again: the next spike warns again
.done:
    EPILOGUE

; noise_update(xmm0=dt) -- drain the meter; loud moments keep alerting T
noise_update:
    PROLOGUE 16
    movss [rsp+0], xmm0
    movss xmm1, [c_decay_still]
    cmp dword [p_crouch], 0
    je .not_crouch
    movss xmm1, [c_decay_crouch]
    jmp .decay
.not_crouch:
    cmp byte [keys_down+0], 0           ; moving forward/back/sideways?
    jne .moving
    cmp byte [keys_down+1], 0
    jne .moving
    cmp byte [keys_down+2], 0
    jne .moving
    cmp byte [keys_down+3], 0
    je .decay
.moving:
    movss xmm1, [c_decay_moving]
.decay:
    mulss xmm1, [rsp+0]
    movss xmm0, [noise_level]
    subss xmm0, xmm1
    maxss xmm0, [c_zero]
    movss [noise_level], xmm0
    ; while it's still noisy, T keeps hearing it every half second
    movss xmm1, [emit_timer]
    subss xmm1, [rsp+0]
    movss [emit_timer], xmm1
    comiss xmm1, [c_zero]
    ja .no_emit
    mov eax, [c_emit_period]
    mov [emit_timer], eax
    comiss xmm0, [c_emit_min]
    jb .no_emit
    call emit
.no_emit:
    call check_warning
    EPILOGUE
