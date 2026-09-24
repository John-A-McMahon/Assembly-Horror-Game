; =============================================================================
; portal.asm -- a Portal-style portal gun.
;
;   Left click fires the blue portal, right click the orange one. Portals
;   stick to walls (one wall face of one grid cell, like a doorway, 1.2m wide
;   and 2m tall, standing on the floor). With both placed, walk into one and
;   you step out of the other: position, height above the floor and facing
;   are carried through the pair's rotation.
;
; Rendering (stencil-buffer portals, one level deep):
;   1. draw portal A's oval into the stencil buffer (depth tested, so only
;      the visible part), then push the depth inside it to the far plane;
;   2. set up a virtual camera = your view moved through A and out of B:
;        view * T(A) * Ry(angle_A + 180 - angle_B) * T(-B)
;      and clip everything behind B's wall with a user clip plane;
;   3. draw the whole scene again (draw_scene) where the stencil says A is.
;   T can't use portals -- they're your escape hatch.
; =============================================================================
%define MODULE_PORTAL
%include "common.inc"

global portal_reset, portal_fire, portal_check_teleport, portal_views, portal_draw_rims
global por_on, por_x, por_y, por_z, por_f, gun_kick, gun_colour

extern draw_scene, use_program, upload_frame_uniforms, bind
extern cam_x, cam_y, cam_z, cur_floor, p_eye_y
extern glStencilFunc, glStencilOp, glStencilMask, glClearStencil, glDepthFunc
extern glDepthRange, glClipPlane, glGetFloatv, glLoadMatrixf, glColorMask
extern snd_portal_open, snd_portal_fizzle, snd_portal_enter, enemy_portal_follow

%macro GLF4 5
    FLD xmm0, %2
    FLD xmm1, %3
    FLD xmm2, %4
    FLD xmm3, %5
    call %1
%endmacro
%ifdef WIN64
extern sv_p_glUseProgram
%else
extern p_glUseProgram
%endif

%define GL_STENCIL_TEST 0x0B90
%define GL_STENCIL_BUFFER_BIT 0x400
%define GL_ALWAYS 0x207
%define GL_EQUAL 0x202
%define GL_LESS 0x201
%define GL_KEEP 0x1E00
%define GL_REPLACE 0x1E01
%define GL_CLIP_PLANE0 0x3000
%define GL_MODELVIEW_MATRIX 0x0BA6

%ifdef WIN64
%macro USE_FIXED 0
    xor edi, edi
    call sv_p_glUseProgram
%endmacro
%else
%macro USE_FIXED 0
    xor edi, edi
    call [p_glUseProgram]
%endmacro
%endif

section .data
c_ray_step  dd 0.04
c_ray_max   dd 60.0
c_half_w    dd 0.6                  ; portal half width
c_half_h    dd 1.0                  ; ...and half height
c_mid_h     dd 1.05                 ; centre above the floor
c_off       dd 0.012                ; just in front of the wall
c_enter_d   dd 0.36                 ; this close to the wall = through you go
c_exit_d    dd 0.55                 ; step out this far in front of the other
c_cool      dd 0.3
c_noise_shot dd 0.2
c_radius    dd 0.32
c_body      dd 1.7
c_step_up   dd 0.7
c_rad2deg_p dd 57.2957795
; colours: blue, orange
por_r       dd 0.25, 1.0
por_g       dd 0.6,  0.55
por_b       dd 1.0,  0.1
m_fizzle    db "The portal fizzles -- it only sticks to walls.",0
m_no_safe   db "The safe room's networking magic scrambles the portal -- no portals in (or into) safe rooms.",0

section .bss
por_on      resd 2
por_f       resd 2
por_x       resd 2                  ; centre of the portal on the wall face
por_y       resd 2
por_z       resd 2
por_nx      resd 2                  ; outward normal (axis aligned)
por_nz      resd 2
por_ang     resd 2                  ; yaw that turns local +Z onto the normal
por_cell    resd 2                  ; wall cell index + face, to stop overlaps
cooldown    resd 1
gun_kick    resd 1                  ; viewmodel recoil timer
gun_colour  resd 1                  ; last portal fired (0 blue / 1 orange)
view_mat    resd 16
save_cam    resd 4
clip_eq     resq 4
ray         resd 8

