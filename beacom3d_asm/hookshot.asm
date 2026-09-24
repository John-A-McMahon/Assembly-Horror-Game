; =============================================================================
; hookshot.asm -- a Zelda-style hookshot: fire it at almost anything solid,
; it latches on and yanks you there.
;
;   fire     the hook flies out along your view (45 m/s, up to 20 m) and
;            bites into the first solid thing: a wall, a pillar, a ceiling,
;            the underside of a balcony, a desk, a crate
;   pull     you're hauled towards it at 15 m/s (p_mode MODE_HOOK). Arrive
;            under a ledge and you mantle straight onto it (parkour.asm), so
;            you can grapple up to the next floor.
;   fling    SPACE mid-pull lets go and keeps the momentum: jump gaps,
;            launch yourself across the atrium (player.asm carries p_mom_x/z)
;   T        a hook that hits T stuns him for a moment -- loudly.
;   miss     nothing solid in range: the hook reels back in.
; T can't follow you anywhere a hookshot takes you.
; =============================================================================
%define MODULE_HOOK
%include "common.inc"

global hookshot_fire, hookshot_update, hookshot_reset
global hk_state, hk_hx, hk_hy, hk_hz, hk_px, hk_py, hk_pz

extern p_mode, p_vy, p_on_ground, p_mom_x, p_mom_z, parkour_try
extern plat_inside, plat_height, t_stun, snd_hook_fire, snd_hook_hit, snd_hook_miss
extern hud_message, slab_cross, build_hit_point, build_break, enemy_hear
extern nm_hook_hear, nemesis_note

%define MODE_WALK 0
%define MODE_HOOK 4
%define HK_IDLE    0
%define HK_FLYING  1
%define HK_PULLING 2
%define HK_RETRACT 3

section .data
c_range     dd 20.0
c_step      dd 0.1                      ; how finely the throw is traced
c_fly       dd 45.0                     ; hook speed out...
c_reel      dd 60.0                     ; ...and back
c_pull      dd 15.0                     ; you, being hauled in
c_arrive    dd 0.3
c_stand_off dd 0.5                      ; stop this far short of the hook
c_eye       dd 1.55
c_radius    dd 0.3
c_body      dd 1.7
c_fling     dd 0.65                     ; share of the pull speed you keep
c_hop       dd 3.5
c_stun      dd 1.6                      ; T, hit by the hook
c_t_r2      dd 0.36                     ; (0.6 m)^2 round T's middle
c_t_h       dd 2.0
c_noise_fire dd 0.08
c_noise_hit  dd 0.16                    ; the clank carries
c_noise_t    dd 0.3
c_spider    dd 2.5                      ; pulled this far up: SPIDER-BEACOM
m_hook_t    db "The hookshot clangs off T -- he staggers!",0

section .bss
alignb 4
hk_state    resd 1
hk_hx       resd 1                      ; where the hook head is now
hk_hy       resd 1
hk_hz       resd 1
hk_px       resd 1                      ; where it's going / latched
hk_py       resd 1
hk_pz       resd 1
hk_dx       resd 1                      ; the throw direction
hk_dy       resd 1
hk_dz       resd 1
hk_len      resd 1                      ; how far the head is out along it
hk_target   resd 1                      ; how far the target is (0 = a miss)
hk_hit_t    resd 1                      ; the hook hit T
hk_from_y   resd 1                      ; your height when the pull began
hk_sx       resd 1                      ; where the throw started (your eye)
hk_sy       resd 1
hk_sz       resd 1

section .text

hookshot_reset:
    mov dword [hk_state], HK_IDLE
    ret

; solid_point(xmm0=x, xmm1=y, xmm2=z, xmm3=previous y) -> eax 1 if a hook
; would bite here: out of the building, a non-walkable cell (walls, pillars,
; racks), a floor/ceiling slab it just crossed, or a platform (desks, crates,
; the grand staircase)
solid_point:
    PROLOGUE 48
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    movss xmm0, [rsp+4]
    divss xmm0, [c_fh]
    roundss xmm0, xmm0, 1
    cvttss2si r12d, xmm0                ; storey
    cmp r12d, 0
    jl .solid
    cmp r12d, NF
    jge .solid
    movss xmm0, [rsp+0]
    mulss xmm0, [c_inv_cell]
    cvttss2si r13d, xmm0
    movss xmm0, [rsp+8]
    mulss xmm0, [c_inv_cell]
    cvttss2si r14d, xmm0
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_at
    test byte [char_class+rax], CF_OPEN
    jz .solid
    ; crossed into another storey? only through an open shaft
    movss xmm0, [rsp+12]
    divss xmm0, [c_fh]
    roundss xmm0, xmm0, 1
    cvttss2si ebx, xmm0
    cmp ebx, r12d
    je .plats
    mov edi, r12d
    cmp ebx, r12d
    cmovg edi, ebx                      ; the slab belongs to the upper storey
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, '.'
    jne .solid
