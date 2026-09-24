; =============================================================================
; audio.asm -- a tiny software synthesizer. No sound files: everything is
; generated sample by sample in SDL's audio callback (stereo float, 44.1kHz).
;
; Always playing:
;   * HVAC rumble   brown noise through a low-pass filter
;   * rain          band-limited white noise (quieter in the basement)
;   * drone         three beating sine waves (55, 58.3, 110.7 Hz)
;   * T's hum       three detuned saw waves, low-passed, panned left/right
;                   toward T and attenuated with distance
; One-shots (32 voices): filtered noise bursts (footsteps, thuds, creaks,
; thunder) and oscillators with pitch sweeps (heartbeat, chimes, stingers).
;
; The callback runs on SDL's audio thread; the main thread only touches
; voices while holding SDL_LockAudioDevice.
; =============================================================================
%define MODULE_AUDIO
%include "common.inc"

global audio_init, snd_footstep, snd_tstep, snd_heartbeat, snd_pickup, snd_deauth
global snd_noise_alert, snd_spotted, snd_thunder, snd_jumpscare, snd_win, snd_set_t
global snd_set_floor, snd_mute, audio_cb, snd_fanfare, snd_clatter, snd_clank, snd_zip
global snd_portal_open, snd_portal_fizzle, snd_portal_enter, snd_slide
%ifdef WIN64
extern audio_cb_win64
%endif

%define RATE      44100
%define NVOICE    32
%define SINE_N    1024
%define AUDIO_F32 0x8120

; voice record (80 bytes)
%define V_ACTIVE   0          ; dword
%define V_KIND     4          ; 0 = noise burst, 1 = oscillator
%define V_WAVE     8          ; 0 sine 1 triangle 2 saw 3 square
%define V_INC      12         ; float: phase increment per sample (freq/RATE)
%define V_SWEEP    16         ; float: multiply V_INC by this each sample
%define V_PHASE    20         ; float 0..1
%define V_ENV      24         ; float current amplitude
%define V_DECAY    28         ; float per-sample decay multiplier
%define V_ATTACK   32         ; int samples of attack left
%define V_ATK_INC  36         ; float amplitude added per attack sample
%define V_DELAY    40         ; int samples before it starts
%define V_LIFE     44         ; int samples left
%define V_POS      48         ; dword 1 = comes from T's position
%define V_F        52         ; float SVF coefficient 2*sin(pi*fc/RATE)
%define V_DAMP     56         ; float SVF damping (1/Q)
%define V_FTYPE    60         ; 0 low-pass 1 band-pass 2 high-pass
%define V_LOW      64
%define V_BAND     68
%define V_GAIN     72
%define V_SIZE     80

%define FT_LP 0
%define FT_BP 1
%define FT_HP 2
%define W_SINE 0
%define W_TRI  1
%define W_SAW  2
%define W_SQR  3

section .data
drone_freq  dd 55.0, 58.3, 110.7
hum_freq    dd 41.0, 43.5, 82.2
c_rate      dd 44100.0
c_inv_rate  dd 2.2675737e-05
c_sine_n    dd 1024.0
c_noise_k   dd 4.656612873e-10
c_brown_a   dd 0.02
c_brown_d   dd 1.02
c_brown_amp dd 3.5
c_rumble_k  dd 0.025
c_rain1_k   dd 0.192
c_rain2_k   dd 0.575
c_hum_k     dd 0.058
c_drone_amp dd 0.035
c_smooth    dd 0.00005
c_hum_smooth dd 0.0001
c_log_floor dd -9.2103              ; ln(0.0001)
c_pos_boost dd 1.5
c_f080      dd 0.6              ; SVF stays stable for f < 2 - damping
c_f033      dd 0.33
c_f2        dd 2.0
c_f4        dd 4.0
c_limit     dd 0.98
c_neg_limit dd -0.98
c_mult_a    dd 1664525
c_attack_tone dd 0.01
c_vol_k     dd 0.9

