; =============================================================================
; nemesis.asm -- T learns how you escape him, over the course of the night.
;
; Every chase you get away from is put down to the last trick you used in
; it: the hookshot, a portal, a safe room, a perch he had to build up to, or
; a deauth. Twice the same way and he adapts; four times and he adapts more:
;
;   hookshot   he hears the hook bite from 50% / 100% further away
;   portal     he follows you through portals even when he wasn't chasing
;   safe room  he waits outside for 10 / 20 s instead of wandering off
;   perch      he builds his stairs faster (1.5 s -> 1.05 -> 0.6)
;   deauth     he shakes a deauth off quicker (5 s -> 4 -> 3)
;
; It's per night: every run starts with a T who knows nothing. You're told
; each time he notices a trick and each time he learns from it. The pause
; menu can switch it off.
; =============================================================================
%define MODULE_NEMESIS
%include "common.inc"

global nemesis_note, nemesis_tick, nemesis_new_night, nemesis_forget, nemesis_apply
global nm_build_time, nm_stun, nm_portal_any, nm_camp_time, nm_hook_hear, nm_cnt

extern cfg_nemesis

%define NTOOLS 5
%define PER_LEVEL 2                     ; escapes the same way per level

section .data
; what the adaptations come to (nemesis_apply sets them)
nm_build_time dd 1.5
nm_stun     dd 5.0
nm_portal_any dd 0
nm_camp_time dd 0.0
nm_hook_hear dd 22.0
c_build0    dd 1.5
c_build_step dd 0.45
c_stun0     dd 5.0
c_hear0     dd 22.0
c_hear_step dd 11.0
c_camp_step dd 10.0
m_intro     db "T learns as the night goes on: escape him the same way twice and he'll adapt to it.",0
m_noticed   db "T saw how you got away: %s. (%d of %d -- then he adapts)",0
m_known     db "You got away with %s again -- but T already knows that one.",0
t_learn0    db "T HAS LEARNED your hookshot: he hears the hook bite from %d m away now.",0
t_learn1    db "T HAS LEARNED your portals: he'll follow you through them even when he isn't chasing you.",0
t_learn2    db "T HAS LEARNED your safe rooms: he'll wait outside for %d s instead of wandering off.",0
t_learn3    db "T HAS LEARNED your perches: he builds his stairs up to you in %d.%d s now.",0
t_learn4    db "T HAS LEARNED your deauths: they only stun him for %d s now.",0
align 8
t_learns    dq t_learn0, t_learn1, t_learn2, t_learn3, t_learn4
tn0         db "the hookshot",0
tn1         db "a portal",0
tn2         db "a safe room",0
tn3         db "a perch he had to build up to",0
tn4         db "a deauth",0
align 8
tnames      dq tn0, tn1, tn2, tn3, tn4

section .bss
alignb 4
nm_cnt      resd NTOOLS                 ; escapes by each trick this night
nm_lvl      resd NTOOLS
nm_tool     resd 1                      ; last trick in this chase (-1 none)
nm_prev     resd 1                      ; T's state last frame
nm_safe     resd 1                      ; you were in a safe room last frame
msg_buf     resb 256

section .text

; level(ebx = tool) -> eax 0..2
level:
    xor eax, eax
    cmp dword [cfg_nemesis], 0
    je .ok
    mov eax, [nm_cnt+rbx*4]
    xor edx, edx
    mov ecx, PER_LEVEL
    div ecx
    cmp eax, 2
    jle .ok
    mov eax, 2
.ok:
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
    cvtsi2ss xmm0, dword [nm_lvl+0]     ; hookshot: hears it further
    mulss xmm0, [c_hear_step]
    addss xmm0, [c_hear0]
    movss [nm_hook_hear], xmm0
    xor eax, eax                        ; portals: follows even un-chasing
    cmp dword [nm_lvl+4], 0
    setne al
    mov [nm_portal_any], eax
    cvtsi2ss xmm0, dword [nm_lvl+8]     ; safe rooms: waits outside
    mulss xmm0, [c_camp_step]
    movss [nm_camp_time], xmm0
    cvtsi2ss xmm0, dword [nm_lvl+12]    ; perches: builds faster
    mulss xmm0, [c_build_step]
    movss xmm1, [c_build0]
    subss xmm1, xmm0
    movss [nm_build_time], xmm1
    cvtsi2ss xmm0, dword [nm_lvl+16]    ; deauths: shorter stun
    movss xmm1, [c_stun0]
    subss xmm1, xmm0
    movss [nm_stun], xmm1
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

; nemesis_tick -- watch the chases end, and tell you what he made of it
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
    jne .learned
    cmp r12d, 2
    jge .known
    ; noticed: "(n of 2)" toward the next lesson
    mov eax, [nm_cnt+rbx*4]
    xor edx, edx
    mov ecx, PER_LEVEL
    div ecx                             ; edx = progress into this level
    lea rdi, [msg_buf]
    mov esi, 256
    mov r8d, edx
    lea rdx, [m_noticed]
    mov rcx, [tnames+rbx*8]
    mov r9d, PER_LEVEL
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, 0xFF47B3FF
    xor edx, edx
    call hud_message
    jmp .forget
.known:
    lea rdi, [msg_buf]
    mov esi, 256
    lea rdx, [m_known]
    mov rcx, [tnames+rbx*8]
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, 0xFF47B3FF
    xor edx, edx
    call hud_message
    jmp .forget
.learned:
    ; he's learned something: say exactly what
    call learned_numbers                ; -> ecx, r8d for the message
    lea rdi, [msg_buf]
    mov esi, 256
    mov rdx, [t_learns+rbx*8]
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, 0xFF3B3BFF
    xor edx, edx
    call hud_message
    call snd_spotted
.forget:
    mov dword [nm_tool], -1
.track:
    mov eax, [t_state]
    mov [nm_prev], eax
.done:
    EPILOGUE

; learned_numbers(ebx = tool) -> ecx (, r8d) = the numbers its message needs
learned_numbers:
    sub rsp, 8
    xor ecx, ecx
    xor r8d, r8d
    cmp ebx, 0
    jne .n2
    cvttss2si ecx, [nm_hook_hear]
.n2:
    cmp ebx, 2
    jne .n3
    cvttss2si ecx, [nm_camp_time]
.n3:
    cmp ebx, 3
    jne .n4
    movss xmm0, [nm_build_time]         ; as d.d
    FLD xmm1, 10.0
    mulss xmm0, xmm1
    cvtss2si eax, xmm0
    xor edx, edx
    mov r9d, 10
    div r9d
    mov ecx, eax
    mov r8d, edx
.n4:
    cmp ebx, 4
    jne .done
    cvttss2si ecx, [nm_stun]
.done:
    add rsp, 8
    ret

; nemesis_new_night -- a new run: he knows nothing yet
nemesis_new_night:
    PROLOGUE 16
    call nemesis_forget
    cmp dword [cfg_nemesis], 0
    je .done
    lea rdi, [m_intro]
    mov esi, 0xFF47B3FF
    xor edx, edx
    call hud_message
.done:
    EPILOGUE

; nemesis_forget -- a blank slate
nemesis_forget:
    PROLOGUE 16
    lea rdi, [nm_cnt]
    xor esi, esi
    mov edx, NTOOLS*4
    call memset
    mov dword [nm_tool], -1
    mov dword [nm_prev], T_WANDER
    mov dword [nm_safe], 0
    call nemesis_apply
    EPILOGUE
