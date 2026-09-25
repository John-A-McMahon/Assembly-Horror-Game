; =============================================================================
; feeders.asm -- bottom feeders: little scuttling scavengers that live off
; what's lying around Beacom. They don't kill you -- they rob you.
;
;   wander   they potter about the building at a slow scuttle
;   chase    one that sees you *while you carry packet captures* comes for
;            you, faster than you walk but slower than you sprint
;   steal    if it reaches you it snatches one capture and bolts
;   flee     it runs for somewhere far from you, with the capture glowing
;            on its back -- catch it first and you snatch it back
;   stash    otherwise it hides the capture there (a new capture item, on
;            the compass like any other) and calms down for a while
;   deauth   a deauth packet aimed at one gets rid of it FOR GOOD (it drops
;            whatever it carries) -- but that packet doesn't touch T. Aim
;            away from them and it's T's: gone, but only for a while.
; They can't go into safe rooms, and the scuffle when one robs you is loud
; enough that T may come to look.
; =============================================================================
%define MODULE_FEED
%include "common.inc"

global feeders_reset, feeders_update, feeders_deauth, feeder_put
global fd_count, fd_x, fd_y, fd_z, fd_yaw, fd_anim, fd_carry, fd_state

extern find_next, cfg_feeders, cfg_t_angry, add_item, snd_pickup
extern snd_feeder_spot, snd_feeder_steal, snd_feeder_click, atan2f, sinf, cosf

%define NFEED     4
%define FD_WANDER 0
%define FD_CHASE  1
%define FD_FLEE   2
%define FD_STUN   3
%define FD_DEAD   4

section .data
fd_speeds   dd 1.6, 4.2, 4.6, 0.0       ; per state (you walk 3.4, sprint 6.0)
c_sight     dd 11.0                     ; how far they notice you...
c_sight_lit dd 16.0                     ; ...further with your flashlight on
c_eye       dd 0.35
c_grab      dd 0.9                      ; within this: a steal, or a snatch back
c_grab_y    dd 1.2
c_lose      dd 4.0                      ; out of sight this long: give up
c_stun      dd 5.0                      ; deauthed
c_daze      dd 3.0                      ; after you snatch a capture back
c_calm      dd 8.0                      ; after stashing one
c_getaway   dd 0.7                      ; a thief can't be grabbed at once
c_deauth_r  dd 15.0                     ; a deauth reaches this far...
c_aim       dd 0.9                      ; ...within ~25 degrees of your aim
c_click_r   dd 10.0                     ; you hear them scuttle this close
c_click_dt  dd 0.15
c_anim      dd 7.0
c_bonus     dd 0.3                      ; = main.asm's T speed bonus per capture
c_noise_steal dd 0.12
c_hide_away dd 30                       ; stash at least this many cells from you
m_smell     db "Something low and quick is scuttling after you -- a BOTTOM FEEDER. It smells your packet captures.",0
m_stolen    db "A bottom feeder snatched a packet capture! (%d/3 left) Catch it before it hides it!",0
m_snatched  db "You snatch the capture back from the bottom feeder! (%d/3)",0
m_stashed   db "The bottom feeder stashed your capture somewhere on the %s.",0
m_killed    db "The deauth fries the bottom feeder. It's gone for good. (T is still out there...)",0
m_killed_c  db "The deauth fries the bottom feeder -- gone for good, and it drops the capture it was carrying!",0
fl_0        db "basement",0
fl_1        db "ground floor",0
fl_2        db "second floor",0
align 8
fl_names    dq fl_0, fl_1, fl_2

section .bss
alignb 4
fd_count    resd 1
fd_x        resd NFEED
fd_y        resd NFEED
fd_z        resd NFEED
fd_yaw      resd NFEED
fd_anim     resd NFEED
fd_node     resd NFEED
fd_next     resd NFEED
fd_goal     resd NFEED
fd_state    resd NFEED
fd_timer    resd NFEED                  ; stun left, or calm-down left
fd_lost     resd NFEED
fd_carry    resd NFEED                  ; 1 = running off with a capture
fd_click    resd 1
fdt         resd 1                      ; this frame's dt
fd_warned   resd 1
msg_buf     resb 160

section .text

; place(ebx = i, edi = node) -- put feeder i on a node, standing still
place:
    PROLOGUE 16
    mov r12d, edi
    call node_center
    movss [fd_x+rbx*4], xmm0
    movss [fd_y+rbx*4], xmm1
    movss [fd_z+rbx*4], xmm2
    mov [fd_node+rbx*4], r12d
    mov [fd_next+rbx*4], r12d
    mov [fd_goal+rbx*4], r12d
    EPILOGUE

