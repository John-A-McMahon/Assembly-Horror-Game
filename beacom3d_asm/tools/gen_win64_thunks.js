// Generates win64_thunks.asm + win64_names.inc for the Windows build.
//
// The game's assembly always calls functions the System V way (Linux):
//   integer/pointer args in rdi, rsi, rdx, rcx, r8, r9, then the stack
//   float/double args in xmm0..xmm7 (counted separately), then the stack
// Windows x64 uses a different convention:
//   the first four arguments by POSITION in rcx/rdx/r8/r9 or xmm0..xmm3,
//   the rest on the stack after a 32-byte "shadow space".
// For every external function we emit a thunk `sv_NAME` that shuffles the
// arguments from one layout to the other and calls the real NAME, and a
// `%define NAME sv_NAME` so the game code transparently calls the thunk.
//
// Usage: node tools/gen_win64_thunks.js   (run from beacom3d_asm/)
//
// Signature letters: i = int/pointer, f = float, d = double,
//                    V = printf-style varargs (up to 6 integer/pointer args)
const fs = require("fs");

const SIGS = {
  // C library
  scanf: "V", puts: "i", putchar: "i", getchar: "",
  system: "i", fopen: "ii", fread: "iiii", fgetc: "i", fclose: "i", fflush: "i", fwrite: "iiii",
  exit: "i", time: "i", getenv: "i", strstr: "ii", strlen: "i",
  memset: "iii", memcpy: "iii",
  sinf: "f", cosf: "f", sqrtf: "f", expf: "f", logf: "f", tanf: "f",
  powf: "ff", atan2f: "ff",
  // Windows console
  GetStdHandle: "i", GetConsoleMode: "ii", SetConsoleMode: "ii",
  // SDL2
  SDL_Init: "i", SDL_Quit: "", SDL_CreateWindow: "iiiiii", SDL_DestroyWindow: "i",
  SDL_GL_SetAttribute: "ii", SDL_GL_CreateContext: "i", SDL_GL_SwapWindow: "i",
  SDL_GL_SetSwapInterval: "i", SDL_GL_GetProcAddress: "i", SDL_PollEvent: "i",
  SDL_GetKeyboardState: "i", SDL_SetRelativeMouseMode: "i",
  SDL_GetPerformanceCounter: "", SDL_GetPerformanceFrequency: "", SDL_Delay: "i",
  SDL_GetError: "", SDL_ShowWindow: "i", SDL_HideWindow: "i", SDL_GetWindowSize: "iii",
  SDL_ConvertSurfaceFormat: "iii", SDL_FreeSurface: "i",
  SDL_CreateRGBSurfaceWithFormat: "iiiii", SDL_UpperBlit: "iiii", SDL_FillRect: "iii",
  SDL_SetWindowTitle: "ii", SDL_RaiseWindow: "i", SDL_SetWindowGrab: "ii",
  SDL_OpenAudioDevice: "iiiii", SDL_PauseAudioDevice: "ii", SDL_LockAudioDevice: "i",
  SDL_UnlockAudioDevice: "i", SDL_SaveBMP_RW: "iii", SDL_RWFromFile: "ii",
  SDL_GetTicks: "", SDL_WarpMouseInWindow: "iii", SDL_ShowCursor: "i", SDL_SetHint: "ii",
  IMG_Init: "i", IMG_Load: "i",
  TTF_Init: "", TTF_OpenFont: "ii", TTF_RenderUTF8_Blended: "iii",
  TTF_RenderUTF8_Blended_Wrapped: "iiii",
  // OpenGL 1.x (exported by opengl32.dll)
  glClear: "i", glClearColor: "ffff", glEnable: "i", glDisable: "i", glBlendFunc: "ii",
  glViewport: "iiii", glMatrixMode: "i", glLoadIdentity: "",
  glFrustum: "dddddd", glOrtho: "dddddd", glRotatef: "ffff", glTranslatef: "fff",
  glBegin: "i", glEnd: "", glVertex3f: "fff", glVertex2f: "ff", glNormal3f: "fff",
  glTexCoord2f: "ff", glColor4f: "ffff", glColor3f: "fff",
  glGenTextures: "ii", glBindTexture: "ii", glTexImage2D: "iiiiiiiii",
  glTexParameteri: "iii", glPixelStorei: "ii", glGenLists: "i", glNewList: "ii",
  glEndList: "", glCallList: "i", glFogi: "ii", glFogf: "if", glFogfv: "ii",
  glDeleteTextures: "ii", glDepthMask: "i", glAlphaFunc: "if", glReadPixels: "iiiiiii",
  glFinish: "", glGetError: "", glPushMatrix: "", glPopMatrix: "", glMultMatrixf: "i",
  glDeleteLists: "ii", glCopyTexSubImage2D: "iiiiiiii", glGetString: "i",
  glLoadMatrixf: "i", glColorMask: "iiii", glPolygonOffset: "ff", glDrawBuffer: "i",
  glReadBuffer: "i", glTexParameterf: "iif",
  // portal.asm: stencil-buffer portals
  glStencilFunc: "iii", glStencilOp: "iii", glStencilMask: "i", glClearStencil: "i",
  glDepthFunc: "i", glDepthRange: "dd", glClipPlane: "ii", glGetFloatv: "ii",
};