section .text

portal_reset:
    xor eax, eax
    mov [por_on], eax
    mov [por_on+4], eax
    mov [cooldown], eax
    mov [gun_kick], eax
    ret

; portal_fire(edi=0 blue / 1 orange) -- shoot along your view
portal_fire:
    PROLOGUE 64
    mov r15d, edi
    mov [gun_colour], edi
    mov dword [gun_kick], __float32__(0.25)
    movss xmm0, [c_noise_shot]
    call noise_add
    ; ray origin (eye) and direction (view forward)
    mov eax, [p_x]
    mov [ray+0], eax
    mov eax, [p_eye_y]
    mov [ray+4], eax
    mov eax, [p_z]
    mov [ray+8], eax
    movss xmm0, [p_pitch]
    call cosf
    movss [rsp+0], xmm0
    movss xmm0, [p_pitch]
    call sinf
    mulss xmm0, [c_ray_step]
    movss [ray+16], xmm0                ; dy per step
    movss xmm0, [p_yaw]
    call sinf
    mulss xmm0, [rsp+0]
    xorps xmm0, [c_sign_mask]
    mulss xmm0, [c_ray_step]
    movss [ray+12], xmm0                ; dx
    movss xmm0, [p_yaw]
    call cosf
    mulss xmm0, [rsp+0]
    xorps xmm0, [c_sign_mask]
    mulss xmm0, [c_ray_step]
    movss [ray+20], xmm0                ; dz
    ; starting cell
    call ray_cell                       ; r12 f, r13 x, r14 y
    mov [rsp+4], r12d
    mov [rsp+8], r13d
    mov [rsp+12], r14d
    movss xmm0, [c_ray_max]
    divss xmm0, [c_ray_step]
    cvttss2si ebx, xmm0
.march:
    dec ebx
    js .fail
    movss xmm0, [ray+0]
    addss xmm0, [ray+12]
    movss [ray+0], xmm0
    movss xmm0, [ray+4]
    addss xmm0, [ray+16]
    movss [ray+4], xmm0
    movss xmm0, [ray+8]
    addss xmm0, [ray+20]
    movss [ray+8], xmm0
    call ray_cell
    cmp r12d, 0
    jl .fail
    cmp r12d, NF
    jge .fail
    ; crossed a floor or ceiling? only allowed through an open shaft
    cmp r12d, [rsp+4]
    je .same_storey
    jg .up
    mov edi, [rsp+4]                    ; going down: the cell we left must be open
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, '.'
    jne .fail
    jmp .same_storey
.up:
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, '.'
    jne .fail
.same_storey:
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_at
    movzx ecx, byte [char_class+rax]
    test ecx, CF_WALL
    jnz .hit
    test ecx, CF_OPEN
    jz .fail                            ; desks, racks, pillars: no portals
    mov [rsp+4], r12d
    mov [rsp+8], r13d
    mov [rsp+12], r14d
    jmp .march
.hit:
    ; which face did we come through?
    xor r8d, r8d                        ; nx
    xor r9d, r9d                        ; nz
    mov eax, [rsp+8]
    sub eax, r13d
    jz .z_face
    mov r8d, eax
    jmp .face_ok
.z_face:
    mov eax, [rsp+12]
    sub eax, r14d
    jz .fail
    mov r9d, eax
.face_ok:
    ; the open cell in front must be plain floor on the same storey
    cmp r12d, [rsp+4]
    jne .fail
    mov edi, r12d
    lea esi, [r13d+r8d]
    lea edx, [r14d+r9d]
    call cell_at
    cmp eax, 'S'                        ; a safe room: no escape hatch in there
    je .safe
    test byte [char_class+rax], CF_FLAT
    jz .fail
    ; not on top of the other portal
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_index
    shl eax, 3                          ; 8 face ids per cell (1..5 used)
    mov ecx, r8d
    add ecx, 1
    add eax, ecx                        ; face id: x-faces 0/2 ...
    mov ecx, r9d
    add ecx, 1
    shl ecx, 1
    add eax, ecx
    mov ecx, r15d
    xor ecx, 1
    cmp dword [por_on+rcx*4], 0
    je .place
    cmp [por_cell+rcx*4], eax
    je .fail
