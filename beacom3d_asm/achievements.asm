; =============================================================================
; achievements.asm -- things worth bragging about.
;
; Unlocking one shows a gold "ACHIEVEMENT UNLOCKED" message with a fanfare and
; saves it to beacom_achievements.cfg (not in --shot / --selftest runs). The
; pause menu lists them all; the end screen lists what this run earned.
;
; Most are noticed where they happen (ach_unlock from main/parkour/traverse/
; portal); the rest are checked every frame (ach_tick) or when you win
; (ach_won), from counters this run keeps (ach_new_run clears them).
; =============================================================================
%define MODULE_ACH
%include "common.inc"

global ach_unlock, ach_new_run, ach_won, ach_tick, ach_load, ach_print_run
global ach_flag, ach_persist, run_deauths, run_spotted, run_warned, run_moves

extern hud_message, snd_fanfare, player_in_safe, t_state, p_on_ground, p_mode
extern fwrite, elapsed_time

%define RGBC(r,g,b) (0xFF000000 | ((b)<<16) | ((g)<<8) | (r))
%define COL_GOLD RGBC(255,215,90)

section .data
; ---- names, in ACH_ order (common.inc) ---------------------------------------
an0  db "PACKET SNIFFER",0
an1  db "FULL CAPTURE",0
an2  db "PACIFIST",0
an3  db "GHOST PROTOCOL",0
an4  db "SPEEDRUN.EXE",0
an5  db "SILENT RUNNING",0
an6  db "ARCHITECT",0
an7  db "LOST IN THE MAZE",0
an8  db "POINT BLANK",0
an9  db "FREE RUNNER",0
an10 db "ZIPLINE ZOOMER",0
an11 db "THINKING WITH PORTALS",0
an12 db "SAFE AND SOUND",0
an13 db "STAGE FRIGHT",0
an14 db "KING OF THE CRATES",0
an15 db "HI I AM TYLER",0
an16 db "CHICKEN JOCKEY",0
an17 db "NETWORKING",0
an18 db "GET OVER HERE",0
an19 db "SPIDER-BEACOM",0
an20 db "DO THE DEW",0
align 8
ach_names   dq an0, an1, an2, an3, an4, an5, an6, an7, an8, an9
            dq an10, an11, an12, an13, an14, an15, an16, an17, an18, an19
            dq an20

m_unlocked  db "ACHIEVEMENT UNLOCKED: %s",0
m_run_head  db 10,"Achievements unlocked this run:",10,0
m_run_line  db "  * %s",10,0
m_run_total db "(%d of %d unlocked in total -- see them in the Esc menu)",10,0
file_name   db "beacom_achievements.cfg",0
mode_w      db "w",0
mode_r      db "r",0
fmt_save    db "unlocked=%u",10,0
key_save    db "unlocked="
c_speedrun  dd 300.0                    ; SPEEDRUN.EXE: under 5 minutes
c_stage_y0  dd 4.7                      ; STAGE FRIGHT: the grand staircase stage
c_stage_y1  dd 4.9
c_stage_x0  dd 48.0
c_stage_x1  dd 64.0
c_stage_z0  dd 42.0
c_stage_z1  dd 44.0
c_crate_top dd 1.8                      ; KING OF THE CRATES: this high above the floor
c_small     dd 0.05

section .bss
alignb 4
ach_flag    resd NACH                   ; 1 = unlocked (ever)
ach_persist resd 1                      ; save to the file? (not in test runs)
run_new     resd 1                      ; bits: unlocked during this run
run_deauths resd 1                      ; deauth packets fired this run
run_spotted resd 1                      ; times T spotted you
run_warned  resd 1                      ; times the noise meter warned you
run_moves   resd 1                      ; mantles + vaults
msg_buf     resb 128
file_buf    resb 64

section .text

; ach_unlock(edi = ACH_ id) -- first time only: flag it, tell the player, save
ach_unlock:
    PROLOGUE 16
    mov ebx, edi
    cmp ebx, NACH
    jae .done
    cmp dword [ach_flag+rbx*4], 0
    jne .done
    mov dword [ach_flag+rbx*4], 1
    bts dword [run_new], ebx
    lea rdi, [msg_buf]
    mov esi, 128
    lea rdx, [m_unlocked]
    mov rcx, [ach_names+rbx*8]
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, COL_GOLD
    xor edx, edx
    call hud_message
    call snd_fanfare
    call ach_save
.done:
    EPILOGUE

; ach_new_run -- a new night: clear this run's counters
ach_new_run:
    xor eax, eax
    mov [run_new], eax
    mov [run_deauths], eax
    mov [run_spotted], eax
    mov [run_warned], eax
    mov [run_moves], eax
    ret

; ach_won -- you freed Y: everything that depends on how you did it
ach_won:
    PROLOGUE 16
    mov edi, ACH_FULL_CAPTURE
    call ach_unlock
    cmp dword [run_deauths], 0
    jne .not_pacifist
    mov edi, ACH_PACIFIST
    call ach_unlock
.not_pacifist:
    cmp dword [run_spotted], 0
    jne .seen
    mov edi, ACH_GHOST
    call ach_unlock
.seen:
    movss xmm0, [elapsed_time]
    comiss xmm0, [c_speedrun]
    jae .slow
    mov edi, ACH_SPEEDRUN
    call ach_unlock
.slow:
    cmp dword [run_warned], 0
    jne .loud
    mov edi, ACH_SILENT
    call ach_unlock