section .bss
alignb 16
voices      resb V_SIZE*NVOICE
sine_tab    resd SINE_N
spec_want   resb 32
spec_have   resb 32
dev_id      resd 1
noise_seed  resd 1
brown       resd 1
rumble      resd 1
rain1       resd 1
rain2       resd 1
hum_lp      resd 1
drone_ph    resd 3
hum_ph      resd 3
amb_target  resd 1
amb_cur     resd 1
rain_target resd 1
rain_cur    resd 1
hum_target  resd 1
hum_cur     resd 1
master_target resd 1
master_cur  resd 1
t_gl        resd 1                  ; left/right gains toward T
t_gr        resd 1
t_att       resd 1                  ; distance attenuation
; parameters for the next voice (filled by burst/tone, then committed)
nv          resb V_SIZE

section .text

; =============================================================================
; the audio thread
; =============================================================================

; white noise in xmm0 (-1..1), LCG. leaf; clobbers eax.
noise:
    mov eax, [noise_seed]
    imul eax, eax, 1664525
    add eax, 1013904223
    mov [noise_seed], eax
    cvtsi2ss xmm0, eax
    mulss xmm0, [c_noise_k]
    ret

; audio_cb(rdi=userdata, rsi=stream, edx=bytes) -- fill the buffer
audio_cb:
    PROLOGUE 32
    mov r12, rsi                        ; output pointer
    mov r13d, edx
    shr r13d, 3                         ; stereo float frames
.frame:
    test r13d, r13d
    jz .done
    dec r13d
    ; ---- smoothing of the ambient levels
    movss xmm0, [amb_target]
    subss xmm0, [amb_cur]
    mulss xmm0, [c_smooth]
    addss xmm0, [amb_cur]
    movss [amb_cur], xmm0
    movss xmm0, [rain_target]
    subss xmm0, [rain_cur]
    mulss xmm0, [c_smooth]
    addss xmm0, [rain_cur]
    movss [rain_cur], xmm0
    movss xmm0, [hum_target]
    subss xmm0, [hum_cur]
    mulss xmm0, [c_hum_smooth]
    addss xmm0, [hum_cur]
    movss [hum_cur], xmm0
    movss xmm0, [master_target]
    subss xmm0, [master_cur]
    mulss xmm0, [c_smooth]
    addss xmm0, [master_cur]
    movss [master_cur], xmm0

    ; ---- rumble: brown noise, low-passed
    call noise
    movss xmm8, xmm0                    ; keep this sample's white noise
    mulss xmm0, [c_brown_a]
    addss xmm0, [brown]
    divss xmm0, [c_brown_d]
    movss [brown], xmm0
    mulss xmm0, [c_brown_amp]
    subss xmm0, [rumble]
    mulss xmm0, [c_rumble_k]
    addss xmm0, [rumble]
    movss [rumble], xmm0
    mulss xmm0, [amb_cur]
    movaps xmm9, xmm0                   ; xmm9 = centre mix

    ; ---- rain: difference of two low-passes = a band of hiss
    movss xmm0, xmm8
    subss xmm0, [rain1]
    mulss xmm0, [c_rain1_k]
    addss xmm0, [rain1]
    movss [rain1], xmm0
    movss xmm1, xmm8
    subss xmm1, [rain2]
    mulss xmm1, [c_rain2_k]
    addss xmm1, [rain2]
    movss [rain2], xmm1
    subss xmm1, xmm0
    mulss xmm1, [rain_cur]
    addss xmm9, xmm1

    ; ---- drone: three sines from the table
    xorps xmm2, xmm2
    xor ecx, ecx
.drone:
    cmp ecx, 3
    jge .drone_done
    movss xmm0, [drone_freq+rcx*4]
    mulss xmm0, [c_inv_rate]
    addss xmm0, [drone_ph+rcx*4]
    comiss xmm0, [c_one]
    jb .dw
    subss xmm0, [c_one]
