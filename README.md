# F030TREX

An Atari Falcon030 port (16 MHz, DSP56001) of the T-Rex renderer from PS1
Demo One (SCES-00048): a DSP56001 geometry/triangle-setup core paired with
an M68030 software rasterizer, targeting a 240x224 render surface inside a
256x224 Videl mode.

## Building

Requirements: `node`, a C compiler/`make` for vasm and vlink
(built from the bundled tarballs), and optionally DOSBox to rebuild the DSP
program.

```sh
make trex_m68030
```

Output: `TREX/m68030/trex_m68030.tos`. Two more variants from the same
source:

```sh
make trex_m68030_run    # no per-frame GEMDOS writes (for viewing)
make trex_m68030_full   # the 2,724-triangle mesh
```

`TREX/dsp/trex_dsp.lod` is checked in prebuilt; `make trex_m68030` needs no
DOSBox for it. Rebuilding the DSP program after a change to `trex_dsp.asm`
does:

```sh
make DOSBOX=/Applications/dosbox.app/Contents/MacOS/DOSBox trex_dsp
```

## Running in Hatari

Use a Falcon configuration with TOS 4.02, 4 MB of ST-RAM, and DSP emulation
enabled. Mount `TREX/m68030` as the emulated GEMDOS drive and auto-start
`TREX_RUN.TOS`; the adjacent `trex_dsp.lod` must remain in that directory.

TOS 4.04 is not compatible with the current DSP load path: the program can
reach its video-mode setup, but the DSP remains closed, no triangle packets
are produced, and the display stays black. This is a TOS/DSP startup issue,
not an empty framebuffer or a renderer timing failure.

## Required reading

[AGENTS.md](AGENTS.md) and [OPTIMIZATION.md](OPTIMIZATION.md) are part of the
implementation, not optional notes: architecture, protocol formats, memory
budgets and every performance-relevant change are documented there and must
stay that way. [TREX/dsp/README.md](TREX/dsp/README.md) describes the DSP
core, its host protocol and its memory budget in detail.

Note: OPTIMIZATION.md is a running measurement log and occasionally names
analysis tooling (for example occlusion-culling or opaque-packet
self-tests) that is not part of this repository's build. Treat those
mentions as the historical record of how a figure was produced, not as
commands you can run here.

## Target and current state

Atari Falcon030, 16 MHz, DSP56001. Render target 240x224 inside a 256x224
Videl mode. The current build reaches 2.05 FPS on the 2,724-triangle mesh --
Hatari emulator timings, not a measurement on real hardware. See
OPTIMIZATION.md for the full measurement history and open roadmap.
