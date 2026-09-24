; =============================================================================
; physics.asm -- a small Verlet physics engine ("semi-ragdoll" physics).
;
; Everything physical is a cloud of particles held together by distance
; constraints (Jakobsen, "Advanced Character Physics", 2001):
;
;   * integrate:   p' = p + (p - p_old) * damping + gravity * h^2
;   * constraints: repeatedly nudge each pair back to its rest length
;   * collisions:  particles are pushed out of floors, stairs and walls
;                  using the same grid queries as the player
;
; Bodies built from it:
;   BOX   cardboard boxes -- 8 corners, all 28 pairs constrained (rigid)
;   SIGN  "caution wet floor" signs -- a tall thin box that tips over easily
;   RAG   T's ragdoll: head, neck, pelvis, hands, feet. A deauth packet makes
;         him collapse and twitch here for a few seconds before his
;         connection finally drops and he reappears somewhere far away.
;
; You shove props just by walking into them; when one hits the floor or a
; wall hard it clatters, and that goes on the noise meter. Boxes are also
; something to climb: props_top lets you stand on them (and mantle onto
; them), and you stop shoving a box once you're standing on top of it.
; =============================================================================
%define MODULE_PHYSICS
%include "common.inc"

global physics_reset, physics_spawn_props, physics_update, physics_ragdoll
global phys_np, phys_nb, px, py, pz, body_type, body_p0, body_np, body_active
global rag_active, rag_body, rag_time, add_box, props_top

extern random_node, enemy_deauth, snd_clatter

%define MAX_P    256
%define MAX_C    640
%define MAX_B    24
%define B_BOX    0
%define B_SIGN   1
%define B_RAG    2
%define NPROPS   12
%define ITERS    6
%define SUBSTEPS 2

section .data
c_gravity   dd -19.0
c_damping   dd 0.995
c_friction  dd 0.55                 ; how much ground contact kills sliding
c_push_r    dd 0.5                  ; player's "shove" radius
c_push_r2   dd 0.25
c_body_mid  dd 0.9
c_body_half dd 0.95
c_impact_v  dd 2.6                  ; impact speed that makes a clatter
c_clatter_cool dd 0.6
c_noise_clatter dd 0.3
c_rag_time  dd 2.8
c_twitch_every dd 0.14
c_twitch    dd 0.09
c_push_kick dd 0.12
c_step_up   dd 0.6
c_tiny      dd 0.000001
; prop sizes (half extents): cardboard box, wet-floor sign
box_hx      dd 0.30, 0.26
box_hy      dd 0.25, 0.45
box_hz      dd 0.30, 0.05
; T's ragdoll rest pose (relative to his feet, facing +Z):
;              head  neck  pelvis lhand rhand lfoot rfoot
rag_rx      dd 0.0,  0.0,  0.0,  -0.42, 0.42, -0.18, 0.18
rag_ry      dd 2.02, 1.72, 0.95,  0.45, 0.45,  0.05, 0.05
rag_rz      dd 0.0,  0.0,  0.0,   0.05, 0.05,  0.0,  0.0
; bones (pairs of particle indices within the ragdoll)
rag_bones   dd 0,1, 1,2, 1,3, 1,4, 2,5, 2,6, 0,2, 5,6, 3,2, 4,2
%define NBONES 10

section .bss
bb          resd 5                  ; body_bounds output
px          resd MAX_P
py          resd MAX_P
pz          resd MAX_P
ox          resd MAX_P
oy          resd MAX_P
oz          resd MAX_P
p_hit       resd MAX_P              ; set when the particle hit something hard
con_a       resd MAX_C
con_b       resd MAX_C
con_len     resd MAX_C
phys_np     resd 1
phys_nc     resd 1
phys_nb     resd 1
body_type   resd MAX_B
body_p0     resd MAX_B
body_np     resd MAX_B
body_c0     resd MAX_B
body_nc     resd MAX_B
body_active resd MAX_B
body_cool   resd MAX_B              ; seconds until it may clatter again
rag_active  resd 1
rag_body    resd 1
rag_time    resd 1
twitch_t    resd 1
h_step      resd 1                  ; substep length (seconds)

section .text

