; =====================================================================
; TINYRAIN.ASM
;
; VGA TEXT MODE SCROLLING RAINBOW RASTER
;
; QBX / PDS 7.1
; DOSBox / DOSBox-Staging
;
; MASM 6.11:
;
;     ML /AT TINYRAIN.ASM;
;
; NON-TSR DEBUG VERSION
;
; This is an ordinary .COM program. It installs INT 60h while it is
; running, exercises the synthetic raster interrupt, changes VGA DAC
; register 7 once per scanline, displays debug information, and
; restores INT 60h before exit.
;
; Raster interrupt:
;
;     INT 60h
;
; Raster target:
;
;     Port 62h
;
; VGA DAC:
;
;     3C8h = DAC index
;     3C9h = DAC data
;
; DAC register 7 is changed on every raster interrupt.
;
; The 400 scanlines contain one complete continuous RGB rainbow:
;
;     RED -> YELLOW -> GREEN -> CYAN -> BLUE -> MAGENTA -> RED
;
; The rainbow is vertically scrolled.
;
; RainbowOffset advances once per complete raster frame.
;
; The lookup is:
;
;     LUT index = scanline - RainbowOffset
;
; wrapping around at 400.
;
; Increasing RainbowOffset therefore moves the colour pattern DOWN
; the screen.
;
; Each DAC component is 6-bit:
;
;     0 .. 63
;
; Debug output is printed every 10 complete 400-line raster frames:
;
;     400 interrupts/frame
;     10 frames
;     4000 interrupts/debug message
;
; =====================================================================

.MODEL TINY
.286
.CODE
ORG 100h

RASTER_PORT     EQU 0062h
RASTER_VECTOR   EQU 060h

DAC_INDEX       EQU 03C8h
DAC_DATA        EQU 03C9h
DAC_COLOUR      EQU 7

VISIBLE_LINES   EQU 400

DEBUG_IRQS      EQU 4000


START:
        mov     ax,cs
        mov     ds,ax

        mov     dx,OFFSET MsgStart
        call    PrintString

        ; -------------------------------------------------------------
        ; Get the existing INT 60h vector.
        ; -------------------------------------------------------------

        mov     ax,3560h
        int     21h

        mov     WORD PTR [OldVectorOff],bx
        mov     WORD PTR [OldVectorSeg],es

        mov     dx,OFFSET MsgVector
        call    PrintString

        ; -------------------------------------------------------------
        ; VGA text mode 03h.
        ; -------------------------------------------------------------

        mov     ax,0003h
        int     10h

        mov     dx,OFFSET MsgMode
        call    PrintString

        ; -------------------------------------------------------------
        ; Build the 400-line rainbow lookup table.
        ; -------------------------------------------------------------

        call    BuildLUT

        mov     dx,OFFSET MsgLUT
        call    PrintString

        ; -------------------------------------------------------------
        ; Runtime state.
        ; -------------------------------------------------------------

        mov     WORD PTR [NextScanline],1
        mov     WORD PTR [FrameCount],0
        mov     WORD PTR [RasterCount],0
        mov     WORD PTR [LastDebugCount],0
        mov     WORD PTR [RainbowOffset],0

        ; -------------------------------------------------------------
        ; Install INT 60h.
        ; -------------------------------------------------------------

        cli

        mov     dx,OFFSET RasterISR
        mov     ax,2560h
        int     21h

        sti

        mov     dx,OFFSET MsgInstalled
        call    PrintString

        ; -------------------------------------------------------------
        ; Arm first raster interrupt.
        ; -------------------------------------------------------------

        mov     ax,1
        call    CommitRasterTarget

        mov     dx,OFFSET MsgArmed
        call    PrintString

        mov     dx,OFFSET MsgRunning
        call    PrintString

        ; -------------------------------------------------------------
        ; Main debug loop.
        ;
        ; One debug message is printed every 4000 raster interrupts,
        ; equivalent to ten complete 400-line raster frames.
        ; -------------------------------------------------------------

MainLoop:

        ; -------------------------------------------------------------
        ; Check keyboard without blocking.
        ; -------------------------------------------------------------

        mov     ah,01h
        int     16h
        jz      NoKey

        mov     ah,00h
        int     16h

        mov     dx,OFFSET MsgKey
        call    PrintString

        jmp     ExitProgram