.loud:
    cmp dword [cfg_building], BLD_GENERATED
    jne .done
    mov edi, ACH_ARCHITECT
    call ach_unlock
    cmp dword [cfg_layout], 0           ; the maze layout
    jne .done
    mov edi, ACH_MAZE
    call ach_unlock
.done:
    EPILOGUE

; ach_tick -- the ones that are about where you are
ach_tick:
    PROLOGUE 16
    ; SAFE AND SOUND: into a safe room with T on your heels
    cmp dword [t_state], T_CHASE
    jne .no_chase
    call player_in_safe
    test eax, eax
    jz .not_safe
    mov edi, ACH_SAFE
    call ach_unlock
.not_safe:
    ; STAGE FRIGHT: on the grand staircase's stage while he chases you
    cmp dword [cur_set], SET_REAL
    jne .no_chase
    movss xmm0, [p_y]
    comiss xmm0, [c_stage_y0]
    jb .no_chase
    comiss xmm0, [c_stage_y1]
    ja .no_chase
    movss xmm0, [p_x]
    comiss xmm0, [c_stage_x0]
    jb .no_chase
    comiss xmm0, [c_stage_x1]
    ja .no_chase
    movss xmm0, [p_z]
    comiss xmm0, [c_stage_z0]
    jb .no_chase
    comiss xmm0, [c_stage_z1]
    ja .no_chase
    mov edi, ACH_STAGE
    call ach_unlock
.no_chase:
    ; KING OF THE CRATES: standing on a tall crate stack ('K')
    cmp dword [p_on_ground], 0
    je .done
    cmp dword [p_mode], 0
    jne .done
    movss xmm0, [p_y]
    subss xmm0, [c_crate_top]
    addss xmm0, [c_small]
    divss xmm0, [c_fh]
    roundss xmm0, xmm0, 1
    cvttss2si ebx, xmm0                 ; the storey the crate stands on
    cvtsi2ss xmm1, ebx
    mulss xmm1, [c_fh]
    movss xmm0, [p_y]
    subss xmm0, xmm1
    comiss xmm0, [c_crate_top]
    jb .done
    mov edi, ebx
    movss xmm0, [p_x]
    mulss xmm0, [c_inv_cell]
    cvttss2si esi, xmm0
    movss xmm0, [p_z]
    mulss xmm0, [c_inv_cell]
    cvttss2si edx, xmm0
    call cell_at
    cmp eax, 'K'
    jne .done
    mov edi, ACH_CRATES
    call ach_unlock
.done:
    EPILOGUE

; ach_print_run -- the end screen, in the terminal
ach_print_run:
    PROLOGUE 16
    cmp dword [run_new], 0
    je .total
    lea rdi, [m_run_head]
    xor eax, eax
    call printf
    xor ebx, ebx
.a:
    cmp ebx, NACH
    jge .total
    bt dword [run_new], ebx
    jnc .n
    lea rdi, [m_run_line]
    mov rsi, [ach_names+rbx*8]
    xor eax, eax
    call printf
.n:
    inc ebx
    jmp .a
.total:
    xor ebx, ebx
    xor ecx, ecx
.c:
    cmp ebx, NACH
    jge .print
    add ecx, [ach_flag+rbx*4]
    inc ebx
    jmp .c
.print:
    lea rdi, [m_run_total]
    mov esi, ecx
    mov edx, NACH
    xor eax, eax
    call printf
    EPILOGUE

; ach_save -- "unlocked=<bits>" (only in real play)
ach_save:
    PROLOGUE 32
    cmp dword [ach_persist], 0
    je .done
    xor ebx, ebx                        ; bits
    xor ecx, ecx
.b:
    cmp ecx, NACH
    jge .have
    cmp dword [ach_flag+rcx*4], 0
    je .nb
    bts ebx, ecx
.nb:
    inc ecx
    jmp .b
.have:
    lea rdi, [file_name]
    lea rsi, [mode_w]
    call fopen
    test rax, rax
    jz .done
    mov r12, rax
    lea rdi, [msg_buf]
    mov esi, 128
    lea rdx, [fmt_save]
    mov ecx, ebx
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    call strlen
    lea rdi, [msg_buf]
    mov esi, 1
    mov edx, eax
    mov rcx, r12
    call fwrite
    mov rdi, r12
    call fclose
.done:
    EPILOGUE

; ach_load -- read the file back (and from now on, save to it)
ach_load:
    PROLOGUE 16
    mov dword [ach_persist], 1
    lea rdi, [file_name]
    lea rsi, [mode_r]
    call fopen
    test rax, rax
    jz .done
    mov r12, rax
    lea rdi, [file_buf]
    mov esi, 1
    mov edx, 63
    mov rcx, r12
    call fread
    mov byte [file_buf+rax], 0
    mov rdi, r12
    call fclose
    ; "unlocked=" then digits
    xor ecx, ecx
.k:
    cmp ecx, 9
    jge .num
    mov al, [file_buf+rcx]
    cmp al, [key_save+rcx]
    jne .done
    inc ecx
    jmp .k
.num:
    lea rsi, [file_buf+9]
    xor ebx, ebx
.d:
    movzx eax, byte [rsi]
    sub eax, '0'
    cmp eax, 9
    ja .bits
    imul ebx, ebx, 10
    add ebx, eax
    inc rsi
    jmp .d
.bits:
    xor ecx, ecx
.f:
    cmp ecx, NACH
    jge .done
    xor eax, eax
    bt ebx, ecx
    setc al
    mov [ach_flag+rcx*4], eax
    inc ecx
    jmp .f
.done:
    EPILOGUE
