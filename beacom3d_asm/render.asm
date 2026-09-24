; =============================================================================
; render.asm -- true 3D with OpenGL.
;
; Static world: at start-up every storey is turned into OpenGL display lists,
; one list per (storey, material). A wall cell only emits the faces that
; border a non-wall cell, floors/ceilings are one quad per cell, and props
; (desks, racks, pillars, stairs, B, Y and his cage) are little boxes.
;
; Lighting: a small GLSL program (the strings below) does per-pixel lighting
; in WORLD space -- the flashlight is a spotlight from the camera, plus six
; pooled point lights that are re-assigned a few times a second to the
; nearest working ceiling fixtures / exit signs / B's aura. Fog and a soft
; tone map finish it. Things that glow (light panels, exit signs, LEDs,
; screens, halos) are drawn afterwards without the shader ("unlit pass").
;
; Dynamic objects (T, items, NPCs, billboards) are placed with a model
; matrix: glMultMatrixf for the camera transform and the same matrix as the
; uModel uniform so the shader knows their world position.
; =============================================================================
%define MODULE_RENDER
%include "common.inc"

; GL 2.0 functions are called through pointers from SDL_GL_GetProcAddress.
; On Windows those pointers use the Microsoft calling convention, so they go
; through thunks too (sv_p_glXxx in win64_thunks.asm).
%ifdef WIN64
%macro GL2CALL 1
    call sv_p_%1
%endmacro
%macro GL2JMP 1
    jmp sv_p_%1
%endmacro
extern sv_p_glCreateShader, sv_p_glShaderSource, sv_p_glCompileShader, sv_p_glGetShaderiv
extern sv_p_glGetShaderInfoLog, sv_p_glCreateProgram, sv_p_glAttachShader, sv_p_glLinkProgram
extern sv_p_glUseProgram, sv_p_glGetUniformLocation, sv_p_glUniform1f, sv_p_glUniform1i
extern sv_p_glUniform3f, sv_p_glUniform3fv, sv_p_glUniformMatrix4fv, sv_p_glGetProgramInfoLog
extern sv_p_glGenFramebuffers, sv_p_glBindFramebuffer, sv_p_glFramebufferTexture2D
extern sv_p_glCheckFramebufferStatus, sv_p_glActiveTexture
%else
%macro GL2CALL 1
    call [p_%1]
%endmacro
%macro GL2JMP 1
    jmp [p_%1]
%endmacro
%endif
global p_glCreateShader, p_glShaderSource, p_glCompileShader, p_glGetShaderiv
global p_glGetShaderInfoLog, p_glCreateProgram, p_glAttachShader, p_glLinkProgram
global p_glUseProgram, p_glGetUniformLocation, p_glUniform1f, p_glUniform1i
global p_glUniform3f, p_glUniform3fv, p_glUniformMatrix4fv, p_glGetProgramInfoLog
global p_glGenFramebuffers, p_glBindFramebuffer, p_glFramebufferTexture2D
global p_glCheckFramebufferStatus, p_glActiveTexture, shadows_on, render_toggle_shadows, dump_shadow_map

global render_init, render_frame, world_lights_update, fixtures, fixture_count
global b_pos_x, b_pos_y, b_pos_z, b_floor, y_pos_x, y_pos_z, render_jumpscare
global draw_scene, use_program, upload_frame_uniforms, bind, cam_x, cam_y, cam_z, cur_floor
global lightning, save_screenshot, choose_render_scale, render_cycle_scale, render_scale, shadows_ok

extern glPushMatrix, glPopMatrix, glMultMatrixf, glDeleteLists, glCopyTexSubImage2D, glGetString, getenv, strstr
extern glLoadMatrixf, glColorMask, glPolygonOffset, glDrawBuffer, glReadBuffer
extern portal_views, portal_draw_rims, draw_viewmodel, media_tex
global render_rebuild_world, set_material, set_emit, model_end, u_model, u_fpos, u_fdir, u_flash, u_son
extern phys_nb, px, py, pz, body_type, body_p0, body_active, rag_active, prop_tex
%define GL_RENDERER 0x1F01
%define SHADOW_SIZE 1024
%define GL_DEPTH_COMPONENT 0x1902
%define GL_DEPTH_COMPONENT24 0x81A6
%define GL_UNSIGNED_INT 0x1405
%define GL_FRAMEBUFFER 0x8D40
%define GL_DEPTH_ATTACHMENT 0x8D00
%define GL_FRAMEBUFFER_COMPLETE 0x8CD5
%define GL_POLYGON_OFFSET_FILL 0x8037
%define GL_TEXTURE0 0x84C0
%define GL_TEXTURE1 0x84C1
extern sign_count, sign_f, sign_x, sign_z, sign_face, sign_exit, sign_set, sign_set_cur
extern p_eye_y, p_roll, player_floor, t_moving


; texture slots (same as textures.asm)
%define TX_H       0
%define TX_C       1
%define TX_G       2
%define TX_L       3
%define TX_N       4
%define TX_CONC    5
%define TX_FLOOR   6
%define TX_FLOOR_B 7
%define TX_FLOOR_S 8
%define TX_CEIL    9
%define TX_CEIL_B  10
%define TX_RACK    11

; materials = display lists per storey. Each has a texture (see mat_tex).
%define M_H       0
%define M_C       1
%define M_G       2
%define M_L       3
%define M_N       4
%define M_CONC    5
%define M_FLOOR   6
%define M_FLOOR_B 7
%define M_FLOOR_S 8
%define M_CEIL    9
%define M_CEIL_B  10
%define M_RACK    11
%define M_WHITE   12          ; vertex-coloured props
%define M_LED     13          ; unlit: rack LEDs
%define M_SCREEN  14          ; unlit: monitors left on
%define M_GLASS   15          ; see-through walls, drawn last with blending
%define NMAT      16
%define NLIT      13          ; materials 0..12 go through the shader

%define MAX_FIX   900
%define NPOOL     6
; fixture states
%define FX_DEAD    0
%define FX_ON      1
%define FX_FLICKER 2
%define FX_EXIT    3
%define FX_AURA    4

; face mask bits for emit_box
%define F_PX 1
%define F_NX 2
%define F_PY 4
%define F_NY 8
%define F_PZ 16
%define F_NZ 32
%define F_ALL 63

; call a GL function that takes 3 or 4 float literals
%macro GLF3 4
    FLD xmm0, %2
    FLD xmm1, %3
    FLD xmm2, %4
    call %1
%endmacro
%macro GLF4 5
    FLD xmm0, %2
    FLD xmm1, %3
    FLD xmm2, %4
    FLD xmm3, %5
    call %1
%endmacro
; set the box extents from float literals
%macro BOX 6
    mov dword [bx0], __float32__(%1)
    mov dword [by0], __float32__(%2)
    mov dword [bz0], __float32__(%3)
    mov dword [bx1], __float32__(%4)
    mov dword [by1], __float32__(%5)
    mov dword [bz1], __float32__(%6)
%endmacro

section .data
; ---- GLSL -----------------------------------------------------------------
vs_src:
    db "#version 120",10
    db "uniform mat4 uModel;",10
    db "varying vec3 vW; varying vec3 vN; varying vec2 vUV; varying vec4 vC;",10
    db "void main(){",10
    db "  vec4 w = uModel * gl_Vertex;",10
    db "  vW = w.xyz;",10
    db "  vN = mat3(uModel) * gl_Normal;",10
    db "  vUV = gl_MultiTexCoord0.xy;",10
    db "  vC = gl_Color;",10
    db "  gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;",10
    db "  gl_ClipVertex = gl_ModelViewMatrix * gl_Vertex;",10     ; portal clip plane
    db "}",10,0