NoKey:

        ; -------------------------------------------------------------
        ; Has another 10-frame block completed?
        ; -------------------------------------------------------------

        mov     ax,WORD PTR [RasterCount]
        mov     bx,WORD PTR [LastDebugCount]

        cmp     ax,bx
        je      MainLoop

        mov     dx,ax
        sub     dx,bx

        cmp     dx,DEBUG_IRQS
        jb      MainLoop

        ; -------------------------------------------------------------
        ; Advance debug marker by exactly 4000 interrupts.
        ; -------------------------------------------------------------

        add     bx,DEBUG_IRQS
        mov     WORD PTR [LastDebugCount],bx

        ; -------------------------------------------------------------
        ; Print:
        ;
        ;     IRQ count
        ;     frame count
        ;     scanline
        ;     rainbow offset
        ;
        ; -------------------------------------------------------------

        mov     dx,OFFSET MsgIRQ
        call    PrintString

        mov     ax,WORD PTR [RasterCount]
        call    PrintHexWord

        mov     dx,OFFSET MsgFrame
        call    PrintString

        mov     ax,WORD PTR [FrameCount]
        call    PrintHexWord

        mov     dx,OFFSET MsgScanline
        call    PrintString

        mov     ax,WORD PTR [NextScanline]
        call    PrintHexWord

        mov     dx,OFFSET MsgOffset
        call    PrintString

        mov     ax,WORD PTR [RainbowOffset]
        call    PrintHexWord

        mov     dx,OFFSET MsgCRLF
        call    PrintString

        jmp     MainLoop


; =====================================================================
; ExitProgram
;
; Disable synthetic raster.
; Restore INT 60h.
; Restore DAC register 7 to DOS light grey.
; Return normally to DOS.
; =====================================================================

ExitProgram:

        cli

        ; -------------------------------------------------------------
        ; Disable synthetic raster:
        ;
        ; target = 0000h
        ; vector = 60h
        ; -------------------------------------------------------------

        mov     dx,RASTER_PORT

        xor     al,al
        out     dx,al

        xor     al,al
        out     dx,al

        mov     al,RASTER_VECTOR
        out     dx,al

        ; -------------------------------------------------------------
        ; Restore original INT 60h vector.
        ; -------------------------------------------------------------

        push    ds

        mov     ax,WORD PTR [OldVectorSeg]
        mov     ds,ax

        mov     dx,WORD PTR [OldVectorOff]

        mov     ax,2520h
        int     21h

        pop     ds

        sti

        ; -------------------------------------------------------------
        ; Restore DOS light-grey DAC colour 7.
        ;
        ; VGA DAC values are 6-bit.
        ; 42 decimal = 2Ah.
        ; -------------------------------------------------------------

        mov     dx,DAC_INDEX
        mov     al,DAC_COLOUR
        out     dx,al

        mov     dx,DAC_DATA

        mov     al,42
        out     dx,al

        mov     al,42
        out     dx,al

        mov     al,42
        out     dx,al

        mov     dx,OFFSET MsgExit
        call    PrintString

        mov     ax,4C00h
        int     21h


; =====================================================================
; CommitRasterTarget
;
; AX = scanline target.
;
; Sends:
;
;     low byte
;     high byte
;     interrupt vector / commit
;
; =====================================================================

CommitRasterTarget PROC NEAR

        push    ax
        push    dx

        mov     dx,RASTER_PORT

        out     dx,al

        mov     al,ah
        out     dx,al

        mov     al,RASTER_VECTOR
        out     dx,al

        pop     dx
        pop     ax

        ret

CommitRasterTarget ENDP


; =====================================================================
; RasterISR
;
; One invocation occurs for each selected VGA scanline.
;
; The ISR:
;
;     1. saves registers
;     2. increments the raster interrupt count
;     3. calculates the scrolling LUT position
;     4. writes VGA DAC register 7
;     5. advances the scanline
;     6. counts complete frames
;     7. advances the rainbow offset once per frame
;     8. arms the next scanline
;     9. restores registers
;    10. IRET
;
; =====================================================================

RasterISR PROC FAR

        push    ax
        push    bx
        push    dx
        push    si
        push    ds

        push    cs
        pop     ds

        ; -------------------------------------------------------------
        ; Record raster interrupt.
        ; -------------------------------------------------------------

        inc     WORD PTR [RasterCount]

        ; -------------------------------------------------------------
        ; Calculate scrolling LUT index.
        ;
        ; Current scanline is 1..400.
        ;
        ; Convert to zero-based:
        ;
        ;     scanline - 1
        ;
        ; Then:
        ;
        ;     LUT = scanline - 1 - RainbowOffset
        ;
        ; We add 400 first so the subtraction cannot go negative.
        ;
        ; Result is wrapped into:
        ;
        ;     0..399
        ; -------------------------------------------------------------

        mov     ax,WORD PTR [NextScanline]
        dec     ax

        add     ax,VISIBLE_LINES

        sub     ax,WORD PTR [RainbowOffset]

        cmp     ax,VISIBLE_LINES
        jb      LUTIndexOK

        sub     ax,VISIBLE_LINES