.dw:
    movss [drone_ph+rcx*4], xmm0
    mulss xmm0, [c_sine_n]
    cvttss2si eax, xmm0
    and eax, SINE_N-1
    addss xmm2, [sine_tab+rax*4]
    inc ecx
    jmp .drone
.drone_done:
    mulss xmm2, [c_drone_amp]
    addss xmm9, xmm2

    ; ---- T's hum: saws, low-passed, panned
    xorps xmm2, xmm2
    xor ecx, ecx
.hum:
    cmp ecx, 3
    jge .hum_done
    movss xmm0, [hum_freq+rcx*4]
    mulss xmm0, [c_inv_rate]
    addss xmm0, [hum_ph+rcx*4]
    comiss xmm0, [c_one]
    jb .hw
    subss xmm0, [c_one]
.hw:
    movss [hum_ph+rcx*4], xmm0
    addss xmm0, xmm0
    subss xmm0, [c_one]
    addss xmm2, xmm0
    inc ecx
    jmp .hum
.hum_done:
    subss xmm2, [hum_lp]
    mulss xmm2, [c_hum_k]
    addss xmm2, [hum_lp]
    movss [hum_lp], xmm2
    mulss xmm2, [hum_cur]
    mulss xmm2, [t_att]
    movaps xmm10, xmm9                  ; L
    movaps xmm11, xmm9                  ; R
    movaps xmm3, xmm2
    mulss xmm3, [t_gl]
    addss xmm10, xmm3
    mulss xmm2, [t_gr]
    addss xmm11, xmm2

    ; ---- one-shot voices
    lea rbx, [voices]
    mov r14d, NVOICE
.voice:
    test r14d, r14d
    jz .voices_done
    dec r14d
    cmp dword [rbx+V_ACTIVE], 0
    je .nv
    cmp dword [rbx+V_DELAY], 0
    jle .run
    dec dword [rbx+V_DELAY]
    jmp .nv
.run:
    cmp dword [rbx+V_KIND], 0
    jne .osc
    ; noise through a state-variable filter
    call noise
    movss xmm1, [rbx+V_LOW]
    movss xmm2, [rbx+V_BAND]
    movss xmm3, [rbx+V_F]
    ; low += f*band
    movaps xmm4, xmm2
    mulss xmm4, xmm3
    addss xmm1, xmm4
    ; high = in - low - damp*band
    movaps xmm5, xmm0
    subss xmm5, xmm1
    movaps xmm4, xmm2
    mulss xmm4, [rbx+V_DAMP]
    subss xmm5, xmm4
    ; band += f*high
    movaps xmm4, xmm5
    mulss xmm4, xmm3
    addss xmm2, xmm4
    movss [rbx+V_LOW], xmm1
    movss [rbx+V_BAND], xmm2
    movaps xmm0, xmm1                   ; low-pass
    cmp dword [rbx+V_FTYPE], FT_BP
    jne .not_bp
    movaps xmm0, xmm2
.not_bp:
    cmp dword [rbx+V_FTYPE], FT_HP
    jne .env
    movaps xmm0, xmm5
    jmp .env
.osc:
    movss xmm0, [rbx+V_PHASE]
    addss xmm0, [rbx+V_INC]
    comiss xmm0, [c_one]
    jb .ow
    subss xmm0, [c_one]
.ow:
    movss [rbx+V_PHASE], xmm0
    movss xmm1, [rbx+V_INC]
    mulss xmm1, [rbx+V_SWEEP]
    movss [rbx+V_INC], xmm1
    mov eax, [rbx+V_WAVE]
    cmp eax, W_SINE
    jne .tri
    mulss xmm0, [c_sine_n]
    cvttss2si eax, xmm0
    and eax, SINE_N-1
    movss xmm0, [sine_tab+rax*4]
    jmp .env