// GL 2.0 entry points reached through pointers (p_NAME in render.asm)
const PTR_SIGS = {
  glCreateShader: "i", glShaderSource: "iiii", glCompileShader: "i", glGetShaderiv: "iii",
  glGetShaderInfoLog: "iiii", glCreateProgram: "", glAttachShader: "ii", glLinkProgram: "i",
  glUseProgram: "i", glGetUniformLocation: "ii", glUniform1f: "if", glUniform1i: "ii",
  glUniform3f: "ifff", glUniform3fv: "iii", glUniformMatrix4fv: "iiii",
  glGetProgramInfoLog: "iiii",
  glGenFramebuffers: "ii", glBindFramebuffer: "ii", glFramebufferTexture2D: "iiiii",
  glCheckFramebufferStatus: "i", glActiveTexture: "i",
};

const SV_INT = ["rdi", "rsi", "rdx", "rcx", "r8", "r9"];
const WIN_INT = ["rcx", "rdx", "r8", "r9"];

function thunk(label, sig, target, indirect) {
  if (sig === "V") sig = "iiiiii";
  const n = sig.length;
  const winStack = Math.max(0, n - 4);
  const tempBase = 32 + 8 * winStack;
  const frame = Math.ceil((tempBase + 8 * n) / 16) * 16 || 32;
  const L = [];
  L.push(`${label}:`);
  L.push(`    push rbp`);
  L.push(`    mov rbp, rsp`);
  L.push(`    sub rsp, ${frame}`);
  // 1. park every System V argument in a temp slot (avoids register clashes)
  let ni = 0, nf = 0, ns = 0;
  for (let p = 0; p < n; p++) {
    const t = sig[p], tmp = `[rsp+${tempBase + 8 * p}]`;
    if (t === "i") {
      if (ni < 6) L.push(`    mov ${tmp}, ${SV_INT[ni++]}`);
      else { L.push(`    mov rax, [rbp+${16 + 8 * ns++}]`, `    mov ${tmp}, rax`); ni++; }
    } else {
      if (nf < 8) L.push(`    movsd ${tmp}, xmm${nf++}`);
      else { L.push(`    mov rax, [rbp+${16 + 8 * ns++}]`, `    mov ${tmp}, rax`); nf++; }
    }
  }
  // 2. load them where Windows expects them
  for (let p = 0; p < n; p++) {
    const t = sig[p], tmp = `[rsp+${tempBase + 8 * p}]`;
    if (p < 4) {
      if (t === "i") L.push(`    mov ${WIN_INT[p]}, ${tmp}`);
      else if (t === "f") L.push(`    movss xmm${p}, ${tmp}`);
      else L.push(`    movsd xmm${p}, ${tmp}`);
    } else {
      L.push(`    mov rax, ${tmp}`, `    mov [rsp+${32 + 8 * (p - 4)}], rax`);
    }
  }
  L.push(indirect ? `    call [${target}]` : `    call ${target}`);
  L.push(`    leave`);
  L.push(`    ret`);
  return L.join("\n");
}

