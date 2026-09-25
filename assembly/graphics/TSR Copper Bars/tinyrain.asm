; =====================================================================
; TINYRAIN.ASM
;
; VGA TEXT MODE RASTER TSR
;
; QBX / PDS 7.1
; DOSBox / DOSBox-Staging
;
; MASM 6.11:
;
;     ML /AT TINYRAIN.ASM;
;
; The TSR installs on INT 08h and programs PIT channel 0 to
; approximately the VGA horizontal scan frequency.
;
; One raster operation is performed per timer interrupt.
;
; This is deliberately NOT a long-running IRQ handler. The handler
; performs at most one horizontal-blank palette update and returns.
;
; This allows keyboard IRQ 1 and other hardware interrupts to run.
;
; The original BIOS INT 08h handler is chained approximately 18.2
; times per second so DOS keeps its normal clock.
;
; Running TINYRAIN a second time detects the resident copy, restores
; the original INT 08h vector, restores the PIT, resets palette index
; zero, frees the resident environment and resident program block,
; then exits normally to DOS.
;
; =====================================================================

.MODEL TINY
.286
.CODE
ORG 100h

start:
    jmp     tsr_init

; =====================================================================
; RESIDENT DATA
; =====================================================================

signature       db      "TINYRAIN"

old_int08       dd      0

bar0_pos        dw      0

; Current visible raster scanline.
;
; 0..399 = active display scanlines.
; 400    = finished active display, waiting for vertical blank.
;
scanline        dw      400

; Previous vertical blank state.
;
; 0 = not in vertical blank
; 1 = in vertical blank
;
in_vblank       db      0

; Re-entrancy guard.
;
; Normally IRQ 0 cannot re-enter itself through the PIC, but keep the
; guard because this handler is intended to be robust under emulation.
;
in_isr          db      0

; ---------------------------------------------------------------------
; BIOS clock phase accumulator.
;
; PIT is approximately 31399.5 Hz.
;
; BIOS needs approximately 18.20648 calls per second.
;
; The phase increment is:
;
;     18.20648 / 31399.526 * 2^32
;
; approximately 2490364.
;
; The 32-bit accumulator naturally overflows and the carry tells us
; when to chain the BIOS INT 08 handler.
; ---------------------------------------------------------------------

clock_phase_lo  dw      0
clock_phase_hi  dw      0

CLOCK_PHASE_INC_LO EQU 2490364 AND 0FFFFh
CLOCK_PHASE_INC_HI EQU 2490364 SHR 16

; ---------------------------------------------------------------------
; PIT divisor.
;
; PIT input = approximately 1,193,182 Hz.
;
; 1,193,182 / 38 = approximately 31,399.5 Hz.
;
; VGA horizontal frequency is approximately 31,469 Hz.
;
; This gives approximately one IRQ per VGA scanline.
; ---------------------------------------------------------------------

PIT_COUNT       EQU     38

; ---------------------------------------------------------------------
; RGB lookup table.
;
; 400 scanlines x 3 bytes.
; ---------------------------------------------------------------------

lut_rgb         db      1200 dup(0)

; =====================================================================
; INT 08h HANDLER
; =====================================================================

timer_isr PROC FAR

    pusha
    push    ds
    push    es

    push    cs
    pop     ds

    ; ---------------------------------------------------------------
    ; Re-entrancy guard.
    ; ---------------------------------------------------------------

    cmp     byte ptr [in_isr], 0
    jne     isr_reentrant

    mov     byte ptr [in_isr], 1

    ; ---------------------------------------------------------------
    ; Check VGA text mode 3.
    ;
    ; BIOS data area:
    ;
    ; 0040:0049 = current video mode.
    ; ---------------------------------------------------------------

    mov     ax, 0040h
    mov     es, ax

    mov     al, byte ptr es:[0049h]
    cmp     al, 3
    jne     raster_done

    ; ---------------------------------------------------------------
    ; Read VGA status register.
    ;
    ; Bit 3 = vertical retrace.
    ; Bit 0 = horizontal retrace.
    ; ---------------------------------------------------------------

    mov     dx, 03DAh
    in      al, dx

    test    al, 8
    jz      not_in_vblank

    ; ---------------------------------------------------------------
    ; We are in vertical blank.
    ;
    ; Mark the frame as waiting for active display.
    ; ---------------------------------------------------------------

    mov     byte ptr [in_vblank], 1
    mov     word ptr [scanline], 400

    jmp     raster_done