.place:
    mov [por_cell+r15*4], eax
    mov [por_f+r15*4], r12d
    cvtsi2ss xmm0, r8d
    movss [por_nx+r15*4], xmm0
    cvtsi2ss xmm1, r9d
    movss [por_nz+r15*4], xmm1
    ; centre: the middle of the wall face, standing on the floor
    cvtsi2ss xmm2, r13d
    addss xmm2, [c_half]
    mulss xmm0, [c_half]
    addss xmm2, xmm0
    mulss xmm2, [c_cell]
    movss [por_x+r15*4], xmm2
    cvtsi2ss xmm2, r14d
    addss xmm2, [c_half]
    movss xmm0, [por_nz+r15*4]
    mulss xmm0, [c_half]
    addss xmm2, xmm0
    mulss xmm2, [c_cell]
    movss [por_z+r15*4], xmm2
    cvtsi2ss xmm2, r12d
    mulss xmm2, [c_fh]
    addss xmm2, [c_mid_h]
    movss [por_y+r15*4], xmm2
    movss xmm0, [por_nx+r15*4]
    movss xmm1, [por_nz+r15*4]
    call atan2f
    movss [por_ang+r15*4], xmm0
    mov dword [por_on+r15*4], 1
    mov edi, r15d
    call snd_portal_open
    EPILOGUE
.fail:
    call snd_portal_fizzle
    EPILOGUE
.safe:
    call snd_portal_fizzle
    lea rdi, [m_no_safe]
    mov esi, 0xFF47B3FF
    xor edx, edx
    call hud_message
    EPILOGUE

; ray_cell -> r12 = storey, r13 = x, r14 = y of the ray point. (uses floor
; division so negative heights give storey -1)
ray_cell:
    sub rsp, 8
    movss xmm0, [ray+4]
    divss xmm0, [c_fh]
    roundss xmm0, xmm0, 1               ; floor
    cvttss2si r12d, xmm0
    movss xmm0, [ray+0]
    mulss xmm0, [c_inv_cell]
    cvttss2si r13d, xmm0
    movss xmm0, [ray+8]
    mulss xmm0, [c_inv_cell]
    cvttss2si r14d, xmm0
    add rsp, 8
    ret

; rot_y(xmm0=x, xmm1=z, xmm2=angle) -> xmm0, xmm1 rotated like a model
; matrix Ry(angle): x' = x cos + z sin, z' = -x sin + z cos
rot_y:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movaps xmm0, xmm2
    call cosf
    movss [rsp+12], xmm0
    movss xmm0, [rsp+8]
    call sinf
    movss [rsp+16], xmm0
    movss xmm0, [rsp+0]
    mulss xmm0, [rsp+12]
    movss xmm2, [rsp+4]
    mulss xmm2, [rsp+16]
    addss xmm0, xmm2
    movss xmm1, [rsp+4]
    mulss xmm1, [rsp+12]
    movss xmm2, [rsp+0]
    mulss xmm2, [rsp+16]
    subss xmm1, xmm2
    EPILOGUE

; portal_check_teleport(xmm0=dt) -- walk into one, come out of the other
portal_check_teleport:
    PROLOGUE 64
    movss xmm1, [cooldown]
    subss xmm1, xmm0
    maxss xmm1, [c_zero]
    movss [cooldown], xmm1
    movss xmm0, [gun_kick]
    FLD xmm2, 0.016
    subss xmm0, xmm2
    maxss xmm0, [c_zero]
    movss [gun_kick], xmm0
    comiss xmm1, [c_zero]
    ja .done
    cmp dword [por_on], 0
    je .done
    cmp dword [por_on+4], 0
    je .done
    cmp dword [p_mode], 0
    jne .done
    xor r12d, r12d                      ; entry portal i
