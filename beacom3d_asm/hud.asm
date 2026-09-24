; =============================================================================
; hud.asm -- everything drawn flat on top of the 3D view, in pixel
; coordinates (origin top-left): floor name, capture diamonds, stamina and
; flashlight bars, deauth count, the interaction prompt, the fading message
; log, "HE SEES YOU", the danger/safe vignettes, film grain, the deauth flash,
; the pause screen and the explored-area map (M / TAB).
; Text is rendered once to textures with SDL_ttf (see textures.asm).
; =============================================================================
%define MODULE_HUD
%include "common.inc"

global hud_init, hud_draw, hud_message, hud_clear_messages, map_visible, explored
global draw_text, draw_rect
global hud_prompt, hud_vignette, hud_safe_tint, hud_flash, hud_update_explored, hud_paused, hud_fps
global map_floor
extern have_map, have_compass, items, item_count, t_x, t_y, t_z, b_pos_x, b_pos_z, b_floor
extern floor_of_height

extern font_hud, font_small, font_big, tt_w, tt_h, t_sees, p_stamina, p_battery
extern p_flash_on, p_exhausted, player_floor, p_x, p_z, p_yaw, glDeleteTextures, t_dist, t_hear_d

%define MAX_MSG 6
%define RGBC(r,g,b) (0xFF000000 | ((b)<<16) | ((g)<<8) | (r))

; quad in pixel space: QUAD x, y, w, h (float literals or registers are not
; supported -- use draw_rect for computed values)

section .data
s_floor0    db "BASEMENT",0
s_floor1    db "GROUND FLOOR",0
s_floor2    db "SECOND FLOOR",0
s_stamina   db "STAMINA",0
s_flash     db "FLASHLIGHT",0
s_sees      db "HE SEES YOU",0
s_pr0       db "[E] take the packet capture",0
s_pr1       db "[E] take the deauth packet",0
s_pr2       db "[E] take the MAP",0
s_pr3       db "[E] take the COMPASS",0
s_pr4       db "[E] take the PORTAL GUN",0
s_pr5       db "[E] take the HOOKSHOT",0
s_pr6       db "[E] drink the DIET MOUNTAIN DEW",0
s_pr7       db "[E] talk to B",0
s_pr8       db "[E] give B the captures",0
s_pr9       db "[E] grab the zipline",0
s_pr10      db "[W] climb the ladder",0
s_dew       db "DIET DEW: UNLIMITED STAMINA",0
s_mapfull   db "MAP  --  [ ] change floor",0
s_dirs      db "N",0,"E",0,"S",0,"W",0
s_paused    db "PAUSED",0
s_paused2   db "T is waiting.   ESC or click to resume   (Q in the terminal quits)",0
s_map       db "explored map",0
s_noise     db "NOISE  (| = T hears)",0
s_deauth_fmt db "ITEM: DEAUTH x%d",0
s_item_portal db "ITEM: PORTAL GUN",0
s_item_hook db "ITEM: HOOKSHOT",0
s_item_none db "ITEM: -",0
align 8
item_strs   dq s_item_none, 0, s_item_portal, s_item_hook
s_fps_fmt   db "FPS %d",0
align 8
floor_names dq s_floor0, s_floor1, s_floor2
prompt_strs dq s_pr0, s_pr1, s_pr2, s_pr3, s_pr4, s_pr5, s_pr6, s_pr7, s_pr8, s_pr9, s_pr10
%define NPROMPTS 11

c_msg_life   dd 7.5
c_lore_life  dd 15.5
c_fade       dd 1.5
c_grain_a    dd 0.07
c_pulse      dd 9.0
c_neg_pi     dd -3.14159265
; compass marker colours by pickup kind: capture deauth map compass portal
mark_col     dd 0.3,0.85,1.0,  1.0,0.3,0.3,  1.0,0.85,0.4,  1.0,0.75,0.2,  1.0,0.55,0.15,  0.45,1.0,0.35,  0.6,1.0,0.2

section .bss
floor_tex   resd NF
floor_w     resd NF
floor_h     resd NF
prompt_tex  resd 10
prompt_w    resd 10
prompt_h    resd 10
map_floor   resd 1                  ; which storey the map is showing
dir_tex     resd 4                  ; N E S W for the compass strip
dir_w       resd 4
dir_h       resd 4
deauth_tex  resd 10
item_tex    resd 4                  ; what you're holding (SP_)
item_w      resd 4
item_h      resd 4
deauth_w    resd 10
deauth_h    resd 10
misc_tex    resd 9                  ; stamina, flashlight, sees, paused, paused2, map, noise, full map, dew
misc_w      resd 9
misc_h      resd 9
msg_tex     resd MAX_MSG
msg_w       resd MAX_MSG
msg_h       resd MAX_MSG
msg_time    resd MAX_MSG            ; seconds left
msg_count   resd 1
map_visible resd 1
hud_prompt  resd 1                  ; -1 none, else index into prompt_strs
hud_vignette resd 1                 ; float 0..1 red danger vignette
hud_safe_tint resd 1                ; float 0..1 blue safe-room vignette
hud_flash   resd 1                  ; float 0..1 deauth flash
hud_paused  resd 1
explored    resb NCELLS
scr_w       resd 1
map_s       resd 1                  ; open map: pixels per cell and origin
map_ox      resd 1
map_oy      resd 1
hud_time    resd 1
scr_h       resd 1
fmt_buf     resb 64
hud_fps     resd 1                  ; -1 = hidden, else frames last second
fps_shown   resd 1
fps_tex     resd 1
fps_w       resd 1
fps_h       resd 1

section .text

; mk(rdi=font, rsi=text, edx=colour) -> eax tex, ecx w, r8d h
mk:
    PROLOGUE 16
    xor ecx, ecx
    call make_text_texture
    mov ecx, [tt_w]
    mov r8d, [tt_h]
    EPILOGUE

; hud_init() -- pre-render all the fixed strings
hud_init:
    PROLOGUE 16
    xor ebx, ebx
.fl:
    cmp ebx, NF
    jge .fl_done
    mov rdi, [font_hud]
    mov rsi, [floor_names+rbx*8]
    mov edx, RGBC(207,198,176)
    call mk
    mov [floor_tex+rbx*4], eax
    mov [floor_w+rbx*4], ecx
    mov [floor_h+rbx*4], r8d
    inc ebx
    jmp .fl
.fl_done:
    xor ebx, ebx
.pr:
    cmp ebx, NPROMPTS
    jge .pr_done
    mov rdi, [font_hud]
    mov rsi, [prompt_strs+rbx*8]
    mov edx, RGBC(255,255,255)
    call mk
    mov [prompt_tex+rbx*4], eax
    mov [prompt_w+rbx*4], ecx
    mov [prompt_h+rbx*4], r8d
    inc ebx
    jmp .pr
.pr_done:
    xor ebx, ebx
