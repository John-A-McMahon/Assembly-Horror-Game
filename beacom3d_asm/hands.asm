; =============================================================================
; hands.asm -- your hands and arms (the view model).
;
; Built from smooth primitives instead of boxes:
;   * tapered tubes (phalanges, thumb, wrist, forearm, sleeve) and
;   * ellipsoids with any three axes (knuckles, palm pads, the ball of the
;     thumb, the back of the hand, fingertips, nails),
; all with smooth per-vertex normals, so the lighting shader shades them like
; any other curved surface. Skin and sleeve use their own procedural textures
; (textures.asm): pores, mottling and creases on the skin, a woven cotton on
; the hoodie. The shader reads texture brightness as a bump map, so the pores
; and the weave catch the light.
;
; One anatomical right hand is modelled, closed in a power grip round an
; object lying along its local Z axis: four fingers whose three phalanges
; really wrap round the object, knuckles that bulge, nails on the fingertips,
; the thumb laid along the object, the palm pads pressing on it, a wrist, a
; forearm, and a ribbed cuff and a folded sleeve. It is compiled once into
; display lists (skin / sleeve / props). The left hand is the same mesh
; mirrored. Poses just orient that grip:
;   right: the flashlight          left: the zipline's handle bar,
;                                        a ladder rung, the portal gun
;
; Lighting: the flashlight shines away from you, so it can't light your own
; hands -- but in real life the beam bouncing off the world does. For this
; last pass the flashlight uniforms are re-aimed: a soft light a metre ahead
; of you shining back at your hands, as bright as the beam allows. With the
; torch off your hands almost vanish into the dark, like they should.
; Local space: metres; camera space: +X right, +Y up, -Z forward.
; =============================================================================
%define MODULE_HANDS
%include "common.inc"

global draw_viewmodel

extern use_program, set_material, bind, set_emit, model_end, cam_x
extern u_model, u_fpos, u_fdir, u_flash, u_son
extern skin_tex, cloth_tex, gun_kick, gun_colour, have_portal, p_bob
extern glPushMatrix, glMultMatrixf, glGenLists, glNewList, glEndList, glCallList

%ifdef WIN64
%macro GL2CALL 1
    call sv_p_%1
%endmacro
extern sv_p_glUseProgram, sv_p_glUniform1f, sv_p_glUniform3f, sv_p_glUniformMatrix4fv
%else
%macro GL2CALL 1
    call [p_%1]
%endmacro
extern p_glUseProgram, p_glUniform1f, p_glUniform3f, p_glUniformMatrix4fv
%endif

%define PT_TUBE 0
%define PT_ELL  1
%define REC     56                  ; part record: type, colour, 12 floats

; display lists
%define L_SKIN  0
%define L_CLOTH 1
%define L_TORCH 2
%define L_BAR   3
%define L_GUN   4
%define L_HOOK  5
%define L_HOOKTIP 6
%define NLISTS  7

%define ELL_LAT 10                  ; (also written as 10.0 in ell_v)
%define ELL_LON 16                  ; (also written as 16.0 in ell_v)

; colours (vertex tint; the skin texture carries the actual skin tone)
%define SK   0xEDE2DC               ; skin
%define KN   0xF3D6CC               ; knuckles: a little redder
%define PAD  0xF4E0D6               ; palm side: a little paler
%define NAIL 0xFFF3EE

; part records
%macro TUBE 12  ; colour, x0,y0,z0, x1,y1,z1, r0, r1, wobble, wobble freq, sides
    dd PT_TUBE, %1
    dd %2, %3, %4, %5, %6, %7, %8, %9, %10, %11, %12, 0.0
%endmacro
%macro ELL 13   ; colour, centre, axis A, axis B, axis C
    dd PT_ELL, %1
    dd %2, %3, %4, %5, %6, %7, %8, %9, %10, %11, %12, %13
%endmacro

section .data
; ---- the hand (skin), gripping round local Z; fingers are added in code ----
hand_parts:
    ; back of the hand, from the wrist to the knuckles
    ELL SK, 0.054, -0.018, 0.0, -0.0302, -0.0196, 0.0, 0.0074, -0.0113, 0.0, 0.0, 0.0, 0.041
    ; palm pads pressing on the grip
    ELL PAD, 0.032, 0.006, 0.0, 0.0116, 0.0031, 0.0, 0.0067, -0.0251, 0.0, 0.0, 0.0, 0.040
    ELL PAD, 0.045, 0.018, 0.022, 0.014, 0.0, 0.0, 0.0, -0.013, 0.0, 0.0, 0.0, 0.016
    ; the ball of the thumb
    ELL PAD, 0.046, 0.012, -0.024, 0.016, -0.004, 0.0, -0.004, -0.015, 0.0, 0.0, 0.0, 0.017
    ; wrist and forearm (it disappears into the sleeve)
    ELL SK, 0.084, 0.004, 0.0, 0.019, 0.0, 0.0, 0.0, -0.0195, 0.0, 0.0, 0.0, 0.028
    TUBE SK, 0.084, 0.004, 0.0, 0.254, 0.0205, 0.246, 0.0235, 0.034, 0.0, 0.0, 18.0
    ; the thumb, laid along the grip: metacarpal, two phalanges, joints
    TUBE SK, 0.050, 0.004, -0.026, 0.034, -0.012, -0.040, 0.0128, 0.0118, 0.0, 0.0, 16.0
    TUBE SK, 0.034, -0.012, -0.040, 0.020, -0.022, -0.060, 0.0116, 0.0102, 0.0, 0.0, 16.0
    TUBE SK, 0.020, -0.022, -0.060, 0.012, -0.025, -0.077, 0.0100, 0.0086, 0.0, 0.0, 16.0
    ELL KN, 0.034, -0.012, -0.040, 0.0122, 0.0, 0.0, 0.0, -0.0122, 0.0, 0.0, 0.0, 0.0122
    ELL KN, 0.020, -0.022, -0.060, 0.0104, 0.0, 0.0, 0.0, -0.0104, 0.0, 0.0, 0.0, 0.0104
    ELL SK, 0.012, -0.025, -0.077, 0.0086, 0.0, 0.0, 0.0, -0.0086, 0.0, 0.0, 0.0, 0.0095
    ; thumbnail
    ELL NAIL, 0.0215, -0.0335, -0.0685, 0.0038, -0.0056, 0.0, 0.0, 0.0, 0.0072, 0.0012, 0.0008, 0.0