.try:
    cmp r12d, 2
    jge .done
    ; same storey, standing on its floor
    cvtsi2ss xmm0, dword [por_f+r12*4]
    mulss xmm0, [c_fh]
    movss xmm1, [p_y]
    subss xmm1, xmm0
    movss [rsp+40], xmm1                ; height above that floor
    andps xmm1, [c_abs_mask]
    FLD xmm2, 0.6
    comiss xmm1, xmm2
    jae .next
    ; offset from the centre (horizontal)
    movss xmm0, [p_x]
    subss xmm0, [por_x+r12*4]
    movss [rsp+0], xmm0
    movss xmm1, [p_z]
    subss xmm1, [por_z+r12*4]
    movss [rsp+4], xmm1
    ; distance in front of the wall
    mulss xmm0, [por_nx+r12*4]
    mulss xmm1, [por_nz+r12*4]
    addss xmm0, xmm1
    movss [rsp+8], xmm0                 ; d
    comiss xmm0, [c_enter_d]
    jae .next
    comiss xmm0, [c_zero]
    jb .next
    ; sideways offset along the wall: t = (-nz, nx)
    movss xmm0, [rsp+0]
    movss xmm1, [por_nz+r12*4]
    mulss xmm0, xmm1
    xorps xmm0, [c_sign_mask]
    movss xmm1, [rsp+4]
    mulss xmm1, [por_nx+r12*4]
    addss xmm0, xmm1
    andps xmm0, [c_abs_mask]
    FLD xmm1, 0.55
    comiss xmm0, xmm1
    jae .next
    ; through! turn by delta = yaw(n_j) - yaw(-n_i), yaw(v) = atan2(-vx, -vz)
    mov r13d, r12d
    xor r13d, 1                         ; exit portal j
    movss xmm0, [por_nx+r13*4]
    xorps xmm0, [c_sign_mask]
    movss xmm1, [por_nz+r13*4]
    xorps xmm1, [c_sign_mask]
    call atan2f
    movss [rsp+12], xmm0
    movss xmm0, [por_nx+r12*4]
    movss xmm1, [por_nz+r12*4]
    call atan2f                          ; yaw(-n_i) = atan2(n_i.x, n_i.z)
    movss xmm1, [rsp+12]
    subss xmm1, xmm0
    movss [rsp+16], xmm1                ; delta
    ; rotate the offset by delta (yaw rotation: x' = x c + z s, z' = -x s + z c)
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+16]
    call rot_y
    ; o' + n_j*d -> the sideways part on the exit wall; then step out
    movss xmm2, [rsp+8]
    movss xmm3, [c_exit_d]
    addss xmm3, xmm2
    addss xmm3, xmm2                    ; o' has -n_j*d in it: add 2d + exit
    movss xmm4, [por_nx+r13*4]
    mulss xmm4, xmm3
    addss xmm0, xmm4
    addss xmm0, [por_x+r13*4]
    movss xmm4, [por_nz+r13*4]
    mulss xmm4, xmm3
    addss xmm1, xmm4
    addss xmm1, [por_z+r13*4]
    movss [rsp+20], xmm0                ; new x
    movss [rsp+24], xmm1                ; new z
    cvtsi2ss xmm2, dword [por_f+r13*4]
    mulss xmm2, [c_fh]
    addss xmm2, [rsp+40]
    movss [rsp+28], xmm2                ; new feet height
    ; is there room?
    movss xmm3, [c_radius]
    movss xmm4, [c_body]
    call collides
    test eax, eax
    jnz .next
    mov eax, [rsp+20]
    mov [p_x], eax
    mov eax, [rsp+24]
    mov [p_z], eax
    mov eax, [rsp+28]
    mov [p_y], eax
    movss xmm0, [p_yaw]
    addss xmm0, [rsp+16]
    movss [p_yaw], xmm0
    mov eax, [c_cool]
    mov [cooldown], eax
    call snd_portal_enter
    mov edi, ACH_PORTALS
    call ach_unlock
    ; T saw you go (or, having learned, heard): he follows. In front of the
    ; entry (feet on its floor) -> in front of the exit.
    cvtsi2ss xmm1, dword [por_f+r12*4]
    mulss xmm1, [c_fh]
    movss xmm0, [por_nx+r12*4]
    mulss xmm0, [c_exit_d]
    addss xmm0, [por_x+r12*4]
    movss xmm2, [por_nz+r12*4]
    mulss xmm2, [c_exit_d]
    addss xmm2, [por_z+r12*4]
    cvtsi2ss xmm4, dword [por_f+r13*4]
    mulss xmm4, [c_fh]
    movss xmm3, [por_nx+r13*4]
    mulss xmm3, [c_exit_d]
    addss xmm3, [por_x+r13*4]
    movss xmm5, [por_nz+r13*4]
    mulss xmm5, [c_exit_d]
    addss xmm5, [por_z+r13*4]
    call enemy_portal_follow
    jmp .done