not_in_vblank:

    ; ---------------------------------------------------------------
    ; If this is the first interrupt after vertical blank, start a
    ; new 400-line raster.
    ; ---------------------------------------------------------------

    cmp     byte ptr [in_vblank], 0
    je      active_frame

    mov     byte ptr [in_vblank], 0

    mov     word ptr [scanline], 0

    ; Decrement the moving colour bar once per frame to move top-to-bottom
    dec     word ptr [bar0_pos]

    jns     active_frame

    mov     word ptr [bar0_pos], 399

active_frame:

    ; ---------------------------------------------------------------
    ; Only raster the 400 visible scanlines.
    ; ---------------------------------------------------------------

    cmp     word ptr [scanline], 400
    jae     raster_done

    ; ---------------------------------------------------------------
    ; Calculate the LUT pointer:
    ;
    ;     ((bar0_pos + scanline) mod 400) * 3
    ;
    ; bar0_pos and scanline are both 0..399, so the sum is at most
    ; 798 and only one subtraction is necessary.
    ; ---------------------------------------------------------------

    mov     ax, [bar0_pos]
    add     ax, [scanline]

    cmp     ax, 400
    jb      lut_index_ok

    sub     ax, 400

lut_index_ok:

    mov     bx, 3
    mul     bx

    add     ax, OFFSET lut_rgb
    mov     si, ax

    ; Pre-load RGB values into CPU registers to minimize DAC write cycles
    mov     bl, cs:[si]
    mov     bh, cs:[si+1]
    mov     ch, cs:[si+2]

    ; ---------------------------------------------------------------
    ; Wait for horizontal blank.
    ;
    ; This is ONE scanline only.
    ;
    ; A timeout is used so a bad/emulated status register cannot leave
    ; IRQ 0 permanently stuck.
    ; ---------------------------------------------------------------

    mov     dx, 03DAh

    mov     cl, 200

wait_hblank_active:

    in      al, dx
    test    al, 1
    jnz     hblank_active_seen

    dec     cl
    jnz     wait_hblank_active

    jmp     raster_done

hblank_active_seen:

    mov     cl, 200

wait_hblank_blank:

    in      al, dx
    test    al, 1
    jz      hblank_blank_seen

    dec     cl
    jnz     wait_hblank_blank

    jmp     raster_done

hblank_blank_seen:

    ; ---------------------------------------------------------------
    ; Write RGB value to DAC palette index 0.
    ; Executed with zero memory fetches during critical hblank window.
    ; ---------------------------------------------------------------

    mov     dx, 03C8h

    xor     al, al
    out     dx, al

    inc     dx          ; 03C9h DAC Data Register

    mov     al, bl      ; Red
    out     dx, al

    mov     al, bh      ; Green
    out     dx, al

    mov     al, ch      ; Blue
    out     dx, al

    ; ---------------------------------------------------------------
    ; Advance to next visible scanline.
    ; ---------------------------------------------------------------

    inc     word ptr [scanline]

raster_done:

    mov     byte ptr [in_isr], 0

isr_clock:

    ; =================================================================
    ; BIOS CLOCK SCALING
    ;
    ; Add the fractional BIOS clock rate to the 32-bit phase
    ; accumulator.
    ;
    ; A carry means that enough high-frequency PIT interrupts have
    ; accumulated for one BIOS INT 08 call.
    ; =================================================================

    mov     ax, CLOCK_PHASE_INC_LO

    add     word ptr cs:[clock_phase_lo], ax

    mov     ax, CLOCK_PHASE_INC_HI

    adc     word ptr cs:[clock_phase_hi], ax

    jc      chain_bios

isr_reentrant:

    ; ---------------------------------------------------------------
    ; No BIOS clock tick this time.
    ;
    ; We own the IRQ, so acknowledge IRQ 0 ourselves.
    ; ---------------------------------------------------------------

    mov     al, 20h
    out     20h, al

    pop     es
    pop     ds
    popa

    iret

chain_bios:

    ; ---------------------------------------------------------------
    ; BIOS INT 08 performs the PIC EOI itself.
    ;
    ; We must restore registers before jumping to the original handler.
    ; ---------------------------------------------------------------

    pop     es
    pop     ds
    popa

    jmp     cs:[old_int08]