hand_parts_end:

; ---- the hoodie sleeve (cloth) ----
sleeve_parts:
    ; ribbed cuff, then the sleeve with a few soft folds, along the forearm
    TUBE 0xFFFFFF,  0.1806,0.0134,0.1396,   0.2004,0.0153,0.1683,   0.0355, 0.0365,  0.07, 28.0, 32.0
    TUBE 0xFFFFFF,  0.1976,0.0150,0.1642,   0.3112,0.0260,0.3284,   0.043, 0.050,   0.05, 5.0, 24.0
    TUBE 0xFFFFFF,  0.3084,0.0257,0.3243,   0.4816,0.0425,0.5747,   0.050, 0.057,   0.06, 4.0, 24.0
    ; the dark inside of the cuff round the wrist
    TUBE 0x606060,  0.1800,0.0133,0.1387,   0.1811,0.0134,0.1404,   0.0355, 0.0245,  0.0, 0.0, 32.0
sleeve_parts_end:

; ---- the flashlight: anodised body along Z, head toward -Z ----
torch_parts:
    TUBE 0x151515,  0.0, 0.0, 0.074,   0.0, 0.0, 0.050,   0.0163, 0.0163,  0.0, 0.0, 24.0   ; tail cap
    ELL  0x151515,  0.0, 0.0, 0.074,   0.0163, 0.0, 0.0,   0.0, 0.0163, 0.0,   0.0, 0.0, 0.004
    TUBE 0x24262C,  0.0, 0.0, 0.050,   0.0, 0.0, -0.126,   0.0157, 0.0157,  0.0, 0.0, 28.0   ; body
    TUBE 0x40434A,  0.0, 0.0, -0.100,  0.0, 0.0, -0.104,   0.0162, 0.0162,  0.0, 0.0, 28.0   ; grip rings
    TUBE 0x40434A,  0.0, 0.0, -0.108,  0.0, 0.0, -0.112,   0.0162, 0.0162,  0.0, 0.0, 28.0
    TUBE 0x40434A,  0.0, 0.0, -0.116,  0.0, 0.0, -0.120,   0.0162, 0.0162,  0.0, 0.0, 28.0
    ELL  0x8A1C1C,  0.0, 0.0158, 0.043,   0.0052, 0.0, 0.0,   0.0, 0.0035, 0.0,   0.0, 0.0, 0.0075   ; switch
    TUBE 0x2B2D33,  0.0, 0.0, -0.126,  0.0, 0.0, -0.160,   0.0157, 0.0236,  0.0, 0.0, 28.0   ; head
    TUBE 0x9C9EA4,  0.0, 0.0, -0.160,  0.0, 0.0, -0.170,   0.0246, 0.0246,  0.0, 0.0, 28.0   ; bezel
    TUBE 0x9C9EA4,  0.0, 0.0, -0.170,  0.0, 0.0, -0.1705,  0.0246, 0.0205,  0.0, 0.0, 28.0
torch_parts_end:
lens_part:
    ELL 0xFFF4DC,   0.0, 0.0, -0.1686,   0.0206, 0.0, 0.0,   0.0, 0.0206, 0.0,   0.0, 0.0, 0.0022

; ---- the zipline trolley's handle bar ----
bar_parts:
    TUBE 0x6A6D72,  0.0, 0.0, -0.30,   0.0, 0.0, 0.30,   0.0135, 0.0135,  0.0, 0.0, 20.0
    TUBE 0x1A1A1A,  0.0, 0.0, -0.075,  0.0, 0.0, 0.075,  0.0150, 0.0150,  0.0, 0.0, 20.0   ; rubber grip
bar_parts_end:

; ---- the portal gun: a dark grip in the hand, the white body ahead ----
gun_parts:
    TUBE 0x2E3036,  0.0, 0.0, 0.075,   0.0, 0.0, -0.05,   0.0175, 0.0175,  0.0, 0.0, 24.0
    ELL  0xE6E6EA,  0.0, 0.032, -0.105,   0.034, 0.0, 0.0,   0.0, 0.036, 0.0,   0.0, 0.0, 0.095
    ELL  0xE6E6EA,  0.0, 0.030, 0.004,   0.027, 0.0, 0.0,   0.0, 0.029, 0.0,   0.0, 0.0, 0.042
    TUBE 0x2E3036,  0.0, 0.032, -0.185,   0.0, 0.032, -0.25,   0.020, 0.017,  0.0, 0.0, 24.0
    TUBE 0x2E3036,  0.0, 0.062, -0.20,   0.0, 0.056, -0.265,   0.0048, 0.0040,  0.0, 0.0, 10.0
    TUBE 0x2E3036,  0.026, 0.017, -0.20,   0.021, 0.020, -0.265,   0.0048, 0.0040,  0.0, 0.0, 10.0
    TUBE 0x2E3036,  -0.026, 0.017, -0.20,   -0.021, 0.020, -0.265,   0.0048, 0.0040,  0.0, 0.0, 10.0
