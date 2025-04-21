%include "/usr/local/share/csc314/asm_io.inc"

; the file that stores the initial state
%define BOARD_FILE 'board.txt'

; how to represent everything
%define WALL_CHAR '#'
%define PLAYER_CHAR 'O'

; the size of the game screen in characters
%define HEIGHT 20
%define WIDTH 40

; the player starting position.
; top left is considered (0,0)
%define STARTX 1
%define STARTY 1

; these keys do things
%define EXITCHAR 'x'
%define UPCHAR 'w'
%define LEFTCHAR 'a'
%define DOWNCHAR 's'
%define RIGHTCHAR 'd'

%define GRAB 'e'



;Inventory items
%define MASTER_KEY 1


segment .data

; used to fopen() the board file defined above
board_file			db BOARD_FILE,0

; used to change the terminal mode
mode_r				db "r",0
raw_mode_on_cmd		db "stty raw -echo",0
raw_mode_off_cmd	db "stty -raw echo",0

; ANSI escape sequence to clear/refresh the screen
clear_screen_code	db	27,"[2J",27,"[H",0

; things the program will print
help_str			db 13,10,"Controls: ", \
					UPCHAR,"=UP / ", \
					LEFTCHAR,"=LEFT / ", \
					DOWNCHAR,"=DOWN / ", \
					RIGHTCHAR,"=RIGHT / ", \
					GRAB,"=grab item /", \
					EXITCHAR,"=EXIT", \
					13,10,10,0
					msg db "%d",10,0
					msg_see_key db "You see a key",10,0
					msg_see_b db "Lord of networking: 'Pull up wireshark and get a capture going. This Beacom building is very dangerous. Mr. T, lurks the halls'",10,0
					game_over db "cat T.txt",0

					segment .bss

	; this array stores the current rendered gameboard (HxW)
board	resb	(HEIGHT * WIDTH)

	; these variables store the current player position
	xpos	resd	1
	ypos	resd	1

	; These variables store the enemy's position
	T_xpos	resd	1
	T_ypos	resd	1

	inventory resd 1
	temp resd 1



	game_lost resd 1

	segment .text

	global	asm_main
	global  raw_mode_on
	global  raw_mode_off
	global  init_board
	global  render

	extern	system
	extern	putchar
	extern	getchar
	extern	printf
	extern	fopen
	extern	fread
	extern	fgetc
	extern	fclose

	asm_main:
	push	ebp
	mov		ebp, esp

	; put the terminal in raw mode so the game works nicely
	call	raw_mode_on

	; read the game board file into the global variable
	call	init_board

	; set the player at the proper start position
	mov		DWORD [xpos], STARTX
	mov		DWORD [ypos], STARTY
	mov dword [game_lost], 0

	; the game happens in this loop
	; the steps are...
	;   1. render (draw) the current board
	;   2. get a character from the user
	;	3. store current xpos,ypos in esi,edi
	;	4. update xpos,ypos based on character from user
	;	5. check what's in the buffer (board) at new xpos,ypos
	;	6. if it's a wall, reset xpos,ypos to saved esi,edi
	;	7. otherwise, just continue! (xpos,ypos are ok)
	game_loop:

	; draw the game board
	call	render

	mov [temp],eax
	push dword [inventory]
	push msg
	call printf
	mov eax, temp


;tick/update function
call CREATE_MEMORY
	call look