.tri:
    cmp eax, W_TRI
    jne .saw
    subss xmm0, [c_half]
    andps xmm0, [c_abs_mask]
    mulss xmm0, [c_f4]
    movss xmm1, [c_one]
    subss xmm1, xmm0
    movaps xmm0, xmm1
    jmp .env
.saw:
    cmp eax, W_SAW
    jne .sqr
    addss xmm0, xmm0
    subss xmm0, [c_one]
    jmp .env
.sqr:
    comiss xmm0, [c_half]
    movss xmm0, [c_one]
    jb .env
    movss xmm0, [c_neg_one]
.env:
    ; attack ramp, then exponential decay
    movss xmm1, [rbx+V_ENV]
    cmp dword [rbx+V_ATTACK], 0
    jle .decay
    dec dword [rbx+V_ATTACK]
    addss xmm1, [rbx+V_ATK_INC]
    jmp .env_set
.decay:
    mulss xmm1, [rbx+V_DECAY]
.env_set:
    movss [rbx+V_ENV], xmm1
    mulss xmm0, xmm1
    dec dword [rbx+V_LIFE]
    jg .alive
    mov dword [rbx+V_ACTIVE], 0
.alive:
    cmp dword [rbx+V_POS], 0
    je .centre
    mulss xmm0, [t_att]
    mulss xmm0, [c_pos_boost]
    movaps xmm1, xmm0
    mulss xmm1, [t_gl]
    addss xmm10, xmm1
    mulss xmm0, [t_gr]
    addss xmm11, xmm0
    jmp .nv
.centre:
    addss xmm10, xmm0
    addss xmm11, xmm0
.nv:
    add rbx, V_SIZE
    jmp .voice
.voices_done:
    ; master volume + hard limit
    mulss xmm10, [master_cur]
    mulss xmm11, [master_cur]
    minss xmm10, [c_limit]
    maxss xmm10, [c_neg_limit]
    minss xmm11, [c_limit]
    maxss xmm11, [c_neg_limit]
    movss [r12], xmm10
    movss [r12+4], xmm11
    add r12, 8
    jmp .frame
.done:
    EPILOGUE

; =============================================================================
; main-thread side
; =============================================================================

; audio_init() -- open the device (silently carries on if there is no audio)
audio_init:
    PROLOGUE 16
    ; sine table
    xor ebx, ebx
.sine:
    cmp ebx, SINE_N
    jge .sine_done
    cvtsi2ss xmm0, ebx
    mulss xmm0, [c_two_pi]
    divss xmm0, [c_sine_n]
    call sinf
    movss [sine_tab+rbx*4], xmm0
    inc ebx
    jmp .sine
.sine_done:
    mov dword [noise_seed], 22222
    mov dword [amb_target], __float32__(0.16)
    mov dword [rain_target], __float32__(0.05)
    mov dword [master_target], __float32__(0.9)
    mov dword [t_gl], __float32__(0.7)
    mov dword [t_gr], __float32__(0.7)
    ; SDL_AudioSpec: freq, format, channels, silence, samples, pad, size, callback, userdata
    lea rdi, [spec_want]
    mov dword [rdi+0], RATE
    mov word [rdi+4], AUDIO_F32
    mov byte [rdi+6], 2
    mov word [rdi+8], 1024
%ifdef WIN64
    lea rax, [audio_cb_win64]           ; SDL calls it the Microsoft way
%else
    lea rax, [audio_cb]
%endif
    mov [rdi+16], rax
    mov qword [rdi+24], 0
    xor edi, edi
    xor esi, esi
    lea rdx, [spec_want]
    lea rcx, [spec_have]
    xor r8d, r8d                        ; no changes allowed: we need f32 stereo
    call SDL_OpenAudioDevice
    mov [dev_id], eax
    test eax, eax
    jz .no_audio
    mov edi, eax
    xor esi, esi
    call SDL_PauseAudioDevice           ; start playing
.no_audio:
    EPILOGUE