timer_isr ENDP

; =====================================================================
; BUILD RGB LOOKUP TABLE
; =====================================================================

build_lut PROC

    pusha

    xor     cx, cx

lut_loop:

    ; ---------------------------------------------------------------
    ; Red
    ; ---------------------------------------------------------------

    mov     ax, cx

    call    calc_bar_val

    mov     bx, cx
    mov     dx, 3

    push    ax

    mov     ax, bx
    mul     dx

    mov     di, ax

    pop     ax

    mov     lut_rgb[di], al

    ; ---------------------------------------------------------------
    ; Green
    ; ---------------------------------------------------------------

    mov     ax, cx
    add     ax, 133

    call    calc_bar_val

    mov     lut_rgb[di+1], al

    ; ---------------------------------------------------------------
    ; Blue
    ; ---------------------------------------------------------------

    mov     ax, cx
    add     ax, 266

    call    calc_bar_val

    mov     lut_rgb[di+2], al

    inc     cx

    cmp     cx, 400
    jl      lut_loop

    popa

    ret

build_lut ENDP

; =====================================================================
; CALCULATE TRIANGULAR BAR VALUE
; =====================================================================

calc_bar_val PROC

    cwd

    mov     bx, 400

    idiv    bx

    mov     ax, dx

    cmp     ax, 64
    jae     val_off

    cmp     ax, 32
    jbe     val_rising

    neg     ax
    add     ax, 64

val_rising:

    ; Scaled peak to maintain background contrast under high text density
    shr     ax, 1

    ret

val_off:

    xor     ax, ax

    ret

calc_bar_val ENDP

; =====================================================================
; INITIALISATION
; =====================================================================

tsr_init:

    ; -----------------------------------------------------------------
    ; DS = our .COM PSP/code segment.
    ; -----------------------------------------------------------------

    push    cs
    pop     ds

    ; -----------------------------------------------------------------
    ; Get current INT 08 vector.
    ;
    ; ES:BX = current handler.
    ; -----------------------------------------------------------------

    mov     ax, 3508h
    int     21h

    ; -----------------------------------------------------------------
    ; First check the handler offset.
    ;
    ; A resident copy of this exact .COM image has the same handler
    ; offset because its internal layout is identical.
    ;
    ; This avoids examining arbitrary memory unless the offset matches.
    ; -----------------------------------------------------------------

    cmp     bx, OFFSET timer_isr
    jne     install_tsr

    ; -----------------------------------------------------------------
    ; Check the signature immediately preceding old_int08.
    ;
    ; signature is located at:
    ;
    ;     timer_isr + (signature - timer_isr)
    ;
    ; which is simply OFFSET signature.
    ; -----------------------------------------------------------------

    push    ds
    push    es

    push    cs
    pop     ds

    mov     si, OFFSET signature

    mov     di, bx
    add     di, signature - timer_isr

    mov     cx, 8

    cld

    repe    cmpsb

    pop     es
    pop     ds

    je      uninstall_tsr

; =====================================================================
; INSTALL
; =====================================================================

install_tsr:

    ; -----------------------------------------------------------------
    ; Save the original INT 08 vector.
    ; -----------------------------------------------------------------

    mov     word ptr [old_int08], bx
    mov     word ptr [old_int08+2], es

    ; -----------------------------------------------------------------
    ; Initialise raster state.
    ; -----------------------------------------------------------------

    mov     word ptr [bar0_pos], 0
    mov     word ptr [scanline], 400

    mov     byte ptr [in_vblank], 0
    mov     byte ptr [in_isr], 0

    mov     word ptr [clock_phase_lo], 0
    mov     word ptr [clock_phase_hi], 0

    ; -----------------------------------------------------------------
    ; Build LUT before installing the handler.
    ; -----------------------------------------------------------------

    call    build_lut

    ; -----------------------------------------------------------------
    ; Disable interrupts while changing the vector and PIT.
    ; -----------------------------------------------------------------

    cli

    ; -----------------------------------------------------------------
    ; Install INT 08.
    ;
    ; INT 21h/AH=25h expects DS:DX.
    ; -----------------------------------------------------------------

    push    ds

    push    cs
    pop     ds

    mov     dx, OFFSET timer_isr

    mov     ax, 2508h
    int     21h

    pop     ds

    ; -----------------------------------------------------------------
    ; Program PIT channel 0.
    ;
    ; Mode 3, binary, channel 0.
    ;
    ; Divisor 38:
    ;
    ;     1193182 / 38 = approximately 31399.5 Hz
    ; -----------------------------------------------------------------

    mov     al, 36h
    out     43h, al

    mov     ax, PIT_COUNT

    out     40h, al

    mov     al, ah
    out     40h, al

    sti

    ; -----------------------------------------------------------------
    ; Installation message.
    ; -----------------------------------------------------------------

    push    cs
    pop     ds

    mov     dx, OFFSET msg_installed

    mov     ah, 09h
    int     21h

    ; -----------------------------------------------------------------
    ; Terminate and stay resident.
    ;
    ; Keep everything through resident_end.
    ; -----------------------------------------------------------------

    mov     dx, OFFSET resident_end

    add     dx, 15

    mov     cl, 4
    shr     dx, cl

    mov     ax, 3100h

    int     21h