physics_reset:
    xor eax, eax
    mov [phys_np], eax
    mov [phys_nc], eax
    mov [phys_nb], eax
    mov [rag_active], eax
    mov dword [rag_body], -1
    ret

; add_particle(xmm0=x, xmm1=y, xmm2=z) -> eax index (at rest). leaf
add_particle:
    mov eax, [phys_np]
    movss [px+rax*4], xmm0
    movss [py+rax*4], xmm1
    movss [pz+rax*4], xmm2
    movss [ox+rax*4], xmm0
    movss [oy+rax*4], xmm1
    movss [oz+rax*4], xmm2
    inc dword [phys_np]
    ret

; add_constraint(edi=a, esi=b) -- rest length = current distance. leaf
add_constraint:
    mov eax, [phys_nc]
    mov [con_a+rax*4], edi
    mov [con_b+rax*4], esi
    movss xmm0, [px+rdi*4]
    subss xmm0, [px+rsi*4]
    mulss xmm0, xmm0
    movss xmm1, [py+rdi*4]
    subss xmm1, [py+rsi*4]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [pz+rdi*4]
    subss xmm1, [pz+rsi*4]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    movss [con_len+rax*4], xmm0
    inc dword [phys_nc]
    ret

; new_body(edi=type) -> eax body index; opens a body at the current counts
new_body:
    mov eax, [phys_nb]
    mov [body_type+rax*4], edi
    mov ecx, [phys_np]
    mov [body_p0+rax*4], ecx
    mov ecx, [phys_nc]
    mov [body_c0+rax*4], ecx
    mov dword [body_active+rax*4], 1
    mov dword [body_cool+rax*4], 0
    inc dword [phys_nb]
    ret

; close_body(edi=body) -- record how many particles/constraints it got
close_body:
    mov eax, [phys_np]
    sub eax, [body_p0+rdi*4]
    mov [body_np+rdi*4], eax
    mov eax, [phys_nc]
    sub eax, [body_c0+rdi*4]
    mov [body_nc+rdi*4], eax
    ret

; add_box(edi=type B_BOX/B_SIGN, xmm0=x, xmm1=floor y, xmm2=z, xmm3=yaw)
; 8 corners (index bit0 = +x, bit1 = +y, bit2 = +z, like render.asm's
; face table) and all 28 pairs constrained, so it stays a rigid box.
add_box:
    PROLOGUE 64
    mov r15d, edi
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movaps xmm0, xmm3
    movss [rsp+12], xmm3
    call cosf
    movss [rsp+16], xmm0
    movss xmm0, [rsp+12]
    call sinf
    movss [rsp+20], xmm0
    mov edi, r15d
    call new_body
    mov r14d, eax                       ; body
    xor ebx, ebx                        ; corner code
.corner:
    cmp ebx, 8
    jge .corners_done
    ; local corner (+/-hx, 0 or 2hy, +/-hz)
    movss xmm0, [box_hx+r15*4]
    test ebx, 1
    jnz .x1
    xorps xmm0, [c_sign_mask]
.x1:
    xorps xmm1, xmm1
    test ebx, 2
    jz .y0
    movss xmm1, [box_hy+r15*4]
    addss xmm1, xmm1
.y0:
    movss xmm2, [box_hz+r15*4]
    test ebx, 4
    jnz .z1
    xorps xmm2, [c_sign_mask]
.z1:
    ; rotate (x,z) by yaw
    movaps xmm3, xmm0
    mulss xmm3, [rsp+16]
    movaps xmm4, xmm2
    mulss xmm4, [rsp+20]
    addss xmm3, xmm4                    ; x' = x c + z s
    movaps xmm4, xmm2
    mulss xmm4, [rsp+16]
    movaps xmm5, xmm0
    mulss xmm5, [rsp+20]
    subss xmm4, xmm5                    ; z' = z c - x s
    movaps xmm0, xmm3
    addss xmm0, [rsp+0]
    addss xmm1, [rsp+4]
    FLD xmm5, 0.02
    addss xmm1, xmm5                    ; start just above the floor
    movaps xmm2, xmm4
    addss xmm2, [rsp+8]
    call add_particle
    inc ebx
    jmp .corner
.corners_done:
    mov r12d, [body_p0+r14*4]
    xor ebx, ebx
