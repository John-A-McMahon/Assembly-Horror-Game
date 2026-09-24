; =============================================================================
; textures.asm -- every texture in the game is painted here, pixel by pixel,
; into a scratch RGBA canvas and uploaded to OpenGL. No image files are
; needed except T's face (../T_Sprite.jpeg, same file doom.asm uses).
;
; Pixels are 32-bit dwords laid out R,G,B,A in memory (SDL's ABGR8888), so a
; colour constant is 0xAABBGGRR -- use the RGB(r,g,b) macro below.
;
; Also here: the fonts, text-to-texture (SDL_ttf) and the hanging signs.
; =============================================================================
%define MODULE_TEX
%include "common.inc"

global textures_init, make_text_texture, tex_ids, face_tex, white_tex, sign_tex, label_tex
extern glTexParameterf
global grain_tex, radial_tex, led_tex, tt_w, tt_h, font_hud, font_small, font_big
global prop_tex, skin_tex, cloth_tex, media_tex
global sign_count, sign_f, sign_x, sign_z, sign_face, sign_exit, sign_set, sign_set_cur

%define RGB(r,g,b) (0xFF000000 | ((b)<<16) | ((g)<<8) | (r))

; texture slots in tex_ids[] -- keep in sync with render.asm
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
%define NUM_TX     12

%define CANVAS_MAX (256*512)
%define NSIGNS_ORIGINAL 30
%define NSIGNS (NSIGNS_ORIGINAL + 18)       ; + the real Beacom's

section .data
face_file   db "../T_Sprite.jpeg",0
%ifdef WIN64
font_path_sans db "C:/Windows/Fonts/arialbd.ttf",0
font_path_mono db "C:/Windows/Fonts/consolab.ttf",0
%else
font_path_sans db "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",0
font_path_mono db "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",0
%endif
err_font    db "Could not load font %s (install fonts-dejavu-core)",10,0
err_face    db "Could not load ../T_Sprite.jpeg -- T will have no face.",10,0

; ---- hanging signs: storey, grid x, grid y, which way it faces, exit sign? ----
; Ground-floor room names come from doom.asm's wayfinding table.
; face 0 = readable walking north/south (plane spans X), 1 = east/west.
sg0  db "BEACOM HALL",0
sg1  db "CSC 314",0
sg2  db "ROOM 102",0
sg3  db "ROOM 103",0
sg4  db "ROOM 104",0
sg5  db "ROOM 105",0
sg6  db "NURSE",0
sg7  db "ROOM 110",0
sg8  db "ROOM 111",0
sg9  db "NURSE",0
sg10 db "GYMNASIUM",0
sg11 db "LIBRARY",0
sg12 db "STAIRS ^ 2",0
sg13 db "STAIRS v B",0
sg14 db "STAIRS v B",0
sg15 db "STAIRS ^ 2",0
sg16 db "OFFICE 201",0
sg17 db "OFFICE 202",0
sg18 db "CYBER LAB 210",0
sg19 db "SAFE ROOM",0
sg20 db "STAIRS v 1",0
sg21 db "STAIRS v 1",0
sg22 db "FACULTY LOUNGE",0
sg23 db "CYBER RANGE",0
sg24 db "DEAN",0
sg25 db "SERVER ROOM",0
sg26 db "STAIRS ^ 1",0
sg27 db "STAIRS ^ 1",0
sg28 db "MECHANICAL",0
sg29 db "SAFE ROOM",0
; the real Beacom Institute of Technology (room numbers from DSU's own pages)
sgr0 db "BEACOM INSTITUTE",0
sgr1 db "ROOM 117",0
sgr2 db "ROOM 112",0
sgr3 db "ROOM 114",0
sgr4 db "RESTROOM",0
sgr5 db "SUB-LEVEL v",0
sgr6 db "GAME DESIGN LAB",0
sgr7 db "ANIMATION LAB",0
sgr8 db "STAIRS ^ 2",0
sgr9 db "ROOM 231",0
sgr10 db "ACADEMIC SERVER ROOM",0
sgr11 db "ROOM 233",0
sgr12 db "CYBER OPS",0
sgr13 db "ROOM 213",0
sgr14 db "BEACOM COLLEGE OFFICE",0
sgr15 db "ROOM 235",0
sgr16 db "STAIRS v 1",0
sgr17 db "ELECTRICAL",0
align 8
sign_text   dq sg0,sg1,sg2,sg3,sg4,sg5,sg6,sg7,sg8,sg9,sg10,sg11,sg12,sg13,sg14
            dq sg15,sg16,sg17,sg18,sg19,sg20,sg21,sg22,sg23,sg24,sg25,sg26,sg27,sg28,sg29
            dq sgr0,sgr1,sgr2,sgr3,sgr4,sgr5,sgr6,sgr7,sgr8,sgr9,sgr10,sgr11,sgr12,sgr13,sgr14,sgr15,sgr16,sgr17
sign_count  dd NSIGNS
sign_f      dd 1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1, 2,2,2,2,2,2,2,2,2, 0,0,0,0,0
            dd 1,1,1,1,1,1,1,1,1,2,2,2,2,2,2,2,2,0
sign_x      dd 2.0,10.0,10.0,33.0,33.0,55.0,55.0,33.0,33.0,17.0,5.0,50.0
            dd 19.5,42.5,40.5,28.0
            dd 5.0,13.0,30.5,51.0,19.5,14.0,6.0,38.0,50.0
            dd 16.5,42.5,40.5,29.0,55.0
            dd 20.55,28.55,30.45,30.45,34.45,34.45,24.0,31.0,37.5,24.0,30.0,35.0,30.55,24.0,30.0,34.0,36.0,13.0
sign_z      dd 2.0,3.0,9.0,3.0,9.0,3.0,9.0,21.0,26.0,26.0,21.0,20.0
            dd 15.0,15.0,16.0,19.5
            dd 3.0,15.0,15.0,15.0,3.0,21.0,15.0,15.0,15.0
            dd 3.0,3.0,27.0,15.0,15.0
            dd 15.0,4.0,2.0,6.0,10.0,12.0,23.45,23.45,23.45,7.55,6.55,7.55,14.0,23.45,23.45,23.45,23.45,16.45
sign_face   dd 0,0,0,0,0,0,0,0,0,0,0,0, 1,1,1,0, 0,1,1,1,1,0,1,1,0, 1,1,1,0,0
            dd 1,1,1,1,1,1,0,0,0,0,0,0,1,0,0,0,0,0
sign_exit   dd 0,0,0,0,0,0,0,0,0,0,0,0, 1,1,1,1, 0,0,0,0,1,1,0,0,0, 0,1,1,0,0
            dd 0,0,0,0,0,1,0,0,1,0,0,0,0,0,0,0,1,0
; which building each sign belongs to (SET_ORIGINAL / SET_REAL)
sign_set    times NSIGNS_ORIGINAL dd SET_ORIGINAL
            times 18 dd SET_REAL
sign_set_cur dd SET_ORIGINAL          ; world_select: the building's set, -1 none

lbl_pcap    db ".pcap",0
lbl_deauth  db "DEAUTH",0
lbl_b       db "B",0
lbl_y       db "Y HELP",0
lbl_map     db "MAP",0
lbl_box     db "FRAGILE",0
lbl_sign    db "CAUTION",10,10,"WET",10,"FLOOR",0
lbl_compass db "N",0
lbl_portal  db "PORTAL",0
lbl_hook    db "HOOK",0

section .data
; Wireshark-ish row colours (weighted by how often they turn up)
media_pal   dd RGB(210,208,240), RGB(210,208,240), RGB(210,208,240), RGB(210,208,240)
            dd RGB(210,208,240), RGB(196,222,240), RGB(196,222,240), RGB(196,222,240)
            dd RGB(210,238,180), RGB(210,238,180), RGB(236,226,196), RGB(196,222,240)
            dd RGB(24,40,48), RGB(24,40,48), RGB(170,20,20), RGB(210,208,240)
media_colx  dd 3, 22, 52, 104, 156, 180     ; No. Time Source Destination Protocol Info
media_colw  dd 12, 20, 38, 38, 14, 70

section .bss
alignb 16
pix         resd CANVAS_MAX           ; scratch canvas
cv_w        resd 1
cv_h        resd 1
tex_ids     resd NUM_TX
face_tex    resd 1
white_tex   resd 1
grain_tex   resd 1
radial_tex  resd 1
led_tex     resd 1
sign_tex    resd NSIGNS
prop_tex    resd 2                    ; cardboard box, wet-floor sign
label_tex   resd 10                   ; .pcap DEAUTH MAP COMPASS PORTAL HOOKSHOT (dew) B "Y HELP"
tt_w        resd 1                    ; size of the last text texture made
tt_h        resd 1
font_hud    resq 1
font_small  resq 1
font_big    resq 1
font_label  resq 1
tmp_id      resd 1
skin_tex    resd 1
cloth_tex   resd 1
media_tex   resd 1

section .text

; =============================================================================
; small painting helpers (all operate on pix[] of size cv_w x cv_h)
; =============================================================================

; rand_n(edi=n) -> eax = rand() % n
rand_n:
    push rbx
    mov ebx, edi
    call rng_next
    xor edx, edx
    div ebx
    mov eax, edx
    pop rbx
    ret

; canvas(edi=w, esi=h)
canvas:
    mov [cv_w], edi
    mov [cv_h], esi
    ret

; shade(edi=colour, esi=amount) -> eax: adds `amount` to R,G,B (clamped). leaf.
shade:
    xor eax, eax
    mov ecx, 0
.ch:
    mov edx, edi
    shr edx, cl
    and edx, 255
    add edx, esi
    cmp edx, 0
    jge .lo
    xor edx, edx
.lo:
    cmp edx, 255
    jle .hi
    mov edx, 255
.hi:
    shl edx, cl
    or eax, edx
    add ecx, 8
    cmp ecx, 24
    jl .ch
    or eax, 0xFF000000
    ret

; put_blend(edi=x, esi=y, edx=colour, ecx=alpha 0..255) -- blend one pixel.
; Keeps the destination's own alpha. leaf.
put_blend:
    cmp edi, 0
    jl .out
    cmp edi, [cv_w]
    jge .out
    cmp esi, 0
    jl .out
    cmp esi, [cv_h]
    jge .out
    mov eax, esi
    imul eax, [cv_w]
    add eax, edi
    lea r8, [pix+rax*4]
    mov r9d, [r8]
    push rbx
    push r12
    xor r10d, r10d
    xor r12d, r12d                      ; shift
.ch:
    push rcx
    mov eax, edx
    mov ecx, r12d
    shr eax, cl
    and eax, 255
    mov r11d, r9d
    shr r11d, cl
    and r11d, 255
    pop rcx
    sub eax, r11d
    imul eax, ecx
    sar eax, 8
    add eax, r11d
    push rcx
    mov ecx, r12d
    shl eax, cl
    pop rcx
    or r10d, eax
    add r12d, 8
    cmp r12d, 24
    jl .ch
    and r9d, 0xFF000000
    or r10d, r9d
    mov [r8], r10d
    pop r12
    pop rbx
.out:
    ret

; put_px(edi=x, esi=y, edx=colour) -- overwrite one pixel (incl. alpha). leaf.
put_px:
    cmp edi, 0
    jl .out
    cmp edi, [cv_w]
    jge .out
    cmp esi, 0
    jl .out
    cmp esi, [cv_h]
    jge .out
    mov eax, esi
    imul eax, [cv_w]
    add eax, edi
    mov [pix+rax*4], edx
.out:
    ret

; fill_rect(edi=x, esi=y, edx=w, ecx=h, r8d=colour)
fill_rect:
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    lea r14d, [rdi+rdx]                 ; x end
    lea r15d, [rsi+rcx]                 ; y end
    mov ebx, r8d
.y:
    cmp r13d, r15d
    jge .done
    mov [rsp+0], r12d
.x:
    mov edi, [rsp+0]
    cmp edi, r14d
    jge .ny
    mov esi, r13d
    mov edx, ebx
    call put_px
    inc dword [rsp+0]
    jmp .x
.ny:
    inc r13d
    jmp .y
.done:
    EPILOGUE

; blend_rect(edi=x, esi=y, edx=w, ecx=h, r8d=colour, r9d=alpha)
blend_rect:
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    lea r14d, [rdi+rdx]
    lea r15d, [rsi+rcx]
    mov ebx, r8d
    mov [rsp+4], r9d
.y:
    cmp r13d, r15d
    jge .done
    mov [rsp+0], r12d
.x:
    mov edi, [rsp+0]
    cmp edi, r14d
    jge .ny
    mov esi, r13d
    mov edx, ebx
    mov ecx, [rsp+4]
    call put_blend
    inc dword [rsp+0]
    jmp .x
.ny:
    inc r13d
    jmp .y
.done:
    EPILOGUE

; blotch(edi=cx, esi=cy, edx=radius, ecx=colour, r8d=alpha) -- soft round stain
blotch:
    PROLOGUE 32
    mov [rsp+0], edi
    mov [rsp+4], esi
    mov [rsp+8], edx
    mov [rsp+12], ecx
    mov [rsp+16], r8d
    mov eax, edx
    imul eax, edx
    inc eax
    mov [rsp+20], eax                   ; r^2 + 1
    mov r12d, edx
    neg r12d                            ; dy
.y:
    cmp r12d, [rsp+8]
    jg .done
    mov r13d, [rsp+8]
    neg r13d                            ; dx
.x:
    cmp r13d, [rsp+8]
    jg .ny
    mov eax, r12d
    imul eax, eax
    mov ecx, r13d
    imul ecx, ecx
    add eax, ecx                        ; d^2
    cmp eax, [rsp+20]
    jge .nx
    ; a = alpha * (r2 - d2) / r2
    mov ecx, [rsp+20]
    sub ecx, eax
    imul ecx, [rsp+16]
    mov eax, ecx
    xor edx, edx
    div dword [rsp+20]
    mov ecx, eax
    mov edi, [rsp+0]
    add edi, r13d
    mov esi, [rsp+4]
    add esi, r12d
    mov edx, [rsp+12]
    call put_blend
.nx:
    inc r13d
    jmp .x
.ny:
    inc r12d
    jmp .y
.done:
    EPILOGUE

; speckle(edi=count, esi=colour, edx=max alpha) -- random single-pixel noise
speckle:
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
.loop:
    test r12d, r12d
    jz .done
    dec r12d
    mov edi, [cv_w]
    call rand_n
    mov ebx, eax
    mov edi, [cv_h]
    call rand_n
    mov r15d, eax
    mov edi, r14d
    call rand_n
    mov ecx, eax
    mov edi, ebx
    mov esi, r15d
    mov edx, r13d
    call put_blend
    jmp .loop
.done:
    EPILOGUE

; grime(edi=count, esi=max alpha) -- dirt blotches and water-stain drips
grime:
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r15d, edi
.loop:
    test r12d, r12d
    jz .drips
    dec r12d
    mov edi, [cv_w]
    call rand_n
    mov ebx, eax
    mov edi, [cv_h]
    call rand_n
    mov r14d, eax
    mov edi, 9
    call rand_n
    lea edx, [rax+1]
    mov edi, r13d
    push rdx
    push rdx
    call rand_n
    pop rdx
    pop rdx
    mov r8d, eax
    mov edi, ebx
    mov esi, r14d
    mov ecx, RGB(30,24,16)
    call blotch
    jmp .loop
.drips:
    ; count/20 vertical stains fading downward
    mov eax, r15d
    xor edx, edx
    mov ecx, 20
    div ecx
    mov r12d, eax
.drip:
    test r12d, r12d
    jz .done
    dec r12d
    mov edi, [cv_w]
    call rand_n
    mov ebx, eax                        ; x
    mov edi, [cv_h]
    call rand_n
    mov r14d, eax                       ; length
    mov edi, 3
    call rand_n
    inc eax
    mov [rsp+0], eax                    ; width
    xor r15d, r15d                      ; y
.dy:
    cmp r15d, r14d
    jge .drip
    ; alpha fades with y
    mov eax, r14d
    sub eax, r15d
    imul eax, r13d
    xor edx, edx
    div r14d
    mov r9d, eax
    mov edi, ebx
    mov esi, r15d
    mov edx, [rsp+0]
    mov ecx, 1
    mov r8d, RGB(40,30,20)
    call blend_rect
    inc r15d
    jmp .dy
.done:
    EPILOGUE

; ring_rune(edi=cx, esi=cy, edx=radius, ecx=colour) -- the "network sorcery"
; seal on safe-room walls: a circle with six spokes
ring_rune:
    PROLOGUE 48
    mov [rsp+0], edi
    mov [rsp+4], esi
    mov [rsp+8], edx
    mov [rsp+12], ecx
    ; circle: 256 samples
    xor ebx, ebx
.circ:
    cmp ebx, 256
    jge .spokes
    cvtsi2ss xmm0, ebx
    mulss xmm0, [c_two_pi]
    mov eax, 256
    cvtsi2ss xmm1, eax
    divss xmm0, xmm1
    movss [rsp+16], xmm0
    call cosf
    cvtsi2ss xmm1, dword [rsp+8]
    mulss xmm0, xmm1
    cvttss2si r12d, xmm0
    movss xmm0, [rsp+16]
    call sinf
    cvtsi2ss xmm1, dword [rsp+8]
    mulss xmm0, xmm1
    cvttss2si r13d, xmm0
    mov edi, [rsp+0]
    add edi, r12d
    mov esi, [rsp+4]
    add esi, r13d
    mov edx, 2
    mov ecx, 2
    mov r8d, [rsp+12]
    call fill_rect
    inc ebx
    jmp .circ
.spokes:
    xor r14d, r14d                      ; spoke
.sp:
    cmp r14d, 6
    jge .done
    cvtsi2ss xmm0, r14d
    mulss xmm0, [c_two_pi]
    mov eax, 6
    cvtsi2ss xmm1, eax
    divss xmm0, xmm1
    movss [rsp+16], xmm0
    call cosf
    movss [rsp+20], xmm0
    movss xmm0, [rsp+16]
    call sinf
    movss [rsp+24], xmm0
    xor ebx, ebx
.along:
    cmp ebx, [rsp+8]
    jge .nsp
    cvtsi2ss xmm1, ebx
    movss xmm0, [rsp+20]
    mulss xmm0, xmm1
    cvttss2si edi, xmm0
    add edi, [rsp+0]
    movss xmm0, [rsp+24]
    mulss xmm0, xmm1
    cvttss2si esi, xmm0
    add esi, [rsp+4]
    mov edx, 2
    mov ecx, 2
    mov r8d, [rsp+12]
    call fill_rect
    inc ebx
    jmp .along
.nsp:
    inc r14d
    jmp .sp
.done:
    EPILOGUE

; upload(edi=repeat? 1:0) -> eax = new GL texture id from pix[] (mipmapped)
upload:
    PROLOGUE 48
    mov r12d, edi
    lea rsi, [tmp_id]
    mov edi, 1
    call glGenTextures
    mov edi, GL_TEXTURE_2D
    mov esi, [tmp_id]
    call glBindTexture
    mov edx, GL_CLAMP_TO_EDGE
    test r12d, r12d
    jz .wrap
    mov edx, GL_REPEAT
.wrap:
    mov ebx, edx
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_WRAP_S
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_WRAP_T
    mov edx, ebx
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_MIN_FILTER
    mov edx, GL_LINEAR_MIPMAP_LINEAR
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_MAG_FILTER
    mov edx, GL_LINEAR
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_GENERATE_MIPMAP
    mov edx, 1
    call glTexParameteri
    ; 8x anisotropic filtering: floors and walls stay sharp at grazing angles
    ; (GL_EXT_texture_filter_anisotropic; a harmless error if unsupported)
    mov edi, GL_TEXTURE_2D
    mov esi, 0x84FE                     ; GL_TEXTURE_MAX_ANISOTROPY_EXT
    FLD xmm0, 8.0
    call glTexParameterf
    mov edi, GL_UNPACK_ROW_LENGTH
    xor esi, esi
    call glPixelStorei
    ; glTexImage2D(target, level, ifmt, w, h, border, fmt, type, pixels)
    mov qword [rsp+0], GL_RGBA
    mov qword [rsp+8], GL_UNSIGNED_BYTE
    lea rax, [pix]
    mov [rsp+16], rax
    mov edi, GL_TEXTURE_2D
    xor esi, esi
    mov edx, GL_RGBA
    mov ecx, [cv_w]
    mov r8d, [cv_h]
    xor r9d, r9d
    call glTexImage2D
    mov eax, [tmp_id]
    EPILOGUE

; =============================================================================
; the procedural textures (ports of the canvas painters in the JS version)
; =============================================================================

; cinderblock(edi=block colour, esi=mortar, edx=stripe or 0) -- hallway walls
tex_cinderblock:
    PROLOGUE 32
    mov [rsp+0], edi
    mov [rsp+4], esi
    mov [rsp+8], edx
    mov edi, 128
    mov esi, 256
    call canvas
    xor edi, edi
    xor esi, esi
    mov edx, 128
    mov ecx, 256
    mov r8d, [rsp+4]
    call fill_rect
    xor r12d, r12d                      ; row
.row:
    cmp r12d, 16
    jge .rows_done
    mov r13d, -64                       ; x
    test r12d, 1
    jz .col
    mov r13d, -32
.col:
    cmp r13d, 128
    jge .next_row
    mov edi, 15
    call rand_n
    sub eax, 7
    mov esi, eax
    mov edi, [rsp+0]
    call shade
    mov r8d, eax
    lea edi, [r13d+1]
    imul esi, r12d, 17
    inc esi
    mov edx, 62
    mov ecx, 15
    call fill_rect
    add r13d, 64
    jmp .col
.next_row:
    inc r12d
    jmp .row
.rows_done:
    cmp dword [rsp+8], 0
    je .no_stripe
    xor edi, edi
    mov esi, 133
    mov edx, 128
    mov ecx, 11
    mov r8d, [rsp+8]
    call fill_rect
.no_stripe:
    xor edi, edi
    mov esi, 249
    mov edx, 128
    mov ecx, 7
    mov r8d, RGB(34,34,34)              ; rubber base
    call fill_rect
    mov edi, 50
    mov esi, 30
    call grime
    mov edi, 1
    call upload
    EPILOGUE

; drywall(edi=base, esi=trim) -- classroom walls with a whiteboard
tex_drywall:
    PROLOGUE 32
    mov [rsp+0], edi
    mov [rsp+4], esi
    mov edi, 128
    mov esi, 256
    call canvas
    xor edi, edi
    xor esi, esi
    mov edx, 128
    mov ecx, 256
    mov r8d, [rsp+0]
    call fill_rect
    mov edi, 2500
    mov esi, RGB(0,0,0)
    mov edx, 25
    call speckle
    xor edi, edi
    mov esi, 247
    mov edx, 128
    mov ecx, 9
    mov r8d, [rsp+4]
    call fill_rect                      ; baseboard
    xor edi, edi
    mov esi, 92
    mov edx, 128
    mov ecx, 3
    mov r8d, [rsp+4]
    call fill_rect                      ; chair rail
    ; whiteboard with scribbles
    mov edi, 10
    mov esi, 110
    mov edx, 108
    mov ecx, 56
    mov r8d, RGB(119,119,119)
    call fill_rect
    mov edi, 12
    mov esi, 112
    mov edx, 104
    mov ecx, 52
    mov r8d, RGB(217,217,210)
    call fill_rect
    xor ebx, ebx
.scribble:
    cmp ebx, 5
    jge .scr_done
    mov edi, 80
    call rand_n
    lea edx, [rax+10]
    mov edi, 18
    imul esi, ebx, 9
    add esi, 118
    mov ecx, 2
    mov r8d, RGB(50,70,170)
    mov r9d, 150
    call blend_rect
    inc ebx
    jmp .scribble
.scr_done:
    mov edi, 40
    mov esi, 30
    call grime
    mov edi, 1
    call upload
    EPILOGUE

; concrete(edi=base) -- stairwells, basement, pillars
tex_concrete:
    PROLOGUE 16
    mov [rsp+0], edi
    mov edi, 128
    mov esi, 256
    call canvas
    xor edi, edi
    xor esi, esi
    mov edx, 128
    mov ecx, 256
    mov r8d, [rsp+0]
    call fill_rect
    mov edi, 3000
    mov esi, RGB(255,255,255)
    mov edx, 30
    call speckle
    mov edi, 3000
    mov esi, RGB(0,0,0)
    mov edx, 40
    call speckle
    xor edi, edi
    mov esi, 127
    mov edx, 128
    mov ecx, 2
    mov r8d, RGB(0,0,0)
    mov r9d, 90
    call blend_rect                     ; form-work seam
    mov edi, 90
    mov esi, 45
    call grime
    mov edi, 1
    call upload
    EPILOGUE

; skin: smooth and warm. At arm's length real skin reads as gentle colour
; variation, not texture: broad soft patches a touch redder or paler than the
; skin around them, and nothing sharp or speckled.
tex_skin:
    PROLOGUE 16
    mov edi, 128
    mov esi, 128
    call canvas
    xor edi, edi
    xor esi, esi
    mov edx, 128
    mov ecx, 128
    mov r8d, RGB(218,166,142)
    call fill_rect
    mov ebx, 140                        ; broad redder patches (blood near the surface)
.red:
    mov edi, 128
    call rand_n
    mov r12d, eax
    mov edi, 128
    call rand_n
    mov r13d, eax
    mov edi, 12
    call rand_n
    lea edx, [rax+8]
    mov edi, r12d
    mov esi, r13d
    mov ecx, RGB(208,138,120)
    mov r8d, 16
    call blotch
    dec ebx
    jnz .red
    mov ebx, 110                        ; broad paler patches
.pale:
    mov edi, 128
    call rand_n
    mov r12d, eax
    mov edi, 128
    call rand_n
    mov r13d, eax
    mov edi, 10
    call rand_n
    lea edx, [rax+7]
    mov edi, r12d
    mov esi, r13d
    mov ecx, RGB(230,186,162)
    mov r8d, 14
    call blotch
    dec ebx
    jnz .pale
    mov edi, 1
    call upload
    EPILOGUE

; the media wall: a Wireshark packet list -- a header bar, then rows in
; Wireshark's colouring (TCP lavender, UDP pale blue, HTTP pale green, ARP
; cream, the odd bad TCP in black and a red RST), each row with its columns
; of "text"
tex_media:
    PROLOGUE 16
    mov edi, 256
    mov esi, 256
    call canvas
    xor edi, edi
    xor esi, esi
    mov edx, 256
    mov ecx, 256
    mov r8d, RGB(10,12,18)
    call fill_rect
    mov r12d, 2                         ; y of the row
.row:
    cmp r12d, 250
    jge .rows_done
    mov edi, 16
    call rand_n
    mov r13d, [media_pal+rax*4]
    xor edi, edi
    mov esi, r12d
    mov edx, 256
    mov ecx, 7
    mov r8d, r13d
    call fill_rect
    xor ebx, ebx
.col:
    cmp ebx, 6
    jge .nrow
    mov edi, [media_colw+rbx*4]
    call rand_n
    lea edx, [rax+4]
    mov edi, [media_colx+rbx*4]
    lea esi, [r12d+2]
    mov ecx, 3
    mov r8d, RGB(40,40,52)
    cmp r13d, RGB(24,40,48)             ; bad TCP: red text on black
    jne .ink
    mov r8d, RGB(230,60,60)
.ink:
    call fill_rect
    inc ebx
    jmp .col
.nrow:
    add r12d, 8
    jmp .row
.rows_done:
    mov edi, 1
    call upload
    EPILOGUE

; cloth: dark navy hoodie cotton -- a fine weave, fuzz and wear
tex_cloth:
    PROLOGUE 16
    mov edi, 64
    mov esi, 64
    call canvas
    xor edi, edi
    xor esi, esi
    mov edx, 64
    mov ecx, 64
    mov r8d, RGB(40,44,58)
    call fill_rect
    xor ebx, ebx
.weave:
    cmp ebx, 64
    jge .woven
    mov edi, 0                          ; darker thread every other row...
    mov esi, ebx
    mov edx, 64
    mov ecx, 1
    mov r8d, RGB(18,20,28)
    mov r9d, 70
    call blend_rect
    mov edi, ebx                        ; ...and a lighter one every other column
    mov esi, 0
    mov edx, 1
    mov ecx, 64
    mov r8d, RGB(80,86,104)
    mov r9d, 40
    call blend_rect
    add ebx, 2
    jmp .weave
.woven:
    mov edi, 900
    mov esi, RGB(120,126,146)
    mov edx, 60
    call speckle
    mov edi, 20
    mov esi, 30
    call grime
    mov edi, 1
    call upload
    EPILOGUE

; gym: red wall, wooden slats low, white stripe
tex_gym:
    PROLOGUE 16
    mov edi, 128
    mov esi, 256
    call canvas
    xor edi, edi
    xor esi, esi
    mov edx, 128
    mov ecx, 256
    mov r8d, RGB(107,29,29)
    call fill_rect
    xor ebx, ebx
.slat:
    cmp ebx, 128
    jge .sl_done
    mov edi, 21
    call rand_n
    lea esi, [rax-10]
    mov edi, RGB(138,106,51)
    call shade
    mov r8d, eax
    mov edi, ebx
    mov esi, 141
    mov edx, 15
    mov ecx, 115
    call fill_rect
    add ebx, 16
    jmp .slat
.sl_done:
    xor edi, edi
    mov esi, 134
    mov edx, 128
    mov ecx, 5
    mov r8d, RGB(238,238,238)
    call fill_rect
    mov edi, 40
    mov esi, 30
    call grime
    mov edi, 1
    call upload
    EPILOGUE

; library shelves full of randomly coloured books
tex_bookshelf:
    PROLOGUE 16
    mov edi, 128
    mov esi, 256
    call canvas
    xor edi, edi
    xor esi, esi
    mov edx, 128
    mov ecx, 256
    mov r8d, RGB(58,36,20)
    call fill_rect
    xor r12d, r12d                      ; shelf
.shelf:
    cmp r12d, 6
    jge .sh_done
    imul r13d, r12d, 42                 ; shelf top y
    lea esi, [r13d+38]
    xor edi, edi
    mov edx, 128
    mov ecx, 4
    mov r8d, RGB(36,22,12)
    call fill_rect
    mov r14d, 5                         ; x
.book:
    cmp r14d, 120
    jge .next_shelf
    mov edi, 7
    call rand_n
    lea r15d, [rax+3]                   ; book width
    mov edi, 14
    call rand_n
    lea ebx, [rax+20]                   ; book height
    ; random dim colour
    mov edi, 140
    call rand_n
    lea ecx, [rax+30]
    mov [rsp+0], ecx
    mov edi, 110
    call rand_n
    lea ecx, [rax+20]
    mov [rsp+4], ecx
    mov edi, 110
    call rand_n
    lea ecx, [rax+20]
    shl ecx, 16
    mov eax, [rsp+4]
    shl eax, 8
    or ecx, eax
    or ecx, [rsp+0]
    or ecx, 0xFF000000
    mov r8d, ecx
    mov edi, r14d
    lea esi, [r13d+38]
    sub esi, ebx
    mov edx, r15d
    mov ecx, ebx
    call fill_rect
    lea r14d, [r14d+r15d+1]
    mov edi, 20
    call rand_n
    test eax, eax
    jnz .book
    add r14d, 10                        ; a missing book
    jmp .book
.next_shelf:
    inc r12d
    jmp .shelf
.sh_done:
    xor edi, edi
    xor esi, esi
    mov edx, 4
    mov ecx, 256
    mov r8d, RGB(43,26,14)
    call fill_rect
    mov edi, 124
    xor esi, esi
    mov edx, 4
    mov ecx, 256
    mov r8d, RGB(43,26,14)
    call fill_rect
    mov edi, 20
    mov esi, 25
    call grime
    mov edi, 1
    call upload
    EPILOGUE

; safe-room wall: blue tiles and a glowing rune
tex_safe:
    PROLOGUE 16
    mov edi, 128
    mov esi, 256
    call canvas
    xor edi, edi
    xor esi, esi
    mov edx, 128
    mov ecx, 256
    mov r8d, RGB(28,53,80)
    call fill_rect
    xor r12d, r12d
.ty:
    cmp r12d, 256
    jge .t_done
    xor r13d, r13d
.tx:
    cmp r13d, 128
    jge .tny
    mov edi, 21
    call rand_n
    lea esi, [rax-10]
    mov edi, RGB(44,90,134)
    call shade
    mov r8d, eax
    lea edi, [r13d+1]
    lea esi, [r12d+1]
    mov edx, 14
    mov ecx, 14
    call fill_rect
    add r13d, 16
    jmp .tx
.tny:
    add r12d, 16
    jmp .ty
.t_done:
    mov edi, 64
    mov esi, 110
    mov edx, 28
    mov ecx, RGB(120,225,255)
    call ring_rune
    mov edi, 1
    call upload
    EPILOGUE

; tex_floor(edi=colour a, esi=colour b, edx=tiles per side) -- checkerboard floor
tex_floor:
    PROLOGUE 32
    mov [rsp+0], edi                    ; colour a
    mov [rsp+4], esi                    ; colour b
    mov eax, 128
    mov ecx, edx
    xor edx, edx
    div ecx
    mov [rsp+8], eax                    ; tile size in pixels
    mov [rsp+12], ecx                   ; tiles per side
    mov edi, 128
    mov esi, 128
    call canvas
    xor r12d, r12d                      ; ty
.ty:
    cmp r12d, [rsp+12]
    jge .done_tiles
    xor r13d, r13d                      ; tx
.tx:
    cmp r13d, [rsp+12]
    jge .tny
    mov eax, r12d
    add eax, r13d
    and eax, 1
    mov edi, [rsp+0]
    jz .ca
    mov edi, [rsp+4]
.ca:
    mov ebx, edi
    mov edi, 11
    call rand_n
    lea esi, [rax-5]
    mov edi, ebx
    call shade
    mov r8d, eax
    mov edi, r13d
    imul edi, [rsp+8]
    mov esi, r12d
    imul esi, [rsp+8]
    mov edx, [rsp+8]
    mov ecx, [rsp+8]
    call fill_rect
    ; grout line along the top and left of the tile
    mov edi, r13d
    imul edi, [rsp+8]
    mov esi, r12d
    imul esi, [rsp+8]
    mov edx, [rsp+8]
    mov ecx, 1
    mov r8d, RGB(0,0,0)
    mov r9d, 70
    call blend_rect
    mov edi, r13d
    imul edi, [rsp+8]
    mov esi, r12d
    imul esi, [rsp+8]
    mov edx, 1
    mov ecx, [rsp+8]
    mov r8d, RGB(0,0,0)
    mov r9d, 70
    call blend_rect
    inc r13d
    jmp .tx
.tny:
    inc r12d
    jmp .ty
.done_tiles:
    mov edi, 30
    mov esi, 30
    call grime
    mov edi, 1
    call upload
    EPILOGUE

; acoustic ceiling tiles with a grid and a water stain
tex_ceiling:
    PROLOGUE 16
    mov edi, 128
    mov esi, 128
    call canvas
    xor edi, edi
    xor esi, esi
    mov edx, 128
    mov ecx, 128
    mov r8d, RGB(184,180,168)
    call fill_rect
    mov edi, 1500
    mov esi, RGB(0,0,0)
    mov edx, 70
    call speckle
    xor edi, edi
    xor esi, esi
    mov edx, 128
    mov ecx, 3
    mov r8d, RGB(106,106,102)
    call fill_rect
    xor edi, edi
    mov esi, 64
    mov edx, 128
    mov ecx, 3
    mov r8d, RGB(106,106,102)
    call fill_rect
    xor edi, edi
    xor esi, esi
    mov edx, 3
    mov ecx, 128
    mov r8d, RGB(106,106,102)
    call fill_rect
    mov edi, 85
    mov esi, 35
    mov edx, 28
    mov ecx, RGB(120,90,40)
    mov r8d, 120
    call blotch
    mov edi, 1
    call upload
    EPILOGUE

; server rack front: dark with slotted units (LEDs are a separate overlay)
tex_rack:
    PROLOGUE 16
    mov edi, 64
    mov esi, 128
    call canvas
    xor edi, edi
    xor esi, esi
    mov edx, 64
    mov ecx, 128
    mov r8d, RGB(16,17,20)
    call fill_rect
    mov ebx, 4
.unit:
    cmp ebx, 124
    jge .done
    mov edi, 4
    mov esi, ebx
    mov edx, 56
    mov ecx, 5
    mov r8d, RGB(29,31,36)
    call fill_rect
    add ebx, 6
    jmp .unit
.done:
    mov edi, 1
    call upload
    EPILOGUE

; LED overlay: transparent except for little green/amber/red dots
tex_leds:
    PROLOGUE 16
    mov edi, 64
    mov esi, 128
    call canvas
    lea rdi, [pix]
    xor esi, esi
    mov edx, 64*128*4
    call memset
    mov ebx, 4
.unit:
    cmp ebx, 124
    jge .done
    mov r12d, 46
.led:
    cmp r12d, 58
    jge .nu
    mov edi, 10
    call rand_n
    cmp eax, 6
    jge .nl
    mov r13d, RGB(40,255,90)            ; mostly green...
    cmp eax, 5
    jne .col
    mov r13d, RGB(255,170,0)            ; ...some amber...
    call rng_next
    test eax, 1
    jz .col
    mov r13d, RGB(255,40,40)            ; ...and the odd red one
.col:
    mov r8d, r13d
    mov edi, r12d
    lea esi, [rbx+1]
    mov edx, 2
    mov ecx, 2
    call fill_rect
.nl:
    add r12d, 3
    jmp .led
.nu:
    add ebx, 6
    jmp .unit
.done:
    mov edi, 1
    call upload
    EPILOGUE

; film grain: grey noise with random alpha (drawn over the whole screen)
tex_grain:
    PROLOGUE 16
    mov edi, 128
    mov esi, 128
    call canvas
    xor ebx, ebx
.px:
    cmp ebx, 128*128
    jge .done
    mov edi, 256
    call rand_n
    mov ecx, eax
    imul ecx, 0x010101
    mov r12d, ecx
    mov edi, 256
    call rand_n
    shl eax, 24
    or eax, r12d
    mov [pix+rbx*4], eax
    inc ebx
    jmp .px
.done:
    mov edi, 1
    call upload
    EPILOGUE

; radial: white with alpha = (1 - d)^2 -- item glows, vignettes, halos
tex_radial:
    PROLOGUE 16
    mov edi, 64
    mov esi, 64
    call canvas
    xor r12d, r12d
.y:
    cmp r12d, 64
    jge .done
    xor r13d, r13d
.x:
    cmp r13d, 64
    jge .ny
    mov eax, r13d
    sub eax, 32
    cvtsi2ss xmm0, eax
    mov eax, r12d
    sub eax, 32
    cvtsi2ss xmm1, eax
    mulss xmm0, xmm0
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    mov eax, 32
    cvtsi2ss xmm1, eax
    divss xmm0, xmm1
    minss xmm0, [c_one]
    movss xmm1, [c_one]
    subss xmm1, xmm0
    mulss xmm1, xmm1
    mov eax, 255
    cvtsi2ss xmm2, eax
    mulss xmm1, xmm2
    cvttss2si eax, xmm1
    shl eax, 24
    or eax, 0x00FFFFFF
    mov ecx, r12d
    shl ecx, 6
    add ecx, r13d
    mov [pix+rcx*4], eax
    inc r13d
    jmp .x
.ny:
    inc r12d
    jmp .y
.done:
    xor edi, edi
    call upload
    EPILOGUE

; T's face: T_Sprite.jpeg with a soft oval alpha mask, desaturated and
; darkened so it fades into the dark instead of showing a square photo.
tex_face:
    PROLOGUE 32
    lea rdi, [face_file]
    call IMG_Load
    test rax, rax
    jnz .loaded
    lea rdi, [err_face]
    xor eax, eax
    call printf
    mov eax, [white_tex]
    mov [face_tex], eax
    EPILOGUE
.loaded:
    mov rdi, rax
    mov r15, rax
    mov esi, SDL_PIXELFORMAT_ABGR8888
    xor edx, edx
    call SDL_ConvertSurfaceFormat
    mov r14, rax                        ; converted surface
    mov rdi, r15
    call SDL_FreeSurface
    ; copy into pix (256x256 nearest-neighbour resample)
    mov edi, 256
    mov esi, 256
    call canvas
    mov eax, [r14+16]
    mov [rsp+0], eax                    ; src w
    mov eax, [r14+20]
    mov [rsp+4], eax                    ; src h
    mov eax, [r14+24]
    mov [rsp+8], eax                    ; pitch
    mov rax, [r14+32]
    mov [rsp+16], rax                   ; pixels
    xor r12d, r12d                      ; y
.y:
    cmp r12d, 256
    jge .done
    xor r13d, r13d                      ; x
.x:
    cmp r13d, 256
    jge .ny
    ; source pixel
    mov eax, r12d
    imul eax, [rsp+4]
    shr eax, 8
    imul eax, [rsp+8]
    mov ecx, r13d
    imul ecx, [rsp+0]
    shr ecx, 8
    lea eax, [rax+rcx*4]
    mov rcx, [rsp+16]
    mov ebx, [rcx+rax]                  ; R G B A
    ; oval mask: d = sqrt(((x-124)/78)^2 + ((y-120)/108)^2), a = clamp((1.15-d)/0.35)
    mov eax, r13d
    sub eax, 124
    cvtsi2ss xmm0, eax
    FLD xmm1, 78.0
    divss xmm0, xmm1
    mulss xmm0, xmm0
    mov eax, r12d
    sub eax, 120
    cvtsi2ss xmm2, eax
    FLD xmm1, 108.0
    divss xmm2, xmm1
    mulss xmm2, xmm2
    addss xmm0, xmm2
    sqrtss xmm0, xmm0
    FLD xmm1, 1.15
    subss xmm1, xmm0
    FLD xmm2, 0.35
    divss xmm1, xmm2
    maxss xmm1, [c_zero]
    minss xmm1, [c_one]
    FLD xmm2, 255.0
    mulss xmm1, xmm2
    cvttss2si r8d, xmm1                 ; alpha
    ; desaturate: g = (r+g+b)/3 ; r' = .95g + .15r, g' = .85g, b' = .8g
    movzx eax, bl
    movzx ecx, bh
    mov edx, ebx
    shr edx, 16
    and edx, 255
    mov r9d, eax                        ; original red
    add eax, ecx
    add eax, edx
    cvtsi2ss xmm0, eax
    FLD xmm1, 3.0
    divss xmm0, xmm1                    ; grey
    FLD xmm1, 0.95
    mulss xmm1, xmm0
    cvtsi2ss xmm2, r9d
    FLD xmm3, 0.15
    mulss xmm2, xmm3
    addss xmm1, xmm2
    FLD xmm3, 255.0
    minss xmm1, xmm3
    cvttss2si r10d, xmm1                ; r' (not eax: FLD uses eax)
    FLD xmm1, 0.85
    mulss xmm1, xmm0
    cvttss2si ecx, xmm1                 ; g'
    FLD xmm1, 0.8
    mulss xmm1, xmm0
    cvttss2si edx, xmm1                 ; b'
    shl ecx, 8
    shl edx, 16
    shl r8d, 24
    mov eax, r10d
    or eax, ecx
    or eax, edx
    or eax, r8d
    mov ecx, r12d
    shl ecx, 8
    add ecx, r13d
    mov [pix+rcx*4], eax
    inc r13d
    jmp .x
.ny:
    inc r12d
    jmp .y
.done:
    mov rdi, r14
    call SDL_FreeSurface
    xor edi, edi
    call upload
    mov [face_tex], eax
    EPILOGUE

; =============================================================================
; text
; =============================================================================

; surface_to_texture(rdi=SDL_Surface* in ABGR8888) -> eax = GL texture id
; (no mipmaps, clamped; sets tt_w / tt_h). Frees the surface.
surface_to_texture:
    PROLOGUE 48
    mov r12, rdi
    mov eax, [r12+16]
    mov [tt_w], eax
    mov eax, [r12+20]
    mov [tt_h], eax
    lea rsi, [tmp_id]
    mov edi, 1
    call glGenTextures
    mov edi, GL_TEXTURE_2D
    mov esi, [tmp_id]
    call glBindTexture
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_MIN_FILTER
    mov edx, GL_LINEAR
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_MAG_FILTER
    mov edx, GL_LINEAR
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_WRAP_S
    mov edx, GL_CLAMP_TO_EDGE
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_TEXTURE_WRAP_T
    mov edx, GL_CLAMP_TO_EDGE
    call glTexParameteri
    mov edi, GL_TEXTURE_2D
    mov esi, GL_GENERATE_MIPMAP
    xor edx, edx
    call glTexParameteri
    ; rows may be padded: tell GL the real row length in pixels
    mov esi, [r12+24]
    shr esi, 2
    mov edi, GL_UNPACK_ROW_LENGTH
    call glPixelStorei
    mov qword [rsp+0], GL_RGBA
    mov qword [rsp+8], GL_UNSIGNED_BYTE
    mov rax, [r12+32]
    mov [rsp+16], rax
    mov edi, GL_TEXTURE_2D
    xor esi, esi
    mov edx, GL_RGBA
    mov ecx, [r12+16]
    mov r8d, [r12+20]
    xor r9d, r9d
    call glTexImage2D
    mov edi, GL_UNPACK_ROW_LENGTH
    xor esi, esi
    call glPixelStorei
    mov rdi, r12
    call SDL_FreeSurface
    mov eax, [tmp_id]
    EPILOGUE

; render_text_surface(rdi=font, rsi=utf8 text, edx=colour 0xAABBGGRR,
;                     ecx=wrap width or 0) -> rax = ABGR8888 surface or 0
render_text_surface:
    PROLOGUE 16
    test ecx, ecx
    jz .plain
    call TTF_RenderUTF8_Blended_Wrapped ; SDL_Color {r,g,b,a} passed in edx
    jmp .have
.plain:
    call TTF_RenderUTF8_Blended
.have:
    test rax, rax
    jz .fail
    mov r12, rax
    mov rdi, rax
    mov esi, SDL_PIXELFORMAT_ABGR8888
    xor edx, edx
    call SDL_ConvertSurfaceFormat
    mov r13, rax
    mov rdi, r12
    call SDL_FreeSurface
    mov rax, r13
.fail:
    EPILOGUE

; make_text_texture(rdi=font, rsi=text, edx=colour, ecx=wrap) -> eax GL id
; (0 on failure); size in tt_w/tt_h
make_text_texture:
    PROLOGUE 16
    call render_text_surface
    test rax, rax
    jz .fail
    mov rdi, rax
    call surface_to_texture
    EPILOGUE
.fail:
    xor eax, eax
    mov dword [tt_w], 0
    mov dword [tt_h], 0
    EPILOGUE

; make_plaque(rdi=text, esi=w, edx=h, ecx=fg, r8d=bg, r9=font) -> eax GL id
; A rectangle with a border and centred text: room signs and item labels.
make_plaque:
    PROLOGUE 64
    mov [rsp+32], rdi                   ; text
    mov [rsp+40], esi                   ; w
    mov [rsp+44], edx                   ; h
    mov [rsp+48], ecx                   ; fg
    mov [rsp+52], r8d                   ; bg
    mov [rsp+56], r9                    ; font
    ; blank canvas surface
    xor edi, edi
    mov esi, [rsp+40]
    mov edx, [rsp+44]
    mov ecx, 32
    mov r8d, SDL_PIXELFORMAT_ABGR8888
    call SDL_CreateRGBSurfaceWithFormat
    mov r12, rax
    ; border colour fills everything, then inset background
    mov rdi, r12
    xor esi, esi
    mov edx, [rsp+48]
    call SDL_FillRect
    mov dword [rsp+0], 6                ; SDL_Rect x
    mov dword [rsp+4], 6                ; y
    mov eax, [rsp+40]
    sub eax, 12
    mov [rsp+8], eax                    ; w
    mov eax, [rsp+44]
    sub eax, 12
    mov [rsp+12], eax                   ; h
    mov rdi, r12
    lea rsi, [rsp+0]
    mov edx, [rsp+52]
    call SDL_FillRect
    ; text, wrapped to the plaque width
    mov rdi, [rsp+56]
    mov rsi, [rsp+32]
    mov edx, [rsp+48]
    mov ecx, [rsp+40]
    sub ecx, 20
    call render_text_surface
    test rax, rax
    jz .no_text
    mov r13, rax
    ; centre it
    mov eax, [rsp+40]
    sub eax, [r13+16]
    sar eax, 1
    mov [rsp+0], eax
    mov eax, [rsp+44]
    sub eax, [r13+20]
    sar eax, 1
    mov [rsp+4], eax
    mov eax, [r13+16]
    mov [rsp+8], eax
    mov eax, [r13+20]
    mov [rsp+12], eax
    mov rdi, r13
    xor esi, esi
    mov rdx, r12
    lea rcx, [rsp+0]
    call SDL_UpperBlit
    mov rdi, r13
    call SDL_FreeSurface
.no_text:
    mov rdi, r12
    call surface_to_texture
    EPILOGUE

; open_font(rdi=path, esi=size) -> rax (exits on failure)
open_font:
    PROLOGUE 16
    mov r12, rdi
    call TTF_OpenFont
    test rax, rax
    jnz .ok
    lea rdi, [err_font]
    mov rsi, r12
    xor eax, eax
    call printf
    mov edi, 1
    call exit
.ok:
    EPILOGUE

; =============================================================================
; textures_init() -- paint and upload everything. Called once, after the GL
; context exists. Uses a fixed srand() so textures look the same every run.
; =============================================================================
textures_init:
    PROLOGUE 16
    mov edi, 1234
    call rng_seed

    ; 1x1 white, used for untextured (vertex-coloured) geometry
    mov edi, 1
    mov esi, 1
    call canvas
    mov dword [pix], 0xFFFFFFFF
    mov edi, 1
    call upload
    mov [white_tex], eax

    mov edi, RGB(185,173,143)
    mov esi, RGB(140,130,107)
    mov edx, RGB(106,42,42)
    call tex_cinderblock
    mov [tex_ids+TX_H*4], eax
    mov edi, RGB(169,167,154)
    mov esi, RGB(61,58,51)
    call tex_drywall
    mov [tex_ids+TX_C*4], eax
    call tex_gym
    mov [tex_ids+TX_G*4], eax
    call tex_bookshelf
    mov [tex_ids+TX_L*4], eax
    call tex_safe
    mov [tex_ids+TX_N*4], eax
    mov edi, RGB(111,109,104)
    call tex_concrete
    mov [tex_ids+TX_CONC*4], eax
    mov edi, RGB(143,138,124)
    mov esi, RGB(111,107,96)
    mov edx, 8
    call tex_floor
    mov [tex_ids+TX_FLOOR*4], eax
    mov edi, RGB(78,76,71)
    mov esi, RGB(70,68,63)
    mov edx, 2
    call tex_floor
    mov [tex_ids+TX_FLOOR_B*4], eax
    mov edi, RGB(45,85,122)
    mov esi, RGB(36,71,100)
    mov edx, 8
    call tex_floor
    mov [tex_ids+TX_FLOOR_S*4], eax
    call tex_ceiling
    mov [tex_ids+TX_CEIL*4], eax
    mov edi, RGB(59,58,55)
    call tex_concrete
    mov [tex_ids+TX_CEIL_B*4], eax
    call tex_rack
    mov [tex_ids+TX_RACK*4], eax
    call tex_leds
    mov [led_tex], eax
    call tex_grain
    mov [grain_tex], eax
    call tex_radial
    mov [radial_tex], eax
    call tex_face
    call tex_skin
    mov [skin_tex], eax
    call tex_cloth
    mov [cloth_tex], eax
    call tex_media
    mov [media_tex], eax

    ; ---- fonts
    call TTF_Init
    lea rdi, [font_path_mono]
    mov esi, 17
    call open_font
    mov [font_hud], rax
    lea rdi, [font_path_mono]
    mov esi, 14
    call open_font
    mov [font_small], rax
    lea rdi, [font_path_sans]
    mov esi, 44
    call open_font
    mov [font_big], rax
    lea rdi, [font_path_mono]
    mov esi, 30
    call open_font
    mov [font_label], rax

    ; ---- hanging signs (exit signs are red on black)
    xor ebx, ebx
.sign:
    cmp ebx, NSIGNS
    jge .signs_done
    mov rdi, [sign_text+rbx*8]
    mov esi, 512
    mov edx, 128
    mov ecx, RGB(232,232,218)
    mov r8d, RGB(29,42,31)
    cmp dword [sign_exit+rbx*4], 0
    je .plain_sign
    mov ecx, RGB(255,64,64)
    mov r8d, RGB(27,0,0)
.plain_sign:
    mov r9, [font_big]
    call make_plaque
    mov [sign_tex+rbx*4], eax
    inc ebx
    jmp .sign
.signs_done:
    ; ---- item / character labels
    lea rdi, [lbl_pcap]
    mov esi, 128
    mov edx, 128
    mov ecx, RGB(79,208,255)
    mov r8d, RGB(4,24,36)
    mov r9, [font_label]
    call make_plaque
    mov [label_tex+0], eax
    lea rdi, [lbl_deauth]
    mov esi, 128
    mov edx, 128
    mov ecx, RGB(255,64,64)
    mov r8d, RGB(32,4,4)
    mov r9, [font_label]
    call make_plaque
    mov [label_tex+4], eax
    lea rdi, [lbl_b]
    mov esi, 128
    mov edx, 128
    mov ecx, RGB(95,216,255)
    mov r8d, RGB(4,18,28)
    mov r9, [font_big]
    call make_plaque
    mov [label_tex+LBL_B*4], eax
    lea rdi, [lbl_y]
    mov esi, 128
    mov edx, 128
    mov ecx, RGB(208,32,32)
    mov r8d, RGB(232,224,200)
    mov r9, [font_label]
    call make_plaque
    mov [label_tex+LBL_Y*4], eax
    ; the Zelda items and the portal gun
    lea rdi, [lbl_map]
    mov esi, 128
    mov edx, 128
    mov ecx, RGB(90,50,20)
    mov r8d, RGB(222,196,140)           ; parchment
    mov r9, [font_label]
    call make_plaque
    mov [label_tex+IT_MAP*4], eax
    lea rdi, [lbl_compass]
    mov esi, 128
    mov edx, 128
    mov ecx, RGB(200,30,30)
    mov r8d, RGB(214,170,60)            ; brass
    mov r9, [font_big]
    call make_plaque
    mov [label_tex+IT_COMPASS*4], eax
    lea rdi, [lbl_portal]
    mov esi, 128
    mov edx, 128
    mov ecx, RGB(255,150,40)
    mov r8d, RGB(235,235,235)
    mov r9, [font_label]
    call make_plaque
    mov [label_tex+IT_PORTAL*4], eax
    lea rdi, [lbl_hook]
    mov esi, 128
    mov edx, 128
    mov ecx, RGB(40,40,40)
    mov r8d, RGB(120,200,90)            ; Zelda green
    mov r9, [font_label]
    call make_plaque
    mov [label_tex+IT_HOOKSHOT*4], eax
    ; props: a cardboard box and a yellow wet-floor sign
    lea rdi, [lbl_box]
    mov esi, 128
    mov edx, 128
    mov ecx, RGB(120,60,30)
    mov r8d, RGB(176,134,84)
    mov r9, [font_small]
    call make_plaque
    mov [prop_tex+0], eax
    lea rdi, [lbl_sign]
    mov esi, 128
    mov edx, 256
    mov ecx, RGB(20,20,20)
    mov r8d, RGB(250,210,20)
    mov r9, [font_hud]
    call make_plaque
    mov [prop_tex+4], eax
    EPILOGUE
