%include "/usr/local/share/csc314/asm_io.inc"

; the file that stores the initial state
%define BOARD_FILE 'board.txt'

; how to represent everything
%define WALL_CHAR '#'
%define PLAYER_CHAR 'O'
%define WIRESHARK_PACKET_CHAR 'W'

; the size of the game screen in characters
%define HEIGHT 31
%define WIDTH  59

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


;field of view/flashlight square radius
%define field_of_view 7



%define INFINITY WIDTH+HEIGHT
%define UNREACHABLE 2*INFINITY



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
					msg db `\r%d\n\r`,10,0
					msg_see_key db "You see a wireshark packet capture... interesting",10,0
					msg_see_b db `\n\rLord of networking: 'Pull up wireshark and get a capture going!\n\r This Beacom building is very dangerous!\n\r Mr. T, lurks the halls.\n\rMr. Y has gone missing, you must find 3 wireshark packet captures before it is too late.\n\rIf you are ever scared, I have used my networking magic to secure this room and some others Mr. T. He cannot enter them! Good luck on your quest! '`,10,0
msg_safe_room db `\n\rYou feel a comforting aura in this room\n\rYou feel safe here\n\rIt is protected by a powerful network sorcerer\n\r`,0
					game_over db "cat T.txt | lolcat",0
					game_over_interesting db "cat chicken_jockey.txt | lolcat",0
					game_won db "cat W.txt | lolcat",0
					;intro_lore db "cat intro.txt | while read line; do echo $line | lolcat; sleep 1; done; bash intro.sh",0
					intro_lore db "cat intro.txt | while read line; do echo $line | lolcat && sleep 1; done;", 0
					side_border db `\x1b[31m|\x1b[39m`,0
					wide_border db `\x1b[31m-\x1b[39m`,0
					sound db `\x1b[31mshh! You made a noise!\x1b[39m`,0
					insult db "YOU COWARD!",0
					question db "DO YOU WISH TO EMBARK ON THIS JOURNEY? (YES=1, NO=0)",10,0
					omniman db "cat rusure.txt | lolcat", 0
					usure db "Are you sure? (YES=1, NO=0)",10,0
; Note to self, to use fancy ansi escape codes we need to use backticks `` instead of quotes ""

					segment .bss

	; this array stores the current rendered gameboard (HxW)
board	resb	(HEIGHT * WIDTH)
secret_game_over resd 1

	; these variables store the current player position
	xpos	resd	1
	ypos	resd	1

	; These variables store the enemy's position
	T_xpos	resd	1
	T_ypos	resd	1

	inventory resd 1
	temp resd 1

	start_row resd 1
	start_col resd 1
	end_row resd 1
	end_col resd 1

	;Where T's destination is
	T_goal_xpos	resd	1
	T_goal_ypos	resd	1

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





extern srand
extern rand
extern sleep

	asm_main:
	push	ebp
	mov		ebp, esp


mov dword [T_xpos], 17
mov dword [T_ypos], 18
mov [secret_game_over],dword  0

; Print intro lore
push intro_lore
call system
add esp,4
mov eax, question
call print_string
doom_loop:
call read_int
cmp eax, 0
jne JOURNEY
push omniman
call system
mov eax, usure
call print_string
add esp,4
push 1
call sleep
add esp,4
jmp doom_loop
JOURNEY:


;Seed rng
push 5
call srand
add esp,4



	; put the terminal in raw mode so the game works nicely
	call	raw_mode_on

	; read the game board file into the global variable
	call	init_board


;Spawn keys
	call spawn_wireshark_packet_captures
	call spawn_T

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
	add esp,4
	add esi, 8
	mov eax, temp

mov eax, [game_lost]

;tick/update function
	call look
mov eax, [game_lost]
cmp eax, 0
jne game_loop_end
push dword [T_xpos]
push dword [T_ypos]
call get_pos
mov ebx,eax
mov eax,board
add eax,ebx
mov byte [eax], ' '
add esp,8
call rand_pos

call defeated

call CREATE_MEMORY
;call can_reach_player


call defeated


call rand
and eax,15; 1/16 chance of making a sound
cmp eax,0
jne SILENCE
call made_sound
SILENCE:

push dword [T_xpos]
push dword [T_ypos]
call get_pos
mov ebx,eax
mov eax,board
add eax,ebx
mov byte [eax], 'T'
add esp,8




cmp dword [game_lost],1
je game_loop_end
cmp dword [inventory],3
jne CON
mov [game_lost],dword -1
jmp game_loop_end


CON:


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
cmp [secret_game_over],dword 1
jne regular_game_over
push game_over_interesting
jmp CALL_SYSTEM_TO_END
regular_game_over:
push game_over
CALL_SYSTEM_TO_END:
call system
add esi, 4
add dword [esp],4
jmp loser