LUTIndexOK:

        ; -------------------------------------------------------------
        ; Each LUT entry is three bytes:
        ;
        ;     red
        ;     green
        ;     blue
        ;
        ; Multiply index by three.
        ; -------------------------------------------------------------

        mov     bx,3
        mul     bx

        mov     si,OFFSET LutRGB
        add     si,ax

        ; -------------------------------------------------------------
        ; Select DAC register 7.
        ; -------------------------------------------------------------

        mov     dx,DAC_INDEX
        mov     al,DAC_COLOUR
        out     dx,al

        ; -------------------------------------------------------------
        ; Write RGB.
        ; -------------------------------------------------------------

        mov     dx,DAC_DATA

        mov     al,BYTE PTR [si]
        out     dx,al

        mov     al,BYTE PTR [si+1]
        out     dx,al

        mov     al,BYTE PTR [si+2]
        out     dx,al

        ; -------------------------------------------------------------
        ; Advance to next scanline.
        ; -------------------------------------------------------------

        mov     ax,WORD PTR [NextScanline]
        inc     ax

        cmp     ax,VISIBLE_LINES+1
        jb      StoreNextScanline

        ; -------------------------------------------------------------
        ; 400 -> 1.
        ;
        ; One complete raster frame has elapsed.
        ; -------------------------------------------------------------

        mov     ax,1

        inc     WORD PTR [FrameCount]

        ; -------------------------------------------------------------
        ; Advance the rainbow by one LUT entry.
        ;
        ; This causes the colour pattern to move down the screen.
        ;
        ; 399 -> 0
        ; -------------------------------------------------------------

        inc     WORD PTR [RainbowOffset]

        cmp     WORD PTR [RainbowOffset],VISIBLE_LINES
        jb      StoreNextScanline

        mov     WORD PTR [RainbowOffset],0


StoreNextScanline:

        mov     WORD PTR [NextScanline],ax

        ; -------------------------------------------------------------
        ; Arm next raster interrupt.
        ; -------------------------------------------------------------

        mov     dx,RASTER_PORT

        out     dx,al

        mov     al,ah
        out     dx,al

        mov     al,RASTER_VECTOR
        out     dx,al

        pop     ds
        pop     si
        pop     dx
        pop     bx
        pop     ax

        iret

RasterISR ENDP


; =====================================================================
; BuildLUT
;
; Build 400 RGB entries representing one complete continuous rainbow.
;
; We calculate:
;
;     position = scanline * 378 / 400
;
; giving a range of:
;
;     0 .. 377
;
; The six colour transitions each occupy 63 units:
;
;       0 ..  62  RED    -> YELLOW
;      63 .. 125  YELLOW -> GREEN
;     126 .. 188  GREEN  -> CYAN
;     189 .. 251  CYAN   -> BLUE
;     252 .. 314  BLUE   -> MAGENTA
;     315 .. 377  MAGENTA-> RED
;
; =====================================================================

BuildLUT PROC NEAR

        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        mov     di,OFFSET LutRGB

        xor     bx,bx

BuildLUTLoop:

        ; -------------------------------------------------------------
        ; AX = scanline index, 0 .. 399.
        ;
        ; Calculate:
        ;
        ;     AX * 378 / 400
        ;
        ; Result:
        ;
        ;     AX = hue position, 0 .. 377
        ;     DX = remainder
        ; -------------------------------------------------------------

        mov     ax,bx
        mov     dx,378
        mul     dx

        mov     cx,400
        div     cx

        ; -------------------------------------------------------------
        ; Divide hue position by 63.
        ;
        ; AX = phase 0 .. 5
        ; DX = interpolation value 0 .. 62
        ; -------------------------------------------------------------

        xor     dx,dx
        mov     cx,63
        div     cx

        ; -------------------------------------------------------------
        ; AX = phase
        ; DX = interpolation
        ; -------------------------------------------------------------

        cmp     ax,0
        je      LUTRedYellow

        cmp     ax,1
        je      LUTYellowGreen

        cmp     ax,2
        je      LUTGreenCyan

        cmp     ax,3
        je      LUTCyanBlue

        cmp     ax,4
        je      LUTBlueMagenta

        jmp     LUTMagentaRed


; ---------------------------------------------------------------------
; RED -> YELLOW
;
; R = 63
; G = interpolation
; B = 0
; ---------------------------------------------------------------------

LUTRedYellow:

        mov     al,63
        stosb

        mov     ax,dx
        stosb

        xor     al,al
        stosb

        jmp     LUTNext


; ---------------------------------------------------------------------
; YELLOW -> GREEN
;
; R = 63 - interpolation
; G = 63
; B = 0
; ---------------------------------------------------------------------

LUTYellowGreen:

        mov     ax,63
        sub     ax,dx
        stosb

        mov     al,63
        stosb

        xor     al,al
        stosb

        jmp     LUTNext