; commit_voice() -- copy nv into a free voice slot (or steal slot 0)
commit_voice:
    PROLOGUE 16
    cmp dword [dev_id], 0
    je .out
    mov edi, [dev_id]
    call SDL_LockAudioDevice
    lea rbx, [voices]
    mov ecx, NVOICE
.find:
    cmp dword [rbx+V_ACTIVE], 0
    je .found
    add rbx, V_SIZE
    loop .find
    lea rbx, [voices]
.found:
    mov rdi, rbx
    lea rsi, [nv]
    mov edx, V_SIZE
    call memcpy
    mov dword [rbx+V_ACTIVE], 1
    mov edi, [dev_id]
    call SDL_UnlockAudioDevice
.out:
    EPILOGUE

; set_env(xmm0=duration s, xmm1=peak gain, xmm2=attack s, xmm3=delay s)
; fills the envelope/timing fields of nv
set_env:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    mulss xmm3, [c_rate]
    cvttss2si eax, xmm3
    mov [nv+V_DELAY], eax
    ; attack samples (at least 1)
    movss xmm0, [rsp+8]
    mulss xmm0, [c_rate]
    cvttss2si eax, xmm0
    cmp eax, 1
    jge .a
    mov eax, 1
.a:
    mov [nv+V_ATTACK], eax
    cvtsi2ss xmm0, eax
    movss xmm1, [rsp+4]
    divss xmm1, xmm0
    movss [nv+V_ATK_INC], xmm1
    mov dword [nv+V_ENV], 0
    movss xmm0, [rsp+4]
    movss [nv+V_GAIN], xmm0
    ; decay: reach -80dB at the end of the duration
    movss xmm0, [rsp+0]
    mulss xmm0, [c_rate]
    movss [rsp+12], xmm0
    cvttss2si eax, xmm0
    add eax, [nv+V_ATTACK]
    mov [nv+V_LIFE], eax
    movss xmm0, [c_log_floor]
    divss xmm0, [rsp+12]
    call expf
    movss [nv+V_DECAY], xmm0
    EPILOGUE

; burst(xmm0=cutoff Hz, xmm1=damping, xmm2=duration, xmm3=gain,
;       edi=filter type, esi=positional?, xmm4=delay, xmm5=attack)
burst:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    movss [rsp+16], xmm4
    movss [rsp+20], xmm5
    mov [rsp+24], edi
    mov [rsp+28], esi
    lea rdi, [nv]
    xor esi, esi
    mov edx, V_SIZE
    call memset
    mov dword [nv+V_KIND], 0
    mov eax, [rsp+24]
    mov [nv+V_FTYPE], eax
    mov eax, [rsp+28]
    mov [nv+V_POS], eax
    movss xmm0, [rsp+4]
    movss [nv+V_DAMP], xmm0
    ; f = 2*sin(pi*fc/RATE), capped for stability
    movss xmm0, [rsp+0]
    mulss xmm0, [c_pi]
    mulss xmm0, [c_inv_rate]
    call sinf
    addss xmm0, xmm0
    minss xmm0, [c_f080]
    movss [nv+V_F], xmm0
    movss xmm0, [rsp+8]
    movss xmm1, [rsp+12]
    movss xmm2, [rsp+20]
    movss xmm3, [rsp+16]
    call set_env
    call commit_voice
    EPILOGUE

