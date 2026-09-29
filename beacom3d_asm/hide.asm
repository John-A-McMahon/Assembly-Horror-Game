; =============================================================================
; hide.asm -- hiding under desks.
;
; E facing a desk ('d' cell, within reach): you squeeze under it. p_mode is
; MODE_HIDE -- you can't move, the camera drops under the desk top, and T
; can't see you (ai.asm skips his sight while hd_on). E again and you climb
; back out where you went in.
;
;   * If T SAW you go in, he knows: he comes to the desk (enemy_hear at the
;     spot you ducked from) and drags you out.
;   * If he didn't, he only finds you by checking: the first time he comes
;     within 2.8 m of your desk (per approach -- he has to walk off past
;     5 m before he checks again) he looks under it. The chance grows
;     with every time you've hidden tonight (he learns), with your
;     flashlight on, and a lot if you're making noise.
;
; Found: you're caught (t_caught), like being caught anywhere else.
; =============================================================================
%define MODULE_HIDE
%include "common.inc"

global hide_reset, hide_try, hide_leave, hide_update, hide_can, hd_on, hd_seen
global hd_count, hd_checked, hd_found, hd_cx, hd_cz

extern p_flash_on
extern p_mode, p_on_ground, p_crouch, t_sees, t_stun, t_caught, noise_level
extern enemy_hear, hud_message, snd_footstep

%define MODE_WALK 0
%define MODE_HIDE 5
%define COL_INFO 0xFFC8D4D8
%define COL_WARN 0xFF47B3FF
%define COL_BAD  0xFF5050FF

section .data
c_probe     dd 0.6, 1.1, 1.6            ; how far ahead to look for a desk
c_reach2    dd 7.84                     ; HD_REACH^2: 2.8 m -- T at your desk
c_forget2   dd 25.0                     ; HD_FORGET^2: 5 m -- he's walked off
c_same_y    dd 1.4
c_base_p    dd 0.15                     ; the chance he looks under YOUR desk...
c_learn_p   dd 0.15                     ; ...plus this per earlier hide tonight
c_noisy     dd 0.25                     ; ...plus c_noisy_p if you're this loud
c_noisy_p   dd 0.4
c_light_p   dd 0.25                     ; ...plus this with your flashlight on
c_max_p     dd 0.8
c_call_t    dd 1.5                      ; he saw you: he's told where, this often
c_call_r    dd 60.0
m_hide_in   db "You squeeze under the desk. Keep still, and kill the light. (E to climb out)",0
m_hide_seen db "He saw you go under there.",0
m_found     db "T drags you out from under the desk.",0
m_passed    db "T stops at your desk... looks under the next one... and moves on.",0