.next:
    inc r12d
    jmp .try
.done:
    EPILOGUE

; ---- drawing -------------------------------------------------------------------

; oval_point(ebx=portal, xmm0=angle, xmm1=scale) -> glVertex3f on its ellipse
oval_point:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    call cosf
    mulss xmm0, [c_half_w]
    mulss xmm0, [rsp+4]
    movss [rsp+8], xmm0                 ; along the wall
    movss xmm0, [rsp+0]
    call sinf
    mulss xmm0, [c_half_h]
    mulss xmm0, [rsp+4]
    movss [rsp+12], xmm0                ; up
    ; wall tangent t = (-nz, nx); lift off the wall by c_off
    movss xmm0, [por_nz+rbx*4]
    xorps xmm0, [c_sign_mask]
    mulss xmm0, [rsp+8]
    addss xmm0, [por_x+rbx*4]
    movss xmm3, [por_nx+rbx*4]
    mulss xmm3, [c_off]
    addss xmm0, xmm3
    movss xmm1, [por_y+rbx*4]
    addss xmm1, [rsp+12]
    movss xmm2, [por_nx+rbx*4]
    mulss xmm2, [rsp+8]
    addss xmm2, [por_z+rbx*4]
    movss xmm3, [por_nz+rbx*4]
    mulss xmm3, [c_off]
    addss xmm2, xmm3
    call glVertex3f
    EPILOGUE

; draw_oval(ebx=portal) -- filled ellipse (triangle fan)
draw_oval:
    PROLOGUE 16
    mov edi, GL_TRIANGLE_FAN
    call glBegin
    xor r12d, r12d
.v:
    cmp r12d, 33
    jge .done
    cvtsi2ss xmm0, r12d
    mulss xmm0, [c_two_pi]
    FLD xmm1, 32.0
    divss xmm0, xmm1
    movss xmm1, [c_one]
    call oval_point
    inc r12d
    jmp .v
.done:
    call glEnd
    EPILOGUE

; draw_ring(ebx=portal, xmm0=inner scale, xmm1=outer scale)
draw_ring:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    mov edi, GL_QUADS
    call glBegin
    xor r12d, r12d
.seg:
    cmp r12d, 32
    jge .done
    cvtsi2ss xmm0, r12d
    mulss xmm0, [c_two_pi]
    FLD xmm1, 32.0
    divss xmm0, xmm1
    movss [rsp+8], xmm0
    lea eax, [r12d+1]
    cvtsi2ss xmm0, eax
    mulss xmm0, [c_two_pi]
    FLD xmm1, 32.0
    divss xmm0, xmm1
    movss [rsp+12], xmm0
    movss xmm0, [rsp+8]
    movss xmm1, [rsp+0]
    call oval_point
    movss xmm0, [rsp+12]
    movss xmm1, [rsp+0]
    call oval_point
    movss xmm0, [rsp+12]
    movss xmm1, [rsp+4]
    call oval_point
    movss xmm0, [rsp+8]
    movss xmm1, [rsp+4]
    call oval_point
    inc r12d
    jmp .seg
.done:
    call glEnd
    EPILOGUE

; portal_draw_rims(xmm0=time) -- glowing rims (unlit pass, blending on). A
; portal whose partner isn't placed yet shows a swirling coloured surface.
portal_draw_rims:
    PROLOGUE 32
    movss [rsp+0], xmm0
    mov edi, [white_tex]
    call bind
    xor ebx, ebx
.p:
    cmp ebx, 2
    jge .done
    cmp dword [por_on+rbx*4], 0
    je .n
    mov eax, [por_f+rbx*4]
    sub eax, [cur_floor]
    cmp eax, VIS_FLOORS
    jg .n
    cmp eax, -VIS_FLOORS
    jl .n
    ; partner missing: a filled, pulsing surface
    mov eax, ebx
    xor eax, 1
    cmp dword [por_on+rax*4], 0
    jne .rim
    movss xmm0, [rsp+0]
    FLD xmm1, 4.0
    mulss xmm0, xmm1
    call sinf
    FLD xmm1, 0.15
    mulss xmm0, xmm1
    FLD xmm1, 0.6
    addss xmm0, xmm1
    movaps xmm3, xmm0
    movss xmm0, [por_r+rbx*4]
    movss xmm1, [por_g+rbx*4]
    movss xmm2, [por_b+rbx*4]
    call glColor4f
    call draw_oval
