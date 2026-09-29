; =============================================================================
; assets.asm -- the baked art: meshes and textures made in Blender by the
; scripts in tools/blender/ (sculpted as distance fields, baked in Cycles),
; loaded from assets/ at start-up.
;
;   <name>.bmsh          "BMSH", uint32 vertex count, then per vertex 8 floats
;                        (position xyz, normal xyz, u, t): plain triangles.
;                        Compiled once into a display list.
;   <name>_albedo.png    colour with the ambient occlusion baked in
;   <name>_normal.png    tangent-space normal (+Y = +t), alpha = gloss
;
; Everything here is optional: if a file is missing the game keeps its
; procedural stand-in (hands.asm checks hand_mesh before using it).
; =============================================================================
%define MODULE_ASSETS
%include "common.inc"

global assets_init, hand_mesh, hand_alb, hand_nrm, torch_mesh, torch_alb, torch_nrm
global sleeve_mesh, sleeve_alb, sleeve_nrm, mat_nrm
global gun_mesh, hook_mesh, tip_mesh, assets_tests

%define MAX_VERTS 131072            ; per mesh
%define TX_H       0                ; textures.asm's texture slots
%define TX_FLOOR   6
%define TX_FLOOR_B 7
%define TX_FLOOR_S 8
%define TX_CEIL    9
%define VSIZE 32                    ; bytes per vertex
%define BATCH 3000                  ; vertices per glBegin/glEnd (a multiple of 3)

section .data
path_hand_mesh  db "assets/hand.bmsh",0
path_hand_alb   db "assets/hand_albedo.png",0
path_hand_nrm   db "assets/hand_normal.png",0
path_torch_mesh db "assets/torch.bmsh",0
path_torch_alb  db "assets/torch_albedo.png",0
path_torch_nrm  db "assets/torch_normal.png",0
path_sleeve_mesh db "assets/sleeve.bmsh",0
path_sleeve_alb  db "assets/sleeve_albedo.png",0
path_sleeve_nrm  db "assets/sleeve_normal.png",0
path_gun_mesh   db "assets/gadget_gun.bmsh",0
path_gun_alb    db "assets/gadget_gun_albedo.png",0
path_gun_nrm    db "assets/gadget_gun_normal.png",0
path_hook_mesh  db "assets/gadget_hook.bmsh",0
path_hook_alb   db "assets/gadget_hook_albedo.png",0
path_hook_nrm   db "assets/gadget_hook_normal.png",0
path_tip_mesh   db "assets/gadget_tip.bmsh",0
path_tip_alb    db "assets/gadget_tip_albedo.png",0
path_tip_nrm    db "assets/gadget_tip_normal.png",0
; every asset: its three files, and where its display list / textures go
align 8
asset_tab:
    dq path_hand_mesh, path_hand_alb, path_hand_nrm, hand_mesh, hand_alb, hand_nrm
    dq path_torch_mesh, path_torch_alb, path_torch_nrm, torch_mesh, torch_alb, torch_nrm
    dq path_sleeve_mesh, path_sleeve_alb, path_sleeve_nrm, sleeve_mesh, sleeve_alb, sleeve_nrm
    dq path_gun_mesh, path_gun_alb, path_gun_nrm, gun_mesh, gun_mesh+4, gun_mesh+8
    dq path_hook_mesh, path_hook_alb, path_hook_nrm, hook_mesh, hook_mesh+4, hook_mesh+8
    dq path_tip_mesh, path_tip_alb, path_tip_nrm, tip_mesh, tip_mesh+4, tip_mesh+8
asset_tab_end:

; the building's surfaces: they replace the painted textures in tex_ids[] and
; add a normal map for that world material (texture slot = material number
; for the lit world materials, see render.asm mat_tex)
path_wall_alb   db "assets/wall_block_albedo.png",0
path_wall_nrm   db "assets/wall_block_normal.png",0
path_floor_alb  db "assets/floor_tile_albedo.png",0
path_floor_nrm  db "assets/floor_tile_normal.png",0
path_floorb_alb db "assets/floor_base_albedo.png",0
path_floorb_nrm db "assets/floor_base_normal.png",0
path_floors_alb db "assets/floor_safe_albedo.png",0
path_floors_nrm db "assets/floor_safe_normal.png",0
path_ceil_alb   db "assets/ceiling_tile_albedo.png",0
path_ceil_nrm   db "assets/ceiling_tile_normal.png",0
align 8
world_tab:
    dq path_wall_alb, path_wall_nrm, TX_H
    dq path_floor_alb, path_floor_nrm, TX_FLOOR
    dq path_floorb_alb, path_floorb_nrm, TX_FLOOR_B
    dq path_floors_alb, path_floors_nrm, TX_FLOOR_S
    dq path_ceil_alb, path_ceil_nrm, TX_CEIL