cmp dword [game_lost],1
je game_loop_end


	; get an action from the user
	call	getchar

	; store the current position
	; we will test if the new position is legal
	; if not, we will restore these
	mov		esi, DWORD [xpos]
	mov		edi, DWORD [ypos]

	; choose what to do
	cmp		eax, EXITCHAR
	je		game_loop_end
	cmp		eax, UPCHAR
	je 		move_up
	cmp		eax, LEFTCHAR
	je		move_left
	cmp		eax, DOWNCHAR
	je		move_down
	cmp		eax, RIGHTCHAR
	je		move_right
	cmp		eax, GRAB
	je		grab
	jmp		input_end			; or just do nothing

	; move the player according to the input character
	grab:
	call pick_up
	;jmp game_loop
	jmp		input_end
	move_up:
	dec		DWORD [ypos]
	jmp		input_end
	move_left:
	dec		DWORD [xpos]
	jmp		input_end
	move_down:
	inc		DWORD [ypos]
	jmp		input_end
	move_right:
	inc		DWORD [xpos]
	input_end:

	; (W * y) + x = pos

	; compare the current position to the wall character
	mov		eax, WIDTH
	mul		DWORD [ypos]
	add		eax, DWORD [xpos]
	lea		eax, [board + eax]
	cmp		BYTE [eax], WALL_CHAR
	jne		valid_move
	; opps, that was an invalid move, reset
	mov		DWORD [xpos], esi
	mov		DWORD [ypos], edi
	valid_move:

	jmp		game_loop
	game_loop_end:

	; restore old terminal functionality
	call raw_mode_off

cmp dword [game_lost],1
jne winner
push game_over
call system
add dword [esp],4



winner:

	mov		eax, 0
	mov		esp, ebp
	pop		ebp
	ret

	raw_mode_on:

	push	ebp
	mov		ebp, esp
	
push	raw_mode_on_cmd
	call	system

	add		esp, 4

	mov		esp, ebp
	pop		ebp
	ret

	raw_mode_off:

	push	ebp
	mov		ebp, esp

	push	raw_mode_off_cmd
	call	system
	add		esp, 4

	mov		esp, ebp
	pop		ebp
	ret

	init_board:

	push	ebp
	mov		ebp, esp

	; FILE* and loop counter
	; ebp-4, ebp-8
	sub		esp, 8

	; open the file
	push	mode_r
	push	board_file
	call	fopen
	add		esp, 8
	mov		DWORD [ebp - 4], eax

	; read the file data into the global buffer
	; line-by-line so we can ignore the newline characters
	mov		DWORD [ebp - 8], 0
	read_loop:
	cmp		DWORD [ebp - 8], HEIGHT
	je		read_loop_end

	; find the offset (WIDTH * counter)
	mov		eax, WIDTH
	mul		DWORD [ebp - 8]
	lea		ebx, [board + eax]

	; read the bytes into the buffer
	push	DWORD [ebp - 4]
	push	WIDTH
	push	1
	push	ebx
	call	fread
	add		esp, 16

	; slurp up the newline
	push	DWORD [ebp - 4]
	call	fgetc
	add		esp, 4

	inc		DWORD [ebp - 8]
	jmp		read_loop
	read_loop_end:


	; close the open file handle
	push	DWORD [ebp - 4]
	call	fclose
	add		esp, 4

	mov		esp, ebp
	pop		ebp
	ret

	render:

	push	ebp
	mov		ebp, esp

	; two ints, for two loop counters
	; ebp-4, ebp-8
	sub		esp, 8

	; clear the screen
	push	clear_screen_code
	call	printf
	add		esp, 4

	; print the help information
	push	help_str
	call	printf
	add		esp, 4

	; outside loop by height
	; i.e. for(c=0; c<height; c++)
	mov		DWORD [ebp - 4], 0
	y_loop_start:
	cmp		DWORD [ebp - 4], HEIGHT
	je		y_loop_end

	; inside loop by width
	; i.e. for(c=0; c<width; c++)
	mov		DWORD [ebp - 8], 0
	x_loop_start:
	cmp		DWORD [ebp - 8], WIDTH
	je 		x_loop_end

	; check if (xpos,ypos)=(x,y)
	mov		eax, DWORD [xpos]
	cmp		eax, DWORD [ebp - 8]
	jne		print_board
	mov		eax, DWORD [ypos]
	cmp		eax, DWORD [ebp - 4]
	jne		print_board
	; if both were equal, print the player
	push	PLAYER_CHAR
	call	putchar
	add		esp, 4
	jmp		print_end
	print_board:
	; otherwise print whatever's in the buffer
	mov		eax, DWORD [ebp - 4]
	mov		ebx, WIDTH
	mul		ebx
	add		eax, DWORD [ebp - 8]
	mov		ebx, 0
	mov		bl, BYTE [board + eax]
	push	ebx
	call	putchar
	add		esp, 4
	print_end:

	inc		DWORD [ebp - 8]
	jmp		x_loop_start
	x_loop_end:

	; write a carriage return (necessary when in raw mode)
	push	0x0d
	call 	putchar
	add		esp, 4

	; write a newline
	push	0x0a
	call	putchar
	add		esp, 4

	inc		DWORD [ebp - 4]
	jmp		y_loop_start
	y_loop_end:

	mov		esp, ebp
	pop		ebp
	ret


	;;;;;; MY CUSTOM FUNCTIONS ;;;;;;;;;;