.rim:
    ; bright rim + soft outer glow
    movss xmm0, [por_r+rbx*4]
    movss xmm1, [por_g+rbx*4]
    movss xmm2, [por_b+rbx*4]
    movss xmm3, [c_one]
    call glColor4f
    FLD xmm0, 0.93
    FLD xmm1, 1.05
    call draw_ring
    movss xmm0, [por_r+rbx*4]
    movss xmm1, [por_g+rbx*4]
    movss xmm2, [por_b+rbx*4]
    FLD xmm3, 0.25
    call glColor4f
    FLD xmm0, 1.05
    FLD xmm1, 1.18
    call draw_ring
.n:
    inc ebx
    jmp .p
.done:
    GLF4 glColor4f, 1.0, 1.0, 1.0, 1.0
    EPILOGUE

; portal_views(xmm0=time) -- the scene through each portal (see top)
portal_views:
    PROLOGUE 64
    movss [rsp+0], xmm0
    cmp dword [por_on], 0
    je .done
    cmp dword [por_on+4], 0
    je .done
    ; remember the real camera
    mov eax, [cam_x]
    mov [save_cam+0], eax
    mov eax, [cam_y]
    mov [save_cam+4], eax
    mov eax, [cam_z]
    mov [save_cam+8], eax
    mov eax, [cur_floor]
    mov [save_cam+12], eax
    mov edi, GL_MODELVIEW_MATRIX
    lea rsi, [view_mat]
    call glGetFloatv
    xor edi, edi
    call glClearStencil
    mov edi, GL_STENCIL_BUFFER_BIT
    call glClear
    mov edi, 0xFF
    call glStencilMask
    xor ebx, ebx                        ; entry portal i