; =====================================================================
; UNINSTALL
; =====================================================================

uninstall_tsr:

    ; -----------------------------------------------------------------
    ; At this point:
    ;
    ; DS = temporary uninstall program's PSP/code segment
    ; ES = resident TINYRAIN PSP/code segment
    ;
    ; The resident block must NOT be treated as the temporary program.
    ; -----------------------------------------------------------------

    cli

    ; -----------------------------------------------------------------
    ; Restore the standard PIT rate.
    ;
    ; Divisor zero means 65536, giving the traditional approximately
    ; 18.2 Hz rate.
    ; -----------------------------------------------------------------

    mov     al, 36h
    out     43h, al

    xor     al, al

    out     40h, al
    out     40h, al

    ; -----------------------------------------------------------------
    ; Restore the original INT 08 vector.
    ;
    ; old_int08 is in the resident block currently addressed by ES.
    ;
    ; INT 21h/AH=25h needs DS:DX, so load DS with the saved handler
    ; segment (es:[old_int08+2]) and DX with offset (es:[old_int08]).
    ; -----------------------------------------------------------------

    push    ds

    mov     dx, word ptr es:[old_int08]
    mov     ds, word ptr es:[old_int08+2]

    mov     ax, 2508h

    int     21h

    pop     ds

    sti

    ; -----------------------------------------------------------------
    ; Reset DAC palette index 0 to black.
    ; -----------------------------------------------------------------

    mov     dx, 03C8h

    xor     al, al

    out     dx, al

    inc     dx

    out     dx, al
    out     dx, al
    out     dx, al

    ; -----------------------------------------------------------------
    ; Report successful removal.
    ;
    ; We must do this before freeing the resident block.
    ; -----------------------------------------------------------------

    push    cs
    pop     ds

    mov     dx, OFFSET msg_uninstalled

    mov     ah, 09h

    int     21h

    ; -----------------------------------------------------------------
    ; Free the resident environment block.
    ;
    ; ES still points at the resident PSP.
    ;
    ; PSP:002C contains the environment segment.
    ; -----------------------------------------------------------------

    mov     ax, es:[002Ch]

    or      ax, ax

    jz      free_resident

    push    es

    mov     es, ax

    mov     ah, 49h

    int     21h

    pop     es

free_resident:

    ; -----------------------------------------------------------------
    ; Free the resident TSR's main memory block.
    ;
    ; ES = resident PSP segment.
    ;
    ; After this instruction we must not execute any resident code.
    ; -----------------------------------------------------------------

    mov     ah, 49h

    int     21h

    ; -----------------------------------------------------------------
    ; This code belongs to the temporary uninstall invocation, not
    ; the resident TSR, so it is still safe to execute.
    ; -----------------------------------------------------------------

    mov     ax, 4C00h

    int     21h

; =====================================================================
; MESSAGES
; =====================================================================

msg_installed:
    db      "TINYRAIN TSR Installed successfully.", 0Dh, 0Ah, '$'

msg_uninstalled:
    db      "TINYRAIN TSR Uninstalled successfully.", 0Dh, 0Ah, '$'

; =====================================================================
; END OF RESIDENT IMAGE
; =====================================================================

resident_end:

END start
