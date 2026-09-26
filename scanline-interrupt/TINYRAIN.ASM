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
;      ML /AT TINYRAIN.ASM;
;
; NON-TSR DEBUG VERSION
;
; This is an ordinary .COM program. It installs INT 60h while it is
; running, exercises the synthetic raster interrupt, changes VGA DAC
; register dynamically once per scanline, displays debug information, and
; restores INT 60h before exit.
;
; Raster interrupt:
;
;      INT 60h
;
; Raster target:
;
;      Port 62h
;
; VGA DAC:
;
;      3C8h = DAC index
;      3C9h = DAC data
;
; DAC register specified by DAC_COLOUR is changed on every raster interrupt.
;
; The 400 scanlines contain one complete continuous RGB rainbow:
;
;      RED -> YELLOW -> GREEN -> CYAN -> BLUE -> MAGENTA -> RED
;
; The rainbow is vertically scrolled.
;
; RainbowOffset advances once per complete raster frame.
;
; The lookup is:
;
;      LUT index = scanline - RainbowOffset
;
; wrapping around at 400.
;
; Increasing RainbowOffset therefore moves the colour pattern DOWN
; the screen.
;
; Each DAC component is 6-bit:
;
;      0 .. 63
;
; Debug output is printed every 10 complete 400-line raster frames:
;
;      400 interrupts/frame
;      10 frames
;      4000 interrupts/debug message
;
; =====================================================================

.MODEL TINY
.286
.CODE
ORG 100h

RASTER_PORT      EQU 0062h
RASTER_VECTOR    EQU 060h

DAC_INDEX        EQU 03C8h
DAC_DATA         EQU 03C9h
DAC_COLOUR       EQU 0

VISIBLE_LINES    EQU 400

DEBUG_IRQS       EQU 4000


START:
        ; Set up data segment to match code segment (standard .COM model)
        mov     ax,cs
        mov     ds,ax

        ; -------------------------------------------------------------
        ; VGA text mode 03h.
        ; Invokes BIOS video service to switch into standard 80x25 text mode
        ; with a 400-line vertical active display structure.
        ; -------------------------------------------------------------

        mov     ax,0003h
        int     10h
        ; -------------------------------------------------------------
        ; Dynamically format DAC_COLOUR into the startup message string.
        ; Converts the byte value into a 2-character hexadecimal representation.
        ; -------------------------------------------------------------

        mov     al,DAC_COLOUR
        mov     ah,al
        shr     al,4            ; Process high nibble
        call    NibbleToAscii
        mov     BYTE PTR [MsgColHex],al

        mov     al,ah           ; Process low nibble
        and     al,0Fh
        call    NibbleToAscii
        mov     BYTE PTR [MsgColHex+1],al

        mov     dx,OFFSET MsgStart
        call    PrintString

        ; -------------------------------------------------------------
        ; Get the existing INT 60h vector.
        ; DOS function 35h retrieves the current interrupt vector table address,
        ; returning the segment in ES and offset in BX.
        ; -------------------------------------------------------------

        mov     ax,3560h
        int     21h

        mov     WORD PTR [OldVectorOff],bx
        mov     WORD PTR [OldVectorSeg],es

        mov     dx,OFFSET MsgVector
        call    PrintString

        mov     dx,OFFSET MsgMode
        call    PrintString

        ; -------------------------------------------------------------
        ; Build the 400-line rainbow lookup table.
        ; Precalculates all RGB values for a smooth 6-phase colour cycle.
        ; -------------------------------------------------------------

        call    BuildLUT

        mov     dx,OFFSET MsgLUT
        call    PrintString

        ; -------------------------------------------------------------
        ; Runtime state initialization.
        ; -------------------------------------------------------------

        mov     WORD PTR [NextScanline],1
        mov     WORD PTR [FrameCount],0
        mov     WORD PTR [RasterCount],0
        mov     WORD PTR [LastDebugCount],0
        mov     WORD PTR [RainbowOffset],0

        ; -------------------------------------------------------------
        ; Install INT 60h.
        ; CLI/STI bracket the vector replacement to prevent race conditions
        ; during hardware or software interrupt dispatching.
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
        ; Sends target scanline 1 to custom port 0x62 to prime the emulator loop.
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
        ; BIOS function 16h (AH=01h) checks if a key is waiting in the buffer.
        ; -------------------------------------------------------------

        mov     ah,01h
        int     16h
        jz      NoKey

        ; Key is available - consume it from the buffer and exit.
        mov     ah,00h
        int     16h

        mov     dx,OFFSET MsgKey
        call    PrintString

        jmp     ExitProgram