gun_parts_end:
; ---- the hookshot: a dark grip, a green body, a brass chain spool and ring,
; and the hook itself on the front (gone while it's flying)
hook_parts:
    TUBE 0x2E3036,  0.0, 0.0, 0.075,   0.0, 0.0, -0.05,   0.0175, 0.0175,  0.0, 0.0, 24.0
    TUBE 0x3F7A3A,  0.0, 0.034, 0.03,   0.0, 0.034, -0.20,   0.031, 0.027,  0.0, 0.0, 24.0
    ELL  0xB89A48,  0.0, 0.034, 0.045,   0.036, 0.0, 0.0,   0.0, 0.036, 0.0,   0.0, 0.0, 0.03
    TUBE 0xB89A48,  0.0, 0.034, -0.20,   0.0, 0.034, -0.216,   0.037, 0.037,  0.0, 0.0, 24.0
    TUBE 0x2E3036,  0.0, 0.034, -0.216,   0.0, 0.034, -0.25,   0.013, 0.012,  0.0, 0.0, 14.0
hook_parts_end:
hooktip_parts:
    ELL  0xC9A94A,  0.0, 0.034, -0.262,   0.016, 0.0, 0.0,   0.0, 0.016, 0.0,   0.0, 0.0, 0.022
    TUBE 0xC9A94A,  0.0, 0.034, -0.27,   0.024, 0.05, -0.29,   0.006, 0.004,  0.0, 0.0, 8.0
    TUBE 0xC9A94A,  0.0, 0.034, -0.27,   -0.024, 0.05, -0.29,   0.006, 0.004,  0.0, 0.0, 8.0
    TUBE 0xC9A94A,  0.0, 0.034, -0.27,   0.0, 0.006, -0.292,   0.006, 0.004,  0.0, 0.0, 8.0
hooktip_parts_end:

tip_part:
    ELL 0xFFFFFF,   0.0, 0.032, -0.252,   0.0135, 0.0, 0.0,   0.0, 0.0135, 0.0,   0.0, 0.0, 0.0135

; ---- the four fingers: z along the grip, radius, and the angles (degrees
; round the grip, 0 = +X, 90 = +Y) of knuckle, middle joint, last joint, tip.
; They curl clockwise seen from behind, thumb forward: the right-hand rule.
;            z        r       MCP   PIP    DIP    tip
fingers:
    dd -0.0300, 0.0090,  -60.0, -140.0, -205.0, -245.0     ; index
    dd -0.0105, 0.0096,  -58.0, -140.0, -207.0, -248.0     ; middle
    dd  0.0085, 0.0091,  -56.0, -138.0, -204.0, -244.0     ; ring
    dd  0.0265, 0.0079,  -54.0, -132.0, -195.0, -232.0     ; pinky
c_grip_r    dd 0.0156               ; radius of what's gripped
c_mcp_out   dd 0.0170               ; knuckles sit this far out from the finger line
c_deg       dd 0.0174532925
c_inv_pi    dd 0.318309886
c_tex_v     dd 22.0                 ; texture repeats per metre along a tube

; ---- poses: where the hand's local X, Y, Z axes point in camera space ----
rot_torch   dd 0.990, -0.139, 0.0,   0.139, 0.990, 0.0,   0.0, 0.0, 1.0
rot_gun     dd 0.990, 0.139, 0.0,   -0.139, 0.990, 0.0,   0.0, 0.0, 1.0
rot_bar     dd 0.0, 1.0, 0.0,   0.0, 0.0, -1.0,  -1.0, 0.0, 0.0
rot_ladder  dd 0.0, 0.6, -0.8,   0.0, 0.8, 0.6,   1.0, 0.0, 0.0
; ...and where the grip sits (camera space)
pos_torch   dd 0.195, -0.195, -0.33
pos_gun     dd -0.20, -0.21, -0.37
pos_bar     dd -0.10, 0.22, -0.40
pos_ladder  dd -0.21, -0.17, -0.42
; the light bouncing back off the world: from here, aimed at there
bounce_from dd 0.0, 0.45, -2.4
bounce_to   dd 0.0, -0.04, -0.32
c_bounce0   dd 0.022                ; with the torch off: a little ambient bounce
c_bounce1   dd 0.17                 ; per unit of flashlight
c_emit0     dd 0.018
c_emit1     dd 0.045
c_lens      dd 3.2
c_swayx     dd 0.012
c_swayy     dd 0.014
c_climb     dd 4.2
c_reach     dd 0.11
c_kick_z    dd 0.5
c_kick_y    dd 0.18

section .bss
alignb 4
lists       resd 1                  ; first display list, 0 = not built yet
rec         resd 14                 ; a part record built in code (fingers)
tb_rec      resq 1
tb_d        resd 3                  ; tube: axis, length, frame
tb_len      resd 1
tb_u        resd 3
tb_v        resd 3
el_rec      resq 1
el_i        resd 3                  ; ellipsoid: 1 / |axis|^2
bas         resd 9                  ; camera basis: right, up, back
mm          resd 16                 ; model matrix
tmp         resd 12
sway_x      resd 1
sway_y      resd 1
lad_l       resd 1
lad_r       resd 1

section .text

; rgb(edi=0xRRGGBB) -- glColor3f
rgb:
    sub rsp, 8
    FLD xmm3, 0.003921569
    mov eax, edi
    shr eax, 16
    and eax, 255
    cvtsi2ss xmm0, eax
    mulss xmm0, xmm3
    mov eax, edi
    shr eax, 8
    and eax, 255
    cvtsi2ss xmm1, eax
    mulss xmm1, xmm3
    mov eax, edi
    and eax, 255
    cvtsi2ss xmm2, eax
    mulss xmm2, xmm3
    call glColor3f
    add rsp, 8
    ret

; ---- tubes -------------------------------------------------------------------

; tube(rsi = record floats: p0, p1, r0, r1, wobble, wobble freq, sides)
tube:
    PROLOGUE 32
    mov [tb_rec], rsi
    mov r12, rsi
    xor ecx, ecx
.d:
    movss xmm0, [r12+12+rcx*4]
    subss xmm0, [r12+rcx*4]
    movss [tb_d+rcx*4], xmm0
    inc ecx
    cmp ecx, 3
    jl .d
    movss xmm0, [tb_d]
    mulss xmm0, xmm0
    movss xmm1, [tb_d+4]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [tb_d+8]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    maxss xmm0, [c_tiny]
    movss [tb_len], xmm0
    xor ecx, ecx
.n:
    movss xmm1, [tb_d+rcx*4]
    divss xmm1, xmm0
    movss [tb_d+rcx*4], xmm1
    inc ecx
    cmp ecx, 3
    jl .n
    ; a helper axis that isn't parallel to the tube
    xorps xmm0, xmm0
    movss [tmp+0], xmm0
    movss [tmp+8], xmm0
    mov eax, [c_one]
    mov [tmp+4], eax                    ; (0,1,0)
    movss xmm0, [tb_d+4]
    andps xmm0, [c_abs_mask]
    FLD xmm1, 0.9
    comiss xmm0, xmm1
    jb .helper
    mov [tmp+0], eax                    ; (1,0,0)
    mov dword [tmp+4], 0
.helper:
    ; u = normalize(d x h), v = d x u
    lea rdi, [tb_u]
    lea rsi, [tb_d]
    lea rdx, [tmp]
    call cross
    lea rdi, [tb_u]
    call normalize
    lea rdi, [tb_v]
    lea rsi, [tb_d]
    lea rdx, [tb_u]
    call cross
    ; the sides
    cvttss2si r13d, [r12+40]
    xor ebx, ebx
.side:
    cmp ebx, r13d
    jge .done
    cvtsi2ss xmm0, ebx
    call side_angle
    movss [rsp+0], xmm0
    lea eax, [rbx+1]
    cvtsi2ss xmm0, eax
    call side_angle
    movss [rsp+4], xmm0
    movss xmm0, [rsp+0]
    xor edi, edi
    call tube_v
    movss xmm0, [rsp+0]
    mov edi, 1
    call tube_v
    movss xmm0, [rsp+4]
    mov edi, 1
    call tube_v
    movss xmm0, [rsp+4]
    xor edi, edi
    call tube_v
    inc ebx
    jmp .side
.done:
    EPILOGUE

; side_angle(xmm0 = i, r13d = sides) -> xmm0 = 2*pi*i/sides. leaf
side_angle:
    mulss xmm0, [c_two_pi]
    cvtsi2ss xmm1, r13d
    divss xmm0, xmm1
    ret

; tube_v(xmm0 = angle, edi = 0 start / 1 end) -- one vertex of the tube
tube_v:
    PROLOGUE 48
    movss [rsp+0], xmm0
    mov ebx, edi
    mov r12, [tb_rec]
    call cosf
    movss [rsp+4], xmm0
    movss xmm0, [rsp+0]
    call sinf
    movss [rsp+8], xmm0
    ; radius, with folds / ribs: r * (1 + wobble * sin(freq * angle))
    movss xmm0, [r12+36]
    mulss xmm0, [rsp+0]
    call sinf
    mulss xmm0, [r12+32]
    addss xmm0, [c_one]
    movss xmm1, [r12+24]
    test ebx, ebx
    jz .r
    movss xmm1, [r12+28]
.r:
    mulss xmm0, xmm1
    movss [rsp+12], xmm0
    ; o = u cos + v sin (the normal)
    xor ecx, ecx
.o:
    movss xmm0, [tb_u+rcx*4]
    mulss xmm0, [rsp+4]
    movss xmm1, [tb_v+rcx*4]
    mulss xmm1, [rsp+8]
    addss xmm0, xmm1
    movss [rsp+16+rcx*4], xmm0
    inc ecx
    cmp ecx, 3
    jl .o
    movss xmm0, [rsp+16]
    movss xmm1, [rsp+20]
    movss xmm2, [rsp+24]
    call glNormal3f
    movss xmm0, [rsp+0]
    mulss xmm0, [c_inv_pi]
    xorps xmm1, xmm1
    test ebx, ebx
    jz .t
    movss xmm1, [tb_len]
    mulss xmm1, [c_tex_v]
.t:
    call glTexCoord2f
    ; position = end point + o * r
    lea rax, [r12]
    test ebx, ebx
    jz .p
    lea rax, [r12+12]
.p:
    xor ecx, ecx
.pp:
    movss xmm0, [rsp+16+rcx*4]
    mulss xmm0, [rsp+12]
    addss xmm0, [rax+rcx*4]
    movss [rsp+32+rcx*4], xmm0
    inc ecx
    cmp ecx, 3
    jl .pp
    movss xmm0, [rsp+32]
    movss xmm1, [rsp+36]
    movss xmm2, [rsp+40]
    call glVertex3f
    EPILOGUE

; ---- ellipsoids ------------------------------------------------------------------

; ell(rsi = record floats: centre, A, B, C)
ell:
    PROLOGUE 32
    mov [el_rec], rsi
    xor ebx, ebx
.inv:
    imul eax, ebx, 12
    lea rdi, [rsi+12+rax]
    movss xmm0, [rdi]
    mulss xmm0, xmm0
    movss xmm1, [rdi+4]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [rdi+8]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    maxss xmm0, [c_tiny]
    movss xmm1, [c_one]
    divss xmm1, xmm0
    movss [el_i+rbx*4], xmm1
    inc ebx
    cmp ebx, 3
    jl .inv
    xor r12d, r12d                      ; latitude band
.lat:
    cmp r12d, ELL_LAT
    jge .done
    xor r13d, r13d                      ; longitude
.lon:
    cmp r13d, ELL_LON
    jge .nlat
    mov edi, r12d
    mov esi, r13d
    call ell_v
    lea edi, [r12d+1]
    mov esi, r13d
    call ell_v
    lea edi, [r12d+1]
    lea esi, [r13d+1]
    call ell_v
    mov edi, r12d
    lea esi, [r13d+1]
    call ell_v
    inc r13d
    jmp .lon
.nlat:
    inc r12d
    jmp .lat
.done:
    EPILOGUE

; ell_v(edi = latitude step, esi = longitude step) -- one vertex
ell_v:
    PROLOGUE 64
    ; theta = -pi/2 + pi * i / LAT, phi = 2pi * j / LON
    cvtsi2ss xmm0, edi
    mulss xmm0, [c_pi]
    FLD xmm1, 10.0
    divss xmm0, xmm1
    movss xmm1, [c_pi]
    mulss xmm1, [c_half]
    subss xmm0, xmm1
    movss [rsp+0], xmm0                 ; theta
    cvtsi2ss xmm0, esi
    mulss xmm0, [c_two_pi]
    FLD xmm1, 16.0
    divss xmm0, xmm1
    movss [rsp+4], xmm0                 ; phi
    movss xmm0, [rsp+0]
    call cosf
    movss [rsp+8], xmm0                 ; ct
    movss xmm0, [rsp+0]
    call sinf
    movss [rsp+12], xmm0                ; st
    movss xmm0, [rsp+4]
    call cosf
    mulss xmm0, [rsp+8]
    movss [rsp+16], xmm0                ; a = ct cp
    movss xmm0, [rsp+4]
    call sinf
    mulss xmm0, [rsp+8]
    movss [rsp+20], xmm0                ; b = ct sp
    mov eax, [rsp+12]
    mov [rsp+24], eax                   ; c = st
    mov r12, [el_rec]
    ; normal = sum coef * axis / |axis|^2, position = centre + sum coef * axis
    xor ecx, ecx
.k:
    movss xmm0, [r12+12+rcx*4]          ; A
    mulss xmm0, [rsp+16]
    movss xmm1, [r12+24+rcx*4]          ; B
    mulss xmm1, [rsp+20]
    movss xmm2, [r12+36+rcx*4]          ; C
    mulss xmm2, [rsp+24]
    movss xmm3, xmm0
    addss xmm3, xmm1
    addss xmm3, xmm2
    addss xmm3, [r12+rcx*4]
    movss [rsp+40+rcx*4], xmm3          ; position
    mulss xmm0, [el_i+0]
    mulss xmm1, [el_i+4]
    mulss xmm2, [el_i+8]
    addss xmm0, xmm1
    addss xmm0, xmm2
    movss [rsp+28+rcx*4], xmm0          ; normal (unnormalised)
    inc ecx
    cmp ecx, 3
    jl .k
    lea rdi, [rsp+28]
    call normalize
    movss xmm0, [rsp+28]
    movss xmm1, [rsp+32]
    movss xmm2, [rsp+36]
    call glNormal3f
    movss xmm0, [rsp+4]
    mulss xmm0, [c_inv_pi]
    movss xmm1, [rsp+0]
    mulss xmm1, [c_inv_pi]
    call glTexCoord2f
    movss xmm0, [rsp+40]
    movss xmm1, [rsp+44]
    movss xmm2, [rsp+48]
    call glVertex3f
    EPILOGUE

; ---- vectors ------------------------------------------------------------------

; cross(rdi = out, rsi = a, rdx = b). leaf
cross:
    movss xmm0, [rsi+4]
    mulss xmm0, [rdx+8]
    movss xmm1, [rsi+8]
    mulss xmm1, [rdx+4]
    subss xmm0, xmm1
    movss xmm2, [rsi+8]
    mulss xmm2, [rdx]
    movss xmm1, [rsi]
    mulss xmm1, [rdx+8]
    subss xmm2, xmm1
    movss xmm3, [rsi]
    mulss xmm3, [rdx+4]
    movss xmm1, [rsi+4]
    mulss xmm1, [rdx]
    subss xmm3, xmm1
    movss [rdi], xmm0
    movss [rdi+4], xmm2
    movss [rdi+8], xmm3
    ret

; normalize(rdi = vec3). leaf
normalize:
    movss xmm0, [rdi]
    mulss xmm0, xmm0
    movss xmm1, [rdi+4]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [rdi+8]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    maxss xmm0, [c_tiny]
    movss xmm1, [c_one]
    divss xmm1, xmm0
    movss xmm0, [rdi]
    mulss xmm0, xmm1
    movss [rdi], xmm0
    movss xmm0, [rdi+4]
    mulss xmm0, xmm1
    movss [rdi+4], xmm0
    movss xmm0, [rdi+8]
    mulss xmm0, xmm1
    movss [rdi+8], xmm0
    ret

; ---- building the display lists ----------------------------------------------------

; parts(rdi = first record, rsi = end) -- emit a table of parts
parts:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
.p:
    cmp r12, r13
    jae .done
    mov edi, [r12+4]
    call rgb
    lea rsi, [r12+8]
    cmp dword [r12], PT_TUBE
    jne .e
    call tube
    jmp .n
.e:
    call ell
.n:
    add r12, REC
    jmp .p
.done:
    EPILOGUE

; finger_point(xmm0 = angle in degrees, xmm1 = radius from the grip axis,
;              xmm2 = z, rdi = out vec3). leaf-ish
finger_point:
    PROLOGUE 32
    mov r12, rdi
    movss [rsp+0], xmm1
    movss [r12+8], xmm2
    mulss xmm0, [c_deg]
    movss [rsp+4], xmm0
    call cosf
    mulss xmm0, [rsp+0]
    movss [r12], xmm0
    movss xmm0, [rsp+4]
    call sinf
    mulss xmm0, [rsp+0]
    movss [r12+4], xmm0
    EPILOGUE

; fingers_emit -- the four fingers wrapped round the grip: three tubes per
; finger between four joints, a bulge at every joint, a nail at the tip
fingers_emit:
    PROLOGUE 128
    ; [rsp+0..47] the four joints (vec3 each), [rsp+48] r, [rsp+52] line radius
    ; [rsp+56] z, [rsp+64..] scratch
    xor ebx, ebx
.f:
    cmp ebx, 4
    jge .done
    imul eax, ebx, 24
    lea r12, [fingers+rax]
    mov eax, [r12]
    mov [rsp+56], eax                   ; z
    mov eax, [r12+4]
    mov [rsp+48], eax                   ; r
    movss xmm0, [r12+4]
    FLD xmm1, 0.95
    mulss xmm0, xmm1
    addss xmm0, [c_grip_r]
    movss [rsp+52], xmm0                ; the finger's centre line round the grip
    ; joints: knuckle (further out), middle, last, tip
    movss xmm0, [r12+8]
    movss xmm1, [rsp+52]
    addss xmm1, [c_mcp_out]
    movss xmm2, [rsp+56]
    lea rdi, [rsp+0]
    call finger_point
    xor r13d, r13d
.j:
    inc r13d
    cmp r13d, 4
    jge .joints_done
    movss xmm0, [r12+8+r13*4]
    movss xmm1, [rsp+52]
    movss xmm2, [rsp+56]
    imul eax, r13d, 12
    lea rdi, [rsp+rax]
    call finger_point
    jmp .j
.joints_done:
    ; phalanges: radius tapers 0.97 -> 0.93 -> 0.88 -> 0.80 of r
    mov edi, SK
    call rgb
    xor r13d, r13d
.seg:
    cmp r13d, 3
    jge .bulges
    imul eax, r13d, 12
    lea rsi, [rsp+rax]
    lea rdi, [rec]
    mov ecx, [rsi]
    mov [rdi], ecx
    mov ecx, [rsi+4]
    mov [rdi+4], ecx
    mov ecx, [rsi+8]
    mov [rdi+8], ecx
    mov ecx, [rsi+12]
    mov [rdi+12], ecx
    mov ecx, [rsi+16]
    mov [rdi+16], ecx
    mov ecx, [rsi+20]
    mov [rdi+20], ecx
    movss xmm0, [rsp+48]
    movss xmm1, [taper+r13*4]
    mulss xmm1, xmm0
    movss [rdi+24], xmm1
    movss xmm1, [taper+4+r13*4]
    mulss xmm1, xmm0
    movss [rdi+28], xmm1
    mov dword [rdi+32], 0
    mov dword [rdi+36], 0
    mov dword [rdi+40], __float32__(16.0)
    lea rsi, [rec]
    call tube
    inc r13d
    jmp .seg
.bulges:
    ; joints: knuckle, middle, last, fingertip (a little longer than wide)
    xor r13d, r13d
.b:
    cmp r13d, 4
    jge .nail
    mov edi, KN
    cmp r13d, 2
    jl .bc
    mov edi, SK
.bc:
    call rgb
    imul eax, r13d, 12
    lea rsi, [rsp+rax]
    lea rdi, [rec]
    mov ecx, [rsi]
    mov [rdi], ecx
    mov ecx, [rsi+4]
    mov [rdi+4], ecx
    mov ecx, [rsi+8]
    mov [rdi+8], ecx
    movss xmm0, [rsp+48]
    mulss xmm0, [bulge+r13*4]
    xorps xmm1, xmm1
    movss [rdi+12], xmm0
    movss [rdi+16], xmm1
    movss [rdi+20], xmm1
    movss [rdi+24], xmm1
    movss [rdi+28], xmm0
    movss [rdi+32], xmm1
    movss [rdi+36], xmm1
    movss [rdi+40], xmm1
    mulss xmm0, [bulge_z+r13*4]
    movss [rdi+44], xmm0
    lea rsi, [rec]
    call ell
    inc r13d
    jmp .b
.nail:
    ; on the outside of the last phalanx: halfway along it, pushed out
    ; radially, a thin ellipsoid lying along the phalanx
    mov edi, NAIL
    call rgb
    xor ecx, ecx
.mid:
    movss xmm0, [rsp+24+rcx*4]
    addss xmm0, [rsp+36+rcx*4]
    mulss xmm0, [c_half]
    movss [rsp+64+rcx*4], xmm0          ; midpoint
    movss xmm0, [rsp+36+rcx*4]
    subss xmm0, [rsp+24+rcx*4]
    movss [rsp+76+rcx*4], xmm0          ; along
    inc ecx
    cmp ecx, 3
    jl .mid
    lea rdi, [rsp+76]
    call normalize
    ; outward = the midpoint's direction from the grip axis
    mov eax, [rsp+64]
    mov [rsp+88], eax
    mov eax, [rsp+68]
    mov [rsp+92], eax
    mov dword [rsp+96], 0
    lea rdi, [rsp+88]
    call normalize
    movss xmm3, [rsp+48]
    FLD xmm4, 0.74
    mulss xmm3, xmm4                    ; out by 0.74 r
    lea rdi, [rec]
    xor ecx, ecx
.nc:
    movss xmm0, [rsp+88+rcx*4]
    mulss xmm0, xmm3
    addss xmm0, [rsp+64+rcx*4]
    movss [rdi+rcx*4], xmm0             ; centre
    movss xmm0, [rsp+76+rcx*4]
    FLD xmm1, 0.0058
    mulss xmm0, xmm1
    movss [rdi+12+rcx*4], xmm0          ; A: along the finger
    movss xmm0, [rsp+88+rcx*4]
    FLD xmm1, 0.0016
    mulss xmm0, xmm1
    movss [rdi+36+rcx*4], xmm0          ; C: thin, outward
    inc ecx
    cmp ecx, 3
    jl .nc
    mov dword [rdi+24], 0               ; B: across the finger (local Z)
    mov dword [rdi+28], 0
    movss xmm0, [rsp+48]
    FLD xmm1, 0.78
    mulss xmm0, xmm1
    movss [rdi+32], xmm0
    lea rsi, [rec]
    call ell
    inc ebx
    jmp .f
.done:
    EPILOGUE

; build_lists -- compile the hand, sleeve and props once
build_lists:
    PROLOGUE 16
    mov edi, NLISTS
    call glGenLists
    mov [lists], eax
    mov edi, L_SKIN
    call begin_list
    lea rdi, [hand_parts]
    lea rsi, [hand_parts_end]
    call parts
    call fingers_emit
    call end_list
    mov edi, L_CLOTH
    call begin_list
    lea rdi, [sleeve_parts]
    lea rsi, [sleeve_parts_end]
    call parts
    call end_list
    mov edi, L_TORCH
    call begin_list
    lea rdi, [torch_parts]
    lea rsi, [torch_parts_end]
    call parts
    call end_list
    mov edi, L_BAR
    call begin_list
    lea rdi, [bar_parts]
    lea rsi, [bar_parts_end]
    call parts
    call end_list
    mov edi, L_GUN
    call begin_list
    lea rdi, [gun_parts]
    lea rsi, [gun_parts_end]
    call parts
    call end_list
    mov edi, L_HOOK
    call begin_list
    lea rdi, [hook_parts]
    lea rsi, [hook_parts_end]
    call parts
    call end_list
    mov edi, L_HOOKTIP
    call begin_list
    lea rdi, [hooktip_parts]
    lea rsi, [hooktip_parts_end]
    call parts
    call end_list
    EPILOGUE

; begin_list(edi = which) / end_list
begin_list:
    sub rsp, 8
    add edi, [lists]
    mov esi, GL_COMPILE
    call glNewList
    mov edi, GL_QUADS
    call glBegin
    add rsp, 8
    ret
end_list:
    sub rsp, 8
    call glEnd
    call glEndList
    add rsp, 8
    ret

; call_list(edi = which)
call_list:
    add edi, [lists]
    jmp glCallList

; ---- materials ----------------------------------------------------------------
mat_skin:
    sub rsp, 8
    mov edi, [skin_tex]
    call bind
    xorps xmm0, xmm0                    ; skin: smooth (no bump relief)...
    FLD xmm1, 0.22                      ; ...with a soft sheen
    call set_material
    add rsp, 8
    ret
mat_cloth:
    sub rsp, 8
    mov edi, [cloth_tex]
    call bind
    FLD xmm0, 0.75
    FLD xmm1, 0.03
    call set_material
    add rsp, 8
    ret
mat_hard:                               ; xmm1 = shine
    sub rsp, 8
    movss [rsp+0], xmm1
    mov edi, [white_tex]
    call bind
    xorps xmm0, xmm0
    movss xmm1, [rsp+0]
    call set_material
    add rsp, 8
    ret

; ---- placing a hand ---------------------------------------------------------------

; basis -- the camera's right / up / back axes in world space (bas)
basis:
    PROLOGUE 32
    movss xmm0, [p_yaw]
    call cosf
    movss [rsp+0], xmm0                 ; c
    movss xmm0, [p_yaw]
    call sinf
    movss [rsp+4], xmm0                 ; s
    movss xmm0, [p_pitch]
    call cosf
    movss [rsp+8], xmm0                 ; cp
    movss xmm0, [p_pitch]
    call sinf
    movss [rsp+12], xmm0                ; sp
    ; right = (c, 0, -s)
    mov eax, [rsp+0]
    mov [bas+0], eax
    mov dword [bas+4], 0
    movss xmm0, [rsp+4]
    xorps xmm0, [c_sign_mask]
    movss [bas+8], xmm0
    ; up = (s sp, cp, c sp)
    movss xmm0, [rsp+4]
    mulss xmm0, [rsp+12]
    movss [bas+12], xmm0
    mov eax, [rsp+8]
    mov [bas+16], eax
    movss xmm0, [rsp+0]
    mulss xmm0, [rsp+12]
    movss [bas+20], xmm0
    ; back = (s cp, -sp, c cp)
    movss xmm0, [rsp+4]
    mulss xmm0, [rsp+8]
    movss [bas+24], xmm0
    movss xmm0, [rsp+12]
    xorps xmm0, [c_sign_mask]
    movss [bas+28], xmm0
    movss xmm0, [rsp+0]
    mulss xmm0, [rsp+8]
    movss [bas+32], xmm0
    EPILOGUE

; to_world(rsi = camera-space vec3, rdi = out world point). leaf
to_world:
    lea rdx, [cam_x]
    xor ecx, ecx
.k:
    movss xmm0, [bas+rcx*4]
    mulss xmm0, [rsi]
    movss xmm1, [bas+12+rcx*4]
    mulss xmm1, [rsi+4]
    addss xmm0, xmm1
    movss xmm1, [bas+24+rcx*4]
    mulss xmm1, [rsi+8]
    addss xmm0, xmm1
    addss xmm0, [rdx+rcx*4]
    movss [rdi+rcx*4], xmm0
    inc ecx
    cmp ecx, 3
    jl .k
    ret

; place(rdi = pose rotation (3 columns), rsi = grip position (camera space),
;       edx = 1 for the mirrored left hand) -- push the model matrix
;   world = cam + B * (pos + R * S * local),  B = camera basis, S = mirror
place:
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    ; rotation columns: B * R[:,k]
    xor ebx, ebx
.col:
    cmp ebx, 3
    jge .cols
    imul eax, ebx, 12
    lea rsi, [r12+rax]
    xor ecx, ecx
.row:
    movss xmm0, [bas+rcx*4]
    mulss xmm0, [rsi]
    movss xmm1, [bas+12+rcx*4]
    mulss xmm1, [rsi+4]
    addss xmm0, xmm1
    movss xmm1, [bas+24+rcx*4]
    mulss xmm1, [rsi+8]
    addss xmm0, xmm1
    mov eax, ebx
    shl eax, 2
    add eax, ecx
    movss [mm+rax*4], xmm0
    inc ecx
    cmp ecx, 3
    jl .row
    mov eax, ebx
    shl eax, 2
    mov dword [mm+12+rax*4], 0
    inc ebx
    jmp .col
.cols:
    test r14d, r14d
    jz .no_mirror
    xor ecx, ecx
.m:
    movss xmm0, [mm+rcx*4]
    xorps xmm0, [c_sign_mask]
    movss [mm+rcx*4], xmm0
    inc ecx
    cmp ecx, 3
    jl .m
.no_mirror:
    ; translation: the grip's world position
    lea rdi, [mm+48]
    mov rsi, r13
    call to_world
    mov eax, [c_one]
    mov [mm+60], eax
    call glPushMatrix
    lea rdi, [mm]
    call glMultMatrixf
    mov edi, [u_model]
    mov esi, 1
    xor edx, edx
    lea rcx, [mm]
    GL2CALL glUniformMatrix4fv
    EPILOGUE

; hand_lists -- the hand and its sleeve, in the current placement
hand_lists:
    sub rsp, 8
    call mat_skin
    mov edi, L_SKIN
    call call_list
    call mat_cloth
    mov edi, L_CLOTH
    call call_list
    add rsp, 8
    ret

; glowing(rdi = part record, xmm0 = emission) -- a lit-up bit (lens, gun tip)
glowing:
    PROLOGUE 16
    mov r12, rdi
    call set_emit
    mov edi, [white_tex]
    call bind
    mov edi, GL_QUADS
    call glBegin
    mov edi, [r12+4]
    call rgb
    lea rsi, [r12+8]
    call ell
    call glEnd
    EPILOGUE

; ---- the frame ------------------------------------------------------------------

; draw_viewmodel(xmm0 = time) -- last thing in the 3D view
draw_viewmodel:
    PROLOGUE 64
    cmp dword [cfg_hands], 0
    je .fixed
    cmp dword [lists], 0
    jne .built
    call build_lists
.built:
    mov edi, GL_DEPTH_BUFFER_BIT        ; hands never sink into walls
    call glClear
    mov edi, GL_BLEND
    call glDisable
    xor edi, edi
    call use_program
    call basis

    ; ---- light: the beam's bounce off the world, shining back at you
    lea rsi, [bounce_from]
    lea rdi, [rsp+0]
    call to_world
    lea rsi, [bounce_to]
    lea rdi, [rsp+12]
    call to_world
    xor ecx, ecx
.dir:
    movss xmm0, [rsp+12+rcx*4]
    subss xmm0, [rsp+rcx*4]
    movss [rsp+24+rcx*4], xmm0
    inc ecx
    cmp ecx, 3
    jl .dir
    lea rdi, [rsp+24]
    call normalize
    mov edi, [u_fpos]
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+8]
    GL2CALL glUniform3f
    mov edi, [u_fdir]
    movss xmm0, [rsp+24]
    movss xmm1, [rsp+28]
    movss xmm2, [rsp+32]
    GL2CALL glUniform3f
    mov edi, [u_son]
    xorps xmm0, xmm0
    GL2CALL glUniform1f
    mov edi, [u_flash]
    movss xmm0, [p_flash_level]
    mulss xmm0, [c_bounce1]
    addss xmm0, [c_bounce0]
    GL2CALL glUniform1f
    call base_emit

    ; ---- sway with the head bob; hand over hand on a ladder
    movss xmm0, [p_bob]
    call sinf
    mulss xmm0, [c_swayx]
    movss [sway_x], xmm0
    movss xmm0, [p_bob]
    addss xmm0, xmm0
    call sinf
    mulss xmm0, [c_swayy]
    movss [sway_y], xmm0
    xorps xmm0, xmm0
    movss [lad_l], xmm0
    movss [lad_r], xmm0
    cmp dword [p_mode], 1
    jne .no_ladder
    movss xmm0, [climb_phase]
    mulss xmm0, [c_climb]
    call sinf
    mulss xmm0, [c_reach]
    movss [lad_r], xmm0
    xorps xmm0, [c_sign_mask]
    addss xmm0, [c_reach]
    movss [lad_l], xmm0