.ci:
    cmp ebx, 8
    jge .done
    lea r13d, [rbx+1]
.cj:
    cmp r13d, 8
    jge .cin
    lea edi, [r12+rbx]
    lea esi, [r12+r13]
    call add_constraint
    inc r13d
    jmp .cj
.cin:
    inc ebx
    jmp .ci
.done:
    mov edi, r14d
    call close_body
    EPILOGUE

; physics_spawn_props -- cardboard boxes and wet-floor signs in random
; hallways (seeded, like the items)
physics_spawn_props:
    PROLOGUE 32
    mov ebx, NPROPS
.prop:
    mov edi, -1
    xor esi, esi
    call random_node
    mov edi, eax
    call node_center                    ; xmm0 x, xmm1 y, xmm2 z
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    call rand01
    mulss xmm0, [c_two_pi]
    movss [rsp+12], xmm0                ; yaw
    call rand01
    mov edi, B_BOX
    FLD xmm1, 0.35
    comiss xmm0, xmm1
    jae .kind
    mov edi, B_SIGN
.kind:
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+8]
    movss xmm3, [rsp+12]
    call add_box
    dec ebx
    jnz .prop
    EPILOGUE

; physics_ragdoll(xmm0=x, xmm1=y, xmm2=z, xmm3=push x, xmm4=push z, xmm5=yaw)
; T collapses here. The push is the direction away from the player.
physics_ragdoll:
    PROLOGUE 64
    cmp dword [rag_active], 0
    jne .done
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    movss [rsp+16], xmm4
    movaps xmm0, xmm5
    movss [rsp+20], xmm5
    call cosf
    movss [rsp+24], xmm0
    movss xmm0, [rsp+20]
    call sinf
    movss [rsp+28], xmm0
    mov edi, B_RAG
    call new_body
    mov r14d, eax
    mov [rag_body], eax
    xor ebx, ebx
.part:
    cmp ebx, 7
    jge .parts_done
    movss xmm0, [rag_rx+rbx*4]
    movss xmm2, [rag_rz+rbx*4]
    movaps xmm3, xmm0
    mulss xmm3, [rsp+24]
    movaps xmm4, xmm2
    mulss xmm4, [rsp+28]
    addss xmm3, xmm4
    movaps xmm4, xmm2
    mulss xmm4, [rsp+24]
    movaps xmm5, xmm0
    mulss xmm5, [rsp+28]
    subss xmm4, xmm5
    movaps xmm0, xmm3
    addss xmm0, [rsp+0]
    movss xmm1, [rag_ry+rbx*4]
    addss xmm1, [rsp+4]
    movaps xmm2, xmm4
    addss xmm2, [rsp+8]
    call add_particle
    ; knock the upper body back: move the "old" position against the push
    cmp ebx, 2
    jg .no_kick
    mov ecx, eax
    cvtsi2ss xmm6, ebx
    FLD xmm7, 0.5
    mulss xmm6, xmm7
    movss xmm7, [c_one]
    subss xmm7, xmm6                    ; head 1.0, neck 0.5, pelvis 0.0
    mulss xmm7, [c_push_kick]
    movss xmm0, [rsp+12]
    mulss xmm0, xmm7
    movss xmm1, [ox+rcx*4]
    subss xmm1, xmm0
    movss [ox+rcx*4], xmm1
    movss xmm0, [rsp+16]
    mulss xmm0, xmm7
    movss xmm1, [oz+rcx*4]
    subss xmm1, xmm0
    movss [oz+rcx*4], xmm1
.no_kick:
    inc ebx
    jmp .part
.parts_done:
    mov r12d, [body_p0+r14*4]
    xor ebx, ebx
.bone:
    cmp ebx, NBONES
    jge .bones_done
    mov edi, [rag_bones+rbx*8]
    add edi, r12d
    mov esi, [rag_bones+rbx*8+4]
    add esi, r12d
    call add_constraint
    inc ebx
    jmp .bone
.bones_done:
    mov edi, r14d
    call close_body
    mov dword [rag_active], 1
    mov eax, [c_rag_time]
    mov [rag_time], eax
    mov dword [twitch_t], 0
.done:
    EPILOGUE