world_tab_end:
mode_rb        db "rb",0
bmsh_magic     db "BMSH"
msg_loaded     db "assets: %s (%d triangles)",10,0
msg_missing    db "assets: %s not found -- using the built-in stand-in",10,0
msg_bad        db "assets: %s is not a valid mesh",10,0
st_assets      db "[selftest] assets: %d of 6 meshes loaded (expect 6), %d of 5 world surfaces normal-mapped (expect 5)",10,0
st_loader      db "[selftest] asset loader: a missing mesh=%d, a PNG passed off as a mesh=%d, a missing texture=%d (expect 0 0 0)",10,0
path_no_mesh   db "assets/no_such_mesh.bmsh",0
path_no_tex    db "assets/no_such_texture.png",0
align 8
mesh_vars      dq hand_mesh, torch_mesh, sleeve_mesh, gun_mesh, hook_mesh, tip_mesh
world_slots    dd TX_H, TX_FLOOR, TX_FLOOR_B, TX_FLOOR_S, TX_CEIL

section .bss
alignb 16
vbuf        resb MAX_VERTS*VSIZE    ; the mesh being compiled
hdr         resd 2
hand_mesh   resd 1                  ; display list, 0 = not loaded
hand_alb    resd 1                  ; textures
hand_nrm    resd 1
torch_mesh  resd 1                  ; (mesh, albedo, normal: a record, like the gadgets)
torch_alb   resd 1
torch_nrm   resd 1
sleeve_mesh resd 1
sleeve_alb  resd 1
sleeve_nrm  resd 1
mat_nrm     resd 16                 ; per world material: normal map or 0
; the gadget in your left hand: display list, albedo, normal map each
; (hands.asm draw_part reads them as a record)
gun_mesh    resd 3
hook_mesh   resd 3
tip_mesh    resd 3

section .text

; load_mesh(rdi = path) -> eax = display list with the mesh, 0 on failure
load_mesh:
    PROLOGUE 16
    mov r12, rdi
    lea rsi, [mode_rb]
    call fopen
    test rax, rax
    jz .missing
    mov r13, rax
    ; header: magic + vertex count
    lea rdi, [hdr]
    mov esi, 4
    mov edx, 2
    mov rcx, r13
    call fread
    cmp rax, 2
    jne .bad
    mov eax, [hdr]
    cmp eax, [bmsh_magic]
    jne .bad
    mov r14d, [hdr+4]                   ; vertices
    test r14d, r14d
    jz .bad
    cmp r14d, MAX_VERTS
    ja .bad
    lea rdi, [vbuf]
    mov esi, VSIZE
    mov edx, r14d
    mov rcx, r13
    call fread
    cmp eax, r14d
    jne .bad
    mov rdi, r13
    call fclose
    ; compile: glNormal3f, glTexCoord2f, glVertex3f per vertex
    mov edi, 1
    call glGenLists
    mov r15d, eax
    mov edi, r15d
    mov esi, GL_COMPILE
    call glNewList
    mov edi, GL_TRIANGLES
    call glBegin
    lea rbx, [vbuf]
    mov r13d, r14d
    mov dword [rsp+0], 0                ; vertices in this batch
.v:
    cmp dword [rsp+0], BATCH            ; drivers digest many small batches
    jb .same                            ; better than one enormous one
    call glEnd
    mov edi, GL_TRIANGLES
    call glBegin
    mov dword [rsp+0], 0
.same:
    inc dword [rsp+0]
    movss xmm0, [rbx+12]
    movss xmm1, [rbx+16]
    movss xmm2, [rbx+20]
    call glNormal3f
    movss xmm0, [rbx+24]
    movss xmm1, [rbx+28]
    call glTexCoord2f
    movss xmm0, [rbx+0]
    movss xmm1, [rbx+4]
    movss xmm2, [rbx+8]
    call glVertex3f
    add rbx, VSIZE
    dec r13d
    jnz .v
    call glEnd
    call glEndList
    lea rdi, [msg_loaded]
    mov rsi, r12
    mov eax, r14d
    xor edx, edx
    mov ecx, 3
    div ecx
    mov edx, eax
    xor eax, eax
    call printf
    mov eax, r15d
    EPILOGUE
.bad:
    mov rdi, r13
    call fclose
    lea rdi, [msg_bad]
    mov rsi, r12
    xor eax, eax
    call printf
    xor eax, eax
    EPILOGUE
.missing:
    lea rdi, [msg_missing]
    mov rsi, r12
    xor eax, eax
    call printf
    xor eax, eax
    EPILOGUE