.portal:
    cmp ebx, 2
    jge .finish
    ; near your floor and facing you?
    mov eax, [por_f+rbx*4]
    sub eax, [save_cam+12]
    cmp eax, VIS_FLOORS
    jg .next
    cmp eax, -VIS_FLOORS
    jl .next
    movss xmm0, [save_cam+0]
    subss xmm0, [por_x+rbx*4]
    mulss xmm0, [por_nx+rbx*4]
    movss xmm1, [save_cam+8]
    subss xmm1, [por_z+rbx*4]
    mulss xmm1, [por_nz+rbx*4]
    addss xmm0, xmm1
    comiss xmm0, [c_zero]
    jbe .next
    mov r12d, ebx
    xor r12d, 1                         ; exit portal j
    ; 1. mark the visible part of the oval in the stencil buffer
    mov edi, GL_STENCIL_TEST
    call glEnable
    mov edi, GL_ALWAYS
    lea esi, [ebx+1]
    mov edx, 0xFF
    call glStencilFunc
    mov edi, GL_KEEP
    mov esi, GL_KEEP
    mov edx, GL_REPLACE
    call glStencilOp
    xor edi, edi
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call glColorMask
    xor edi, edi
    call glDepthMask
    USE_FIXED
    call draw_oval
    ; 2. push the depth inside it to the far plane
    mov edi, GL_EQUAL
    lea esi, [ebx+1]
    mov edx, 0xFF
    call glStencilFunc
    mov edi, GL_KEEP
    mov esi, GL_KEEP
    mov edx, GL_KEEP
    call glStencilOp
    mov edi, 1
    call glDepthMask
    mov edi, GL_ALWAYS
    call glDepthFunc
    mov rax, __float64__(1.0)
    movq xmm0, rax
    movq xmm1, rax
    call glDepthRange
    call draw_oval
    xorps xmm0, xmm0
    mov rax, __float64__(1.0)
    movq xmm1, rax
    call glDepthRange
    mov edi, GL_LESS
    call glDepthFunc
    mov edi, 1
    mov esi, 1
    mov edx, 1
    mov ecx, 1
    call glColorMask
    ; 3. the virtual camera: view * T(A) * Ry(angA + 180 - angB) * T(-B)
    mov edi, GL_MODELVIEW
    call glMatrixMode
    lea rdi, [view_mat]
    call glLoadMatrixf
    movss xmm0, [por_x+rbx*4]
    movss xmm1, [por_y+rbx*4]
    movss xmm2, [por_z+rbx*4]
    call glTranslatef
    movss xmm0, [por_ang+rbx*4]
    addss xmm0, [c_pi]
    subss xmm0, [por_ang+r12*4]
    movss [rsp+4], xmm0                 ; A->B rotation
    mulss xmm0, [c_rad2deg_p]
    xorps xmm1, xmm1
    movss xmm2, [c_one]
    xorps xmm3, xmm3
    call glRotatef
    movss xmm0, [por_x+r12*4]
    xorps xmm0, [c_sign_mask]
    movss xmm1, [por_y+r12*4]
    xorps xmm1, [c_sign_mask]
    movss xmm2, [por_z+r12*4]
    xorps xmm2, [c_sign_mask]
    call glTranslatef
    ; only what's in front of the exit wall
    movss xmm0, [por_nx+r12*4]
    cvtss2sd xmm0, xmm0
    movsd [clip_eq+0], xmm0
    mov qword [clip_eq+8], 0
    movss xmm1, [por_nz+r12*4]
    cvtss2sd xmm1, xmm1
    movsd [clip_eq+16], xmm1
    movss xmm2, [por_x+r12*4]
    mulss xmm2, [por_nx+r12*4]
    movss xmm3, [por_z+r12*4]
    mulss xmm3, [por_nz+r12*4]
    addss xmm2, xmm3
    xorps xmm2, [c_sign_mask]
    cvtss2sd xmm2, xmm2
    movsd [clip_eq+24], xmm2
    mov edi, GL_CLIP_PLANE0
    lea rsi, [clip_eq]
    call glClipPlane
    mov edi, GL_CLIP_PLANE0
    call glEnable
    ; where that virtual camera is, for fog, highlights and billboards:
    ; cam_v = B + Ry(angB + 180 - angA) (cam - A)
    movss xmm0, [save_cam+0]
    subss xmm0, [por_x+rbx*4]
    movss xmm1, [save_cam+8]
    subss xmm1, [por_z+rbx*4]
    movss xmm2, [por_ang+r12*4]
    addss xmm2, [c_pi]
    subss xmm2, [por_ang+rbx*4]
    call rot_y
    addss xmm0, [por_x+r12*4]
    movss [cam_x], xmm0
    addss xmm1, [por_z+r12*4]
    movss [cam_z], xmm1
    movss xmm0, [save_cam+4]
    subss xmm0, [por_y+rbx*4]
    addss xmm0, [por_y+r12*4]
    movss [cam_y], xmm0
    mov eax, [por_f+r12*4]
    mov [cur_floor], eax
    mov edi, 1
    call use_program
    call upload_frame_uniforms
    xor edi, edi
    call use_program
    call upload_frame_uniforms
    ; 4. draw the world through the stencil
    mov edi, GL_EQUAL
    lea esi, [ebx+1]
    mov edx, 0xFF
    call glStencilFunc
    movss xmm0, [rsp+0]
    call draw_scene
    ; back to the real camera
    mov edi, GL_CLIP_PLANE0
    call glDisable
    mov edi, GL_STENCIL_TEST
    call glDisable
    mov eax, [save_cam+0]
    mov [cam_x], eax
    mov eax, [save_cam+4]
    mov [cam_y], eax
    mov eax, [save_cam+8]
    mov [cam_z], eax
    mov eax, [save_cam+12]
    mov [cur_floor], eax
    mov edi, GL_MODELVIEW
    call glMatrixMode
    lea rdi, [view_mat]
    call glLoadMatrixf
    mov edi, 1
    call use_program
    call upload_frame_uniforms
    xor edi, edi
    call use_program
    call upload_frame_uniforms
.next:
    inc ebx
    jmp .portal
.finish:
    mov edi, GL_STENCIL_TEST
    call glDisable
.done:
    EPILOGUE
