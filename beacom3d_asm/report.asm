; =============================================================================
; report.asm -- the report card at the end of a night.
;
; While you play, report_tick keeps what the rest of the game doesn't: the
; closest T got while he could see you, the loudest you were, how far you
; walked and how long you hid in safe rooms (T's sightings, deauths and
; mantles are already counted by achievements.asm, gadget shots by
; gadget.asm). When the night ends, report_finish scores it, grades it
; (S A B C D F), compares it with your best on this kind of building
; (beacom_records.cfg) and renders the card's lines; hud_draw draws the card
; (report_draw) while main.asm's report_screen waits for a key.
;
; The score (report_score), all integers:
;   200 per capture you hold
;   + 1000 for bringing them to B
;   + 1 per second under 10 minutes (a win)
;   + 300 if T never saw you (a win)
;   - 50 per time T spotted you, - 25 per deauth fired
;   then x (100 - 15 per part in your loadout) / 100: travel light, score more
; =============================================================================
%define MODULE_REPORT
%include "common.inc"

global report_reset, report_tick, report_finish, report_draw, report_score
global report_load, rc_show, rc_score, rc_grade, rc_best, rc_closest, rc_loud
global rc_walked, rc_safe_t, rc_new_best, rc_tex

extern elapsed_time, inventory, run_spotted, run_deauths, run_moves, ach_persist
extern t_dist, t_sees, noise_level, gd_shots
extern make_text_texture, glDeleteTextures, draw_text, draw_rect
extern font_hud, font_small, font_big, tt_w, tt_h, fwrite

%define NLINES 15
%define WIN_TIME 600                    ; the speed bonus runs out at 10 minutes

section .data
file_name   db "beacom_records.cfg",0
mode_rb     db "rb",0
mode_wb     db "wb",0
rec_magic   dd 0x31434552               ; "REC1"
c_far       dd 1.0e9
c_step_max  dd 3.0                      ; a frame's walk longer than this was a teleport
c_hundred   dd 100.0
; grades: the lowest score for each
grade_min   dd 2200, 1800, 1400, 1000, 500, 0
grade_ch    db "SABCDF"
align 4
grade_col   dd 0xFF5AD7FF, 0xFF8FE38F, 0xFFE8E0C8, 0xFFE8E0C8, 0xFF47B3FF, 0xFF5050FF
col_info    dd 0xFFC8D4D8
col_dim     dd 0xFF909898
col_best    dd 0xFF5AD7FF
t_won       db "YOU GOT OUT -- Y IS FREE",0
t_lost      db "T CAUGHT YOU",0
t_secret    db "THE CHICKEN JOCKEY",0
f_grade     db "GRADE %c      SCORE %d",0
f_best      db "Best on this building: %d%s",0
s_new_best  db "   NEW BEST!",0
s_empty     db "",0
f_time      db "Time                     %dm %02ds",0
f_caps      db "Captures                 %d / 3",0
f_spotted   db "T spotted you            %d times",0
f_close     db "Closest call             %d.%d m",0
f_close_no  db "Closest call             he never saw you close",0
f_loud      db "Loudest moment           %d%% of T's hearing",0
f_deauth    db "Deauths fired            %d",0
f_shots     db "Gadget shots             %d",0
f_moves     db "Mantles and vaults       %d",0
f_walked    db "Walked                   %d m  (%d s of it in safe rooms)",0
f_load0     db "Loadout                  nothing -- full score",0
f_load1     db "Loadout                  %s%s",0
f_load2     db "  (score x%d%%)",0
s_plus      db " + ",0
lm_0        db "PORTAL module",0
lm_1        db "ROD module",0
lm_2        db "LINE module",0
lm_3        db "SMOKE module",0
lf_0        db "LASER",0
lf_1        db "ORB",0
lf_2        db "HOOK",0
lf_3        db "GRABBER",0
align 8
lm_names    dq s_empty, lm_0, lm_1, lm_2, lm_3
lf_names    dq s_empty, lf_0, lf_1, lf_2, lf_3
s_continue  db "ENTER / SPACE / click: continue",0