.it:
    cmp ebx, 4
    jge .it_done
    mov rsi, [item_strs+rbx*8]
    test rsi, rsi
    jz .it_next
    mov rdi, [font_hud]
    mov edx, RGBC(255,110,110)
    call mk
    mov [item_tex+rbx*4], eax
    mov [item_w+rbx*4], ecx
    mov [item_h+rbx*4], r8d
.it_next:
    inc ebx
    jmp .it
.it_done:
    xor ebx, ebx
.da:
    cmp ebx, 10
    jge .da_done
    lea rdi, [fmt_buf]
    mov esi, 64
    lea rdx, [s_deauth_fmt]
    mov ecx, ebx
    xor eax, eax
    call snprintf
    mov rdi, [font_small]
    lea rsi, [fmt_buf]
    mov edx, RGBC(255,107,107)
    call mk
    mov [deauth_tex+rbx*4], eax
    mov [deauth_w+rbx*4], ecx
    mov [deauth_h+rbx*4], r8d
    inc ebx
    jmp .da
.da_done:
    mov rdi, [font_small]
    lea rsi, [s_stamina]
    mov edx, RGBC(216,212,200)
    call mk
    mov [misc_tex+0], eax
    mov [misc_w+0], ecx
    mov [misc_h+0], r8d
    mov rdi, [font_small]
    lea rsi, [s_flash]
    mov edx, RGBC(216,212,200)
    call mk
    mov [misc_tex+4], eax
    mov [misc_w+4], ecx
    mov [misc_h+4], r8d
    mov rdi, [font_hud]
    lea rsi, [s_sees]
    mov edx, RGBC(255,59,59)
    call mk
    mov [misc_tex+8], eax
    mov [misc_w+8], ecx
    mov [misc_h+8], r8d
    mov rdi, [font_big]
    lea rsi, [s_paused]
    mov edx, RGBC(176,20,26)
    call mk
    mov [misc_tex+12], eax
    mov [misc_w+12], ecx
    mov [misc_h+12], r8d
    mov rdi, [font_hud]
    lea rsi, [s_paused2]
    mov edx, RGBC(170,165,150)
    call mk
    mov [misc_tex+16], eax
    mov [misc_w+16], ecx
    mov [misc_h+16], r8d
    mov rdi, [font_small]
    lea rsi, [s_map]
    mov edx, RGBC(150,150,150)
    call mk
    mov [misc_tex+20], eax
    mov [misc_w+20], ecx
    mov [misc_h+20], r8d
    mov rdi, [font_small]
    lea rsi, [s_noise]
    mov edx, RGBC(216,212,200)
    call mk
    mov [misc_tex+24], eax
    mov [misc_w+24], ecx
    mov [misc_h+24], r8d
    mov rdi, [font_small]
    lea rsi, [s_mapfull]
    mov edx, RGBC(230,200,130)
    call mk
    mov [misc_tex+28], eax
    mov [misc_w+28], ecx
    mov [misc_h+28], r8d
    mov rdi, [font_small]
    lea rsi, [s_dew]
    mov edx, RGBC(150,255,60)
    call mk
    mov [misc_tex+32], eax
    mov [misc_w+32], ecx
    mov [misc_h+32], r8d
    ; compass letters
    xor ebx, ebx
.dir:
    cmp ebx, 4
    jge .dir_done
    mov rdi, [font_hud]
    lea rsi, [s_dirs+rbx*2]
    mov edx, RGBC(240,210,120)
    cmp ebx, 0
    jne .dcol
    mov edx, RGBC(255,80,70)            ; north in red
.dcol:
    call mk
    mov [dir_tex+rbx*4], eax
    mov [dir_w+rbx*4], ecx
    mov [dir_h+rbx*4], r8d
    inc ebx
    jmp .dir
.dir_done:
    mov dword [hud_prompt], -1
    mov dword [hud_fps], -1
    mov dword [fps_shown], -1
    EPILOGUE

; delete_msg(edi=slot) -- free a message texture and shift the rest down
delete_msg:
    PROLOGUE 16
    mov ebx, edi
    lea rsi, [msg_tex+rbx*4]
    mov edi, 1
    call glDeleteTextures
.shift:
    lea eax, [rbx+1]
    cmp eax, [msg_count]
    jge .shifted
    mov ecx, [msg_tex+rax*4]
    mov [msg_tex+rbx*4], ecx
    mov ecx, [msg_w+rax*4]
    mov [msg_w+rbx*4], ecx
    mov ecx, [msg_h+rax*4]
    mov [msg_h+rbx*4], ecx
    mov ecx, [msg_time+rax*4]
    mov [msg_time+rbx*4], ecx
    inc ebx
    jmp .shift
.shifted:
    dec dword [msg_count]
    EPILOGUE

; hud_message(rdi=text, esi=colour 0xAABBGGRR, edx=1 if long lore text)
; Shows the text over the bottom of the screen for a few seconds.
hud_message:
    PROLOGUE 16
    mov r12, rdi
    mov r13d, esi
    mov r14d, edx
    cmp dword [msg_count], MAX_MSG
    jl .room
    xor edi, edi
    call delete_msg                     ; drop the oldest
.room:
    mov rdi, [font_hud]
    mov rsi, r12
    mov edx, r13d
    mov ecx, 760                        ; wrap long lines
    call make_text_texture
    test eax, eax
    jz .done
    mov ecx, [msg_count]
    mov [msg_tex+rcx*4], eax
    mov eax, [tt_w]
    mov [msg_w+rcx*4], eax
    mov eax, [tt_h]
    mov [msg_h+rcx*4], eax
    mov eax, [c_msg_life]
    test r14d, r14d
    jz .life
    mov eax, [c_lore_life]
.life:
    mov [msg_time+rcx*4], eax
    inc dword [msg_count]
.done:
    EPILOGUE

hud_clear_messages:
    PROLOGUE 16
.loop:
    cmp dword [msg_count], 0
    je .done
    xor edi, edi
    call delete_msg
    jmp .loop
.done:
    EPILOGUE

; hud_update_explored() -- reveal a 7x7 patch of the map around the player
hud_update_explored:
    PROLOGUE 16
    call player_floor
    mov r12d, eax
    movss xmm0, [p_x]
    mulss xmm0, [c_inv_cell]
    cvttss2si r13d, xmm0
    movss xmm0, [p_z]
    mulss xmm0, [c_inv_cell]
    cvttss2si r14d, xmm0
    mov ebx, -3
.dy:
    cmp ebx, 3
    jg .done
    mov r15d, -3
.dx:
    cmp r15d, 3
    jg .ndy
    lea esi, [r13d+r15d]
    lea edx, [r14d+ebx]
    cmp esi, 0
    jl .ndx
    cmp esi, MAP_W
    jge .ndx
    cmp edx, 0
    jl .ndx
    cmp edx, MAP_H
    jge .ndx
    mov edi, r12d
    call cell_index
    mov byte [explored+rax], 1