; end_ragdoll -- the connection finally drops: T vanishes and reappears far
; away (enemy_deauth), and the ragdoll's particles are released
end_ragdoll:
    PROLOGUE 16
    mov dword [rag_active], 0
    mov ebx, [rag_body]
    mov dword [body_active+rbx*4], 0
    ; it was the last body added, so its particles can be handed back
    lea eax, [rbx+1]
    cmp eax, [phys_nb]
    jne .keep
    mov [phys_nb], ebx
    mov eax, [body_p0+rbx*4]
    mov [phys_np], eax
    mov eax, [body_c0+rbx*4]
    mov [phys_nc], eax
.keep:
    mov dword [rag_body], -1
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

; ---- the simulation ----------------------------------------------------------

; integrate(xmm0=h) -- Verlet step for every particle of an active body
integrate:
    PROLOGUE 32
    movss xmm7, xmm0
    mulss xmm7, xmm0
    mulss xmm7, [c_gravity]             ; g h^2
    movss [rsp+0], xmm7
    xor r12d, r12d                      ; body
.body:
    cmp r12d, [phys_nb]
    jge .done
    cmp dword [body_active+r12*4], 0
    je .nb
    mov ebx, [body_p0+r12*4]
    mov r13d, ebx
    add r13d, [body_np+r12*4]
.p:
    cmp ebx, r13d
    jge .nb
    mov dword [p_hit+rbx*4], 0
    ; x
    movss xmm0, [px+rbx*4]
    movaps xmm1, xmm0
    subss xmm1, [ox+rbx*4]
    mulss xmm1, [c_damping]
    movss [ox+rbx*4], xmm0
    addss xmm0, xmm1
    movss [px+rbx*4], xmm0
    ; y (+ gravity)
    movss xmm0, [py+rbx*4]
    movaps xmm1, xmm0
    subss xmm1, [oy+rbx*4]
    mulss xmm1, [c_damping]
    movss [oy+rbx*4], xmm0
    addss xmm0, xmm1
    addss xmm0, [rsp+0]
    movss [py+rbx*4], xmm0
    ; z
    movss xmm0, [pz+rbx*4]
    movaps xmm1, xmm0
    subss xmm1, [oz+rbx*4]
    mulss xmm1, [c_damping]
    movss [oz+rbx*4], xmm0
    addss xmm0, xmm1
    movss [pz+rbx*4], xmm0
    inc ebx
    jmp .p
.nb:
    inc r12d
    jmp .body
.done:
    EPILOGUE

; relax -- one pass over every constraint of every active body. leaf-ish
relax:
    PROLOGUE 16
    xor r12d, r12d
.body:
    cmp r12d, [phys_nb]
    jge .done
    cmp dword [body_active+r12*4], 0
    je .nb
    mov ebx, [body_c0+r12*4]
    mov r13d, ebx
    add r13d, [body_nc+r12*4]
.c:
    cmp ebx, r13d
    jge .nb
    mov eax, [con_a+rbx*4]
    mov ecx, [con_b+rbx*4]
    movss xmm0, [px+rcx*4]
    subss xmm0, [px+rax*4]              ; d = b - a
    movss xmm1, [py+rcx*4]
    subss xmm1, [py+rax*4]
    movss xmm2, [pz+rcx*4]
    subss xmm2, [pz+rax*4]
    movaps xmm3, xmm0
    mulss xmm3, xmm0
    movaps xmm4, xmm1
    mulss xmm4, xmm1
    addss xmm3, xmm4
    movaps xmm4, xmm2
    mulss xmm4, xmm2
    addss xmm3, xmm4
    sqrtss xmm3, xmm3                   ; |d|
    maxss xmm3, [c_tiny]
    ; each end moves half of (|d| - rest) along d
    movss xmm4, xmm3
    subss xmm4, [con_len+rbx*4]
    divss xmm4, xmm3
    mulss xmm4, [c_half]
    mulss xmm0, xmm4
    mulss xmm1, xmm4
    mulss xmm2, xmm4
    movss xmm5, [px+rax*4]
    addss xmm5, xmm0
    movss [px+rax*4], xmm5
    movss xmm5, [py+rax*4]
    addss xmm5, xmm1
    movss [py+rax*4], xmm5
    movss xmm5, [pz+rax*4]
    addss xmm5, xmm2
    movss [pz+rax*4], xmm5
    movss xmm5, [px+rcx*4]
    subss xmm5, xmm0
    movss [px+rcx*4], xmm5
    movss xmm5, [py+rcx*4]
    subss xmm5, xmm1
    movss [py+rcx*4], xmm5
    movss xmm5, [pz+rcx*4]
    subss xmm5, xmm2
    movss [pz+rcx*4], xmm5
    inc ebx
    jmp .c