; tone(xmm0=start Hz, xmm1=end Hz, xmm2=duration, xmm3=gain, edi=wave, xmm4=delay)
tone:
    PROLOGUE 32
    movss [rsp+0], xmm0
    movss [rsp+4], xmm1
    movss [rsp+8], xmm2
    movss [rsp+12], xmm3
    movss [rsp+16], xmm4
    mov [rsp+20], edi
    lea rdi, [nv]
    xor esi, esi
    mov edx, V_SIZE
    call memset
    mov dword [nv+V_KIND], 1
    mov eax, [rsp+20]
    mov [nv+V_WAVE], eax
    movss xmm0, [rsp+0]
    mulss xmm0, [c_inv_rate]
    movss [nv+V_INC], xmm0
    ; sweep = exp(ln(f1/f0) / samples)
    movss xmm0, [rsp+4]
    divss xmm0, [rsp+0]
    call logf
    movss xmm1, [rsp+8]
    mulss xmm1, [c_rate]
    divss xmm0, xmm1
    call expf
    movss [nv+V_SWEEP], xmm0
    movss xmm0, [rsp+8]
    movss xmm1, [rsp+12]
    movss xmm2, [c_attack_tone]
    movss xmm3, [rsp+16]
    call set_env
    call commit_voice
    EPILOGUE

; ---- the sound effects (ports of audio.js) -----------------------------------
%macro BURST 8     ; cutoff, damping, dur, gain, ftype, positional, delay, attack
    FLD xmm0, %1
    FLD xmm1, %2
    FLD xmm2, %3
    FLD xmm3, %4
    mov edi, %5
    mov esi, %6
    FLD xmm4, %7
    FLD xmm5, %8
    call burst
%endmacro
%macro TONE 6      ; f0, f1, dur, gain, wave, delay
    FLD xmm0, %1
    FLD xmm1, %2
    FLD xmm2, %3
    FLD xmm3, %4
    mov edi, %5
    FLD xmm4, %6
    call tone
%endmacro

; snd_footstep(edi=loud?) -- scuff + click
snd_footstep:
    PROLOGUE 16
    mov ebx, edi
    call rand01
    FLD xmm1, 80.0
    mulss xmm0, xmm1
    FLD xmm1, 170.0
    addss xmm0, xmm1
    FLD xmm1, 0.8
    FLD xmm2, 0.08
    FLD xmm3, 0.22
    test ebx, ebx
    jz .q
    FLD xmm2, 0.12
    FLD xmm3, 0.5
.q:
    mov edi, FT_BP
    xor esi, esi
    xorps xmm4, xmm4
    xorps xmm5, xmm5
    call burst
    FLD xmm3, 0.03
    test ebx, ebx
    jz .q2
    FLD xmm3, 0.08
.q2:
    FLD xmm0, 2200.0
    FLD xmm1, 0.5
    FLD xmm2, 0.03
    mov edi, FT_BP
    xor esi, esi
    xorps xmm4, xmm4
    xorps xmm5, xmm5
    call burst
    EPILOGUE

; T's heavy footstep, from where he is
snd_tstep:
    PROLOGUE 16
    BURST 110.0, 0.7, 0.18, 1.2, FT_LP, 1, 0.0, 0.0
    BURST 900.0, 0.33, 0.05, 0.25, FT_BP, 1, 0.0, 0.0
    EPILOGUE

; snd_heartbeat(xmm0=strength 0..1) -- lub-dub
snd_heartbeat:
    PROLOGUE 16
    movss [rsp+0], xmm0
    FLD xmm0, 58.0
    FLD xmm1, 40.0
    FLD xmm2, 0.14
    FLD xmm3, 0.5
    mulss xmm3, [rsp+0]
    mov edi, W_SINE
    xorps xmm4, xmm4
    call tone
    FLD xmm0, 52.0
    FLD xmm1, 36.0
    FLD xmm2, 0.16
    FLD xmm3, 0.35
    mulss xmm3, [rsp+0]
    mov edi, W_SINE
    FLD xmm4, 0.22
    call tone
    EPILOGUE

snd_pickup:
    PROLOGUE 16
    TONE 660.0, 660.0, 0.25, 0.15, W_TRI, 0.0
    TONE 880.0, 880.0, 0.25, 0.15, W_TRI, 0.08
    TONE 1320.0, 1320.0, 0.25, 0.15, W_TRI, 0.16
    EPILOGUE