; player_cell -> esi = x, edx = y, eax = floor (for random_node's "away")
player_cell:
    PROLOGUE 16
    call player_floor
    mov ebx, eax
    movss xmm0, [p_x]
    mulss xmm0, [c_inv_cell]
    cvttss2si esi, xmm0
    movss xmm0, [p_z]
    mulss xmm0, [c_inv_cell]
    cvttss2si edx, xmm0
    mov eax, ebx
    EPILOGUE

; feeders_reset -- a new night: they start well away from you
feeders_reset:
    PROLOGUE 16
    mov eax, [cfg_feeders]
    cmp eax, NFEED
    jle .n
    mov eax, NFEED
.n:
    mov [fd_count], eax
    mov dword [fd_warned], 0
    mov dword [fd_click], 0
    xor ebx, ebx
.f:
    cmp ebx, [fd_count]
    jge .done
    mov edi, -1
    mov esi, 1
    mov edx, [start_f]
    mov ecx, [start_x]
    mov r8d, [start_y]
    mov r9d, 25
    call random_node
    mov edi, eax
    call place
    mov dword [fd_state+rbx*4], FD_WANDER
    mov dword [fd_timer+rbx*4], 0
    mov dword [fd_lost+rbx*4], 0
    mov dword [fd_carry+rbx*4], 0
    mov dword [fd_anim+rbx*4], 0
    mov dword [fd_yaw+rbx*4], 0
    inc ebx
    jmp .f
.done:
    EPILOGUE

; set_bonus -- T gets angrier with every capture you hold (as main.asm does)
set_bonus:
    cmp dword [cfg_t_angry], 0
    je .no
    cvtsi2ss xmm0, dword [inventory]
    mulss xmm0, [c_bonus]
    movss [t_speed_bonus], xmm0
.no:
    ret

; drop_capture(ebx = i) -- the capture it carries lands where it stands
drop_capture:
    PROLOGUE 16
    mov dword [fd_carry+rbx*4], 0
    mov esi, [fd_node+rbx*4]
    mov edi, IT_KEY
    call add_item
    EPILOGUE

; feeders_deauth -> eax 1 if the packet you just fired was aimed at a bottom
; feeder (the nearest one in your sights, in reach and in view): it's gone
; for good. 0: nothing to hit here -- the packet is T's.
feeders_deauth:
    PROLOGUE 48
    ; your aim: forward = (-sin yaw cos pitch, sin pitch, -cos yaw cos pitch)
    movss xmm0, [p_pitch]
    call cosf
    movss [rsp+0], xmm0
    movss xmm0, [p_pitch]
    call sinf
    movss [rsp+8], xmm0
    movss xmm0, [p_yaw]
    call sinf
    mulss xmm0, [rsp+0]
    xorps xmm0, [c_sign_mask]
    movss [rsp+4], xmm0
    movss xmm0, [p_yaw]
    call cosf
    mulss xmm0, [rsp+0]
    xorps xmm0, [c_sign_mask]
    movss [rsp+12], xmm0
    mov r12d, -1                        ; the target
    mov eax, [c_deauth_r]
    mov [rsp+16], eax                   ; nearest so far
    xor ebx, ebx
.f:
    cmp ebx, [fd_count]
    jge .picked
    cmp dword [fd_state+rbx*4], FD_DEAD
    je .n
    ; direction from your eye to its middle
    movss xmm0, [fd_x+rbx*4]
    subss xmm0, [p_x]
    movss xmm1, [fd_y+rbx*4]
    addss xmm1, [c_eye]
    subss xmm1, [p_eye_y]
    movss xmm2, [fd_z+rbx*4]
    subss xmm2, [p_z]
    movss [rsp+20], xmm0
    movss [rsp+24], xmm1
    movss [rsp+28], xmm2
    mulss xmm0, xmm0
    mulss xmm1, xmm1
    mulss xmm2, xmm2
    addss xmm0, xmm1
    addss xmm0, xmm2
    sqrtss xmm0, xmm0
    comiss xmm0, [rsp+16]
    jae .n
    movss [rsp+32], xmm0
    ; in your sights?
    movss xmm1, [rsp+20]
    mulss xmm1, [rsp+4]
    movss xmm2, [rsp+24]
    mulss xmm2, [rsp+8]
    addss xmm1, xmm2
    movss xmm2, [rsp+28]
    mulss xmm2, [rsp+12]
    addss xmm1, xmm2
    movss xmm2, [c_aim]
    mulss xmm2, xmm0
    comiss xmm1, xmm2
    jb .n
    ; ...and not behind a wall
    movss xmm0, [p_x]
    movss xmm1, [p_eye_y]
    movss xmm2, [p_z]
    movss xmm3, [fd_x+rbx*4]
    movss xmm4, [fd_y+rbx*4]
    addss xmm4, [c_eye]
    movss xmm5, [fd_z+rbx*4]
    call line_of_sight_3d
    test eax, eax
    jz .n
    mov r12d, ebx
    mov eax, [rsp+32]
    mov [rsp+16], eax
.n:
    inc ebx
    jmp .f
.picked:
    xor eax, eax
    cmp r12d, 0
    jl .done
    mov ebx, r12d
    mov dword [fd_state+rbx*4], FD_DEAD
    lea rdi, [m_killed]
    cmp dword [fd_carry+rbx*4], 0
    je .say
    call drop_capture
    lea rdi, [m_killed_c]
.say:
    mov esi, 0xFF8FE38F
    xor edx, edx
    call hud_message
    mov eax, 1
.done:
    EPILOGUE

; dist_to(ebx = i) -> xmm0 = 3D distance to you, xmm1 = flat, xmm2 = |dy|. leaf
dist_to:
    movss xmm0, [p_x]
    subss xmm0, [fd_x+rbx*4]
    mulss xmm0, xmm0
    movss xmm1, [p_z]
    subss xmm1, [fd_z+rbx*4]
    mulss xmm1, xmm1
    addss xmm1, xmm0
    movss xmm2, [p_y]
    subss xmm2, [fd_y+rbx*4]
    andps xmm2, [c_abs_mask]
    movaps xmm0, xmm2
    mulss xmm0, xmm0
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    sqrtss xmm1, xmm1
    ret

; new_goal(ebx = i) -- somewhere to wander to, or (fleeing) far from you
new_goal:
    PROLOGUE 16
    cmp dword [fd_state+rbx*4], FD_FLEE
    je .hide
    mov edi, -1
    xor esi, esi
    call random_node
    mov [fd_goal+rbx*4], eax
    EPILOGUE
.hide:
    call player_cell
    mov ecx, esi
    mov r8d, edx
    mov edx, eax
    mov edi, -1
    mov esi, 1
    mov r9d, [c_hide_away]
    call random_node
    mov [fd_goal+rbx*4], eax
    EPILOGUE

; feeders_update(xmm0 = dt)
feeders_update:
    PROLOGUE 48
    ; [rsp+0] dt  [rsp+4] 3D dist  [rsp+8] flat  [rsp+12] |dy|  [rsp+16] safe
    ; [rsp+20] step  [rsp+24..32] target  [rsp+36] sees
    movss [rsp+0], xmm0
    movss [fdt], xmm0
    cmp dword [fd_count], 0
    je .done
    movss xmm1, [fd_click]
    subss xmm1, xmm0
    movss [fd_click], xmm1
    call player_in_safe
    mov [rsp+16], eax
    xor ebx, ebx
.f:
    cmp ebx, [fd_count]
    jge .done
    cmp dword [fd_state+rbx*4], FD_DEAD
    je .next
    ; ---- timers
    movss xmm0, [fd_timer+rbx*4]
    subss xmm0, [rsp+0]
    maxss xmm0, [c_zero]
    movss [fd_timer+rbx*4], xmm0
    cmp dword [fd_state+rbx*4], FD_STUN
    jne .awake
    comiss xmm0, [c_zero]
    ja .next                            ; still twitching on the floor
    mov dword [fd_state+rbx*4], FD_WANDER
    mov eax, [fd_node+rbx*4]
    mov [fd_goal+rbx*4], eax
.awake:
    call dist_to
    movss [rsp+4], xmm0
    movss [rsp+8], xmm1
    movss [rsp+12], xmm2
    ; scuttling you can hear
    comiss xmm0, [c_click_r]
    jae .quiet
    movss xmm0, [fd_click]
    comiss xmm0, [c_zero]
    ja .quiet
    mov eax, [c_click_dt]
    mov [fd_click], eax
    call snd_feeder_click
.quiet:
    cmp dword [fd_state+rbx*4], FD_FLEE
    jne .hunt
    ; ---- running off with a capture: catch it and you get it back (once it
    ; has had its getaway moment)
    movss xmm0, [fd_timer+rbx*4]
    comiss xmm0, [c_zero]
    ja .move
    call close_enough
    test eax, eax
    jz .move
    mov dword [fd_carry+rbx*4], 0
    inc dword [inventory]
    call set_bonus
    mov dword [fd_state+rbx*4], FD_STUN
    mov eax, [c_daze]
    mov [fd_timer+rbx*4], eax
    call snd_pickup
    lea rdi, [msg_buf]
    mov esi, 160
    lea rdx, [m_snatched]
    mov ecx, [inventory]
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, 0xFF8FE38F
    xor edx, edx
    call hud_message
    mov edi, ACH_OUTFED
    call ach_unlock
    jmp .next
.hunt:
    ; ---- can it see you (and smell captures on you)?
    mov dword [rsp+36], 0
    cmp dword [inventory], 0
    je .looked
    cmp dword [rsp+16], 0
    jne .looked
    movss xmm0, [fd_timer+rbx*4]        ; calming down after a stash
    comiss xmm0, [c_zero]
    ja .looked
    movss xmm1, [c_sight]
    cmp dword [p_flash_on], 0
    je .range
    movss xmm1, [c_sight_lit]
.range:
    movss xmm0, [rsp+4]
    comiss xmm0, xmm1
    jae .looked
    movss xmm0, [fd_x+rbx*4]
    movss xmm1, [fd_y+rbx*4]
    addss xmm1, [c_eye]
    movss xmm2, [fd_z+rbx*4]
    movss xmm3, [p_x]
    movss xmm4, [p_eye_y]
    movss xmm5, [p_z]
    call line_of_sight_3d
    mov [rsp+36], eax
.looked:
    cmp dword [rsp+36], 0
    je .unseen
    cmp dword [fd_state+rbx*4], FD_CHASE
    je .chasing
    call snd_feeder_spot
    cmp dword [fd_warned], 0
    jne .chasing
    mov dword [fd_warned], 1
    lea rdi, [m_smell]
    mov esi, 0xFF47B3FF
    xor edx, edx
    call hud_message
.chasing:
    mov dword [fd_state+rbx*4], FD_CHASE
    mov dword [fd_lost+rbx*4], 0
    movss xmm0, [p_x]
    movss xmm1, [p_y]
    movss xmm2, [p_z]
    call node_at_pos
    mov r12d, eax
    mov edi, eax
    call node_walkable
    test eax, eax
    jz .contact
    mov [fd_goal+rbx*4], r12d
    jmp .contact
.unseen:
    cmp dword [fd_state+rbx*4], FD_CHASE
    jne .move
    movss xmm0, [fd_lost+rbx*4]
    addss xmm0, [rsp+0]
    movss [fd_lost+rbx*4], xmm0
    comiss xmm0, [c_lose]
    ja .give_up
    cmp dword [inventory], 0
    je .give_up
    cmp dword [rsp+16], 0
    je .contact
.give_up:
    mov dword [fd_state+rbx*4], FD_WANDER
    mov eax, [fd_node+rbx*4]
    mov [fd_goal+rbx*4], eax
    jmp .move
.contact:
    ; ---- got you: one capture, then run
    cmp dword [inventory], 0
    je .move
    cmp dword [rsp+16], 0
    jne .move
    call close_enough
    test eax, eax
    jz .move
    dec dword [inventory]
    call set_bonus
    mov dword [fd_carry+rbx*4], 1
    mov dword [fd_state+rbx*4], FD_FLEE
    mov eax, [c_getaway]
    mov [fd_timer+rbx*4], eax
    call new_goal
    movss xmm0, [c_noise_steal]
    call noise_add
    call snd_feeder_steal
    lea rdi, [msg_buf]
    mov esi, 160
    lea rdx, [m_stolen]
    mov ecx, [inventory]
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, 0xFF3B3BFF
    xor edx, edx
    call hud_message
.move:
    call move_feeder
.next:
    inc ebx
    jmp .f
.done:
    EPILOGUE

; close_enough(ebx = i) -> eax 1 if it's right at your feet
close_enough:
    sub rsp, 8
    call dist_to
    add rsp, 8
    xor eax, eax
    comiss xmm1, [c_grab]
    jae .no
    comiss xmm2, [c_grab_y]
    jae .no
    mov eax, 1
.no:
    ret

; move_feeder(ebx = i; dt in fdt) -- along the nav graph, a node
; at a time (a fresh route at every node, so a chase follows you)
move_feeder:
    PROLOGUE 48
    mov eax, [fd_node+rbx*4]
    cmp eax, [fd_next+rbx*4]
    jne .go
    ; standing on a node: arrived?
    cmp eax, [fd_goal+rbx*4]
    jne .route
    cmp dword [fd_state+rbx*4], FD_FLEE
    jne .arrived
    ; far enough away: hide it here
    call drop_capture
    mov dword [fd_state+rbx*4], FD_WANDER
    mov eax, [c_calm]
    mov [fd_timer+rbx*4], eax
    movss xmm0, [fd_y+rbx*4]
    call floor_of_height
    mov edi, eax
    call floor_name
    mov rcx, rax
    lea rdi, [msg_buf]
    mov esi, 160
    lea rdx, [m_stashed]
    xor eax, eax
    call snprintf
    lea rdi, [msg_buf]
    mov esi, 0xFF47B3FF
    xor edx, edx
    call hud_message
.arrived:
    cmp dword [fd_state+rbx*4], FD_CHASE
    je .done                            ; on your last known spot: wait
    call new_goal
.route:
    mov edi, [fd_node+rbx*4]
    mov esi, [fd_goal+rbx*4]
    call find_next
    cmp eax, -1
    jne .have_next
    call new_goal                       ; can't get there: pick elsewhere
    jmp .done
.have_next:
    mov [fd_next+rbx*4], eax
.go:
    mov edi, [fd_next+rbx*4]
    call node_center
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    subss xmm0, [fd_x+rbx*4]
    subss xmm1, [fd_y+rbx*4]
    subss xmm2, [fd_z+rbx*4]
    movss [rsp+12], xmm0
    movss [rsp+16], xmm1
    movss [rsp+20], xmm2
    mulss xmm0, xmm0
    mulss xmm1, xmm1
    mulss xmm2, xmm2
    addss xmm0, xmm1
    addss xmm0, xmm2
    sqrtss xmm0, xmm0
    movss [rsp+24], xmm0                ; how far to the node
    mov eax, [fd_state+rbx*4]
    movss xmm1, [fd_speeds+rax*4]
    mulss xmm1, [fdt]
    movss [rsp+28], xmm1                ; this frame's step
    ; legs
    movss xmm2, [fd_speeds+rax*4]
    mulss xmm2, [fdt]
    mulss xmm2, [c_anim]
    addss xmm2, [fd_anim+rbx*4]
    movss [fd_anim+rbx*4], xmm2
    comiss xmm1, xmm0
    jb .part
    ; reached it
    mov eax, [rsp+0]
    mov [fd_x+rbx*4], eax
    mov eax, [rsp+4]
    mov [fd_y+rbx*4], eax
    mov eax, [rsp+8]
    mov [fd_z+rbx*4], eax
    mov eax, [fd_next+rbx*4]
    mov [fd_node+rbx*4], eax
    jmp .face
.part:
    divss xmm1, xmm0
    movss xmm0, [rsp+12]
    mulss xmm0, xmm1
    addss xmm0, [fd_x+rbx*4]
    movss [fd_x+rbx*4], xmm0
    movss xmm0, [rsp+16]
    mulss xmm0, xmm1
    addss xmm0, [fd_y+rbx*4]
    movss [fd_y+rbx*4], xmm0
    movss xmm0, [rsp+20]
    mulss xmm0, xmm1
    addss xmm0, [fd_z+rbx*4]
    movss [fd_z+rbx*4], xmm0
.face:
    ; face where it's going (flat)
    movss xmm0, [rsp+12]
    movss xmm1, [rsp+20]
    movaps xmm2, xmm0
    mulss xmm2, xmm2
    movaps xmm3, xmm1
    mulss xmm3, xmm3
    addss xmm2, xmm3
    FLD xmm3, 0.0001
    comiss xmm2, xmm3
    jb .done
    call atan2f
    movss [fd_yaw+rbx*4], xmm0
.done:
    EPILOGUE

; feeder_put(edi = i, esi = node) -- (self-tests) put feeder i there, wandering
feeder_put:
    PROLOGUE 16
    mov ebx, edi
    mov edi, esi
    call place
    mov dword [fd_state+rbx*4], FD_WANDER
    mov dword [fd_timer+rbx*4], 0
    mov dword [fd_carry+rbx*4], 0
    EPILOGUE