; two fragment programs share this body: program 0 (the world) has no
; alpha test, program 1 (T's face) does. A shader that can discard stops a
; software rasteriser from rejecting hidden pixels early, so the world must
; not pay for it.
fs_head0: db "#version 120",10,0
fs_head1: db "#version 120",10,"#define ALPHA_TEST",10,0
empty_str: db 0
fs_src:
    db "uniform sampler2D uTex;",10
    db "uniform sampler2D uShadow;",10
    db "uniform mat4 uShadowMat;",10
    db "uniform vec3 uCam; uniform vec3 uFlashPos; uniform vec3 uFlashDir; uniform vec3 uAmb;",10
    db "uniform float uFlash; uniform float uEmit; uniform float uFog;",10
    db "uniform float uBump; uniform float uSpec; uniform float uShadowOn;",10
    db "uniform vec3 uLP[6]; uniform vec3 uLC[6];",10
    db "varying vec3 vW; varying vec3 vN; varying vec2 vUV; varying vec4 vC;",10
    db "float lum(vec2 uv) { return dot(texture2D(uTex, uv).rgb, vec3(0.299, 0.587, 0.114)); }",10
    db "vec3 bump(vec3 N, float s) {",10
    db "  vec3 dpx = dFdx(vW); vec3 dpy = dFdy(vW);",10
    db "  float h0 = lum(vUV);",10
    db "  float dbx = lum(vUV + dFdx(vUV)) - h0;",10
    db "  float dby = lum(vUV + dFdy(vUV)) - h0;",10
    db "  vec3 r1 = cross(dpy, N); vec3 r2 = cross(N, dpx);",10
    db "  float det = dot(dpx, r1);",10
    db "  vec3 g = sign(det) * (dbx * r1 + dby * r2);",10
    db "  return normalize(abs(det) * N - s * g);",10
    db "}",10
    db "float shadow() {",10
    db "  vec4 sc = uShadowMat * vec4(vW, 1.0);",10
    db "  if (sc.w <= 0.0) return 1.0;",10
    db "  vec3 p = sc.xyz / sc.w * 0.5 + 0.5;",10
    db "  if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0 || p.z > 1.0) return 1.0;",10
    db "  float lit = 0.0;",10
    db "  for (int x = -1; x <= 1; x++)",10
    db "    for (int y = -1; y <= 1; y++)",10
    db "      lit += (p.z - 0.0015 > texture2D(uShadow, p.xy + vec2(float(x), float(y)) / 1024.0).r) ? 0.0 : 1.0;",10
    db "  return lit / 9.0;",10
    db "}",10
    db "void main(){",10
    db "  vec4 t = texture2D(uTex, vUV) * vC;",10
    db "#ifdef ALPHA_TEST",10
    db "  if (t.a < 0.08) discard;",10
    db "#endif",10
    db "  vec3 N = normalize(vN);",10
    db "  vec3 toCam = uCam - vW; float dc = length(toCam); vec3 V = toCam / max(dc, 0.001);",10
    db "  if (dot(N, V) < 0.0) N = -N;",10
    db "  if (uBump > 0.0) N = bump(N, uBump);",10
    db "  float shin = 12.0 + 60.0 * uSpec;",10
    db "  vec3 light = uAmb;",10
    db "  vec3 spec = vec3(0.0);",10
    db "  vec3 Lf = uFlashPos - vW; float df = length(Lf); Lf /= max(df, 0.001);",10
    db "  float cosA = dot(-Lf, uFlashDir);",10
    db "  float spot = smoothstep(0.88, 0.96, cosA) + 0.3 * smoothstep(0.72, 0.88, cosA);",10
    db "  if (spot > 0.0 && uFlash > 0.0) {",10
    db "    float sh = uShadowOn > 0.5 ? shadow() : 1.0;",10
    db "    vec3 fc = vec3(1.0, 0.94, 0.84) * uFlash * spot * sh * 7.0 / (1.0 + 0.22 * df * df);",10
    db "    light += fc * max(dot(N, Lf), 0.0);",10
    db "    spec += fc * uSpec * pow(max(dot(N, normalize(Lf + V)), 0.0), shin);",10
    db "  }",10
    db "  for (int i = 0; i < 6; i++) {",10
    db "    vec3 L = uLP[i] - vW; float d = length(L); L /= max(d, 0.001);",10
    db "    float att = clamp(1.0 - d / 14.0, 0.0, 1.0) / (1.0 + 0.35 * d * d);",10
    db "    light += uLC[i] * att * (0.3 + 0.7 * max(dot(N, L), 0.0));",10
    db "    spec += uLC[i] * att * uSpec * pow(max(dot(N, normalize(L + V)), 0.0), shin);",10
    db "  }",10
    db "  vec3 c = t.rgb * (light + uEmit) + spec;",10
    db "  c = vec3(1.0) - exp(-c * 1.4);",10
    db "  float fog = exp(-pow(uFog * dc, 2.0));",10
    db "  gl_FragColor = vec4(mix(vec3(0.008, 0.008, 0.012), c, fog), t.a);",10
    db "}",10
    db 0


err_shader  db "GLSL error: %s",10,0
err_gl2     db "OpenGL 2.0 shaders are not available (need a GL 2.0+ driver).",10,0

; names of the GL 2.0 entry points we fetch with SDL_GL_GetProcAddress
n_CreateShader       db "glCreateShader",0
n_ShaderSource       db "glShaderSource",0
n_CompileShader      db "glCompileShader",0
n_GetShaderiv        db "glGetShaderiv",0
n_GetShaderInfoLog   db "glGetShaderInfoLog",0
n_CreateProgram      db "glCreateProgram",0
n_AttachShader       db "glAttachShader",0
n_LinkProgram        db "glLinkProgram",0
n_UseProgram         db "glUseProgram",0
n_GetUniformLocation db "glGetUniformLocation",0
n_Uniform1f          db "glUniform1f",0
n_Uniform1i          db "glUniform1i",0
n_Uniform3f          db "glUniform3f",0
n_Uniform3fv         db "glUniform3fv",0
n_UniformMatrix4fv   db "glUniformMatrix4fv",0
n_GetProgramInfoLog  db "glGetProgramInfoLog",0
align 8
gl2_names   dq n_CreateShader, n_ShaderSource, n_CompileShader, n_GetShaderiv
            dq n_GetShaderInfoLog, n_CreateProgram, n_AttachShader, n_LinkProgram
            dq n_UseProgram, n_GetUniformLocation, n_Uniform1f, n_Uniform1i
            dq n_Uniform3f, n_Uniform3fv, n_UniformMatrix4fv, n_GetProgramInfoLog
%define NGL2 16

u_names:
un_model  db "uModel",0
un_tex    db "uTex",0
un_cam    db "uCam",0
un_fdir   db "uFlashDir",0
un_amb    db "uAmb",0
un_flash  db "uFlash",0
un_emit   db "uEmit",0
un_fog    db "uFog",0
un_lp     db "uLP",0
un_lc     db "uLC",0
un_fpos   db "uFlashPos",0
un_bump   db "uBump",0
un_spec   db "uSpec",0
un_smat   db "uShadowMat",0
un_stex   db "uShadow",0
un_son    db "uShadowOn",0
align 8
u_name_ptrs dq un_model, un_tex, un_cam, un_fdir, un_amb, un_flash, un_emit, un_fog, un_lp, un_lc
            dq un_fpos, un_bump, un_spec, un_smat, un_stex, un_son
%define NUNI 16

; face table for emit_box: normal, then 4 corner codes (bit0 = x1, bit1 = y1,
; bit2 = z1). Corners run top-left, top-right, bottom-right, bottom-left as
; seen from outside, so texture v=0 is the top of every wall.
face_norm   dd 1.0,0.0,0.0,  -1.0,0.0,0.0,  0.0,1.0,0.0,  0.0,-1.0,0.0,  0.0,0.0,1.0,  0.0,0.0,-1.0
face_corner db 7,3,1,5,  2,6,4,0,  2,3,7,6,  4,5,1,0,  6,7,5,4,  3,2,0,1
corner_u    dd 0.0, 1.0, 1.0, 0.0
corner_v    dd 0.0, 0.0, 1.0, 1.0

; material -> texture slot (M_WHITE/M_SCREEN use white_tex, M_LED led_tex)
mat_tex     dd TX_H, TX_C, TX_G, TX_L, TX_N, TX_CONC, TX_FLOOR, TX_FLOOR_B, TX_FLOOR_S
            dd TX_CEIL, TX_CEIL_B, TX_RACK, -1, -2, -1, -1

identity    dd 1.0,0.0,0.0,0.0, 0.0,1.0,0.0,0.0, 0.0,0.0,1.0,0.0, 0.0,0.0,0.0,1.0
; T's ragdoll as drawn: torso, neck, arms, legs (particle pairs) and widths
rag_draw    dd 1,2, 0,1, 1,3, 1,4, 2,5, 2,6
rag_width   dd 0.2, 0.05, 0.06, 0.06, 0.08, 0.08
%define RAG_DRAW_BONES 6
; pickups: half-size of the spinning box, and the colour of the glow under it
;              capture deauth map   compass portal
item_half_x dd 0.21,   0.25,  0.26,  0.17,   0.28,   0.30,  0.10
item_half_y dd 0.21,   0.15,  0.04,  0.06,   0.12,   0.08,  0.17
item_half_z dd 0.21,   0.15,  0.19,  0.17,   0.12,   0.10,  0.10
item_glow   dd 0.16,0.66,1.0,  1.0,0.12,0.12,  1.0,0.85,0.4,  1.0,0.75,0.2,  1.0,0.55,0.15,  0.45,1.0,0.35,  0.6,1.0,0.2
; per material: bump strength (texture brightness read as height) and shine
;              H    C    G    L    N    #    floor flrB flrS ceil ceilB rack white
mat_bump    dd 0.55,0.25,0.2, 0.5, 0.4, 0.5, 0.35,0.5, 0.35,0.3, 0.5, 0.4, 0.0
mat_spec    dd 0.12,0.1, 0.25,0.05,0.3, 0.05,0.8, 0.35,0.8, 0.0, 0.0, 0.6, 0.15
c_up        dd 0.0, 1.0, 0.0
c_flash_right dd 0.22                    ; the flashlight is in your right hand...
c_flash_down  dd -0.25                   ; ...a little below your eyes
c_shadow_fov  dd 1.5708                  ; 90 degree shadow frustum covers the beam
c_shadow_near dd 0.1
c_shadow_far  dd 30.0
c_poly_factor dd 1.5
c_poly_units  dd 3.0
env_shadows db "BEACOM_SHADOWS",0
n_GenFramebuffers  db "glGenFramebuffers",0
n_BindFramebuffer  db "glBindFramebuffer",0
n_FramebufferTex2D db "glFramebufferTexture2D",0
n_CheckFBStatus    db "glCheckFramebufferStatus",0
n_ActiveTexture    db "glActiveTexture",0
align 8
fbo_names   dq n_GenFramebuffers, n_BindFramebuffer, n_FramebufferTex2D, n_CheckFBStatus, n_ActiveTexture
fog_color   dd 0.008, 0.008, 0.012, 1.0

c_near      dq 0.05
c_far       dq 45.0                  ; exp2 fog is fully opaque by ~40 units
fovtan_cur  dq 0.7265425            ; tan(fov/2) -- 72 degree vertical FOV by default
c_half_deg  dd 0.00872664626        ; pi / 360: degrees -> half-angle radians
c_fog       dd 0.055
c_amb_r     dd 0.043
c_amb_g     dd 0.050
c_amb_b     dd 0.062
c_amb_base  dd 0.9                  ; ambient multiplier upstairs
c_amb_basem dd 0.6                  ; ...in the basement
c_light_on  dd 2.4
c_light_exit dd 0.45
c_light_aura dd 3.0
c_pool_dist dd 1024.0               ; 32^2
c_ywt       dd 16.0                 ; vertical distance counts x4 (squared x16)
c_flick_a   dd 13.0
c_flick_b   dd 7.3
c_flick_c   dd 1.7
c_flick_hi  dd 0.4
c_flick_mid dd 0.1
c_flick_m   dd 0.3
c_flick_lo  dd 0.02
c_exit_lvl  dd 0.6
c_fix_off   dd 0.35
c_n_emit    dd 0.3
c_n_pulse   dd 0.12
c_rack_emit dd 0.05
c_sign_emit dd 0.08
c_face_emit dd 0.16
c_face_chase dd 0.6
c_item_emit dd 0.9
c_hundred   dd 100.0
c_fix_dead  dd 0.09
c_led_a     dd 0.75
c_led_b     dd 0.25
c_led_speed dd 9.0
c_step_d    dd 1.0

section .bss
alignb 8
gl2_ptrs:
p_glCreateShader       resq 1
p_glShaderSource       resq 1
p_glCompileShader      resq 1
p_glGetShaderiv        resq 1
p_glGetShaderInfoLog   resq 1
p_glCreateProgram      resq 1
p_glAttachShader       resq 1
p_glLinkProgram        resq 1
p_glUseProgram         resq 1
p_glGetUniformLocation resq 1
p_glUniform1f          resq 1
p_glUniform1i          resq 1
p_glUniform3f          resq 1
p_glUniform3fv         resq 1
p_glUniformMatrix4fv   resq 1
p_glGetProgramInfoLog  resq 1
uni:
u_model resd 1
u_tex   resd 1
u_cam   resd 1
u_fdir  resd 1
u_amb   resd 1
u_flash resd 1
u_emit  resd 1
u_fog   resd 1
u_lp    resd 1
u_lc    resd 1
u_fpos  resd 1
u_bump  resd 1
u_spec  resd 1
u_smat  resd 1
u_stex  resd 1
u_son   resd 1
program resd 1
list_base resd 1
info_log  resb 1024
src_ptr   resq 2
programs  resd 2
uni_tab   resd NUNI*2               ; uniform locations of both programs
cur_prog  resd 1
amb_col   resd 3

; box being emitted (world or model space)
bx0 resd 1
by0 resd 1
bz0 resd 1
bx1 resd 1
by1 resd 1
bz1 resd 1
u_rep resd 1                        ; texture repeats across a face
v_rep resd 1

; fixtures (ceiling panels, exit signs, B's aura): struct of arrays
fixture_count resd 1
fixtures:
fx_x     resd MAX_FIX
fx_y     resd MAX_FIX
fx_z     resd MAX_FIX
fx_f     resd MAX_FIX
fx_state resd MAX_FIX
fx_r     resd MAX_FIX
fx_g     resd MAX_FIX
fx_b     resd MAX_FIX
fx_phase resd MAX_FIX
fx_level resd MAX_FIX               ; brightness this frame (0..1)
pool_idx resd NPOOL                 ; fixture index per pooled light (-1 none)
pool_timer resd 1
lp_buf   resd NPOOL*3               ; uniform uploads
lc_buf   resd NPOOL*3
model_mat resd 16
lightning resd 1                    ; 0..1 lightning flash (set by main.asm)
; flashlight shadow map
alignb 8
fbo_ptrs:
p_glGenFramebuffers       resq 1
p_glBindFramebuffer       resq 1
p_glFramebufferTexture2D  resq 1
p_glCheckFramebufferStatus resq 1
p_glActiveTexture         resq 1
shadow_fbo  resd 1
shadow_tex  resd 1
shadows_ok  resd 1
shadows_on  resd 1
flash_pos   resd 3
light_view  resd 16
light_proj  resd 16
shadow_mat  resd 16

b_pos_x resd 1
b_pos_y resd 1
b_pos_z resd 1
b_floor resd 1
y_pos_x resd 1
y_pos_z resd 1
y_found resd 1
cam_x   resd 1
cam_y   resd 1
cam_z   resd 1
fdir    resd 3
cur_floor resd 1
shot_buf resb 1920*1200*4
render_scale resd 1
lowres_tex resd 1
lowres_w resd 1
lowres_h resd 1

section .text

; =============================================================================
; little emitters (call between glBegin(GL_QUADS) and glEnd)
; =============================================================================

; emit_box(edi=face mask) -- axis-aligned box from bx0..bz1, textured 0..1
; (times u_rep/v_rep) on each face
emit_box:
    PROLOGUE 32
    mov r12d, edi
    xor ebx, ebx                        ; face
.face:
    cmp ebx, 6
    jge .done
    bt r12d, ebx
    jnc .next
    imul eax, ebx, 12
    lea r13, [face_norm+rax]
    movss xmm0, [r13]
    movss xmm1, [r13+4]
    movss xmm2, [r13+8]
    call glNormal3f
    xor r14d, r14d                      ; corner
.corner:
    cmp r14d, 4
    jge .next
    movss xmm0, [corner_u+r14*4]
    mulss xmm0, [u_rep]
    movss xmm1, [corner_v+r14*4]
    mulss xmm1, [v_rep]
    call glTexCoord2f
    lea eax, [rbx*4+r14]
    movzx eax, byte [face_corner+rax]
    movss xmm0, [bx0]
    test eax, 1
    jz .cx
    movss xmm0, [bx1]
.cx:
    movss xmm1, [by0]
    test eax, 2
    jz .cy
    movss xmm1, [by1]
.cy:
    movss xmm2, [bz0]
    test eax, 4
    jz .cz
    movss xmm2, [bz1]
.cz:
    call glVertex3f
    inc r14d
    jmp .corner
.next:
    inc ebx
    jmp .face
.done:
    EPILOGUE

; box_at(xmm0=cx, xmm1=y0, xmm2=cz, xmm3=half x, xmm4=height, xmm5=half z)
; sets bx0..bz1 for a box standing on y0. leaf.
box_at:
    movaps xmm6, xmm0
    subss xmm6, xmm3
    movss [bx0], xmm6
    addss xmm0, xmm3
    movss [bx1], xmm0
    movss [by0], xmm1
    addss xmm1, xmm4
    movss [by1], xmm1
    movaps xmm6, xmm2
    subss xmm6, xmm5
    movss [bz0], xmm6
    addss xmm2, xmm5
    movss [bz1], xmm2
    ret

; cbox(xmm0..5 as box_at, edi=colour 0xRRGGBB) -- a vertex-coloured full box
cbox:
    PROLOGUE 16
    mov ebx, edi
    call box_at
    call set_rgb
    mov edi, F_ALL
    call emit_box
    EPILOGUE

; set_rgb(ebx=0xRRGGBB) -- glColor3f from a packed colour
set_rgb:
    sub rsp, 8
    FLD xmm3, 255.0
    mov eax, ebx
    shr eax, 16
    and eax, 255
    cvtsi2ss xmm0, eax
    divss xmm0, xmm3
    mov eax, ebx
    shr eax, 8
    and eax, 255
    cvtsi2ss xmm1, eax
    divss xmm1, xmm3
    mov eax, ebx
    and eax, 255
    cvtsi2ss xmm2, eax
    divss xmm2, xmm3
    call glColor3f
    add rsp, 8
    ret

; emit_cyl(xmm0=cx, xmm1=y0, xmm2=cz, xmm3=bottom radius, xmm4=top radius,
;          xmm5=height, edi=segments) -- side of a (tapered) cylinder
emit_cyl:
    PROLOGUE 64
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    movss [rsp+16], xmm4
    movss [rsp+20], xmm5
    mov r12d, edi
    xor ebx, ebx
.seg:
    cmp ebx, r12d
    jge .done
    ; angles a0, a1 -> cos/sin
    cvtsi2ss xmm0, ebx
    mulss xmm0, [c_two_pi]
    cvtsi2ss xmm1, r12d
    divss xmm0, xmm1
    movss [rsp+24], xmm0
    call cosf
    movss [rsp+28], xmm0                ; c0
    movss xmm0, [rsp+24]
    call sinf
    movss [rsp+32], xmm0                ; s0
    lea eax, [rbx+1]
    cvtsi2ss xmm0, eax
    mulss xmm0, [c_two_pi]
    cvtsi2ss xmm1, r12d
    divss xmm0, xmm1
    movss [rsp+24], xmm0
    call cosf
    movss [rsp+36], xmm0                ; c1
    movss xmm0, [rsp+24]
    call sinf
    movss [rsp+40], xmm0                ; s1
    ; normal at the middle of the segment
    movss xmm0, [rsp+28]
    addss xmm0, [rsp+36]
    mulss xmm0, [c_half]
    xorps xmm1, xmm1
    movss xmm2, [rsp+32]
    addss xmm2, [rsp+40]
    mulss xmm2, [c_half]
    call glNormal3f
    ; 4 vertices: bottom0, bottom1, top1, top0
    mov r13d, 0
.v:
    cmp r13d, 4
    jge .next
    ; which angle: 0,3 -> a0 ; 1,2 -> a1
    movss xmm6, [rsp+28]
    movss xmm7, [rsp+32]
    cmp r13d, 1
    je .a1
    cmp r13d, 2
    jne .have_a
.a1:
    movss xmm6, [rsp+36]
    movss xmm7, [rsp+40]
.have_a:
    ; radius / height: 0,1 bottom ; 2,3 top
    movss xmm5, [rsp+12]
    movss xmm4, [rsp+4]
    cmp r13d, 2
    jl .bottom
    movss xmm5, [rsp+16]
    addss xmm4, [rsp+20]
.bottom:
    mulss xmm6, xmm5
    addss xmm6, [rsp+0]
    mulss xmm7, xmm5
    addss xmm7, [rsp+8]
    movss [rsp+44], xmm6
    movss [rsp+48], xmm4
    movss [rsp+52], xmm7
    cvtsi2ss xmm0, ebx
    cvtsi2ss xmm1, r12d
    divss xmm0, xmm1
    xorps xmm1, xmm1
    cmp r13d, 2
    jl .tc
    movss xmm1, [c_one]
.tc:
    call glTexCoord2f
    movss xmm0, [rsp+44]
    movss xmm1, [rsp+48]
    movss xmm2, [rsp+52]
    call glVertex3f
    inc r13d
    jmp .v
.next:
    inc ebx
    jmp .seg
.done:
    EPILOGUE

; emit_limb(xmm0=top x, xmm1=top y, xmm2=top z, xmm3=bottom x, xmm4=bottom y,
;           xmm5=bottom z, xmm6=half width) -- 4-sided prism between two points
emit_limb:
    PROLOGUE 48
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    movss [rsp+16], xmm4
    movss [rsp+20], xmm5
    movss [rsp+24], xmm6
    ; sides: (+x), (-x), (+z), (-z). For each: two top corners, two bottom.
    xor ebx, ebx
.side:
    cmp ebx, 4
    jge .done
    ; normal
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    xorps xmm2, xmm2
    cmp ebx, 0
    jne .n1
    movss xmm0, [c_one]
.n1:
    cmp ebx, 1
    jne .n2
    movss xmm0, [c_neg_one]
.n2:
    cmp ebx, 2
    jne .n3
    movss xmm2, [c_one]
.n3:
    cmp ebx, 3
    jne .n4
    movss xmm2, [c_neg_one]
.n4:
    call glNormal3f
    xor r12d, r12d
.corner:
    cmp r12d, 4
    jge .next_side
    ; offsets: the side's fixed axis is +/-w; the other axis runs -w..+w
    movss xmm7, [rsp+24]                ; w
    movaps xmm6, xmm7                   ; along = +w for corners 0,3 ; -w for 1,2
    cmp r12d, 1
    je .neg
    cmp r12d, 2
    jne .pos
.neg:
    xorps xmm6, [c_sign_mask]
.pos:
    ; top (0,1) or bottom (2,3)
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+8]
    cmp r12d, 2
    jl .top
    movss xmm0, [rsp+12]
    movss xmm1, [rsp+16]
    movss xmm2, [rsp+20]
.top:
    cmp ebx, 2
    jge .zside
    ; x side: x += +/-w, z += along
    movaps xmm5, xmm7
    cmp ebx, 0
    je .xs
    xorps xmm5, [c_sign_mask]
.xs:
    addss xmm0, xmm5
    addss xmm2, xmm6
    jmp .emit
.zside:
    movaps xmm5, xmm7
    cmp ebx, 2
    je .zs
    xorps xmm5, [c_sign_mask]
.zs:
    addss xmm2, xmm5
    addss xmm0, xmm6
.emit:
    call glVertex3f
    inc r12d
    jmp .corner
.next_side:
    inc ebx
    jmp .side
.done:
    EPILOGUE

; emit_ring(xmm0=cx, xmm1=y, xmm2=cz, xmm3=radius, xmm4=width) -- flat annulus
emit_ring:
    PROLOGUE 48
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    movss [rsp+16], xmm4
    xor ebx, ebx
.seg:
    cmp ebx, 40
    jge .done
    xor r12d, r12d
.v:
    cmp r12d, 4
    jge .next
    ; angle index: 0,3 -> i ; 1,2 -> i+1 ; radius: 0,1 inner ; 2,3 outer
    mov eax, ebx
    cmp r12d, 1
    je .i1
    cmp r12d, 2
    jne .i0
.i1:
    inc eax
.i0:
    cvtsi2ss xmm0, eax
    mulss xmm0, [c_two_pi]
    FLD xmm1, 40.0
    divss xmm0, xmm1
    movss [rsp+20], xmm0
    call cosf
    movss [rsp+24], xmm0
    movss xmm0, [rsp+20]
    call sinf
    movss xmm5, [rsp+12]
    cmp r12d, 2
    jl .inner
    addss xmm5, [rsp+16]
.inner:
    mulss xmm0, xmm5
    addss xmm0, [rsp+8]
    movss [rsp+28], xmm0                ; z
    movss xmm0, [rsp+24]
    mulss xmm0, xmm5
    addss xmm0, [rsp+0]                 ; x
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+28]
    call glVertex3f
    inc r12d
    jmp .v
.next:
    inc ebx
    jmp .seg
.done:
    EPILOGUE

; =============================================================================
; model matrix: translate + rotate about Y. Used for everything that moves.
; =============================================================================

; model_begin(xmm0=x, xmm1=y, xmm2=z, xmm3=yaw)
model_begin:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    movaps xmm0, xmm3
    call cosf
    movss [rsp+16], xmm0
    movss xmm0, [rsp+12]
    call sinf
    ; column-major: col0=(c,0,-s,0) col1=(0,1,0,0) col2=(s,0,c,0) col3=(x,y,z,1)
    lea rdi, [model_mat]
    movss xmm1, [rsp+16]
    movss [rdi+0], xmm1
    mov dword [rdi+4], 0
    movaps xmm2, xmm0
    xorps xmm2, [c_sign_mask]
    movss [rdi+8], xmm2
    mov dword [rdi+12], 0
    mov dword [rdi+16], 0
    mov eax, [c_one]
    mov [rdi+20], eax
    mov dword [rdi+24], 0
    mov dword [rdi+28], 0
    movss [rdi+32], xmm0
    mov dword [rdi+36], 0
    movss [rdi+40], xmm1
    mov dword [rdi+44], 0
    mov eax, [rsp+0]
    mov [rdi+48], eax
    mov eax, [rsp+4]
    mov [rdi+52], eax
    mov eax, [rsp+8]
    mov [rdi+56], eax
    mov eax, [c_one]
    mov [rdi+60], eax
    call glPushMatrix
    lea rdi, [model_mat]
    call glMultMatrixf
    mov edi, [u_model]
    mov esi, 1
    xor edx, edx
    lea rcx, [model_mat]
    GL2CALL glUniformMatrix4fv
    EPILOGUE

model_end:
    sub rsp, 8
    call glPopMatrix
    mov edi, [u_model]
    mov esi, 1
    xor edx, edx
    lea rcx, [identity]
    GL2CALL glUniformMatrix4fv
    add rsp, 8
    ret

; use_program(edi=0 world / 1 alpha-tested) -- glUseProgram + make its
; uniform locations the current ones (u_model, u_emit, ... below)
use_program:
    PROLOGUE 16
    mov [cur_prog], edi
    mov ebx, edi
    mov edi, [programs+rbx*4]
    GL2CALL glUseProgram
    imul eax, ebx, NUNI
    lea rsi, [uni_tab+rax*4]
    lea rdi, [uni]
    mov ecx, NUNI
    rep movsd
    EPILOGUE

; set_material(xmm0=bump strength, xmm1=shine) -- current program
set_material:
    PROLOGUE 16
    cmp dword [render_scale], 1
    je .full
    xorps xmm0, xmm0                    ; software GL: bump mapping costs too much
.full:
    movss [rsp+0], xmm1
    mov edi, [u_bump]
    GL2CALL glUniform1f
    mov edi, [u_spec]
    movss xmm0, [rsp+0]
    GL2CALL glUniform1f
    EPILOGUE

; =============================================================================
; 4x4 matrices (column-major, like OpenGL) for the flashlight's shadow camera
; =============================================================================

; dot3(rdi=a, rsi=b) -> xmm0.  leaf
dot3:
    movss xmm0, [rdi]
    mulss xmm0, [rsi]
    movss xmm1, [rdi+4]
    mulss xmm1, [rsi+4]
    addss xmm0, xmm1
    movss xmm1, [rdi+8]
    mulss xmm1, [rsi+8]
    addss xmm0, xmm1
    ret

; cross3(rdi=out, rsi=a, rdx=b).  leaf
cross3:
    movss xmm0, [rsi+4]
    mulss xmm0, [rdx+8]
    movss xmm1, [rsi+8]
    mulss xmm1, [rdx+4]
    subss xmm0, xmm1
    movss [rdi], xmm0
    movss xmm0, [rsi+8]
    mulss xmm0, [rdx]
    movss xmm1, [rsi]
    mulss xmm1, [rdx+8]
    subss xmm0, xmm1
    movss [rdi+4], xmm0
    movss xmm0, [rsi]
    mulss xmm0, [rdx+4]
    movss xmm1, [rsi+4]
    mulss xmm1, [rdx]
    subss xmm0, xmm1
    movss [rdi+8], xmm0
    ret

; normalize3(rdi=v, in place).  leaf
normalize3:
    mov rsi, rdi
    call dot3
    sqrtss xmm0, xmm0
    FLD xmm1, 0.000001
    maxss xmm0, xmm1
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

; mat_lookat(rdi=out, rsi=eye, rdx=forward) -- view matrix with world up = +Y
;   rows: s = normalize(f x up), u = s x f, -f ; translation -(s.e, u.e, -f.e)
mat_lookat:
    PROLOGUE 64
    ; [rsp+0] f  [rsp+16] s  [rsp+32] u
    mov r12, rdi
    mov r13, rsi
    mov eax, [rdx]
    mov [rsp+0], eax
    mov eax, [rdx+4]
    mov [rsp+4], eax
    mov eax, [rdx+8]
    mov [rsp+8], eax
    lea rdi, [rsp+0]
    call normalize3
    lea rdi, [rsp+16]
    lea rsi, [rsp+0]
    lea rdx, [c_up]
    call cross3
    lea rdi, [rsp+16]
    call normalize3
    lea rdi, [rsp+32]
    lea rsi, [rsp+16]
    lea rdx, [rsp+0]
    call cross3
    ; column-major: element (row r, column c) lives at out[c*4 + r]
    xor ecx, ecx                        ; c = x, y, z component
.col:
    cmp ecx, 3
    jge .trans
    mov eax, ecx
    shl eax, 4                          ; column c starts at byte c*16
    mov r8d, [rsp+16+rcx*4]
    mov [r12+rax], r8d                  ; row 0 = s
    mov r8d, [rsp+32+rcx*4]
    mov [r12+rax+4], r8d                ; row 1 = u
    movss xmm0, [rsp+0+rcx*4]
    xorps xmm0, [c_sign_mask]
    movss [r12+rax+8], xmm0             ; row 2 = -f
    mov dword [r12+rax+12], 0           ; row 3 = 0
    inc ecx
    jmp .col
.trans:
    lea rdi, [rsp+16]
    mov rsi, r13
    call dot3
    xorps xmm0, [c_sign_mask]
    movss [r12+48], xmm0
    lea rdi, [rsp+32]
    mov rsi, r13
    call dot3
    xorps xmm0, [c_sign_mask]
    movss [r12+52], xmm0
    lea rdi, [rsp+0]
    mov rsi, r13
    call dot3
    movss [r12+56], xmm0
    mov eax, [c_one]
    mov [r12+60], eax
    EPILOGUE

; mat_perspective(rdi=out, xmm0=fovy radians, xmm1=aspect, xmm2=near, xmm3=far)
mat_perspective:
    PROLOGUE 32
    mov r12, rdi
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    mulss xmm0, [c_half]
    call tanf
    movss xmm1, [c_one]
    divss xmm1, xmm0
    movss [rsp+0], xmm1                 ; f = 1/tan(fovy/2)
    mov rdi, r12
    xor eax, eax
    mov ecx, 16
    rep stosd
    movss xmm0, [rsp+0]
    divss xmm0, [rsp+4]
    movss [r12+0], xmm0
    movss xmm0, [rsp+0]
    movss [r12+20], xmm0
    movss xmm0, [rsp+12]
    addss xmm0, [rsp+8]
    movss xmm1, [rsp+8]
    subss xmm1, [rsp+12]
    divss xmm0, xmm1
    movss [r12+40], xmm0                ; (far+near)/(near-far)
    mov eax, [c_neg_one]
    mov [r12+44], eax
    movss xmm0, [rsp+12]
    mulss xmm0, [rsp+8]
    addss xmm0, xmm0
    divss xmm0, xmm1
    movss [r12+56], xmm0                ; 2*far*near/(near-far)
    EPILOGUE