.nb:
    inc r12d
    jmp .body
.done:
    EPILOGUE

; body_bounds(edi = body) -> bb = x0, x1, z0, z1, top (of its particles)
body_bounds:
    mov eax, [body_p0+rdi*4]
    mov ecx, eax
    add ecx, [body_np+rdi*4]
    movss xmm0, [px+rax*4]
    movaps xmm1, xmm0
    movss xmm2, [pz+rax*4]
    movaps xmm3, xmm2
    movss xmm4, [py+rax*4]
.p:
    inc eax
    cmp eax, ecx
    jge .done
    minss xmm0, [px+rax*4]
    maxss xmm1, [px+rax*4]
    minss xmm2, [pz+rax*4]
    maxss xmm3, [pz+rax*4]
    maxss xmm4, [py+rax*4]
    jmp .p
.done:
    movss [bb+0], xmm0
    movss [bb+4], xmm1
    movss [bb+8], xmm2
    movss [bb+12], xmm3
    movss [bb+16], xmm4
    ret

; props_top(xmm0=x, xmm1=z, xmm2=limit) -> xmm0 = the top of the highest box
; under that point that isn't above the limit, or -1e30. (A box's footprint
; is its particles' bounding rectangle pulled in a little, so a tipped box is
; a slightly smaller step.)
props_top:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    mov eax, [c_neg_big]
    mov [rsp+12], eax
    xor ebx, ebx
.b:
    cmp ebx, [phys_nb]
    jge .done
    cmp dword [body_active+rbx*4], 0
    je .n
    cmp dword [body_type+rbx*4], B_BOX
    jne .n
    mov edi, ebx
    call body_bounds
    FLD xmm5, 0.06
    movss xmm0, [rsp+0]
    movss xmm1, [bb+0]
    addss xmm1, xmm5
    comiss xmm0, xmm1
    jb .n
    movss xmm1, [bb+4]
    subss xmm1, xmm5
    comiss xmm0, xmm1
    ja .n
    movss xmm0, [rsp+4]
    movss xmm1, [bb+8]
    addss xmm1, xmm5
    comiss xmm0, xmm1
    jb .n
    movss xmm1, [bb+12]
    subss xmm1, xmm5
    comiss xmm0, xmm1
    ja .n
    movss xmm0, [bb+16]
    comiss xmm0, [rsp+8]
    ja .n
    maxss xmm0, [rsp+12]
    movss [rsp+12], xmm0
.n:
    inc ebx
    jmp .b
.done:
    movss xmm0, [rsp+12]
    EPILOGUE

; blocked(xmm0=x, xmm1=y, xmm2=z) -> eax 1 if that point is inside a wall
blocked:
    PROLOGUE 16
    movss [rsp+0], xmm0
    movss [rsp+4], xmm2
    movaps xmm0, xmm1
    FLD xmm3, 0.05
    addss xmm0, xmm3
    call floor_of_height
    mov edi, eax
    movss xmm0, [rsp+0]
    mulss xmm0, [c_inv_cell]
    cvttss2si esi, xmm0
    movss xmm0, [rsp+4]
    mulss xmm0, [c_inv_cell]
    cvttss2si edx, xmm0
    call cell_at
    xor ecx, ecx
    test byte [char_class+rax], CF_OPEN
    sete cl
    mov eax, ecx
    EPILOGUE

; collide -- floors/stairs, walls and the player, for every live particle
collide:
    PROLOGUE 32
    xor r12d, r12d
