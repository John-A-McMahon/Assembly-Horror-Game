; =============================================================================
; nemesis.asm -- T remembers you.
;
; Every chase you get away from is put down to the last trick you used in
; it: the hookshot, a portal, a safe room, a perch he had to build up to, or
; a deauth. Three escapes the same way and he adapts; six and he adapts more:
;
;   hookshot   he hears the hook bite from 50% / 100% further away
;   portal     he follows you through portals even when he wasn't chasing
;   safe room  he waits outside for 10 / 20 s instead of wandering off
;   perch      he builds his stairs faster (1.5 s -> 1.05 -> 0.6)
;   deauth     he shakes a deauth off quicker (5 s -> 4 -> 3)
;
; And a grudge: every night you beat him makes him 4% faster (every time he
; catches you takes 2% off again, up to +16%).
;
; It all lives in beacom_nemesis.cfg (in real play; delete it to start
; over). The pause menu can switch the memory off.
; =============================================================================
%define MODULE_NEMESIS
%include "common.inc"

global nemesis_load, nemesis_note, nemesis_tick, nemesis_end, nemesis_new_night
global nemesis_forget, nemesis_apply
global nm_build_time, nm_stun, nm_portal_any, nm_camp_time, nm_hook_hear, nm_speed
global nm_cnt, nm_caught, nm_wins, nm_nights

extern cfg_nemesis, fwrite, fread, fopen, fclose

%define NTOOLS 5

section .data
; what the adaptations come to (nemesis_apply sets them)
nm_build_time dd 1.5
nm_stun     dd 5.0
nm_portal_any dd 0
nm_camp_time dd 0.0
nm_hook_hear dd 22.0
nm_speed    dd 1.0
c_build0    dd 1.5
c_build_step dd 0.45
c_stun0     dd 5.0
c_hear0     dd 22.0
c_hear_step dd 11.0
c_camp_step dd 10.0
c_grudge_w  dd 0.04
c_grudge_c  dd 0.02
c_grudge_max dd 0.16
file_name   db "beacom_nemesis.cfg",0
mode_w      db "w",0
mode_r      db "r",0
fmt_key     db "nemesis=",0
fmt_num     db "%d ",0
key_save    db "nemesis="
t_learn0    db "T is learning your hookshot tricks: he hears the hook bite from further away.",0
t_learn1    db "T is learning about your portals: he follows you through them now.",0
t_learn2    db "T is learning where you hide: he'll wait outside your safe rooms.",0
t_learn3    db "T is learning to climb: he builds his way up to you faster.",0
t_learn4    db "T is learning to shrug off deauths: they stun him for less time.",0
align 8
t_learns    dq t_learn0, t_learn1, t_learn2, t_learn3, t_learn4
m_head      db "T REMEMBERS YOU. Night %d: he has caught you %d times, you have beaten him %d. ",0
m_learned   db "He has learned:",0
m_nothing   db "He hasn't figured you out yet.",0
m_grudge    db " He holds a grudge: +%d%% speed.",0
kname0      db " [your hookshot]",0
kname1      db " [your portals]",0
kname2      db " [your safe rooms]",0
kname3      db " [your perches]",0
kname4      db " [your deauths]",0
align 8
knames      dq kname0, kname1, kname2, kname3, kname4

section .bss
alignb 4
nm_cnt      resd NTOOLS                 ; escapes by each trick (persistent)
nm_caught   resd 1
nm_wins     resd 1
nm_nights   resd 1
nm_tool     resd 1                      ; last trick in this chase (-1 none)
nm_prev     resd 1                      ; T's state last frame
nm_safe     resd 1                      ; you were in a safe room last frame
nm_lvl      resd NTOOLS
msg_buf     resb 512
file_buf    resb 128

section .text

; level(ebx = tool) -> eax 0..2
level:
    mov eax, [nm_cnt+rbx*4]
    xor edx, edx
    mov ecx, 3
    div ecx
    cmp eax, 2
    jle .ok
    mov eax, 2
.ok:
    cmp dword [cfg_nemesis], 0
    jne .on
    xor eax, eax
.on:
    ret

; nemesis_apply -- turn what he knows into how he plays
nemesis_apply:
    PROLOGUE 16
    xor ebx, ebx
.l:
    cmp ebx, NTOOLS
    jge .have
    call level
    mov [nm_lvl+rbx*4], eax
    inc ebx
    jmp .l