.no_ladder:

    ; ---- right hand: the flashlight
    lea rsi, [pos_torch]
    lea rdi, [rsp+40]
    movss xmm0, [lad_r]
    call pose_pos
    lea rdi, [rot_torch]
    lea rsi, [rsp+40]
    xor edx, edx
    call place
    call hand_lists
    FLD xmm1, 0.9
    call mat_hard
    mov edi, L_TORCH
    call call_list
    movss xmm0, [p_flash_level]
    mulss xmm0, [c_lens]
    addss xmm0, [c_emit0]
    lea rdi, [lens_part]
    call glowing
    call base_emit
    call model_end

    ; ---- left hand
    cmp dword [p_mode], 2
    je .zip
    cmp dword [p_mode], 1
    je .ladder
    cmp dword [p_mode], 3               ; mantling/vaulting: plant it on the edge
    je .ladder
    cmp dword [have_portal], 0
    jne .gun
    cmp dword [have_hookshot], 0
    jne .hook
    jmp .done
.hook:
    ; the hookshot, held like the portal gun
    lea rsi, [pos_gun]
    lea rdi, [rsp+40]
    xorps xmm0, xmm0
    call pose_pos
    lea rdi, [rot_gun]
    lea rsi, [rsp+40]
    mov edx, 1
    call place
    call hand_lists
    FLD xmm1, 0.6
    call mat_hard
    mov edi, L_HOOK
    call call_list
    cmp dword [hk_state], 0             ; the hook's out on its chain
    jne .hook_out
    mov edi, L_HOOKTIP
    call call_list