; mat_mul(rdi=out, rsi=A, rdx=B) -- out = A*B (out must not alias). leaf
mat_mul:
    xor ecx, ecx                        ; column
.c:
    cmp ecx, 4
    jge .done
    xor r8d, r8d                        ; row
.r:
    cmp r8d, 4
    jge .nc
    xorps xmm0, xmm0
    xor r9d, r9d                        ; k
.k:
    cmp r9d, 4
    jge .store
    lea eax, [r9*4+r8]
    movss xmm1, [rsi+rax*4]             ; A[row r, column k]
    lea eax, [rcx*4+r9]
    mulss xmm1, [rdx+rax*4]             ; B[row k, column c]
    addss xmm0, xmm1
    inc r9d
    jmp .k
.store:
    lea eax, [rcx*4+r8]
    movss [rdi+rax*4], xmm0
    inc r8d
    jmp .r
.nc:
    inc ecx
    jmp .c
.done:
    ret

; =============================================================================
; flashlight shadows
; =============================================================================

; compute_flashlight -- the beam's direction (view forward, tipped down a
; touch) and where the torch is: in your right hand, below your eyes. Being
; offset from the eye is what makes its shadows visible at all.
compute_flashlight:
    PROLOGUE 32
    movss xmm0, [p_pitch]
    FLD xmm1, -0.05
    addss xmm0, xmm1
    movss [rsp+0], xmm0
    call cosf
    movss [rsp+4], xmm0                 ; cos pitch
    movss xmm0, [rsp+0]
    call sinf
    movss [fdir+4], xmm0
    movss xmm0, [p_yaw]
    call sinf
    movss [rsp+8], xmm0                 ; sin yaw
    mulss xmm0, [rsp+4]
    xorps xmm0, [c_sign_mask]
    movss [fdir], xmm0
    movss xmm0, [p_yaw]
    call cosf
    movss [rsp+12], xmm0                ; cos yaw
    mulss xmm0, [rsp+4]
    xorps xmm0, [c_sign_mask]
    movss [fdir+8], xmm0
    ; hand = camera + right*0.22 + down*0.25, right = (cos yaw, 0, -sin yaw)
    movss xmm0, [rsp+12]
    mulss xmm0, [c_flash_right]
    addss xmm0, [cam_x]
    movss [flash_pos], xmm0
    movss xmm0, [cam_y]
    addss xmm0, [c_flash_down]
    movss [flash_pos+4], xmm0
    movss xmm0, [rsp+8]
    mulss xmm0, [c_flash_right]
    movss xmm1, [cam_z]
    subss xmm1, xmm0
    movss [flash_pos+8], xmm1
    EPILOGUE

; init_shadows -- depth texture + framebuffer for the flashlight's shadow
; map. Needs framebuffer objects (GL 3.0 / ARB_framebuffer_object); without
; them the game simply runs without shadows. Off by default when rendering
; in software; BEACOM_SHADOWS=0/1 overrides, F5 toggles in game.
init_shadows:
    PROLOGUE 48
    mov dword [shadows_ok], 0
    mov dword [shadows_on], 0
    xor ebx, ebx
.fetch:
    cmp ebx, 5
    jge .fetched
    mov rdi, [fbo_names+rbx*8]
    call SDL_GL_GetProcAddress
    test rax, rax
    jz .done
    mov [fbo_ptrs+rbx*8], rax
    inc ebx
    jmp .fetch
.fetched:
    lea rsi, [shadow_tex]
    mov edi, 1
    call glGenTextures
    mov edi, [shadow_tex]
    call bind
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_MIN_FILTER
    mov edx, GL_NEAREST
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_MAG_FILTER
    mov edx, GL_NEAREST
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_WRAP_S
    mov edx, GL_CLAMP_TO_EDGE
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_WRAP_T
    mov edx, GL_CLAMP_TO_EDGE
    call glTexParameteri
    mov qword [rsp+0], GL_DEPTH_COMPONENT
    mov qword [rsp+8], GL_UNSIGNED_INT
    mov qword [rsp+16], 0
    mov edi, GL_TEXTURE_2D
    xor esi, esi
    mov edx, GL_DEPTH_COMPONENT24
    mov ecx, SHADOW_SIZE
    mov r8d, SHADOW_SIZE
    xor r9d, r9d
    call glTexImage2D
    lea rsi, [shadow_fbo]
    mov edi, 1
    GL2CALL glGenFramebuffers
    mov edi, GL_FRAMEBUFFER
    mov esi, [shadow_fbo]
    GL2CALL glBindFramebuffer
    mov edi, GL_FRAMEBUFFER
    mov esi, GL_DEPTH_ATTACHMENT
    mov edx, GL_TEXTURE_2D
    mov ecx, [shadow_tex]
    xor r8d, r8d
    GL2CALL glFramebufferTexture2D
    xor edi, edi                        ; depth only: no colour buffer
    call glDrawBuffer
    xor edi, edi
    call glReadBuffer
    mov edi, GL_FRAMEBUFFER
    GL2CALL glCheckFramebufferStatus
    mov ebx, eax
    mov edi, GL_FRAMEBUFFER
    xor esi, esi
    GL2CALL glBindFramebuffer
    xor edi, edi
    call bind
    cmp ebx, GL_FRAMEBUFFER_COMPLETE
    jne .done
    mov dword [shadows_ok], 1
    cmp dword [render_scale], 1
    jne .env
    mov dword [shadows_on], 1
.env:
    lea rdi, [env_shadows]
    call getenv
    test rax, rax
    jz .done
    movzx eax, byte [rax]
    sub eax, '0'
    and eax, 1
    mov [shadows_on], eax
.done:
    EPILOGUE

; render_toggle_shadows -- F5
render_toggle_shadows:
    cmp dword [shadows_ok], 0
    je .no
    xor dword [shadows_on], 1
.no:
    ret

; shadow_pass -- depth of everything near you, as seen from the flashlight
shadow_pass:
    PROLOGUE 32
    lea rdi, [light_view]
    lea rsi, [flash_pos]
    lea rdx, [fdir]
    call mat_lookat
    lea rdi, [light_proj]
    movss xmm0, [c_shadow_fov]
    movss xmm1, [c_one]
    movss xmm2, [c_shadow_near]
    movss xmm3, [c_shadow_far]
    call mat_perspective
    lea rdi, [shadow_mat]
    lea rsi, [light_proj]
    lea rdx, [light_view]
    call mat_mul
    ; never sample the map while rendering into it (unit 1 = nothing for now)
    mov edi, GL_TEXTURE1
    GL2CALL glActiveTexture
    xor edi, edi
    call bind
    mov edi, GL_TEXTURE0
    GL2CALL glActiveTexture
    mov edi, GL_FRAMEBUFFER
    mov esi, [shadow_fbo]
    GL2CALL glBindFramebuffer
    xor edi, edi
    xor esi, esi
    mov edx, SHADOW_SIZE
    mov ecx, SHADOW_SIZE
    call glViewport
    mov edi, GL_DEPTH_BUFFER_BIT
    call glClear
    mov edi, GL_PROJECTION
    call glMatrixMode
    lea rdi, [light_proj]
    call glLoadMatrixf
    mov edi, GL_MODELVIEW
    call glMatrixMode
    lea rdi, [light_view]
    call glLoadMatrixf
    xor edi, edi
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call glColorMask
    mov edi, GL_POLYGON_OFFSET_FILL
    call glEnable
    movss xmm0, [c_poly_factor]
    movss xmm1, [c_poly_units]
    call glPolygonOffset
    mov edi, GL_DEPTH_TEST
    call glEnable
    xor edi, edi
    call use_program
    ; the static world on the storeys around you...
    xor r12d, r12d                      ; every storey: the atrium sees them all
.fl:
    cmp r12d, NF-1
    jg .world_done
    cmp r12d, 0
    jl .fl_next
    cmp r12d, NF
    jge .fl_next
    xor r13d, r13d
.mat:
    cmp r13d, NLIT
    jge .fl_next
    imul edi, r12d, NMAT
    add edi, r13d
    add edi, [list_base]
    call glCallList
    inc r13d
    jmp .mat
.fl_next:
    inc r12d
    jmp .fl
.world_done:
    ; ...and T, whose silhouette is the whole point (and anything physical)
    call draw_t
    call draw_physics
    mov edi, GL_POLYGON_OFFSET_FILL
    call glDisable
    mov edi, 1
    mov esi, 1
    mov edx, 1
    mov ecx, 1
    call glColorMask
    mov edi, GL_FRAMEBUFFER
    xor esi, esi
    GL2CALL glBindFramebuffer
    ; the main pass reads the map from texture unit 1
    mov edi, GL_TEXTURE1
    GL2CALL glActiveTexture
    mov edi, [shadow_tex]
    call bind
    mov edi, GL_TEXTURE0
    GL2CALL glActiveTexture
    EPILOGUE

; =============================================================================
; physics bodies (physics.asm): props are drawn straight from their 8 corner
; particles, so they tumble exactly as simulated; T's ragdoll gets proper
; limbs between its particles and his face on the head
; =============================================================================

; pvec(eax=particle, rdi=out vec3) -- copy a particle position. leaf
pvec:
    mov ecx, [px+rax*4]
    mov [rdi], ecx
    mov ecx, [py+rax*4]
    mov [rdi+4], ecx
    mov ecx, [pz+rax*4]
    mov [rdi+8], ecx
    ret

; sub3(rdi=out, rsi=a, rdx=b) -- out = a - b. leaf
sub3:
    movss xmm0, [rsi]
    subss xmm0, [rdx]
    movss [rdi], xmm0
    movss xmm0, [rsi+4]
    subss xmm0, [rdx+4]
    movss [rdi+4], xmm0
    movss xmm0, [rsi+8]
    subss xmm0, [rdx+8]
    movss [rdi+8], xmm0
    ret

; draw_prop(r12d=body) -- 6 faces from the corner particles
draw_prop:
    PROLOGUE 96
    ; [rsp+0] TL [rsp+16] TR [rsp+32] BL [rsp+48] e1 [rsp+64] e2 [rsp+80] n
    mov eax, [body_type+r12*4]
    mov edi, [prop_tex+rax*4]
    call bind
    mov edi, GL_QUADS
    call glBegin
    mov r13d, [body_p0+r12*4]
    xor ebx, ebx                        ; face
.face:
    cmp ebx, 6
    jge .faces_done
    ; normal = (BL - TL) x (TR - TL), outward
    movzx eax, byte [face_corner+rbx*4+0]
    add eax, r13d
    lea rdi, [rsp+0]
    call pvec
    movzx eax, byte [face_corner+rbx*4+1]
    add eax, r13d
    lea rdi, [rsp+16]
    call pvec
    movzx eax, byte [face_corner+rbx*4+3]
    add eax, r13d
    lea rdi, [rsp+32]
    call pvec
    lea rdi, [rsp+48]
    lea rsi, [rsp+32]
    lea rdx, [rsp+0]
    call sub3
    lea rdi, [rsp+64]
    lea rsi, [rsp+16]
    lea rdx, [rsp+0]
    call sub3
    lea rdi, [rsp+80]
    lea rsi, [rsp+48]
    lea rdx, [rsp+64]
    call cross3
    lea rdi, [rsp+80]
    call normalize3
    movss xmm0, [rsp+80]
    movss xmm1, [rsp+84]
    movss xmm2, [rsp+88]
    call glNormal3f
    xor r14d, r14d                      ; corner
.corner:
    cmp r14d, 4
    jge .next_face
    movss xmm0, [corner_u+r14*4]
    movss xmm1, [corner_v+r14*4]
    call glTexCoord2f
    lea eax, [rbx*4+r14]
    movzx eax, byte [face_corner+rax]
    add eax, r13d
    movss xmm0, [px+rax*4]
    movss xmm1, [py+rax*4]
    movss xmm2, [pz+rax*4]
    call glVertex3f
    inc r14d
    jmp .corner
.next_face:
    inc ebx
    jmp .face
.faces_done:
    call glEnd
    EPILOGUE

; emit_bone(edi=particle a, esi=particle b, xmm0=half width)
emit_bone:
    PROLOGUE 48
    mov eax, edi
    lea rdi, [rsp+0]
    call pvec
    mov eax, esi
    lea rdi, [rsp+16]
    call pvec
    lea rdi, [rsp+0]
    lea rsi, [rsp+16]
    call emit_tube
    EPILOGUE

; emit_tube(rdi=&A, rsi=&B, xmm0=half width) -- a 4-sided tube between two
; points in any orientation (limbs, cables, arms)
emit_tube:
    PROLOGUE 160
    ; [rsp+0] A [rsp+16] B [rsp+32] d [rsp+48] up [rsp+64] u [rsp+80] v
    ; [rsp+96] ring offsets 4 x vec3 (48 bytes) [rsp+144] w
    movss [rsp+144], xmm0
    mov eax, [rdi]
    mov [rsp+0], eax
    mov eax, [rdi+4]
    mov [rsp+4], eax
    mov eax, [rdi+8]
    mov [rsp+8], eax
    mov eax, [rsi]
    mov [rsp+16], eax
    mov eax, [rsi+4]
    mov [rsp+20], eax
    mov eax, [rsi+8]
    mov [rsp+24], eax
    lea rdi, [rsp+32]
    lea rsi, [rsp+16]
    lea rdx, [rsp+0]
    call sub3
    lea rdi, [rsp+32]
    call normalize3
    ; a helper axis not parallel to the bone
    mov dword [rsp+48], 0
    mov dword [rsp+52], __float32__(1.0)
    mov dword [rsp+56], 0
    movss xmm0, [rsp+36]
    andps xmm0, [c_abs_mask]
    FLD xmm1, 0.9
    comiss xmm0, xmm1
    jb .up_ok
    mov dword [rsp+48], __float32__(1.0)
    mov dword [rsp+52], 0
.up_ok:
    lea rdi, [rsp+64]
    lea rsi, [rsp+32]
    lea rdx, [rsp+48]
    call cross3
    lea rdi, [rsp+64]
    call normalize3
    lea rdi, [rsp+80]
    lea rsi, [rsp+32]
    lea rdx, [rsp+64]
    call cross3
    ; ring: (+u+v) (-u+v) (-u-v) (+u-v), scaled by w
    xor ebx, ebx
.ring:
    cmp ebx, 4
    jge .ring_done
    movss xmm6, [rsp+144]               ; su*w
    cmp ebx, 1
    je .neg_u
    cmp ebx, 2
    jne .u_ok
.neg_u:
    xorps xmm6, [c_sign_mask]
.u_ok:
    movss xmm7, [rsp+144]               ; sv*w
    cmp ebx, 2
    jl .v_ok
    xorps xmm7, [c_sign_mask]
.v_ok:
    imul eax, ebx, 12
    xor ecx, ecx
.comp:
    cmp ecx, 3
    jge .comp_done
    movss xmm0, [rsp+64+rcx*4]
    mulss xmm0, xmm6
    movss xmm1, [rsp+80+rcx*4]
    mulss xmm1, xmm7
    addss xmm0, xmm1
    lea edx, [rax+rcx*4]
    movss [rsp+96+rdx], xmm0
    inc ecx
    jmp .comp
.comp_done:
    inc ebx
    jmp .ring
.ring_done:
    ; four sides: ring i -> ring i+1, from A to B
    xor ebx, ebx
.side:
    cmp ebx, 4
    jge .done
    imul r12d, ebx, 12                  ; ring i
    lea eax, [rbx+1]
    and eax, 3
    imul r13d, eax, 12                  ; ring i+1
    ; normal ~ ring i + ring i+1
    movss xmm0, [rsp+96+r12]
    addss xmm0, [rsp+96+r13]
    movss xmm1, [rsp+100+r12]
    addss xmm1, [rsp+100+r13]
    movss xmm2, [rsp+104+r12]
    addss xmm2, [rsp+104+r13]
    call glNormal3f
    ; A + ring i, A + ring i+1, B + ring i+1, B + ring i
    xor r14d, r14d
.v:
    cmp r14d, 4
    jge .next
    mov r15d, r12d
    cmp r14d, 1
    je .ri1
    cmp r14d, 2
    jne .rsel
.ri1:
    mov r15d, r13d
.rsel:
    xor eax, eax                        ; A (0) or B (16)
    cmp r14d, 2
    jl .pa
    mov eax, 16
.pa:
    movss xmm0, [rsp+rax]
    addss xmm0, [rsp+96+r15]
    movss xmm1, [rsp+rax+4]
    addss xmm1, [rsp+100+r15]
    movss xmm2, [rsp+rax+8]
    addss xmm2, [rsp+104+r15]
    call glVertex3f
    inc r14d
    jmp .v
.next:
    inc ebx
    jmp .side
.done:
    EPILOGUE

; draw_ragdoll(r12d=body) -- T, collapsed
draw_ragdoll:
    PROLOGUE 32
    mov r13d, [body_p0+r12*4]
    mov edi, [white_tex]
    call bind
    GLF3 glColor3f, 0.043, 0.043, 0.05
    mov edi, GL_QUADS
    call glBegin
    xor ebx, ebx
.bone:
    cmp ebx, RAG_DRAW_BONES
    jge .bones_done
    mov edi, [rag_draw+rbx*8]
    add edi, r13d
    mov esi, [rag_draw+rbx*8+4]
    add esi, r13d
    movss xmm0, [rag_width+rbx*4]
    call emit_bone
    inc ebx
    jmp .bone
.bones_done:
    call glEnd
    GLF3 glColor3f, 1.0, 1.0, 1.0
    ; the face, on the head particle, turned toward you and glitching
    movss xmm0, [px+r13*4]
    movss xmm1, [pz+r13*4]
    call face_camera_yaw
    movaps xmm3, xmm0
    movss xmm0, [px+r13*4]
    movss xmm1, [py+r13*4]              ; face sits on the head, above the floor
    movss xmm2, [pz+r13*4]
    call model_begin
    mov edi, 1
    call use_program
    mov edi, [u_model]
    mov esi, 1
    xor edx, edx
    lea rcx, [model_mat]
    GL2CALL glUniformMatrix4fv
    call rand01
    FLD xmm1, 0.9
    mulss xmm0, xmm1
    call set_emit                       ; flickering glow: the deauth at work
    mov edi, [face_tex]
    call bind
    GLF3 glColor3f, 0.7, 0.9, 1.0
    mov edi, GL_QUADS
    call glBegin
    FLD xmm0, 0.31
    xorps xmm1, xmm1
    FLD xmm2, 0.62
    FLD xmm3, 0.05
    call quad_xy
    call glEnd
    GLF3 glColor3f, 1.0, 1.0, 1.0
    xorps xmm0, xmm0
    call set_emit
    call model_end
    xor edi, edi
    call use_program
    mov edi, [u_model]
    mov esi, 1
    xor edx, edx
    lea rcx, [identity]
    GL2CALL glUniformMatrix4fv
    EPILOGUE

; draw_physics -- every active body within a floor of you
draw_physics:
    PROLOGUE 16
    xor r12d, r12d
.body:
    cmp r12d, [phys_nb]
    jge .done
    cmp dword [body_active+r12*4], 0
    je .nb
    mov eax, [body_p0+r12*4]
    movss xmm0, [py+rax*4]
    call floor_of_height
    sub eax, [cur_floor]
    cmp eax, VIS_FLOORS
    jg .nb
    cmp eax, -VIS_FLOORS
    jl .nb
    cmp dword [body_type+r12*4], 2      ; B_RAG
    je .rag
    call draw_prop
    jmp .nb
.rag:
    call draw_ragdoll
.nb:
    inc r12d
    jmp .body
.done:
    EPILOGUE

; bind(edi=GL texture id)
bind:
    mov esi, edi
    mov edi, GL_TEXTURE_2D
    jmp glBindTexture

; set_emit(xmm0=emission)
set_emit:
    mov edi, [u_emit]
    GL2JMP glUniform1f

; =============================================================================
; start-up
; =============================================================================