const out = [];
out.push(`; GENERATED by tools/gen_win64_thunks.js -- do not edit by hand.
;
; System V -> Microsoft x64 calling-convention thunks for the Windows build.
; Each sv_NAME takes its arguments the Linux way (rdi, rsi, ..., xmm0..7),
; moves them to the Windows places (rcx/rdx/r8/r9 or xmm0..3 by position,
; the rest on the stack above 32 bytes of shadow space) and calls NAME.
; rbx, rbp and r12-r15 are preserved by both conventions, so nothing else
; needs saving on the way out. The two entry thunks at the bottom go the
; other way: Windows calls into our System V code.
default rel
section .text
`);
for (const [name, sig] of Object.entries(SIGS)) {
  out.push(`global sv_${name}\nextern ${name}\n; ${name}(${sig || "void"})`);
  out.push(thunk(`sv_${name}`, sig, name, false) + "\n");
}
for (const [name, sig] of Object.entries(PTR_SIGS)) {
  out.push(`global sv_p_${name}\nextern p_${name}\n; (*p_${name})(${sig || "void"})`);
  out.push(thunk(`sv_p_${name}`, sig, `p_${name}`, true) + "\n");
}
// printf-family: argument types come from the format string at run time
function varargsThunk(name, nfixed) {
  // System V: the nfixed fixed args (the last is the format) use the first
  // integer registers; the rest of the integer registers and xmm0..7 hold the
  // variadic values in order of their own kind.
  const freeInts = SV_INT.slice(nfixed);
  const L = [`global sv_${name}\nextern ${name}
; ${name}(${"i".repeat(nfixed)}, ...) -- walks the format string: each %f/%e/%g
; conversion takes the next xmm register, every other conversion the next
; integer register; then everything is laid out by position for Windows
; (variadic doubles travel in integer registers/stack slots there).
sv_${name}:
    push rbp
    mov rbp, rsp
    sub rsp, 368
    ; [rsp+0..31] shadow, [rsp+32..127] stack args, [rsp+128..255] A[16]
    ; (the Windows argument list), [rsp+256..] free integer regs, [rsp+304..] xmm0..7`];
  for (let k = 0; k < nfixed; k++) L.push(`    mov [rsp+${128 + 8 * k}], ${SV_INT[k]}`);
  freeInts.forEach((r, k) => L.push(`    mov [rsp+${256 + 8 * k}], ${r}`));
  for (let k = 0; k < 8; k++) L.push(`    movsd [rsp+${304 + 8 * k}], xmm${k}`);
  L.push(`    mov r10, ${SV_INT[nfixed - 1]}             ; format string
    mov r11d, ${nfixed}                    ; next position in A
    xor ecx, ecx                        ; integer values used
    xor edx, edx                        ; float values used
.scan:
    movzx eax, byte [r10]
    test eax, eax
    jz .scanned
    inc r10
    cmp eax, '%'
    jne .scan
.spec:
    movzx eax, byte [r10]
    test eax, eax
    jz .scanned
    inc r10
    cmp eax, '%'
    je .scan                            ; "%%" is a literal percent sign
    ; skip flags, width, precision and length modifiers
    cmp eax, '9'
    jbe .spec
    cmp eax, 'l'
    je .spec
    cmp eax, 'h'
    je .spec
    cmp eax, 'L'
    je .spec
    cmp eax, 'z'
    je .spec
    ; a conversion character
    cmp eax, 'f'
    je .flt
    cmp eax, 'e'
    je .flt
    cmp eax, 'g'
    je .flt
    cmp eax, 'F'
    je .flt
    cmp eax, 'E'
    je .flt
    cmp eax, 'G'
    je .flt
    mov rax, [rsp+256+rcx*8]
    inc ecx
    jmp .store
.flt:
    mov rax, [rsp+304+rdx*8]
    inc edx
.store:
    cmp r11d, 16
    jge .scan
    mov [rsp+128+r11*8], rax
    inc r11d
    jmp .scan
.scanned:
    ; positions 4.. go on the stack above the shadow space
    mov ecx, 4
.stk:
    cmp ecx, r11d
    jge .regs
    mov rax, [rsp+128+rcx*8]
    mov [rsp+32+rcx*8-32], rax
    inc ecx
    jmp .stk
.regs:
    mov rcx, [rsp+128]
    mov rdx, [rsp+136]
    mov r8, [rsp+144]
    mov r9, [rsp+152]
    movq xmm0, rcx
    movq xmm1, rdx
    movq xmm2, r8
    movq xmm3, r9
    call ${name}
    leave
    ret
`);
  return L.join("\n");
}
out.push(varargsThunk("printf", 1));
out.push(varargsThunk("snprintf", 3));

