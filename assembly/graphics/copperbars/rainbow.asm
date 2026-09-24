; =====================================================================
; VGA Text Mode Smooth Rolling Copper Bars - Three Bars
; With Smooth Horizontal Scrolling Text (Adjusted Speed)
;
; Assembled with MASM:
;      ml /AT rainbow.asm;
;
; British English conventions applied.
; =====================================================================

.MODEL TINY
.386
.CODE
ORG 100h

START:
    ; -------------------------------------------------------------
    ; Switch to standard 80x25 text mode.
    ; This also restores the normal VGA palette.
    ; -------------------------------------------------------------

    mov ax, 0003h
    int 10h

    ; -------------------------------------------------------------
    ; Generate the three bar lookup tables.
    ; -------------------------------------------------------------

    call MakeBarTemplates

    ; -------------------------------------------------------------
    ; Initialise the scrolling text row.
    ; -------------------------------------------------------------

    call InitialiseScrollingText

    ; -------------------------------------------------------------
    ; Initialise scrolling position.
    ; -------------------------------------------------------------

    mov word ptr [ScrollOffset], 0
    mov byte ptr [ScrollCounter], 0

    ; -------------------------------------------------------------
    ; Initialise DAC colour 0 to black.
    ;
    ; The actual copper effect is produced by changing DAC 0,
    ; because the text screen has a black background.
    ; -------------------------------------------------------------

    mov dx, 03C8h
    xor al, al
    out dx, al

    mov dx, 03C9h
    xor al, al
    out dx, al
    out dx, al
    out dx, al


; =====================================================================
; Main loop
;
; The vertical retrace is now the frame synchronisation point.
;
; All frame preparation is performed immediately after the start of
; vertical retrace.  The raster effect then runs for the active
; display.
; =====================================================================

MainLoop:

    ; -------------------------------------------------------------
    ; Wait until we are outside vertical retrace.
    ;
    ; This guarantees that the following wait catches the NEXT
    ; vertical retrace rather than accidentally continuing from
    ; the current one.
    ; -------------------------------------------------------------

    mov dx, 03DAh

WaitVRetOutside:
    in al, dx
    test al, 08h
    jnz WaitVRetOutside

    ; -------------------------------------------------------------
    ; Wait for vertical retrace to begin.
    ; -------------------------------------------------------------

WaitVRetStart:
    in al, dx
    test al, 08h
    jz WaitVRetStart

    ; -------------------------------------------------------------
    ; We are now synchronised to the start of a new frame.
    ;
    ; Check for ESC here rather than allowing keyboard polling to
    ; occur at an arbitrary point in the raster.
    ; -------------------------------------------------------------

    mov ah, 01h
    int 16h
    jz NoKey

    mov ah, 00h
    int 16h

    cmp al, 1Bh
    je ExitProgram

NoKey:

    ; -------------------------------------------------------------
    ; Update Bar 0.
    ; Moves down one scanline.
    ; -------------------------------------------------------------

    mov ax, [bar0_pos]
    inc ax

    cmp ax, 400
    jb Bar0PosOk

    xor ax, ax

Bar0PosOk:
    mov [bar0_pos], ax

    ; -------------------------------------------------------------
    ; Update Bar 1.
    ; Moves up one scanline.
    ; -------------------------------------------------------------

    mov ax, [bar1_pos]
    dec ax

    jns Bar1PosOk

    mov ax, 399

Bar1PosOk:
    mov [bar1_pos], ax

    ; -------------------------------------------------------------
    ; Update Bar 2.
    ; Moves down two scanlines.
    ; -------------------------------------------------------------

    mov ax, [bar2_pos]
    add ax, 2

    cmp ax, 400
    jb Bar2PosOk

    sub ax, 400

Bar2PosOk:
    mov [bar2_pos], ax

    ; -------------------------------------------------------------
    ; Build the complete 400-line RGB lookup buffer.
    ; -------------------------------------------------------------

    call UpdateFrameBuffer

    ; -------------------------------------------------------------
    ; Advance the scrolling text at a slower, readable speed.
    ; Only updates every 3rd frame.
    ; -------------------------------------------------------------

    inc byte ptr [ScrollCounter]
    cmp byte ptr [ScrollCounter], 3
    jb SkipScrollText
    mov byte ptr [ScrollCounter], 0
    call ScrollTextFrame