; compile_shader(edi=type, rsi=header, rdx=body) -> eax shader id (exits on error)
compile_shader:
    PROLOGUE 16
    mov [src_ptr], rsi
    mov [src_ptr+8], rdx
    GL2CALL glCreateShader
    mov ebx, eax
    mov edi, ebx
    mov esi, 2
    lea rdx, [src_ptr]
    xor ecx, ecx
    GL2CALL glShaderSource
    mov edi, ebx
    GL2CALL glCompileShader
    mov edi, ebx
    mov esi, GL_COMPILE_STATUS
    lea rdx, [rsp+0]
    GL2CALL glGetShaderiv
    cmp dword [rsp+0], 0
    jne .ok
    mov edi, ebx
    mov esi, 1024
    xor edx, edx
    lea rcx, [info_log]
    GL2CALL glGetShaderInfoLog
    lea rdi, [err_shader]
    lea rsi, [info_log]
    xor eax, eax
    call printf
    mov edi, 1
    call exit
.ok:
    mov eax, ebx
    EPILOGUE

init_shaders:
    PROLOGUE 16
    ; fetch GL 2.0 entry points
    xor ebx, ebx
.fetch:
    cmp ebx, NGL2
    jge .fetched
    mov rdi, [gl2_names+rbx*8]
    call SDL_GL_GetProcAddress
    test rax, rax
    jnz .got
    lea rdi, [err_gl2]
    xor eax, eax
    call printf
    mov edi, 1
    call exit
.got:
    mov [gl2_ptrs+rbx*8], rax
    inc ebx
    jmp .fetch
.fetched:
    mov edi, GL_VERTEX_SHADER
    lea rsi, [empty_str]
    lea rdx, [vs_src]
    call compile_shader
    mov r12d, eax                       ; vertex shader, shared
    xor r14d, r14d                      ; program index 0 / 1
.prog:
    cmp r14d, 2
    jge .progs_done
    mov edi, GL_FRAGMENT_SHADER
    lea rsi, [fs_head0]
    test r14d, r14d
    jz .h
    lea rsi, [fs_head1]
.h:
    lea rdx, [fs_src]
    call compile_shader
    mov r13d, eax
    GL2CALL glCreateProgram
    mov [programs+r14*4], eax
    mov edi, eax
    mov esi, r12d
    GL2CALL glAttachShader
    mov edi, [programs+r14*4]
    mov esi, r13d
    GL2CALL glAttachShader
    mov edi, [programs+r14*4]
    GL2CALL glLinkProgram
    xor ebx, ebx
.uni:
    cmp ebx, NUNI
    jge .uni_done
    mov edi, [programs+r14*4]
    mov rsi, [u_name_ptrs+rbx*8]
    GL2CALL glGetUniformLocation
    imul ecx, r14d, NUNI
    add ecx, ebx
    mov [uni_tab+rcx*4], eax
    inc ebx
    jmp .uni
.uni_done:
    ; constant uniforms
    mov edi, r14d
    call use_program
    mov edi, [u_tex]
    xor esi, esi
    GL2CALL glUniform1i
    mov edi, [u_model]
    mov esi, 1
    xor edx, edx
    lea rcx, [identity]
    GL2CALL glUniformMatrix4fv
    mov edi, [u_fog]
    movss xmm0, [c_fog]
    GL2CALL glUniform1f
    mov edi, [u_stex]
    mov esi, 1                          ; shadow map on texture unit 1
    GL2CALL glUniform1i
    inc r14d
    jmp .prog
.progs_done:
    xor edi, edi
    call use_program
    EPILOGUE

; add_fixture(xmm0=x, xmm1=y, xmm2=z, edi=f, esi=state, edx=0xRRGGBB)
add_fixture:
    PROLOGUE 16
    mov ecx, [fixture_count]
    cmp ecx, MAX_FIX
    jge .full
    movss [fx_x+rcx*4], xmm0
    movss [fx_y+rcx*4], xmm1
    movss [fx_z+rcx*4], xmm2
    mov [fx_f+rcx*4], edi
    mov [fx_state+rcx*4], esi
    FLD xmm3, 255.0
    mov eax, edx
    shr eax, 16
    and eax, 255
    cvtsi2ss xmm0, eax
    divss xmm0, xmm3
    movss [fx_r+rcx*4], xmm0
    mov eax, edx
    shr eax, 8
    and eax, 255
    cvtsi2ss xmm0, eax
    divss xmm0, xmm3
    movss [fx_g+rcx*4], xmm0
    mov eax, edx
    and eax, 255
    cvtsi2ss xmm0, eax
    divss xmm0, xmm3
    movss [fx_b+rcx*4], xmm0
    mov ebx, ecx
    call rand01
    mulss xmm0, [c_hundred]
    movss [fx_phase+rbx*4], xmm0
    inc dword [fixture_count]
.full:
    EPILOGUE

; cell_box(r12d=f, r13d=x, r14d=y) -- set bx0..bz1 to the full cell volume
cell_box:
    cvtsi2ss xmm0, r13d
    mulss xmm0, [c_cell]
    movss [bx0], xmm0
    addss xmm0, [c_cell]
    movss [bx1], xmm0
    cvtsi2ss xmm0, r14d
    mulss xmm0, [c_cell]
    movss [bz0], xmm0
    addss xmm0, [c_cell]
    movss [bz1], xmm0
    cvtsi2ss xmm0, r12d
    mulss xmm0, [c_fh]
    movss [by0], xmm0
    addss xmm0, [c_fh]
    movss [by1], xmm0
    ret

; cell_centre -> xmm0 = centre X, xmm2 = centre Z, xmm1 = floor Y (uses r12-r14)
cell_centre:
    cvtsi2ss xmm0, r13d
    addss xmm0, [c_half]
    mulss xmm0, [c_cell]
    cvtsi2ss xmm2, r14d
    addss xmm2, [c_half]
    mulss xmm2, [c_cell]
    cvtsi2ss xmm1, r12d
    mulss xmm1, [c_fh]
    ret

; nchar(edi=dx, esi=dy) -> eax char of neighbour of (r12,r13,r14) on the same storey
nchar:
    lea esi, [r14d+esi]
    lea eax, [r13d+edi]
    mov edx, esi
    mov esi, eax
    mov edi, r12d
    jmp cell_at

; -----------------------------------------------------------------------------
; build_material(r15d = material, rbx = storey) -- emits the geometry of one
; material on one storey (called while compiling that display list)
; -----------------------------------------------------------------------------
build_material:
    PROLOGUE 64
    mov r12d, ebx                       ; f (kept in r12 for helpers)
    mov [rsp+32], r15d                  ; material
    cmp r15d, M_GLASS
    jne .not_glass
    GLF4 glColor4f, 0.62, 0.80, 0.88, 0.20   ; faintly blue-green, mostly clear
.not_glass:
    xor r14d, r14d                      ; y
.y:
    cmp r14d, MAP_H
    jge .done
    xor r13d, r13d                      ; x
.x:
    cmp r13d, MAP_W
    jge .ny
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_at
    mov [rsp+36], eax                   ; this cell's char
    mov ecx, [rsp+32]
    mov dword [u_rep], __float32__(1.0)
    mov dword [v_rep], __float32__(1.0)

    ; ---------------- walls
    movzx edx, byte [char_class+rax]
    test edx, CF_WALL
    jz .not_wall
    ; which material is this wall?
    mov edx, M_CONC
    cmp eax, 'H'
    jne .w1
    mov edx, M_H
.w1:
    cmp eax, 'C'
    jne .w2
    mov edx, M_C
.w2:
    cmp eax, 'G'
    jne .w3
    mov edx, M_G
.w3:
    cmp eax, 'L'
    jne .w4
    mov edx, M_L
.w4:
    cmp eax, 'N'
    jne .w5
    mov edx, M_N
.w5:
    cmp eax, 'g'                        ; glass
    jne .w6
    mov edx, M_GLASS
.w6:
    cmp eax, 'W'                        ; the media wall: drywall behind the screens
    jne .w7
    mov edx, M_C
.w7:
    cmp edx, ecx
    jne .next
    ; only faces that border a non-wall cell
    xor r15d, r15d                      ; face mask
    mov edi, 1
    xor esi, esi
    call nchar
    test byte [char_class+rax], CF_WALL
    jnz .m1
    or r15d, F_PX
.m1:
    mov edi, -1
    xor esi, esi
    call nchar
    test byte [char_class+rax], CF_WALL
    jnz .m2
    or r15d, F_NX
.m2:
    xor edi, edi
    mov esi, 1
    call nchar
    test byte [char_class+rax], CF_WALL
    jnz .m3
    or r15d, F_PZ
.m3:
    xor edi, edi
    mov esi, -1
    call nchar
    test byte [char_class+rax], CF_WALL
    jnz .m4
    or r15d, F_NZ
.m4:
    ; skip faces that point out of the map
    test r15d, r15d
    jz .restore
    call cell_box
    mov edi, r15d
    call emit_box
.restore:
    mov r15d, [rsp+32]
    jmp .next

.not_wall:
    ; ---------------- floor tile (not under an open shaft)
    cmp eax, '.'
    je .ceiling
    mov edx, M_FLOOR
    test r12d, r12d
    jnz .fl1
    mov edx, M_FLOOR_B
.fl1:
    cmp eax, 'S'
    jne .fl2
    mov edx, M_FLOOR_S
.fl2:
    cmp edx, ecx
    jne .ceiling
    call cell_box
    mov eax, [by0]
    mov [by1], eax
    mov edi, F_PY
    call emit_box
    mov ecx, [rsp+32]
    mov eax, [rsp+36]

.ceiling:
    ; ---------------- ceiling (unless this is a stair or the storey above is open)
    movzx edx, byte [char_class+rax]
    test edx, CF_STAIR
    jnz .props
    cmp r12d, NF-1
    je .ceil_yes
    lea edi, [r12d+1]
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, '.'
    je .props_reload
.ceil_yes:
    mov edx, M_CEIL
    test r12d, r12d
    jnz .c1
    mov edx, M_CEIL_B
.c1:
    cmp edx, [rsp+32]
    jne .props_reload
    call cell_box
    movss xmm0, [by1]
    FLD xmm1, 0.01
    subss xmm0, xmm1                    ; 1cm below the floor above: no z-fighting
    movss [by0], xmm0
    movss [by1], xmm0
    mov edi, F_NY
    call emit_box
.props_reload:
    mov ecx, [rsp+32]
    mov eax, [rsp+36]

.props:
    ; ---------------- stairs: two concrete steps per cell
    movzx edx, byte [char_class+rax]
    test edx, CF_STAIR
    jz .not_stair
    cmp ecx, M_CONC
    jne .next
    call emit_stair_cell
    jmp .next
.not_stair:
    cmp eax, 'P'
    jne .not_pillar
    cmp ecx, M_CONC
    jne .next
    call cell_centre
    FLD xmm3, 0.55
    movss xmm4, [c_fh]
    movaps xmm5, xmm3
    call box_at
    mov dword [u_rep], __float32__(0.5)
    mov edi, F_PX|F_NX|F_PZ|F_NZ
    call emit_box
    jmp .next
.not_pillar:
    cmp eax, 'R'
    jne .not_rack
    cmp ecx, M_RACK
    je .rack
    cmp ecx, M_LED
    jne .next
    ; LED overlay: same box pushed out a hair
    call cell_centre
    FLD xmm3, 0.86
    FLD xmm4, 2.5
    FLD xmm5, 0.86
    call box_at
    mov edi, F_PX|F_NX|F_PZ|F_NZ
    call emit_box
    jmp .next
.rack:
    call cell_centre
    FLD xmm3, 0.85
    FLD xmm4, 2.5
    FLD xmm5, 0.85
    call box_at
    mov edi, F_ALL
    call emit_box
    jmp .next
.not_rack:
    cmp eax, 'd'
    jne .not_desk
    cmp ecx, M_WHITE
    je .desk
    cmp ecx, M_SCREEN
    jne .next
    ; a third of the monitors were left on
    mov eax, r13d
    imul eax, 7
    add eax, r14d
    imul eax, 13
    add eax, r12d
    xor edx, edx
    mov ecx, 3
    div ecx
    test edx, edx
    jnz .next
    call desk_screen
    jmp .next
.desk:
    call emit_desk
    jmp .next
.not_desk:
    cmp eax, 'Y'
    jne .not_cage
    cmp ecx, M_WHITE
    jne .next
    call emit_cage_cell
    jmp .next
.not_cage:
    cmp eax, 'u'
    jne .not_ladder
    cmp ecx, M_WHITE
    jne .next
    call emit_ladder
    jmp .next
.not_ladder:
    cmp eax, 'B'
    jne .next
    cmp ecx, M_WHITE
    jne .next
    call emit_b
.next:
    inc r13d
    jmp .x
.ny:
    inc r14d
    jmp .y
.done:
    ; ramps and bridges (world.asm) are bare concrete, crates are wood
    cmp dword [rsp+32], M_FLOOR_B
    jne .not_conc
    mov edi, PS_CONCRETE
    call build_platforms
.not_conc:
    cmp dword [rsp+32], M_WHITE
    jne .out
    GLF3 glColor3f, 0.55, 0.42, 0.26
    mov edi, PS_CRATE
    call build_platforms
    GLF3 glColor3f, 1.0, 1.0, 1.0
.out:
    EPILOGUE

; build_platforms(r12d = storey, edi = style) -- every platform of that style
; whose low end is on this storey, as a (possibly sloped) slab: top,
; bottom and four sides
build_platforms:
    PROLOGUE 32
    mov [rsp+8], edi
    xor ebx, ebx
.p:
    cmp ebx, [plat_count]
    jge .done
    mov eax, [plat_style+rbx*4]
    cmp eax, [rsp+8]
    jne .n
    movss xmm0, [plat_ya+rbx*4]
    minss xmm0, [plat_yb+rbx*4]
    call floor_of_height
    cmp eax, r12d
    jne .n
    ; corners 0 (x0,z0) 1 (x1,z0) 2 (x1,z1) 3 (x0,z1)
    mov eax, [plat_x0+rbx*4]
    mov [pc_x+0], eax
    mov [pc_x+12], eax
    mov eax, [plat_x1+rbx*4]
    mov [pc_x+4], eax
    mov [pc_x+8], eax
    mov eax, [plat_z0+rbx*4]
    mov [pc_z+0], eax
    mov [pc_z+4], eax
    mov eax, [plat_z1+rbx*4]
    mov [pc_z+8], eax
    mov [pc_z+12], eax
    ; heights: flat, rising along X (corners 1,2 high) or along Z (2,3 high)
    mov eax, [plat_ya+rbx*4]
    mov ecx, [plat_yb+rbx*4]
    mov [pc_t+0], eax
    mov [pc_t+4], eax
    mov [pc_t+8], eax
    mov [pc_t+12], eax
    cmp dword [plat_axis+rbx*4], 1
    jne .not_x
    mov [pc_t+4], ecx
    mov [pc_t+8], ecx
.not_x:
    cmp dword [plat_axis+rbx*4], 2
    jne .heights
    mov [pc_t+8], ecx
    mov [pc_t+12], ecx
.heights:
    xor ecx, ecx
.bot:
    movss xmm0, [pc_t+rcx*4]
    subss xmm0, [plat_thick+rbx*4]
    movss [pc_b+rcx*4], xmm0
    inc ecx
    cmp ecx, 4
    jl .bot
    ; top and bottom, textured in world space
    GLF3 glNormal3f, 0.0, 1.0, 0.0
    xor esi, esi
    call plat_cap
    GLF3 glNormal3f, 0.0, -1.0, 0.0
    mov esi, 1
    call plat_cap
    ; sides: edge i -> j, outward normal (dz, 0, -dx)
    xor r13d, r13d
.side:
    cmp r13d, 4
    jge .n
    lea r14d, [r13d+1]
    and r14d, 3
    movss xmm0, [pc_z+r14*4]
    subss xmm0, [pc_z+r13*4]
    movss xmm2, [pc_x+r13*4]
    subss xmm2, [pc_x+r14*4]
    movaps xmm3, xmm0
    mulss xmm3, xmm3
    movaps xmm4, xmm2
    mulss xmm4, xmm4
    addss xmm3, xmm4
    sqrtss xmm3, xmm3
    divss xmm0, xmm3
    divss xmm2, xmm3
    xorps xmm1, xmm1
    call glNormal3f
    movss xmm0, [pc_x+r13*4]
    addss xmm0, [pc_z+r13*4]
    mulss xmm0, [c_half]
    movss [rsp+0], xmm0                 ; u at i
    movss xmm0, [pc_x+r14*4]
    addss xmm0, [pc_z+r14*4]
    mulss xmm0, [c_half]
    movss [rsp+4], xmm0                 ; u at j
    mov edi, r13d
    xor esi, esi
    movss xmm0, [rsp+0]
    xorps xmm1, xmm1
    call plat_v
    mov edi, r14d
    xor esi, esi
    movss xmm0, [rsp+4]
    xorps xmm1, xmm1
    call plat_v
    mov edi, r14d
    mov esi, 1
    movss xmm0, [rsp+4]
    FLD xmm1, 0.1
    call plat_v
    mov edi, r13d
    mov esi, 1
    movss xmm0, [rsp+0]
    FLD xmm1, 0.1
    call plat_v
    inc r13d
    jmp .side
.n:
    inc ebx
    jmp .p
.done:
    EPILOGUE

; plat_cap(esi = 0 top / 1 bottom) -- the four corners, uv = world xz / 2
plat_cap:
    PROLOGUE 16
    mov r12d, esi
    xor r13d, r13d
.c:
    cmp r13d, 4
    jge .done
    movss xmm0, [pc_x+r13*4]
    mulss xmm0, [c_half]
    movss xmm1, [pc_z+r13*4]
    mulss xmm1, [c_half]
    mov edi, r13d
    mov esi, r12d
    call plat_v
    inc r13d
    jmp .c
.done:
    EPILOGUE

; plat_v(edi = corner, esi = 0 top / 1 bottom, xmm0/xmm1 = u/v) -- one vertex
plat_v:
    PROLOGUE 16
    mov ebx, edi
    mov r12d, esi
    call glTexCoord2f
    movss xmm0, [pc_x+rbx*4]
    movss xmm1, [pc_t+rbx*4]
    test r12d, r12d
    jz .top
    movss xmm1, [pc_b+rbx*4]
.top:
    movss xmm2, [pc_z+rbx*4]
    call glVertex3f
    EPILOGUE

; emit_stair_cell -- two steps; the step top follows the ramp so each step's
; top sits at the ramp height at its far edge (r12..r14 = f,x,y)
emit_stair_cell:
    PROLOGUE 48
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_index
    mov ebx, eax                        ; cell index
    xor r15d, r15d                      ; step 0/1
.step:
    cmp r15d, 2
    jge .done
    call cell_centre
    movss [rsp+0], xmm0                 ; cx
    movss [rsp+4], xmm1                 ; floor y
    movss [rsp+8], xmm2                 ; cz
    ; step centre offset along the run: -0.5 or +0.5
    cvtsi2ss xmm3, r15d
    subss xmm3, [c_half]
    movsx eax, byte [st_dx+rbx]
    test eax, eax
    jz .along_z
    addss xmm0, xmm3
    movss [rsp+0], xmm0
    jmp .off_done
.along_z:
    addss xmm2, xmm3
    movss [rsp+8], xmm2
.off_done:
    ; distance of the step centre from the bottom edge -> step index
    mov edi, ebx
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+8]
    call stair_t                        ; 0..1 at the step centre
    movzx eax, byte [st_len+rbx]
    shl eax, 1                          ; steps in the run (1 per world unit)
    cvtsi2ss xmm1, eax
    movss [rsp+12], xmm1
    mulss xmm0, xmm1
    cvttss2si eax, xmm0
    inc eax
    cvtsi2ss xmm0, eax
    divss xmm0, [rsp+12]
    mulss xmm0, [c_fh]                  ; step top height above the floor
    movaps xmm4, xmm0
    ; half sizes: 0.5 along the run, 1.0 across
    movsx eax, byte [st_dx+rbx]
    movss xmm3, [c_one]
    movss xmm5, [c_half]
    test eax, eax
    jz .dims
    movss xmm3, [c_half]
    movss xmm5, [c_one]