.body:
    cmp r12d, [phys_nb]
    jge .done
    cmp dword [body_active+r12*4], 0
    je .nb
    ; standing on this box? then you don't push it around
    mov dword [rsp+0], 0
    cmp dword [body_type+r12*4], B_BOX
    jne .not_stood
    mov edi, r12d
    call body_bounds
    movss xmm0, [p_x]
    comiss xmm0, [bb+0]
    jb .not_stood
    comiss xmm0, [bb+4]
    ja .not_stood
    movss xmm0, [p_z]
    comiss xmm0, [bb+8]
    jb .not_stood
    comiss xmm0, [bb+12]
    ja .not_stood
    movss xmm0, [bb+16]
    FLD xmm1, 0.15
    subss xmm0, xmm1
    comiss xmm0, [p_y]
    ja .not_stood
    mov dword [rsp+0], 1
.not_stood:
    mov ebx, [body_p0+r12*4]
    mov r13d, ebx
    add r13d, [body_np+r12*4]
.p:
    cmp ebx, r13d
    jge .nb
    ; -- walls: undo the move along whichever axis went into one
    movss xmm0, [px+rbx*4]
    movss xmm1, [py+rbx*4]
    movss xmm2, [pz+rbx*4]
    call blocked
    test eax, eax
    jz .floor
    ; horizontal speed before the hit, for the clatter test
    movss xmm0, [px+rbx*4]
    subss xmm0, [ox+rbx*4]
    andps xmm0, [c_abs_mask]
    movss xmm1, [pz+rbx*4]
    subss xmm1, [oz+rbx*4]
    andps xmm1, [c_abs_mask]
    maxss xmm0, xmm1
    divss xmm0, [h_step]
    comiss xmm0, [c_impact_v]
    jb .w1
    mov dword [p_hit+rbx*4], 1
.w1:
    movss xmm0, [ox+rbx*4]
    movss xmm1, [py+rbx*4]
    movss xmm2, [pz+rbx*4]
    call blocked
    test eax, eax
    jnz .w2
    mov eax, [ox+rbx*4]                 ; x was the problem
    mov [px+rbx*4], eax
    jmp .floor
.w2:
    movss xmm0, [px+rbx*4]
    movss xmm1, [py+rbx*4]
    movss xmm2, [oz+rbx*4]
    call blocked
    test eax, eax
    jnz .w3
    mov eax, [oz+rbx*4]                 ; z was the problem
    mov [pz+rbx*4], eax
    jmp .floor
.w3:
    mov eax, [ox+rbx*4]
    mov [px+rbx*4], eax
    mov eax, [oz+rbx*4]
    mov [pz+rbx*4], eax
.floor:
    ; -- floors and stair ramps
    movss xmm0, [px+rbx*4]
    movss xmm1, [pz+rbx*4]
    movss xmm2, [oy+rbx*4]
    movss xmm3, [c_step_up]
    call ground_height
    movss xmm1, [py+rbx*4]
    comiss xmm1, xmm0
    jae .player
    ; landed: how hard?
    movss xmm2, [oy+rbx*4]
    subss xmm2, xmm1
    divss xmm2, [h_step]
    comiss xmm2, [c_impact_v]
    jb .soft
    mov dword [p_hit+rbx*4], 1
.soft:
    movss [py+rbx*4], xmm0
    ; friction: ground contact bleeds off sideways motion
    movss xmm0, [px+rbx*4]
    subss xmm0, [ox+rbx*4]
    mulss xmm0, [c_friction]
    addss xmm0, [ox+rbx*4]
    movss [ox+rbx*4], xmm0
    movss xmm0, [pz+rbx*4]
    subss xmm0, [oz+rbx*4]
    mulss xmm0, [c_friction]
    addss xmm0, [oz+rbx*4]
    movss [oz+rbx*4], xmm0
.player:
    ; -- the player shoves anything inside his radius (props only)
    cmp dword [body_type+r12*4], B_RAG
    je .np
    cmp dword [rsp+0], 0
    jne .np
    movss xmm0, [py+rbx*4]
    subss xmm0, [p_y]
    subss xmm0, [c_body_mid]
    andps xmm0, [c_abs_mask]
    comiss xmm0, [c_body_half]
    jae .np
    movss xmm0, [px+rbx*4]
    subss xmm0, [p_x]
    movss xmm1, [pz+rbx*4]
    subss xmm1, [p_z]
    movaps xmm2, xmm0
    mulss xmm2, xmm0
    movaps xmm3, xmm1
    mulss xmm3, xmm1
    addss xmm2, xmm3
    comiss xmm2, [c_push_r2]
    jae .np
    comiss xmm2, [c_tiny]
    jbe .np
    sqrtss xmm2, xmm2
    movss xmm3, [c_push_r]
    subss xmm3, xmm2
    divss xmm3, xmm2
    mulss xmm0, xmm3
    mulss xmm1, xmm3
    addss xmm0, [px+rbx*4]
    movss [px+rbx*4], xmm0
    addss xmm1, [pz+rbx*4]
    movss [pz+rbx*4], xmm1