SkipScrollText:

    ; -------------------------------------------------------------
    ; Render 400 scanlines.
    ;
    ; Each scanline explicitly selects DAC colour 0 because writing
    ; RGB values through 03C9h automatically increments the DAC
    ; index.
    ; -------------------------------------------------------------

    mov cx, 400
    mov si, OFFSET PrecalcBuffer

RenderLineLoop:
    push cx

    ; -------------------------------------------------------------
    ; Wait for horizontal retrace.
    ; -------------------------------------------------------------

    call WaitHRetrace

    ; -------------------------------------------------------------
    ; Select DAC colour 0.
    ; -------------------------------------------------------------

    mov dx, 03C8h
    xor al, al
    out dx, al

    ; -------------------------------------------------------------
    ; Write RGB values for this scanline.
    ; -------------------------------------------------------------

    mov dx, 03C9h

    mov al, [si]
    out dx, al

    mov al, [si+1]
    out dx, al

    mov al, [si+2]
    out dx, al

    add si, 3

    pop cx
    dec cx
    jnz RenderLineLoop

    ; -------------------------------------------------------------
    ; Return DAC colour 0 to black.
    ; -------------------------------------------------------------

    mov dx, 03C8h
    xor al, al
    out dx, al

    mov dx, 03C9h
    xor al, al
    out dx, al
    out dx, al
    out dx, al

    jmp MainLoop


; =====================================================================
; ExitProgram
; =====================================================================

ExitProgram:

    ; -------------------------------------------------------------
    ; Restore normal text mode and palette.
    ; -------------------------------------------------------------

    mov ax, 0003h
    int 10h

    mov ax, 4C00h
    int 21h


; =====================================================================
; InitialiseScrollingText
;
; Clears only row 12 of the text screen.
;
; Character = space
; Attribute = 07h
; =====================================================================

InitialiseScrollingText PROC

    push ax
    push cx
    push di
    push es

    ; -------------------------------------------------------------
    ; Point ES at VGA text memory.
    ; -------------------------------------------------------------

    mov ax, 0B800h
    mov es, ax

    ; -------------------------------------------------------------
    ; Row 12 starts at byte offset:
    ;
    ; 12 * 80 * 2 = 1920
    ; -------------------------------------------------------------

    mov di, 1920

    ; -------------------------------------------------------------
    ; Write 80 spaces with white foreground and black background.
    ; -------------------------------------------------------------

    mov ax, 0720h
    mov cx, 80
    rep stosw

    pop es
    pop di
    pop cx
    pop ax

    ret

InitialiseScrollingText ENDP


; =====================================================================
; ScrollTextFrame
;
; Moves the scrolling text one character position to the left.
;
; The new character is inserted into column 79.
;
; Scroll sequence:
;
;      80 spaces
;      message
;      80 spaces
;
; This provides a clean entry and exit from the screen.
;
; Only row 12 is touched.  The rest of the text screen is untouched.
; =====================================================================

ScrollTextFrame PROC

    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    ; -------------------------------------------------------------
    ; Point ES at VGA text memory.
    ; -------------------------------------------------------------

    mov ax, 0B800h
    mov es, ax

    ; -------------------------------------------------------------
    ; Row 12 starts at byte offset 1920.
    ; -------------------------------------------------------------

    mov di, 1920

    ; -------------------------------------------------------------
    ; Shift columns 1..79 into columns 0..78.
    ;
    ; Each text cell is two bytes.
    ; -------------------------------------------------------------

    mov cx, 79