.dims:
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+8]
    call box_at
    mov dword [u_rep], __float32__(0.5)
    mov dword [v_rep], __float32__(0.15)
    mov edi, F_ALL & ~F_NY
    call emit_box
    inc r15d
    jmp .step
.done:
    mov dword [u_rep], __float32__(1.0)
    mov dword [v_rep], __float32__(1.0)
    EPILOGUE

; which way does a desk face? even rows face north, odd rows south
; desk_sign -> xmm7 = +1 or -1 (uses r14)
desk_sign:
    movss xmm7, [c_one]
    test r14d, 1
    jnz .s
    movss xmm7, [c_neg_one]
.s:
    ret

; emit_desk -- table, legs, monitor and chair, vertex coloured
emit_desk:
    PROLOGUE 48
    call cell_centre
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    call desk_sign
    movss [rsp+12], xmm7
    ; table top
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    FLD xmm6, 0.71
    addss xmm1, xmm6
    movss xmm2, [rsp+8]
    FLD xmm3, 0.75
    FLD xmm4, 0.06
    FLD xmm5, 0.4
    mov edi, 0x7a5a3a
    call cbox
    ; four legs
    xor ebx, ebx
.leg:
    cmp ebx, 4
    jge .legs_done
    FLD xmm0, 0.68
    test ebx, 1
    jz .lx
    xorps xmm0, [c_sign_mask]
.lx:
    addss xmm0, [rsp+0]
    FLD xmm2, 0.34
    test ebx, 2
    jz .lz
    xorps xmm2, [c_sign_mask]
.lz:
    addss xmm2, [rsp+8]
    movss xmm1, [rsp+4]
    FLD xmm3, 0.025
    FLD xmm4, 0.71
    FLD xmm5, 0.025
    mov edi, 0x333333
    call cbox
    inc ebx
    jmp .leg
.legs_done:
    ; monitor (back of the desk) + stand
    FLD xmm2, -0.2
    mulss xmm2, [rsp+12]
    addss xmm2, [rsp+8]
    movss [rsp+16], xmm2                ; monitor z
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    FLD xmm6, 0.88
    addss xmm1, xmm6
    FLD xmm3, 0.31
    FLD xmm4, 0.4
    FLD xmm5, 0.02
    mov edi, 0x16171a
    call cbox
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    FLD xmm6, 0.77
    addss xmm1, xmm6
    movss xmm2, [rsp+16]
    FLD xmm3, 0.04
    FLD xmm4, 0.12
    FLD xmm5, 0.04
    mov edi, 0x16171a
    call cbox
    ; chair: seat + back
    FLD xmm2, 0.62
    mulss xmm2, [rsp+12]
    addss xmm2, [rsp+8]
    movss [rsp+20], xmm2
    movss xmm0, [rsp+0]
    FLD xmm6, 0.15
    addss xmm0, xmm6
    movss xmm1, [rsp+4]
    FLD xmm6, 0.44
    addss xmm1, xmm6
    FLD xmm3, 0.23
    FLD xmm4, 0.05
    FLD xmm5, 0.23
    mov edi, 0x2a3350
    call cbox
    FLD xmm2, 0.86
    mulss xmm2, [rsp+12]
    addss xmm2, [rsp+8]
    movss xmm0, [rsp+0]
    FLD xmm6, 0.15
    addss xmm0, xmm6
    movss xmm1, [rsp+4]
    FLD xmm6, 0.47
    addss xmm1, xmm6
    FLD xmm3, 0.23
    FLD xmm4, 0.5
    FLD xmm5, 0.025
    mov edi, 0x2a3350
    call cbox
    movss xmm0, [rsp+0]
    FLD xmm6, 0.15
    addss xmm0, xmm6
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+20]
    FLD xmm3, 0.025
    FLD xmm4, 0.44
    FLD xmm5, 0.025
    mov edi, 0x222222
    call cbox
    mov ebx, 0xffffff
    call set_rgb
    EPILOGUE

; desk_screen -- a glowing monitor face (unlit list)
desk_screen:
    PROLOGUE 16
    call cell_centre
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    call desk_sign
    FLD xmm2, -0.2
    FLD xmm6, 0.025
    addss xmm2, xmm6                    ; just in front of the monitor
    mulss xmm2, xmm7
    call cell_centre
    FLD xmm6, -0.175
    mulss xmm6, xmm7
    addss xmm2, xmm6
    movss xmm1, [rsp+4]
    FLD xmm6, 0.91
    addss xmm1, xmm6
    FLD xmm3, 0.28
    FLD xmm4, 0.34
    FLD xmm5, 0.001
    call box_at
    mov ebx, 0x5577bb
    call set_rgb
    mov edi, F_PZ|F_NZ
    call emit_box
    mov ebx, 0xffffff
    call set_rgb
    EPILOGUE

; emit_cage_cell -- bars along every edge that doesn't join another Y cell,
; and Y himself slumped in the middle of the first cell of the row
emit_cage_cell:
    PROLOGUE 48
    call cell_centre
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    xor ebx, ebx                        ; direction 0..3: +x -x +z -z
.dir:
    cmp ebx, 4
    jge .figure
    xor edi, edi
    xor esi, esi
    cmp ebx, 0
    jne .d1
    mov edi, 1
.d1:
    cmp ebx, 1
    jne .d2
    mov edi, -1
.d2:
    cmp ebx, 2
    jne .d3
    mov esi, 1
.d3:
    cmp ebx, 3
    jne .d4
    mov esi, -1
.d4:
    mov [rsp+12], edi
    mov [rsp+16], esi
    call nchar
    cmp eax, 'Y'
    je .ndir
    ; six bars along this edge
    xor r15d, r15d
.bar:
    cmp r15d, 6
    jge .ndir
    cvtsi2ss xmm6, r15d
    addss xmm6, [c_half]
    FLD xmm7, 6.0
    divss xmm6, xmm7
    subss xmm6, [c_half]
    mulss xmm6, [c_cell]                ; offset along the edge
    FLD xmm7, 0.96                      ; 0.48 * CELL
    movss xmm0, [rsp+0]
    movss xmm2, [rsp+8]
    cvtsi2ss xmm3, dword [rsp+12]
    cvtsi2ss xmm4, dword [rsp+16]
    ; edge position
    mulss xmm3, xmm7
    addss xmm0, xmm3
    mulss xmm4, xmm7
    addss xmm2, xmm4
    ; spread along the edge (perpendicular axis)
    cmp dword [rsp+12], 0
    je .spread_x
    addss xmm2, xmm6
    jmp .spread_done
.spread_x:
    addss xmm0, xmm6
.spread_done:
    movss xmm1, [rsp+4]
    FLD xmm3, 0.035
    movss xmm4, [c_fh]
    FLD xmm5, 0.035
    mov edi, 0x55504a
    call cbox
    inc r15d
    jmp .bar
.ndir:
    inc ebx
    jmp .dir
.figure:
    ; Y sits in the cage group: draw him once, from its leftmost cell
    mov edi, -1
    xor esi, esi
    call nchar
    cmp eax, 'Y'
    je .done
    mov eax, [rsp+0]
    mov [y_pos_x], eax
    mov eax, [rsp+8]
    mov [y_pos_z], eax
    ; he is centred over the next cell to the right (4-wide cage -> middle)
    movss xmm0, [rsp+0]
    FLD xmm6, 3.0
    addss xmm0, xmm6
    movss [rsp+0], xmm0
    movss [y_pos_x], xmm0
    ; slumped body and head
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+8]
    FLD xmm3, 0.35
    FLD xmm4, 0.7
    FLD xmm5, 0.25
    mov edi, 0x4b4136
    call cbox
    movss xmm0, [rsp+0]
    FLD xmm6, 0.1
    addss xmm0, xmm6
    movss xmm1, [rsp+4]
    FLD xmm6, 0.72
    addss xmm1, xmm6
    movss xmm2, [rsp+8]
    FLD xmm3, 0.15
    FLD xmm4, 0.3
    FLD xmm5, 0.15
    mov edi, 0xc9a98a
    call cbox
    mov ebx, 0xffffff
    call set_rgb
.done:
    EPILOGUE

; emit_ladder -- two rails and rungs against the wall, running up through
; the hatch and a metre past it as a handhold (r12..r14 = f, x, y)
emit_ladder:
    PROLOGUE 48
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call ladder_dir
    cmp eax, 0
    jl .done
    mov r15d, eax
    call cell_centre
    movss [rsp+0], xmm0                 ; cell centre x
    movss [rsp+4], xmm1                 ; floor y
    movss [rsp+8], xmm2                 ; cell centre z
    ; the ladder plane: 0.85 from the centre toward the wall
    FLD xmm3, 0.85
    cmp r15d, 1
    je .neg
    cmp r15d, 3
    jne .pos
.neg:
    xorps xmm3, [c_sign_mask]
.pos:
    movss [rsp+12], xmm3
    ; two rails, then rungs every 0.3m
    xor ebx, ebx
.rail:
    cmp ebx, 2
    jge .rungs
    FLD xmm6, 0.32
    test ebx, ebx
    jz .r0
    xorps xmm6, [c_sign_mask]
.r0:
    movss xmm0, [rsp+0]
    movss xmm2, [rsp+8]
    cmp r15d, 2
    jge .rail_z
    addss xmm0, [rsp+12]
    addss xmm2, xmm6
    FLD xmm3, 0.03
    FLD xmm5, 0.035
    jmp .rail_emit
.rail_z:
    addss xmm2, [rsp+12]
    addss xmm0, xmm6
    FLD xmm3, 0.035
    FLD xmm5, 0.03
.rail_emit:
    movss xmm1, [rsp+4]
    movss xmm4, [c_fh]
    FLD xmm7, 1.0
    addss xmm4, xmm7
    mov edi, 0x6d7074
    call cbox
    inc ebx
    jmp .rail
.rungs:
    FLD xmm0, 0.25
    movss [rsp+16], xmm0                ; rung height
.rung:
    movss xmm0, [c_fh]
    FLD xmm1, 0.9
    addss xmm0, xmm1
    comiss xmm0, [rsp+16]
    jb .done
    movss xmm0, [rsp+0]
    movss xmm2, [rsp+8]
    movss xmm1, [rsp+4]
    addss xmm1, [rsp+16]
    cmp r15d, 2
    jge .rung_z
    addss xmm0, [rsp+12]
    FLD xmm3, 0.022
    FLD xmm5, 0.3
    jmp .rung_emit
.rung_z:
    addss xmm2, [rsp+12]
    FLD xmm3, 0.3
    FLD xmm5, 0.022
.rung_emit:
    FLD xmm4, 0.035
    mov edi, 0x8a8f94
    call cbox
    movss xmm0, [rsp+16]
    FLD xmm1, 0.3
    addss xmm0, xmm1
    movss [rsp+16], xmm0
    jmp .rung
.done:
    mov ebx, 0xffffff
    call set_rgb
    EPILOGUE

; draw_ziplines -- cables, their wall anchors and the trolley
draw_ziplines:
    PROLOGUE 64
    mov edi, [white_tex]
    call bind
    mov edi, GL_QUADS
    call glBegin
    xor ebx, ebx
.z:
    cmp ebx, [zip_count]
    jge .done
    movss xmm0, [zip_ay+rbx*4]
    call floor_of_height
    sub eax, [cur_floor]
    cmp eax, VIS_FLOORS
    jg .nz
    cmp eax, -VIS_FLOORS
    jl .nz
    ; cable
    GLF3 glColor3f, 0.3, 0.3, 0.32
    mov eax, [zip_ax+rbx*4]
    mov [rsp+0], eax
    mov eax, [zip_ay+rbx*4]
    mov [rsp+4], eax
    mov eax, [zip_az+rbx*4]
    mov [rsp+8], eax
    mov eax, [zip_bx+rbx*4]
    mov [rsp+16], eax
    mov eax, [zip_by+rbx*4]
    mov [rsp+20], eax
    mov eax, [zip_bz+rbx*4]
    mov [rsp+24], eax
    lea rdi, [rsp+0]
    lea rsi, [rsp+16]
    FLD xmm0, 0.015
    call emit_tube
    ; anchor plates at both ends
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    FLD xmm6, 0.12
    subss xmm1, xmm6
    movss xmm2, [rsp+8]
    FLD xmm3, 0.08
    FLD xmm4, 0.24
    FLD xmm5, 0.08
    mov edi, 0x404448
    call cbox
    movss xmm0, [rsp+16]
    movss xmm1, [rsp+20]
    FLD xmm6, 0.12
    subss xmm1, xmm6
    movss xmm2, [rsp+24]
    FLD xmm3, 0.08
    FLD xmm4, 0.24
    FLD xmm5, 0.08
    mov edi, 0x404448
    call cbox
    ; trolley: parked at the top end, or wherever you are on it
    xorps xmm7, xmm7
    cmp ebx, [zip_active]
    jne .parked
    movss xmm7, [zip_t]
.parked:
    FLD xmm6, 0.02
    maxss xmm7, xmm6
    movss xmm0, [rsp+16]
    subss xmm0, [rsp+0]
    mulss xmm0, xmm7
    addss xmm0, [rsp+0]
    movss xmm1, [rsp+20]
    subss xmm1, [rsp+4]
    mulss xmm1, xmm7
    addss xmm1, [rsp+4]
    FLD xmm6, 0.1
    subss xmm1, xmm6
    movss xmm2, [rsp+24]
    subss xmm2, [rsp+8]
    mulss xmm2, xmm7
    addss xmm2, [rsp+8]
    movss [rsp+32], xmm0
    movss [rsp+36], xmm1
    movss [rsp+40], xmm2
    FLD xmm3, 0.1
    FLD xmm4, 0.14
    FLD xmm5, 0.06
    mov edi, 0xb03020                   ; red trolley
    call cbox
    ; handle bar hanging below it
    movss xmm0, [rsp+32]
    movss xmm1, [rsp+36]
    FLD xmm6, 0.32
    subss xmm1, xmm6
    movss xmm2, [rsp+40]
    FLD xmm3, 0.2
    FLD xmm4, 0.03
    FLD xmm5, 0.03
    mov edi, 0x202020
    call cbox
.nz:
    inc ebx
    jmp .z
.done:
    call glEnd
    GLF3 glColor3f, 1.0, 1.0, 1.0
    EPILOGUE

; draw_hook -- the hookshot's chain, from your left hand to the hook head
draw_hook:
    PROLOGUE 64
    cmp dword [hk_state], 0
    je .done
    ; your left hand: eye + forward*0.45 - right*0.2 - 0.2 down
    movss xmm0, [p_yaw]
    call sinf
    movss [rsp+48], xmm0                ; s
    movss xmm0, [p_yaw]
    call cosf
    movss [rsp+52], xmm0                ; c
    movss xmm0, [rsp+48]                ; x = px - 0.45 s - 0.2 c
    FLD xmm1, -0.45
    mulss xmm0, xmm1
    movss xmm1, [rsp+52]
    FLD xmm2, -0.2
    mulss xmm1, xmm2
    addss xmm0, xmm1
    addss xmm0, [p_x]
    movss [rsp+0], xmm0
    movss xmm0, [p_eye_y]
    FLD xmm1, -0.2
    addss xmm0, xmm1
    movss [rsp+4], xmm0
    movss xmm0, [rsp+52]                ; z = pz - 0.45 c + 0.2 s
    FLD xmm1, -0.45
    mulss xmm0, xmm1
    movss xmm1, [rsp+48]
    FLD xmm2, 0.2
    mulss xmm1, xmm2
    addss xmm0, xmm1
    addss xmm0, [p_z]
    movss [rsp+8], xmm0
    mov eax, [hk_hx]
    mov [rsp+16], eax
    mov eax, [hk_hy]
    mov [rsp+20], eax
    mov eax, [hk_hz]
    mov [rsp+24], eax
    mov edi, [white_tex]
    call bind
    mov edi, GL_QUADS
    call glBegin
    GLF3 glColor3f, 0.42, 0.43, 0.46    ; the chain
    lea rdi, [rsp+0]
    lea rsi, [rsp+16]
    FLD xmm0, 0.014
    call emit_tube
    movss xmm0, [rsp+16]                ; the hook head, brass
    movss xmm1, [rsp+20]
    FLD xmm6, -0.06
    addss xmm1, xmm6
    movss xmm2, [rsp+24]
    FLD xmm3, 0.06
    FLD xmm4, 0.12
    FLD xmm5, 0.06
    mov edi, 0xC9A94A
    call cbox
    call glEnd
    GLF3 glColor3f, 1.0, 1.0, 1.0
.done:
    EPILOGUE

; emit_b -- B, the lord of networking: a tall robed figure
emit_b:
    PROLOGUE 32
    call cell_centre
    movss [b_pos_x], xmm0
    movss [b_pos_y], xmm1
    movss [b_pos_z], xmm2
    mov [b_floor], r12d
    mov ebx, 0x1b2a6b
    call set_rgb
    movss xmm0, [b_pos_x]
    movss xmm1, [b_pos_y]
    movss xmm2, [b_pos_z]
    FLD xmm3, 0.5
    FLD xmm4, 0.2
    FLD xmm5, 1.6
    mov edi, 12
    call emit_cyl
    mov ebx, 0xd8b89a
    call set_rgb
    movss xmm0, [b_pos_x]
    movss xmm1, [b_pos_y]
    FLD xmm6, 1.6
    addss xmm1, xmm6
    movss xmm2, [b_pos_z]
    FLD xmm3, 0.19
    FLD xmm4, 0.19
    FLD xmm5, 0.35
    mov edi, 10
    call emit_cyl
    mov ebx, 0xffffff
    call set_rgb
    EPILOGUE

; collect_fixtures -- ceiling panels on a 3x3 grid of floor cells: mostly
; dead, some steady, some flickering. Plus exit signs and B's aura.
collect_fixtures:
    PROLOGUE 32
    mov dword [fixture_count], 0
    xor r12d, r12d
.f:
    cmp r12d, NF
    jge .extras
    xor r14d, r14d
.y:
    cmp r14d, MAP_H
    jge .nf
    xor r13d, r13d
.x:
    cmp r13d, MAP_W
    jge .ny
    ; grid positions only
    mov eax, r13d
    xor edx, edx
    mov ecx, 3
    div ecx
    cmp edx, 1
    jne .nx
    mov eax, r14d
    xor edx, edx
    mov ecx, 3
    div ecx
    cmp edx, 1
    jne .nx
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_at
    mov ebx, eax
    cmp ebx, ' '
    je .ok
    cmp ebx, 'S'
    je .ok
    cmp ebx, '.'                        ; tall spaces: lights on whatever ceiling
    jne .nx                             ; is over them (checked just below)
.ok:
    ; no fixture where the ceiling is open
    cmp r12d, NF-1
    je .ok2
    lea edi, [r12d+1]
    mov esi, r13d
    mov edx, r14d
    call cell_at
    cmp eax, '.'
    je .nx
.ok2:
    ; state: 16% are alive -- half steady, half flickering
    mov r15d, FX_DEAD
    call rand01
    FLD xmm1, 0.16
    comiss xmm0, xmm1
    jae .state
    mov r15d, FX_ON
    call rand01
    comiss xmm0, [c_half]
    jae .state
    mov r15d, FX_FLICKER
.state:
    mov edx, 0xe8f0ff
    test r12d, r12d
    jnz .col1
    mov edx, 0xffd9a0                   ; warm bulbs in the basement
.col1:
    cmp ebx, 'S'
    jne .col2
    mov edx, 0x7fdcff                   ; safe rooms glow blue
    mov r15d, FX_ON
.col2:
    mov [rsp+0], edx
    call cell_centre
    addss xmm1, [c_fh]
    FLD xmm6, -0.04
    addss xmm1, xmm6
    mov edi, r12d
    mov esi, r15d
    mov edx, [rsp+0]
    call add_fixture
.nx:
    inc r13d
    jmp .x
.ny:
    inc r14d
    jmp .y
.nf:
    inc r12d
    jmp .f
.extras:
    ; exit signs cast a little red light
    xor ebx, ebx