winner:
cmp dword [game_lost], -1
jne loser

push game_won
call system
add esi, 4
add dword [esp],4

loser:



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




pusha

;Start n rows before player row
mov eax, [ypos]
sub eax, field_of_view
cmp eax,0
jge GOOD_START_ROW
mov eax,0
GOOD_START_ROW:
mov [start_row],eax

;end n rows after player row
mov eax, [ypos]
add eax,field_of_view
cmp eax,HEIGHT
jl GOOD_END_ROW
mov eax, HEIGHT
dec eax
GOOD_END_ROW:
mov [end_row],eax


;Start n cols before player row
mov eax, [xpos]
sub eax, field_of_view
cmp eax,0
jge GOOD_START_COL
mov eax,0
GOOD_START_COL:
mov [start_col],eax

;End n cols after player row
mov eax, [xpos]
add eax,field_of_view
cmp eax, WIDTH
jl GOOD_END_COL
mov eax, WIDTH
dec eax
GOOD_END_COL:
mov [end_col],eax



popa





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
	




; print top row
	call print_wide_border

	; write a carriage return (necessary when in raw mode)
	push	0x0d
	call 	putchar
	add		esp, 4



	mov eax, [start_row]
	mov		DWORD [ebp - 4], eax;0
	y_loop_start:






	mov eax, [end_row]
	cmp		DWORD [ebp - 4], eax;HEIGHT
	je		y_loop_end



	; print red |  on the left side
	push side_border
	call printf
	add esp,4


	; inside loop by width
	; i.e. for(c=0; c<width; c++)
	mov eax, [start_col]
	mov		DWORD [ebp - 8], eax;0
	x_loop_start:
	mov eax, [end_col]
	cmp		DWORD [ebp - 8], eax;WIDTH
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


	; print red |  on the right side
	push side_border
	call printf
	add esp,4


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


	call print_wide_border

	mov		esp, ebp
	pop		ebp
	ret


	;;;;;; MY CUSTOM FUNCTIONS ;;;;;;;;;;

; [ebp+8] = steps
; [ebp+12] = y
; [ebp+16] = x
; [ebp+20] = MEMORY POINTER THING
SEARCH:
push ebp
mov ebp, esp




;freezes for some reason
;mov eax, [ebp+8]  ; store # steps in eax
;call print_int
;call print_nl
;cmp eax,INFINITY 
;jge JOEVER



mov eax, [ebp+20] ; move memory into eax

push dword [ebp+16] ; x
push dword [ebp+12] ; y
call get_pos; store index in eax
add esp, 8

shl eax, 2; index*4
mov ebx,eax ; move index into ebx


; For Debugging purposes skip all the code




mov eax,[ebp+20] ; store memory in eax
add eax,ebx; jump to correct index

cmp [eax],dword UNREACHABLE; Ignore walls
je JOEVER




; if the current position can already be reached in fewer steps, stop
mov ecx, dword [eax]
cmp [ebp+8],ecx
jge JOEVER


; cur position steps = steps
mov eax, dword [ebp+20]
add eax,ebx; Jump to correct index
mov ebx, dword [ebp+8]; ebx = steps
mov dword [eax], ebx
mov eax,dword [eax]

;


;push eax;  save eax

;(x+1,y)
mov eax, dword [ebp+20]; memory
push eax
mov eax, dword [ebp+16]; x
inc eax ; (x+1)
push eax
mov eax, dword [ebp+12]; y
push eax
mov eax, dword [ebp+8]; steps
inc eax
push eax
call SEARCH
add esp,16 ; pop the stack back


;(x-1,y)
mov eax, dword [ebp+20]; memory
push eax
mov eax, dword [ebp+16]; x
dec eax ;(x-1)
push eax
mov eax, dword [ebp+12]; y
push eax
mov eax, dword [ebp+8]; steps
inc eax
push eax
call SEARCH
add esp,16  ; pop the stack back


;(x,y+1)
mov eax, dword [ebp+20]; memory
push eax
mov eax, dword [ebp+16]; x
push eax
mov eax, dword [ebp+12]; y
inc eax; (y+1)
push eax
mov eax, dword [ebp+8]; steps
inc eax
push eax
call SEARCH
add esp,16  ; pop the stack back



;(x,y-1)
mov eax, dword [ebp+20]; memory
push eax
mov eax, dword [ebp+16]; x
push eax
mov eax, dword [ebp+12]; y
dec eax; (y-1)
push eax
mov eax, dword [ebp+8]; steps
inc eax
push eax
call SEARCH
add esp,16  ; pop the stack back



;pop eax;  restore eax


JOEVER:
;popa
pop ebp
ret


CREATE_MEMORY:
push ebp
mov ebp,esp
pusha