; [ebp-8] = steps
; [ebp-12] = y
; [ebp-16] = x
; [ebp-20] = MEMORY POINTER THING
SEARCH:
push ebp
mov ebp, esp
pusha

push dword [ebp-16] ; x
push dword [ebp-12] ; y
call get_pos ; store index in eax

add eax, board
cmp [eax],byte -1
je JOEVER





mov ebx, [eax]
cmp [ebp-8],ebx 
jge JOEVER














JOEVER:
popa
pop ebp
ret


CREATE_MEMORY:
push ebp
mov ebp,esp
pusha

mov eax, esp; eax= memory pointer
sub esp, WIDTH*HEIGHT ; this is the AI 'memory' 

mov ecx, WIDTH*HEIGHT
dec ecx
mov edx, board
add edx,ecx
dec edx


traverse:
sub eax,ecx
mov [eax],byte 0


cmp [edx], byte '#'
jne KEEP_GOING
mov [eax], byte -1




KEEP_GOING:

add eax,ecx

dec edx
loop traverse

add esp, WIDTH*HEIGHT

popa
pop ebp
ret







;convert (x,y) to position to index of the flattened array
;y=[ebp+8]
;x=[ebp+12]
; 0 = out of bounds
; 1 = in bounds
inbounds:
push ebp
mov ebp,esp

mov eax,1

cmp dword [ebp+12],0
jl OUT_OF_BOUNDS


cmp dword [ebp+12],WIDTH
jge OUT_OF_BOUNDS

cmp dword [ebp+8],0
jl OUT_OF_BOUNDS


cmp dword [ebp+12],HEIGHT
jge OUT_OF_BOUNDS

JMP IN_BOUNDS

OUT_OF_BOUNDS:
DEC eax ;0 = false


IN_BOUNDS:



pop ebp
ret

;convert (x,y) to position to index of the flattened array
;y=[ebp+8]
;x=[ebp+12]
;the result is stored in eax
get_pos:
push ebp
mov ebp,esp

xor edx,edx
mov eax, WIDTH
mul dword [ebp+8]
add eax, [ebp+12]

pop ebp
ret




look:
push	ebp
mov		ebp, esp

pusha

push dword [xpos]
push dword [ypos]
call get_pos; calculate position in game array
add esp,8; pop parameters off stack
mov eax, WIDTH
mul dword [ypos]
add eax, [xpos]

mov ebx,board ;loads pointer to board in ebx

add ebx,eax ; jump to the index we care about

cmp byte [ebx], 'k'
jne check_b
mov eax, msg_see_key
call print_string


check_b:
cmp byte [ebx], 'B'
jne check_t
mov eax, msg_see_b
call print_string
je done_look

check_t:
cmp byte [ebx], 'T'
jne done_look
mov dword [game_lost],1
jmp done_look



done_look:
popa

mov		esp, ebp
pop		ebp
ret





pick_up:
push	ebp
mov		ebp, esp

pusha

mov eax, WIDTH
mul dword [ypos]
add eax, [xpos]

mov ebx,board ;loads pointer to board in ebx

add ebx,eax ; jump to the index we care about

cmp dword [inventory], 0
cmp byte [ebx], 'k'
jne done
inc dword [inventory]
mov byte[ebx], ' '
done:
popa

mov		esp, ebp
pop		ebp
ret