.ndx:
    inc r15d
    jmp .dx
.ndy:
    inc ebx
    jmp .dy
.done:
    EPILOGUE

; draw_tex(edi=texture, xmm0=x, xmm1=y, xmm2=w, xmm3=h, xmm4=alpha)
draw_tex:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    movss [rsp+16], xmm4
    mov esi, edi
    mov edi, GL_TEXTURE_2D
    call glBindTexture
    movss xmm0, [c_one]
    movss xmm1, [c_one]
    movss xmm2, [c_one]
    movss xmm3, [rsp+16]
    call glColor4f
    mov edi, GL_QUADS
    call glBegin
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    call glTexCoord2f
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    call glVertex2f
    movss xmm0, [c_one]
    xorps xmm1, xmm1
    call glTexCoord2f
    movss xmm0, [rsp+0]
    addss xmm0, [rsp+8]
    movss xmm1, [rsp+4]
    call glVertex2f
    movss xmm0, [c_one]
    movss xmm1, [c_one]
    call glTexCoord2f
    movss xmm0, [rsp+0]
    addss xmm0, [rsp+8]
    movss xmm1, [rsp+4]
    addss xmm1, [rsp+12]
    call glVertex2f
    xorps xmm0, xmm0
    movss xmm1, [c_one]
    call glTexCoord2f
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    addss xmm1, [rsp+12]
    call glVertex2f
    call glEnd
    EPILOGUE

; draw_text(edi=texture, esi=w, edx=h, xmm0=x, xmm1=y, xmm2=alpha)
draw_text:
    sub rsp, 8
    movaps xmm4, xmm2
    cvtsi2ss xmm2, esi
    cvtsi2ss xmm3, edx
    call draw_tex
    add rsp, 8
    ret

; draw_rect(xmm0=x, xmm1=y, xmm2=w, xmm3=h, xmm4=r, xmm5=g, xmm6=b, xmm7=a)
; flat colour (binds the white texture)
draw_rect:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    movss [rsp+16], xmm4
    movss [rsp+20], xmm5
    movss [rsp+24], xmm6
    movss [rsp+28], xmm7
    mov edi, GL_TEXTURE_2D
    mov esi, [white_tex]
    call glBindTexture
    movss xmm0, [rsp+16]
    movss xmm1, [rsp+20]
    movss xmm2, [rsp+24]
    movss xmm3, [rsp+28]
    call glColor4f
    mov edi, GL_QUADS
    call glBegin
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    call glVertex2f
    movss xmm0, [rsp+0]
    addss xmm0, [rsp+8]
    movss xmm1, [rsp+4]
    call glVertex2f
    movss xmm0, [rsp+0]
    addss xmm0, [rsp+8]
    movss xmm1, [rsp+4]
    addss xmm1, [rsp+12]
    call glVertex2f
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    addss xmm1, [rsp+12]
    call glVertex2f
    call glEnd
    EPILOGUE

; vignette(xmm0=r, xmm1=g, xmm2=b, xmm3=edge alpha) -- transparent in the
; middle, coloured at the edges: a ring of quads from an inner ellipse
; (alpha 0) out past the screen corners (alpha a)
vignette:
    PROLOGUE 64
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    mov edi, GL_TEXTURE_2D
    mov esi, [white_tex]
    call glBindTexture
    mov edi, GL_QUADS
    call glBegin
    xor ebx, ebx
.seg:
    cmp ebx, 32
    jge .done
    xor r12d, r12d
.v:
    cmp r12d, 4
    jge .nseg
    ; corners: 0 inner(i) 1 inner(i+1) 2 outer(i+1) 3 outer(i)
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
    FLD xmm1, 32.0
    divss xmm0, xmm1
    movss [rsp+16], xmm0
    call cosf
    movss [rsp+20], xmm0
    movss xmm0, [rsp+16]
    call sinf
    movss [rsp+24], xmm0
    ; radius factor: inner 0.55, outer 1.5 (of the half-screen size)
    FLD xmm5, 0.55
    xorps xmm3, xmm3                    ; alpha
    cmp r12d, 2
    jl .inner
    FLD xmm5, 1.5
    movss xmm3, [rsp+12]
.inner:
    movss [rsp+28], xmm5
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    movss xmm2, [rsp+8]
    call glColor4f
    cvtsi2ss xmm6, dword [scr_w]
    mulss xmm6, [c_half]
    cvtsi2ss xmm7, dword [scr_h]
    mulss xmm7, [c_half]
    movss xmm0, [rsp+20]
    mulss xmm0, [rsp+28]
    mulss xmm0, xmm6
    addss xmm0, xmm6
    movss xmm1, [rsp+24]
    mulss xmm1, [rsp+28]
    mulss xmm1, xmm7
    addss xmm1, xmm7
    call glVertex2f
    inc r12d
    jmp .v
.nseg:
    inc ebx
    jmp .seg
.done:
    call glEnd
    EPILOGUE

; diamond(xmm0=cx, xmm1=cy, edi=filled?) -- a capture indicator
diamond:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    mov ebx, edi
    mov edi, GL_TEXTURE_2D
    mov esi, [white_tex]
    call glBindTexture
    FLD xmm0, 0.2
    FLD xmm1, 0.2
    FLD xmm2, 0.2
    movss xmm3, [c_one]
    test ebx, ebx
    jz .col
    FLD xmm0, 0.31
    FLD xmm1, 0.82
    FLD xmm2, 1.0
.col:
    call glColor4f
    mov edi, GL_QUADS
    call glBegin
    FLD xmm2, 9.0
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    subss xmm1, xmm2
    call glVertex2f
    FLD xmm2, 9.0
    movss xmm0, [rsp+0]
    addss xmm0, xmm2
    movss xmm1, [rsp+4]
    call glVertex2f
    FLD xmm2, 9.0
    movss xmm0, [rsp+0]
    movss xmm1, [rsp+4]
    addss xmm1, xmm2
    call glVertex2f
    FLD xmm2, 9.0
    movss xmm0, [rsp+0]
    subss xmm0, xmm2
    movss xmm1, [rsp+4]
    call glVertex2f
    call glEnd
    EPILOGUE

; map_mark(xmm0=world x, xmm1=world z, xmm2..4=rgb, xmm5=size px) -- a
; square marker on the open map. Uses the map layout at [map_s], [map_ox], [map_oy].
map_mark:
    PROLOGUE 32
    movss [rsp+16], xmm5
    mulss xmm0, [c_inv_cell]
    mulss xmm0, [map_s]
    addss xmm0, [map_ox]
    mulss xmm1, [c_inv_cell]
    mulss xmm1, [map_s]
    addss xmm1, [map_oy]
    movss xmm7, xmm5
    mulss xmm7, [c_half]
    subss xmm0, xmm7
    subss xmm1, xmm7
    movaps xmm6, xmm4
    movaps xmm5, xmm3
    movaps xmm4, xmm2
    movss xmm2, [rsp+16]
    movss xmm3, [rsp+16]
    movss xmm7, [c_one]
    call draw_rect
    EPILOGUE

