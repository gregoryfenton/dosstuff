# DOS Programming & Demoscene Archive

Welcome to my personal repository dedicated to 16-bit MS-DOS programming, real-mode x86 assembly, and classic demoscene effects. This collection serves as a technical playground and historical archive for low-level hardware interaction, custom screen modes, raster timing tricks, and retro software engineering.

## Overview

Programming for vintage MS-DOS environments forces a return to bare-metal principles - direct memory access, precise I/O port manipulation, and strict adherence to hardware cycles. Rather than relying on modern abstractions or heavy graphics frameworks, the projects housed here interact directly with the underlying hardware architecture of the IBM PC compatible.

Whether exploring standard 80x25 text mode visual tricks or fine-tuning scanline synchronisation, this archive captures the creative engineering spirit of classic demoscene productions implemented with modern toolchains.

## Core Focus Areas

* **Raster & Palette Manipulation:** Harnessing the VGA Digital-to-Analogue Converter (DAC) registers (`03C8h` and `03C9h`) to produce smooth gradient copper bars, split-screen colour shifts, and custom palettes without leaving text mode.
* **Timing & Synchronisation:** Eliminating screen tearing and jitter by locking application logic strictly to vertical and horizontal retrace intervals (`03DAh`).
* **Optimised Assembly:** Crafting compact, fast-executing 16-bit `.COM` binaries using MASM and compatible assemblers with `.MODEL TINY` memory models.
* **Retro UI & Scrollers:** Implementing efficient text-buffer shifts, character-based horizontal scrollers, and custom message rendering routines.

## Recommended Toolchain & Environment

To build and run the projects in this archive successfully, a standard 16-bit assembler and a reliable emulator are required:

* **Assembler:** Microsoft Macro Assembler (MASM) or JWASM.
* **Emulator:** DOSBox-Staging or DOSBox-X (configured with high cycle counts or max settings to test performance ceilings).

## Repository Structure

* `rainbow/` - A smooth-scrolling text mode copper bar effect featuring silvery grey, gold, and emerald green raster bars synchronised to 60Hz.
* *(Additional projects and utilities will be added here as the archive expands)*

## Author

Gregory Fenton (M0ODZ)