section .bss
alignb 4
rc_show     resd 1                      ; 1: hud_draw draws the card
rc_closest  resd 1                      ; float: nearest T got while seeing you
rc_loud     resd 1                      ; float: the noise meter's peak (0..1)
rc_walked   resd 1                      ; float metres
rc_safe_t   resd 1                      ; float seconds in safe rooms
rc_last_x   resd 1
rc_last_z   resd 1
rc_score    resd 1
rc_grade    resd 1                      ; 0 = S .. 5 = F
rc_best     resd 4                      ; per cfg_building
rc_new_best resd 1
rc_parts    resd 5                      ; the score's terms (captures, win, speed, unseen, penalties)
rc_tex      resd NLINES
rc_w        resd NLINES
rc_h        resd NLINES
rc_col      resd NLINES
rc_buf      resb 256

section .text

; report_reset -- a new night (new_game)
report_reset:
    mov eax, [c_far]
    mov [rc_closest], eax
    xor eax, eax
    mov [rc_loud], eax
    mov [rc_walked], eax
    mov [rc_safe_t], eax
    mov [rc_show], eax
    mov eax, [p_x]
    mov [rc_last_x], eax
    mov eax, [p_z]
    mov [rc_last_z], eax
    ret

; report_tick(xmm0 = dt) -- every frame of play (game_tick)
report_tick:
    PROLOGUE 16
    movss [rsp+0], xmm0
    ; the closest call: T's distance while he can see you
    cmp dword [t_sees], 0
    je .loud
    movss xmm0, [t_dist]
    minss xmm0, [rc_closest]
    movss [rc_closest], xmm0
.loud:
    movss xmm0, [noise_level]
    maxss xmm0, [rc_loud]
    movss [rc_loud], xmm0
    ; walked (flat; a jump of more than c_step_max in one frame is a portal
    ; or a respawn, not walking)
    movss xmm0, [p_x]
    subss xmm0, [rc_last_x]
    mulss xmm0, xmm0
    movss xmm1, [p_z]
    subss xmm1, [rc_last_z]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    comiss xmm0, [c_step_max]
    ja .moved
    addss xmm0, [rc_walked]
    movss [rc_walked], xmm0
.moved:
    mov eax, [p_x]
    mov [rc_last_x], eax
    mov eax, [p_z]
    mov [rc_last_z], eax
    call player_in_safe
    test eax, eax
    jz .done
    movss xmm0, [rc_safe_t]
    addss xmm0, [rsp+0]
    movss [rc_safe_t], xmm0
.done:
    EPILOGUE

; report_score(edi = GS_WON / GS_LOST / GS_SECRET) -> eax = the score;
; rc_score, rc_grade and rc_parts[] set. No side effects beyond those.
report_score:
    PROLOGUE 16
    mov r12d, edi
    ; captures
    mov eax, [inventory]
    imul eax, eax, 200
    mov [rc_parts+0], eax
    xor eax, eax
    mov [rc_parts+4], eax
    mov [rc_parts+8], eax
    mov [rc_parts+12], eax
    cmp r12d, GS_WON
    jne .pen
    mov dword [rc_parts+4], 1000
    cvttss2si eax, [elapsed_time]
    mov ecx, WIN_TIME
    sub ecx, eax
    xor eax, eax
    test ecx, ecx
    cmovs ecx, eax
    mov [rc_parts+8], ecx
    cmp dword [run_spotted], 0
    jne .pen
    mov dword [rc_parts+12], 300
.pen:
    mov eax, [run_spotted]
    imul eax, eax, 50
    mov ecx, [run_deauths]
    imul ecx, ecx, 25
    add eax, ecx
    neg eax
    mov [rc_parts+16], eax
    mov eax, [rc_parts+0]
    add eax, [rc_parts+4]
    add eax, [rc_parts+8]
    add eax, [rc_parts+12]
    add eax, [rc_parts+16]
    xor ecx, ecx
    test eax, eax
    cmovs eax, ecx
    ; the loadout
    call loadout_pct
    imul eax, ecx
    xor edx, edx
    mov ecx, 100
    div ecx
    mov [rc_score], eax
    ; the grade
    xor ecx, ecx
.g:
    cmp eax, [grade_min+rcx*4]
    jge .graded
    inc ecx
    cmp ecx, 5
    jl .g
.graded:
    mov [rc_grade], ecx
    mov eax, [rc_score]
    EPILOGUE