; ---------------------------------------------------------------------
; GREEN -> CYAN
;
; R = 0
; G = 63
; B = interpolation
; ---------------------------------------------------------------------

LUTGreenCyan:

        xor     al,al
        stosb

        mov     al,63
        stosb

        mov     ax,dx
        stosb

        jmp     LUTNext


; ---------------------------------------------------------------------
; CYAN -> BLUE
;
; R = 0
; G = 63 - interpolation
; B = 63
; ---------------------------------------------------------------------

LUTCyanBlue:

        xor     al,al
        stosb

        mov     ax,63
        sub     ax,dx
        stosb

        mov     al,63
        stosb

        jmp     LUTNext


; ---------------------------------------------------------------------
; BLUE -> MAGENTA
;
; R = interpolation
; G = 0
; B = 63
; ---------------------------------------------------------------------

LUTBlueMagenta:

        mov     ax,dx
        stosb

        xor     al,al
        stosb

        mov     al,63
        stosb

        jmp     LUTNext


; ---------------------------------------------------------------------
; MAGENTA -> RED
;
; R = 63
; G = 0
; B = 63 - interpolation
; ---------------------------------------------------------------------

LUTMagentaRed:

        mov     al,63
        stosb

        xor     al,al
        stosb

        mov     ax,63
        sub     ax,dx
        stosb


LUTNext:

        inc     bx

        cmp     bx,VISIBLE_LINES
        jb      BuildLUTLoop

        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax

        ret

BuildLUT ENDP


; =====================================================================
; PrintString
;
; DS:DX -> DOS $-terminated string.
; =====================================================================

PrintString PROC NEAR

        push    ax

        mov     ah,09h
        int     21h

        pop     ax

        ret

PrintString ENDP


; =====================================================================
; PrintHexWord
;
; AX = value to print as four hexadecimal digits.
; =====================================================================

PrintHexWord PROC NEAR

        push    ax
        push    bx
        push    cx
        push    dx

        mov     bx,ax
        mov     cx,4

PrintHexLoop:

        rol     bx,1
        rol     bx,1
        rol     bx,1
        rol     bx,1

        mov     dl,bl
        and     dl,0Fh

        cmp     dl,9
        jbe     PrintHexDigit

        add     dl,'A'-10
        jmp     OutputHexDigit


PrintHexDigit:

        add     dl,'0'


OutputHexDigit:

        mov     ah,02h
        int     21h

        loop    PrintHexLoop

        pop     dx
        pop     cx
        pop     bx
        pop     ax

        ret

PrintHexWord ENDP


; =====================================================================
; Debug strings
; =====================================================================

MsgStart       DB 13,10,"TINYRAIN VGA SCROLLING RAINBOW",13,10
               DB "Author: Gregory Fenton", 13, 10
               DB "https://github.com/gregoryfenton/dosstuff/tree/main/scanline-interrupt",13,10

               DB "--------------------------------",13,10
               DB "DAC colour 7 = continuous rainbow",13,10
               DB "RED -> YELLOW -> GREEN -> CYAN -> BLUE -> MAGENTA",13,10
               DB "Colour changes every raster scanline.",13,10
               DB "Rainbow scrolls DOWN one LUT entry per frame.",13,10
               DB "Debug output = every 10 raster frames",13,10
               DB "400 interrupts/frame, 4000 interrupts/message",13,10
               DB "$"

MsgVector      DB "INT 60h vector saved.",13,10,"$"

MsgMode        DB "VGA mode 03h set.",13,10,"$"

MsgLUT         DB "400-line RGB rainbow LUT built.",13,10,"$"

MsgInstalled   DB "INT 60h installed.",13,10,"$"

MsgArmed       DB "Raster target 0001h armed.",13,10,"$"

MsgRunning     DB "Raster running - press any key to exit.",13,10,"$"

MsgIRQ         DB "IRQ count = $"

MsgFrame       DB "  frame = $"

MsgScanline    DB "  scanline = $"

MsgOffset      DB "  offset = $"

MsgCRLF        DB 13,10,"$"

MsgKey         DB 13,10,"Key detected - shutting down.",13,10,"$"

MsgExit        DB "Raster disabled, INT 60h restored.",13,10
               DB "Returning to DOS.",13,10,"$"


; =====================================================================
; Runtime state
; =====================================================================

OldVectorOff   DW 0
OldVectorSeg   DW 0

NextScanline   DW 1
FrameCount     DW 0

RasterCount    DW 0
LastDebugCount DW 0

RainbowOffset  DW 0


; =====================================================================
; RGB lookup table
;
; 400 entries x 3 bytes = 1200 bytes.
; =====================================================================

LutRGB         DB 1200 DUP (0)


END START