.have:
    ; hookshot: hears it further
    cvtsi2ss xmm0, dword [nm_lvl+0]
    mulss xmm0, [c_hear_step]
    addss xmm0, [c_hear0]
    movss [nm_hook_hear], xmm0
    ; portals: follows even un-chasing
    xor eax, eax
    cmp dword [nm_lvl+4], 0
    setne al
    mov [nm_portal_any], eax
    ; safe rooms: camps outside
    cvtsi2ss xmm0, dword [nm_lvl+8]
    mulss xmm0, [c_camp_step]
    movss [nm_camp_time], xmm0
    ; perches: builds faster
    cvtsi2ss xmm0, dword [nm_lvl+12]
    mulss xmm0, [c_build_step]
    movss xmm1, [c_build0]
    subss xmm1, xmm0
    movss [nm_build_time], xmm1
    ; deauths: shorter stun
    cvtsi2ss xmm0, dword [nm_lvl+16]
    movss xmm1, [c_stun0]
    subss xmm1, xmm0
    movss [nm_stun], xmm1
    ; the grudge
    mov eax, [c_one]
    mov [nm_speed], eax
    cmp dword [cfg_nemesis], 0
    je .done
    cvtsi2ss xmm0, dword [nm_wins]
    mulss xmm0, [c_grudge_w]
    cvtsi2ss xmm1, dword [nm_caught]
    mulss xmm1, [c_grudge_c]
    subss xmm0, xmm1
    maxss xmm0, [c_zero]
    minss xmm0, [c_grudge_max]
    addss xmm0, [c_one]
    movss [nm_speed], xmm0
.done:
    EPILOGUE

; nemesis_note(edi = trick: 0 hookshot 1 portal 2 safe room 3 perch 4 deauth)
; -- you just used it; if it gets you out of this chase, he'll remember
nemesis_note:
    cmp dword [cfg_nemesis], 0
    je .no
    cmp edi, 4
    je .yes                             ; a deauth ends a chase by itself
    cmp dword [t_state], T_CHASE
    jne .no
.yes:
    mov [nm_tool], edi
.no:
    ret

; nemesis_tick -- watch the chases end
nemesis_tick:
    PROLOGUE 16
    cmp dword [cfg_nemesis], 0
    je .done
    ; ducking into a safe room mid-chase
    call player_in_safe
    mov ebx, eax
    test eax, eax
    jz .safe_done
    cmp dword [nm_safe], 0
    jne .safe_done
    mov edi, 2
    call nemesis_note
.safe_done:
    mov [nm_safe], ebx
    ; a chase that just ended with you alive: put it down to the trick
    cmp dword [nm_prev], T_CHASE
    jne .track
    cmp dword [t_state], T_CHASE
    je .track
    cmp dword [t_caught], 0
    jne .forget
    mov ebx, [nm_tool]
    cmp ebx, 0
    jl .forget
    mov r12d, [nm_lvl+rbx*4]
    inc dword [nm_cnt+rbx*4]
    call nemesis_apply
    cmp [nm_lvl+rbx*4], r12d
    je .forget
    ; he's learned something new
    mov rdi, [t_learns+rbx*8]
    mov esi, 0xFF3B3BFF
    xor edx, edx
    call hud_message
.forget:
    mov dword [nm_tool], -1
.track:
    mov eax, [t_state]
    mov [nm_prev], eax
.done:
    EPILOGUE

; nemesis_new_night -- apply what he knows, and tell you about it
nemesis_new_night:
    PROLOGUE 16
    mov dword [nm_tool], -1
    mov dword [nm_prev], T_WANDER
    mov dword [nm_safe], 0
    call nemesis_apply
    cmp dword [cfg_nemesis], 0
    je .done
    cmp dword [nm_nights], 0
    je .done
    lea rdi, [msg_buf]
    mov esi, 512
    lea rdx, [m_head]
    mov ecx, [nm_nights]
    inc ecx
    mov r8d, [nm_caught]
    mov r9d, [nm_wins]
    xor eax, eax
    call snprintf
    ; what he's learned
    xor ebx, ebx
    xor r12d, r12d
.k:
    cmp ebx, NTOOLS
    jge .listed
    cmp dword [nm_lvl+rbx*4], 0
    je .kn
    test r12d, r12d
    jnz .more
    lea rsi, [m_learned]
    call append
    mov r12d, 1
.more:
    mov rsi, [knames+rbx*8]
    call append