section .bss
alignb 4
hd_on       resd 1                      ; you're under a desk
hd_seen     resd 1                      ; ...and T saw you get there
hd_count    resd 1                      ; times you've hidden tonight
hd_checked  resd 1                      ; T has checked on this approach
hd_found    resd 1                      ; (tests) T found you
hd_cx       resd 1                      ; the desk (cell centre)
hd_cz       resd 1
hd_bx       resd 1                      ; where you went in from
hd_by       resd 1
hd_bz       resd 1
hd_call     resd 1                      ; seconds to the next enemy_hear
hd_ax       resd 1                      ; (hide_can's find)
hd_az       resd 1

section .text

; hide_reset -- a new night
hide_reset:
    xor eax, eax
    mov [hd_on], eax
    mov [hd_seen], eax
    mov [hd_count], eax
    mov [hd_checked], eax
    mov [hd_found], eax
    ret

; hide_can -> eax 1 if there's a desk to get under within reach ahead
; (hd_ax/hd_az = its cell centre). Walking, on the ground, not hidden.
hide_can:
    PROLOGUE 32
    xor eax, eax
    cmp dword [hd_on], 0
    jne .out
    cmp dword [p_mode], MODE_WALK
    jne .out
    cmp dword [p_on_ground], 0
    je .out
    movss xmm0, [p_yaw]
    call sinf
    xorps xmm0, [c_sign_mask]
    movss [rsp+0], xmm0                 ; forward x
    movss xmm0, [p_yaw]
    call cosf
    xorps xmm0, [c_sign_mask]
    movss [rsp+4], xmm0                 ; forward z
    call player_floor
    mov [rsp+8], eax
    xor ebx, ebx
.p:
    cmp ebx, 3
    jge .none
    movss xmm0, [rsp+0]
    mulss xmm0, [c_probe+rbx*4]
    addss xmm0, [p_x]
    mulss xmm0, [c_inv_cell]
    cvttss2si r12d, xmm0                ; cell x
    movss xmm0, [rsp+4]
    mulss xmm0, [c_probe+rbx*4]
    addss xmm0, [p_z]
    mulss xmm0, [c_inv_cell]
    cvttss2si r13d, xmm0                ; cell y
    mov edi, [rsp+8]
    mov esi, r12d
    mov edx, r13d
    call cell_at
    cmp eax, 'd'
    je .found
    inc ebx
    jmp .p
.found:
    cvtsi2ss xmm0, r12d
    addss xmm0, [c_half]
    mulss xmm0, [c_cell]
    movss [hd_ax], xmm0
    cvtsi2ss xmm0, r13d
    addss xmm0, [c_half]
    mulss xmm0, [c_cell]
    movss [hd_az], xmm0
    mov eax, 1
    jmp .out
.none:
    xor eax, eax
.out:
    EPILOGUE

; hide_try -> eax 1 if you got under a desk
hide_try:
    PROLOGUE 16
    call hide_can
    test eax, eax
    jz .out
    mov eax, [p_x]
    mov [hd_bx], eax
    mov eax, [p_y]
    mov [hd_by], eax
    mov eax, [p_z]
    mov [hd_bz], eax
    mov eax, [hd_ax]
    mov [hd_cx], eax
    mov [p_x], eax
    mov eax, [hd_az]
    mov [hd_cz], eax
    mov [p_z], eax
    mov dword [p_mode], MODE_HIDE
    mov dword [p_crouch], 1
    mov dword [hd_on], 1
    mov dword [hd_checked], 0
    mov dword [hd_found], 0
    mov dword [hd_call], 0
    inc dword [hd_count]
    xor eax, eax
    cmp dword [t_sees], 0
    setne al
    mov [hd_seen], eax
    xor edi, edi
    call snd_footstep
    lea rdi, [m_hide_in]
    mov esi, COL_INFO
    xor edx, edx
    call hud_message
    cmp dword [hd_seen], 0
    je .ok
    lea rdi, [m_hide_seen]
    mov esi, COL_WARN
    xor edx, edx
    call hud_message
.ok:
    mov eax, 1
.out:
    EPILOGUE

; hide_leave -> eax 1 if you climbed out (back where you went in, crouched)
hide_leave:
    PROLOGUE 16
    xor eax, eax
    cmp dword [hd_on], 0
    je .out
    mov eax, [hd_bx]
    mov [p_x], eax
    mov eax, [hd_by]
    mov [p_y], eax
    mov eax, [hd_bz]
    mov [p_z], eax
    mov dword [p_mode], MODE_WALK
    mov dword [hd_on], 0
    mov dword [hd_seen], 0
    xor edi, edi
    call snd_footstep
    mov eax, 1
.out:
    EPILOGUE

; hide_update(xmm0 = dt) -- every frame of play: does T find you?
hide_update:
    PROLOGUE 32
    movss [rsp+0], xmm0
    cmp dword [hd_on], 0
    je .out
    cmp dword [t_caught], 0
    jne .out
    ; he saw you go in: keep telling him where
    cmp dword [hd_seen], 0
    je .dist
    movss xmm0, [hd_call]
    subss xmm0, [rsp+0]
    movss [hd_call], xmm0
    comiss xmm0, [c_zero]
    ja .dist
    mov eax, [c_call_t]
    mov [hd_call], eax
    movss xmm0, [hd_bx]
    movss xmm1, [hd_by]
    movss xmm2, [hd_bz]
    movss xmm3, [c_call_r]
    call enemy_hear
.dist:
    ; T and your desk: same storey, flat distance
    movss xmm0, [t_y]
    subss xmm0, [p_y]
    andps xmm0, [c_abs_mask]
    comiss xmm0, [c_same_y]
    jae .far
    movss xmm0, [t_x]
    subss xmm0, [hd_cx]
    mulss xmm0, xmm0
    movss xmm1, [t_z]
    subss xmm1, [hd_cz]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    comiss xmm0, [c_forget2]
    jae .far
    comiss xmm0, [c_reach2]
    jae .out
    ; he's at your desk (and not knocked out)
    movss xmm0, [t_stun]
    comiss xmm0, [c_zero]
    ja .out
    cmp dword [hd_seen], 0
    jne .found
    cmp dword [hd_checked], 0
    jne .out
    mov dword [hd_checked], 1
    ; the chance he looks under this one
    mov eax, [hd_count]
    dec eax
    cvtsi2ss xmm1, eax
    mulss xmm1, [c_learn_p]
    addss xmm1, [c_base_p]
    movss xmm0, [noise_level]
    comiss xmm0, [c_noisy]
    jbe .quiet
    addss xmm1, [c_noisy_p]
.quiet:
    cmp dword [p_flash_on], 0
    je .dark
    addss xmm1, [c_light_p]
.dark:
    minss xmm1, [c_max_p]
    movss [rsp+4], xmm1
    call rand01
    comiss xmm0, [rsp+4]
    jb .found
    lea rdi, [m_passed]
    mov esi, COL_INFO
    xor edx, edx
    call hud_message
    jmp .out
.found:
    mov dword [hd_found], 1
    mov dword [t_caught], 1
    lea rdi, [m_found]
    mov esi, COL_BAD
    xor edx, edx
    call hud_message
    jmp .out
.far:
    mov dword [hd_checked], 0           ; he's walked off: next time he checks again
.out:
    EPILOGUE