NoKey:

        ; -------------------------------------------------------------
        ; Has another 10-frame block completed?
        ; Compares total elapsed interrupts against the tracking watermark.
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
        ; Print structured telemetry:
        ;   - IRQ count
        ;   - Frame count
        ;   - Current target scanline
        ;   - Rainbow scrolling offset
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
; Restore DAC register to DOS light grey.
; Return normally to DOS.
; =====================================================================

ExitProgram:

        cli

        ; -------------------------------------------------------------
        ; Disable synthetic raster:
        ; Writing target = 0000h via port 0x62 clears the enabled flag
        ; inside the emulator state machine.
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
        ; Uses DOS function 25h with the saved segment/offset pair.
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
        ; Restore DOS light-grey DAC colour for DAC_COLOUR.
        ; VGA DAC values are 6-bit (range 0..63).
        ; 42 decimal = 2Ah provides standard light grey intensity.
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
; Sends the 3-byte protocol to port 0x62:
;      1. Low byte of scanline
;      2. High byte of scanline
;      3. Interrupt vector ID / commit byte
; =====================================================================

CommitRasterTarget PROC NEAR

        push    ax
        push    dx

        mov     dx,RASTER_PORT

        ; Send low byte of scanline target
        out     dx,al

        ; Send high byte of scanline target
        mov     al,ah
        out     dx,al

        ; Send interrupt vector (triggers commit in backend hardware model)
        mov     al,RASTER_VECTOR
        out     dx,al

        pop     dx
        pop     ax

        ret

CommitRasterTarget ENDP


; =====================================================================
; RasterISR
;
; One invocation occurs for each selected VGA scanline via INT 60h.
;
; The ISR workflow:
;      1. Saves registers and establishes local data context
;      2. Increments global raster interrupt counter
;      3. Calculates scrolling lookup table position with bounds wrapping
;      4. Updates VGA DAC register dynamically via ports 0x3C8/0x3C9
;      5. Advances and cycles the active scanline counter (1..400)
;      6. Detects frame boundaries and advances the rainbow offset
;      7. Re-arms the custom hardware port for the next target scanline
;      8. Restores registers and executes IRET
; =====================================================================

RasterISR PROC FAR

        push    ax
        push    bx
        push    dx
        push    si
        push    ds

        ; Bind DS to CS to safely access local code-segment variables
        push    cs
        pop     ds

        ; -------------------------------------------------------------
        ; Record raster interrupt count.
        ; -------------------------------------------------------------

        inc     WORD PTR [RasterCount]

        ; -------------------------------------------------------------
        ; Calculate scrolling LUT index.
        ;
        ; Current scanline ranges from 1 to 400.
        ; Converted to zero-based index: (scanline - 1)
        ; Factoring offset: (scanline - 1 - RainbowOffset)
        ; Adding VISIBLE_LINES (400) first prevents underflow during subtraction.
        ; Final value is clamped via modulo/subtraction to stay in 0..399.
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
        ; Each LUT entry consists of 3 bytes (Red, Green, Blue).
        ; Multiplies table index by 3 to locate the exact byte offset.
        ; -------------------------------------------------------------

        mov     bx,3
        mul     bx

        mov     si,OFFSET LutRGB
        add     si,ax

        ; -------------------------------------------------------------
        ; Select DAC register index for real-time modification.
        ; -------------------------------------------------------------

        mov     dx,DAC_INDEX
        mov     al,DAC_COLOUR
        out     dx,al

        ; -------------------------------------------------------------
        ; Write RGB triplet directly to DAC data port (0x3C9).
        ; Hardware latches these values instantly for the active trace line.
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
        ; Frame boundary reached (Scanline 400 completed).
        ; Reset line counter back to 1 and bump frame counter.
        ; -------------------------------------------------------------

        mov     ax,1

        inc     WORD PTR [FrameCount]

        ; -------------------------------------------------------------
        ; Advance the rainbow position by one LUT entry per frame.
        ; Creates the illusion of a smooth downward waterfall animation.
        ; Wraps around if offset reaches 400.
        ; -------------------------------------------------------------

        inc     WORD PTR [RainbowOffset]

        cmp     WORD PTR [RainbowOffset],VISIBLE_LINES
        jb      StoreNextScanline

        mov     WORD PTR [RainbowOffset],0


