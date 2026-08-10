# F030TREX

An Atari Falcon030 port (16 MHz, DSP56001) of the T-Rex renderer from PS1
Demo One (SCES-00048): a DSP56001 geometry/triangle-setup core paired with
an M68030 software rasterizer, targeting a 240x224 render surface inside a
256x224 Videl mode.

## Building

Requirements: `node`, `python3`, a C compiler/`make` for vasm and vlink
(built from the bundled tarballs), and optionally DOSBox to rebuild the DSP
program.

`TREX/dsp/trex_dsp.lod` is checked in prebuilt; `make trex_release` needs no
DOSBox for it. Rebuilding the DSP program after a change to `trex_dsp.asm`
does:

```sh
make DOSBOX=/Applications/dosbox.app/Contents/MacOS/DOSBox trex_dsp
```

The full-mesh occlusion-culling release package is built with:

```sh
make trex_release
```

This produces `TREX/m68030/TREX.TOS`: the full 2,724-triangle model with armed
DSP occlusion, textured Gouraud lighting, and no per-frame diagnostic file
writes.  Its matching `TREX.LOD` is copied beside it for deployment.

Run the release on a Falcon or under Hatari from the directory containing the
two files. For TOS 4.02 under Hatari:

```sh
hatari --machine falcon --tos /path/to/tos402.rom --dsp emu --memsize 4 \
  TREX.TOS
```

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
Videl mode. The supported release is a single full-mesh package: `TREX.TOS`
uses the 2,724-triangle model, DSP occlusion, and textured Gouraud shading;
`TREX.LOD` is the matching DSP program. The older flat-shaded and reduced-mesh
variants are not part of the release surface. Performance figures in
OPTIMIZATION.md are identified as Hatari/emulator results; physical Falcon030
timing remains unmeasured.