; loadout_pct -> ecx = 100 - 15 per part you brought, edx = parts (eax kept)
loadout_pct:
    xor edx, edx
    cmp dword [cfg_bring_mod], 0
    je .f
    inc edx
.f:
    cmp dword [cfg_bring_fire], 0
    je .n
    inc edx
.n:
    imul ecx, edx, -15
    add ecx, 100
    ret

; report_load -- your best scores (start-up, not in the test modes)
report_load:
    PROLOGUE 32
    lea rdi, [file_name]
    lea rsi, [mode_rb]
    call fopen
    test rax, rax
    jz .done
    mov rbx, rax
    lea rdi, [rsp+0]                    ; magic + 4 bests
    mov esi, 4
    mov edx, 5
    mov rcx, rbx
    call fread
    mov r12, rax
    mov rdi, rbx
    call fclose
    cmp r12, 5
    jne .done
    mov eax, [rsp+0]
    cmp eax, [rec_magic]
    jne .done
    xor ecx, ecx
.c:
    mov eax, [rsp+4+rcx*4]
    mov [rc_best+rcx*4], eax
    inc ecx
    cmp ecx, 4
    jl .c
.done:
    EPILOGUE

; save_records -- (only when ach_persist: never from a test run)
save_records:
    PROLOGUE 32
    cmp dword [ach_persist], 0
    je .done
    lea rdi, [file_name]
    lea rsi, [mode_wb]
    call fopen
    test rax, rax
    jz .done
    mov rbx, rax
    mov eax, [rec_magic]
    mov [rsp+0], eax
    xor ecx, ecx
.c:
    mov eax, [rc_best+rcx*4]
    mov [rsp+4+rcx*4], eax
    inc ecx
    cmp ecx, 4
    jl .c
    lea rdi, [rsp+0]
    mov esi, 4
    mov edx, 5
    mov rcx, rbx
    call fwrite
    mov rdi, rbx
    call fclose
.done:
    EPILOGUE

; line(ebx = line, rdi = font, edx = colour) -- rc_buf becomes that line's
; texture (the old one goes)
line:
    PROLOGUE 16
    mov r12, rdi
    mov r13d, edx
    mov [rc_col+rbx*4], edx
    cmp dword [rc_tex+rbx*4], 0
    je .fresh
    mov edi, 1
    lea rsi, [rc_tex+rbx*4]
    call glDeleteTextures
    mov dword [rc_tex+rbx*4], 0
.fresh:
    mov rdi, r12
    lea rsi, [rc_buf]
    mov edx, r13d
    xor ecx, ecx
    call make_text_texture
    mov [rc_tex+rbx*4], eax
    mov eax, [tt_w]
    mov [rc_w+rbx*4], eax
    mov eax, [tt_h]
    mov [rc_h+rbx*4], eax
    EPILOGUE

; fmt1(rsi = format, edx = a, ecx = b) -- snprintf into rc_buf. leaf-ish
fmt1:
    sub rsp, 8
    mov r8d, ecx
    mov ecx, edx
    mov rdx, rsi
    lea rdi, [rc_buf]
    mov esi, 256
    xor eax, eax
    call snprintf
    add rsp, 8
    ret

; report_finish(edi = how the night ended) -- score it, keep the best, and
; make the card's lines. (The GL context must exist: textures.)
report_finish:
    PROLOGUE 32
    mov r14d, edi
    call report_score
    ; the best on this kind of building
    mov dword [rc_new_best], 0
    mov ecx, [cfg_building]
    and ecx, 3
    mov eax, [rc_score]
    cmp eax, [rc_best+rcx*4]
    jle .no_best
    test eax, eax
    jz .no_best
    mov [rc_best+rcx*4], eax
    mov dword [rc_new_best], 1
    call save_records
.no_best:
    ; 0: title
    xor ebx, ebx
    lea rsi, [t_lost]
    cmp r14d, GS_WON
    jne .t1
    lea rsi, [t_won]
.t1:
    cmp r14d, GS_SECRET
    jne .t2
    lea rsi, [t_secret]