sub esp, 4*WIDTH*HEIGHT ; this is the AI 'memory' 
mov eax, esp; eax= memory pointer

mov ecx, 0
traverse:
mov bl, [board+ecx]
mov [eax+4*ecx],dword INFINITY
cmp bl, ' ' ; T does not go to special tiles
je KEEP_GOING
mov [eax+4*ecx],dword UNREACHABLE
KEEP_GOING:
inc ecx; ecx=ecx+1
cmp ecx, WIDTH*HEIGHT
jl traverse


push eax

push eax


; DO DFS
push eax 
push dword [T_goal_xpos]
push dword [T_goal_ypos]
push dword 0
call SEARCH

mov eax,[T_goal_xpos]
mov eax,[T_goal_ypos]

add esp, 16


pop eax
push eax

push dword [T_xpos]
push dword [T_ypos]
call get_pos
add esp,8
mov ebx,eax ; save T index into ebx

pop eax ; store memory back in eax
add eax,ebx
mov eax, dword [eax]



pop eax
push eax
call move_T
add esp,4

add esp, 4*WIDTH*HEIGHT ; remove memory array on the stack 
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

get_pos_2:
push ebp
mov ebp,esp

;xor edx,edx
;mov eax, WIDTH
;mul dword [ebp+8]
;add eax, [ebp+12]

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
;mov eax, WIDTH
;mul dword [ypos]
;add eax, [xpos]

mov ebx,board ;loads pointer to board in ebx

add ebx,eax ; jump to the index we care about


;;Chicken Jockey Easter Egg
cmp byte [ebx], 'J'
jne check_wireshark_packet
mov [game_lost],dword 1
mov eax,[game_lost]
mov [secret_game_over],dword  1
jmp done_look


check_wireshark_packet:
cmp byte [ebx], WIRESHARK_PACKET_CHAR
jne check_b
mov eax, msg_see_key
call print_string


check_b:
cmp byte [ebx], 'B'
jne check_t
cmp [inventory], dword 3
jl NOT_ENOUGH_PACKETS
mov [game_lost], dword -1 ; Game won
jmp done_look
NOT_ENOUGH_PACKETS:
;jne check_t
mov eax, msg_see_b
call print_string
jmp done_look

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
cmp byte [ebx], WIRESHARK_PACKET_CHAR 
jne done
inc dword [inventory]
mov byte[ebx], ' '
done:
popa

mov		esp, ebp
pop		ebp
ret


;[ebp+8] = memory 
move_T:
push ebp
mov ebp,esp


mov ebx, [ebp+8]



push dword [T_xpos]
push dword [T_ypos]
call get_pos
add esp,8
shl eax,2; index *4
mov edx, eax; save old pos in edx
add eax,ebx; cur pos





sub eax, 4
push eax ; left [ebp-4]
add eax, 4


add eax, 4
push eax ;  right [ebp-8]
sub eax, 4


sub eax, 4*WIDTH
push eax ;  UP [ebp-12]
add eax, 4*WIDTH


add eax, 4*WIDTH
push eax ;  DOWN  [ebp-16]
sub eax, 4*WIDTH

mov eax,[ebp-4]
mov eax, dword[eax]
push eax
mov eax,[ebp-8]
mov eax,dword [eax]
push eax
call get_min
add esp, 8

push eax
mov eax,[ebp-12]
mov eax,dword [eax]
push eax
call get_min
add esp, 8

push eax
mov eax,[ebp-16]
mov eax,dword [eax]
push eax
call get_min
add esp, 8

pusha
;If eax==INFINITY than the destination is unreachable and we should make a new goal
mov ebx,0
cmp eax, INFINITY
jne CAN_REACH
mov ebx,1
mov eax,msg_safe_room 
call print_string
CAN_REACH:
mov eax,ebx
push ebx
call T_goal_logic
add esp,4

mov eax,[T_goal_xpos]
mov eax,[T_goal_ypos]

popa

mov ebx,[ebp-4]; LEFT
mov ebx, dword [ebx]
cmp eax,ebx
je MOVE_LEFT

mov ebx,[ebp-8]; RIGHT
mov ebx, dword [ebx]
cmp eax,ebx
je MOVE_RIGHT

mov ebx,[ebp-12]; UP
mov ebx, dword [ebx]
cmp eax,ebx
je MOVE_UP

mov ebx,[ebp-16]; DOWN
mov ebx, dword [ebx]
cmp eax,ebx
je MOVE_DOWN



JMP ALL_GOOD; here for debugging purposes

MOVE_LEFT:
dec dword [T_xpos]
JMP ALL_GOOD

MOVE_RIGHT:
inc dword [T_xpos]
JMP ALL_GOOD