out.push(`
; ---- Windows -> System V entry points -------------------------------------------
; Windows expects rdi, rsi and xmm6-xmm15 to survive a call; System V code
; treats them as scratch, so these wrappers save and restore them.
%macro SAVE_WIN_REGS 0
    push rbp
    mov rbp, rsp
    push rdi
    push rsi
    sub rsp, 160
    movdqu [rsp+0], xmm6
    movdqu [rsp+16], xmm7
    movdqu [rsp+32], xmm8
    movdqu [rsp+48], xmm9
    movdqu [rsp+64], xmm10
    movdqu [rsp+80], xmm11
    movdqu [rsp+96], xmm12
    movdqu [rsp+112], xmm13
    movdqu [rsp+128], xmm14
    movdqu [rsp+144], xmm15
%endmacro
%macro RESTORE_WIN_REGS 0
    movdqu xmm6, [rsp+0]
    movdqu xmm7, [rsp+16]
    movdqu xmm8, [rsp+32]
    movdqu xmm9, [rsp+48]
    movdqu xmm10, [rsp+64]
    movdqu xmm11, [rsp+80]
    movdqu xmm12, [rsp+96]
    movdqu xmm13, [rsp+112]
    movdqu xmm14, [rsp+128]
    movdqu xmm15, [rsp+144]
    add rsp, 160
    pop rsi
    pop rdi
    pop rbp
%endmacro

; int SDL_main(int argc, char **argv) -- called by SDL2main's real main()
global SDL_main
extern beacom_main
SDL_main:
    SAVE_WIN_REGS
    mov edi, ecx
    mov rsi, rdx
    call beacom_main
    RESTORE_WIN_REGS
    ret

; void audio_cb_win64(void *userdata, Uint8 *stream, int len) -- SDL audio thread
global audio_cb_win64
extern audio_cb
audio_cb_win64:
    SAVE_WIN_REGS
    mov rdi, rcx
    mov rsi, rdx
    mov edx, r8d
    call audio_cb
    RESTORE_WIN_REGS
    ret
`);
fs.writeFileSync("win64_thunks.asm", out.join("\n"));

const names = [`; GENERATED by tools/gen_win64_thunks.js -- routes external calls through the
; System V -> Windows x64 thunks in win64_thunks.asm (Windows build only).`];
for (const name of [...Object.keys(SIGS), "printf", "snprintf"]) names.push(`%define ${name} sv_${name}`);
fs.writeFileSync("win64_names.inc", names.join("\n") + "\n");
console.log(`wrote ${Object.keys(SIGS).length + Object.keys(PTR_SIGS).length} thunks`);
