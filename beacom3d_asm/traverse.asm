; =============================================================================
; traverse.asm -- ladders and ziplines: ways around the building that only
; you can use (T can't climb or ride -- they're your escape routes).
;
; Ladders: map character 'u' is the bottom cell of a ladder, fixed to the
;   wall next to it; the cell above it on the next floor is '.', a hatch.
;   Walk into the ladder and push W to climb; at the top keep pushing W to
;   step off onto the floor above. Walking into a hatch from above grabs the
;   ladder on the way down. Space lets go. Every rung clanks (noise meter).
;
; Ziplines: a cable along the longest corridor of each floor, plus one
;   dropping a whole storey across the atrium, high end -> low end. Stand under it and press E to grab; you accelerate to the far
;   end (Space drops you early). The camera sways, shakes and the field of
;   view opens up with speed.
; =============================================================================
%define MODULE_TRAVERSE
%include "common.inc"

global traverse_reset, traverse_update, traverse_try_grab, ladder_dir
global p_mode, trav_prompt, trav_roll, trav_shake, trav_fov, climb_phase
global zip_count, zip_ax, zip_ay, zip_az, zip_bx, zip_by, zip_bz, zip_active, zip_t

extern p_vy, p_on_ground, snd_clank, snd_zip, parkour_update

%define MODE_WALK   0
%define MODE_LADDER 1
%define MODE_ZIP    2
%define NZIP        4