.sign:
    cmp ebx, [sign_count]
    jge .aura
    mov eax, [sign_set+rbx*4]           ; only this building's signs
    cmp eax, [sign_set_cur]
    jne .ns
    cmp dword [sign_exit+rbx*4], 0
    je .ns
    movss xmm0, [sign_x+rbx*4]
    addss xmm0, [c_half]
    mulss xmm0, [c_cell]
    movss xmm2, [sign_z+rbx*4]
    addss xmm2, [c_half]
    mulss xmm2, [c_cell]
    cvtsi2ss xmm1, dword [sign_f+rbx*4]
    mulss xmm1, [c_fh]
    addss xmm1, [c_fh]
    FLD xmm6, -0.55
    addss xmm1, xmm6
    mov edi, [sign_f+rbx*4]
    mov esi, FX_EXIT
    mov edx, 0xff2a2a
    call add_fixture
.ns:
    inc ebx
    jmp .sign
.aura:
    movss xmm0, [b_pos_x]
    movss xmm1, [b_pos_y]
    FLD xmm6, 2.2
    addss xmm1, xmm6
    movss xmm2, [b_pos_z]
    mov edi, [b_floor]
    mov esi, FX_AURA
    mov edx, 0x5fd8ff
    call add_fixture
    EPILOGUE

; -----------------------------------------------------------------------------
; render_init() -- GL state, shaders, textures, display lists, fixtures
; -----------------------------------------------------------------------------
render_init:
    PROLOGUE 32
    call init_shaders
    call textures_init

    mov edi, GL_DEPTH_TEST
    call glEnable
    mov edi, GL_CULL_FACE
    call glDisable
    mov edi, GL_TEXTURE_2D
    call glEnable
    ; fixed-function fog for the unlit pass (the shader does its own)
    mov edi, GL_FOG_MODE
    mov esi, GL_EXP2
    call glFogi
    mov edi, GL_FOG_DENSITY
    movss xmm0, [c_fog]
    call glFogf
    mov edi, GL_FOG_COLOR
    lea rsi, [fog_color]
    call glFogfv
    GLF4 glClearColor, 0.0, 0.0, 0.0, 1.0

    ; ---- display lists: NF * NMAT
    mov edi, NF*NMAT
    call glGenLists
    mov [list_base], eax
    call build_world
    call choose_render_scale
    call init_shadows
    EPILOGUE

; render_rebuild_world -- after world_select: new geometry and lights (the
; building's own signs are picked by world_select: sign_set_cur)
render_rebuild_world:
    PROLOGUE 16
    call find_media_wall
    call build_world
    EPILOGUE

; build_world -- compile every storey's display lists and find the fixtures
build_world:
    PROLOGUE 16
    xor ebx, ebx                        ; storey
.lf:
    cmp ebx, NF
    jge .lists_done
    xor r15d, r15d                      ; material
.lm:
    cmp r15d, NMAT
    jge .lnf
    imul edi, ebx, NMAT
    add edi, r15d
    add edi, [list_base]
    mov esi, GL_COMPILE
    call glNewList
    GLF3 glColor3f, 1.0, 1.0, 1.0
    mov edi, GL_QUADS
    call glBegin
    push rbx
    push r15
    call build_material
    pop r15
    pop rbx
    call glEnd
    call glEndList
    inc r15d
    jmp .lm
.lnf:
    inc ebx
    jmp .lf
.lists_done:
    mov edi, 4321
    call rng_seed
    call collect_fixtures
    mov ecx, NPOOL
    lea rdi, [pool_idx]
    mov eax, -1
    rep stosd
    mov dword [pool_timer], 0
    EPILOGUE

; =============================================================================
; per-frame lighting
; =============================================================================

; flicker_level(ebx=fixture, xmm0=time) -> xmm0 brightness 0..1
flicker_level:
    PROLOGUE 32
    mov eax, [fx_state+rbx*4]
    cmp eax, FX_FLICKER
    je .flick
    movss xmm0, [c_exit_lvl]
    cmp eax, FX_EXIT
    je .out
    movss xmm0, [c_one]
    cmp eax, FX_DEAD
    jne .out
    xorps xmm0, xmm0
    jmp .out
.flick:
    ; n = sin(13t+p)*sin(7.3t+2p) + sin(1.7t+p)
    movss [rsp+0], xmm0
    movss xmm1, [fx_phase+rbx*4]
    movss [rsp+4], xmm1
    mulss xmm0, [c_flick_a]
    addss xmm0, xmm1
    call sinf
    movss [rsp+8], xmm0
    movss xmm0, [rsp+0]
    mulss xmm0, [c_flick_b]
    movss xmm1, [rsp+4]
    addss xmm1, xmm1
    addss xmm0, xmm1
    call sinf
    mulss xmm0, [rsp+8]
    movss [rsp+8], xmm0
    movss xmm0, [rsp+0]
    mulss xmm0, [c_flick_c]
    addss xmm0, [rsp+4]
    call sinf
    addss xmm0, [rsp+8]
    movss xmm1, [c_one]
    comiss xmm0, [c_flick_hi]
    ja .fl_out
    movss xmm1, [c_flick_m]
    comiss xmm0, [c_flick_mid]
    ja .fl_out
    movss xmm1, [c_flick_lo]
.fl_out:
    movaps xmm0, xmm1
.out:
    EPILOGUE

; world_lights_update(xmm0=dt, xmm1=time) -- brightness of every fixture and
; (a few times a second) which fixtures get the six real point lights
world_lights_update:
    PROLOGUE 64
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    ; brightness of each fixture this frame
    xor ebx, ebx
.lvl:
    cmp ebx, [fixture_count]
    jge .lvl_done
    movss xmm0, [rsp+4]
    call flicker_level
    movss [fx_level+rbx*4], xmm0
    inc ebx
    jmp .lvl
.lvl_done:
    ; re-assign the light pool every 0.3s
    movss xmm0, [pool_timer]
    subss xmm0, [rsp+0]
    movss [pool_timer], xmm0
    comiss xmm0, [c_zero]
    ja .upload
    FLD xmm0, 0.3
    movss [pool_timer], xmm0
    ; selection: NPOOL passes, each picking the nearest unchosen live fixture
    mov ecx, NPOOL
    lea rdi, [pool_idx]
    mov eax, -1
    rep stosd
    xor r12d, r12d                      ; pool slot
.pick:
    cmp r12d, NPOOL
    jge .upload
    mov r13d, -1                        ; best index
    movss xmm7, [c_pool_dist]           ; best distance^2
    xor ebx, ebx
.cand:
    cmp ebx, [fixture_count]
    jge .picked
    cmp dword [fx_state+rbx*4], FX_DEAD
    je .ncand
    ; already chosen?
    xor ecx, ecx
.chk:
    cmp ecx, r12d
    jge .fresh
    cmp [pool_idx+rcx*4], ebx
    je .ncand
    inc ecx
    jmp .chk
.fresh:
    movss xmm0, [fx_x+rbx*4]
    subss xmm0, [p_x]
    mulss xmm0, xmm0
    movss xmm1, [fx_z+rbx*4]
    subss xmm1, [p_z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    movss xmm1, [fx_y+rbx*4]
    subss xmm1, [p_y]
    mulss xmm1, xmm1
    mulss xmm1, [c_ywt]
    addss xmm0, xmm1
    comiss xmm0, xmm7
    jae .ncand
    movaps xmm7, xmm0
    mov r13d, ebx
.ncand:
    inc ebx
    jmp .cand
.picked:
    mov [pool_idx+r12*4], r13d
    inc r12d
    jmp .pick
.upload:
    ; position + colour*power*level for each pooled light
    xor r12d, r12d
.up:
    cmp r12d, NPOOL
    jge .done
    imul r14d, r12d, 12
    mov ebx, [pool_idx+r12*4]
    xorps xmm0, xmm0
    movss [lc_buf+r14], xmm0
    movss [lc_buf+r14+4], xmm0
    movss [lc_buf+r14+8], xmm0
    cmp ebx, 0
    jl .nup
    movss xmm0, [fx_x+rbx*4]
    movss [lp_buf+r14], xmm0
    movss xmm0, [fx_y+rbx*4]
    subss xmm0, [c_fix_off]
    movss [lp_buf+r14+4], xmm0
    movss xmm0, [fx_z+rbx*4]
    movss [lp_buf+r14+8], xmm0
    movss xmm1, [c_light_on]
    mov eax, [fx_state+rbx*4]
    cmp eax, FX_EXIT
    jne .p1
    movss xmm1, [c_light_exit]
.p1:
    cmp eax, FX_AURA
    jne .p2
    movss xmm1, [c_light_aura]
.p2:
    mulss xmm1, [fx_level+rbx*4]
    movss xmm0, [fx_r+rbx*4]
    mulss xmm0, xmm1
    movss [lc_buf+r14], xmm0
    movss xmm0, [fx_g+rbx*4]
    mulss xmm0, xmm1
    movss [lc_buf+r14+4], xmm0
    movss xmm0, [fx_b+rbx*4]
    mulss xmm0, xmm1
    movss [lc_buf+r14+8], xmm0
.nup:
    inc r12d
    jmp .up
.done:
    EPILOGUE

; =============================================================================
; drawing
; =============================================================================

; upload_frame_uniforms -- camera, flashlight, ambient and the light pool
; into the current program
upload_frame_uniforms:
    PROLOGUE 16
    mov edi, [u_fpos]
    movss xmm0, [flash_pos]
    movss xmm1, [flash_pos+4]
    movss xmm2, [flash_pos+8]
    GL2CALL glUniform3f
    mov edi, [u_smat]
    mov esi, 1
    xor edx, edx
    lea rcx, [shadow_mat]
    GL2CALL glUniformMatrix4fv
    mov edi, [u_son]
    cvtsi2ss xmm0, dword [shadows_on]
    GL2CALL glUniform1f
    mov edi, [u_cam]
    movss xmm0, [cam_x]
    movss xmm1, [cam_y]
    movss xmm2, [cam_z]
    GL2CALL glUniform3f
    mov edi, [u_fdir]
    movss xmm0, [fdir]
    movss xmm1, [fdir+4]
    movss xmm2, [fdir+8]
    GL2CALL glUniform3f
    mov edi, [u_flash]
    movss xmm0, [p_flash_level]
    GL2CALL glUniform1f
    mov edi, [u_amb]
    movss xmm0, [amb_col]
    movss xmm1, [amb_col+4]
    movss xmm2, [amb_col+8]
    GL2CALL glUniform3f
    mov edi, [u_lp]
    mov esi, NPOOL
    lea rdx, [lp_buf]
    GL2CALL glUniform3fv
    mov edi, [u_lc]
    mov esi, NPOOL
    lea rdx, [lc_buf]
    GL2CALL glUniform3fv
    xorps xmm0, xmm0
    call set_emit
    EPILOGUE

; setup_camera(edi=w, esi=h) -- projection + view (Rz(-roll) Rx(-pitch) Ry(-yaw) T(-cam))
setup_camera:
    PROLOGUE 32
    mov r12d, edi
    mov r13d, esi
    ; field of view from the settings: tan(fov / 2)
    cvtsi2ss xmm0, dword [cfg_fov]
    mulss xmm0, [c_half_deg]
    call tanf
    cvtss2sd xmm0, xmm0
    movsd [fovtan_cur], xmm0
    xor edi, edi
    xor esi, esi
    mov edx, r12d
    mov ecx, r13d
    call glViewport
    mov edi, GL_PROJECTION
    call glMatrixMode
    call glLoadIdentity
    ; glFrustum(-r, r, -t, t, near, far) in doubles
    movsd xmm2, [c_near]
    mulsd xmm2, [fovtan_cur]            ; t
    movss xmm6, [trav_fov]              ; zipline speed widens the view
    addss xmm6, [c_one]
    cvtss2sd xmm6, xmm6
    mulsd xmm2, xmm6
    movsd xmm3, xmm2
    cvtsi2sd xmm4, r12d
    cvtsi2sd xmm5, r13d
    divsd xmm4, xmm5                    ; aspect
    movsd xmm1, xmm2
    mulsd xmm1, xmm4                    ; r
    movsd xmm0, xmm1
    xorpd xmm0, [dsign]                 ; -r
    movsd [rsp+0], xmm3
    movsd xmm3, [rsp+0]                 ; t
    movsd xmm2, xmm3
    xorpd xmm2, [dsign]                 ; -t
    movsd xmm4, [c_near]
    movsd xmm5, [c_far]
    call glFrustum
    mov edi, GL_MODELVIEW
    call glMatrixMode
    call glLoadIdentity
    movss xmm0, [p_roll]
    mulss xmm0, [c_rad2deg]
    xorps xmm0, [c_sign_mask]
    xorps xmm1, xmm1
    xorps xmm2, xmm2
    movss xmm3, [c_one]
    call glRotatef
    movss xmm0, [p_pitch]
    mulss xmm0, [c_rad2deg]
    xorps xmm0, [c_sign_mask]
    movss xmm1, [c_one]
    xorps xmm2, xmm2
    xorps xmm3, xmm3
    call glRotatef
    movss xmm0, [p_yaw]
    mulss xmm0, [c_rad2deg]
    xorps xmm0, [c_sign_mask]
    xorps xmm1, xmm1
    movss xmm2, [c_one]
    xorps xmm3, xmm3
    call glRotatef
    movss xmm0, [cam_x]
    xorps xmm0, [c_sign_mask]
    movss xmm1, [cam_y]
    xorps xmm1, [c_sign_mask]
    movss xmm2, [cam_z]
    xorps xmm2, [c_sign_mask]
    call glTranslatef
    EPILOGUE

RODATA
align 16
dsign dq 0x8000000000000000, 0
section .text

; face_camera_yaw(xmm0=x, xmm1=z) -> xmm0 = yaw that turns local +Z toward the camera
face_camera_yaw:
    sub rsp, 8
    movss xmm2, [cam_x]
    subss xmm2, xmm0
    movss xmm3, [cam_z]
    subss xmm3, xmm1
    movaps xmm0, xmm2
    movaps xmm1, xmm3
    call atan2f
    add rsp, 8
    ret

; quad_xy(xmm0=half w, xmm1=y0, xmm2=y1, xmm3=z) -- a local-space quad facing +Z
; (for billboards; call inside glBegin(GL_QUADS) with a model matrix set)
quad_xy:
    sub rsp, 8
    movaps xmm3, xmm0
    xorps xmm3, [c_sign_mask]
    movss [bx0], xmm3
    movss [bx1], xmm0
    movss [by0], xmm1
    movss [by1], xmm2
    movss [bz0], xmm3
    movss [bz1], xmm3
    mov dword [u_rep], __float32__(1.0)
    mov dword [v_rep], __float32__(1.0)
    mov edi, F_PZ
    call emit_box
    add rsp, 8
    ret

; draw_signs(edi=exit?) -- hanging signs: lit ones through the shader, exit
; signs in the unlit pass. Each sign is a 2cm-thick board whose front (+Z)
; and back (-Z) faces both read correctly (emit_box runs u the right way
; on each side), so the text is never mirrored.
draw_signs:
    PROLOGUE 32
    mov r12d, edi
    xor ebx, ebx
.s:
    cmp ebx, [sign_count]
    jge .done
    mov eax, [sign_set+rbx*4]           ; only this building's signs
    cmp eax, [sign_set_cur]
    jne .n
    mov eax, [sign_exit+rbx*4]
    cmp eax, r12d
    jne .n
    mov eax, [sign_f+rbx*4]
    sub eax, [cur_floor]
    cmp eax, VIS_FLOORS
    jg .n
    cmp eax, -VIS_FLOORS
    jl .n
    movss xmm0, [sign_x+rbx*4]
    addss xmm0, [c_half]
    mulss xmm0, [c_cell]
    cvtsi2ss xmm1, dword [sign_f+rbx*4]
    mulss xmm1, [c_fh]
    addss xmm1, [c_fh]
    FLD xmm6, -0.55
    addss xmm1, xmm6
    movss xmm2, [sign_z+rbx*4]
    addss xmm2, [c_half]
    mulss xmm2, [c_cell]
    xorps xmm3, xmm3
    cmp dword [sign_face+rbx*4], 0
    je .yaw
    movss xmm3, [c_pi]
    mulss xmm3, [c_half]
.yaw:
    movss [rsp+0], xmm3
    call model_begin
    mov edi, [sign_tex+rbx*4]
    call bind
    mov edi, GL_QUADS
    call glBegin
    BOX -0.75, -0.1875, -0.01, 0.75, 0.1875, 0.01
    mov dword [u_rep], __float32__(1.0)
    mov dword [v_rep], __float32__(1.0)
    mov edi, F_PZ|F_NZ
    call emit_box
    call glEnd
    call model_end
.n:
    inc ebx
    jmp .s
.done:
    EPILOGUE

; draw_items -- spinning .pcap cubes, deauth packets, Tyler, the chicken jockey
draw_items:
    PROLOGUE 48
    xor ebx, ebx
.it:
    cmp ebx, [item_count]
    jge .done
    imul r12d, ebx, ITEM_SIZE
    lea r12, [items+r12]
    cmp dword [r12+ITEM_ACTIVE], 0
    je .n
    mov eax, [r12+ITEM_F]
    sub eax, [cur_floor]
    cmp eax, VIS_FLOORS
    jg .n
    cmp eax, -VIS_FLOORS
    jl .n
    mov eax, [r12+ITEM_KIND]
    cmp eax, IT_TYLER
    jge .npc
    ; spin + bob
    movss xmm0, [elapsed_time]
    movss [rsp+0], xmm0
    FLD xmm1, 2.0
    mulss xmm0, xmm1
    addss xmm0, [r12+ITEM_X]
    call sinf
    FLD xmm1, 0.08
    mulss xmm0, xmm1
    addss xmm0, [r12+ITEM_Y]
    FLD xmm1, 0.9
    addss xmm0, xmm1
    movaps xmm1, xmm0
    movss xmm0, [r12+ITEM_X]
    movss xmm2, [r12+ITEM_Z]
    movss xmm3, [rsp+0]
    FLD xmm4, 1.6
    mulss xmm3, xmm4
    call model_begin
    movss xmm0, [c_item_emit]
    call set_emit
    cmp dword [r12+ITEM_KIND], IT_DEW
    je .dew_can
    mov eax, [r12+ITEM_KIND]
    mov edi, [label_tex+rax*4]
    call bind
    mov edi, GL_QUADS
    call glBegin
    ; the shape depends on the kind (half sizes from item_half_*)
    mov eax, [r12+ITEM_KIND]
    movss xmm0, [item_half_x+rax*4]
    movss xmm1, [item_half_y+rax*4]
    movss xmm2, [item_half_z+rax*4]
    movss [bx1], xmm0
    movss [by1], xmm1
    movss [bz1], xmm2
    xorps xmm0, [c_sign_mask]
    xorps xmm1, [c_sign_mask]
    xorps xmm2, [c_sign_mask]
    movss [bx0], xmm0
    movss [by0], xmm1
    movss [bz0], xmm2
    mov dword [u_rep], __float32__(1.0)
    mov dword [v_rep], __float32__(1.0)
    mov edi, F_ALL
    call emit_box
    call glEnd
    call model_end
    xorps xmm0, xmm0
    call set_emit
    jmp .n
.dew_can:
    ; a can of Diet Mountain Dew: silver ends, green body, the red DIET band
    mov edi, [white_tex]
    call bind
    mov edi, GL_QUADS
    call glBegin
    push rbx
    push rbx
    mov ebx, 0xc8ccd0
    call set_rgb
    xorps xmm0, xmm0
    FLD xmm1, -0.17
    xorps xmm2, xmm2
    FLD xmm3, 0.085
    FLD xmm4, 0.1
    FLD xmm5, 0.03
    mov edi, 14
    call emit_cyl
    mov ebx, 0x1f9a3a
    call set_rgb
    xorps xmm0, xmm0
    FLD xmm1, -0.14
    xorps xmm2, xmm2
    FLD xmm3, 0.1
    FLD xmm4, 0.1
    FLD xmm5, 0.24
    mov edi, 14
    call emit_cyl
    mov ebx, 0xd02028
    call set_rgb
    xorps xmm0, xmm0
    FLD xmm1, -0.03
    xorps xmm2, xmm2
    FLD xmm3, 0.102
    FLD xmm4, 0.102
    FLD xmm5, 0.05
    mov edi, 14
    call emit_cyl
    mov ebx, 0xc8ccd0
    call set_rgb
    xorps xmm0, xmm0
    FLD xmm1, 0.1
    xorps xmm2, xmm2
    FLD xmm3, 0.1
    FLD xmm4, 0.078
    FLD xmm5, 0.04
    mov edi, 14
    call emit_cyl
    xorps xmm0, xmm0
    FLD xmm1, 0.14
    xorps xmm2, xmm2
    FLD xmm3, 0.078
    xorps xmm4, xmm4
    FLD xmm5, 0.005
    mov edi, 14
    call emit_cyl
    mov ebx, 0xffffff
    call set_rgb
    pop rbx
    pop rbx
    call glEnd
    call model_end
    xorps xmm0, xmm0
    call set_emit
    jmp .n
.npc:
    ; NPCs turn to face you
    movss xmm0, [r12+ITEM_X]
    movss xmm1, [r12+ITEM_Z]
    call face_camera_yaw
    movaps xmm3, xmm0
    movss xmm0, [r12+ITEM_X]
    movss xmm1, [r12+ITEM_Y]
    movss xmm2, [r12+ITEM_Z]
    call model_begin
    mov edi, [white_tex]
    call bind
    mov edi, GL_QUADS
    call glBegin
    cmp dword [r12+ITEM_KIND], IT_TYLER
    jne .jockey
    ; Tyler: green hoodie + head
    mov ebx, 0x3b5d3a
    push rbx
    push rbx
    call set_rgb
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    xorps xmm2, xmm2
    FLD xmm3, 0.3
    FLD xmm4, 0.25
    FLD xmm5, 1.2
    mov edi, 10
    call emit_cyl
    mov ebx, 0xd8b494
    call set_rgb
    xorps xmm0, xmm0
    FLD xmm1, 1.22
    xorps xmm2, xmm2
    FLD xmm3, 0.18
    FLD xmm4, 0.18
    FLD xmm5, 0.36
    mov edi, 10
    call emit_cyl
    pop rbx
    pop rbx
    jmp .npc_done
.jockey:
    ; a small blue-shirted zombie riding a chicken
    push rbx
    push rbx
    xorps xmm0, xmm0
    FLD xmm1, 0.22
    xorps xmm2, xmm2
    FLD xmm3, 0.2
    FLD xmm4, 0.35
    FLD xmm5, 0.25
    mov edi, 0xf2f2ee
    call cbox
    xorps xmm0, xmm0
    FLD xmm1, 0.55
    FLD xmm2, 0.28
    FLD xmm3, 0.11
    FLD xmm4, 0.3
    FLD xmm5, 0.1
    mov edi, 0xf2f2ee
    call cbox
    xorps xmm0, xmm0
    FLD xmm1, 0.67
    FLD xmm2, 0.42
    FLD xmm3, 0.06
    FLD xmm4, 0.06
    FLD xmm5, 0.05
    mov edi, 0xe0a020
    call cbox
    xorps xmm0, xmm0
    FLD xmm1, 0.6
    xorps xmm2, xmm2
    FLD xmm3, 0.11
    FLD xmm4, 0.3
    FLD xmm5, 0.07
    mov edi, 0x2f7fbf
    call cbox
    xorps xmm0, xmm0
    FLD xmm1, 0.9
    xorps xmm2, xmm2
    FLD xmm3, 0.1
    FLD xmm4, 0.2
    FLD xmm5, 0.1
    mov edi, 0x4f9f4f
    call cbox
    pop rbx
    pop rbx
.npc_done:
    mov ebx, 0xffffff
    call set_rgb
    call glEnd
    call model_end
    ; restore loop counter clobbered by set_rgb's use of ebx
    mov rax, r12
    sub rax, items
    xor edx, edx
    mov ecx, ITEM_SIZE
    div ecx
    mov ebx, eax
.n:
    inc ebx
    jmp .it
.done:
    EPILOGUE

; draw_t -- the cloaked figure with long arms and the face that always looks
; at you. Glitches while stunned. Glows red while chasing.
draw_t:
    PROLOGUE 64
    cmp dword [rag_active], 0
    jne .done
    movss xmm0, [t_y]
    call floor_of_height
    sub eax, [cur_floor]
    cmp eax, VIS_FLOORS
    jg .done
    cmp eax, -VIS_FLOORS
    jl .done
    ; stunned: flicker out 35% of frames, jitter
    xorps xmm6, xmm6
    movss [rsp+16], xmm6                ; jitter x
    movss [rsp+20], xmm6                ; jitter z
    movss xmm0, [t_stun]
    comiss xmm0, [c_zero]
    jbe .solid
    call rand01
    FLD xmm1, 0.35
    comiss xmm0, xmm1
    jb .done
    call rand01
    subss xmm0, [c_half]
    FLD xmm1, 0.3
    mulss xmm0, xmm1
    movss [rsp+16], xmm0
    call rand01
    subss xmm0, [c_half]
    FLD xmm1, 0.3
    mulss xmm0, xmm1
    movss [rsp+20], xmm0
.solid:
    movss xmm0, [t_x]
    addss xmm0, [rsp+16]
    movss [rsp+0], xmm0
    movss xmm1, [t_z]
    addss xmm1, [rsp+20]
    movss [rsp+8], xmm1
    call face_camera_yaw
    movaps xmm3, xmm0
    movss xmm0, [rsp+0]
    movss xmm1, [t_y]
    movss xmm2, [rsp+8]
    call model_begin
    mov edi, [white_tex]
    call bind
    mov edi, GL_QUADS
    call glBegin
    GLF3 glColor3f, 0.043, 0.043, 0.05
    ; cloak (open tapered cylinder)
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    xorps xmm2, xmm2
    FLD xmm3, 0.55
    FLD xmm4, 0.22
    FLD xmm5, 1.75
    mov edi, 12
    call emit_cyl
    ; hunched shoulders
    BOX -0.4, 1.66, -0.22, 0.4, 1.84, 0.22
    mov edi, F_ALL
    call emit_box
    ; arms swing opposite each other: bottom end moves forward/back
    movss xmm0, [t_anim_phase]
    call sinf
    cvtsi2ss xmm1, dword [t_moving]
    mulss xmm0, xmm1
    FLD xmm1, 0.45
    mulss xmm0, xmm1
    movss [rsp+24], xmm0                ; swing
    FLD xmm0, -0.4
    FLD xmm1, 1.75
    xorps xmm2, xmm2
    FLD xmm3, -0.44
    FLD xmm4, 0.4
    movss xmm5, [rsp+24]
    FLD xmm6, 0.05
    call emit_limb
    FLD xmm0, 0.4
    FLD xmm1, 1.75
    xorps xmm2, xmm2
    FLD xmm3, 0.44
    FLD xmm4, 0.4
    movss xmm5, [rsp+24]
    xorps xmm5, [c_sign_mask]
    FLD xmm6, 0.05
    call emit_limb
    call glEnd

    ; the face: a billboard with T_Sprite.jpeg, glowing faintly (red when
    ; chasing). Its oval mask needs the alpha-tested program.
    mov edi, 1
    call use_program
    mov edi, [u_model]
    mov esi, 1
    xor edx, edx
    lea rcx, [model_mat]
    GL2CALL glUniformMatrix4fv
    movss xmm0, [c_face_emit]
    cmp dword [t_state], T_CHASE
    jne .fe
    movss xmm0, [c_face_chase]
.fe:
    call set_emit
    mov edi, [face_tex]
    call bind
    GLF3 glColor3f, 1.0, 1.0, 1.0
    cmp dword [t_state], T_CHASE
    jne .tint
    GLF3 glColor3f, 1.0, 0.6, 0.55
.tint:
    mov edi, GL_QUADS
    call glBegin
    ; slight wobble
    movss xmm0, [elapsed_time]
    FLD xmm1, 1.3
    mulss xmm0, xmm1
    call sinf
    FLD xmm1, 0.03
    mulss xmm0, xmm1
    movss [rsp+28], xmm0
    FLD xmm0, 0.31
    FLD xmm1, 1.71
    addss xmm1, [rsp+28]
    FLD xmm2, 2.33
    addss xmm2, [rsp+28]
    FLD xmm3, 0.2                       ; in front of the hood
    call quad_xy
    call glEnd
    GLF3 glColor3f, 1.0, 1.0, 1.0
    xorps xmm0, xmm0
    call set_emit
    call model_end
    xor edi, edi
    call use_program
    ; program 0 still holds T's model matrix from model_begin above (the face
    ; switched programs before model_end reset it) -- reset it here too, or
    ; everything drawn next would be lit as if it stood where T is
    mov edi, [u_model]
    mov esi, 1
    xor edx, edx
    lea rcx, [identity]
    GL2CALL glUniformMatrix4fv
.done:
    EPILOGUE

; draw_billboard_label(xmm0=x, xmm1=y, xmm2=z, edi=texture, xmm3=half size)
draw_billboard_label:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    mov ebx, edi
    movaps xmm1, xmm2
    call face_camera_yaw
    movaps xmm3, xmm0
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+8]
    call model_begin
    mov edi, ebx
    call bind
    mov edi, GL_QUADS
    call glBegin
    movss xmm0, [rsp+12]
    movaps xmm1, xmm0
    xorps xmm1, [c_sign_mask]
    movss xmm2, [rsp+12]
    xorps xmm3, xmm3
    call quad_xy
    call glEnd
    call model_end
    EPILOGUE