.t2:
    xor edx, edx
    call fmt1
    mov rdi, [font_big]
    mov eax, [rc_grade]
    mov edx, [grade_col+rax*4]
    call line
    ; 1: grade and score
    mov ebx, 1
    mov eax, [rc_grade]
    movzx edx, byte [grade_ch+rax]
    mov ecx, [rc_score]
    lea rsi, [f_grade]
    call fmt1
    mov rdi, [font_big]
    mov eax, [rc_grade]
    mov edx, [grade_col+rax*4]
    call line
    ; 2: the best
    mov ebx, 2
    mov eax, [cfg_building]
    and eax, 3
    mov edx, [rc_best+rax*4]
    lea rcx, [s_empty]
    cmp dword [rc_new_best], 0
    je .b1
    lea rcx, [s_new_best]
.b1:
    lea rdi, [rc_buf]
    mov esi, 256
    mov r8, rcx
    mov ecx, edx
    lea rdx, [f_best]
    xor eax, eax
    call snprintf
    mov rdi, [font_hud]
    mov edx, [col_best]
    call line
    ; 3: time
    mov ebx, 3
    cvttss2si eax, [elapsed_time]
    xor edx, edx
    mov ecx, 60
    div ecx
    mov ecx, edx
    mov edx, eax
    lea rsi, [f_time]
    call fmt1
    call .info
    ; 4: captures
    mov ebx, 4
    mov edx, [inventory]
    lea rsi, [f_caps]
    call fmt1
    call .info
    ; 5: spotted
    mov ebx, 5
    mov edx, [run_spotted]
    lea rsi, [f_spotted]
    call fmt1
    call .info
    ; 6: closest call (tenths of a metre)
    mov ebx, 6
    lea rsi, [f_close_no]
    movss xmm0, [rc_closest]
    comiss xmm0, [c_hundred]
    jae .close_fmt
    FLD xmm1, 10.0
    mulss xmm0, xmm1
    cvttss2si eax, xmm0
    xor edx, edx
    mov ecx, 10
    div ecx
    mov ecx, edx
    mov edx, eax
    lea rsi, [f_close]
.close_fmt:
    call fmt1
    call .info
    ; 7: loudest
    mov ebx, 7
    movss xmm0, [rc_loud]
    mulss xmm0, [c_hundred]
    cvttss2si edx, xmm0
    lea rsi, [f_loud]
    call fmt1
    call .info
    ; 8: deauths, 9: gadget shots, 10: moves
    mov ebx, 8
    mov edx, [run_deauths]
    lea rsi, [f_deauth]
    call fmt1
    call .info
    mov ebx, 9
    mov edx, [gd_shots]
    lea rsi, [f_shots]
    call fmt1
    call .info
    mov ebx, 10
    mov edx, [run_moves]
    lea rsi, [f_moves]
    call fmt1
    call .info
    ; 11: walked
    mov ebx, 11
    cvttss2si edx, [rc_walked]
    cvttss2si ecx, [rc_safe_t]
    lea rsi, [f_walked]
    call fmt1
    call .info
    ; 12: the loadout
    mov ebx, 12
    call load_line
    call .info
    ; 13: how the score was made
    mov ebx, 13
    call calc_line
    mov rdi, [font_small]
    mov edx, [col_dim]
    call line
    ; 14: how to go on
    mov ebx, 14
    lea rsi, [s_continue]
    call fmt1
    mov rdi, [font_hud]
    mov edx, [col_best]
    call line
    EPILOGUE
.info:
    sub rsp, 8                          ; (keep the stack 16-aligned for line)
    mov rdi, [font_hud]
    mov edx, [col_info]
    call line
    add rsp, 8
    ret

; load_line -- rc_buf = what you brought ("ROD module + HOOK  (score x70%)")
load_line:
    PROLOGUE 16
    call loadout_pct
    test edx, edx
    jnz .some
    lea rsi, [f_load0]
    call fmt1
    EPILOGUE
.some:
    mov [rsp+0], ecx
    mov eax, [cfg_bring_mod]
    mov rcx, [lm_names+rax*8]
    mov eax, [cfg_bring_fire]
    mov r9, [lf_names+rax*8]
    lea r8, [s_empty]
    cmp dword [cfg_bring_mod], 0
    je .one
    cmp dword [cfg_bring_fire], 0
    je .one
    lea r8, [s_plus]