; load_texture(rdi = path) -> eax = GL texture (mipmapped, repeating), 0 on failure
load_texture:
    PROLOGUE 32
    mov r12, rdi
    call IMG_Load
    test rax, rax
    jz .missing
    mov r13, rax
    mov rdi, rax
    mov esi, SDL_PIXELFORMAT_ABGR8888
    xor edx, edx
    call SDL_ConvertSurfaceFormat
    mov r14, rax
    mov rdi, r13
    call SDL_FreeSurface
    test r14, r14
    jz .missing
    lea rsi, [rsp+24]
    mov edi, 1
    call glGenTextures
    mov r15d, [rsp+24]
    mov edi, GL_TEXTURE_2D
    mov esi, r15d
    call glBindTexture
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_MIN_FILTER
    mov edx, GL_LINEAR_MIPMAP_LINEAR
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_MAG_FILTER
    mov edx, GL_LINEAR
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_WRAP_S
    mov edx, GL_REPEAT
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_WRAP_T
    mov edx, GL_REPEAT
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_GENERATE_MIPMAP
    mov edx, 1
    call glTexParameteri
    mov esi, [r14+24]                   ; rows may be padded
    shr esi, 2
    mov edi, GL_UNPACK_ROW_LENGTH
    call glPixelStorei
    ; glTexImage2D's 7th..9th arguments go on the stack (the frame's bottom)
    mov qword [rsp+0], GL_RGBA
    mov qword [rsp+8], GL_UNSIGNED_BYTE
    mov rax, [r14+32]
    mov [rsp+16], rax
    mov edi, GL_TEXTURE_2D
    xor esi, esi
    mov edx, GL_RGBA
    mov ecx, [r14+16]
    mov r8d, [r14+20]
    xor r9d, r9d
    call glTexImage2D
    mov edi, GL_UNPACK_ROW_LENGTH
    xor esi, esi
    call glPixelStorei
    mov rdi, r14
    call SDL_FreeSurface
    mov eax, r15d
    EPILOGUE
.missing:
    lea rdi, [msg_missing]
    mov rsi, r12
    xor eax, eax
    call printf
    xor eax, eax
    EPILOGUE

; assets_init -- load everything in asset_tab (after the GL context exists).
; An asset's mesh is only loaded -- and so only used -- when both its
; textures loaded.
assets_init:
    PROLOGUE 16
    lea rbx, [asset_tab]
.a:
    lea rax, [asset_tab_end]
    cmp rbx, rax
    jae .done
    mov rdi, [rbx+8]
    call load_texture
    mov rcx, [rbx+32]
    mov [rcx], eax
    mov rdi, [rbx+16]
    call load_texture
    mov rcx, [rbx+40]
    mov [rcx], eax
    xor eax, eax
    mov rcx, [rbx+32]
    cmp dword [rcx], 0
    je .no_mesh
    mov rcx, [rbx+40]
    cmp dword [rcx], 0
    je .no_mesh
    mov rdi, [rbx]
    call load_mesh
.no_mesh:
    mov rcx, [rbx+24]
    mov [rcx], eax
    add rbx, 48
    jmp .a
.done:
    ; the building's surfaces: both maps or neither
    lea rbx, [world_tab]
.w:
    lea rax, [world_tab_end]
    cmp rbx, rax
    jae .w_done
    mov rdi, [rbx]
    call load_texture
    mov r12d, eax
    mov rdi, [rbx+8]
    call load_texture
    mov r13d, eax
    test r12d, r12d
    jz .w_next
    test r13d, r13d
    jz .w_next
    mov rcx, [rbx+16]
    mov [tex_ids+rcx*4], r12d
    mov [mat_nrm+rcx*4], r13d
.w_next:
    add rbx, 24
    jmp .w
.w_done:
    EPILOGUE

; assets_tests -- what loaded, and the loader turning away what it should
assets_tests:
    PROLOGUE 16
    xor r12d, r12d                      ; meshes loaded
    xor ebx, ebx
.m:
    mov rax, [mesh_vars+rbx*8]
    cmp dword [rax], 0
    je .m_next
    inc r12d
.m_next:
    inc ebx
    cmp ebx, 6
    jl .m
    xor r13d, r13d                      ; world surfaces with a normal map
    xor ebx, ebx
.w:
    mov eax, [world_slots+rbx*4]
    cmp dword [mat_nrm+rax*4], 0
    je .w_next
    inc r13d
.w_next:
    inc ebx
    cmp ebx, 5
    jl .w
    lea rdi, [st_assets]
    mov esi, r12d
    mov edx, r13d
    xor eax, eax
    call printf
    lea rdi, [path_no_mesh]
    call load_mesh
    mov r12d, eax
    lea rdi, [path_hand_alb]
    call load_mesh
    mov r13d, eax
    lea rdi, [path_no_tex]
    call load_texture
    mov ecx, eax
    lea rdi, [st_loader]
    mov esi, r12d
    mov edx, r13d
    xor eax, eax
    call printf
    EPILOGUE