.hook_out:
    call model_end
    jmp .done
.zip:
    lea rsi, [pos_bar]
    lea rdi, [rsp+40]
    xorps xmm0, xmm0
    call pose_pos
    lea rdi, [rot_bar]
    lea rsi, [rsp+40]
    mov edx, 1
    call place
    call hand_lists
    FLD xmm1, 0.6
    call mat_hard
    mov edi, L_BAR
    call call_list
    call model_end
    jmp .done
.ladder:
    lea rsi, [pos_ladder]
    lea rdi, [rsp+40]
    movss xmm0, [lad_l]
    call pose_pos
    lea rdi, [rot_ladder]
    lea rsi, [rsp+40]
    mov edx, 1
    call place
    call hand_lists
    call model_end
    jmp .done
.gun:
    lea rsi, [pos_gun]
    lea rdi, [rsp+40]
    movss xmm0, [gun_kick]
    mulss xmm0, [c_kick_y]
    call pose_pos
    movss xmm0, [gun_kick]
    mulss xmm0, [c_kick_z]
    addss xmm0, [rsp+48]
    movss [rsp+48], xmm0
    lea rdi, [rot_gun]
    lea rsi, [rsp+40]
    mov edx, 1
    call place
    call hand_lists
    FLD xmm1, 0.45
    call mat_hard
    mov edi, L_GUN
    call call_list
    ; the core glows in the colour of the last portal
    lea rdi, [tip_part]
    mov dword [rdi+4], 0x40A0FF
    cmp dword [gun_colour], 0
    je .blue
    mov dword [rdi+4], 0xFF8C1A