section .data
; ziplines (world units): high end A -> low end B -- any two points in 3D.
; One along the longest corridor of each floor, and one down across the
; atrium: from the 2nd-floor server room over the void (under the 2nd
; floor's edge on the far side) to the ground-floor balcony.
;             basement   ground floor  second floor  atrium
zip_ax      dd 111.0,    7.0,          7.0,          85.0
zip_ay      dd 2.95,     6.15,         9.35,         9.35
zip_az      dd 53.0,     29.0,         5.0,          37.0
zip_bx      dd 7.0,      111.0,        111.0,        63.0
zip_by      dd 2.55,     5.75,         8.95,         5.75
zip_bz      dd 53.0,     29.0,         5.0,          37.0
zip_count   dd NZIP

c_climb_speed dd 2.2
c_rung        dd 0.3                ; one clank per rung
c_wall_gap    dd 0.62               ; how far from the ladder's wall you hang
c_dismount    dd 1.25               ; step this far past the wall at the top
c_hang        dd 2.15               ; feet below the cable while riding
c_zip_accel   dd 6.0
c_zip_max     dd 11.0
c_zip_start   dd 1.5
c_grab_r      dd 1.3                ; horizontal reach to the cable
c_grab_lo     dd -0.4               ; cable height relative to your eyes
c_grab_hi     dd 1.5
c_eye         dd 1.62
c_whirr_every dd 0.07
c_noise_rung  dd 0.07
c_noise_zip   dd 0.015
c_fov_kick    dd 0.14

section .bss
p_mode      resd 1                  ; 0 walk, 1 ladder, 2 zipline
trav_prompt resd 1                  ; -1, 7 zipline, 8 ladder (hud prompt index)
trav_roll   resd 1                  ; extra camera roll (zipline sway)
trav_shake  resd 1                  ; extra camera height jitter
trav_fov    resd 1                  ; field-of-view boost, 0..~0.14
climb_phase resd 1                  ; for the hands: distance climbed
lad_f       resd 1                  ; the ladder being climbed
lad_x       resd 1                  ; its anchor (world, next to the wall)
lad_z       resd 1
lad_dx      resd 1                  ; direction to its wall
lad_dz      resd 1
lad_base    resd 1                  ; bottom and top heights
lad_top     resd 1
rung_acc    resd 1
zip_active  resd 1                  ; which cable we're on
zip_t       resd 1                  ; 0..1 along it
zip_speed   resd 1
zip_cand    resd 1                  ; cable you could grab right now (-1 none)
whirr_t     resd 1
sway_t      resd 1

section .text

traverse_reset:
    xor eax, eax
    mov [p_mode], eax
    mov [trav_roll], eax
    mov [trav_shake], eax
    mov [trav_fov], eax
    mov [climb_phase], eax
    mov dword [trav_prompt], -1
    mov dword [zip_cand], -1
    mov dword [zip_active], -1
    ret

; ladder_dir(edi=f, esi=x, edx=y) -> eax = 0 +x, 1 -x, 2 +z, 3 -z: the side
; with a wall on this floor and open floor on the floor above; -1 if none
ladder_dir:
    PROLOGUE 32
    mov [rsp+0], edi
    mov [rsp+4], esi
    mov [rsp+8], edx
    xor ebx, ebx
.d:
    cmp ebx, 4
    jge .none
    mov esi, [rsp+4]
    mov edx, [rsp+8]
    cmp ebx, 0
    jne .d1
    inc esi
.d1:
    cmp ebx, 1
    jne .d2
    dec esi
.d2:
    cmp ebx, 2
    jne .d3
    inc edx
.d3:
    cmp ebx, 3
    jne .d4
    dec edx
.d4:
    mov r12d, esi
    mov r13d, edx
    mov edi, [rsp+0]
    call cell_at
    test byte [char_class+rax], CF_WALL
    jz .nd
    mov edi, [rsp+0]
    inc edi
    mov esi, r12d
    mov edx, r13d
    call cell_at
    test byte [char_class+rax], CF_FLAT
    jnz .found
.nd:
    inc ebx
    jmp .d
.found:
    mov eax, ebx
    EPILOGUE
.none:
    mov eax, -1
    EPILOGUE

; start_climb(edi=f, esi=x, edx=y, ecx=dir, xmm0=start height)
start_climb:
    PROLOGUE 16
    movss [rsp+0], xmm0
    mov [lad_f], edi
    ; direction vector toward the wall
    xorps xmm1, xmm1
    xorps xmm2, xmm2
    cmp ecx, 0
    jne .c1
    movss xmm1, [c_one]
.c1:
    cmp ecx, 1
    jne .c2
    movss xmm1, [c_neg_one]
.c2:
    cmp ecx, 2
    jne .c3
    movss xmm2, [c_one]
.c3:
    cmp ecx, 3
    jne .c4
    movss xmm2, [c_neg_one]
.c4:
    movss [lad_dx], xmm1
    movss [lad_dz], xmm2
    ; anchor = cell centre + dir * gap
    cvtsi2ss xmm0, esi
    addss xmm0, [c_half]
    mulss xmm0, [c_cell]
    movaps xmm3, xmm1
    mulss xmm3, [c_wall_gap]
    addss xmm0, xmm3
    movss [lad_x], xmm0
    cvtsi2ss xmm0, edx
    addss xmm0, [c_half]
    mulss xmm0, [c_cell]
    movaps xmm3, xmm2
    mulss xmm3, [c_wall_gap]
    addss xmm0, xmm3
    movss [lad_z], xmm0
    cvtsi2ss xmm0, edi
    mulss xmm0, [c_fh]
    movss [lad_base], xmm0
    addss xmm0, [c_fh]
    movss [lad_top], xmm0
    mov eax, [rsp+0]
    mov [p_y], eax
    mov dword [p_vy], 0
    mov dword [p_mode], MODE_LADDER
    mov dword [rung_acc], 0
    EPILOGUE

; forward_dot(xmm0=dx, xmm1=dz) -> xmm0 = how much you face that way. leaf-ish
forward_dot:
    PROLOGUE 16
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss xmm0, [p_yaw]
    call sinf
    movss [rsp+8], xmm0
    movss xmm0, [p_yaw]
    call cosf
    ; forward = (-sin, -cos)
    mulss xmm0, [rsp+4]
    movss xmm1, [rsp+8]
    mulss xmm1, [rsp+0]
    addss xmm0, xmm1
    xorps xmm0, [c_sign_mask]
    EPILOGUE

; walk_checks -- while walking: ladders at your feet or under you, cables above
walk_checks:
    PROLOGUE 32
    mov dword [trav_prompt], -1
    mov dword [zip_cand], -1
    movss xmm0, [p_x]
    mulss xmm0, [c_inv_cell]
    cvttss2si r13d, xmm0
    movss xmm0, [p_z]
    mulss xmm0, [c_inv_cell]
    cvttss2si r14d, xmm0
    call player_floor
    mov r12d, eax
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, 'u'
    jne .hatch
    ; standing at the foot of a ladder
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call ladder_dir
    cmp eax, 0
    jl .zips
    mov ebx, eax
    mov dword [trav_prompt], 8
    cmp byte [keys_down+0], 0           ; W
    je .zips
    ; facing the wall?
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    cmp ebx, 0
    jne .f1
    movss xmm0, [c_one]
.f1:
    cmp ebx, 1
    jne .f2
    movss xmm0, [c_neg_one]
.f2:
    cmp ebx, 2
    jne .f3
    movss xmm1, [c_one]
.f3:
    cmp ebx, 3
    jne .f4
    movss xmm1, [c_neg_one]
.f4:
    call forward_dot
    FLD xmm1, 0.3
    comiss xmm0, xmm1
    jb .zips
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, ebx
    cvtsi2ss xmm0, r12d
    mulss xmm0, [c_fh]
    call start_climb
    EPILOGUE
.hatch:
    ; stepped into a hatch: grab the ladder below on the way down
    cmp eax, '.'
    jne .hatch2
    jmp .in_hole
.hatch2:
    ; (floor_of_height may already say the storey below once you drop in)
    lea edi, [r12d+1]
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, '.'
    jne .zips
    inc r12d
.in_hole:
    lea edi, [r12d-1]
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, 'u'
    jne .zips
    lea edi, [r12d-1]
    mov esi, r13d
    mov edx, r14d
    call ladder_dir
    cmp eax, 0
    jl .zips
    mov ecx, eax
    lea edi, [r12d-1]
    mov esi, r13d
    mov edx, r14d
    cvtsi2ss xmm0, r12d
    mulss xmm0, [c_fh]
    FLD xmm1, 0.15
    subss xmm0, xmm1
    minss xmm0, [p_y]
    call start_climb
    EPILOGUE
.zips:
    ; any cable within reach?
    xor ebx, ebx
.zip:
    cmp ebx, NZIP
    jge .done
    call zip_closest                    ; xmm0 = t, xmm1 = horiz dist, xmm2 = height
    comiss xmm1, [c_grab_r]
    jae .nz
    movss xmm3, [p_y]
    addss xmm3, [c_eye]
    subss xmm2, xmm3
    comiss xmm2, [c_grab_lo]
    jb .nz
    comiss xmm2, [c_grab_hi]
    ja .nz
    mov [zip_cand], ebx
    movss [rsp+0], xmm0
    mov eax, [rsp+0]
    mov [zip_cand_t], eax
    cmp dword [trav_prompt], 0
    jge .nz
    mov dword [trav_prompt], 7
.nz:
    inc ebx
    jmp .zip
.done:
    EPILOGUE

; zip_closest(ebx=cable) -> xmm0 = t along it (0..1), xmm1 = horizontal
; distance from you, xmm2 = cable height there
zip_closest:
    PROLOGUE 16
    movss xmm4, [zip_bx+rbx*4]
    subss xmm4, [zip_ax+rbx*4]          ; d = B - A (x, z)
    movss xmm5, [zip_bz+rbx*4]
    subss xmm5, [zip_az+rbx*4]
    movss xmm0, [p_x]
    subss xmm0, [zip_ax+rbx*4]
    movss xmm1, [p_z]
    subss xmm1, [zip_az+rbx*4]
    mulss xmm0, xmm4
    mulss xmm1, xmm5
    addss xmm0, xmm1                    ; (P-A).d
    movaps xmm6, xmm4
    mulss xmm6, xmm4
    movaps xmm7, xmm5
    mulss xmm7, xmm5
    addss xmm6, xmm7
    divss xmm0, xmm6
    maxss xmm0, [c_zero]
    minss xmm0, [c_one]                 ; t
    ; closest point
    movaps xmm1, xmm4
    mulss xmm1, xmm0
    addss xmm1, [zip_ax+rbx*4]
    subss xmm1, [p_x]
    mulss xmm1, xmm1
    movaps xmm2, xmm5
    mulss xmm2, xmm0
    addss xmm2, [zip_az+rbx*4]
    subss xmm2, [p_z]
    mulss xmm2, xmm2
    addss xmm1, xmm2
    sqrtss xmm1, xmm1
    movss xmm2, [zip_by+rbx*4]
    subss xmm2, [zip_ay+rbx*4]
    mulss xmm2, xmm0
    addss xmm2, [zip_ay+rbx*4]
    EPILOGUE

; traverse_try_grab() -> eax 1 if E grabbed a zipline
traverse_try_grab:
    cmp dword [p_mode], MODE_WALK
    jne .no
    mov eax, [zip_cand]
    cmp eax, 0
    jl .no
    mov [zip_active], eax
    mov eax, [zip_cand_t]
    mov [zip_t], eax
    mov eax, [c_zip_start]
    mov [zip_speed], eax
    mov dword [p_mode], MODE_ZIP
    mov dword [trav_prompt], -1
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; ride(xmm0=dt) -- slide down the cable
ride:
    PROLOGUE 32
    movss [rsp+0], xmm0
    mov ebx, [zip_active]
    ; speed builds up
    PCT xmm3, cfg_zip                   ; custom: zipline speed
    movss xmm1, [c_zip_accel]
    mulss xmm1, xmm3
    mulss xmm1, xmm0
    addss xmm1, [zip_speed]
    movss xmm2, [c_zip_max]
    mulss xmm2, xmm3
    minss xmm1, xmm2
    movss [zip_speed], xmm1
    ; cable length
    movss xmm2, [zip_bx+rbx*4]
    subss xmm2, [zip_ax+rbx*4]
    mulss xmm2, xmm2
    movss xmm3, [zip_bz+rbx*4]
    subss xmm3, [zip_az+rbx*4]
    mulss xmm3, xmm3
    addss xmm2, xmm3
    sqrtss xmm2, xmm2
    mulss xmm1, xmm0
    divss xmm1, xmm2
    addss xmm1, [zip_t]
    movss [zip_t], xmm1
    ; off the end, or Space: let go
    comiss xmm1, [c_one]
    jae .release
    cmp byte [keys_down+6], 0           ; Space
    jne .release
    ; position: hanging under the trolley
    movss xmm0, [zip_bx+rbx*4]
    subss xmm0, [zip_ax+rbx*4]
    mulss xmm0, xmm1
    addss xmm0, [zip_ax+rbx*4]
    movss [p_x], xmm0
    movss xmm0, [zip_bz+rbx*4]
    subss xmm0, [zip_az+rbx*4]
    mulss xmm0, xmm1
    addss xmm0, [zip_az+rbx*4]
    movss [p_z], xmm0
    movss xmm0, [zip_by+rbx*4]
    subss xmm0, [zip_ay+rbx*4]
    mulss xmm0, xmm1
    addss xmm0, [zip_ay+rbx*4]
    subss xmm0, [c_hang]
    movss [p_y], xmm0
    mov dword [p_vy], 0
    ; sway, shake and a wider view with speed
    movss xmm0, [sway_t]
    addss xmm0, [rsp+0]
    movss [sway_t], xmm0
    FLD xmm1, 3.1
    mulss xmm0, xmm1
    call sinf
    FLD xmm1, 0.07
    mulss xmm0, xmm1
    movss [trav_roll], xmm0
    call rand01
    subss xmm0, [c_half]
    movss xmm1, [zip_speed]
    divss xmm1, [c_zip_max]
    mulss xmm0, xmm1
    FLD xmm2, 0.04
    mulss xmm0, xmm2
    movss [trav_shake], xmm0
    movss xmm0, [zip_speed]
    divss xmm0, [c_zip_max]
    mulss xmm0, [c_fov_kick]
    movss [trav_fov], xmm0
    ; the trolley whirrs (quietly -- but it's metal on metal)
    movss xmm0, [whirr_t]
    subss xmm0, [rsp+0]
    movss [whirr_t], xmm0
    comiss xmm0, [c_zero]
    ja .done
    mov eax, [c_whirr_every]
    mov [whirr_t], eax
    movss xmm0, [zip_speed]
    call snd_zip
    movss xmm0, [c_noise_zip]
    call noise_add
    jmp .done
.release:
    mov dword [p_mode], MODE_WALK
    mov dword [p_on_ground], 0
    mov dword [p_vy], 0
    xor eax, eax
    mov [trav_roll], eax
    mov [trav_shake], eax
    mov [trav_fov], eax
    mov dword [zip_active], -1
.done:
    EPILOGUE

; climb(xmm0=dt) -- up and down the ladder
climb:
    PROLOGUE 32
    movss [rsp+0], xmm0
    mov eax, [lad_x]
    mov [p_x], eax
    mov eax, [lad_z]
    mov [p_z], eax
    mov dword [p_vy], 0
    ; W up, S down
    movzx eax, byte [keys_down+0]
    movzx ecx, byte [keys_down+1]
    sub eax, ecx
    cvtsi2ss xmm1, eax
    mulss xmm1, [c_climb_speed]
    mulss xmm1, [rsp+0]
    movss [rsp+4], xmm1
    movss xmm0, [p_y]
    addss xmm0, xmm1
    ; clank on every rung
    movaps xmm2, xmm1
    andps xmm2, [c_abs_mask]
    addss xmm2, [rung_acc]
    movss [rung_acc], xmm2
    movss xmm3, [climb_phase]
    addss xmm3, xmm1
    movss [climb_phase], xmm3
    comiss xmm2, [c_rung]
    jb .no_clank
    mov dword [rung_acc], 0
    movss [rsp+8], xmm0
    call snd_clank
    movss xmm0, [c_noise_rung]
    call noise_add
    movss xmm0, [rsp+8]
.no_clank:
    ; bottom: back on your feet
    comiss xmm0, [lad_base]
    ja .not_bottom
    movss xmm0, [lad_base]
    movss [p_y], xmm0
    cmp byte [keys_down+1], 0
    je .check_jump
    mov dword [p_mode], MODE_WALK
    mov dword [p_on_ground], 1
    jmp .done
.not_bottom:
    ; top: step off onto the floor above
    comiss xmm0, [lad_top]
    jb .mid
    movss xmm0, [lad_top]
    movss [p_y], xmm0
    cmp byte [keys_down+0], 0
    je .check_jump
    movss xmm0, [lad_dx]
    mulss xmm0, [c_dismount]
    addss xmm0, [lad_x]
    movss [p_x], xmm0
    movss xmm0, [lad_dz]
    mulss xmm0, [c_dismount]
    addss xmm0, [lad_z]
    movss [p_z], xmm0
    mov dword [p_mode], MODE_WALK
    mov dword [p_on_ground], 1
    jmp .done
.mid:
    movss [p_y], xmm0
.check_jump:
    ; Space: let go
    cmp byte [keys_down+6], 0
    je .done
    mov dword [p_mode], MODE_WALK
    mov dword [p_on_ground], 0
    ; push off the wall a little
    movss xmm0, [lad_dx]
    FLD xmm1, -0.25
    mulss xmm0, xmm1
    addss xmm0, [p_x]
    movss [p_x], xmm0
    movss xmm0, [lad_dz]
    FLD xmm1, -0.25
    mulss xmm0, xmm1
    addss xmm0, [p_z]
    movss [p_z], xmm0
.done:
    EPILOGUE

; traverse_update(xmm0=dt) -- call before player_update
traverse_update:
    PROLOGUE 16
    movss [rsp+0], xmm0
    mov eax, [p_mode]
    cmp eax, MODE_LADDER
    je .ladder
    cmp eax, MODE_ZIP
    je .zip
    cmp eax, 3                          ; mantling / vaulting (parkour.asm)
    je .parkour
    xor eax, eax
    mov [trav_roll], eax
    mov [trav_shake], eax
    mov [trav_fov], eax
    call walk_checks
    EPILOGUE
.ladder:
    mov dword [trav_prompt], -1
    movss xmm0, [rsp+0]
    call climb
    EPILOGUE
.zip:
    mov dword [trav_prompt], -1
    movss xmm0, [rsp+0]
    call ride
    EPILOGUE
.parkour:
    mov dword [trav_prompt], -1
    movss xmm0, [rsp+0]
    call parkour_update
    EPILOGUE

section .bss
zip_cand_t  resd 1