StoreNextScanline:

        mov     WORD PTR [NextScanline],ax

        ; -------------------------------------------------------------
        ; Arm next raster interrupt via port 0x62 protocol.
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
; Generates 400 RGB entries mapping out a full continuous colour spectrum.
;
; Scaling formula maps scanline indices to a 378-unit hue scale:
;      position = scanline * 378 / 400
;
; The spectrum splits into six 63-unit gradient phases:
;        0 ..  62   RED    -> YELLOW
;       63 .. 125   YELLOW -> GREEN
;      126 .. 188   GREEN  -> CYAN
;      189 .. 251   CYAN   -> BLUE
;      252 .. 314   BLUE   -> MAGENTA
;      315 .. 377   MAGENTA-> RED
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
        ; AX = scanline index (0 .. 399 in BX).
        ; Performs fixed-point scaling: (BX * 378) / 400
        ; AX = scaled hue position (0 .. 377), DX = remainder.
        ; -------------------------------------------------------------

        mov     ax,bx
        mov     dx,378
        mul     dx

        mov     cx,400
        div     cx

        ; -------------------------------------------------------------
        ; Divide hue position by 63 to determine phase and sub-ramp offset.
        ; AX = phase index (0 .. 5)
        ; DX = interpolation value (0 .. 62)
        ; -------------------------------------------------------------

        xor     dx,dx
        mov     cx,63
        div     cx

        ; Dispatch based on current phase block
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
; Phase 0: RED -> YELLOW (Red constant at max 63, Green ramps up, Blue 0)
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
; Phase 1: YELLOW -> GREEN (Red ramps down from 63, Green constant at 63, Blue 0)
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
; Phase 2: GREEN -> CYAN (Red 0, Green constant at 63, Blue ramps up)
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
; Phase 3: CYAN -> BLUE (Red 0, Green ramps down from 63, Blue constant at 63)
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
; Phase 4: BLUE -> MAGENTA (Red ramps up, Green 0, Blue constant at 63)
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
; Phase 5: MAGENTA -> RED (Red constant at 63, Green 0, Blue ramps down)
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
; NibbleToAscii
;
; Converts a 4-bit value in AL (0h..Fh) to its hexadecimal ASCII character.
; =====================================================================

NibbleToAscii PROC NEAR

        cmp     al,9
        jbe     NibbleIsDigit
        add     al,7

NibbleIsDigit:
        add     al,'0'
        ret

NibbleToAscii ENDP


; =====================================================================
; PrintString
;
; DS:DX -> DOS dollar-terminated string handler.
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
; Converts and outputs the 16-bit value in AX as four hexadecimal digits.
; =====================================================================

PrintHexWord PROC NEAR

        push    ax
        push    bx
        push    cx
        push    dx

        mov     bx,ax
        mov     cx,4

PrintHexLoop:

        ; Rotate left by 4 bits to bring the next nibble into position
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
; Debug strings and data blocks
; =====================================================================

MsgStart        DB 13,10,"TINYRAIN VGA SCROLLING RAINBOW",13,10
               DB "Author: Gregory Fenton", 13, 10
               DB "https://github.com/gregoryfenton/dosstuff/tree/main/scanline-interrupt",13,10

               DB "--------------------------------",13,10
               DB "DAC colour "
MsgColHex      DB "00"
               DB " = continuous rainbow",13,10
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
; Runtime state variables
; =====================================================================

OldVectorOff   DW 0
OldVectorSeg   DW 0

NextScanline   DW 1
FrameCount     DW 0

RasterCount    DW 0
LastDebugCount DW 0

RainbowOffset  DW 0


; =====================================================================
; RGB lookup table allocation
; 400 entries * 3 bytes (R, G, B) = 1200 bytes total.
; =====================================================================

LutRGB         DB 1200 DUP (0)


END START