ShiftText:

    mov ax, es:[di+2]
    mov es:[di], ax

    add di, 2

    dec cx
    jnz ShiftText

    ; -------------------------------------------------------------
    ; DI now points at column 79.
    ; Default new character is a space.
    ; -------------------------------------------------------------

    mov ax, 0720h

    ; -------------------------------------------------------------
    ; BX = current position in the complete scrolling sequence.
    ; -------------------------------------------------------------

    mov bx, [ScrollOffset]

    ; -------------------------------------------------------------
    ; First 80 positions are blank.
    ; -------------------------------------------------------------

    cmp bx, 80
    jb WriteScrollCharacter

    ; -------------------------------------------------------------
    ; Subtract the leading blank area.
    ; -------------------------------------------------------------

    sub bx, 80

    ; -------------------------------------------------------------
    ; If BX is within the actual message, fetch its character.
    ; Otherwise we are in the trailing blank area.
    ; -------------------------------------------------------------

    cmp bx, ScrollTextLength
    jae WriteScrollCharacter

    mov si, OFFSET ScrollText
    add si, bx

    mov al, [si]

    ; -------------------------------------------------------------
    ; AH remains 07h.
    ; -------------------------------------------------------------

WriteScrollCharacter:

    mov es:[di], ax

    ; -------------------------------------------------------------
    ; Advance to the next position in the scrolling sequence.
    ; Total sequence:
    ;
    ;      80 + message length + 80
    ; -------------------------------------------------------------

    inc word ptr [ScrollOffset]

    mov ax, [ScrollOffset]
    cmp ax, ScrollTotalLength
    jb ScrollPositionOk

    xor ax, ax
    mov [ScrollOffset], ax

ScrollPositionOk:

    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax

    ret

ScrollTextFrame ENDP


; =====================================================================
; MakeBarTemplates
;
; Generates three 60-scanline triangular copper bars with custom palettes:
; Bar 0 = Silvery Grey
; Bar 1 = Gold
; Bar 2 = Emerald Green
; =====================================================================

MakeBarTemplates PROC

    ; -------------------------------------------------------------
    ; Bar 0 - Silvery Grey (Balanced R, G, B with metallic brightness)
    ; -------------------------------------------------------------

    xor cx, cx
    mov di, OFFSET BarTemplate0

MakeBar0:
    cmp cx, 60
    jge MakeBar1Start

    mov ax, cx

    cmp ax, 30
    jle Bar0IntensityOk

    mov ax, 60
    sub ax, cx

Bar0IntensityOk:
    shl ax, 1                   ; Scale up to max 60

    cmp al, 55                  ; Cap slightly below max white for silver sheen
    jbe Bar0Cap
    mov al, 55

Bar0Cap:
    mov [di], al                ; Red
    mov [di+1], al              ; Green
    mov [di+2], al              ; Blue

    add di, 3
    inc cx

    jmp MakeBar0


    ; -------------------------------------------------------------
    ; Bar 1 - Gold (High Red, medium Green, zero Blue)
    ; -------------------------------------------------------------

MakeBar1Start:
    xor cx, cx
    mov di, OFFSET BarTemplate1

MakeBar1:
    cmp cx, 60
    jge MakeBar2Start

    mov ax, cx

    cmp ax, 30
    jle Bar1IntensityOk

    mov ax, 60
    sub ax, cx

Bar1IntensityOk:
    shl ax, 1                   ; al holds the base ramp intensity (0 to 60)

    ; Red component: Full intensity ramp
    mov bl, al
    mov [di], bl

    ; Green component: ~67% of red intensity for a rich gold hue
    movzx ax, bl
    mov dx, 43
    mul dx
    shr ax, 6
    mov [di+1], al              ; Green component

    mov byte ptr [di+2], 0      ; Blue component (zero)

    add di, 3
    inc cx

    jmp MakeBar1


    ; -------------------------------------------------------------
    ; Bar 2 - Emerald Green (Pure Green ramp)
    ; -------------------------------------------------------------

MakeBar2Start:
    xor cx, cx
    mov di, OFFSET BarTemplate2

MakeBar2:
    cmp cx, 60
    jge MakeBarsDone

    mov ax, cx

    cmp ax, 30
    jle Bar2IntensityOk

    mov ax, 60
    sub ax, cx

Bar2IntensityOk:
    shl ax, 1

    cmp al, 63
    jbe Bar2Cap
    mov al, 63