; draw_compass_marks -- what Zelda's compass shows: the treasure (captures,
; deauths, the other items), B, and the boss -- T -- on the floor being viewed
draw_compass_marks:
    PROLOGUE 32
    xor ebx, ebx
.it:
    cmp ebx, [item_count]
    jge .items_done
    imul eax, ebx, ITEM_SIZE
    lea r12, [items+rax]
    cmp dword [r12+ITEM_ACTIVE], 0
    je .n
    mov eax, [r12+ITEM_KIND]
    cmp eax, IT_TYLER
    jge .n
    mov eax, [r12+ITEM_F]
    cmp eax, [map_floor]
    jne .n
    mov eax, [r12+ITEM_KIND]
    lea rax, [rax*3]
    movss xmm2, [mark_col+rax*4]
    movss xmm3, [mark_col+rax*4+4]
    movss xmm4, [mark_col+rax*4+8]
    movss xmm0, [r12+ITEM_X]
    movss xmm1, [r12+ITEM_Z]
    FLD xmm5, 7.0
    call map_mark
.n:
    inc ebx
    jmp .it
.items_done:
    ; B
    mov eax, [b_floor]
    cmp eax, [map_floor]
    jne .no_b
    movss xmm0, [b_pos_x]
    movss xmm1, [b_pos_z]
    FLD xmm2, 0.37
    FLD xmm3, 0.85
    FLD xmm4, 1.0
    FLD xmm5, 9.0
    call map_mark
.no_b:
    ; T: a pulsing red block
    movss xmm0, [t_y]
    call floor_of_height
    cmp eax, [map_floor]
    jne .done
    movss xmm0, [hud_time]
    FLD xmm1, 8.0
    mulss xmm0, xmm1
    call sinf
    FLD xmm1, 3.0
    mulss xmm0, xmm1
    FLD xmm5, 10.0
    addss xmm5, xmm0
    movss xmm0, [t_x]
    movss xmm1, [t_z]
    FLD xmm2, 1.0
    FLD xmm3, 0.1
    FLD xmm4, 0.1
    call map_mark
.done:
    ; the bottom feeders: little purple dots
    xor ebx, ebx
.fd:
    cmp ebx, [fd_count]
    jge .fd_done
    movss xmm0, [fd_y+rbx*4]
    call floor_of_height
    cmp eax, [map_floor]
    jne .fd_n
    movss xmm0, [fd_x+rbx*4]
    movss xmm1, [fd_z+rbx*4]
    FLD xmm2, 0.75
    FLD xmm3, 0.35
    FLD xmm4, 1.0
    FLD xmm5, 6.0
    call map_mark
.fd_n:
    inc ebx
    jmp .fd
.fd_done:
    EPILOGUE

; draw_heading_strip -- a Skyrim-style compass bar at the top of the screen:
; N/E/S/W slide past as you turn; a cyan tick points at the nearest capture
draw_heading_strip:
    PROLOGUE 48
    cvtsi2ss xmm0, dword [scr_w]
    mulss xmm0, [c_half]
    movss [rsp+0], xmm0                 ; centre x
    ; backdrop
    FLD xmm1, 180.0
    subss xmm0, xmm1
    FLD xmm1, 8.0
    FLD xmm2, 360.0
    FLD xmm3, 26.0
    xorps xmm4, xmm4
    xorps xmm5, xmm5
    xorps xmm6, xmm6
    FLD xmm7, 0.45
    call draw_rect
    ; centre notch
    movss xmm0, [rsp+0]
    FLD xmm1, 1.0
    subss xmm0, xmm1
    FLD xmm1, 30.0
    FLD xmm2, 2.0
    FLD xmm3, 6.0
    movss xmm4, [c_one]
    movss xmm5, [c_one]
    movss xmm6, [c_one]
    FLD xmm7, 0.8
    call draw_rect
    ; heading: bearing clockwise from north = -yaw
    movss xmm0, [p_yaw]
    xorps xmm0, [c_sign_mask]
    movss [rsp+4], xmm0
    xor ebx, ebx
.letter:
    cmp ebx, 4
    jge .letters_done
    cvtsi2ss xmm0, ebx
    FLD xmm1, 1.5707963
    mulss xmm0, xmm1                    ; letter bearing
    subss xmm0, [rsp+4]
    call wrap_pi
    ; visible within +/- 90 degrees; 180 px per 90 degrees
    movaps xmm1, xmm0
    andps xmm1, [c_abs_mask]
    FLD xmm2, 1.5707963
    comiss xmm1, xmm2
    jae .nl
    FLD xmm1, 114.59                    ; 180 / (pi/2)
    mulss xmm0, xmm1
    addss xmm0, [rsp+0]
    cvtsi2ss xmm1, dword [dir_w+rbx*4]
    mulss xmm1, [c_half]
    subss xmm0, xmm1
    FLD xmm1, 10.0
    mov edi, [dir_tex+rbx*4]
    mov esi, [dir_w+rbx*4]
    mov edx, [dir_h+rbx*4]
    movss xmm2, [c_one]
    call draw_text
.nl:
    inc ebx
    jmp .letter
.letters_done:
    ; nearest capture still out there (any floor): a cyan tick
    mov r13d, -1
    movss xmm7, [c_big]
    movss [rsp+8], xmm7
    xor ebx, ebx