.plats:
    xor ebx, ebx
.p:
    cmp ebx, [plat_count]
    jge .clear
    mov ecx, ebx
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+8]
    xorps xmm2, xmm2
    call plat_inside
    test eax, eax
    jz .pn
    mov ecx, ebx
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+8]
    call plat_height
    movss xmm1, [rsp+4]
    comiss xmm1, xmm0
    ja .pn                              ; above its top
    subss xmm0, [plat_thick+rbx*4]
    comiss xmm1, xmm0
    jae .solid                          ; inside the slab
.pn:
    inc ebx
    jmp .p
.clear:
    xor eax, eax
    EPILOGUE
.solid:
    mov eax, 1
    EPILOGUE

; hookshot_fire -- throw it along your view (if it's not already out)
hookshot_fire:
    PROLOGUE 64
    cmp dword [hk_state], HK_IDLE
    jne .done
    cmp dword [p_mode], MODE_WALK
    jne .done
    ; direction = view forward
    movss xmm0, [p_pitch]
    call cosf
    movss [rsp+0], xmm0
    movss xmm0, [p_pitch]
    call sinf
    movss [hk_dy], xmm0
    movss xmm0, [p_yaw]
    call sinf
    mulss xmm0, [rsp+0]
    xorps xmm0, [c_sign_mask]
    movss [hk_dx], xmm0
    movss xmm0, [p_yaw]
    call cosf
    mulss xmm0, [rsp+0]
    xorps xmm0, [c_sign_mask]
    movss [hk_dz], xmm0
    mov eax, [p_x]
    mov [hk_sx], eax
    mov eax, [p_eye_y]
    mov [hk_sy], eax
    mov eax, [p_z]
    mov [hk_sz], eax
    ; trace it: the last free point before something solid
    mov dword [hk_target], 0
    mov dword [hk_hit_t], 0
    xorps xmm0, xmm0
    movss [rsp+4], xmm0                 ; distance
.trace:
    movss xmm0, [rsp+4]
    addss xmm0, [c_step]
    comiss xmm0, [c_range]
    ja .traced
    movss [rsp+4], xmm0
    ; the point, and the height a step back
    movss xmm1, [hk_dx]
    mulss xmm1, xmm0
    addss xmm1, [hk_sx]
    movss [rsp+8], xmm1
    movss xmm1, [hk_dy]
    mulss xmm1, xmm0
    addss xmm1, [hk_sy]
    movss [rsp+12], xmm1
    movss xmm1, [hk_dz]
    mulss xmm1, xmm0
    addss xmm1, [hk_sz]
    movss [rsp+16], xmm1
    ; T in the way?
    call hits_t
    test eax, eax
    jnz .got_t
    ; T's stairs? hook them and yank them down
    movss xmm0, [rsp+8]
    movss xmm1, [rsp+12]
    movss xmm2, [rsp+16]
    call build_hit_point
    test eax, eax
    jnz .got_stairs
    movss xmm4, [hk_dy]                 ; the height one step back
    mulss xmm4, [c_step]
    movss xmm3, [rsp+12]
    subss xmm3, xmm4
    movss xmm0, [rsp+8]
    movss xmm1, [rsp+12]
    movss xmm2, [rsp+16]
    call solid_point
    test eax, eax
    jz .trace
    ; bitten: latch a step short of the surface
    movss xmm0, [rsp+4]
    subss xmm0, [c_step]
    movss [hk_target], xmm0
    jmp .traced
.got_stairs:
    mov dword [hk_hit_t], 2
    mov eax, [rsp+4]
    mov [hk_target], eax
    jmp .traced
.got_t:
    mov dword [hk_hit_t], 1
    mov eax, [rsp+4]
    mov [hk_target], eax
.traced:
    ; where the head is headed: the target, or the end of the chain
    movss xmm0, [hk_target]
    comiss xmm0, [c_zero]
    ja .aim
    movss xmm0, [c_range]
.aim:
    movss xmm1, [hk_dx]
    mulss xmm1, xmm0
    addss xmm1, [hk_sx]
    movss [hk_px], xmm1
    movss xmm1, [hk_dy]
    mulss xmm1, xmm0
    addss xmm1, [hk_sy]
    movss [hk_py], xmm1
    movss xmm1, [hk_dz]
    mulss xmm1, xmm0
    addss xmm1, [hk_sz]
    movss [hk_pz], xmm1
    mov dword [hk_len], 0
    mov dword [hk_state], HK_FLYING
    movss xmm0, [c_noise_fire]
    call noise_add
    call snd_hook_fire
.done:
    EPILOGUE

; hits_t -- is the traced point ([rsp+8..16] of hookshot_fire's frame, passed
; in xmm via the caller's stack) inside T? Reads hookshot_fire's locals.
hits_t:
    movss xmm0, [rsp+8+8]               ; (return address in between)
    subss xmm0, [t_x]
    mulss xmm0, xmm0
    movss xmm1, [rsp+16+8]
    subss xmm1, [t_z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    xor eax, eax
    comiss xmm0, [c_t_r2]
    jae .no
    movss xmm0, [rsp+12+8]
    subss xmm0, [t_y]
    comiss xmm0, [c_zero]
    jb .no
    comiss xmm0, [c_t_h]
    ja .no
    movss xmm0, [t_stun]                ; (not while he's already down)
    comiss xmm0, [c_zero]
    ja .no
    mov eax, 1
.no:
    ret

; head_at(xmm0 = distance along the throw) -- place the head there. leaf
head_at:
    movss xmm1, [hk_dx]
    mulss xmm1, xmm0
    addss xmm1, [hk_sx]
    movss [hk_hx], xmm1
    movss xmm1, [hk_dy]
    mulss xmm1, xmm0
    addss xmm1, [hk_sy]
    movss [hk_hy], xmm1
    movss xmm1, [hk_dz]
    mulss xmm1, xmm0
    addss xmm1, [hk_sz]
    movss [hk_hz], xmm1
    ret

; hookshot_update(xmm0 = dt)
hookshot_update:
    PROLOGUE 64
    movss [rsp+0], xmm0
    mov eax, [hk_state]
    cmp eax, HK_FLYING
    je .flying
    cmp eax, HK_PULLING
    je .pulling
    cmp eax, HK_RETRACT
    je .retract
    EPILOGUE

.flying:
    movss xmm0, [c_fly]
    mulss xmm0, [rsp+0]
    addss xmm0, [hk_len]
    movss [hk_len], xmm0
    ; how far it's going
    movss xmm1, [hk_target]
    comiss xmm1, [c_zero]
    ja .has_target
    movss xmm1, [c_range]
.has_target:
    comiss xmm0, xmm1
    jb .fly_on
    movaps xmm0, xmm1
    movss [hk_len], xmm0
    call head_at
    cmp dword [hk_hit_t], 2
    je .hit_stairs
    cmp dword [hk_hit_t], 0
    jne .hit_t
    movss xmm0, [hk_target]
    comiss xmm0, [c_zero]
    jbe .miss
    ; it bit: now haul -- and the clank carries: T comes to see (from
    ; further, once he's learned your hookshot)
    movss xmm0, [hk_hx]
    movss xmm1, [hk_dx]
    mulss xmm1, [c_stand_off]
    subss xmm0, xmm1
    movss xmm1, [p_y]
    movss xmm2, [hk_hz]
    movss xmm3, [hk_dz]
    mulss xmm3, [c_stand_off]
    subss xmm2, xmm3
    movss xmm3, [nm_hook_hear]
    call enemy_hear
    xor edi, edi
    call nemesis_note
    mov dword [hk_state], HK_PULLING
    mov dword [p_mode], MODE_HOOK
    mov dword [p_vy], 0
    mov eax, [p_y]
    mov [hk_from_y], eax
    movss xmm0, [c_noise_hit]
    call noise_add
    call snd_hook_hit
    EPILOGUE
.fly_on:
    call head_at
    EPILOGUE
.hit_t:
    ; stagger T, reel the hook back in
    mov eax, [c_stun]
    mov [t_stun], eax
    movss xmm0, [c_noise_t]
    call noise_add
    call snd_hook_hit
    lea rdi, [m_hook_t]
    mov esi, 0xFF47B3FF
    xor edx, edx
    call hud_message
    mov edi, ACH_HOOK_T
    call ach_unlock
    mov dword [hk_state], HK_RETRACT
    EPILOGUE
.hit_stairs:
    call snd_hook_hit
    mov edi, 1
    call build_break
    mov dword [hk_state], HK_RETRACT
    EPILOGUE
.miss:
    call snd_hook_miss
    mov dword [hk_state], HK_RETRACT
    EPILOGUE

.retract:
    movss xmm0, [c_reel]
    mulss xmm0, [rsp+0]
    movss xmm1, [hk_len]
    subss xmm1, xmm0
    movss [hk_len], xmm1
    comiss xmm1, [c_zero]
    ja .reel_on
    mov dword [hk_state], HK_IDLE
    EPILOGUE
.reel_on:
    ; reel towards where you are now
    mov eax, [p_x]
    mov [hk_sx], eax
    mov eax, [p_eye_y]
    mov [hk_sy], eax
    mov eax, [p_z]
    mov [hk_sz], eax
    movaps xmm0, xmm1
    call head_at
    EPILOGUE

.pulling:
    ; SPACE: let go, keep the momentum
    cmp byte [keys_down+6], 0
    jne .fling
    ; the goal for your eye: just short of the hook
    movss xmm0, [hk_hx]
    movss xmm1, [hk_hy]
    movss xmm2, [hk_hz]
    movss xmm3, [c_stand_off]
    movss xmm4, [hk_dx]
    mulss xmm4, xmm3
    subss xmm0, xmm4
    movss xmm4, [hk_dy]
    mulss xmm4, xmm3
    subss xmm1, xmm4
    movss xmm4, [hk_dz]
    mulss xmm4, xmm3
    subss xmm2, xmm4
    subss xmm1, [c_eye]                 ; -> where your feet go
    subss xmm0, [p_x]
    subss xmm1, [p_y]
    subss xmm2, [p_z]
    movss [rsp+4], xmm0
    movss [rsp+8], xmm1
    movss [rsp+12], xmm2
    mulss xmm0, xmm0
    mulss xmm1, xmm1
    mulss xmm2, xmm2
    addss xmm0, xmm1
    addss xmm0, xmm2
    sqrtss xmm0, xmm0
    movss [rsp+16], xmm0                ; how far to go
    comiss xmm0, [c_arrive]
    jb .arrive
    movss xmm1, [c_pull]
    mulss xmm1, [rsp+0]
    minss xmm1, xmm0
    divss xmm1, xmm0                    ; fraction of the way this frame
    movss xmm0, [rsp+4]
    mulss xmm0, xmm1
    addss xmm0, [p_x]
    movss [rsp+20], xmm0
    movss xmm0, [rsp+8]
    mulss xmm0, xmm1
    addss xmm0, [p_y]
    movss [rsp+24], xmm0
    movss xmm0, [rsp+12]
    mulss xmm0, xmm1
    addss xmm0, [p_z]
    movss [rsp+28], xmm0
    ; anything in the way? then you've arrived as far as you'll get
    movss xmm0, [rsp+20]
    movss xmm1, [rsp+28]
    movss xmm2, [rsp+24]
    movss xmm3, [c_radius]
    movss xmm4, [c_body]
    call collides
    test eax, eax
    jnz .arrive
    ; ...or a floor / ceiling between here and there (hooked the floor, or
    ; hauled up at a ceiling): stop at it rather than go through
    movss xmm0, [rsp+20]
    movss xmm1, [rsp+28]
    movss xmm2, [p_y]
    movss xmm3, [rsp+24]
    movss xmm4, [c_radius]
    movss xmm5, [c_body]
    call slab_cross
    test eax, eax
    jnz .arrive
    mov eax, [rsp+20]
    mov [p_x], eax
    mov eax, [rsp+24]
    mov [p_y], eax
    mov eax, [rsp+28]
    mov [p_z], eax
    mov dword [p_vy], 0
    EPILOGUE
.fling:
    ; keep going the way you were being pulled, with a hop
    movss xmm0, [c_pull]
    mulss xmm0, [c_fling]
    movss xmm1, [hk_dx]
    mulss xmm1, xmm0
    movss [p_mom_x], xmm1
    movss xmm1, [hk_dz]
    mulss xmm1, xmm0
    movss [p_mom_z], xmm1
    movss xmm1, [hk_dy]
    mulss xmm1, xmm0
    addss xmm1, [c_hop]
    movss [p_vy], xmm1
    jmp .let_go
.arrive:
    mov dword [p_vy], 0
.let_go:
    mov dword [p_mode], MODE_WALK
    mov dword [p_on_ground], 0
    mov dword [hk_state], HK_RETRACT
    mov eax, [p_x]
    mov [hk_sx], eax
    mov eax, [p_eye_y]
    mov [hk_sy], eax
    mov eax, [p_z]
    mov [hk_sz], eax
    ; hauled well up: SPIDER-BEACOM
    movss xmm0, [p_y]
    subss xmm0, [hk_from_y]
    comiss xmm0, [c_spider]
    jb .low
    mov edi, ACH_SPIDER
    call ach_unlock
.low:
    ; a ledge right in front? pull yourself up onto it
    cmp byte [keys_down+6], 0
    jne .done
    call parkour_try
.done:
    EPILOGUE