Bar2Cap:
    mov byte ptr [di], 0        ; Red
    mov [di+1], al              ; Green (pure)
    mov byte ptr [di+2], 0      ; Blue

    add di, 3
    inc cx

    jmp MakeBar2


MakeBarsDone:
    ret

MakeBarTemplates ENDP


; =====================================================================
; UpdateFrameBuffer
;
; Clears all 400 scanlines, then stamps each 60-line bar.
;
; Bar positions wrap modulo 400, allowing a bar to cross the
; top/bottom boundary without leaving stale pixels behind.
; =====================================================================

UpdateFrameBuffer PROC

    ; -------------------------------------------------------------
    ; Clear 400 * 3 = 1200 bytes.
    ; -------------------------------------------------------------

    mov di, OFFSET PrecalcBuffer
    mov cx, 1200 / 4
    xor eax, eax
    rep stosd

    ; -------------------------------------------------------------
    ; Bar 0
    ; -------------------------------------------------------------

    mov bx, [bar0_pos]
    mov si, OFFSET BarTemplate0
    mov cx, 60

CopyBar0:
    mov ax, bx
    mov dx, 3
    mul dx

    mov di, OFFSET PrecalcBuffer
    add di, ax

    mov al, [si]
    mov [di], al

    mov al, [si+1]
    mov [di+1], al

    mov al, [si+2]
    mov [di+2], al

    add si, 3

    inc bx
    cmp bx, 400
    jb Bar0NoWrap

    xor bx, bx

Bar0NoWrap:
    dec cx
    jnz CopyBar0

    ; -------------------------------------------------------------
    ; Bar 1
    ; -------------------------------------------------------------

    mov bx, [bar1_pos]
    mov si, OFFSET BarTemplate1
    mov cx, 60

CopyBar1:
    mov ax, bx
    mov dx, 3
    mul dx

    mov di, OFFSET PrecalcBuffer
    add di, ax

    mov al, [si]
    mov [di], al

    mov al, [si+1]
    mov [di+1], al

    mov al, [si+2]
    mov [di+2], al

    add si, 3

    inc bx
    cmp bx, 400
    jb Bar1NoWrap

    xor bx, bx

Bar1NoWrap:
    dec cx
    jnz CopyBar1

    ; -------------------------------------------------------------
    ; Bar 2
    ; -------------------------------------------------------------

    mov bx, [bar2_pos]
    mov si, OFFSET BarTemplate2
    mov cx, 60

CopyBar2:
    mov ax, bx
    mov dx, 3
    mul dx

    mov di, OFFSET PrecalcBuffer
    add di, ax

    mov al, [si]
    mov [di], al

    mov al, [si+1]
    mov [di+1], al

    mov al, [si+2]
    mov [di+2], al

    add si, 3

    inc bx
    cmp bx, 400
    jb Bar2NoWrap

    xor bx, bx

Bar2NoWrap:
    dec cx
    jnz CopyBar2

    ret

UpdateFrameBuffer ENDP


; =====================================================================
; WaitHRetrace
; =====================================================================

WaitHRetrace PROC
    push dx
    push ax

    mov dx, 03DAh

WH1:
    in al, dx
    test al, 01h
    jnz WH1

WH2:
    in al, dx
    test al, 01h
    jz WH2

    pop ax
    pop dx
    ret

WaitHRetrace ENDP


; =====================================================================
; Data
; =====================================================================

; The actual message length is calculated by MASM.
ScrollText     db "    *** VGA TEXT MODE SMOOTH ROLLING COPPER BARS ***    "
ScrollTextLength EQU $ - ScrollText

; 80 blank columns before the message and 80 after it.
ScrollTotalLength EQU 80 + ScrollTextLength + 80

ScrollOffset   dw 0
ScrollCounter  db 0

bar0_pos       dw 0
bar1_pos       dw 200
bar2_pos       dw 100

BarTemplate0   db 180 dup (0)
BarTemplate1   db 180 dup (0)
BarTemplate2   db 180 dup (0)

PrecalcBuffer  db 1200 dup (0)

END START