; draw_fixtures -- the light panels themselves (unlit pass)
draw_fixtures:
    PROLOGUE 32
    mov edi, [white_tex]
    call bind
    mov edi, GL_QUADS
    call glBegin
    xor ebx, ebx
.f:
    cmp ebx, [fixture_count]
    jge .done
    mov eax, [fx_state+rbx*4]
    cmp eax, FX_EXIT
    jge .n
    mov eax, [fx_f+rbx*4]
    sub eax, [cur_floor]
    cmp eax, VIS_FLOORS
    jg .n
    cmp eax, -VIS_FLOORS
    jl .n
    movss xmm3, [fx_level+rbx*4]
    maxss xmm3, [c_fix_dead]
    movss xmm0, [fx_r+rbx*4]
    mulss xmm0, xmm3
    movss xmm1, [fx_g+rbx*4]
    mulss xmm1, xmm3
    movss xmm2, [fx_b+rbx*4]
    mulss xmm2, xmm3
    call glColor3f
    movss xmm0, [fx_x+rbx*4]
    movss xmm1, [fx_y+rbx*4]
    movss xmm2, [fx_z+rbx*4]
    FLD xmm3, 0.35
    FLD xmm4, 0.04
    FLD xmm5, 0.75
    call box_at
    mov edi, F_NY
    call emit_box
.n:
    inc ebx
    jmp .f
.done:
    call glEnd
    GLF3 glColor3f, 1.0, 1.0, 1.0
    EPILOGUE

; draw_glows -- faint coloured discs under items (additive, unlit)
draw_glows:
    PROLOGUE 32
    mov edi, [radial_tex]
    call bind
    mov edi, GL_QUADS
    call glBegin
    xor ebx, ebx
.it:
    cmp ebx, [item_count]
    jge .done
    imul eax, ebx, ITEM_SIZE
    lea r12, [items+rax]
    cmp dword [r12+ITEM_ACTIVE], 0
    je .n
    mov eax, [r12+ITEM_KIND]
    cmp eax, IT_TYLER
    jge .n
    mov eax, [r12+ITEM_KIND]
    lea rax, [rax*3]
    movss xmm0, [item_glow+rax*4]
    movss xmm1, [item_glow+rax*4+4]
    movss xmm2, [item_glow+rax*4+8]
    FLD xmm3, 0.35
    call glColor4f
    movss xmm0, [r12+ITEM_X]
    movss xmm1, [r12+ITEM_Y]
    FLD xmm6, 0.02
    addss xmm1, xmm6
    movss xmm2, [r12+ITEM_Z]
    FLD xmm3, 0.8
    xorps xmm4, xmm4
    FLD xmm5, 0.8
    call box_at
    mov edi, F_PY
    call emit_box
.n:
    inc ebx
    jmp .it
.done:
    call glEnd
    GLF4 glColor4f, 1.0, 1.0, 1.0, 1.0
    EPILOGUE

; -----------------------------------------------------------------------------
; draw_scene(xmm0=time) -- everything in the 3D world, seen from the current
; camera (cam_x/y/z, the GL matrices and cur_floor). render_frame draws it
; once for your eyes and portal.asm again through each portal.
; -----------------------------------------------------------------------------
draw_scene:
    PROLOGUE 64
    movss [rsp+8], xmm0
    xor edi, edi
    call use_program
    ; ---- static world: storeys within one of the player's
    xor r12d, r12d                      ; every storey: the atrium sees them all
.fl:
    cmp r12d, NF-1
    jg .fl_done
    cmp r12d, 0
    jl .fl_next
    cmp r12d, NF
    jge .fl_next
    xor r13d, r13d
.mat:
    cmp r13d, NLIT
    jge .fl_next
    ; texture
    mov eax, [mat_tex+r13*4]
    mov edi, [white_tex]
    cmp eax, 0
    jl .tx
    mov edi, [tex_ids+rax*4]
.tx:
    call bind
    ; emission: safe-room walls pulse, racks glow a little
    xorps xmm0, xmm0
    cmp r13d, M_N
    jne .e1
    movss xmm0, [rsp+8]
    FLD xmm1, 1.5
    mulss xmm0, xmm1
    call sinf
    mulss xmm0, [c_n_pulse]
    addss xmm0, [c_n_emit]
.e1:
    cmp r13d, M_RACK
    jne .e2
    movss xmm0, [c_rack_emit]
.e2:
    call set_emit
    movss xmm0, [mat_bump+r13*4]
    movss xmm1, [mat_spec+r13*4]
    call set_material
    imul edi, r12d, NMAT
    add edi, r13d
    add edi, [list_base]
    call glCallList
    inc r13d
    jmp .mat
.fl_next:
    inc r12d
    jmp .fl
.fl_done:
    xorps xmm0, xmm0
    call set_emit
    xorps xmm0, xmm0                    ; moving things: smooth, nearly matte
    FLD xmm1, 0.08
    call set_material

    ; ---- lit dynamic things
    movss xmm0, [c_sign_emit]
    call set_emit
    xor edi, edi
    call draw_signs
    xorps xmm0, xmm0
    call set_emit
    call draw_items
    call draw_t
    call draw_physics
    call draw_ziplines
    call draw_hook
    ; Y's plaque on the cage
    cmp dword [cur_floor], 1
    jg .no_y
    movss xmm0, [y_pos_x]
    FLD xmm1, 1.9
    movss xmm2, [y_pos_z]
    FLD xmm3, 0.3
    mov edi, [label_tex+LBL_Y*4]
    call draw_billboard_label

.no_y:
    ; ---- unlit pass: things that glow
    xor edi, edi
    GL2CALL glUseProgram
    mov edi, GL_FOG
    call glEnable
    call draw_fixtures
    mov edi, 1
    call draw_signs
    ; monitors left on + rack LEDs (LEDs blink by modulating their colour)
    mov edi, GL_BLEND
    call glEnable
    mov edi, GL_SRC_ALPHA
    mov esi, GL_ONE_MINUS_SRC_ALPHA
    call glBlendFunc
    xor r12d, r12d                      ; every storey: the atrium sees them all
.ul:
    cmp r12d, NF-1
    jg .ul_done
    cmp r12d, 0
    jl .ul_next
    cmp r12d, NF
    jge .ul_next
    mov edi, [white_tex]
    call bind
    imul edi, r12d, NMAT
    add edi, M_SCREEN
    add edi, [list_base]
    call glCallList
    mov edi, [led_tex]
    call bind
    movss xmm0, [rsp+8]
    mulss xmm0, [c_led_speed]
    call sinf
    mulss xmm0, [c_led_b]
    addss xmm0, [c_led_a]
    movaps xmm1, xmm0
    movaps xmm2, xmm0
    movss xmm3, [c_one]
    call glColor4f
    imul edi, r12d, NMAT
    add edi, M_LED
    add edi, [list_base]
    call glCallList
    GLF4 glColor4f, 1.0, 1.0, 1.0, 1.0
.ul_next:
    inc r12d
    jmp .ul
.ul_done:
    ; B's halo and floating name tag
    mov eax, [b_floor]
    sub eax, [cur_floor]
    cmp eax, VIS_FLOORS
    jg .no_b
    cmp eax, -VIS_FLOORS
    jl .no_b
    mov edi, [white_tex]
    call bind
    GLF3 glColor3f, 0.37, 0.85, 1.0
    mov edi, GL_QUADS
    call glBegin
    movss xmm0, [rsp+8]
    FLD xmm1, 2.0
    mulss xmm0, xmm1
    call sinf
    FLD xmm1, 0.15
    mulss xmm0, xmm1
    addss xmm0, [b_pos_y]
    FLD xmm1, 0.9
    addss xmm0, xmm1
    movaps xmm1, xmm0
    movss xmm0, [b_pos_x]
    movss xmm2, [b_pos_z]
    FLD xmm3, 0.7
    FLD xmm4, 0.07
    call emit_ring
    call glEnd
    GLF3 glColor3f, 1.0, 1.0, 1.0
    movss xmm0, [b_pos_x]
    movss xmm1, [b_pos_y]
    FLD xmm6, 2.35
    addss xmm1, xmm6
    movss xmm2, [b_pos_z]
    FLD xmm3, 0.25
    mov edi, [label_tex+LBL_B*4]
    call draw_billboard_label