.kn:
    inc ebx
    jmp .k
.listed:
    test r12d, r12d
    jnz .grudge
    lea rsi, [m_nothing]
    call append
.grudge:
    movss xmm0, [nm_speed]
    subss xmm0, [c_one]
    FLD xmm1, 100.5
    mulss xmm0, xmm1
    cvttss2si ebx, xmm0
    test ebx, ebx
    jz .say
    lea rdi, [msg_buf]
    call strlen
    lea rdi, [msg_buf+rax]
    mov esi, 64
    lea rdx, [m_grudge]
    mov ecx, ebx
    xor eax, eax
    call snprintf
.say:
    lea rdi, [msg_buf]
    mov esi, 0xFF3B3BFF
    mov edx, 1
    call hud_message
.done:
    EPILOGUE

; nemesis_end(edi = 0 he caught you / 1 you won) -- the night's over
nemesis_end:
    PROLOGUE 16
    cmp dword [cfg_nemesis], 0
    je .done
    inc dword [nm_nights]
    test edi, edi
    jz .caught
    inc dword [nm_wins]
    jmp .save
.caught:
    inc dword [nm_caught]
.save:
    call nemesis_save
.done:
    EPILOGUE

; nemesis_forget -- (self-tests) a blank slate
nemesis_forget:
    PROLOGUE 16
    lea rdi, [nm_cnt]
    xor esi, esi
    mov edx, (NTOOLS+3)*4
    call memset
    call nemesis_apply
    EPILOGUE

; nemesis_save -- only in real play (like the achievements):
; "nemesis=<5 escape counts> <caught> <wins> <nights>"
nemesis_save:
    PROLOGUE 16
    cmp dword [ach_persist], 0
    je .done
    mov byte [file_buf], 0
    lea rsi, [fmt_key]
    call append_file
    xor ebx, ebx
.n:
    cmp ebx, NTOOLS+3
    jge .write
    lea rdi, [file_buf]
    call strlen
    lea rdi, [file_buf+rax]
    mov esi, 16
    lea rdx, [fmt_num]
    mov ecx, [nm_cnt+rbx*4]
    xor eax, eax
    call snprintf
    inc ebx
    jmp .n
.write:
    lea rdi, [file_name]
    lea rsi, [mode_w]
    call fopen
    test rax, rax
    jz .done
    mov r12, rax
    lea rdi, [file_buf]
    call strlen
    lea rdi, [file_buf]
    mov esi, 1
    mov edx, eax
    mov rcx, r12
    call fwrite
    mov rdi, r12
    call fclose
.done:
    EPILOGUE

; append(rsi = text) -- onto the end of msg_buf / append_file: file_buf
append:
    lea rdi, [msg_buf]
    jmp append_to
append_file:
    lea rdi, [file_buf]
append_to:
.end:
    cmp byte [rdi], 0
    je .copy
    inc rdi
    jmp .end
.copy:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .copy
    ret

; nemesis_load -- read the file back
nemesis_load:
    PROLOGUE 16
    lea rdi, [file_name]
    lea rsi, [mode_r]
    call fopen
    test rax, rax
    jz .done
    mov r12, rax
    lea rdi, [file_buf]
    mov esi, 1
    mov edx, 127
    mov rcx, r12
    call fread
    mov byte [file_buf+rax], 0
    mov rdi, r12
    call fclose
    xor ecx, ecx
.key:
    cmp ecx, 8
    jge .nums
    mov al, [file_buf+rcx]
    cmp al, [key_save+rcx]
    jne .done
    inc ecx
    jmp .key
.nums:
    ; eight numbers: cnt0..4, caught, wins, nights (the same order in memory)
    lea rsi, [file_buf+8]
    xor ebx, ebx
.n:
    cmp ebx, NTOOLS+3
    jge .done
    xor edx, edx
.skip:
    movzx eax, byte [rsi]
    test eax, eax
    jz .done
    sub eax, '0'
    cmp eax, 9
    jbe .digits
    inc rsi
    jmp .skip
.digits:
    movzx eax, byte [rsi]
    sub eax, '0'
    cmp eax, 9
    ja .stored
    imul edx, edx, 10
    add edx, eax
    inc rsi
    jmp .digits
.stored:
    mov [nm_cnt+rbx*4], edx
    inc ebx
    jmp .n
.done:
    call nemesis_apply
    EPILOGUE