MOVE_UP:
dec dword [T_ypos]
JMP ALL_GOOD

MOVE_DOWN:
inc dword [T_ypos]
JMP ALL_GOOD




ALL_GOOD:

add esp, 4*4; pop LEFT,RIGHT,UP,DOWN



pop ebp
ret


;[ebp+8]
;[ebp+12]
;store min in eax
get_min:
push ebp
mov ebp,esp

mov eax,[ebp+8] 
mov ebx,[ebp+12] 
cmp eax,ebx
jb found_min
mov eax,ebx



found_min:
pop ebp
ret


print_wide_border:
push ebp
mov ebp,esp


pusha
mov eax,[start_col]
mov ebx,[end_col]
sub ebx,eax

mov ecx, ebx
wide_border_loop:

mov eax, wide_border 
call print_string


dec ecx
cmp ecx,0
jge wide_border_loop


call print_nl


popa

pop ebp
ret



defeated:
push ebp
mov ebp,esp

call dist
cmp eax,1
jg TOO_FAR
mov eax,1 
jmp D_LOGIC_DONE




TOO_FAR:
mov eax,0

D_LOGIC_DONE:
mov [game_lost], eax

pop ebp
ret


;Calculating |x2-x1|+|y2-y1|
;Taxi/Manhattan distance because idk how to do square roots in assembly lol
dist:
push ebp
mov ebp,esp

mov eax, [xpos]
sub eax, [T_xpos]
cmp eax,0
jge Y_dist
neg eax




Y_dist:
mov ebx, [ypos]
sub ebx, [T_ypos]
cmp ebx,0
jge sum_them_up
neg ebx




sum_them_up:
add eax,ebx


pop ebp
ret



rand_pos:
push ebp
mov ebp,esp



LOOP_UNTIL_VALID_LOCATION:


xor eax,eax; row=0
xor ebx,ebx; col=0


call rand
mov ecx,HEIGHT
xor edx,edx
div ecx
mov eax,edx; use remainder
mov ebx, eax



call rand
mov ecx,WIDTH
xor edx,edx
div ecx
mov eax,edx; use remainder


push eax
push ebx
call get_pos
add eax, board
movzx ecx, byte [eax]
pop ebx
pop eax

cmp ecx, byte ' '
jne LOOP_UNTIL_VALID_LOCATION



pop ebp
ret



spawn_wireshark_packet_captures:
push ebp
mov ebp,esp
pusha

mov ecx,4
LOOP_SPAWN_WIRESHARK_PACKET_CAPTURES:
pusha
call rand_pos
push eax
push ebx
call get_pos
add eax,board
mov bl,byte WIRESHARK_PACKET_CHAR
mov [eax],bl
add esp,8
popa
loop LOOP_SPAWN_WIRESHARK_PACKET_CAPTURES

popa
pop ebp
ret

spawn_T:
push ebp
mov ebp,esp


TRY_AGAIN_IF_TOO_CLOSE:
call rand_pos
mov [T_xpos],eax
mov [T_ypos],ebx
call dist
cmp eax,20
jle TRY_AGAIN_IF_TOO_CLOSE
pop ebp
ret



;[ebp+4] = cannot reach
T_goal_logic:
push ebp
mov ebp,esp


cmp [ebp+8],byte 1
je PICK_RANDOM


mov eax, [T_xpos]

cmp eax, [T_goal_xpos]
jne FINISH_GOAL_LOGIC

mov eax, [T_ypos]
cmp eax, [T_goal_ypos]
jne FINISH_GOAL_LOGIC





; If T is close to the player than set T's goal to the player postion (AKA you should be scared!)
call dist
cmp eax, 20
jge PICK_RANDOM



;This code alone is hard mode need to fix commented code for 'smart' AI
pusha
call can_reach_player
cmp eax,0
popa
jne PICK_RANDOM

mov eax, [xpos]
mov [T_goal_xpos], eax
mov eax, [ypos]
mov [T_goal_ypos], eax
;jmp FINISH_GOAL_LOGIC






PICK_RANDOM:
call rand_pos
mov [T_goal_xpos],eax
mov [T_goal_ypos],ebx


FINISH_GOAL_LOGIC:
pop ebp
ret




; When you become cooked!
made_sound:
push ebp
mov ebp,esp

mov eax, [xpos]
mov ebx, [ypos]
mov [T_goal_xpos], eax
mov [T_goal_ypos], ebx


mov eax,sound
call print_string





pop ebp
ret



can_reach_player:
push ebp
mov ebp, esp



push dword [xpos]
push dword [ypos]
call get_pos
add esp,8


add eax, board

cmp [eax], byte ' '
mov ebx,0
jne answer_found
mov ebx,1





answer_found:
mov eax,ebx

pop ebp
ret


