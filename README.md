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
writes.  Its matching `TREX.LOD` is copied beside it for deployment, and
`TREX/m68030/README.TXT` is the 40-column, CRLF release note that ships with
them; those three files together are the release archive.

The release also draws a frame-rate readout in the top-left corner: white
`NN.NN` frames per second, fixed width so the digits never shift column.  It is
built from `-DTREX_FPS` and is on the release target only -- it writes into the
framebuffer, so the diagnostic and capture binaries deliberately omit it (see
OPTIMIZATION.md 2.6).

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

## Feature comparison with the PS1 reference

The port preserves the source model and animation data, but its execution
pipeline is deliberately Falcon-specific. This table describes the current
release rather than claiming pixel-for-pixel equivalence with the PS1 demo.

| Feature | PS1 reference | Falcon port (`TREX.TOS`) |
| --- | --- | --- |
| Mesh | Original TMD model | Same full mesh: 1,376 vertices and 2,724 triangles |
| Animation | Authored morph-target choreography | Extracted PS1 morph data rebuilt on the DSP: 46 full gait poses plus sparse targets 5–8; the port adds a post-source hold after frame 273 |
| Transform and culling | Original console geometry pipeline | DSP56001 handles transform, perspective projection, near-plane, degenerate-area, back-face and screen culling |
| Occlusion | Reference-scene behavior | Falcon addition: an armed DSP screen-space prepass builds a conservative triangle kill bitmap during the authored choreography |
| Lighting | Original PS1 lighting | Textured Gouraud shading with three coloured lights and reddish ambient light; documented as not yet an exact PS1 lighting reproduction |
| Textures | PS1 TIM pages and CLUT metadata | Extracted PS1 texture pages and CLUTs, sampled by the M68030 software rasterizer |
| Rasterization | PS1 hardware GPU path | M68030 software rasterizer; the DSP supplies projected vertices and span setup, and the host links the Ordering Table |
| Display | Original PS1 display mode | 240×224 render surface inside a 256×224 Falcon Videl mode |

The release therefore matches the PS1 source data most closely in geometry,
animation and texture assets, while transform, occlusion, lighting and
rasterization are the Falcon implementation.

## Credits

The PlayStation forensics -- working out the TMD model, the TANM morph
animation and the TIM texture pages from the source disc -- the whole M68030
front end and most of the DSP56001 program were written by AI: ChatGPT 5.6,
Claude Opus 5 and Claude Fable 5.

Sascha Springer's share is the direction, a number of the ideas, and the two
innermost routines of the DSP core, both carried over from the Falcon DSP 3D
engine he wrote in 1994: `transform_vertices` is the MAC pipeline of that
engine's `rotate_translate`, unchanged apart from three added `rnd`
instructions and new symbol names, and the signed perspective divide is the
same 1994 `rep #24` / `div` sequence. They run per vertex and per visible
triangle, so the oldest code in the repository is also the hottest.
Everything beyond that is the AI's work.

Model, animation and textures are extracted from Sony's PlayStation *Demo
One* (SCES-00048). The 256x224 Videl register sets are Screenspain's
(Chris/AURA and Scandion/Mugwumps), carried over from the F030Arcade snowbros
port -- see the video-mode comment in `TREX/m68030/trex_m68030.s`. This is a
non-commercial hobby port; the original PS1 assets belong to their owners.
