# F030TREX

An Atari Falcon030 port (16 MHz, DSP56001) of the T-Rex renderer from PS1
Demo One (SCES-00048): a DSP56001 geometry/triangle-setup core paired with
an M68030 software rasterizer, targeting a 240x224 render surface inside a
256x224 Videl mode.

## Download

Prebuilt release archives are on the
[releases page](https://github.com/AnimaInCorpore/F030TREX/releases):
`TREX.ZIP` contains `TREX.TOS`, `TREX.LOD` and the 40-column `README.TXT`,
ready to unpack and run on a stock Falcon030 or under Hatari.  The current
release is
[v1.2](https://github.com/AnimaInCorpore/F030TREX/releases/tag/v1.2) --
the full-mesh package rebuilt from the post-v1.1 DSP and M68030 sources,
with the corrected release benchmark and validation fixes included.

## Building

Requirements: `node`, a C compiler/`make` for vasm and vlink
(built from the bundled tarballs), and optionally DOSBox to rebuild the DSP
program.

`TREX/dsp/trex_dsp.lod` is checked in prebuilt; `make trex_release` needs no
DOSBox for it. Rebuilding the DSP program after a change to `trex_dsp.asm`
does:

```sh
make DOSBOX=/Applications/dosbox.app/Contents/MacOS/DOSBox trex_dsp
```

The full-mesh release package is built with:

```sh
make trex_release
```

This produces `TREX/m68030/TREX.TOS`: the full 2,724-triangle model with
textured Gouraud lighting and no per-frame diagnostic file writes. The DSP
occlusion path remains compiled in but defaults to disarmed because its current
conservative yield measures as a net loss at the corrected DSP clock. Its
matching `TREX.LOD` is copied beside it for deployment, and
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

Use TOS 4.02, 4 MB of ST-RAM and DSP emulation enabled.

**For timing work, use the corrected Hatari, not a stock one.** Stock Hatari
(including the 2.6.1 Homebrew release) grants the Falcon DSP four clocks per
emulated 68030 clock instead of two, so the DSP56001 runs at 32 MIPS against
the real 16. The build vendored in the sibling `F030Arcade` checkout at
`third_party/hatari` fixes that and recalibrates the CPU-to-DSP host port
against DSPBench's real-Falcon figures. On this program the difference is 84.5
ms per frame — 449.7 ms / 2.22 FPS becomes 534.2 ms / 1.87 FPS, all of it in
the DSP readback and packet-build stage, with byte-identical output.
`make measure` runs the documented headless timing recipe against that build
and prints the stage report; OPTIMIZATION.md 2.4g has the measurement, the
mechanism and what it changes. Stock Hatari remains fine for simply watching
the program run. **TOS 4.04 is not
compatible with the current DSP load path**: the program reaches its
video-mode setup, but the DSP remains closed and no triangle packets are
produced. The T-Rex stays absent, although the release-only FPS field can
still update on the black framebuffer. That is a TOS/DSP startup issue, not a
rasterizer failure.

To run the current SSI feed test on a real Falcon, build
`make trex_ssi_loopback` and copy `TREXSSI.TOS` and `TREXSSI.LOD` together to
an otherwise empty directory. This binary executes the validated full-row
stream consumer and feeds the existing rasterizer on the M68030. It is safe
to run on hardware, but it is still a software loopback: it does not enable
the Falcon SSI, Crossbar or record-DMA registers. The run writes the frame-0
diagnostic sidecars (`ssi_rows.res`, `ssi_rows.pkt`, `ssi_rows.status` and
`ssihatri.sta`) so the transport and feed verdict can be copied back for
inspection; later frames use the normal CPU path.

`make trex_m68030_ssi_dma` builds the one target that really does claim the
sound channel and start the Falcon record engine. It routes DSP transmit to
DMA record, has the DSP transmit one framed 16,304-word burst over the SSI,
waits for the declared end address, invalidates the 68030 data cache and
compares the capture against a frame the host built beforehand -- then hands
the channel back and renders normally. It writes `ssi_dma.res` (the
stage-by-stage verdict plus every raw register image it saw) and
`ssi_dcap.res` (the capture); `make ssi_dma_verify` re-derives the payload
and CRC independently. Under the corrected Hatari the transfer arrives
byte-exact. **Its 245 KB/s is the emulator's structural rate, not the
Falcon's specified 1 MB/s**, and the cache contract is untested on real
silicon -- see OPTIMIZATION.md 7.4b before quoting either.

### Hatari capture

![Texture-mapped T-Rex head in three-quarter view, running under Hatari](docs/screenshots/trex-hatari-three-quarter.png)

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
uses the 2,724-triangle model and textured Gouraud shading; the optional DSP
occlusion implementation is retained but default-disarmed;
`TREX.LOD` is the matching DSP program. The deprecated reduced-mesh variant
and its build assets have been removed. Performance figures in
OPTIMIZATION.md are identified as Hatari/emulator results; physical Falcon030
timing remains unmeasured. Figures predating OPTIMIZATION.md 2.4g were taken
with the DSP at twice its real clock and are superseded by the re-measurement
there. Over the 265-frame prefix the current full-mesh **diagnostic** build
measures **459.6 ms / 2.18 FPS**, and `TREX.TOS` measures **457.1 ms /
2.19 FPS** with its release-only overlay and default-disarmed prepass.
The frame-local normal-light cache removes 7.6 ms from the diagnostic
DSP/packet path (section 2.4i), section 8.2b's direct-to-packet record unpack
removes another 24.9 ms of the packet stage at byte-identical output, 2.4j's
object-space lighting a further 2.1 ms at whole-choreography pixel identity,
and 2.4k's frame-ahead lighting -- every survivor lit inside the FINISH window
over a two-word packed normal table, BUILD reading one word per survivor --
38.6 ms more at byte-identical output over all 483 hashed frames; each section
carries its fixed-prefix gates.  Section 2.4l then put a per-phase timer on
what is left of the DSP's exposed work: of 130.4 ms of compute over the whole
mesh, **span setup is 70.1 ms**, the backface classify 22.3, the chunk loop
and index unpack 13.3, the record pack 11.2, the bounding box 6.3, the sort
key 5.1 and the prelight fetch 2.1 -- 128.1 ms once the ladder's own guards
(~2 ms, measured by its control arm) are taken out.  `make_triangle_span` is
the largest measured item left inside BUILD.

The v1.2 release has a measured figure: **511.2 ms per frame, 1.956 FPS**
under a Hatari corrected to run the DSP at the Falcon's real clock
(OPTIMIZATION.md 2.4e). Older figures in that file were taken on a stock
emulator that ran the DSP at twice its rate and are ~24% optimistic on the
whole frame; sections 2.4b--2.4j are the corrected ones. Still not a Falcon
measurement.

The DSP program is the post-harvest build of OPTIMIZATION.md section 2.3h --
nine sites reworked for size and speed at byte-identical output, with the
armed occlusion prepass measured 25.6% cheaper in Hatari -- plus 2.4i's
128-entry normal-light cache, which lets repeated corner normals bypass their
3x3 rotation and six direct-light dot products while retaining the
per-triangle depth cue, and object-space lighting: the six light vectors
rotate through the frame-matrix transpose once per frame and the Lambert loops
dot the raw corner normal, measured pixel-identical over a 321-frame
whole-choreography hash sweep, and 2.4k's prelight pass: the corner-normal
table is packed two words per normal, the 3,610 words that frees hold one
lighting word per triangle, and the FINISH window -- otherwise idle DSP time
while the 68030 rasterizes -- lights every survivor of the frame ahead of
BUILD, which reads the table instead of computing.

The default build ends at `P:$09A6`, 25 words below the resident-index
ceiling; the camera-lights A/B reference (`make trex_dsp_camlights`) ends at
`P:$0993`. Seven switches in the generated `dspconf.inc` select what is
assembled, because it does not all fit: the `CMD_SSI_STREAM` transport probe
of section 7.4b (`SSIPROBE`, 103 words), the prelight pass (`PRELIGHT`, 66),
the cross-frame window burn loop (`WINPROBE`, 44), section 2.3j's prepass
diagnostic counters (`PREPASSDIAG`, 30), the host-port calibration burst
(`PIOBURST`, 25), section 2.4l's per-phase BUILD timing ladder
(`PHASEPROBE`, 21) and object-space lighting (`OBJLIGHTS`, 19). The shipping
and measurement builds take object-space lighting and the prelight pass; the
window probe and the counters each re-assemble only beside `OBJLIGHTS=0`
(`WINPROBE=1 OBJLIGHTS=0` ends exactly at `P:$09BF`); the SSI transport
bring-up build trades everything but the probe and ends at `P:$09B8` with 7
words to spare. `PHASEPROBE` is the only one that fits beside the shipping
configuration unchanged (`P:$09BB`, 4 words free), which is what lets its
ladder time the BUILD body the release actually runs -- `make measure_phase`
and `make measure_phase_control`, decoded by
`tools/decode_phase_stats.py`.

## Feature comparison with the PS1 reference

The port preserves the source model and animation data, but its execution
pipeline is deliberately Falcon-specific. This table describes the current
release rather than claiming pixel-for-pixel equivalence with the PS1 demo.

| Feature | PS1 reference | Falcon port (`TREX.TOS`) |
| --- | --- | --- |
| Mesh | Original TMD model | Same full mesh: 1,376 vertices and 2,724 triangles |
| Animation | Authored morph-target choreography | Extracted PS1 morph data rebuilt on the DSP: 46 full gait poses plus sparse targets 5–8; the port adds a post-source hold after frame 273 |
| Transform and culling | Original console geometry pipeline | DSP56001 handles transform, perspective projection, near-plane, degenerate-area, back-face and screen culling |
| Occlusion | Reference-scene behavior | Falcon addition: an optional DSP screen-space prepass builds a conservative triangle kill bitmap; retained for yield work, default-disarmed in the release after corrected-clock measurement |
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