.np:
    inc ebx
    jmp .p
.nb:
    inc r12d
    jmp .body
.done:
    EPILOGUE

; clatter_check(xmm0=dt) -- a prop that hit something hard makes a noise
clatter_check:
    PROLOGUE 16
    movss [rsp+0], xmm0
    xor r12d, r12d
.body:
    cmp r12d, [phys_nb]
    jge .done
    cmp dword [body_active+r12*4], 0
    je .nb
    movss xmm0, [body_cool+r12*4]
    subss xmm0, [rsp+0]
    maxss xmm0, [c_zero]
    movss [body_cool+r12*4], xmm0
    cmp dword [body_type+r12*4], B_RAG
    je .nb
    comiss xmm0, [c_zero]
    ja .nb
    mov ebx, [body_p0+r12*4]
    mov r13d, ebx
    add r13d, [body_np+r12*4]
.p:
    cmp ebx, r13d
    jge .nb
    cmp dword [p_hit+rbx*4], 0
    jne .hit
    inc ebx
    jmp .p
.hit:
    mov eax, [c_clatter_cool]
    mov [body_cool+r12*4], eax
    mov edi, [body_type+r12*4]
    call snd_clatter
    movss xmm0, [c_noise_clatter]
    call noise_add
.nb:
    inc r12d
    jmp .body
.done:
    EPILOGUE

; twitch -- while T lies there, his limbs jerk (the deauth glitching him)
twitch:
    PROLOGUE 16
    call rng_next
    xor edx, edx
    mov ecx, 7
    div ecx                             ; edx = which of the 7 parts
    mov ebx, [rag_body]
    add edx, [body_p0+rbx*4]
    mov ebx, edx                        ; particle
    call rand01
    subss xmm0, [c_half]
    mulss xmm0, [c_twitch]
    movss xmm1, [ox+rbx*4]
    subss xmm1, xmm0
    movss [ox+rbx*4], xmm1
    call rand01
    mulss xmm0, [c_twitch]
    movss xmm1, [oy+rbx*4]
    subss xmm1, xmm0                    ; mostly upward jerks
    movss [oy+rbx*4], xmm1
    call rand01
    subss xmm0, [c_half]
    mulss xmm0, [c_twitch]
    movss xmm1, [oz+rbx*4]
    subss xmm1, xmm0
    movss [oz+rbx*4], xmm1
    EPILOGUE

; physics_update(xmm0=dt)
physics_update:
    PROLOGUE 16
    movss [rsp+0], xmm0
    comiss xmm0, [c_zero]
    jbe .done
    mov eax, SUBSTEPS
    cvtsi2ss xmm1, eax
    divss xmm0, xmm1
    movss [h_step], xmm0
    mov r14d, SUBSTEPS
.sub:
    movss xmm0, [h_step]
    call integrate
    mov r15d, ITERS
.iter:
    call relax
    dec r15d
    jnz .iter
    call collide
    dec r14d
    jnz .sub
    movss xmm0, [rsp+0]
    call clatter_check
    ; T's ragdoll: twitch, then vanish
    cmp dword [rag_active], 0
    je .done
    movss xmm0, [twitch_t]
    subss xmm0, [rsp+0]
    movss [twitch_t], xmm0
    comiss xmm0, [c_zero]
    ja .no_twitch
    mov eax, [c_twitch_every]
    mov [twitch_t], eax
    call twitch
.no_twitch:
    movss xmm0, [rag_time]
    subss xmm0, [rsp+0]
    movss [rag_time], xmm0
    comiss xmm0, [c_zero]
    ja .done
    call end_ragdoll
.done:
    EPILOGUE