.one:
    ; "%s%s" + the firing type's name after the separator: two passes
    mov [rsp+8], r9
    lea rdi, [rc_buf]
    mov esi, 256
    lea rdx, [f_load1]
    xor eax, eax
    call snprintf
    lea rdi, [rc_buf]
    call strlen
    lea rdi, [rc_buf+rax]
    mov esi, 200
    lea rdx, [fmt_s]
    mov rcx, [rsp+8]
    xor eax, eax
    call snprintf
    lea rdi, [rc_buf]
    call strlen
    lea rdi, [rc_buf+rax]
    mov esi, 100
    lea rdx, [f_load2]
    mov ecx, [rsp+0]
    xor eax, eax
    call snprintf
    EPILOGUE

; calc_line -- rc_buf = the score's terms. printf-family calls must keep to
; registers (the Windows thunks), so it's built in two snprintfs.
calc_line:
    PROLOGUE 16
    lea rdi, [rc_buf]
    mov esi, 256
    lea rdx, [f_calc1]
    mov ecx, [inventory]
    mov r8d, [rc_parts+4]
    mov r9d, [rc_parts+8]
    xor eax, eax
    call snprintf
    lea rdi, [rc_buf]
    call strlen
    mov [rsp+0], eax
    call loadout_pct
    mov r9d, ecx                        ; x%
    mov eax, [rsp+0]
    lea rdi, [rc_buf+rax]
    mov esi, 256
    sub esi, eax
    lea rdx, [f_calc2]
    mov ecx, [rc_parts+12]
    mov r8d, [rc_parts+16]
    xor eax, eax
    call snprintf
    EPILOGUE

section .data
fmt_s       db "%s",0
f_calc1     db "%d captures x200  %+d win  %+d speed",0
f_calc2     db "  %+d unseen  %+d seen/deauths  x%d%%",0
section .text

; report_draw(edi = screen w, esi = screen h) -- the card over the frozen
; night (hud_draw calls it last, in its 2D pixel projection)
report_draw:
    PROLOGUE 48
    cvtsi2ss xmm0, edi
    movss [rsp+0], xmm0                 ; w
    cvtsi2ss xmm0, esi
    movss [rsp+4], xmm0                 ; h
    ; darken everything
    xorps xmm0, xmm0
    xorps xmm1, xmm1
    movss xmm2, [rsp+0]
    movss xmm3, [rsp+4]
    xorps xmm4, xmm4
    xorps xmm5, xmm5
    xorps xmm6, xmm6
    FLD xmm7, 0.72
    call draw_rect
    ; the panel: 720 wide, centred
    movss xmm0, [rsp+0]
    FLD xmm1, 720.0
    subss xmm0, xmm1
    mulss xmm0, [c_half]
    movss [rsp+8], xmm0                 ; x0
    movss xmm1, [rsp+4]
    FLD xmm2, 520.0
    subss xmm1, xmm2
    mulss xmm1, [c_half]
    maxss xmm1, [c_zero]
    movss [rsp+12], xmm1                ; y0
    FLD xmm2, 720.0
    FLD xmm3, 520.0
    FLD xmm4, 0.05
    FLD xmm5, 0.05
    FLD xmm6, 0.07
    FLD xmm7, 0.94
    call draw_rect
    ; the lines
    movss xmm0, [rsp+12]
    FLD xmm1, 24.0
    addss xmm0, xmm1
    movss [rsp+16], xmm0                ; y
    xor ebx, ebx
.l:
    cmp ebx, NLINES
    jge .foot
    cmp dword [rc_tex+rbx*4], 0
    je .n
    mov edi, [rc_tex+rbx*4]
    mov esi, [rc_w+rbx*4]
    mov edx, [rc_h+rbx*4]
    movss xmm0, [rsp+8]
    FLD xmm1, 36.0
    addss xmm0, xmm1
    movss xmm1, [rsp+16]
    movss xmm2, [c_one]
    call draw_text
    cvtsi2ss xmm0, dword [rc_h+rbx*4]
    addss xmm0, [rsp+16]
    FLD xmm1, 6.0
    addss xmm0, xmm1
    cmp ebx, 2                          ; a gap after the grade and best...
    je .wide
    cmp ebx, 13                         ; ...and before "continue"
    jne .gap
.wide:
    FLD xmm1, 14.0
    addss xmm0, xmm1
.gap:
    movss [rsp+16], xmm0
.n:
    inc ebx
    jmp .l
.foot:
    EPILOGUE