snd_deauth:
    PROLOGUE 16
    TONE 1800.0, 60.0, 0.6, 0.2, W_SAW, 0.0
    TONE 90.0, 30.0, 0.8, 0.12, W_SQR, 0.0
    BURST 3000.0, 1.2, 0.6, 0.3, FT_BP, 0, 0.0, 0.0
    EPILOGUE

; a floorboard / door creak -- "shh! You made a noise!"
snd_noise_alert:
    PROLOGUE 16
    TONE 210.0, 140.0, 0.5, 0.08, W_SAW, 0.0
    BURST 600.0, 0.125, 0.4, 0.25, FT_BP, 0, 0.0, 0.0
    EPILOGUE

; the stinger when T sees you
snd_spotted:
    PROLOGUE 16
    TONE 880.0, 830.0, 0.9, 0.12, W_SAW, 0.0
    TONE 932.0, 880.0, 0.9, 0.12, W_SAW, 0.0
    BURST 5000.0, 1.0, 0.5, 0.2, FT_HP, 0, 0.0, 0.0
    EPILOGUE

snd_thunder:
    PROLOGUE 16
    call rand01
    FLD xmm1, 0.8
    mulss xmm0, xmm1
    FLD xmm1, 0.3
    addss xmm0, xmm1
    movaps xmm4, xmm0
    FLD xmm0, 300.0
    FLD xmm1, 1.0
    FLD xmm2, 3.8
    FLD xmm3, 1.4
    mov edi, FT_LP
    xor esi, esi
    FLD xmm5, 0.25
    call burst
    EPILOGUE

snd_jumpscare:
    PROLOGUE 16
    TONE 220.0, 110.0, 1.6, 0.3, W_SAW, 0.0
    TONE 233.0, 116.5, 1.6, 0.3, W_SAW, 0.0
    TONE 311.0, 155.5, 1.6, 0.3, W_SAW, 0.0
    TONE 466.0, 233.0, 1.6, 0.3, W_SAW, 0.0
    BURST 1500.0, 1.2, 1.6, 1.2, FT_BP, 0, 0.0, 0.0
    EPILOGUE

; snd_clatter(edi=0 cardboard box / 1 plastic sign) -- something fell over
snd_clatter:
    PROLOGUE 16
    test edi, edi
    jnz .plastic
    BURST 160.0, 0.9, 0.25, 0.7, FT_LP, 0, 0.0, 0.0
    BURST 700.0, 1.0, 0.08, 0.15, FT_BP, 0, 0.0, 0.0
    EPILOGUE
.plastic:
    BURST 1300.0, 0.6, 0.07, 0.35, FT_BP, 0, 0.0, 0.0
    BURST 420.0, 0.8, 0.12, 0.3, FT_BP, 0, 0.03, 0.0
    EPILOGUE

; a ladder rung under your hand/foot: metallic ping + thud
snd_clank:
    PROLOGUE 16
    TONE 1850.0, 1800.0, 0.18, 0.05, W_TRI, 0.0
    TONE 2710.0, 2650.0, 0.12, 0.03, W_TRI, 0.0
    BURST 300.0, 0.8, 0.07, 0.25, FT_BP, 0, 0.0, 0.0
    EPILOGUE

; snd_zip(xmm0=speed) -- one grain of the trolley whirring along the cable
snd_zip:
    PROLOGUE 16
    FLD xmm1, 90.0
    mulss xmm0, xmm1
    FLD xmm1, 300.0
    addss xmm0, xmm1                    ; pitch rises with speed
    FLD xmm1, 0.35
    FLD xmm2, 0.09
    FLD xmm3, 0.12
    mov edi, FT_BP
    xor esi, esi
    xorps xmm4, xmm4
    FLD xmm5, 0.02
    call burst
    EPILOGUE

; snd_portal_open(edi=0 blue / 1 orange) -- a rising "vwoom", orange a fifth higher
snd_portal_open:
    PROLOGUE 16
    test edi, edi
    jnz .orange
    TONE 180.0, 520.0, 0.35, 0.14, W_SAW, 0.0
    TONE 360.0, 1040.0, 0.3, 0.05, W_SINE, 0.0
    jmp .air
