# VGA Text Mode Smooth Rolling Copper Bars

A 16-bit real-mode x86 assembly demoscene intro featuring smooth raster copper bars and a horizontally scrolling text line running in standard VGA text mode. Designed for MASM and optimised for modern emulators like DOSBox-Staging.

## Video Demonstration

[![Watch the demo on YouTube](https://img.youtube.com/vi/W2slMkVjct0/0.jpg)](https://www.youtube.com/watch?v=W2slMkVjct0)

## Features

- **Raster Copper Bars:** Three independent 60-scanline triangular colour bars (Silvery Grey, Gold, and Emerald Green) moving at distinct velocities with full screen wrapping.
- **Smooth Horizontal Scroller:** A custom text message scrolling smoothly across row 12 at a comfortable, readable pace via frame-rate throttling.
- **Strict Raster Timing:** Synchronised precisely to vertical and horizontal retraces (`03DAh`) to completely eliminate screen tearing and jitter.
- **Pure Text Mode:** Operates entirely within standard 80x25 text mode (`0003h`), dynamically updating the DAC palette registers (`03C8h`/`03C9h`) per scanline while leaving text characters and attributes crisp and untouched.

## Requirements

- **Assembler:** Microsoft Macro Assembler (MASM) or a compatible clone (such as JWASM).
- **Environment:** DOSBox-Staging, DOSBox-X, or vintage MS-DOS hardware.

## Building the Project

To assemble the source code into a tiny `.com` executable using MASM, run the following command in your build environment:

```bash
ml /AT rainbow.asm