.cap:
    cmp ebx, [item_count]
    jge .cap_done
    imul eax, ebx, ITEM_SIZE
    lea r12, [items+rax]
    cmp dword [r12+ITEM_ACTIVE], 0
    je .ncap
    cmp dword [r12+ITEM_KIND], IT_KEY
    jne .ncap
    movss xmm0, [r12+ITEM_X]
    subss xmm0, [p_x]
    mulss xmm0, xmm0
    movss xmm1, [r12+ITEM_Z]
    subss xmm1, [p_z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    comiss xmm0, [rsp+8]
    jae .ncap
    movss [rsp+8], xmm0
    mov r13d, ebx
.ncap:
    inc ebx
    jmp .cap
.cap_done:
    cmp r13d, 0
    jl .done
    imul eax, r13d, ITEM_SIZE
    lea r12, [items+rax]
    ; bearing of the capture: atan2(dx, -dz) clockwise from north
    movss xmm0, [r12+ITEM_X]
    subss xmm0, [p_x]
    movss xmm1, [p_z]
    subss xmm1, [r12+ITEM_Z]
    call atan2f
    subss xmm0, [rsp+4]
    call wrap_pi
    movaps xmm1, xmm0
    andps xmm1, [c_abs_mask]
    FLD xmm2, 1.5707963
    comiss xmm1, xmm2
    jb .on_strip
    ; behind you: pin it to the nearer end of the strip
    FLD xmm1, 1.55
    comiss xmm0, [c_zero]
    ja .pin
    xorps xmm1, [c_sign_mask]
.pin:
    movaps xmm0, xmm1
.on_strip:
    FLD xmm1, 114.59
    mulss xmm0, xmm1
    addss xmm0, [rsp+0]
    FLD xmm1, 3.0
    subss xmm0, xmm1
    FLD xmm1, 26.0
    FLD xmm2, 6.0
    FLD xmm3, 7.0
    FLD xmm4, 0.3
    FLD xmm5, 0.8
    movss xmm6, [c_one]
    movss xmm7, [c_one]
    call draw_rect
.done:
    EPILOGUE

; wrap_pi(xmm0) -> xmm0 in (-pi, pi]. leaf-ish (no calls)
wrap_pi:
.lo:
    comiss xmm0, [c_neg_pi]
    ja .hi
    addss xmm0, [c_two_pi]
    jmp .lo
.hi:
    comiss xmm0, [c_pi]
    jbe .ok
    subss xmm0, [c_two_pi]
    jmp .hi
.ok:
    ret

; draw_noise_meter -- green -> yellow -> red bar with a tick where T, at his
; current distance, would start to hear you
draw_noise_meter:
    PROLOGUE 32
    cvtsi2ss xmm0, dword [scr_h]
    FLD xmm1, 140.0
    subss xmm0, xmm1
    movss [rsp+0], xmm0                 ; label y
    mov edi, [misc_tex+24]
    mov esi, [misc_w+24]
    mov edx, [misc_h+24]
    movaps xmm1, xmm0
    FLD xmm0, 18.0
    movss xmm2, [c_one]
    call draw_text
    ; colour by level
    movss xmm5, [noise_level]
    movss xmm6, xmm5
    addss xmm6, xmm6                    ; t = 2n
    comiss xmm5, [c_half]
    jae .hot
    ; 0..0.5: green (0.4,0.9,0.4) -> yellow (1.0,0.85,0.3)
    FLD xmm2, 0.4
    FLD xmm7, 0.6
    mulss xmm7, xmm6
    addss xmm2, xmm7
    FLD xmm3, 0.9
    FLD xmm7, 0.05
    mulss xmm7, xmm6
    subss xmm3, xmm7
    FLD xmm4, 0.4
    FLD xmm7, 0.1
    mulss xmm7, xmm6
    subss xmm4, xmm7
    jmp .bar
.hot:
    ; 0.5..1: yellow -> red (1.0,0.25,0.2)
    subss xmm6, [c_one]                 ; t = 2n - 1
    movss xmm2, [c_one]
    FLD xmm3, 0.85
    FLD xmm7, 0.6
    mulss xmm7, xmm6
    subss xmm3, xmm7
    FLD xmm4, 0.3
    FLD xmm7, 0.1
    mulss xmm7, xmm6
    subss xmm4, xmm7
.bar:
    movss xmm0, [rsp+0]
    FLD xmm1, 20.0
    addss xmm0, xmm1
    movss [rsp+4], xmm0                 ; bar y
    movaps xmm1, xmm5
    call bar
    ; tick: meter level at which T hears you (distance + walls and floors between)
    movss xmm0, [t_hear_d]
    divss xmm0, [noise_range]
    comiss xmm0, [c_one]
    jae .done
    FLD xmm1, 200.0
    mulss xmm0, xmm1
    FLD xmm1, 17.0
    addss xmm0, xmm1                    ; x = 18 + 200*frac - 1
    movss xmm1, [rsp+4]
    FLD xmm2, 3.0
    subss xmm1, xmm2
    FLD xmm2, 2.0
    FLD xmm3, 11.0
    movss xmm4, [c_one]
    movss xmm5, [c_one]
    movss xmm6, [c_one]
    movss xmm7, [c_one]
    call draw_rect
.done:
    EPILOGUE

; bar(xmm0=y, xmm1=fraction, xmm2..4 = rgb) -- stamina / flashlight bar
bar:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    movss [rsp+16], xmm4
    FLD xmm0, 18.0
    movss xmm1, [rsp+0]
    FLD xmm2, 200.0
    FLD xmm3, 5.0
    FLD xmm4, 1.0
    FLD xmm5, 1.0
    FLD xmm6, 1.0
    FLD xmm7, 0.12
    call draw_rect
    FLD xmm0, 18.0
    movss xmm1, [rsp+0]
    FLD xmm2, 200.0
    mulss xmm2, [rsp+4]
    FLD xmm3, 5.0
    movss xmm4, [rsp+8]
    movss xmm5, [rsp+12]
    movss xmm6, [rsp+16]
    movss xmm7, [c_one]
    call draw_rect
    EPILOGUE

; draw_map -- explored cells of the current storey, player arrow
draw_map:
    PROLOGUE 64
    ; cell size in pixels
    cvtsi2ss xmm0, dword [scr_w]
    FLD xmm1, 0.5
    mulss xmm0, xmm1
    FLD xmm1, 59.0
    divss xmm0, xmm1
    FLD xmm1, 10.0
    minss xmm0, xmm1
    movss [rsp+0], xmm0                 ; s
    ; origin: top-right corner, 16px margin, 50px from the top
    FLD xmm1, 59.0
    mulss xmm1, xmm0
    cvtsi2ss xmm2, dword [scr_w]
    subss xmm2, xmm1
    FLD xmm3, 16.0
    subss xmm2, xmm3
    movss [rsp+4], xmm2                 ; ox
    FLD xmm3, 84.0                      ; below the compass strip
    movss [rsp+8], xmm3                 ; oy
    movss xmm0, [rsp+0]
    movss [map_s], xmm0
    movss [map_ox], xmm2
    movss [map_oy], xmm3
    ; backdrop
    movss xmm0, [rsp+4]
    FLD xmm6, 8.0
    subss xmm0, xmm6
    movss xmm1, [rsp+8]
    subss xmm1, xmm6
    FLD xmm2, 59.0
    mulss xmm2, [rsp+0]
    FLD xmm6, 16.0
    addss xmm2, xmm6
    FLD xmm3, 31.0
    mulss xmm3, [rsp+0]
    addss xmm3, xmm6
    xorps xmm4, xmm4
    xorps xmm5, xmm5
    xorps xmm6, xmm6
    FLD xmm7, 0.85
    call draw_rect
    ; title: the floor's name, and either "explored map" or the MAP hint
    mov r12d, [map_floor]
    mov edi, [floor_tex+r12*4]
    mov esi, [floor_w+r12*4]
    mov edx, [floor_h+r12*4]
    movss xmm0, [rsp+4]
    movss xmm1, [rsp+8]
    FLD xmm2, 30.0
    subss xmm1, xmm2
    movss xmm2, [c_one]
    call draw_text
    mov edi, [misc_tex+20]
    mov esi, [misc_w+20]
    mov edx, [misc_h+20]
    cmp dword [have_map], 0
    je .title2
    mov edi, [misc_tex+28]
    mov esi, [misc_w+28]
    mov edx, [misc_h+28]
.title2:
    movss xmm0, [rsp+4]
    FLD xmm1, 190.0
    addss xmm0, xmm1
    movss xmm1, [rsp+8]
    FLD xmm2, 27.0
    subss xmm1, xmm2
    movss xmm2, [c_one]
    call draw_text
    xor r14d, r14d
.y:
    cmp r14d, MAP_H
    jge .cells_done
    xor r13d, r13d
.x:
    cmp r13d, MAP_W
    jge .ny
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call cell_index
    movzx r15d, byte [explored+rax]     ; 1 = seen with your own eyes
    test r15d, r15d
    jnz .seen
    cmp dword [have_map], 0             ; the MAP shows the rest, dimmed
    je .nx
.seen:
    movzx ebx, byte [grid+rax]
    ; colour by type
    FLD xmm4, 0.14
    FLD xmm5, 0.13
    FLD xmm6, 0.12
    test byte [char_class+rbx], CF_WALL
    jz .c1
    FLD xmm4, 0.35
    FLD xmm5, 0.34
    FLD xmm6, 0.31
    cmp ebx, 'N'
    jne .c1
    FLD xmm4, 0.12
    FLD xmm5, 0.42
    FLD xmm6, 0.6
.c1:
    cmp ebx, 'S'
    jne .c2
    FLD xmm4, 0.07
    FLD xmm5, 0.23
    FLD xmm6, 0.33
.c2:
    test byte [char_class+rbx], CF_STAIR
    jz .c3
    FLD xmm4, 0.79
    FLD xmm5, 0.7
    FLD xmm6, 0.48
.c3:
    cmp ebx, '.'
    jne .c4
    FLD xmm4, 0.05
    FLD xmm5, 0.05
    FLD xmm6, 0.05
.c4:
    cmp ebx, 'B'
    jne .c5
    FLD xmm4, 0.37
    FLD xmm5, 0.85
    FLD xmm6, 1.0
.c5:
    test r15d, r15d
    jnz .bright
    FLD xmm7, 0.45                      ; not explored yet: Zelda-grey
    mulss xmm4, xmm7
    mulss xmm5, xmm7
    mulss xmm6, xmm7
.bright:
    cvtsi2ss xmm0, r13d
    mulss xmm0, [rsp+0]
    addss xmm0, [rsp+4]
    cvtsi2ss xmm1, r14d
    mulss xmm1, [rsp+0]
    addss xmm1, [rsp+8]
    movss xmm2, [rsp+0]
    movss xmm3, [rsp+0]
    movss xmm7, [c_one]
    call draw_rect
.nx:
    inc r13d
    jmp .x
.ny:
    inc r14d
    jmp .y
.cells_done:
    cmp dword [have_compass], 0
    je .no_compass
    call draw_compass_marks
.no_compass:
    ; player: a red arrow pointing along the view direction (your floor only)
    call player_floor
    cmp eax, [map_floor]
    jne .done
    movss xmm0, [p_x]
    mulss xmm0, [c_inv_cell]
    mulss xmm0, [rsp+0]
    addss xmm0, [rsp+4]
    movss [rsp+12], xmm0
    movss xmm0, [p_z]
    mulss xmm0, [c_inv_cell]
    mulss xmm0, [rsp+0]
    addss xmm0, [rsp+8]
    movss [rsp+16], xmm0
    movss xmm0, [p_yaw]
    call sinf
    movss [rsp+20], xmm0
    movss xmm0, [p_yaw]
    call cosf
    movss [rsp+24], xmm0
    mov edi, GL_TEXTURE_2D
    mov esi, [white_tex]
    call glBindTexture
    FLD xmm0, 1.0
    FLD xmm1, 0.23
    FLD xmm2, 0.23
    movss xmm3, [c_one]
    call glColor4f
    mov edi, GL_TRIANGLES
    call glBegin
    ; tip = pos + fwd*9 ; fwd = (-sin yaw, -cos yaw) on the map
    FLD xmm2, 9.0
    movss xmm0, [rsp+20]
    mulss xmm0, xmm2
    movss xmm1, [rsp+12]
    subss xmm1, xmm0
    movaps xmm0, xmm1
    movss xmm1, [rsp+24]
    mulss xmm1, xmm2
    movss xmm3, [rsp+16]
    subss xmm3, xmm1
    movaps xmm1, xmm3
    call glVertex2f
    ; two back corners: pos -/+ right*5 + back*4 ; right = (cos, -sin)
    FLD xmm2, 5.0
    FLD xmm3, 4.0
    movss xmm0, [rsp+24]
    mulss xmm0, xmm2
    movss xmm4, [rsp+20]
    mulss xmm4, xmm3
    addss xmm0, xmm4
    addss xmm0, [rsp+12]
    movss xmm1, [rsp+20]
    mulss xmm1, xmm2
    xorps xmm1, [c_sign_mask]
    movss xmm4, [rsp+24]
    mulss xmm4, xmm3
    addss xmm1, xmm4
    addss xmm1, [rsp+16]
    call glVertex2f
    FLD xmm2, 5.0
    FLD xmm3, 4.0
    movss xmm0, [rsp+24]
    mulss xmm0, xmm2
    xorps xmm0, [c_sign_mask]
    movss xmm4, [rsp+20]
    mulss xmm4, xmm3
    addss xmm0, xmm4
    addss xmm0, [rsp+12]
    movss xmm1, [rsp+20]
    mulss xmm1, xmm2
    movss xmm4, [rsp+24]
    mulss xmm4, xmm3
    addss xmm1, xmm4
    addss xmm1, [rsp+16]
    call glVertex2f
    call glEnd
.done:
    EPILOGUE

; -----------------------------------------------------------------------------
; hud_draw(edi=w, esi=h, xmm0=dt, xmm1=time)
; -----------------------------------------------------------------------------
hud_draw:
    PROLOGUE 64
    mov [scr_w], edi
    mov [scr_h], esi
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [hud_time], xmm1
    ; 2D pixel projection
    mov edi, GL_PROJECTION
    call glMatrixMode
    call glLoadIdentity
    xorps xmm0, xmm0
    cvtsi2sd xmm1, dword [scr_w]
    cvtsi2sd xmm2, dword [scr_h]
    xorps xmm3, xmm3
    mov rax, __float64__(-1.0)
    movq xmm4, rax
    mov rax, __float64__(1.0)
    movq xmm5, rax
    call glOrtho
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

    ; ---- full-screen effects
    ; film grain: the noise texture at a random offset each frame
    mov edi, GL_TEXTURE_2D
    mov esi, [grain_tex]
    call glBindTexture
    movss xmm0, [c_one]
    movss xmm1, [c_one]
    movss xmm2, [c_one]
    movss xmm3, [c_grain_a]
    PCT xmm4, cfg_grain                 ; film grain setting
    mulss xmm3, xmm4
    call glColor4f
    call rand01
    movss [rsp+8], xmm0
    call rand01
    movss [rsp+12], xmm0
    mov edi, GL_QUADS
    call glBegin
    xor ebx, ebx
.gv:
    cmp ebx, 4
    jge .gv_done
    ; corners 0:(0,0) 1:(w,0) 2:(w,h) 3:(0,h); uv = pos/128 + offset
    xorps xmm6, xmm6
    xorps xmm7, xmm7
    cmp ebx, 1
    je .gx
    cmp ebx, 2
    jne .gnx
.gx:
    cvtsi2ss xmm6, dword [scr_w]
.gnx:
    cmp ebx, 2
    jl .gny
    cvtsi2ss xmm7, dword [scr_h]
.gny:
    movss [rsp+16], xmm6
    movss [rsp+20], xmm7
    FLD xmm2, 128.0
    movaps xmm0, xmm6
    divss xmm0, xmm2
    addss xmm0, [rsp+8]
    movaps xmm1, xmm7
    divss xmm1, xmm2
    addss xmm1, [rsp+12]
    call glTexCoord2f
    movss xmm0, [rsp+16]
    movss xmm1, [rsp+20]
    call glVertex2f
    inc ebx
    jmp .gv
.gv_done:
    call glEnd

    ; red danger vignette (pulses at the highest band)
    movss xmm3, [hud_vignette]
    comiss xmm3, [c_zero]
    jbe .no_vig
    FLD xmm0, 0.47
    xorps xmm1, xmm1
    xorps xmm2, xmm2
    call vignette
.no_vig:
    movss xmm3, [hud_safe_tint]
    comiss xmm3, [c_zero]
    jbe .no_safe
    FLD xmm0, 0.12
    FLD xmm1, 0.47
    FLD xmm2, 0.78
    FLD xmm6, 0.5
    mulss xmm3, xmm6
    call vignette
.no_safe:
    ; deauth flash
    movss xmm7, [hud_flash]
    comiss xmm7, [c_zero]
    jbe .no_flash
    FLD xmm6, 0.7
    mulss xmm7, xmm6
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    cvtsi2ss xmm2, dword [scr_w]
    cvtsi2ss xmm3, dword [scr_h]
    FLD xmm4, 0.6
    FLD xmm5, 1.0
    FLD xmm6, 0.93
    call draw_rect
.no_flash:

    ; ---- top bar: floor name (left), captures (right)
    call player_floor
    mov ebx, eax
    mov edi, [floor_tex+rbx*4]
    mov esi, [floor_w+rbx*4]
    mov edx, [floor_h+rbx*4]
    FLD xmm0, 18.0
    FLD xmm1, 12.0
    movss xmm2, [c_one]
    call draw_text
    ; F3 frames-per-second readout (texture rebuilt only when the number changes)
    mov eax, [hud_fps]
    cmp eax, 0
    jl .no_fps
    cmp eax, [fps_shown]
    je .draw_fps
    mov [fps_shown], eax
    cmp dword [fps_tex], 0
    je .fps_new
    lea rsi, [fps_tex]
    mov edi, 1
    call glDeleteTextures
.fps_new:
    lea rdi, [fmt_buf]
    mov esi, 64
    lea rdx, [s_fps_fmt]
    mov ecx, [fps_shown]
    xor eax, eax
    call snprintf
    mov rdi, [font_small]
    lea rsi, [fmt_buf]
    mov edx, RGBC(255,230,120)
    call mk
    mov [fps_tex], eax
    mov [fps_w], ecx
    mov [fps_h], r8d
.draw_fps:
    mov edi, [fps_tex]
    mov esi, [fps_w]
    mov edx, [fps_h]
    FLD xmm0, 18.0
    FLD xmm1, 36.0
    movss xmm2, [c_one]
    call draw_text
.no_fps:
    xor ebx, ebx
.cap:
    cmp ebx, 3
    jge .cap_done
    cvtsi2ss xmm0, dword [scr_w]
    mov eax, 3
    sub eax, ebx
    imul eax, 26
    cvtsi2ss xmm1, eax
    subss xmm0, xmm1
    FLD xmm1, 24.0
    xor edi, edi
    cmp ebx, [inventory]
    jge .empty
    mov edi, 1
.empty:
    call diamond
    inc ebx
    jmp .cap
.cap_done:

    cmp dword [have_compass], 0
    je .no_strip
    call draw_heading_strip
.no_strip:

    ; ---- HE SEES YOU
    cmp dword [t_state], T_CHASE
    jne .no_sees
    cmp dword [t_sees], 0
    je .no_sees
    movss xmm0, [rsp+4]
    mulss xmm0, [c_pulse]
    call sinf
    FLD xmm1, 0.3
    mulss xmm0, xmm1
    FLD xmm1, 0.7
    addss xmm0, xmm1
    movaps xmm2, xmm0
    mov edi, [misc_tex+8]
    mov esi, [misc_w+8]
    mov edx, [misc_h+8]
    cvtsi2ss xmm0, dword [scr_w]
    cvtsi2ss xmm1, esi
    subss xmm0, xmm1
    mulss xmm0, [c_half]
    FLD xmm1, 48.0
    call draw_text
.no_sees:

    ; ---- crosshair
    cvtsi2ss xmm0, dword [scr_w]
    mulss xmm0, [c_half]
    FLD xmm6, 2.0
    subss xmm0, xmm6
    cvtsi2ss xmm1, dword [scr_h]
    mulss xmm1, [c_half]
    subss xmm1, xmm6
    FLD xmm2, 4.0
    FLD xmm3, 4.0
    movss xmm4, [c_one]
    movss xmm5, [c_one]
    movss xmm6, [c_one]
    FLD xmm7, 0.5
    call draw_rect

    ; ---- interaction prompt
    mov ebx, [hud_prompt]
    cmp ebx, 0
    jl .no_prompt
    cvtsi2ss xmm0, dword [scr_w]
    cvtsi2ss xmm1, dword [prompt_w+rbx*4]
    subss xmm0, xmm1
    mulss xmm0, [c_half]
    movss [rsp+8], xmm0
    cvtsi2ss xmm1, dword [scr_h]
    FLD xmm2, 0.58
    mulss xmm1, xmm2
    movss [rsp+12], xmm1
    FLD xmm6, 12.0
    subss xmm0, xmm6
    FLD xmm6, 6.0
    subss xmm1, xmm6
    cvtsi2ss xmm2, dword [prompt_w+rbx*4]
    FLD xmm6, 24.0
    addss xmm2, xmm6
    cvtsi2ss xmm3, dword [prompt_h+rbx*4]
    FLD xmm6, 12.0
    addss xmm3, xmm6
    xorps xmm4, xmm4
    xorps xmm5, xmm5
    xorps xmm6, xmm6
    FLD xmm7, 0.6
    call draw_rect
    mov edi, [prompt_tex+rbx*4]
    mov esi, [prompt_w+rbx*4]
    mov edx, [prompt_h+rbx*4]
    movss xmm0, [rsp+8]
    movss xmm1, [rsp+12]
    movss xmm2, [c_one]
    call draw_text
.no_prompt:

    ; ---- noise meter (above the rest of the bottom-left block)
    call draw_noise_meter

    ; ---- bottom-left: deauth count, stamina, flashlight
    cvtsi2ss xmm0, dword [scr_h]
    FLD xmm1, 96.0
    subss xmm0, xmm1
    movss [rsp+8], xmm0                 ; y of the block
    ; what you're holding (deauths show how many)
    mov eax, [special]
    mov edi, [item_tex+rax*4]
    mov esi, [item_w+rax*4]
    mov edx, [item_h+rax*4]
    cmp eax, SP_DEAUTH
    jne .item_ok
    mov ebx, [deauths]
    cmp ebx, 9
    jle .dok
    mov ebx, 9
.dok:
    mov edi, [deauth_tex+rbx*4]
    mov esi, [deauth_w+rbx*4]
    mov edx, [deauth_h+rbx*4]
.item_ok:
    FLD xmm0, 18.0
    movss xmm1, [rsp+8]
    movss xmm2, [c_one]
    call draw_text
    mov edi, [misc_tex+0]
    mov esi, [misc_w+0]
    mov edx, [misc_h+0]
    movss xmm0, [p_dew]
    comiss xmm0, [c_zero]
    jbe .stam_label
    mov edi, [misc_tex+32]
    mov esi, [misc_w+32]
    mov edx, [misc_h+32]
.stam_label:
    FLD xmm0, 18.0
    movss xmm1, [rsp+8]
    FLD xmm2, 22.0
    addss xmm1, xmm2
    movss xmm2, [c_one]
    call draw_text
    movss xmm0, [rsp+8]
    FLD xmm1, 42.0
    addss xmm0, xmm1
    movss xmm1, [p_stamina]
    FLD xmm2, 0.87
    FLD xmm3, 0.87
    FLD xmm4, 0.87
    cmp dword [p_exhausted], 0
    je .st
    FLD xmm2, 1.0
    FLD xmm3, 0.23
    FLD xmm4, 0.23
.st:
    movss xmm5, [p_dew]                 ; on the Dew: a lime bar, running down
    comiss xmm5, [c_zero]
    jbe .st_plain
    movaps xmm1, xmm5
    FLD xmm5, 20.0
    divss xmm1, xmm5
    minss xmm1, [c_one]
    FLD xmm2, 0.6
    FLD xmm3, 1.0
    FLD xmm4, 0.2
.st_plain:
    call bar
    mov edi, [misc_tex+4]
    mov esi, [misc_w+4]
    mov edx, [misc_h+4]
    FLD xmm0, 18.0
    movss xmm1, [rsp+8]
    FLD xmm2, 52.0
    addss xmm1, xmm2
    movss xmm2, [c_one]
    call draw_text
    movss xmm0, [rsp+8]
    FLD xmm1, 72.0
    addss xmm0, xmm1
    movss xmm1, [p_battery]
    FLD xmm2, 0.94
    FLD xmm3, 0.85
    FLD xmm4, 0.56
    cmp dword [p_flash_on], 0
    jne .bt
    FLD xmm2, 0.33
    FLD xmm3, 0.33
    FLD xmm4, 0.33
.bt:
    call bar

    ; ---- message log: newest at the bottom, fading out
    cvtsi2ss xmm0, dword [scr_h]
    FLD xmm1, 24.0
    subss xmm0, xmm1
    movss [rsp+8], xmm0                 ; bottom edge of the next message
    mov ebx, [msg_count]
.msg:
    dec ebx
    js .msg_done
    ; age it
    movss xmm0, [msg_time+rbx*4]
    subss xmm0, [rsp+0]
    movss [msg_time+rbx*4], xmm0
    ; alpha = min(1, time/1.5)
    divss xmm0, [c_fade]
    minss xmm0, [c_one]
    maxss xmm0, [c_zero]
    movss [rsp+12], xmm0
    cvtsi2ss xmm1, dword [msg_h+rbx*4]
    movss xmm0, [rsp+8]
    subss xmm0, xmm1
    FLD xmm2, 10.0
    subss xmm0, xmm2
    movss [rsp+8], xmm0                 ; top of this message box
    ; box
    cvtsi2ss xmm0, dword [scr_w]
    cvtsi2ss xmm1, dword [msg_w+rbx*4]
    subss xmm0, xmm1
    mulss xmm0, [c_half]
    movss [rsp+16], xmm0
    FLD xmm6, 12.0
    subss xmm0, xmm6
    movss xmm1, [rsp+8]
    FLD xmm6, 4.0
    subss xmm1, xmm6
    cvtsi2ss xmm2, dword [msg_w+rbx*4]
    FLD xmm6, 24.0
    addss xmm2, xmm6
    cvtsi2ss xmm3, dword [msg_h+rbx*4]
    FLD xmm6, 8.0
    addss xmm3, xmm6
    xorps xmm4, xmm4
    xorps xmm5, xmm5
    xorps xmm6, xmm6
    FLD xmm7, 0.55
    mulss xmm7, [rsp+12]
    call draw_rect
    mov edi, [msg_tex+rbx*4]
    mov esi, [msg_w+rbx*4]
    mov edx, [msg_h+rbx*4]
    movss xmm0, [rsp+16]
    movss xmm1, [rsp+8]
    movss xmm2, [rsp+12]
    call draw_text
    jmp .msg
.msg_done:
    ; drop expired messages (oldest are at the front)
.expire:
    cmp dword [msg_count], 0
    je .expired
    movss xmm0, [msg_time]
    comiss xmm0, [c_zero]
    ja .expired
    xor edi, edi
    call delete_msg
    jmp .expire
.expired:

    ; ---- map
    cmp dword [map_visible], 0
    je .no_map
    call draw_map
.no_map:

    ; ---- pause screen: the settings menu (settings.asm)
    cmp dword [hud_paused], 0
    je .no_pause
    mov edi, [scr_w]
    mov esi, [scr_h]
    call menu_draw
.no_pause:
    movss xmm0, [c_one]
    movss xmm1, [c_one]
    movss xmm2, [c_one]
    movss xmm3, [c_one]
    call glColor4f
    mov edi, GL_BLEND
    call glDisable
    mov edi, GL_DEPTH_TEST
    call glEnable
    EPILOGUE