.no_b:
    ; glows under items (no depth writes so they don't hide each other)
    xor edi, edi
    call glDepthMask
    call draw_glows
    mov edi, 1
    call glDepthMask
    ; portal rims glow like everything else in this pass
    movss xmm0, [rsp+8]
    call portal_draw_rims
    ; the media wall: the screens are the light
    movss xmm0, [rsp+8]
    call draw_media_wall
    ; glass last: see-through, and lit like everything else
    call draw_glass
    mov edi, GL_FOG
    call glDisable
    mov edi, GL_BLEND
    call glDisable
    EPILOGUE

; draw_glass -- every storey's glass walls, blended over what's behind them
draw_glass:
    PROLOGUE 16
    xor edi, edi
    call use_program
    mov edi, [white_tex]
    call bind
    xorps xmm0, xmm0
    call set_emit
    xorps xmm0, xmm0
    FLD xmm1, 0.95                      ; glossy: catches the flashlight
    call set_material
    mov edi, GL_BLEND
    call glEnable
    mov edi, GL_SRC_ALPHA
    mov esi, GL_ONE_MINUS_SRC_ALPHA
    call glBlendFunc
    xor edi, edi
    call glDepthMask
    xor ebx, ebx
.f:
    cmp ebx, NF
    jge .done
    imul edi, ebx, NMAT
    add edi, M_GLASS
    add edi, [list_base]
    call glCallList
    inc ebx
    jmp .f
.done:
    mov edi, 1
    call glDepthMask
    xor edi, edi
    GL2CALL glUseProgram
    EPILOGUE

; find_media_wall -- where the building's media wall ('W' cells) is: one run
; of wall cells, screens on its west face
find_media_wall:
    PROLOGUE 16
    mov dword [mw_on], 0
    xor ebx, ebx
.c:
    cmp ebx, NCELLS
    jge .done
    cmp byte [grid+rbx], 'W'
    jne .n
    mov eax, ebx
    xor edx, edx
    mov ecx, MAP_W
    div ecx                             ; eax = f*MAP_H + y, edx = x
    mov r12d, edx
    xor edx, edx
    mov ecx, MAP_H
    div ecx                             ; eax = f, edx = y
    cmp dword [mw_on], 0
    jne .more
    mov dword [mw_on], 1
    cvtsi2ss xmm0, r12d
    mulss xmm0, [c_cell]
    movss [mw_x], xmm0                  ; the west face
    cvtsi2ss xmm0, eax
    mulss xmm0, [c_fh]
    movss [mw_y0], xmm0
    cvtsi2ss xmm0, edx
    mulss xmm0, [c_cell]
    movss [mw_z0], xmm0
.more:
    inc edx
    cvtsi2ss xmm0, edx
    mulss xmm0, [c_cell]
    movss [mw_z1], xmm0                 ; (cells come in order: the last one wins)
.n:
    inc ebx
    jmp .c
.done:
    EPILOGUE

; draw_media_wall(xmm0 = time) -- 25 TVs in a 5 x 5 grid, together one huge
; screen: a Wireshark packet list scrolling up, each TV its own slice of it
draw_media_wall:
    PROLOGUE 64
    cmp dword [mw_on], 0
    je .done
    FLD xmm1, 0.035
    mulss xmm0, xmm1
    movss [rsp+0], xmm0                 ; scroll
    ; a black backing panel
    mov edi, [white_tex]
    call bind
    GLF4 glColor4f, 0.02, 0.02, 0.025, 1.0
    mov edi, GL_QUADS
    call glBegin
    movss xmm0, [mw_z0]
    addss xmm0, [mw_z1]
    mulss xmm0, [c_half]
    movss [rsp+4], xmm0                 ; middle of the wall
    FLD xmm1, -2.72
    addss xmm0, xmm1
    movss [rsp+8], xmm0                 ; panel left
    FLD xmm1, 5.44
    addss xmm0, xmm1
    movss [rsp+12], xmm0                ; panel right
    movss xmm0, [mw_y0]
    FLD xmm1, 0.18
    addss xmm0, xmm1
    movss [rsp+16], xmm0                ; panel bottom
    FLD xmm1, 2.98
    addss xmm0, xmm1
    movss [rsp+20], xmm0                ; panel top
    movss xmm0, [mw_x]
    FLD xmm1, -0.015
    addss xmm0, xmm1
    movss [rsp+24], xmm0
    movss xmm0, [rsp+24]
    movss xmm1, [rsp+20]
    movss xmm2, [rsp+8]
    call glVertex3f
    movss xmm0, [rsp+24]
    movss xmm1, [rsp+20]
    movss xmm2, [rsp+12]
    call glVertex3f
    movss xmm0, [rsp+24]
    movss xmm1, [rsp+16]
    movss xmm2, [rsp+12]
    call glVertex3f
    movss xmm0, [rsp+24]
    movss xmm1, [rsp+16]
    movss xmm2, [rsp+8]
    call glVertex3f
    call glEnd
    ; the screens (they glow: no fog on them)
    mov edi, GL_FOG
    call glDisable
    mov edi, [media_tex]
    call bind
    GLF4 glColor4f, 1.0, 1.0, 1.0, 1.0
    movss xmm0, [mw_x]
    FLD xmm1, -0.03
    addss xmm0, xmm1
    movss [rsp+24], xmm0
    mov edi, GL_QUADS
    call glBegin
    xor r12d, r12d                      ; row (top first)
.row:
    cmp r12d, 5
    jge .rows_done
    xor r13d, r13d                      ; column (left = north)
.col:
    cmp r13d, 5
    jge .nrow
    cvtsi2ss xmm0, r13d
    FLD xmm1, 1.06
    mulss xmm0, xmm1
    addss xmm0, [rsp+8]
    FLD xmm1, 0.06
    addss xmm0, xmm1
    movss [rsp+28], xmm0                ; z left
    FLD xmm1, 1.0
    addss xmm0, xmm1
    movss [rsp+32], xmm0                ; z right
    cvtsi2ss xmm0, r12d
    FLD xmm1, -0.59
    mulss xmm0, xmm1
    addss xmm0, [rsp+20]
    FLD xmm1, -0.04
    addss xmm0, xmm1
    movss [rsp+36], xmm0                ; y top
    FLD xmm1, -0.55
    addss xmm0, xmm1
    movss [rsp+40], xmm0                ; y bottom
    cvtsi2ss xmm0, r13d
    FLD xmm1, 0.2
    mulss xmm0, xmm1
    movss [rsp+44], xmm0                ; u left
    addss xmm0, xmm1
    movss [rsp+48], xmm0                ; u right
    cvtsi2ss xmm0, r12d
    mulss xmm0, xmm1
    addss xmm0, [rsp+0]
    movss [rsp+52], xmm0                ; v top
    addss xmm0, xmm1
    movss [rsp+56], xmm0                ; v bottom
    movss xmm0, [rsp+44]
    movss xmm1, [rsp+52]
    call glTexCoord2f
    movss xmm0, [rsp+24]
    movss xmm1, [rsp+36]
    movss xmm2, [rsp+28]
    call glVertex3f
    movss xmm0, [rsp+48]
    movss xmm1, [rsp+52]
    call glTexCoord2f
    movss xmm0, [rsp+24]
    movss xmm1, [rsp+36]
    movss xmm2, [rsp+32]
    call glVertex3f
    movss xmm0, [rsp+48]
    movss xmm1, [rsp+56]
    call glTexCoord2f
    movss xmm0, [rsp+24]
    movss xmm1, [rsp+40]
    movss xmm2, [rsp+32]
    call glVertex3f
    movss xmm0, [rsp+44]
    movss xmm1, [rsp+56]
    call glTexCoord2f
    movss xmm0, [rsp+24]
    movss xmm1, [rsp+40]
    movss xmm2, [rsp+28]
    call glVertex3f
    inc r13d
    jmp .col
.nrow:
    inc r12d
    jmp .row
.rows_done:
    call glEnd
    mov edi, GL_FOG
    call glEnable
.done:
    EPILOGUE

; -----------------------------------------------------------------------------
; render_frame(edi=window w, esi=window h, xmm0=time)
; -----------------------------------------------------------------------------
render_frame:
    PROLOGUE 64
    mov [rsp+32], edi                   ; full window size
    mov [rsp+36], esi
    ; the 3D view is drawn render_scale times smaller, then scaled up
    mov eax, edi
    xor edx, edx
    div dword [render_scale]
    mov [rsp+0], eax
    mov eax, esi
    xor edx, edx
    div dword [render_scale]
    mov [rsp+4], eax
    movss [rsp+8], xmm0
    ; camera position
    mov eax, [p_x]
    mov [cam_x], eax
    mov eax, [p_eye_y]
    mov [cam_y], eax
    mov eax, [p_z]
    mov [cam_z], eax
    call player_floor
    mov [cur_floor], eax
    call compute_flashlight
    cmp dword [shadows_on], 0
    je .no_shadow_pass
    call shadow_pass
.no_shadow_pass:

    mov edi, GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT
    call glClear
    mov edi, [rsp+0]
    mov esi, [rsp+4]
    call setup_camera
    mov edi, GL_DEPTH_TEST
    call glEnable
    mov edi, GL_BLEND
    call glDisable
    mov edi, GL_FOG
    call glDisable

    ; ---- shader inputs for this frame
    ; flashlight direction = view forward (tilted down a touch)
    movss xmm0, [p_pitch]
    FLD xmm1, -0.05
    addss xmm0, xmm1
    movss [rsp+12], xmm0
    call cosf
    movss [rsp+16], xmm0                ; cos pitch
    movss xmm0, [rsp+12]
    call sinf
    movss [fdir+4], xmm0
    movss xmm0, [p_yaw]
    call sinf
    mulss xmm0, [rsp+16]
    xorps xmm0, [c_sign_mask]
    movss [fdir], xmm0
    movss xmm0, [p_yaw]
    call cosf
    mulss xmm0, [rsp+16]
    xorps xmm0, [c_sign_mask]
    movss [fdir+8], xmm0
    ; ambient: dim blue-grey, a bit darker in the basement, lightning flashes
    movss xmm3, [c_amb_base]
    cmp dword [cur_floor], 0
    jne .amb
    movss xmm3, [c_amb_basem]
.amb:
    PCT xmm4, cfg_bright                ; brightness setting
    mulss xmm3, xmm4
    movss xmm4, [lightning]
    FLD xmm5, 12.0
    mulss xmm4, xmm5
    addss xmm3, xmm4
    movss xmm0, [c_amb_r]
    mulss xmm0, xmm3
    movss xmm1, [c_amb_g]
    mulss xmm1, xmm3
    movss xmm2, [c_amb_b]
    mulss xmm2, xmm3
    movss [amb_col], xmm0
    movss [amb_col+4], xmm1
    movss [amb_col+8], xmm2
    mov edi, 1
    call use_program
    call upload_frame_uniforms
    xor edi, edi
    call use_program
    call upload_frame_uniforms

    movss xmm0, [rsp+8]
    call draw_scene
    ; what you see through the portals (portal.asm)
    movss xmm0, [rsp+8]
    call portal_views
    ; your hands, on top of everything
    movss xmm0, [rsp+8]
    call draw_viewmodel
    cmp dword [render_scale], 1
    je .done
    mov edi, [rsp+0]
    mov esi, [rsp+4]
    mov edx, [rsp+32]
    mov ecx, [rsp+36]
    call upscale_blit
.done:
    EPILOGUE

; -----------------------------------------------------------------------------
; Render scale. Per-pixel lighting is the expensive part when OpenGL runs on
; the CPU (Mesa llvmpipe -- e.g. inside Docker), so there the 3D view is
; drawn at half size in the corner of the back buffer, copied into a texture
; and stretched over the whole window with nearest filtering: chunky pixels,
; Quake style, and roughly 3-4x cheaper. The HUD is drawn afterwards at full
; resolution. On a real GPU the scale stays 1.
; -----------------------------------------------------------------------------

; choose_render_scale() -- BEACOM_SCALE=1..4 wins; otherwise 2 on software GL
choose_render_scale:
    PROLOGUE 16
    mov dword [render_scale], 1
    lea rdi, [env_scale]
    call getenv
    test rax, rax
    jz .auto
    movzx eax, byte [rax]
    sub eax, '0'
    cmp eax, 1
    jl .auto
    cmp eax, 4
    jg .auto
    mov [render_scale], eax
    EPILOGUE
.auto:
    mov edi, GL_RENDERER
    call glGetString
    test rax, rax
    jz .done
    mov rdi, rax
    lea rsi, [s_llvmpipe]
    call strstr
    test rax, rax
    jnz .soft
    mov edi, GL_RENDERER
    call glGetString
    mov rdi, rax
    lea rsi, [s_softpipe]
    call strstr
    test rax, rax
    jz .done
.soft:
    mov dword [render_scale], 2
    mov edi, 0x809D                     ; GL_MULTISAMPLE: too slow in software
    call glDisable
.done:
    EPILOGUE

; render_cycle_scale -- F4: 1 -> 2 -> 3 -> 1
render_cycle_scale:
    mov eax, [render_scale]
    inc eax
    cmp eax, 3
    jle .ok
    mov eax, 1
.ok:
    mov [render_scale], eax
    ret

; upscale_blit(edi=rw, esi=rh, edx=w, ecx=h)
upscale_blit:
    PROLOGUE 48
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    xor edi, edi
    GL2CALL glUseProgram
    ; (re)allocate the low-res texture when the size changes
    cmp dword [lowres_tex], 0
    jne .have_tex
    lea rsi, [lowres_tex]
    mov edi, 1
    call glGenTextures
.have_tex:
    mov edi, [lowres_tex]
    call bind
    cmp r12d, [lowres_w]
    jne .alloc
    cmp r13d, [lowres_h]
    je .copy
.alloc:
    mov [lowres_w], r12d
    mov [lowres_h], r13d
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_MIN_FILTER
    mov edx, GL_NEAREST
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_MAG_FILTER
    mov edx, GL_NEAREST
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_WRAP_S
    mov edx, GL_CLAMP_TO_EDGE
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_WRAP_T
    mov edx, GL_CLAMP_TO_EDGE
    call glTexParameteri
    mov qword [rsp+0], GL_RGB
    mov qword [rsp+8], GL_UNSIGNED_BYTE
    mov qword [rsp+16], 0
    mov edi, GL_TEXTURE_2D
    xor esi, esi
    mov edx, GL_RGB
    mov ecx, r12d
    mov r8d, r13d
    xor r9d, r9d
    call glTexImage2D
.copy:
    ; glCopyTexSubImage2D(target, level, xoff, yoff, x, y, w, h)
    mov qword [rsp+0], r12
    mov qword [rsp+8], r13
    mov edi, GL_TEXTURE_2D
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call glCopyTexSubImage2D
    ; stretch it over the whole window
    xor edi, edi
    xor esi, esi
    mov edx, r14d
    mov ecx, r15d
    call glViewport
    mov edi, GL_PROJECTION
    call glMatrixMode
    call glLoadIdentity
    mov edi, GL_MODELVIEW
    call glMatrixMode
    call glLoadIdentity
    mov edi, GL_DEPTH_TEST
    call glDisable
    GLF4 glColor4f, 1.0, 1.0, 1.0, 1.0
    mov edi, GL_QUADS
    call glBegin
    xor ebx, ebx
.v:
    cmp ebx, 4
    jge .v_done
    ; texture v runs bottom-up here (it came from the framebuffer)
    movss xmm0, [corner_u+rbx*4]
    movss xmm1, [c_one]
    subss xmm1, [corner_v+rbx*4]
    call glTexCoord2f
    movss xmm0, [corner_u+rbx*4]
    addss xmm0, xmm0
    subss xmm0, [c_one]
    movss xmm1, [corner_v+rbx*4]
    addss xmm1, xmm1
    subss xmm1, [c_one]
    xorps xmm1, [c_sign_mask]
    call glVertex2f
    inc ebx
    jmp .v
.v_done:
    call glEnd
    mov edi, GL_DEPTH_TEST
    call glEnable
    EPILOGUE

; render_jumpscare(edi=w, esi=h, xmm0=seconds since caught) -- T's face fills
; the screen, shaking, on black
render_jumpscare:
    PROLOGUE 32
    mov r12d, edi
    mov r13d, esi
    movss [rsp+0], xmm0
    xor edi, edi
    GL2CALL glUseProgram
    mov edi, GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT
    call glClear
    xor edi, edi
    xor esi, esi
    mov edx, r12d
    mov ecx, r13d
    call glViewport
    mov edi, GL_PROJECTION
    call glMatrixMode
    call glLoadIdentity
    mov edi, GL_MODELVIEW
    call glMatrixMode
    call glLoadIdentity
    mov edi, GL_DEPTH_TEST
    call glDisable
    mov edi, GL_BLEND
    call glEnable
    mov edi, GL_SRC_ALPHA
    mov esi, GL_ONE_MINUS_SRC_ALPHA
    call glBlendFunc
    mov edi, [face_tex]
    call bind
    ; shake: random offset, scale grows over time
    call rand01
    subss xmm0, [c_half]
    FLD xmm1, 0.06
    mulss xmm0, xmm1
    movss [rsp+4], xmm0
    call rand01
    subss xmm0, [c_half]
    FLD xmm1, 0.06
    mulss xmm0, xmm1
    movss [rsp+8], xmm0
    movss xmm0, [rsp+0]
    FLD xmm1, 0.4
    mulss xmm0, xmm1
    FLD xmm1, 1.0
    addss xmm0, xmm1                    ; scale
    ; keep the face square: half height = scale, half width = scale*h/w
    movss [rsp+12], xmm0
    cvtsi2ss xmm1, r13d
    cvtsi2ss xmm2, r12d
    divss xmm1, xmm2
    mulss xmm1, xmm0
    movss [rsp+16], xmm1
    GLF4 glColor4f, 1.0, 0.85, 0.85, 1.0
    mov edi, GL_QUADS
    call glBegin
    ; manual quad in clip space
    xor ebx, ebx
.v:
    cmp ebx, 4
    jge .v_done
    movss xmm0, [corner_u+rbx*4]
    movss xmm1, [corner_v+rbx*4]
    call glTexCoord2f
    movss xmm0, [corner_u+rbx*4]
    addss xmm0, xmm0
    subss xmm0, [c_one]
    mulss xmm0, [rsp+16]
    addss xmm0, [rsp+4]
    movss xmm1, [corner_v+rbx*4]
    addss xmm1, xmm1
    subss xmm1, [c_one]
    xorps xmm1, [c_sign_mask]
    mulss xmm1, [rsp+12]
    addss xmm1, [rsp+8]
    call glVertex2f
    inc ebx
    jmp .v
.v_done:
    call glEnd
    GLF4 glColor4f, 1.0, 1.0, 1.0, 1.0
    mov edi, GL_BLEND
    call glDisable
    mov edi, GL_DEPTH_TEST
    call glEnable
    EPILOGUE

; dump_shadow_map(rdi=path) -- debugging aid (--shot with BEACOM_DUMP_SHADOW=1):
; saves the flashlight's depth map as a greyscale BMP (near = dark)
dump_shadow_map:
    PROLOGUE 48
    mov r12, rdi
    cmp dword [shadows_ok], 0
    je .done
    mov edi, GL_FRAMEBUFFER
    mov esi, [shadow_fbo]
    GL2CALL glBindFramebuffer
    mov edi, GL_PACK_ALIGNMENT
    mov esi, 1
    call glPixelStorei
    lea rax, [shot_buf]
    mov [rsp+0], rax
    xor edi, edi
    xor esi, esi
    mov edx, SHADOW_SIZE
    mov ecx, SHADOW_SIZE
    mov r8d, GL_DEPTH_COMPONENT
    mov r9d, 0x1406                     ; GL_FLOAT
    call glReadPixels
    mov edi, GL_FRAMEBUFFER
    xor esi, esi
    GL2CALL glBindFramebuffer
    ; float depth -> grey RGBA, in place (4 bytes each, same size)
    xor ebx, ebx
.px:
    cmp ebx, SHADOW_SIZE*SHADOW_SIZE
    jge .save
    movss xmm0, [shot_buf+rbx*4]
    ; stretch the interesting range (depth is very non-linear)
    mulss xmm0, xmm0
    mulss xmm0, xmm0
    mulss xmm0, xmm0
    FLD xmm1, 255.0
    mulss xmm0, xmm1
    minss xmm0, xmm1
    cvttss2si eax, xmm0
    imul eax, 0x010101
    or eax, 0xFF000000
    mov [shot_buf+rbx*4], eax
    inc ebx
    jmp .px
.save:
    xor edi, edi
    mov esi, SHADOW_SIZE
    mov edx, SHADOW_SIZE
    mov ecx, 32
    mov r8d, SDL_PIXELFORMAT_ABGR8888
    call SDL_CreateRGBSurfaceWithFormat
    mov r15, rax
    mov rdi, [r15+32]
    lea rsi, [shot_buf]
    mov edx, SHADOW_SIZE*SHADOW_SIZE*4
    call memcpy
    mov rdi, r12
    lea rsi, [mode_wb]
    call SDL_RWFromFile
    mov rsi, rax
    mov rdi, r15
    mov edx, 1
    call SDL_SaveBMP_RW
    mov rdi, r15
    call SDL_FreeSurface
.done:
    EPILOGUE

; save_screenshot(rdi=path, esi=w, edx=h) -- read the back buffer, save a BMP
; (used by the --shot test mode)
save_screenshot:
    PROLOGUE 48
    mov r12, rdi
    mov r13d, esi
    mov r14d, edx
    mov edi, GL_PACK_ALIGNMENT
    mov esi, 1
    extern glPixelStorei
    call glPixelStorei
    lea rax, [shot_buf]
    mov [rsp+0], rax
    xor edi, edi
    xor esi, esi
    mov edx, r13d
    mov ecx, r14d
    mov r8d, GL_RGBA
    mov r9d, GL_UNSIGNED_BYTE
    call glReadPixels
    xor edi, edi
    mov esi, r13d
    mov edx, r14d
    mov ecx, 32
    mov r8d, SDL_PIXELFORMAT_ABGR8888
    call SDL_CreateRGBSurfaceWithFormat
    mov r15, rax
    ; copy rows bottom-up (GL's origin is the bottom-left)
    xor ebx, ebx
.row:
    cmp ebx, r14d
    jge .rows_done
    mov eax, r14d
    sub eax, ebx
    dec eax
    imul eax, [r15+24]
    mov rdi, [r15+32]
    add rdi, rax
    mov eax, ebx
    imul eax, r13d
    shl eax, 2
    lea rsi, [shot_buf]
    add rsi, rax
    mov edx, r13d
    shl edx, 2
    call memcpy
    inc ebx
    jmp .row
.rows_done:
    mov rdi, r12
    lea rsi, [mode_wb]
    call SDL_RWFromFile
    mov rsi, rax
    mov rdi, r15
    mov edx, 1
    call SDL_SaveBMP_RW
    mov rdi, r15
    call SDL_FreeSurface
    EPILOGUE

RODATA
mode_wb db "wb",0
env_scale db "BEACOM_SCALE",0
s_llvmpipe db "llvmpipe",0
s_softpipe db "softpipe",0

section .bss
pc_x        resd 4                      ; corners of the platform being built
pc_z        resd 4
pc_t        resd 4                      ; top and bottom heights
pc_b        resd 4
mw_on       resd 1                      ; the media wall: is there one, and where
mw_x        resd 1
mw_y0       resd 1
mw_z0       resd 1
mw_z1       resd 1