.blue:
    FLD xmm0, 1.6
    call glowing
    call model_end
.done:
    xorps xmm0, xmm0
    call set_emit
    FLD xmm0, 1.0
    FLD xmm1, 1.0
    FLD xmm2, 1.0
    FLD xmm3, 1.0
    call glColor4f
.fixed:
    xor edi, edi
    GL2CALL glUseProgram                ; back to the fixed pipeline for the HUD
    EPILOGUE

; pose_pos(rsi = base position, rdi = out, xmm0 = extra lift) -- add the sway
pose_pos:
    movss xmm1, [rsi]
    addss xmm1, [sway_x]
    movss [rdi], xmm1
    movss xmm1, [rsi+4]
    addss xmm1, [sway_y]
    addss xmm1, xmm0
    movss [rdi+4], xmm1
    mov eax, [rsi+8]
    mov [rdi+8], eax
    ret

; base_emit -- the faint glow that keeps hands readable in the dark
base_emit:
    sub rsp, 8
    movss xmm0, [p_flash_level]
    mulss xmm0, [c_emit1]
    addss xmm0, [c_emit0]
    call set_emit
    add rsp, 8
    ret

section .data
taper       dd 0.97, 0.93, 0.88, 0.80
bulge       dd 1.16, 1.04, 0.93, 0.82          ; knuckle, middle, last joint, tip
bulge_z     dd 1.0, 1.0, 1.0, 1.12
c_tiny      dd 0.000001