.orange:
    TONE 270.0, 780.0, 0.35, 0.14, W_SAW, 0.0
    TONE 540.0, 1560.0, 0.3, 0.05, W_SINE, 0.0
.air:
    BURST 2400.0, 0.9, 0.25, 0.18, FT_BP, 0, 0.0, 0.02
    EPILOGUE

; the shot hit something portals won't stick to
snd_portal_fizzle:
    PROLOGUE 16
    TONE 600.0, 90.0, 0.25, 0.1, W_SQR, 0.0
    BURST 5000.0, 1.0, 0.2, 0.15, FT_HP, 0, 0.0, 0.0
    EPILOGUE

; stepping through: a low whoosh with a bright tail
snd_portal_enter:
    PROLOGUE 16
    BURST 350.0, 0.7, 0.45, 0.45, FT_BP, 0, 0.0, 0.05
    TONE 900.0, 300.0, 0.4, 0.07, W_SINE, 0.0
    EPILOGUE

; a slide: shoes and jeans scraping along the floor
snd_slide:
    PROLOGUE 16
    BURST 700.0, 0.9, 0.55, 0.35, FT_BP, 0, 0.0, 0.03
    BURST 2600.0, 1.1, 0.35, 0.12, FT_BP, 0, 0.05, 0.02
    EPILOGUE

; the "you found a dungeon item" fanfare
snd_fanfare:
    PROLOGUE 16
    TONE 392.0, 392.0, 0.18, 0.13, W_SQR, 0.0
    TONE 523.2, 523.2, 0.18, 0.13, W_SQR, 0.12
    TONE 659.3, 659.3, 0.18, 0.13, W_SQR, 0.24
    TONE 784.0, 784.0, 0.9, 0.13, W_SQR, 0.36
    TONE 1046.5, 1046.5, 0.9, 0.08, W_TRI, 0.36
    EPILOGUE

snd_win:
    PROLOGUE 16
    TONE 261.6, 261.6, 2.5, 0.12, W_TRI, 0.0
    TONE 329.6, 329.6, 2.5, 0.12, W_TRI, 0.15
    TONE 392.0, 392.0, 2.5, 0.12, W_TRI, 0.3
    TONE 523.2, 523.2, 2.5, 0.12, W_TRI, 0.45
    EPILOGUE

; snd_set_t(xmm0=pan -1..1, xmm1=distance attenuation 0..1, xmm2=hum level)
snd_set_t:
    PROLOGUE 16
    movss [rsp+0], xmm0
    movss [t_att], xmm1
    movss [hum_target], xmm2
    ; equal-power pan
    movss xmm0, [c_one]
    subss xmm0, [rsp+0]
    mulss xmm0, [c_half]
    sqrtss xmm0, xmm0
    movss [t_gl], xmm0
    movss xmm0, [c_one]
    addss xmm0, [rsp+0]
    mulss xmm0, [c_half]
    sqrtss xmm0, xmm0
    movss [t_gr], xmm0
    EPILOGUE

; snd_set_floor(edi=storey) -- the basement is quieter (no rain) but rumbles
snd_set_floor:
    mov dword [rain_target], __float32__(0.05)
    mov dword [amb_target], __float32__(0.16)
    cmp edi, 0
    jne .up
    mov dword [rain_target], __float32__(0.008)
    mov dword [amb_target], __float32__(0.3)
    ret
.up:
    cmp edi, 2
    jne .done
    mov dword [rain_target], __float32__(0.07)
.done:
    ret

; snd_mute(edi=1 mute / 0 unmute) -- used while paused
snd_mute:
    PCT xmm0, cfg_volume
    mulss xmm0, [c_vol_k]
    movss [master_target], xmm0
    test edi, edi
    jz .done
    mov dword [master_target], 0
.done:
    ret
