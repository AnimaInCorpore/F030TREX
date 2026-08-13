# Falcon030 T-Rex 3D Pipeline Optimization

This document records the current state of the PS1-style T-Rex renderer and
the optimization options discussed for the Atari Falcon030 M68030/DSP56001
implementation.

It covers:

- the current software rasterizer and its measured cost,
- the work already assigned to the DSP,
- the flat-shading path and why it is free in the pixel loop,
- operations that are good or poor DSP candidates,
- the Falcon SSI/crossbar/DMA data paths,
- a proposed streaming architecture, and
- the recommended implementation order.

## 1. Current architecture

The current target is a Falcon030 renderer for the extracted T-Rex mesh. The
Falcon has a 16 MHz M68030 and a 32 MHz Motorola DSP56001. The DSP has 32K
24-bit words of local zero-wait-state RAM, equivalent to 96 KiB.

The current implementation is a PS1-inspired software pipeline:

```text
T-Rex O3D/TMD/TIM data + extracted TANM v2 choreography
        |
        v
M68030 model/texture setup, choreography lookup, XYZ16 stream expansion,
       preshaded CLUT banks
        |
        v
DSP56001: build exact morph pose, transform, project, cull, light,
          and build packed span-setup records in chunks
        |
        v
M68030: packet construction and Ordering Table setup
        |
        v
M68030: software span rasterizer, PS1-style painter's order
        |   (far-to-near OT walk, DDA scanline spans -- no Z-buffer,
        |    no per-pixel coverage test)
        v
16-bit Falcon framebuffer -> Videl display
```

The Falcon Videl is only the display controller here. It is not being used as
a programmable triangle rasterizer or depth-buffer GPU. The `gpu_*` routines
in the current source are host-side shadow interfaces; the actual rasterizer
runs on the M68030.

The render target is 240x224 inside a 256x224 Falcon true-colour mode that the
front end programs into the Videl registers directly, on both monitor types
(section 6.6). Those 256 pixels are wide ones -- four Videl cycles each -- and
cover the same physical screen width the 320 square pixels of the previous
320x240 XBIOS mode did, so the change is a horizontal resampling of the same
picture rather than a smaller viewport. Vertically nothing was resampled: the
224 rendered lines are the 224 displayed lines, which is 24 lines more than
the 320x200 RGB/TV mode could show.

The projection therefore uses `focal_y = 933` -- the PS1's projection distance
of 1000 scaled to 224 of its 240 lines -- and `focal_x = 746`, the same 933
pre-squeezed by the 0.8 the render window shrank by. That is not an aspect
correction but the inverse of the display's own horizontal stretch, and it
leaves the on-screen geometry identical to the 300x224 version's. It does mean
the axis ratio can only be judged on screen: in buffer coordinates the model
is now 1.25x taller than wide, and a framebuffer dump has to be stretched to
300x224 before it is compared with anything. The PS1's own framebuffer figures
still cannot be carried across: it renders 640x240, where a pixel is half as
wide as tall, and that squeeze is undone by the display rather than by the
projection. Section 2 has the measured proportions for each choice.

The current implementation uses the Falcon DSP host port through XBIOS
`Dsp_BlkUnpacked`, except for the animation transactions, which poll the port
per word for the reason in section 2.1. The DSP program is in
[`TREX/dsp/trex_dsp.asm`](TREX/dsp/trex_dsp.asm), and the M68030 front end is
in [`TREX/m68030/trex_m68030.s`](TREX/m68030/trex_m68030.s).

## 2. Current measured baseline

The deprecated reduced-mesh LOD, its generator and its generated assets were
removed in the full-mesh-only revision. The maintained frontend now always
embeds the original 2,724-triangle O3D and its full sidecars; there is no mesh
selection define or build target. References to LOD measurements later in this
file are retained only as labelled historical results and must not be read as
current build or release options.

No new performance result is claimed for removing that selection code. The
last reproducible full-mesh diagnostic measurement is the first 265 frames of
the extracted 274-frame automatic sequence, run in Hatari with the corrected
TMD byte order, negative-area front-face rule, the 240x224 render target and
its `focal_x=746`/`focal_y=933` projection, the source light model, span-start
sub-pixel prestep, shade floor and jaw vocalisation envelope. It is the former
`trex_m68030_fullm` configuration; after this revision, `make trex_m68030`
builds the same full-mesh diagnostic configuration. The release adds its
prepass/FPS options, so this table is not a release timing claim.

These are emulator timings, not a cycle-accurate benchmark and not a
measurement on physical Falcon030 hardware. **Section 2.4a is the bound on how
far they may be read**: the core that produced them charges bus traffic and IO
wait states but no instruction execution time at all, which makes the
bus-dominated stages the trustworthy ones and the arithmetic-heavy rasterizer
the least trustworthy. No figure in this document has ever been taken on a
Falcon.

| Stage | Time per frame | Share of frame |
|---|---:|---:|
| DSP triangle setup/readback and packet build | 185.7 ms | 40.4% |
| Raster row/span walk | 113.4 ms | 24.7% |
| Raster per-packet setup | 68.3 ms | 14.8% |
| Raster pixel loops | 62.2 ms | 13.5% |
| Set-frame send, clear, OT and rounding | 30.4 ms | 6.6% |
| **Total** | **460.0 ms / 2.17 FPS** | **100.0%** |

The frame-100 framebuffer checkpoint was byte-identical to the recorded
full-mesh hash `d89958b3…3d16`. This is an emulator result, not a physical
Falcon030 timing. The former LOD shipping result, 319.8 ms / 3.13 FPS, is
historical and no longer describes a buildable configuration.

The full 2,724-triangle mesh moved from **763.8 to 488.8 ms** in section 3.9's
instruction-cache series (1.31 to 2.05 FPS) at byte-identical output. Section
8.2a then recorded the 460.0 ms diagnostic baseline above after 3.9b/3.9c.

The following 475.2/517.3 ms discussion is retained as the historical
reduced-mesh measurement timeline, not as a current baseline. Section 3.8's
full-mesh one-byte A/B remains the authority on the opaque path's measured
-27.8 ms effect; the retired LOD gate is no longer a supported comparison.

Two changes separate this table from the 528.5 ms one it replaces, and only
the second is in this document's usual sense an optimization:

**The camera moved back** (`PS1_VIEWPOINT_Z` 2000 to 9000, plus the
post-frame-273 turntable). That is choreography, not performance work, and it
was never re-tabulated: re-measured over the same 0-263 prefix, the build
before the render-target change runs **498.2 ms / 2.01 FPS** at 41,533 pixels
per frame. That is the reference the row below is measured against, not the
528.5 ms table.

**The 240x224 render target** (section 6.6) then removed 20% of the pixels
without changing what the display shows, since the 256-pixel Videl mode is
exactly that much wider per pixel:

| Stage | HEAD, 300x224 | 240x224 | Delta |
|---|---:|---:|---:|
| DSP set_frame | 12.8 ms | 12.8 ms | 0.0 ms |
| DSP readback + packet build | 114.0 ms | 112.7 ms | -1.3 ms |
| Framebuffer clear | 18.0 ms | 14.6 ms | -3.4 ms |
| Ordering Table insertion | 1.7 ms | 1.4 ms | -0.3 ms |
| Software span rasterizer | 351.3 ms | 333.2 ms | **-18.1 ms** |
| **Total** | **498.2 ms** | **475.2 ms** | **-23.0 ms (-4.6%)** |

Written pixels fall from 41,533 to 33,173 per frame — 79.9%, the width ratio
to within rounding — and the clear follows the target at 81.1%. Both of those
are unambiguous. The rasterizer's -18.1 ms is not: it is only -5.2% for a -20%
pixel count, and it sits inside the layout band measured immediately below. If
anything it says the per-pixel term is not what dominates the rasterizer at
this coverage. Frame 263 links 644 packets against 670 — the horizontal
squeeze collapses a few more edge-on slivers to zero screen area, where the
DSP's area test drops them. This is the one change in this document that is
not output-preserving by construction — the image is resampled, not
reproduced — so its gate is the geometric one in section 1, not `fb.res` byte
identity.

**Eight bytes of text moved the rasterizer by 28.1 ms.** Removing the dead
`Logbase` call from `gpu_open` — an XBIOS call whose result nothing read any
more — re-measured the same source at **503.7 ms**, with `fb.res`
byte-identical, the same 33,173 pixels and the same 644 packets: DSP set_frame
13.0, readback 112.5, clear 14.6, OT 1.8, rasterizer **361.3 ms**. That is a
5.9% frame regression from deleting eight bytes. The call is therefore kept,
with a comment saying why, and the table above is the shipped binary (`cmp`
against the measured `.TOS`).

This one is not explained by the mechanism roadmap item 16 closed. The raster
state cells, the packet buffer and the OT nodes are all anchored with an
absolute `cnop 0,256`, so an eight-byte text change cannot move their cache
phase; the render target is pinned to 4 KiB; and forcing `rasterize_packet`
to four different offsets inside a 256-byte boundary measured flat to the
tick. Something outside all three still carries 28 ms, so item 16's "the
rasterizer's entire layout sensitivity lives in the raster state cells" holds
for data phase and not for this. The practical rule until it is bounded: in
this program there is no such thing as a layout-neutral cleanup — measure the
ones that only remove code too.

The rest of this section is the history behind the 528.5 ms table, measured at
the 300x224 render target and the z=2000 camera of its time: the stage figures
and the per-frame pixel counts in it are that epoch's, not the table's above.

Against the flat
428.1 ms epoch the cost decomposes by measurement: the interpolation itself
is **+8.1 ms** (one-byte gouraud_enabled A/B in one binary; +5.0 ms on the
gate prefix), the corner-lighting protocol -- three rotations and light
sums per survivor, chunk UV shipping, four level divisions, the 18-word
record -- adds ~32 ms to the readback stage, and ~60 ms is layout phase
the record growth exposed: pinning the preshaded CLUT banks recovered the
gate prefix completely and 17 ms of the full prefix (roadmap item 16 --
its suspect is CONFIRMED), the texture pages' phase is the measured-open
remainder.  The flat path stays selectable (gouraud_enabled=0: 520.4 ms /
1.92 FPS, same binary).  The previous epochs remain below for
comparability; the full-mesh figures predate Gouraud. The detailed
reduced-mesh experiment has been removed from the repository and is no longer
a supported configuration. The contemporary full 2,724-triangle build
measured **601.6 ms / 1.66 FPS** over the identical prefix with stages
21.9 / 114.4 / 17.8 / 2.2 / 445.0 ms. The present
stage reads 0.0 ms because there is nothing left to time: the renderer draws
into the screen buffer that is not on display and the frame ends by writing
three Videl base registers (section 6.5). The rasterizer
consumes the DSP's validated span-setup record (sections 4.1b-4.1d), the
record travels packed at fourteen words, and the chunk protocol pipelines DSP
chunk N+1 against host unpack of chunk N. `span_validate_enabled` defaults off
and remains the on-demand field-for-field regression gate.

Two epoch breaks separate this table from the previous 784.9 ms baseline:

**The jaw animation changed the geometry.** Feeding the source vocalisation
envelope to morph target 4 moves real vertices, so coverage and survivor mix
shifted: 77,301 written pixels per frame against 77,853 before, and the
pre-series binary re-measured 742.7 ms instead of 784.9 over the identical
prefix.  The difference is choreography and layout, not an optimization, and
**742.7 ms is the reference** the rasterizer series below is measured against.
The `fb.res` checkpoint also moved from frame 0 to the frame-100 close-up by
its data value -- an order of magnitude more covered pixels makes it the
stronger byte-identity gate; `cmp -l` confirmed the one-byte binary change.

**The rasterizer micro-optimization series** (section 3.6) then removed
140.5 ms of rasterizer time at exactly equal output:

| Stage | Before series | After | Delta |
|---|---:|---:|---:|
| DSP set_frame | 21.7 ms | 21.9 ms | +0.2 ms |
| DSP readback + packet build | 114.9 ms | 114.4 ms | -0.5 ms |
| Clear + OT + present | 20.3 ms | 20.0 ms | -0.3 ms |
| Software span rasterizer | 585.5 ms | 445.0 ms | **-140.5 ms** |
| **Total** | **742.7 ms** | **601.6 ms** | **-141.1 ms** |

That is 1.35 to 1.66 FPS, +23%, with the 20,407,685-pixel write count equal
to the last pixel and the frame-100 dump byte-identical across every step of
the series.  The stages the series never touched moved by at most 0.5 ms,
the stage-stability section 2.1 predicts for them.

Two corrections of this revision are a measurement epoch break of their own, and
both change the image far more than they change the timings:

| | Before | Isotropic projection + working OT |
|---|---:|---:|
| Software span rasterizer | 596.9 ms | 643.2 ms |
| **Total** | **777.4 ms** | **826.0 ms** |
| Written pixels per frame | 56,358 | 77,853 |
| FPS | 1.29 | 1.21 |

The +48.6 ms are bought, not lost. `focal_x` and `focal_y` are now equal
(section 1): the Falcon's square pixels made the previous 625/933 an anamorphic
squeeze that rendered the model 1.49x too tall, and removing it widens the
animal by 49%, hence 38% more written pixels. The rasterizer grew only 7.8%
against those 38%, which puts most of its cost in per-span and per-triangle
work rather than per-pixel. The Ordering Table fix (section 6.2) costs
essentially nothing — 2.5 to 2.8 ms of insertion — but restores depth sorting
for frames 0..125, which had none at all.

The source light model of the following revision changed nearly every pixel of
the image and cost nothing measurable: 826.0 ms before, 821.8 ms after over the
same prefix, at identical pixel and packet counts. Three lights with per-light
clamping replace one white light, and the brightness level the DSP sends now
carries a two-bit colour class alongside it, which selects among 64 preshaded
CLUT banks per page instead of 16. The pixel loop never learns about any of it.
Section 4.4 has the derivation and the one deliberate deviation from the source
data.

The texture-accuracy fixes of an earlier revision are a separate epoch break.
Both builds were re-measured over the identical 0-263 prefix for this table;
the previous one reproduced its recorded 711.7 ms exactly, which is what makes
the comparison usable:

| Stage | Before | With prestep + shade floor | Delta |
|---|---:|---:|---:|
| DSP animation/transform/project | 20.5 ms | 21.0 ms | +0.5 ms |
| DSP triangle/readback/packet build | 108.5 ms | 108.9 ms | +0.4 ms |
| Clear + OT + present | 50.8 ms | 50.2 ms | -0.6 ms |
| Software span rasterizer | 531.5 ms | 596.9 ms | **+65.4 ms** |
| **Total** | **711.7 ms** | **777.4 ms** | **+65.7 ms (+9.2%)** |

That is 1.41 down to 1.29 FPS. The whole cost is the span-start sub-pixel
prestep: the row loop advances U/V from the un-snapped chain position to
`ceil(xl)` with two 64-bit multiplies, on every row of every packet. The other
two fixes are free -- the shade floor runs once per CLUT entry while the
preshaded banks are built, and the per-word host-port handshake (section 2.1)
replaces an XBIOS trap with inline polling, which is if anything slightly
cheaper.

A gradient-gated prestep -- skip the correction when both U/V gradients stay
below one texel per pixel -- was built and measured over the same prefix:
775.4 ms, only 2.0 ms cheaper, and it loses 52 of the corrected pixels again.
Even in the close-ups most packets still exceed a texel per pixel, so the gate
almost never fires. The unconditional version is what is in the tree.

What the fixes buy is texture accuracy, not pixel count: over the whole prefix
they add just 124 written pixels. The effect concentrates where the model is
small and heavily minified. At frame 0, 70 pixels that were stored as pure
black -- shade level 0 crushing a dark texel's three channels to zero, on a
black background indistinguishable from a hole in the mesh -- are now filled,
and 1,484 of that frame's ~3,650 pixels sample a different, geometrically
correct texel.

The corrected face rule was the previous revision's epoch break; both columns
of the following table predate the texture fixes above.  Over the identical
0-263 prefix, changing the DSP branch from the erroneous positive-area rule
to the negative-area PS1-view rule changed the measured stages as follows:

| Stage | Wrong back faces | Correct front faces | Delta |
|---|---:|---:|---:|
| DSP animation/transform/project | 20.5 ms | 20.3 ms | -0.2 ms |
| DSP triangle/readback/packet build | 113.9 ms | 108.8 ms | -5.1 ms |
| Clear + OT + present | 50.4 ms | 50.5 ms | +0.1 ms |
| Software span rasterizer | 637.8 ms | 531.7 ms | **-106.1 ms** |
| **Total** | **822.9 ms** | **711.7 ms** | **-111.2 ms (-13.5%)** |

That is 1.22 to 1.41 FPS, about 15.6% more frames per second.  Average written
pixels are effectively unchanged (56,320 versus 56,358), and frame 263
actually has more survivors (997 versus 1,065).  The rasterizer improvement is
therefore not a simple triangle/pixel-count saving: the selected faces have a
different span and transparent-texel work mix, neither of which the current
counter measures separately.  The delta is far above the roughly 20 ms layout
noise floor, but should not be attributed more narrowly without a visited-
pixel/span counter.

The earlier aspect check predates this culling correction: the literal
`focal_x=469`, `focal_y=933` run measured frames 0-260 at 784.0 ms/1.28 FPS and
44,767 writes, while the then-current X=625/back-face run measured 822.9 ms /
1.22 FPS and 56,320 writes.  It still bounds the visible-width cost at about
5%, but neither timing is the current renderer baseline.

One earlier apparent multi-second collapse is explicitly invalid and must not
be used as a baseline: the M68030 initially read the PS1 TMD base vertices as
big-endian words. They are little-endian, so the DSP received nonsensical
coordinates and the rasterizer covered enormous invalid triangles. Byte-
swapping each TMD component before sign extension restored the mesh and the
timings above.

Other measured values:

- 1,078 DSP packets and Ordering Table nodes in frame 263; all 2,724 triangles
  enter the culling path and survivor count varies with choreography,
- 77,853 framebuffer pixel writes per frame on average, painter's overdraw
  included,
- DSP state: open, face normals uploaded,
- video mode: active — the 256x224 true-colour Videl mode of section 6.6,
- DSP free memory reported by the run: 16,040 X words and 16,127 Y words.

The pixel-write counter counts texels actually stored after span coverage and
texture-transparency tests. It is not the number of span pixels visited;
transparent samples still consume rasterizer work without incrementing it.

### 2.1 How to compare two configurations

Several properties of this benchmark make naive before/after comparisons wrong
by far more than most changes are worth. All of them were found the hard way.

**Compare equal frame counts.** `make run_trex_headless` is bounded by VBLs,
not by rendered frames, so a slower build completes fewer records. The exact
sequence is 274 nonuniform shots: distant opening frames are cheap and the
face close-ups are expensive. Compare the same prefix or one complete
274-frame cycle. `render_stats.res` is rewritten after every completed frame,
so its frame count is the authority.

**A working build can be one unrelated edit away from deadlocking.** TOS 4.02's
`Dsp_BlkUnpacked` tests TXDE once and then `DBF`s straight back onto the write
instruction (`$e05176`-`$e05182` in ROM), so it blasts a whole block at CPU
speed. The DSP56001 host port is a single register: a word written while TXDE
is clear overwrites the one the DSP has not fetched yet, and that word is gone.
Any command whose DSP-side loop does real work between two reads can lose one.
The animation target loop, with its Q12 multiply-accumulate per component,
does: the host-port trace shows target 7 sending 36 deltas, the DSP receiving
35, and the value at index 25 replaced by the one at index 26. The DSP then
waits for a word that never arrives while the host waits for the reply.
Whether the race is lost at all is cycle-exact, so it moves with layout -- the
build before this revision survived it, the same build with 16, 48, 78 or 128
bytes of unused padding added to the text section deadlocked on animation frame
1, and 2 or 256 bytes were fine again. The animation transactions therefore
poll the port per word (`dsp_block_handshake`) instead of calling
`Dsp_BlkUnpacked`. The bulk mesh/index/UV uploads and the chunk protocol still
use the XBIOS call: their DSP-side loops only store or emit words and win the
race by a wide margin.

**Do not change binary layout to disable a feature.** Commenting out a call is
not a neutral edit: dropping the four bytes of one `BSR` shifts everything after
it, and that moved the rasterizer by 78 ms per frame — an order of magnitude
more than the feature under test. Use a data flag instead, such as
`lighting_enabled`, and verify with `cmp -l` that the two binaries differ only
in that longword.

**The sensitivity is data placement, not the instruction cache.** This was
originally attributed to the 68030's 256-byte instruction cache. That is at
most a small part of it. Forcing `rasterize_packet` to offsets 0, 64, 128 and
192 within a 256-byte boundary, with everything else identical, measures
1340.5, 1340.3, 1340.5 and 1340.5 ms — flat to the tick. What actually moves
the number is where `framebuffer` and `depth_buffer` land: adding a buffer
above them and shifting them by 21,800 bytes cost 78 ms per frame at unchanged
pixel and packet counts.

Both are therefore now pinned with `cnop 0,4096` immediately before
`screen_buffer_raw`, so the render targets keep a fixed page offset no matter
what changes size above them. That recovered 61 ms of the 78. A residual of
about 17 ms per frame survives the pinning and is not yet explained; treat any
rasterizer delta below roughly 20 ms per frame as noise unless the pixel loop
itself changed.

One candidate for that residual is measured and eliminated: `FRAMEBUFFER_BYTES`
is a multiple of 256, so framebuffer and Z-buffer share their low eight address
bits and could in principle fight over the 68030's sixteen direct-mapped
data-cache lines. A 128-byte de-phasing pad between them changed the rasterizer
by 0.7 ms — nothing. The conflict that matters is not framebuffer-versus-Z;
the CLUT and texture reads, which sweep the whole cache every few pixels, are
the more plausible suspect but are not yet isolated.

**Compare stages, not totals.** The rasterizer is 75% of the frame and carries
all of that layout noise. A change that only touches the host-port path is best
judged on the readback/packet-build stage, which is stable to about 0.2 ms
across layouts.

**The `fb.res` byte gate is per render-target size.** Dumps are
`SCREEN_WIDTH*SCREEN_HEIGHT*2` bytes — 107,520 since the 240x224 target,
134,400 before it — so a checkpoint captured under a different geometry can
only be compared after both are converted and rescaled to a common displayed
width, never byte-for-byte. `tools/fb2png.py` rejects a dump whose length does
not match its own `W`, because the old length passes a `>=` test and converts
to a silently sheared image.

Applying these rules, over 64 frames (two full revolutions) from binaries
differing in exactly one byte. This table predates the render-target pinning,
so its absolute rasterizer figure is 1,293.8 ms rather than the 1,310.5 ms in
section 2; the delta it reports is unaffected, because both binaries in it
share one layout:

| Stage | Lighting off | Lighting on | Delta |
|---|---:|---:|---:|
| DSP set-frame | 6.2 ms | 6.6 ms | +0.4 ms |
| DSP readback and packet build | 125.9 ms | 128.6 ms | +2.7 ms |
| Framebuffer and Z-buffer clear | 51.0 ms | 51.2 ms | +0.2 ms |
| Ordering Table insertion | 2.3 ms | 2.3 ms | 0.0 ms |
| Software rasterizer | 1,293.8 ms | 1,293.8 ms | **0.0 ms** |
| Present | 30.2 ms | 30.1 ms | -0.1 ms |
| **Total** | **1,509.8 ms** | **1,512.8 ms** | **+3.0 ms (+0.20%)** |

Both configurations write the same 17,072 pixels and link the same 752 packets.
The rasterizer figure is identical to the tick, which is the whole point of the
preshaded CLUT banks: the pixel loop does not know that lighting exists. The
entire cost of flat shading is **+0.20% of the frame**, spent on the DSP side.

**Viewing runs versus measurement runs.** `make run_trex` starts
`TREX_RUN.TOS`, assembled from the same source with `-DTREX_RUN`: both
capture flags are zero, so the frame loop performs no GEMDOS traffic and only
a keypress exit writes one final `render_stats.res` through `trex_shutdown`.
The conditional keeps the same `dc.l` sizes on both branches, so the binary
is layout-identical to the measured `TREX_M68.TOS` except for those two data
longwords — `cmp -l` reports exactly two differing bytes — and every timing
in this document carries over to the viewing build.  Measurement and
regression runs keep using `TREX_M68.TOS`, whose per-frame stats flush is
what makes interrupted runs comparable in the first place.

### 2.2 Per-frame processor utilization

The current timers measure pipeline stages, not independent CPU and DSP cycle
counters. Any internal split below is therefore a cost model unless explicitly
labelled as a Hatari stage measurement.

For the 475.2 ms / 1,600-triangle build of its epoch the narrowest reproducible
critical-path split was as follows.  Section 3.9 has since taken that build to
319.8 ms, essentially all of it out of the rasterizer row; the DSP and
host-port rows are untouched by it.  The split's structural conclusion is
stronger now rather than weaker, because the M68030-only share fell while the
transport share did not -- the frame is now 34.3% packet stage against 21.5%
before, and the cross-frame window the DSP hides in shrank with the
rasterizer:

| Requested component | Current wall time | Status |
|---|---:|---|
| DSP animation run | **0.0 ms visible** | DSP work is cross-frame-hidden inside the 333.2 ms raster window; the 12.8 ms animation stage is send PIO |
| Host-port data transfer | **about 45.6-45.9 ms** | 12.8 ms measured animation PIO plus 32.8-33.1 ms triangle-wire model |
| DSP triangle run | **not separately observable; at most part of 79.6-79.9 ms** | overlaps chunk N's host unpack/packet build and the first clear |
| M68030 record unpack + packet build | **not separately observable; shares the same 79.6-79.9 ms** | residual of the 112.7 ms mixed triangle stage after its wire model |
| M68030 software rasterizer | **333.2 ms** | measured Hatari stage |
| M68030 clear + OT + timer rounding | **16.5 ms** | 14.6 + 1.4 + 0.5 ms measured |
| **Frame** | **475.2 ms / 2.10 FPS** | Hatari, not physical Falcon030 |

The triangle-wire model follows the shipping protocol, rather than the stale
three-word BUILD shorthand: 1,600 UV pairs plus three header words per 32-face
chunk are 3,350 input words; fifty BUILD acknowledgements are 100; up to fifty
GET commands and their reply headers are 150; and 599.6 average survivors at
18 words each are 10,793. That is 14,243-14,393 words depending on fully culled
chunks, or 32.8-33.1 ms at the historical 2.3 us/word calibration. Adding the
measured 12.8 ms animation PIO gives the transfer line above.

The two 79-ms entries are one shared residual, **not two costs to add**. A DSP
busy-time counter or a CPU-side no-unpack hardware probe is required to divide
them. The pre-pass's separately measured 15.2 ms proves that substantial DSP
geometry work fits inside the cross-frame window; it does not identify how
much of the shipping mixed stage is DSP time. Likewise, the transfer estimate
does not apply to section 7.3a's unmeasured blind receive loop.

Measured M68030-only work is already at least 582.2 ms per frame: rasterizer
531.7 ms, present 30.3 ms, clear 17.5 ms and OT insertion 2.7 ms. The combined
animation/DSP stage is 20.3 ms and triangle setup/readback/packet build is
108.8 ms; both mix M68030 programmed-I/O/unpack work, DSP execution and time
blocked on acknowledgements. Thus at least 81.8% of the current frame cannot
be reduced by moving more geometry arithmetic to the DSP.

The exact choreography averages 4,933 input words per frame. At the historical
Hatari host-port calibration of about 2.3 us/word, input transport alone models
to roughly 11.3 ms before DSP morph/transform work and M68030 XYZ16 expansion.
That explains why the completed morph offload measures 20.3 ms rather than the
old 6 ms transform-only stage without implying that the CPU performs the
morph math.

The DSP is therefore doing materially more useful geometry work than in the
former transform-only path, but it is not busy for the whole frame.  Even the
deliberately generous assumption that it is active throughout both mixed
stages gives only 129.1 / 711.7 = 18.1% wall-time utilization; the real value
is lower because those stages include M68030 programmed I/O, sign extension,
record unpacking, packet construction and acknowledgement waits.  Within the
animation stage the CPU does not evaluate morph products or matrices, but over
the complete frame its role is emphatically not limited to transport.

This utilization split is a snapshot of the 711.7 ms epoch; the page flip
(section 6.5), the rasterizer series (section 3.6) and the mesh LOD
(section 10 item 10) have since landed.  Its structural conclusion is
unchanged at the 362.8 ms LOD baseline: 295.1 ms of clear/OT/rasterizer is
pure M68030 work before the CPU shares inside the two DSP stages are
counted, so at least 81% of the frame still cannot be reduced by moving
more geometry arithmetic to the DSP.  The dominant next levers
remain framebuffer-side: reduce triangles/overdraw with a visual LOD and
continue on the pixel loop.  Cross-frame geometry pipelining can hide part of
the 136.3 ms combined DSP/host-port stages, but it cannot hide the 445.0 ms
rasterizer and the DSP still has no path to write the framebuffer directly
(section 6.1).

### 2.3 Occlusion: how much of the transferred geometry is invisible

Every triangle that survives the DSP's zero-area/back-face/near-plane/off-screen
cull is transferred as an 18-word record and drawn, whether or not anything
nearer covers it. This section is the measurement of how much that costs, and
of how much of it a conservative test could recover. It decides nothing on its
own — it is the input to that decision.

The measurement is a separate instrumented binary, `-DTREX_OCCL`
(`make trex_m68030_occl`). It writes one `OCnnnn.RES` per frame holding a
48-byte record per survivor in draw order plus a 240x224 **owner bitmap**: the
rank of the last triangle to store each pixel. Because there is no Z-buffer and
the OT walk is strict painter's order, that single bitmap answers everything:

- a survivor is **fully occluded** exactly when no pixel carries its rank, and
- at the moment rank `r` is tested in a near-to-far pass, the set of pixels
  already covered is exactly `{ p : R(p) > r }`.

The second identity is what makes the conservative test a rectangle-minimum
query on the finished rank map instead of an incremental mask simulation, so
every mask policy, box and resolution can be replayed offline from one run.
`tools/occl_dump.py` validates, `tools/occl_replay.py` runs the gates and
caches, `tools/occl_analyze.py` produces the matrix, `tools/occl_selftest.py`
is the synthetic-scene regression (60 expectations, no emulator).

Measured over the identical 0-263 prefix, 240x224, 1,600-triangle LOD. Hatari,
not physical Falcon030:

| | absolute | share |
|---|---:|---:|
| Survivors transferred | 158,307 | 599.6 per frame |
| Z — drew no pixel at all | 17,406 | 11.00% of survivors |
| **E — drew pixels, none survived** | **38,929** | **24.59% of survivors** |
| E by a strictly nearer OT bucket | 35,371 | 22.34% |
| Framebuffer writes spent on E | 1,947,520 | **22.24% of all writes** |
| Overdraw factor | 1.90 | 1.28 to 2.22 per frame |
| Texels dropped by the bit-17 test | 14,456 | 0.16% |

**E is the ceiling for any whole-triangle occlusion culling: 24.59%.** It is
not uniform — 14.0% in the opening long shots, 24.1% median, 38.6% at frame
194 — so the aggregate alone would mislead. Z is reported separately and never
counted into E: those triangles are prey for a sharper clip, not for an
occlusion test.

The conservative test, as a matrix of mask policy x test box x mask
resolution. `C_in_E` is what it recovers of the ceiling; no variant ever culls
a visible triangle (gate G6, `Falsch` = 0 in all 30 cells):

| Mask | Box | Res | Words | culled | of E | of writes |
|---|---|---|---:|---:|---:|---:|
| M_ideal | B_vbox | 1x1 | 2,240 | 28,414 | 60.9% | 16.8% |
| M_ideal | B_span | 1x1 | 2,240 | 35,919 | 89.2% | 18.3% |
| **M_uv** | **B_vbox** | **2x2** | **560** | **20,422** | **44.2%** | **11.3%** |
| M_uv | B_vbox | 1x1 | 2,240 | 24,524 | 51.7% | 11.8% |
| M_uv | B_span | 2x2 | 560 | 26,653 | 66.5% | 12.6% |
| M_static | B_vbox | 2x2 | 560 | 1,721 | 3.1% | 0.2% |
| M_flat | B_vbox | 2x2 | 560 | 1 | 0.0% | 0.0% |

**The occluder-qualification granularity is worth a factor of twelve, and it
was nearly the whole answer.** A triangle may only seal coverage if it writes
opaquely, and the first policy tried was per texture page: page 10 carries
5.82% transparent texels, so all 475 triangles on it are disqualified — 30% of
the mesh, scattered everywhere, which perforates the mask and collapses the
whole scheme to 3.1% of the ceiling. Asked per triangle instead — does *this*
triangle's UV footprint touch a transparent texel — 1,555 of 1,600 qualify
instead of 1,125, and only 45 triangles on page 10 are genuinely affected.
That is `M_uv`, it is exactly as statically precomputable as the page rule (one
bit per triangle beside the resident index list), and it is the policy any DSP
implementation should use. The measured drop rate confirms the direction: the
rasterizer discards 0.16% of its texels, so transparency is a real constraint
on *which* triangles may seal and a negligible one on how much gets sealed.

Secondary results:

- **Resolution matters less than expected.** Halving to a 2x2 cell minimum —
  the rule "set the bit only when the whole cell is covered" — costs 7.1
  percentage points of recall (51.7% to 44.2%) for a quarter of the memory.
  560 words fit the current DSP map; 2,240 do not.
- **The span box beats the vertex box by half again** (66.5% against 44.2% at
  2x2). The clipped span box is tighter than the clipped vertex bbox, but the
  DSP only knows it after the span setup the culling is meant to avoid.
  Whether a cheap span-box estimate is reachable before setup is open.
- **24,880 survivors (15.7%) leave one to three visible pixels.** An
  approximate test would collect far more than a conservative one — and would
  change the image, which no other optimization in this document does.
- **Cross-frame coherence is 85.7%**: a triangle occluded in frame n-1 is
  occluded again in frame n, and blindly trusting the previous frame would lose
  0.41% of visible pixels.

### 2.3a The price of the order the DSP can actually produce

The matrix above tests in draw order, which lets a triangle be sealed by a
neighbour in its *own* OT bucket. A DSP cannot do that: within one bucket the
host draws LIFO from submission and the DSP has no way to know that order. A
sound DSP rule may only seal against **strictly nearer buckets**. The analyzer
therefore carries an order axis — `O_rank` (draw order, the optimistic bound)
and `O_bucket` (seal only at bucket boundaries, what a DSP pre-pass can
establish) — and the whole matrix is evaluated under both.

Measured over the same prefix, on the same cache, with no new emulator run:

| | culled | of E | of writes |
|---|---:|---:|---:|
| `M_uv`/`B_vbox`/2x2/**O_rank** (perfect order) | 20,422 | 44.19% | 11.31% |
| `M_uv`/`B_vbox`/2x2/**O_bucket** (DSP-achievable) | 19,614 | 42.66% | 11.24% |

**The ordering restriction costs almost nothing: 1.52 points of E, 3.4%
relative, and 0.07 points of the write share.** With `OT_KEY_SHIFT = 8` there
are enough buckets that same-bucket sealing was never carrying the result. The
ceiling moves the same way — E 24.59% to E_tief 22.34% — so this is a property
of the mesh's depth distribution, not of the test.

That closes the largest open question hanging over section 2.3. What it does
not close is the *cost* of producing that order, which is section 2.3b.

### 2.3b Historical ordering-only pre-pass measurement

The table in this subsection is the predecessor's ordering-only measurement,
not a result from the current full-mesh occlusion binary. Its
`CMD_PREPASS` (`-DTREX_PREPASS`) pass walked the 1,600-triangle LOD after the projection,
re-uses `make_triangle_area`/`make_triangle_bbox`/`make_triangle_zkey`
unchanged, derives the host's OT bucket from the same key, and LSD-radix sorts
the survivors into a near-to-far list — two passes of 6 and 5 bits over the
full 11-bit bucket, so the ordering is exact and nothing is coarsened.

Five arms of **one binary**, switched by a one-byte patch of `prepass_arm` and
verified with `cmp -l`, plus one control. Hatari, ~270-frame prefix:

| Arm | | ms/frame | t_setframe | t_packets | t_raster | t_prepass |
|---|---|---:|---:|---:|---:|---:|
| R0 | off | 485.9 | 12.75 | 118.69 | 337.49 | 0.00 |
| R0z | null command, same bracket | 485.7 | 12.69 | 118.87 | 337.31 | 0.02 |
| R1 | inline, in the hidden window | 485.7 | 12.94 | 118.65 | 337.52 | 0.00 |
| R2 | freestanding, on the critical path | 501.7 | 13.00 | 133.97 | 338.11 | 15.24 |
| RV2 | R2 + per-frame order verification | 504.6 | 12.76 | 135.28 | 337.98 | 15.26 |
| RG | unchanged `trex_m68030.tos`, new `.lod` | 476.7 | 12.68 | 113.03 | 334.58 | — |

**(a) The pre-pass costs 15.2 ms per frame.** `t_prepass(R2) - t_prepass(R0z)`
= 15.22 ms, and the independent cross-check `t_packets(R2) - t_packets(R0)` =
15.28 ms agrees to 0.06 ms. The cost model predicted 20.4 ms, so the model was
25% pessimistic. Of that measured figure the radix sort is the small part — the
model puts it at 1.55 of 20.4 ms — and the geometry pass dominates. That
geometry is work `CMD_BUILD_TRIANGLES` already does per chunk; a real
integration would fold the two rather than run both, which is why 15.2 ms is an
upper bound on what ordering would cost in production, not the production cost.

**(b) It disappears completely into the cross-frame window.**
`t_packets(R1) - t_packets(R0)` = **-0.04 ms**, frame total -0.2 ms, against a
decision threshold of 0.5 ms. The DSP is blocked for roughly 337 ms of
rasterization per frame and needs 15 of them, a factor of 22. Arm 1 arms the
DSP once at startup and the pre-pass then runs inside `FINISH_ANIMATED_FRAME`,
so it costs nothing on the critical path at all.

Gates, from `prep_sta.res`:

- **The pre-pass finds exactly the survivor set `CMD_BUILD_TRIANGLES` finds.**
  R2 reports `surv_last` 673 against `dsp_packet_count` 673, RV2 663 against
  663. It re-uses the same three cull routines by `jsr`, so this is a
  construction guarantee that the run confirms rather than a coincidence.
- **The order is compatible with the host OT in every frame.** RV2 fetched the
  DSP list and cross-checked it against the host's own bucket arithmetic on all
  272 frames: 0 failures.
- **No overflow, and the margin is thin.** Capacity is 744 entries, the
  measured maximum is 699 — 6.4% headroom, `overflow` 0. That matches the
  cache's independently measured maximum exactly. It is not much, and a
  different camera or LOD could eat it.
- **No protocol failure.** `fail_count` 0 in every arm. This matters more than
  it looks: a lost ack makes the timed bracket contain four wire words and
  nothing else, and the campaign would then report that the pre-pass costs
  nothing measurable. The counter is what separates that from arm 1's genuine
  zero.

Two methodological notes. R0 and RG differ by 9.2 ms per frame at identical
arithmetic — same source, same `.lod`, only `-DTREX_PREPASS`'s extra text and
BSS between them. That is section 2.1's layout sensitivity in one line, and it
is exactly why every number above is a difference *within* one binary. And the
arms completed 270 to 273 frames rather than an identical count, worth up to
±0.4 ms of per-frame average — negligible against a 15.2 ms effect, but it is
the reason conclusion (b) is stated against a 0.5 ms threshold and not a
tighter one.

**That predecessor left 12 words of DSP program memory.** It consumed 255 of the
267 free P words; the last occupied address was `P:$09B3` against
`triangle_indices` at `P:$09C0`. The mask stamping that stage 2 would need had
no room at all — the pre-pass answered the ordering question and in doing so
exposed program memory, not data memory and not time, as the binding
constraint. Section 2.3c is what happened when that constraint was examined.

### 2.3c Historical layout recovery: 166 P words were an assembler artefact

This is also a predecessor-build record. The obvious response to 12 free words was to fold the pre-pass's per-triangle
classification into `CMD_BUILD_TRIANGLES` instead of duplicating it. That was
designed, built and measured: **it recovers 12 words.** Twelve. BUILD gives up
17 and takes back a `jsr` plus an `n2` setup, the pre-pass gives up 17 and takes
back a `jsr`, and the shared leaf routine costs 18. It would have doubled a
budget that was nowhere near enough either way, at a cost of two extra
`jsr`/`rts` pairs across ~3,200 calls per frame.

The actual cause was somewhere else entirely. ASM56000 sizes a jump in pass 1,
so **every forward jump was assembled in its two-word long form** while every
backward jump got the one-word short form: the listing held 168 long forward
jumps and zero long backward ones. Forcing short addressing with the `<` prefix
on jump targets — 206 lines, purely a change of operand notation — recovers
**166 words**:

| Variant | last P | free to `$09BF` | gain |
|---|---|---:|---:|
| before | `$09B3` | 12 | — |
| forced short addressing | `$090D` | **178** | +166 |
| the fold alone | `$09A7` | 24 | +12 |
| both | `$0900` | 191 | +179 |

There is exactly one exception, and the assembler names it: `ERROR 911:
Instruction cannot appear at last address` on the fourth `jsr send_next_x_word`
closing a `DO` loop in `command_get_vertices`. A one-word JSR would sit on the
loop-end address itself, which the architecture forbids; as a two-word
instruction only its extension word lands there. That line stays long, and it
costs one word.

Two things make this safe rather than clever. The instruction stream is
provably untouched — normalising both listings to mnemonics and operands gives
1,593 instructions before and 1,593 after, diff zero, same instructions in the
same order with narrower jump encodings. And it was verified empirically: a
baseline run against the new `.lod` reproduced `fb.res` of frame 100
**byte-identically** and measured 475.3 ms per frame against the recorded
475.2. The 12-bit short form reaches `$0FFF` while the program may never grow
past `$09BF` anyway because of the Y/P overlay, so the encoding can never
become too narrow — the constraint is self-enforcing.

The fold stays designed and unbuilt in the tree's history: 13 further words are
not worth 0.8 to 1.6 ms per frame (estimate) and a new register protocol while
178 are free. It takes about twenty minutes to add if stage 2 ever needs it.

**The lesson generalises past this program.** The pre-pass was blamed for a
scarcity it only exposed; 62% of what looked like its footprint was jump
encoding that had been there all along. Before restructuring DSP code to save
program memory, check what the assembler is spending it on.

### 2.3d Historical parallel-move reserve

2.3c asked what the assembler spends words on and found jump encoding. Asked a
second time, of the instruction stream rather than the encoding, it finds
something larger. Counted from the assembled listing of the current program:

| | count |
|---|---:|
| instructions | 1,582 |
| words | 2,241 |
| extension words | 659 |
| standalone two-word absolute `x:`/`y:` moves | **489** |
| ALU ops that accept a parallel move | **230** |
| ...of those, ones that actually carry one | **9** |
| standalone `nop` | 41 |

**The DSP56001's defining feature is unused.** Every one of those 489 absolute
moves is a standalone `move`; the architecture lets one data ALU operation carry
a memory move in the same instruction, and 221 of the 230 eligible ALU ops carry
nothing. Each successful pairing removes exactly one word -- the ALU op's own --
because the move's extension word survives when the address is absolute, and the
whole pair collapses to one word when it is register-indirect. The upper bound is
therefore about **221 words**, against the 35 item 19 is short. Even a one-in-five
success rate against data hazards clears it.

Two things bound where to start, so the next attempt does not begin where this
one would have. `Tcc` takes only a second *register* transfer, never a memory
move, so the compare-and-clamp code (`cmp` 27, `tgt` 7, `tlt` 6) resists pairing
outright -- `make_triangle_bbox`, which looks like the densest target because it
is almost all two-word absolute reads, is in fact one of the worst. The 13
Tcc sites are a small minority though, and the yield is in the `mac`/`mpy`/`add`
class, i.e. the transform, projection and shading loops, where pairing removes a
word *and* a cycle from code that runs per vertex and per corner. And short
immediates are already exploited correctly: they are one word only for address
registers, where the value is zero-extended, while a data ALU register left-
aligns an 8-bit immediate into the high byte, which is why every integer constant
in this file legitimately carries `#>`.

**Consequence for item 19: program memory is no longer the blocker in
principle.** It is an unexploited reserve in code that predates the occlusion
work entirely, and the pass that harvests it is mechanical, site-by-site, and
gated by the same byte-identical `fb.res` every other change here is. What it is
not is free of risk: a parallel move reads its source register at the start of
the instruction, so any pairing that reuses a register the ALU op also writes has
to be reasoned about individually, which is why the bound above is an upper bound
and not a plan.

Projected saving, **estimate and not a measurement** — the baseline's Hatari
stage times scaled by the measured shares, with the cost of the test itself
(mask rasterizer, zkey bucket sort, extra wire words) in none of it:
rasterizer -37.7 ms and readback/packet-build -14.5 ms per frame at `M_uv` /
`B_vbox` / 2x2, against a DSP-side cost estimated at roughly 15 ms that would
largely land in the cross-frame window that runs empty today.

### 2.3e Full-mesh implementation and first validation round (superseded by 2.3f)

**Historical note: every validation in this subsection was later shown to
have exercised a non-functional culling stage -- see 2.3f for the four
defects, the rewrite, and the re-validation.  The X overlay, `PREPASS_MAX`,
the P extent and the hold-disarm behaviour described below are all
obsolete.**

The source at that time implemented the previously described design against
the stock full geometry, rather than moving the resident arrays or switching
to the LOD. The DSP resident index words are three words per triangle, so the
prepass reloads `triangle_indices + 3*index`; the full 2,724-bit kill bitmap is
114 X words. The X overlay is exactly:

| Range | Words | Owner |
|---|---:|---|
| `X:$39DF-$3CB1` | 723 | phase-local sorted survivor order |
| `X:$3CB2-$3F84` | 723 | radix scratch / first 336 words: seal+pending masks |
| `X:$3F85-$3FF6` | 114 | global triangle kill bitmap |
| `X:$3FF7-$3FFE` | 8 | BUILD cursor/status |

The mask is 60 columns by 56 rows of 4x4-pixel cells, three 24-bit words per
row and 168 words per mask. Query cells use the clipped victim bbox against
sealed coverage. A qualified opaque triangle stamps pending coverage only if
all four cell corners pass the front-facing point-in-triangle test; pending
coverage is merged only when the sorted OT bucket changes. BUILD reads the
bitmap in ascending global triangle order and skips killed triangles. If the
723-entry order capacity overflows, the bitmap remains clear and the frame is
unculled.

The reproducible build checks performed for this implementation are:

| Check | Result |
|---|---|
| DSP DOSBox assembly | 0 errors, 0 warnings |
| Full-mesh P extent | last instruction `P:$09BA`; `$09BB-$09BF` remain free |
| Full-mesh X extent | `prepass_status` ends at `X:$3FFE` |
| Resident Y extent | indices begin at `Y:$09C0`; normals end at `Y:$3FFE` |
| Host full-mesh build | `make trex_m68030` passes |
| Host prepass build | `make trex_m68030_prepass` passes |

The first runtime pass exposed and fixed a correctness bug in the kill writer:
the sorted entry is `(triangle_index << 12) | bucket`, but the writer was
adding the bucket back to the already-unpacked triangle index. That shifted
kills onto unrelated source triangles. The writer now addresses the bitmap
with the global triangle index alone.

Hatari validation of the corrected full-mesh binary used TOS 4.02, Falcon DSP
emulation, 4 MB ST-RAM, the exact runtime `trex_dsp.lod` mounted beside the
program, and a 4,000-VBL bounded run. The arm-1 inline-prepass and arm-0
disarmed control produced the same frame-100 `fb.res`:

| Check | Result |
|---|---|
| Arm-1 framebuffer SHA-256 | `d89958b314c924ad6654f5e92cd29b859ab99b0c4f197170dfe8cfc0216f3d16` |
| Arm-0 framebuffer SHA-256 | identical |
| `cmp fb.res` | PASS, zero differences |
| Full geometry | 2,724 triangles; no LOD substitution |

An edge-transition regression then exposed two state-machine errors in the
coverage sweep: the sorted-list and mask clear were inside the per-entry DSP
loop, and an uncovered mask cell did not advance the cell cursor while the
query result was returned as covered unconditionally. The fix moves the
per-run setup outside that loop, advances every 4x4 cell, and returns the
accumulated query result.

A second reproduction showed that the synthetic post-source hold (the
frontend continues moving after the extracted choreography ends at frame 273)
can make the per-triangle pending-coverage stamp sweep exceed the stock DSP
frame budget at the right edge. The full-mesh prepass therefore stayed
armed through the authored sequence and sent one disarm command when
`gait_hold_index` started. The hold still rendered the complete
2,724-triangle mesh; it simply used the already-correct unculled BUILD path
rather than allowing culling work to stall the animation. This was a
correctness guard for the frontend-added hold, not a physical-Falcon timing
result -- and the overrun it guarded against was the old full-grid cell
walk's; the guard is retired in 2.3f.

The guard was checked with the custom Hatari Falcon harness, TOS 4.02, 4 MB
ST-RAM, DSP emulation and the exact runtime `.lod`. Starting at frame 270, the
armed and disarmed controls produced identical frame-273 `fb.res`
(`de4397e3436df8ed7818baeeaac92e753d17cd0f87f619db449fd05816280a8e`), and
the guarded arm crossed frame 291 with the clean disarmed-control hash
`e66d4d433360c9e63938bc78efdf774716c31dbaf22679b6ac0ffd1f42b00486`.
The rebuilt production binary also completed an 8,000-VBL run with zero
prepass protocol failures or overflow reports. These are emulator correctness
results; physical-Falcon timing remains unmeasured.

The diagnostic build carries owner instrumentation and is not a timing
binary. No physical-Falcon run has been completed, so DSP-window occupancy,
stock-hardware timing and FPS remain unmeasured. The framebuffer identity is a
Hatari correctness result, not a physical-machine performance claim.

### 2.3f The prepass never actually culled -- four latent defects, the rewrite that fixed them, and the retired hold disarm

Everything above in 2.3e describes a stage that, as later established with
DSP-level breakpoints in Hatari, never killed a single triangle in any
validated run. The byte-identical framebuffers were all trivially identical:
the compared images were produced by the same unculled path on both arms.
Four independent defects each sufficed to keep the stage dead, and the
budget overrun that motivated the synthetic-hold disarm was a symptom of the
same code. All four are fixed in the current source; the sweep, the sort and
the BUILD consumption were rewritten in the process, and the rewrite is both
smaller and asymptotically cheaper than what it replaced.

The defects, in the order they were found:

1. **The stamp predicate was unsatisfiable.** `prepass_point_inside` stored
   `A1` of each fractional MPY/MAC edge product, but a small product's value
   lands in `A0` and its `A1` is only the sign extension -- the very trap the
   `span_cross` comment documents. The stored "edge values" were 0 or -1, and
   the reconstructed third-edge test degenerated to "the point lies ON edge
   01 or edge 12", which four cell corners can never satisfy simultaneously.
   No cell was ever stamped, so seal coverage stayed empty and the query
   could never prove a triangle covered.
2. **The walk cursors died at bit 23.** The one-hot mask advance in the old
   cell walk (and, independently, in BUILD's streaming kill-bitmap cursor)
   tested the shifted mask with a full-accumulator `TST` after `MOVE X1,A`.
   A bit-23 one-hot sign-extends into A2, so the "mask became zero, advance
   the word" branch never fired: the walk cursor zeroed itself and stopped
   testing or stamping past the twelfth cell of each row, and BUILD stopped
   consuming kill bits after the 24th triangle of every armed frame.  The
   fix reads the carried-out bit from A2 bit 0 (`JCLR #0,A2`) in all
   walkers, at the same word count.
3. **The classification overflowed its capacity every frame, invisibly.**
   The full mesh has ~1,100-1,200 area+box survivors per frame (measured
   1,145-1,194 over the choreography), but the radix sort's ping-pong
   scratch capped `PREPASS_MAX` at 723.  Worse, the overrun marker was
   unreliable: the capacity check compared the survivor counter that the
   overrun path had just set to `$ffffff`, the next survivor incremented it
   to zero, and the count then kept climbing -- so the host's
   `PREPASS_OVERFLOW_MARK` check saw a plausible small number instead of the
   sentinel.  The prepass aborted before the sort on every frame and
   reported healthy-looking survivor counts while doing so.
4. **The sweep's triangle reload read the wrong memory.** The once-folded
   `add x0,a a1,r2` in `prepass_load_triangle` stored the PRE-add A1 into
   R2 -- a parallel move reads its source at the start of the instruction,
   exactly the constraint 2.3d documents -- so the reload walked the on-chip
   scalars at `Y:3*index` instead of the resident list.  Unobservable while
   defects 1-3 kept the stage inert; fatal the moment they were fixed.

The current implementation replaces the sweep and the sort:

- **Two-pass counting sort into 64 depth classes** (32 OT buckets each,
  `PREPASS_COARSE_BITS`): classification runs once to count survivors per
  class and once more to scatter them to prefix-summed cursors.  No second
  list exists, which raises `PREPASS_MAX` to 1,335 -- the X window from
  `chunk_uvs` to the top of physical X memory now holds the order list
  (1,335), both coverage masks (2x56), the kill bitmap (114) and the status
  cells (8) exactly.  Coarse classes only merge neighbouring buckets, so
  sealing across class boundaries under-approximates the host's
  strictly-nearer draw order and kills remain sound.  Overflow is now
  detected once, after the counting pass, where no wrap can hide it.
- **Range-restricted coverage walks.** Both the seal query and the pending
  stamp visit only the 8x8-pixel cells the survivor's clamped screen box
  overlaps ([min>>3, max>>3] per axis -- the box is cell-exact), instead of
  every cell of the screen grid per survivor.  The query additionally exits
  at the first unsealed cell, which is the common case.  This removes the
  cost class that made the old sweep exceed the frame budget on the
  synthetic hold's right-edge poses.
- **Incremental three-edge stamp.** Full-cell coverage is decided by three
  edge accumulators anchored at each edge's maximising cell corner
  (+cell-1 per axis where the gradient is positive), so the four-corner
  test collapses to one sign test per edge and stepping to the next cell or
  row is one add per edge.  The anchors come from the same fractional
  MPY/MAC the area routine uses, read from `A0` after one ASR; everything
  downstream is exact 24-bit integer adds.  The doubled gradients live in
  short Y cells, deliberately not N registers, whose 16-bit zero-extended
  read-back would silently turn negative gradients positive.
- **Dirty-flag merge.** Pending coverage is merged into seal at a class
  boundary only when the closing class stamped anything; classes without a
  qualified visible occluder skip the whole external-memory merge pass.
- **Shared index unpack.** The classification loop and the sweep's reload
  share one `prepass_unpack_indices` subroutine; the reload's base add and
  R2 store are split into two instructions (defect 4).

Sizes: the full-mesh program now ends at `P:$0988` -- 50 words smaller than
the `P:$09BA` recorded in 2.3e -- with `$0989-$09BF` free before the
resident indices.  The order-entry format keeps its shape
(`(triangle_index << 12) | class`, class in the low bits), so the host
protocol is untouched except for the retired hold disarm.

**The hold disarm is retired.** `trex_m68030.s` no longer sends
`PREPASS_MODE_DISARM` when `gait_hold_index` starts, and
`prepass_hold_disarmed` is gone: the prepass stays armed for the entire run.
The guard existed to keep the old full-grid sweep from overrunning the frame
budget on the hold's right-edge poses; the range-restricted sweep is bounded
by each survivor's own screen box and removed that overrun class.

Validation, all with the Hatari 2.6.1 Falcon harness, TOS 4.02, 4 MB
ST-RAM, DSP emulation, and the exact runtime `trex_dsp.lod` beside the
binary -- emulator correctness results, not physical-Falcon measurements:

| Check | Result |
|---|---|
| DSP DOSBox assembly | 0 errors, 0 warnings |
| Full-mesh P extent | last instruction `P:$0988`; `$0989-$09BF` free |
| Full-mesh X extent | `prepass_status` ends at `X:$3FFF` exactly |
| Host prepass build | `make trex_m68030_prepass` passes |
| Survivors (arm 2, freestanding) | 1,145 last / 1,194 max over 65 frames; 0 overflow, 0 protocol failures |
| Frame-100 `fb.res`, arm 1 vs arm 0 | byte-identical, SHA-256 `d89958b314c924ad...3d16` (the recorded full-mesh hash) |
| Hold frame-291 `fb.res`, arm 1 vs arm 0 | byte-identical, SHA-256 `e66d4d433360c9e6...b00486` (the recorded clean-control hash) |
| Armed hold run | 351 frames over 11,500 VBLs, 0 failures, 0 overruns, no stall |
| Culling activity | armed wrote 61,697 fewer raster pixels than disarmed by frame ~351, 19 fewer by frame 109, at identical images |

The pixel deltas confirm the kill bitmap is live end-to-end (sweep, bitmap,
BUILD skip, host packet stream) and that its kills are invisible, as the
sealing rule requires.  The yield with 8x8 cells and 64 depth classes is
deliberately conservative -- tens of triangles per frame in the second half
of the choreography, near zero in the close-up frames whose depth spread
collapses into one or two classes.  Raising the yield (finer classes via a
segmented sort, 4x4 cells if X memory is found for the larger masks) is
future work.  The arm-2 freestanding prepass costs 75.6 ms/frame in Hatari
-- the two classification passes dominate -- which the production arm-1
inline mode hides inside the FINISH window as before; these are emulator
figures under the 2.4a caveats.

One methodological note for future diagnostic work: instrumented DSP builds
are bound by the same `P:$09BF` ceiling as the shipping program.  A
temporary counter that pushes the extent past it lands in the words the
resident index upload rewrites, executes index data as code, and reports
zeros -- which produced one full round of self-contradictory measurements
during this investigation before the extent check was applied to the
diagnostic builds too.

### 2.3g Full-mesh release package — implemented

For visual playback without per-frame host-disk traffic, build the release
target `trex_release`. It emits `TREX.TOS`, retaining `TREX_PREPASS` and the
rewritten armed culling path from 2.3f while defining `TREX_RUN`:
framebuffer/stat diagnostics and the final diagnostic flush are
disabled. The matching `TREX.LOD` is still read once at startup, so the
mounted GEMDOS volume remains necessary.

This is the single supported full-mesh package: textured Gouraud shading,
armed DSP occlusion through both the authored choreography and the frontend's
post-frame-273 gait/turn hold, and no per-frame diagnostic file writes. Build
it with `make trex_release`; the matching `TREX.LOD` copy is placed beside the
TOS so the release directory is self-contained. The DSP protocol, resident
memory layout and `.LOD` contents are the validated production path described
above; no separate presentation-mode variants are part of the release.

### 2.4 The occlusion binary is not a timing source

`trex_occl.tos` moves text and adds ~371 KB of BSS, and it stores an owner id
per written pixel. By section 2.1 every stage time it reports is meaningless;
its `render_stats.res` exists only to poll progress mid-run. No number in
section 2.3 is a time taken from it.

What makes its geometry trustworthy instead is a gate chain, all of which held
over the full prefix:

| Gate | What it proves | Result |
|---|---|---|
| G0 | Campaign `trex_m68030.tos` byte-identical to its pre-change build | 1,123,274 bytes, `cmp` clean in that epoch |
| G1 | DSP program and `.lod` untouched | sha256 equal |
| G2 | Occl run's frame-100 `fb.res` identical to the baseline run's | byte-identical |
| G3 | Per-record write counts sum to `raster_pixel_count`, every frame | PASS, 8,757,777 = 33,173/frame |
| G4 | Every non-black framebuffer pixel has a non-zero owner | PASS, 0 stray |
| G5 | Every span box contained in its DSP vertex bbox | PASS |
| G6 | Every conservatively culled set is a subset of E ∪ Z | PASS, 0 false in 30 variants |

G3's total is the strongest single check: 33,173 written pixels per frame is
the baseline figure of section 2 reproduced to the pixel from a completely
different code path. The baseline run itself re-measured 475.9 ms against the
recorded 475.2 ms over the same prefix.

Two properties of the harness are deliberate. `occl_replay.py` refuses to cache
a frame whose gate failed and records `gates_ok` in the index; `occl_analyze.py`
refuses to report anything on such a cache. Without that lock a broken run
still produced a complete, plausible table ending in `VERDICT: CLEAN`. And the
measurement target reassembles unconditionally: `make` cannot see that
`-DTREX_OCC_FIRST/-DTREX_OCC_LAST` changed, so a pilot binary would otherwise
satisfy a full campaign and silently dump only the pilot's frames.

### 2.4a What the measuring emulator actually charges for

Every millisecond in this document comes from Hatari 2.6.1-devel, and the
question of what its timing model contains had never been asked. It was, at the
source. The findings below are verified in `tools/hatari`; they do not make the
figures wrong, but they bound what may be concluded from them.

**The core used charges no instruction execution time.** `--mmu true` selects
`m68k_run_mmu030` and opcode table 35. `cpuemu_35.c` contains zero calls to
`x_do_cycles`; the emitting block in `gencpu.c:607-621` sits under `#if 0` and
only a generator-internal counter is incremented. The 44 costed calls in the
whole table are `do_cycles(20)` ×22, `(34)` ×11, `(48)` ×11 — MULU.W, MULS.W,
DIVU.W, DIVS.W, in raw units against 256 units per CPU cycle. **`MULS.L` and
`MULU.L` cost exactly zero**: `op_4c00_35_ff` holds a dead `count_cycles = 0`
and nothing else. The rasterizer's row loop uses two of them per row in the
sub-pixel prestep. Emulated time is therefore bus traffic plus IO wait states;
arithmetic, register work and address computation are free.

Consequences, in order of how much they matter here:

- **Bus-dominated stages are the trustworthy ones.** The framebuffer clear is a
  flat `move.l` loop and its 14.57 ms is about as good as this model gets. The
  rasterizer's 333.2 ms, an arithmetic-heavy inner loop, is the least
  trustworthy — and it is 70% of the frame.
- **The layout sensitivity is amplified by construction.** With execution at
  zero cost, cache and bus-phase effects are 100% of the signal instead of
  diluted. The 28.1 ms from eight bytes of dead text (section 2) and the 13.5 ms
  from the delta-clear code merely being present (2.5) are real measurements of
  this model; how much survives on hardware is unknown.
- **Videl steals no cycles.** No video component calls `M68000_WaitState` — the
  only callers are acia, dsp, fdc, mfp, psg and rs232. There is a constant
  0/1/2-cycle bus raster in `src/cpu/custom.c:329-336` that applies to every
  access, but no display-driven contention. A 256x224 true-colour mode reads
  114,688 bytes per display refresh on real hardware and that cost is absent
  here.
- **The DSP ratio is as intended, contrary to first impression.**
  `DSP_CPU_FREQ_RATIO` **is** defined — `src/falcon/dsp.h:29`, value 2, with a
  comment naming the Falcon's 32/16 MHz. The active `DSP_Run(2 * cpu_cycles ...)`
  and the commented-out `DSP_Run(DSP_CPU_FREQ_RATIO * ...)` produce the same
  rate; the `FIXME` beside them is about catch-up granularity (per-instruction
  burst versus global clock counter), not about the rate. What remains open is
  the unit of `dsp_cpu.c`'s `instr_cycle`, and that `dsp_cpu.c:66` states
  outright that cycle counting was simplified and the external DSP RAM's BCR
  wait states ignored — this program lives in that external RAM.
- **The per-frame GEMDOS writes are free here and would not be on hardware.**
  `OpCode_GemDos` costs a flat 4 cycles (`src/cpu/hatari-glue.c:291`) and the
  file work happens host-side outside emulated time, yet the writes sit inside
  the timing bracket. `trex_run.tos` already solves this: `-DTREX_RUN` zeroes
  `stats_flush_enabled` and `framebuffer_dump_enabled`, and the binary is
  layout-identical to the normal target.  In the current opaque-path revision
  both are 1,123,302 bytes and differ only in the two documented data bytes.
- **Everything is in ST-RAM.** `-tos-fastload` sets PRGFLAGS bit 0 only
  (`tools/vlink/tosopts.c:25-30`), no TTRAMLOAD/TTRAMMEM, and there is no
  `Malloc` call in the renderer. Hatari models ST-RAM as `CE_MEMBANK_CHIP16`
  without burst bits while TT-RAM is `FAST32` with them, and the cache-line
  burst paths test for `FAST32` — so a line miss fetches 4 bytes, not 16. If a
  real Falcon's controller bursts, hardware would be *faster* than the model on
  code-heavy loops. Whether it does is not established here.

One free experiment follows directly: re-run the same binary **without**
`--mmu`, which selects table 23, where the same `DIVU.W` costs 34 *full* cycles
instead of 34 raw units. The difference brackets the word MUL/DIV share of the
frame and shows how much of the layout sensitivity is a property of the core
rather than of the program. It needs no hardware and no code change.

### 2.5 Delta clearing: built, measured, rejected

Roadmap item 20 said the clear wipes 240x224 while only 32.5% of it is ever
touched, so clearing the dirty region should be worth about 9.8 ms. It was
built (`-DTREX_DELTACLEAR`, `make trex_m68030_delta`) and measured. **It costs
6.1 ms per frame instead of saving.**

Dirty state is tracked per 8-row band — 28 bands, two pages so each screen
buffer carries its own, since the buffer being cleared was last drawn two
frames ago. The bookkeeping runs once per packet, never per span row: at 9,043
span rows against 600 packets per frame a per-row min/max would cost about what
the whole clear saves. The x hull comes from `{xl0, x1r, raster_xl, raster_xr}`
at `.raster_packet_done`, which needs no multiply — the two DDA chains end on
the third vertex, so those four values enclose all three corners.

Four runs, the same binary throughout, `delta_clear_enabled` switched by a
one-byte patch (`cmp -l`: exactly one byte). Hatari, ~275-frame prefix:

| Run | | ms/frame | t_clear | t_raster |
|---|---|---:|---:|---:|
| base | before the change | 475.9 | 14.55 | 333.72 |
| lodchk | before the change, new `.lod` | 475.3 | 14.60 | 335.54 |
| DC0 | code present, switch **off** | 489.2 | 14.57 | 349.08 |
| DC1 | switch **on** | 495.4 | **6.58** | **363.47** |

**The clear itself does exactly what the model promised: 14.57 to 6.58 ms.**
The image gate holds — `fb.res` of frame 100 is byte-identical in both arms, so
the band table covers every written pixel and there are no ghosts. Written
pixels and packet counts are unchanged.

Everything else is loss. The bookkeeping costs **+14.40 ms in the rasterizer**,
1.8x what the clear saves, for a net **+6.14 ms**. And the code's mere presence
costs **+13.5 ms** with the switch off (t_raster 335.54 to 349.08) — section
2.1's layout sensitivity, larger than the entire benefit.

The cause was predicted before the run and confirmed by it: instruction fetch.
`delta_mark_packet` is 136 bytes of code called 600 times per frame, and
`span_walk_half` sweeps far more than the 68030's 256-byte instruction cache
between two calls, so its text is re-fetched from ST-RAM every time. (This
paragraph continued "`CACR` is never programmed anywhere in this source, so
the cache may not even be on." That has since been measured and is wrong:
`CACR` reads `$3111` while the program runs, TOS 4.02 turns both caches on at
boot, and section 3.9 is what followed from taking the cache seriously. The
instruction-fetch diagnosis in this paragraph was right either way.) At
the bus floor this program actually exhibits — 8.05 cycles per longword — 34
longwords of instruction fetch plus 9 data reads plus the `bsr`/`rts` stack
traffic comes to 362 cycles per packet, 13.6 ms per frame. The measurement said
14.40.

**The clear stage is at the memory floor of the model that measured it.**
26,880 longwords in 14.57 ms at 16 MHz is 8.7 cycles each, and a longword to
16-bit ST-RAM needs two bus transfers. Read that as an emulator property
first: Hatari charges `x_do_cycles_post(3*cpucycleunit)` per 16-bit ST-RAM
access plus a 0-2 cycle bus raster (`src/cpu/custom.c:329-361`), so ~7.5
cycles per longword falls out of the model by construction. A real 68030
needs two cycles per bus cycle, three with one wait state, so the emulator
sits at or above the hardware figure rather than below it — but "8 cycles is
the hardware minimum" is not something this campaign measured. What follows
regardless: the stage is bus-dominated, `movem.l` moves the same transfers
and cannot help, and only area is a lever. The delta clear's own rate is
consistent: 10,397 longwords in 6.58 ms is 10.1 cycles each, slightly worse
than the flat loop because of the per-band setup.

The code stays in the tree behind its flag and `delta_clear_enabled` defaults
to 0; the shipping binary is byte-identical to the build that preceded the
experiment. (Since 2026-08-09 the mechanism lives unconditionally in the main
path -- see the re-measurement at the end of this section; the flag and its
zero default remain, the conditional assembly does not.) What is worth
keeping is the measurement, not the mechanism.

Two lessons for the next attempt at this stage. A cost model that counts only
data traffic will understate any routine called per primitive on this machine —
instruction fetch dominated here by three to one. And a saving of 8 ms in a
stage is not 8 ms in the frame unless the bookkeeping that finds it is free.

**What this rejects is bookkeeping on the M68030, not the delta clear.** Cho
Ren Sha 68k, the prior art this idea came from, splits the work the other way:
its DSP owns the coverage buffer and emits the run list, and the 68030 receives
a finished description and does nothing but clear. This implementation put
`delta_mark_packet` on the 68030 — 600 calls per frame — which is exactly where
the 14.4 ms went. Three things that were not available when this was built now
are: the DSP has 178 free P words (section 2.3c), its cross-frame window is
measured empty (2.3b), and after the pre-pass it already holds every survivor's
geometry. Per-band marking there is on the order of 1,800 updates in a window
that runs idle, and the table is ~224 words on the wire. That variant is
untested and its DSP cost unmeasured, but it is the one the evidence points at,
and the -8.0 ms it would collect is the most model-robust number in this
section: the clear is pure bus traffic, which is the one thing the measuring
core does charge for (section 2.4a).

**Re-measured 2026-08-09, after section 3.9.** The mechanism was moved into
the main path (the `TREX_DELTACLEAR` conditionals are gone; the switch is the
same data longword, with `-DTREX_DELTA_ON` as the layout-identical on-arm, one
byte by `cmp -l`) and re-run over the identical 0-263 prefix, frame-100
`fb.res` byte-identical in every arm:

| 0-263 LOD | off | on | | Full mesh, 0-101 | off | on |
|---|---:|---:|---|---|---:|---:|
| t_clear | 14.6 | **6.3** | | t_clear | 14.9 | **3.1** |
| t_raster | 178.6 | 193.3 | | t_raster | 237.0 | 261.8 |
| frame | 317.4 | 323.6 | | frame | 461.6 | 475.0 |

Net **+6.2 ms** on the LOD, **+13.4 ms** on the full mesh: the 2.5 verdict
stands, and for the predicted reason -- the walker still sweeps far more than
256 bytes between two `delta_mark_packet` calls, so 3.9's loop work changed
nothing about the per-packet fetch term.  What 3.9 did change is the cost of
the code's mere presence: 2.5 ms (t_raster 176.5 to 178.6) against 13.5 ms in
the pre-3.9 layout, now that every hot loop is phase-pinned (the 250-byte
record-unpack body gained an explicit `cnop 0,16` in the process, making its
cache fit unconditional).  `delta_clear_enabled` ships as 0.  Two untested
routes could invert the sign: the DSP variant above, still the strongest
candidate, and a host-side batch -- spill `raster_xl/xr` per packet (two
stores in place of the `bsr`) and compute every hull in one tight per-frame
loop that stays cache-resident, amortising the fetch that costs 14.7 ms
today.

### 2.6 Frame-rate overlay — implemented, release only

`-DTREX_FPS` draws a five-cell `NN.NN` frames-per-second field into the top-left
corner of the render window, in white (`$ffdf`), from `gpu_draw_fps`. It is on
the `TREX.TOS` rule alone. Every other target — `trex_prepass*`, the `fb.res`
capture path, the span validator — must stay without it, because the overlay
writes into the framebuffer and would contaminate any dump or byte-identity
comparison. With the flag off the assembled binary is byte-identical to the
build that predates the feature (verified: both link to SHA-1 `3810c7e5`), so
the gate is not merely conventional.

Format and placement:

- **`NN.NN`, zero padded, never blanked.** Both digit pairs and the point hold
  fixed columns, so the field cannot shift sideways as the rate crosses 10.
- **Two fraction digits are what make it useful.** At the rate this renderer
  runs — 2.02–2.43 fps observed below — an integer field would sit on `02` and
  show nothing. The value is `20000/ticks` from the 200 Hz `_hz_200` tick, so
  the quotient carries its own hundredths and no second division is needed.
- **Clamped at both ends.** A zero tick delta would divide by zero and a long
  stall would overflow `DIVU.W`'s 16-bit divisor; the first pegs the field at
  `99.99`, the second reads `00.00`. Neither can wrap into a plausible number.
- **Independent of DSP availability.** The overlay is a release-side 68030
  write and is deliberately not gated on `dsp_program_loaded`. If `TREX.LOD`
  cannot be loaded, no T-Rex packets exist but the FPS field can still update
  on the black framebuffer; that distinguishes a live frontend from geometry.
- Drawn after `gpu_rasterize_ot` and before the page flip. The release replaces
  its word-sized presenter call with a same-width call to `gpu_draw_fps`, which
  tail-branches through `gpu_present_frame`; no second call is inserted ahead
  of the hot rasterizer text. The no-FPS release comparison explicitly forces
  the same word-sized BSR, while diagnostic targets keep their original short
  direct presenter call and byte layout. The overlay is consequently inside
  the release's present `TimeMark` bracket, but `TREX_RUN` disables
  `render_stats.res` in that build.

Cost and layout: plain CPU stores, no Blitter. The field is drawn 1:1 — 30x7
pixels for the whole readout — so a set source pixel is one `MOVE.W #$ffdf,(a4)`
straight into the framebuffer. Per frame that is a 30x7 wipe (105 longword
stores) plus at most 175 tested source pixels. That is an operation count, not
an end-to-end timing claim: this renderer has repeatedly shown that small text
movements can dominate the direct cost through instruction-cache phase.
Accordingly the whole overlay routine now sits after every existing render and
prepass routine, and the call-site substitution above is the same width with
the flag on or off. Enabling `TREX_FPS` therefore cannot move
`gpu_rasterize_ot`, `rasterize_packet`, `span_walk_half`, or the prepass host
code. On the wide 256-mode pixels a 5x7 glyph displays about 6.25x7
square-equivalent, which is near the readable limit on a 15 kHz monitor;
`FPS_SCALE` carries the ratio through the derived geometry, but doubling it
also needs the companion stores in the inner loop, which is written for 1:1.
The wipe is unconditional because `delta_clear_enabled` is a byte patch
applied to the built file: with the delta clear armed the frame clear only
touches dirtied bands and last frame's digits would survive underneath. The
font (11 cells x 7 bytes) sits at the end of the data section and the 10 bytes
of state at the end of BSS. An otherwise identical release build without
`TREX_FPS` was assembled and linked on 2026-08-12: the FPS build is 9,704 text
plus 1,174,040 data = 1,183,744 bytes, against 9,448 + 1,170,200 = 1,179,648
bytes without it. The actual growth is therefore exactly 4 KiB, not zero as
the first integration note claimed; BSS grows separately by 10 bytes. The
release/no-FPS listings put `gpu_rasterize_ot`, `rasterize_packet`,
`span_walk_half` and `prepass_frame_call` at identical addresses, and all
pinned BSS symbols retain identical section offsets. The text growth is 256
bytes and the total loaded text+data growth is 4 KiB, so the documented
256-byte instruction/data-cache phases and 4-KiB BSS anchors do not move.
This is an assembler/link layout validation, not a measured performance
result; physical-Falcon overlay cost remains unmeasured.

Validation: Hatari, TOS 4.02, Falcon DSP emulation, 4 MB ST-RAM, the runtime
`.lod` beside the executable. The field renders as specified and updates per
frame — `02.43` and `02.02` captured at different points in the choreography,
holding the same columns. These are emulator readings of an emulator's frame
rate; they are not a physical Falcon030 measurement, and the overlay running on
hardware will report whatever that machine actually does.

## 3. Rasterizer cost model

**This model describes the retired bounding-box edge-function rasterizer.**
The shipping rasterizer is the DDA span walker of section 3.4; the tables
below are kept because they explain why the span conversion was worth 807 ms,
and their sub-operation shares are the reference for what the DSP setup
record still has to replace. All percentages predate the DSP culling and
describe a rasterizer that saw all 2,724 triangles.

| Rasterizer area | Estimated share of rasterizer | Equivalent share of full frame |
|---|---:|---:|
| Ordering Table walk and packet dispatch | ~1% | ~0.9% |
| Triangle pre-test and rejection | ~10% | ~8.6% |
| Setup of surviving triangles | ~30% | ~25.7% |
| Scanline and pixel loops | ~59% | ~50.6% |
| **Total** | **100%** | **85.7%** |

### 3.1 Triangle pre-test: approximately 10% of the rasterizer

This path runs for every submitted triangle:

| Sub-operation | Estimated share of rasterizer |
|---|---:|
| Load screen coordinates and form deltas | ~3% |
| Signed area calculation | ~3% |
| Bounding-box construction | ~3% |
| Framebuffer clipping and early return | ~1% |

The active DSP path now provides a survivor-count proxy at packet-build time:
frame 263 of the current run links 1,078 of 2,724 input triangles, so 1,646 were
rejected by the DSP's combined zero-area, near-plane, bounding-box and
backface predicates. The share varies strongly with choreography. These are
triangle-count ratios, not timing ratios.

The bounding-box and clipping rows of this sub-table are retired: since the
survivors-only protocol of section 4.1a the DSP returns the clipped box with
each survivor and `rasterize_packet` loads the complete setup record. The
normal path no longer recomputes area, box or gradients on the host; only the
diagnostic fallback/reference arithmetic does. These model percentages predate
DSP culling entirely and describe a rasterizer that saw all 2,724 triangles.

### 3.2 Setup of surviving triangles: approximately 30%

This path is only reached after the early area and bounding-box tests pass:

| Sub-operation | Estimated share of rasterizer |
|---|---:|
| Primitive type, transparency, shade bank, and texture-page selection | ~4% |
| Fetch the three camera-space Z values | ~3% |
| Edge deltas and edge increments | ~4% |
| Evaluate edge functions and normalize winding | ~6% |
| UV/Z gradient setup and starting values | ~13% |

The last item was expensive because the retired host setup performed nine
longword
divisions per visible triangle:

- three horizontal gradients: `du/dx`, `dv/dx`, `dz/dx`,
- three vertical gradients: `du/dy`, `dv/dy`, `dz/dy`,
- three row-start values: `u`, `v`, `z`.

This was the strongest candidate for DSP offload and is now complete. The DSP
generates the validated span record; the M68030 performs none of these
divisions in the active path. Section 4.1c records the measured switch-over.

### 3.3 Scanline and pixel loops: approximately 59%

| Sub-operation | Estimated share of rasterizer |
|---|---:|
| Row initialization and row stepping | ~5% |
| Edge coverage tests and edge increments | ~20% |
| Software Z-buffer address, read, compare, and write | ~14% |
| Affine UV calculation and indexed TIM/CLUT lookup | ~10% |
| Indexed CLUT lookup and flags | ~10% |
| PS1 RGB555 to Falcon RGB555X conversion (removed from hot path) | ~6% |
| Transparency and semitransparency handling | ~4% |
| Flat shading | 0% - the CLUT bank is chosen once per triangle |

This is the largest numerical block, but it is a poor fit for the current
DSP because the DSP does not directly own the Falcon framebuffer or the
M68030's normal ST-RAM address space in the current design. Sending individual
pixels or spans through the host port would usually cost more than the
computation saved.

### 3.4 The shipping span rasterizer

The shipping path renders PS1-style DDA scanline spans. The DSP's
`make_triangle_span` produces the setup:

1. sort the three vertices by screen Y (the UV packet offsets travel with
   their vertices),
2. one cross product of the sorted triangle — twice the signed area, the
   degenerate guard, and the middle vertex's side in a single value,
3. X along each edge steps in 12.12 fixed point per row; U/V step in Q8.8
   along the LEFT chain only; du/dx and dv/dx come from the same barycentric
   expression the old rasterizer used, now over the sorted vertices, which
   makes it winding-agnostic — backfacing fallback triangles need no
   normalization step,
4. per row, the span is [ceil(xl), ceil(xr)-1]: right/bottom-exclusive like
   the PS1 GPU, so adjacent triangles never double-draw a shared edge,
5. pack the result into the fourteen-word wire record.

The M68030 unpacks that record into the semantic fields once, links it through
the Ordering Table, then `rasterize_packet` only selects one of three span-loop
variants (opaque textured, flat, semitransparent) and walks the two halves. U/V
stay in data registers, the framebuffer pointer walks in an address register,
and there is no per-pixel coverage or depth test.

The long edge spans both trapezoid halves and is never restarted, so its DDA
rounding stays that of a single slope division; the short chain restarts
exactly at the middle vertex. Screen clipping is per-row in X (with a UV
catch-up multiply only when a span actually crosses the left edge) and
row-count based in Y.

Divisions per textured triangle at introduction: 5 with the middle vertex on
the right, 7 on the left, plus the 2 span-gradient divisions.  Measured
effect of the conversion: 1,147.3 to 340.4 ms rasterizer time at
near-identical coverage.  Since the record switch-over (section 4.1c) every
one of those divisions — and the sort and gradients with them — runs on the
DSP instead. The historical 269.6 ms record-driven figure was measured at the
old fixed view; the current choreography prefix measures 531.7 ms because its
close-ups cover many more pixels, not because setup moved back to the CPU.

### 3.5 Measured decomposition of the shipping rasterizer

The table at the top of this section is an estimate for a rasterizer that no
longer exists. The shipping one can be split by measurement instead, without
touching a line of source: three binaries that differ from the shipped one in
one to eight bytes, so the code layout — which section 2.1 shows moves the
result by up to 20 ms on its own — is bit-for-bit identical.

- **No pixel loop.** `bmi .span_row_advance` becomes `bra`, so every row is
  treated as empty. All triangle setup and row walking still runs.
- **No row walking.** The four `bsr span_walk_half` calls become NOPs of the
  same length. Only the per-packet work is left.

Over the same 0-263 prefix as section 2:

| Build | Rasterizer | Frame |
|---|---:|---:|
| Full | 633.2 ms | 820.2 ms |
| No pixel loop | 260.4 ms | 447.3 ms |
| No row walking | 61.6 ms | 248.7 ms |

| Component | Time | Of the rasterizer | Of the frame |
|---|---:|---:|---:|
| Pixel loop | **372.8 ms** | 59% | 45% |
| Row/span walk | **198.8 ms** | 31% | 24% |
| Per-packet setup | **61.6 ms** | 10% | 8% |

The 59% pixel share reproduces the old model's estimate for the retired
rasterizer exactly, which is a useful check on both. `DSP readback + packet
build` sits outside the rasterizer at 114.5 ms and is unaffected by either
patch, as expected: it scales with survivors, not with coverage.

This is the split any geometry-side optimization has to be judged against.
Nothing that reduces triangle count can touch the 372.8 ms pixel loop, which
is the single largest item in the frame.

This decomposition predates the section 3.6 series and the jaw-animation
epoch; its absolute numbers describe the retired loop bodies.  A fresh
equal-layout split of the current **full 2,724-triangle renderer**, including
the opaque path in section 3.8, has now been taken over frames 0--263:

| Full-mesh patch build | Rasterizer | Frame |
|---|---:|---:|
| Normal | 544.3 ms | 763.7 ms |
| `TREX_PROFILE_NO_PIXELS` | 399.2 ms | 618.7 ms |
| `TREX_PROFILE_NO_ROWS` | 95.3 ms | 314.9 ms |

The resulting split was **145.1 ms pixel loop (26.7%)**, **303.9 ms
row/span walk (55.8%)**, and **95.3 ms per-packet setup (17.5%)**.  The two
compile-time patches preserve the replaced instruction lengths, and the
unmodified profile build is byte-identical to the measured normal binary.
These are Hatari patch measurements, not physical-Falcon timings; in
particular, section 2.4a still forbids interpreting the split as a CPU cycle
profile.

Section 3.9's instruction-cache series then changed the shape of that split
completely.  Re-taken the same way on the same full mesh and the same prefix:

| Full-mesh patch build | Rasterizer | Frame |
|---|---:|---:|
| Normal | 272.0 ms | 488.8 ms |
| `TREX_PROFILE_NO_PIXELS` | 203.8 ms | 420.4 ms |
| `TREX_PROFILE_NO_ROWS` | 91.2 ms | 308.0 ms |

| Component | Before 3.9 | After 3.9 | Delta |
|---|---:|---:|---:|
| Pixel loops | 145.1 ms | **68.2 ms** | -76.9 ms |
| Row/span walk | 303.9 ms | **112.6 ms** | **-191.3 ms** |
| Per-packet setup | 95.3 ms | **91.2 ms** | -4.1 ms |

The row walk was the target and gave up two thirds of itself.  The pixel loops
were never touched -- not one instruction of `.span_tex_opaque_loop` changed --
and still more than halved, because they share cache lines with the row body
that used to evict them.  That is the clearest single piece of evidence that
the term being removed is instruction fetch and not arithmetic.  Per-packet
setup ended up slightly cheaper than it started even though `rasterize_packet`
absorbed the work the row loop gave up: step 5 took the three classification
flags out of memory, which paid for the entry resolver and a little over.

### 3.6 Pixel-loop and row-walk micro-optimization -- measured

Three commits, each gated on an exactly equal 102-frame prefix with the
frame-100 close-up `fb.res` byte-identical and the pixel-write counter equal
to the last pixel, then measured together over the 0-263 prefix (the series
table in section 2).  The gate prefix is dominated by the cheap distant
shots, so its absolute deltas understate the full-sequence effect: the three
steps sum to -57.3 ms on the gate prefix and to -140.5 ms over 0-263.

| Build | Rasterizer, 102-frame gate prefix | Delta |
|---|---:|---:|
| Series base (jaw-animation epoch) | 386.8 ms | |
| Span-accumulated pixel counter | 379.4 ms | -7.4 ms |
| Word-mask texel addressing | 369.3 ms | -10.1 ms |
| One-muls prestep, register DDA state | 329.5 ms | **-39.8 ms** |

What each step is:

- **The statistics counter left the pixel loops.**  `raster_pixel_count` was
  an `addq.l` read-modify-write on an absolute address per written pixel --
  measurement infrastructure billed inside the hottest loop, and in the flat
  span loop the most expensive instruction there was.  Each span now
  pre-counts its full length into D7 right after the length is known and only
  transparent texels subtract one; the sum reaches memory once per trapezoid
  half.  The reported value is exactly the one the per-pixel counter
  produced, which the unchanged 20,407,685-pixel total certifies.
- **The texel offset is two word operations.**  Both Q8.8 integer parts are
  bits 8-15 of their register, so `(v AND $ff00) OR (u >> 8)` replaces the
  eight-instruction shift/mask chain bit-for-bit, and 68030 scaled indexed
  addressing (`(0,a5,d1.l)` texel fetch, `(0,a6,d2.l*4)` CLUT fetch, both
  brief-format) absorbs the two pointer builds and the CLUT's `lsl #2`.
  A3 left the pixel loop entirely; 21 instructions per written texel became
  16, at bit-identical addresses for all inputs.
- **The prestep runs on one `muls.l` per channel.**  The retired 64-bit
  sequence existed because fraction times gradient overflows 32 bits for
  sliver triangles -- but sampling only ever reads bits 8-15 of the Q8.8
  sum, everything downstream of the sum is an addition, so congruence mod
  2^16 is all that must survive, and the carry bits a single 32-bit product
  discards are multiples of 2^20.  One multiply and two shifts per channel
  per row replace the muls/swap/mask sequence; the byte-identical frame-100
  dump gates the argument.
- **The left chain X and the framebuffer row walk in registers** (A3/A2) for
  the duration of a trapezoid half instead of paying one memory
  read-modify-write per row each, and `raster_y_current` -- never read inside
  the row loop -- advances once at the end by the walked row count.
  `rasterize_packet` saves A2 alongside the OT walker's A3/D7.

Rejected and open items from the old candidate list: packing U and V into
one register for a combined per-pixel add changes the wrap behaviour the
per-register masks provide and is not bit-exact, so the byte-identity gate
rules it out.  The right chain X and the UV chain stay in memory for want of
spare registers -- freeing more would spill the texture/CLUT state in A5/A6
that the loops need every pixel.  A per-row ceil incrementalization remains
open; the fresh full-mesh patch decomposition is recorded in section 3.5.

### 3.7 Remaining CPU multiply/divide work and the DSP boundary

An instruction inventory of the active textured span path leaves **no divide
at all** on the M68030.  The triangle divisions, slopes and gradients are
already part of the DSP's span-setup record.  The apparent CPU DIV/MUL block
in `compute_span_reference` is the optional validator/fallback, not the normal
renderer; the OCCL divisions are measurement instrumentation.  Three `DIVU.W`
operations divide static O3D vertex offsets by three once while the resident
triangle stream is built; the CLUT `MULU.W` operations run only during upload.
The `MULU.W` operations in `dsp_set_frame` index the yaw/gait input tables once
per frame and are animation transport work, not raster work.  In the active
raster path the remaining operations are:

- two `MULS.L` operations on a row whose left edge is not already integral,
  used to move U and V from the DDA edge to `ceil(xl)`;
- four `MULS.L` operations plus one stride multiply when an upper half starts
  above the screen, and two more for a span crossing the left screen edge --
  cold clipping paths that the current camera does not enter; and
- one `sy0 * 512` per packet.  This last multiplication is now a same-size
  `lsl.l #8` / `add.l` pair.  It is cheaper to derive locally than to widen the
  DSP record and, because both encodings occupy four bytes, changes no later
  code address.

The full-mesh 274-frame OCCL corpus measures **1,018.96 packets and 12,439.35
walked rows per frame** (18,181 rows at the observed maximum); the LOD corpus
has 8,568.18 rows/frame.  The MC68030 manual lists 44 clocks as the maximum
register-form `MULS.L` time, so the full-mesh hot pair is bounded by 88 clocks,
or **68.4 ms/frame at 16 MHz** if every row takes the branch and every multiply
takes the maximum.  This is a theoretical hardware upper bound, not a
measurement: the timing is data-dependent, integral left edges skip the pair,
and Hatari's active MMU core charges these long multiplies zero (section 2.4a).

The direct DSP alternative loses on the **measured current host-port paths**.
Returning the two 16-bit U/V starts for every full-mesh row needs 24,879
additional 24-bit words per frame in the simple representation, **57.2 ms** at
the Hatari-derived 2.3 us/word calibration before DSP work, host unpacking and
more XBIOS calls.  Even ideal dense packing is 32 bits per row, 16,586 DSP
words and 38.1 ms before unpacking.  The simple wire path at that calibration spends
about 74 stock-CPU clocks per row against at most 88 clocks for the two
multiplies, leaving only 14 clocks for all DSP and host overhead.  It also does
not fit the chunk scratch: `chunk_uvs` plus the current 18-word output is 640 X
words, leaving 104 of the 744-word overlay; a representative full 32-survivor
chunk would need roughly 965 more simple words (about 643 even densely packed).
Smaller chunks would add still more host calls.

That 2.3 us/word figure is **not a lower bound on host-port PIO**. Static
inspection of the published Cho Ren Sha 68k Falcon build finds a third mode
(section 7.3a): one application-level rendezvous at the block boundary followed
by direct reads from `$FFFFA204/$FFFFA206`, with no RXDF test per word. Removing
the status-register read and conditional branch is unambiguously less CPU work
on a stock 16 MHz M68030, but neither its words/second nor its benefit here has
been measured on hardware. Cho Ren Sha also interleaves useful RLE copy work
between port reads; a dense U/V receiver could outrun the producer where that
loop does not. A fixed-count, block-gated blind receiver therefore reopens the
host-port experiment, but does not yet reverse the measured cost result.

An additive per-half protocol is possible in principle: the DSP could return
initial prestep state and carry/step constants instead of every row.  Exact
agreement is the constraint, not the DSP multiply -- the CPU result depends on
bits 12..27 of a 32-bit-wrapped product, so the recurrence needs at least a
28-bit state or an equivalent split representation rather than one native
24-bit DSP word.  The first layout sketch needs roughly 10--14 extra words per
survivor for the long, upper and lower left chains.  That would reduce
`MAX_CHUNK` from 32 to roughly 24--21, add about 13.8--19.3 ms/frame of wire
traffic at 600 survivors, and require a new bit-exact protocol validator.  It
has therefore not been built: the current emulator cannot measure the CPU
cycles it removes, and only a physical Falcon timing (or a future SSI/DMA
transport) could demonstrate a net win.

**Conclusion for the current host port:** the per-word-polled and XBIOS paths
do not support a profitable direct MUL/DIV offload. The Cho Ren Sha-style
block-gated blind path is now an explicit unresolved candidate, not a claimed
loss; it still occupies the M68030 for every word and needs a physical-Falcon
throughput/correctness result. SSI-to-record-DMA remains the stronger
architectural variant because its transfer can run without M68030 PIO and
outside the consuming frame's critical path; section 8.1 specifies it. The
next low-risk arithmetic experiment remains the CPU-side per-row ceil
incrementalization in roadmap item 11. It attacks the same two hot multiplies
without sending row data. The packet stride multiply has been removed locally.
No performance baseline is changed by this section: all milliseconds above are
cost-model estimates, and the output/build gates below record correctness only.

### 3.8 Qualified opaque packets and the 16-bit CLUT -- implemented

Normal textured packets used to pay the palette-word validity `BTST` and
branch for every sample even when their source triangle could never reach a
zero PS1 palette word.  The new host-owned qualification closes that branch
without changing the DSP wire record or the potentially-transparent path:

- [`tools/o3d2opaque.js`](tools/o3d2opaque.js) reads the authoritative TIM
  pixel data and little-endian CLUT words.  Five pages contain no invalid
  referenced palette word and qualify in full.  On holed page 10 it computes
  an integer-only closed texel-cell/affine-UV-triangle intersection and then a
  two-texel Chebyshev dilation with 8-bit wrapping.  This deliberately covers
  more than the old floating-point `M_uv` test.  The dilation is tied to the
  current 240x224 Q8.8 walker: a target, precision or sampling change requires
  regeneration and the recorded gate below.
- The generated full-mesh sidecar is one byte per source triangle:
  `trex_opaque.bin` is 2,724 bytes and qualifies **2,491/2,588 (96.25%)**.
  The 136 flat triangles remain on the flat path. Page 10 contributes
  671/768; every textured triangle on pages 12/14/26/28/30 qualifies.
- The packet builder already owns the source-triangle identity.  It maps a
  qualified normal textured triangle to spare host command bit 23
  (`OPAQUE_PACKET_BIT`) and explicitly clears the interpretation for flat or
  semitransparent packets.  No field or word is added to the 14-word DSP
  record or the host packet.
- The original flag-bearing longword CLUT stays authoritative for possible
  holes and semitransparency.  In parallel, upload builds six pages x 64 banks
  x 256 exact RGB555X words, **196,608 bytes (192 KiB)**.  Qualified packets
  select this word table.  Their scalar loop is 12 instructions/sample rather
  than 16 and vasm accepts the useful final operation directly:
  `MOVE.W (0,A6,D2.L*2),(A4)+`.  It eliminates the validity test and the
  separate framebuffer-pointer increment without pretending that a longword
  framebuffer store saves ST-RAM transfers.

The soundness gate is executable, not inferred from the triangle count.
[`tools/opaque_selftest.py`](tools/opaque_selftest.py) regenerates the
full-mesh table byte-for-byte and, when given OCCL dumps from a baseline binary (opaque hint
disabled so bit-17 rejects remain observable), rejects any qualified packet
with one invalid sample.  Across every available recorded frame for both
assets it found no false positive:

| Asset | Frames | Packets | Samples | Qualified packets | Qualified samples |
|---|---:|---:|---:|---:|---:|
| LOD 1,600 | 274 | 164,956 | 9,102,114 | 140,833 (85.38%) | 8,552,962 (93.97%) |
| Full 2,724 | 274 | 279,196 | 9,373,240 | 250,878 (89.86%) | 8,903,212 (94.99%) |
| **Combined** | **548** | **444,152** | **18,475,354** | **391,711 (88.19%)** | **17,456,174 (94.48%)** |

False negatives are harmless.  A new camera or raster convention is not
silently grandfathered: its dumps have to pass this same zero-drop condition
before the corresponding sidecar is accepted.

Timing uses linked A/B binaries with exactly the same layout.  The baseline
contains every new instruction and table but one data longword disables hint
emission (`TREX_OPAQUE_BASELINE`); `cmp -l` reports one differing byte.  The
frame-100 framebuffer, pixel counters and packet counters are identical:

| Gate | Baseline off | Opaque on | Isolated delta |
|---|---:|---:|---:|
| LOD, frames 0--101, total | 403.8 ms | 395.7 ms | -8.1 ms |
| LOD, rasterizer | 261.0 ms | 252.5 ms | **-8.5 ms** |
| Full mesh, frames 0--263, total | 791.5 ms | 763.7 ms | **-27.8 ms** |
| Full mesh, rasterizer | 572.7 ms | 544.3 ms | **-28.4 ms** |

The full-mesh result is the performance authority: 1.26 to 1.31 FPS in this
Hatari layout, with 9,019,985 total writes and 1,149 packets in the final
frame in both arms.  Frame 100 is byte-identical (SHA-256
`d89958b314c924ad6654f5e92cd29b859ab99b0c4f197170dfe8cfc0216f3d16`).
The LOD checkpoint remains SHA-256
`aa67eb8eae94020079d0a9132dde39cc2655368a5fb86dcd23fbb8710a09e988`.
These fresh absolute numbers must not be compared with older layouts; only
the one-byte A/B delta is attributed to the path.  No physical-Falcon timing
exists.  The current normal TOS is 1,123,302 bytes; its `TREX_RUN` variant has
the same size and differs only in the two established output-gate data bytes.

At full-mesh recorded coverage the static instruction delta is about
32,493.5 qualified samples/frame x four instructions = **129,974 removed
M68030 instructions/frame**.  The longword-to-word CLUT change also removes
one nominal 16-bit ST-RAM transfer for an uncached lookup, about 65.0 KiB/frame
at that coverage, but cache-line fills and Hatari's FAST32 model mean this is
a bus-cost model, not a measured transaction count.

A separately gated 2x loop with an exact odd-pixel tail was also tested, only
after the scalar path won.  At identical full-mesh output it regressed the
102-frame rasterizer from 375.0 to 399.4 ms and total frame time from 604.3 to
628.7 ms.  It is **rejected and not present in the shipping source**.

### 3.9 The hot loops did not fit in the instruction cache -- measured

Section 2.1 has said since the beginning that this program's timings move by
tens of milliseconds for reasons that are not the arithmetic, and section 2.4a
named instruction fetch as the suspect with evidence behind it. This section
is what happened when the suspect was measured instead of suspected. It is the
largest single result in this document: **-38.2% of the frame on the shipping
LOD and -36.0% on the full mesh, at byte-identical output**, from moving and
shrinking code without changing what any of it computes.

**First, the cache is on.** Section 2.5 wrote that "`CACR` is never programmed
anywhere in this source, so the cache may not even be on". It is on. Hatari's
debugger reports `CACR = $3111` while the program runs -- EI, IBE, ED, DBE and
WA -- so TOS 4.02 enables both 68030 caches at boot and nothing in the
renderer disturbs them. Hatari models them: `cpu_data_cache` and
`cpu_compatible` both default true (`src/configuration.c:841,844`), and with
`--mmu` the 030 path takes `get_iword_mmu030c_state` and the `dc030` data
accessors. The 68030 instruction cache is **256 bytes, direct-mapped, line
selected by address bits 4..7.** That is the constant the rest of this section
is about, and it is a property of the chip, not of the emulator.

**The row loop was 552 bytes.** `span_walk_half`'s per-row body ran from
`.span_row_loop` to its closing `bne` across 552 bytes of address space, of
which about 304 executed on a qualified-opaque textured row: the row prologue,
one of four pixel bodies, and `.span_row_advance` -- which sat at the far end,
*behind* the 146-byte semitransparent blender and two other pixel loops that
the row had just jumped over. Mapped onto sixteen cache lines, five lines
carried three competing regions each. Every row re-fetched them from ST-RAM.
That is the whole mechanism: 12,439 rows per frame on the full mesh, each
paying tens of longwords of instruction fetch for code it had executed one row
earlier.

Five steps, each measured over the identical 0--263 prefix, each gated on the
frame-100 `fb.res` dump and on the pixel and packet counters:

| # | Change | Loop bytes | LOD ms | LOD FPS | Rasterizer |
|---|---|---:|---:|---:|---:|
| — | baseline | 552 | 517.3 | 1.93 | 376.8 |
| 1 | cold row bodies moved out of the loop | 308 | 472.3 | 2.12 | 332.2 |
| 2 | packet invariants hoisted; loop crosses 256 | **248** | 342.9 | 2.92 | 203.0 |
| 3 | right chain in the freed shift register | 242 | 334.7 | 2.99 | 194.1 |
| 4 | record-unpack loop 336 -> 248 bytes | — | 327.9 | 3.05 | 189.1 |
| 5 | packet classification flags leave memory | — | **319.8** | **3.13** | 180.7 |

and on the full 2,724-triangle mesh over the same prefix:

| # | Full-mesh ms | FPS | Rasterizer | Packet stage |
|---|---:|---:|---:|---:|
| — | 763.8 | 1.31 | 544.3 | 189.1 |
| 1--3 | 513.8 | 1.95 | 294.4 | 189.0 |
| 4 | 502.4 | 1.99 | 285.8 | 186.6 |
| 5 | **488.8** | **2.05** | 272.0 | 186.3 |

The baseline reproduces section 8.2's recorded full-mesh figure to 0.1 ms
(763.8 against 763.7, rasterizer 544.3 against 544.3), which is what makes the
whole ladder comparable with everything already in this document.

What each step is:

1. **`.span_row_advance` moved next to the pixel body it follows**, and the
   transparent-textured, flat and semitransparent bodies plus both screen-edge
   clip corrections moved below the walker's `rts`. Not one instruction
   changed except the `bra` that became a fall-through. **-45.0 ms.**
2. **Everything packet-invariant left the row.** `raster_du_dx`/`raster_dv_dx`
   are loaded into A0/A1 once per trapezoid half; the four-way
   textured/semitransparent/opaque/flat test became a single
   `jmp ([raster_span_entry])` through a pointer `rasterize_packet` resolves
   once; and the CLUT bank select lost its `gouraud_enabled` test and its
   stride branch to a `muls.w raster_lvl_stride,d2` against a packet constant.
   Sixty bytes, and the loop went from 308 to 248. **-129.4 ms.**
3. **The 12.12 shift constant gave up its register to the right chain.**
   `asr.l #8`/`asr.l #4` costs four bytes more of instruction stream than
   `asr.l d3` and buys one read plus one read-modify-write of memory per row.
   **-8.2 ms.**
4. **The record-unpack loop is the same shape.** Its body is fetched once per
   survivor and was 336 bytes. Branchless sign extension (`x ^ m - m` with the
   field's sign bit held in a register) for six fields, big-endian byte loads
   in place of load-and-mask for the four UV components, and the never-taken
   validator call moved out of line brought it to 248. **-6.8 ms.**
5. **`raster_textured`, `raster_semitrans` and `raster_opaque` never leave
   `rasterize_packet`**, so they no longer leave registers: the parse now
   produces the pixel-body address, the bank stride and the CLUT selector
   directly. The three cells stay declared as reserved space, because every
   raster state cell below them has a measured cache phase (item 16).
   **-8.1 ms.**

Steps 2 and 4 are the two that cross 256 bytes and they are not linear in the
bytes removed: step 2 removed sixty bytes and 129.4 ms, step 3 removed six
more and 8.2 ms. **The threshold is the effect.** Below it a line fetched for
row *n* is still valid for row *n+1*; above it the loop evicts itself.

Gates, at every step:

- frame-100 `fb.res` SHA-256 `aa67eb8e…9988` on the LOD and `d89958b3…3d16`
  on the full mesh, unchanged from the recorded checkpoints of section 3.8;
- 8,757,777 written pixels and 644 packets (LOD), 9,019,985 and 1,149
  (full mesh), equal to the last pixel at every step;
- the flat path is gated separately, because step 2 changed its mechanism
  rather than skipping it: `gouraud_enabled = 0` built from the pre-change and
  post-change sources produces SHA-256 `4ce9b1b6…71d9` and 1,151,405 written
  pixels in **both**, so giving the unconditional bank select `dlvl = 0` and
  the packet's own level reproduces the single fixed bank exactly;
- `trex_run.tos` remains layout-identical to `trex_m68030.tos` -- same size,
  `cmp -l` reports the same two documented data bytes.

Two caveats bound how far this may be read. The individual steps are each a
new text layout, so section 2.1's noise floor applies to them one at a time;
the cumulative -197.5 ms and -275.0 ms are an order of magnitude above it, and
the byte counts predicted where the discontinuity would fall. And section 2.4a
still holds: the measuring core charges bus traffic and no instruction
execution at all, so this frame is *entirely* fetch and access cost, which is
exactly the term these changes attack. A real Falcon also pays for the
arithmetic, so the same removal is a smaller share of a hardware frame. The
mechanism itself is not an emulator artefact -- the 256-byte direct-mapped
instruction cache is in the MC68030 -- but no figure here has been taken on a
Falcon.

#### 3.9a Two follow-ups that removed work and cost time

Both were built on top of step 5, both produce a byte-identical frame-100 dump
and identical pixel and packet counters, and both are **slower**.  They are
recorded because together they say something the series above does not.

**The apex row.** At the top of an upper trapezoid half both DDA chains still
sit on the same X, so `ceil(xl) > ceil(xr)-1` and the row is empty for every
possible value, before and after either edge clamp.  The walker ran its whole
row prologue for it and fell out at the emptiness test.  Stepping the chains in
a 60-byte routine called once per packet instead removes one iteration from
every upper half in the frame:

| | LOD | Full mesh |
|---|---:|---:|
| step 5 | 319.8 ms | 488.8 ms |
| + apex skip | **329.1 ms** | **502.6 ms** |

**The texture-page search.** `rasterize_packet` resolved a five-bit TPage by
walking a six-entry list, about 37 bytes and 1.5 extra reads per packet more
than a static 32-byte lookup table costs.  The table is strictly less work:

| | LOD | Full mesh |
|---|---:|---:|
| step 5 | 319.8 ms | 488.8 ms |
| + page table | **326.6 ms** | **496.1 ms** |
| + page table + apex skip | 328.1 ms | 500.6 ms |

**They do not add up, which is the finding.** +9.3 and +6.8 separately, +8.3
together.  A change with a real cost of its own composes; layout does not.
After section 3.9 the row loop is cached across its own iterations, so an
iteration of it no longer costs instruction fetch -- only its dozen or so
memory accesses. What still costs fetch is the **refill after every
`rasterize_packet`**: that routine's executed body is around 450 bytes, it
covers all sixteen cache lines, and the walker's 242 bytes are therefore
re-fetched once per packet no matter what. Both changes here pay into that
term -- the apex skip by adding 60 more bytes of once-per-packet code, the page
table by moving `rasterize_packet`'s remaining bytes onto different lines --
and both pay more into it than the work they removed was worth.

The consequence for what to try next is specific: **inside the rasterizer,
removing per-row work is now worth roughly its memory accesses and nothing
more, while anything that changes the once-per-packet code footprint is worth
several times its size.**  The first thing to measure on this stage is
therefore not a smaller row body but whether the per-packet refill itself can
be reduced -- which needs `rasterize_packet`'s executed footprint under the
cache size, and at ~450 bytes it is not close.  Neither change is in the tree;
the shipping binary is byte-identical to the step-5 build measured above.

**The general rule this establishes for this program**: on a 16 MHz 68030
with a 256-byte instruction cache, the length of a loop body is a first-order
cost, and a byte that merely *sits* between the top of a loop and its closing
branch is as expensive as one that executes. Cold paths belong out of line.
Everything constant across the iterations belongs above them. It is worth
checking the address span of any loop this program executes thousands of times
per frame before optimizing anything inside it.

#### 3.9b The per-packet fetch term, measured -- and the dead weight in it

Section 3.9a closed by demanding the per-packet refill be measured before any
more per-row work.  Listing-based accounting (vasm -L addresses summed over
the branch path a dominant packet actually executes: qualified-opaque
textured, Gouraud build, unclipped, both halves live) replaces 3.9a's
~450-byte estimate with exact numbers:

| fetched per packet | bytes |
|---|---:|
| `rasterize_packet`, executed body (one CLUT arm, one mid arm) | 432 / 482 |
| `span_walk_half` entry + exit, run per half | 2 x 138 |
| row loop, refetched after the packet body swept the cache | 230 |
| OT node walk | 20 |
| **total** | **938 / 988** |

(432 with the middle vertex on the right, 482 on the left -- that arm
re-derives the restart U/V.)  At the model's ~8.05 cycles per longword this
is ~1.9k cycles per packet: 136-143 ms of the full mesh's 236.7 ms rasterizer
stage, and 76-80 ms of the LOD's 178.7, is per-PACKET instruction fetch.
The walker's per-row work stopped being the dominant term in 3.9; this is
what replaced it.  Both the packet path and the walker cover all sixteen
cache lines, so no placement can save part of the walker across the packet
boundary -- the only lever is removing executed bytes, at the exchange rate
3.9a predicted, about 2 cycles per byte per packet.

Three cuts follow, each behavior-preserving and none touching the row loop
(still 230 bytes, a fit at every phase since 230+15 <= 256):

1. **The packet-time CLUT bank pointer was dead.**  Since the Gouraud change
   moved the bank select into the row prologue, a6 is derived from
   `raster_clut_tint_base` before any pixel body reads it; the five
   instructions per CLUT arm that still computed a6 at packet time (14 bytes
   plus a table read on the executed arm) had no consumer left.  A full-file
   scan shows no other a6 read outside the walker.  Measured alone: 145.1 to
   143.9 ms rasterizer on the 102-frame LOD gate, -1.2 ms against a -1.13 ms
   model -- the exchange rate confirmed to a tenth.
2. **The dominant class now falls through classification.**  The old chain
   preloaded the semi defaults, tested semi, preloaded the general-texture
   entry, tested the opaque hint, and only then overwrote everything with the
   qualified-opaque setup: 58 executed bytes for 88-95% of all packets.
   Semi-transparency still wins outright -- the producer contract of section
   3.8 is untouched -- but both minority arms resolve out of line now: 36
   bytes on the fall-through.
3. **Y clipping is decided once per packet, not tested per half.**  The two
   halves together walk exactly [sy0, sy0+rows_up+rows_low), so
   sign(sy0 | (SCREEN_HEIGHT - y_end)) covers both clamps for both halves:
   one 26-byte straight-line computation per packet replaces 2 x 36 bytes of
   entry checks and six absolute reads; the clamp block itself moved below
   `.span_walk_empty` unchanged and is entered on the flag.  The call sites'
   existing rows_up/rows_low tests keep zero-row halves off the hot entry.
   The OT walk's bucket cursor also moved into a2, which `rasterize_packet`
   preserves anyway, ending the per-node a0 push/pop.

The ladder on the 102-frame LOD gate prefix, then the confirmation runs, all
at byte-identical frame-100 `fb.res` (LOD `aa67eb8e…`, full mesh
`d89958b3…` -- the recorded 3.9 checkpoints), equal written pixels and equal
packet counts in every arm:

| 102 LOD | rasterizer | frame | fps |
|---|---:|---:|---:|
| base | 145.1 | 286.3 | 3.49 |
| + dead a6 | 143.9 | 285.0 | 3.51 |
| + fall-through + Y flag + a2 cursor | 136.4 | 277.4 | 3.60 |

| confirm | rasterizer | frame | fps |
|---|---:|---:|---:|
| LOD 0-263, base | 178.7 | 317.4 | 3.15 |
| LOD 0-263, cut | 170.6 | 309.1 | **3.24** |
| full mesh 0-101, base | 236.7 | 461.6 | 2.17 |
| full mesh 0-101, cut | 221.0 | 445.7 | **2.24** |

Both baselines reproduce this document's recorded state to the tenth -- 317.4
and 461.6 are the delta-clear re-measurement's off arms -- which keeps this
ladder comparable with everything above.  The measured -8.1/-15.7 ms sit
above the pure fetch model's -5.7/-10.2 because the removed bytes carried
absolute data reads with them; and unlike a coverage-scaling change, the
102er delta transfers to the 264er almost unchanged, because the term scales
with packets.

What remains of the term is ~860 bytes per packet, and the accounting says
where the next candidates stand: a per-frame resolve pass in the batch
pattern the delta-clear coda already names -- classification, page/CLUT
resolution and the Y flag computed for every packet in one cache-resident
loop over the packet buffer, trading ~110 more executed bytes per packet
against a few longword accesses -- and the packed u|v presplit, which buys
28 bytes per packet but must find its room against the record-unpack loop's
250-of-256 budget.  Neither is built.  The 8-byte `delta_clear_enabled` test
stays where it is: it is the price of section 2.5's one-byte A/B contract.
(The resolve pass has since been built -- section 3.9c.)

#### 3.9c The batch resolve pass: per-packet setup moved into one resident sweep

3.9b named the batch pattern as the next candidate; built and measured, it is
the third win of this series.  The packet grew six RESOLVE SLOTS
(`GPU_PACKET_WORDS` 26 to 32 -- the buffer and the occlusion index divide
scale through the constant, the builder pays one longer LEA), and a sweep at
the top of `gpu_rasterize_ot` -- inside the t_raster bracket, so every
rasterizer figure in this document stays comparable -- classifies each
packet once, resolves the page/CLUT/tint pointers and the flat colour, and
parks span entry, texture base, tint-or-flat colour, bank stride and shade
in the slots.  The sweep's resident loop is 120 bytes ($1D06..$1D7E in the
build measured here), the minority arms sit below its DBRA, and
`rasterize_packet` loads the five values with one MOVEM and six cell
stores: the parse, the classification, the page lookup and the CLUT
arithmetic left its per-packet text entirely, ~92 executed bytes plus their
table reads.

The exchange is fetch-per-packet against a store/load roundtrip through the
slots (five longword writes per packet in the sweep, five reads in the
rasterizer, and the sweep re-reads the command and token words once per
frame).  The fetch model nets about -80 cycles per packet; the measurement
came in at roughly double, as in 3.9b -- removed text carries its data
accesses with it:

| 102 LOD | rasterizer | frame | fps |
|---|---:|---:|---:|
| 3.9b state | 136.4 | 277.4 | 3.60 |
| + resolve pass | 129.7 | 270.8 | 3.69 |

| confirm | rasterizer | frame | fps |
|---|---:|---:|---:|
| LOD 0-263 | 170.6 -> 164.0 | 309.1 -> 302.6 | 3.24 -> **3.30** |
| full mesh 0-101 | 221.0 -> 211.3 | 445.7 -> 436.0 | 2.24 -> **2.29** |

Gates as always: frame-100 `fb.res` byte-identical in every pair (the
`aa67eb8e…`/`d89958b3…` checkpoints), written pixels and packet counts
equal, and the packet-build stage unchanged (113.6 to 113.8 ms, noise).
Combined with 3.9b the ledger of this campaign reads **317.4 to 302.6 ms
(3.15 to 3.30 FPS) on the LOD 0-263 and 461.6 to 436.0 ms (2.17 to 2.29)
on the full mesh**, at byte-identical output throughout.

Two notes bound the result.  The sweep's flat-packet arm is exercised by no
packet in either gated corpus -- the mesh is fully textured and
`raster_force_flat` has no writer, it stays a debugger patch point -- so
that arm is transplant-verified only: the formulas are the old flat arm's,
moved.  And the resolve slots are refilled every frame before any read, so
a stale slot cannot survive a mesh or count change; the spare sixth slot is
for the next candidate (fb_row or the Y flag, should their roundtrip ever
price in).

## 4. Work already assigned to the DSP

The current DSP program keeps the static vertex mesh, the packed triangle
indices and the complete 3,610-entry PS1 corner-normal table resident, and
performs:

1. base-pose plus deduplicated full-body gait reconstruction,
2. signed-Q12 application of active sparse morph targets 5-8,
3. 3x3 fixed-point matrix transformation and object-space translation,
4. independent-X/Y perspective projection and projected Z generation,
5. zero-area, near-plane, bounding-box and backface culling,
6. per-corner (Gouraud) shading against a camera-space light direction,
   selectable back to the earlier per-face flat path (section 4.4),
7. chunk-local average-Z/Ordering-Table key generation, and
8. complete clipped DDA span-setup construction for every survivor.

UV pairs are no longer resident: the corner-normal table displaced them, and
each `BUILD_TRIANGLES` chunk now carries its own instead (section 4.4a).

The current protocol is:

```text
LOAD_VERTICES:
    command, count, count * (x, y, z)

LOAD_NORMALS:
    command, count, count * (nx, ny, nz)
    -> ACK_NORMALS, count
    The complete PS1 corner-normal table, one unit object-space normal per
    entry in TMD normal order (count = 3,610). LOAD_TRIANGLES' packed
    corner-normal indices address it directly. Section 4.4a has the
    DSP-side split that makes it resident.

SET_FRAME:
    command, 9 matrix words, 3 translation words,
    3 animation-bias words, focal length, centre x, centre y, near value,
    3 camera-space light-direction words
    Legacy diagnostic/fallback path; focal X and Y are identical.

SET_ANIMATED_FRAME:
    command, 9 matrix words, 3 translation words,
    focal X, focal Y, centre x, centre y, near value,
    3 camera-space light-direction words
    -> ACK_ANIMATION_BEGIN

LOAD_ANIMATION_GAIT:
    command, first vertex, count, count * (delta x, delta y, delta z)
    -> ACK_ANIMATION_GAIT
    Repeated in chunks of at most 512 vertices.  The DSP writes
    base+gait into the camera/object work array.

APPLY_ANIMATION_TARGET:
    command, signed Q12 weight, first vertex, count,
    count * (delta x, delta y, delta z)
    -> ACK_ANIMATION_TARGET
    Sent only for non-zero targets 5-8, also in at most 512-vertex chunks.

FINISH_ANIMATED_FRAME:
    command -> ACK_FRAME, vertex count
    Transforms and projects the completed object-space work array in place.

GET_VERTICES:
    command -> acknowledgement, count * (screen x, screen y, z, flags)

LOAD_TRIANGLES:
    command, count, count * (i0 | i1<<12, i2 | n0<<12, n1 | n2<<12)
    -> ACK_LOAD_TRIANGLES, count
    The static index list, uploaded once: three vertex AND three
    corner-normal indices per triangle, three packed words total since
    Gouraud (was two). Twelve bits per index; 1,376 vertices and 3,610
    corner normals both fit. Section 4.4a has the DSP-side split that made
    room for the wider record.

BUILD_TRIANGLES:
    command, count, global index of the chunk's first triangle,
    count * 2 packed UV words (one pair per triangle, chunk order)
    -> ACK_TRIANGLES, survivor count
    The index/corner-normal records are resident, so the header is three
    words regardless of chunk size, as it always was -- but the UV tail is
    new and does scale with chunk size, because the corner-normal table
    displaced the UV pairs that used to be resident too (section 4.4a). It
    ships for the WHOLE chunk, before the DSP has culled a single triangle
    in it, not survivors only. The ack must carry the survivor count:
    Dsp_BlkUnpacked transfers a word count fixed before the call, so the
    host has to know the GET_TRIANGLES reply size in advance. A fully
    culled chunk reports zero and the host skips the fetch.

GET_TRIANGLES:
    command
    -> ACK_GET_TRIANGLES, survivor count,
       survivor count * 18-word packed span-setup record
    Survivors only -- culled triangles send nothing.  Section 9.2 defines
    the seventeen classic DDA fields and their packing contract; section
    4.4a has the four Gouraud level words the record gained on top of them
    (section 9.2's own field table predates that addition).
```

The survivor key packs the chunk-local triangle index in bits 0..7 and the
4-bit shade level in bits 8..11. Both fit one 24-bit DSP word, so the lighting
result adds no host-port traffic to a stage that is already the second-largest
of the frame. Widening the record instead would have added 2,724 words per
frame. At the 2.3 us per word measured in section 4.1, widening the record
would have cost about 6 ms per frame — twice what the whole shading feature
actually cost.

The chunk base index addresses both resident arrays: the index list and the
face normals are both indexed globally, while survivor keys stay chunk-local.

The active M68030 frontend splits 2,724 records into 86 chunks of at most 32
triangles. Each chunk is announced with a three-word `Dsp_BlkUnpacked`,
acknowledged, and fetched with a second `Dsp_BlkUnpacked`. Returned chunk-local
survivor indices are rebased to the global triangle index on the M68030 before
packet construction, and the shade level is unpacked into a three-longword
host-side record.

### 4.1 The index list is resident, and what that measured

The index list used to be re-sent with every chunk of every frame: 43 chunks
carrying 4 words per triangle, 10,896 words, for a list that
`dsp_build_triangle_stream` builds once from the O3D and never touches again.
That was 49% of all host-port traffic in the frame.

`CMD_LOAD_TRIANGLES` now uploads it once, packed, at init. Measured over 64
frames against the same binary without the change:

| Stage | Per-frame upload | Resident list | Delta |
|---|---:|---:|---:|
| DSP readback and packet build | 128.6 ms | 103.6 ms | **-25.0 ms** |

The render output is unaffected: `fb.res` is byte-identical, 17,072 pixels and
752 packets in both. The `material` word went away with the per-frame upload —
the DSP stored it and never read it, and the host looks its own copy up by
source index when it builds packets.

This also retired the input double-buffering the DSP needed. A chunk command is
now three words in and everything else out, so each `Dsp_BlkUnpacked` is
one-directional by construction rather than by careful sequencing.

**Calibration for future protocol changes:** 25.0 ms for 10,896 removed words
is about **2.3 µs per host-port word**, or roughly 37 M68030 cycles at 16 MHz,
including the per-call `Dsp_BlkUnpacked` XBIOS overhead. This replaces the
5.8 µs/word upper bound previously derived from the whole stage, which also
contained the sign-extension pass and the host packet build. Use 2.3 µs/word
when costing a wider result record: the 17-word setup record sketched in
section 9.2 would cost about 29 ms per frame for 752 survivors.

### 4.1a Survivors-only records with the clipped bounding box

The second protocol revision changed the result stream in two ways at once:

- **Survivors only.** `GET_TRIANGLES` used to return two words per *input*
  triangle — 5,448 words per frame, three quarters of them `CULLED_MARKER`
  padding. Now `BUILD_TRIANGLES` acks with the survivor count, the host sizes
  its receive from it (skipping the fetch entirely for fully-culled chunks),
  and only survivors are sent.
- **The bounding box rides along.** `make_triangle_bbox` computes the clipped
  screen-space box on the DSP — after the area cull, so it only runs for the
  ~27% of triangles that survive — and returns it as two packed words. The
  min/max/clamp/empty-test block in `rasterize_packet` (~75 instructions per
  packet) is deleted; the rasterizer loads four longwords from the packet tail
  instead. A box that clips empty is exactly the fully-off-screen case, so the
  separate pre-area screen test was subsumed by it.

Result-stream wire cost per final frame: 5,590 words before, 86 + 4 × 752 =
3,094 after. Measured over 64 frames against the resident-list baseline, at
byte-identical `fb.res`, 752 packets and 17,072 pixels in both:

| Stage | Before | After | Delta |
|---|---:|---:|---:|
| DSP readback and packet build | 103.6 ms | 96.6 ms | **-7.0 ms** |
| Software rasterizer | 1,310.5 ms | 1,228.0 ms | **-82.5 ms** |
| **Total** | **1,503.5 ms** | **1,415.2 ms** | **-88.3 ms** |

The transfer delta matches the calibration: -2,496 words predict -5.7 ms, plus
the retired marker-skip iterations in two host loops. Of the rasterizer delta,
roughly 25-45 ms is the deleted block by instruction count; the remainder is
secondary layout and instruction-cache effect from the ~450-byte code removal
and the 64-to-80-byte packet stride — real and reproducible in this binary,
but not attributable line by line (section 2.1).

The host fallback `build_host_triangle_stream` produces the same dense record
stream with nothing culled. It is the reason `rasterize_packet` keeps its
cross-product zero test — the fallback culls neither degenerate nor
backfacing triangles. That path only runs when the DSP is absent and is not
exercised by the measured Hatari runs.

### 4.1b The span-setup record, validated field-for-field

Protocol revision four ships the fifteen span-setup fields of section 9.2
with every survivor — everything `rasterize_packet` derives per packet, from
the Y-sort to the UV gradients — under a validation-first regime: the host
recomputes every field with its own arithmetic and compares EXACTLY, while
the rasterizer keeps consuming its own setup until the comparison is clean.

What that took:

- **The projection now overlays the camera array in place.**
  `project_vertices` runs backward so vertex i's four-word record at 4i
  lands above every camera triple still to be read (4i > 3i-1 for all i).
  That freed 4,128 X words, verified byte-identical before anything else
  changed.
- **The static UV bytes live on the DSP** (`CMD_LOAD_UVS`, two packed words
  per triangle, 5,448 words once), packed from the same
  `gpu_texture_meta_buffer` every host-side consumer reads.
- **Both resident Y arrays moved up** to `Y:$09C0` to make room for the span
  code; the program-growth trap boundary is now `P:$09BF`.
- **Chunks shrank to 32 triangles** so the seventeen-word output records fit
  the X bank.

The verdict, over 64 frames and two full revolutions: **56,826 records,
852,390 field comparisons, zero mismatches**, at a byte-identical
framebuffer throughout (the rasterizer never touched the records).
`tools/decode_val_stats.py` decodes the per-frame report.

The validator earned its existence three times before turning clean:

1. **Packet-stride shear (host).** Removing the four bounding-box longwords
   from the packet builder without shrinking `GPU_PACKET_WORDS` left the
   builder writing 16-long packets against a 20-long stride — every packet
   after the first was read sheared, rendering full-screen garbage while
   every DSP-side value validated clean.  The stride constant and the
   builder are now documented as one invariant.
2. **Dividend positioning (DSP).**  The 24-step DIV idiom computes
   A48/(2·divisor), so a numerator built by LOADING a value (which lands at
   <<24 in the accumulator) must shift RIGHT into place, while MAC-built
   sums already carry a <<1 and shift LEFT.  The first attempt shifted
   loaded values left and saturated every division-derived field at
   $7FFFxx — the validator's very first frame caught it.
3. **The fractional-MPY trap, again (DSP).**  The sorted cross product was
   stored from A1, but integer MPY results live in the accumulator's LOW
   word — the gradients divided by 0 or -1 and saturated.  The same trap
   the old area routine's normalization comment warns about; the store now
   reads A0 and says why.

Mode costs, measured over 64 frames each at identical output: shipping the
record and computing it on the DSP costs **+44.7 ms** on the readback stage
(96.9 to 141.6 ms; wire at the section 4.1 calibration plus the DSP's ~9
divisions per survivor), and the host validator a further **+168.8 ms** —
the validator now off by default since the switch-over below.

### 4.1c The switch-over: the rasterizer consumes the record

Before the flip the record gained two fields the consumer cannot derive
without redoing the sort: the sorted top and middle vertices' UV bytes
(u|v<<8 each), the left chain's start values.  Nineteen words per survivor,
gated CLEAN through the validator before anything consumed them.

The flip itself:

- **The packet lost its screen coordinates.**  Twenty-one longwords now:
  command|shade, material, OT key, texture page, then the seventeen span
  fields copied verbatim from the record (sign-extended once during chunk
  unpack).  The OT submit reads its key at the new fixed offset.
- **`rasterize_packet` derives nothing.**  No sort, no cross product, no UV
  parse, not a single division — it parses the command, resolves the
  texture page, loads the chain state from the packet and calls
  `span_walk_half` twice.  The walker itself is untouched.
- **GET_VERTICES retired from the normal path.**  The record pipeline never
  reads a projected vertex; `fetch_projected_vertices` runs only for the
  validator's reference arithmetic or the host fallback, at most once per
  frame.
- **The fallback shares the validator's arithmetic.**  The reference
  computation is now `compute_span_reference`, used by the validator to
  compare and by `build_host_triangle_stream` to emit records when the DSP
  path is unavailable — one implementation of the host-side formulas
  instead of two, with a degenerate guard (the record consumer has none).

Acceptance was byte-identity: 852,390 validated field equalities imply the
record-driven walk renders the exact frame the self-computing walk did, and
it does — `fb.res` is unchanged through the entire conversion, and the
64-frame gate with validation on stayed at zero mismatches.

| Stage | Anchor (self-computing) | Record-driven | Delta |
|---|---:|---:|---:|
| DSP readback, records, packet build | 96.9 ms | 131.0 ms | +34.1 ms |
| Span rasterizer | 340.4 ms | 269.6 ms | **-70.8 ms** |
| **Total** | **493.7 ms** | **456.6 ms** | **-37.1 ms** |

The rasterizer figure now contains no setup arithmetic; what remains is the
command/page parse, the chain loads, the row walk and the pixel loops.

### 4.1d Wire packing and the pipelined chunk protocol

Two further readback-stage reductions, gated like everything else and both
byte-identical in output:

**The record travels packed at fourteen words** (down from nineteen; layout
mirrored between `SPAN_RECORD_WORDS` in the DSP source and the host's unpack
comment).  The key, shade, middle-vertex flag and both sorted slot ids share
one word; sy0/rows and the two chain-restart X coordinates pack as 12-bit
fields, relying on the same |value| < 2048 bound the 12.12 slope format
already imposes; and the two UV start packs left the wire entirely — the
host rebuilds them from its own resident texture metadata via the slot ids.
The unpack expands everything into the identical seventeen-field block, so
the packet builder and rasterizer never noticed the change.  The validator
now compares against the *unpacked* fields, which checks the DSP arithmetic
and the pack/unpack round trip in one comparison — and promptly caught a
real bug on first contact: the metadata lookup read its source index at
`-80(a1)` while the record head was only 18 longwords behind the write
pointer at that moment, fetching the *previous* record's field as an index.

**The chunk protocol is pipelined.**  `dsp_packets_begin` launches the first
BUILD (three words out, nothing back) and returns while the DSP computes it;
the frame loop runs the framebuffer clear inside that window;
`dsp_packets_finish` then drains the pipeline — read the in-flight chunk's
ack, fetch its records, immediately launch the next chunk, and only then
unpack, so the DSP always computes chunk N+1 while the host expands chunk N.
The DSP program is untouched: only the order of host transactions changed.
Every failure point sits between transactions, so the host fallback never
collides with a pending reply.

Measured over 64 frames at byte-identical output:

| Stage | Before | After packing + pipeline | Delta |
|---|---:|---:|---:|
| DSP readback, records, packet build | 131.0 ms | 106.6 ms | **-24.4 ms** |
| Framebuffer clear | 17.6 ms | 17.2 ms | -0.4 ms |
| **Total** | **456.6 ms** | **434.0 ms** | **-22.6 ms** |

The packing accounts for roughly 10 ms of that (5 x 752 words at the wire
calibration); the rest is DSP compute hidden behind the clear and the
per-chunk unpack.  The clear stage still reports its own ~17 ms of host
time — the saving appears as vanished *waiting* inside the readback stage.

### 4.2 DSP memory layout and the Falcon P/X/Y overlay

The DSP X-memory layout ends at `X:$3CEB`: the base-vertex array, the
camera/projected overlay, the resident packed UV pairs, and 448 output words
for a 32-triangle chunk. The input buffer that used to follow the vertex
arrays is gone with the per-frame index upload. The frontend reserves 15,872
X words (`X:$0000-$3DFF`), leaving 276 reserved words after the current last
allocation. The latest run reports 16,040 free X words and 16,127 free Y
words from the Falcon DSP system before these explicit reservations.

Neither the 8,172-word face-normal array nor the 5,448-word packed index list
fits beside those three vertex arrays, so both live in Y memory — and their
placement is constrained by a hardware detail that is easy to miss. The Falcon
wires one 32K-word external SRAM into all three DSP address spaces. Only the
low addresses are on-chip:

| Space | On-chip | External mapping |
|---|---|---|
| P | `$0000-$01FF` | `$0200-$7FFF` -> external word `address` |
| X | `$0000-$00FF` | `$0100-$3FFF` -> external word `address + $4000` |
| Y | `$0000-$00FF` | `$0100-$3FFF` -> external word `address` |

So `Y:$0200` upwards is physically the same memory as `P:$0200` upwards, which
is where a DSP program larger than 512 words keeps its own code. Placing the
normal array at the bottom of Y overwrote the program: the DSP executed
`normal[151].z` as an instruction at `P:$0202` and faulted immediately.

Both arrays therefore start above the program. The tracked LOD's first free P
address is currently `P:$075B`:

| Array | Range | Words |
|---|---|---:|
| `triangle_indices` | `Y:$09C0-$1F07` | 5,448 |
| `face_normals` | `Y:$1F08-$3EF3` | 8,172 |

`Y:$09C0` leaves 613 external words (`$075B-$09BF`) free above the current
program for code growth. The frontend reserves 16,120 Y words through
`Y:$3EF7`, so only four reserved words remain above `face_normals`. X memory
is unaffected by the P/Y overlay: its external portion maps to
`P:$4000-$7FFF`, which no realistic program size reaches.

The two arrays use 13,620 words. That is why the index list is packed at two
words per triangle: the unpacked three-word form would need 8,172 and does not
fit in the remaining P/Y window.

Anything that grows the DSP program past `P:$09BF` silently corrupts the first
triangle indices instead of failing to assemble. Check the first free P
address in the LOD after adding DSP code:

```bash
awk '/^_DATA P 0040/{f=1;next} /^_DATA/{f=0} f{n+=NF} END{printf "first free P address: $%X\n", 0x40+n}' TREX/dsp/trex_dsp.lod
```

The complete animation-pose/transform/projection stage is 2.5% of the current
frame. It is already DSP-side except for XYZ16 expansion and programmed-I/O
transport, so moving more vertex arithmetic cannot materially improve the
result. The dominant remaining work is the M68030 framebuffer path.

### 4.3 Extracted PS1 morph animation and choreography — active

The original Demo One animation has now been extracted by
[`TREX/disassembly/extract_trex_animation.py`](TREX/disassembly/extract_trex_animation.py)
into [`TREX/model/trex_animation.bin`](TREX/model/trex_animation.bin), with a
machine-readable audit trail in
[`TREX/model/trex_animation.json`](TREX/model/trex_animation.json). Extraction
facts, distinct from the Hatari timing measurements below:

- the PS1 data contains nine Q12-weighted morph targets and 6,993 delta
  vertices (56,056 bytes in the original padded block),
- its automatic sequence renders 274 weight frames (counter 0 through
  `0x111` inclusive),
- autoplay uses targets 0, 1, 2, 3, 5, 6, 7 and 8; target 4 is inactive,
- exact target-0..3 evaluation deduplicates to 46 complete gait-delta poses,
  each `1,376 * 3 * 2 = 8,256` bytes,
- targets 5, 6, 7 and 8 remain sparse (147, 557, 12 and 557 vertices), and
- TANM v2 is 444,416 bytes, including full weights, 274 64-byte choreography
  records and all gait poses.

The Falcon consumes this file directly. The M68030 selects the 64-byte record,
converts its Q12 matrix to Q1.23, folds the fixed PS1 viewpoint `(0,0,2000)`
into the translation, and transports native host-port words. It performs no
per-vertex morph multiplication or matrix arithmetic. The DSP first expands
base+gait into the existing camera array, applies every non-zero sparse target
with the original signed Q12 weight, then transforms and projects that array
in place. Target 0-3 products are exact offline extraction work, not M68030
runtime work.

The active protocol sends 4,159 input words for a frame with no sparse target:
21 BEGIN words, three gait chunks totalling 4,137 words, and one FINISH word.
Across all 274 records the measured-from-data transport model is 4,933.4 input
words per frame on average; the maximum is 7,557 words at frame 184. This is
an exact count from the generated choreography, not a timed throughput claim.
Target 7 is active in 121 frames, target 5 in 66, target 6 in 58, and target 8
in 48. Each sub-transaction is acknowledged and bounded at 512 vertices.

The M68030 transfer buffer is deliberately overallocated by 65,535 bytes and
the active window is aligned to a 64-KiB boundary. This is a defensive response
to the TOS 4.02 `Dsp_BlkUnpacked` source-walk failure observed when a long
animation transaction crossed that boundary in Hatari; the smaller raw-XYZ
chunks also keep the DSP receiver responsive. This behavior is not yet
confirmed on physical Falcon hardware.

The linked TOS image currently reports 7,710 text bytes, 1,139,170 data bytes
and 1,187,360 BSS bytes: 2,334,240 bytes of program image plus BSS before TOS
runtime overhead. The complete player boots and runs in Hatari's 4 MB Falcon
configuration. This is an emulator validation of the memory budget, not a
physical-machine measurement.

The choreography is exact through frame 273: matrices, translation, morph
weights, gait pose, active mask, audio-volume state and the automatic-to-
interactive flag are preserved. The current Falcon player deliberately loops
273 back to 0; it does not yet implement the original interactive controller
entered after autoplay. Audio volume is retained as state but no sample/audio
backend consumes it yet.

### 4.4 Shading: the source light model, per corner — implemented (Gouraud default)

The Falcon path dots a surface normal against the three lights Demo One's own
setup routine installs, each clamped separately so a face turned away from one
light gets nothing from it instead of darkening the others. Two sums come out
of that, one over the red-scaled and one over the green-scaled vectors (green
equals blue for every light and for the ambient in this scene), and they carry
both pieces the renderer needs:

- the **brightness level**, from the luminance of the direct term alone, so the
  ambient floor does not eat the bottom of the sixteen-step range, and
- the **tint class**, from the R/G ratio of the face's own light colour, as
  three threshold comparisons rather than a division: R is halved and the
  thresholds are stored halved, which keeps both operands inside 1.23.

Which normal this runs against, and how many times, is what has since changed.
`gouraud_enabled` defaults to 1 (`TREX/m68030/trex_m68030.s`), and in that
configuration the DSP runs the pass above once per TRIANGLE CORNER, against
that corner's own PS1 vertex normal (`shade_corner_loop` inside
`make_triangle_shade`, `TREX/dsp/trex_dsp.asm`) — not once per face against a
single shared normal. Section 4.4a is the memory and protocol split that put a
corner's own normal within reach at all; this section remains the light model
and CLUT-bank derivation both the corner pass and its pre-Gouraud predecessor
share. Each corner's two clamped channel sums contribute exactly one third to
a running total (`shade_acc_r`/`shade_acc_g`); that mean, quantized through the
same brightness formula above, is the record's single tint-class-and-mean-level
word (`triangle_shade`) — thirds keep every intermediate below the saturation
limit the next paragraph describes, and they make the accumulator the corner
mean without a separate division afterward. Tint class is derived from that
same corner-mean sum, exactly as it was for a single face normal: colour class
is not interpolated across a triangle, only brightness is. Each corner's OWN
quantized level survives too, in `corner_levels`, for the span interpolation
section 4.4a describes.

Each channel sum has to saturate before it is stored, and that is not a
formality: the vectors are normalised on luminance, the key light is redder
than its own luminance, and a face pointing straight at it reaches 1.09 in red.
Keeping only the accumulator's high longword drops the extension byte and wraps
that to -0.91, which puts the brightest faces in the darkest bank -- a shadow
exactly where the light is strongest, on the flat patches of the snout and brow.
Saturating is also what the PS1 does, which clamps every colour channel to 255.
The bug cost 988 pixels of the frame-100 image, every one of them too dark.

The record carries `tint<<4 | level` in a six-bit field, and the host holds
`SHADE_TINTS * SHADE_LEVELS` = 64 preshaded CLUT banks per texture page instead
of 16. The pixel loop is untouched — it looks up one longword in a bank, and
which bank that is now encodes colour as well as brightness. Measured at equal
frame counts the whole change is free: 482.8 ms before, 482.5 ms after. It is
paid for in RAM, where the preshaded CLUTs grow from 98 KB to 393 KB and the
program from 2.34 MB to 2.64 MB.

The bank table is a fit, not a hand-tuned ramp. For every (tint, level) cell it
holds the median actual colour of the faces that land there under the source
light model, taken over every eighth choreography frame; the class boundaries
are the quartiles of the R/G distribution over the same population (1.378,
1.529, 1.649). Level 0 of each class sits near the PS1 ambient
(0.333, 0.200, 0.200) — warm and clearly red, which is what an unlit face is
left with — and red saturates towards the top of each class, so highlights come
out near neutral exactly as the PS1's per-channel clamp makes them.

One deliberate deviation: the fitted table renders warmer than the source model
implies, because the faces covering the most pixels are the ones facing the
camera, and the camera-facing light is the pink key. Feeding the medians
straight through measures R/G 2.20 in the image against 1.85 for a single
average ramp. The banks are therefore calibrated by a constant factor on the
green and blue channels so the image mean lands at 1.82, which keeps the
per-face variation — white-lit faces come out genuinely neutral, at a 10%
quantile of 1.39 against the single ramp's 1.50 — while matching the overall
warmth that was chosen by eye. Anyone reproducing the source exactly should
drop that factor.

Per-corner Gouraud shading — the light model above, evaluated at each corner
and interpolated down the two edge chains as the span rasterizer walks them —
is what ships by default. It is not the source's per-pixel Gouraud: what is
interpolated is a scalar brightness LEVEL that selects among the CLUT banks
above, once per span ROW, not a continuously-varying RGB colour sampled every
pixel — smooth down the model, flat across any one scanline. Section 4.4a has
the split that made per-corner lighting possible and the two places the
shipped protocol departs from the plan it followed; section 4.4b has what the
remaining, source-exact per-pixel tier would cost. The single-normal-per-face
path above remains selectable for direct comparison and regression
(`gouraud_enabled=0`, 520.4 ms / 1.92 FPS on the same binary — section 2).

The raw TMD and setup routine `0x80127764` establish a different source
contract:

- all 2,724 triangles carry three normal indices; 3,609 of the 3,610 Q12
  normals are referenced,
- 2,588 mode-`0x34` triangles are textured Gouraud and 136 mode-`0x30`
  triangles are untextured Gouraud,
- the untextured base colours are `(255,230,110)` for 120 primitives and
  `(35,30,0)` for 16 — the current diagnostic flat colours are not source
  colours,
- three lights use directions/colours `(20,-100,-100)/(255,144,144)`,
  `(20,-50,128)/(128,128,128)`, and `(-20,100,20)/(128,128,128)`, and
- ambient RGB is Q12 `(0x555,0x333,0x333)`.

These are extraction facts validated into `trex_animation.json`. The lights,
their intensities, the ambient and the untextured base colours are all in the
renderer now. The colours needed a detour: the O3D gives every polygon the same
material word `0x0020`, so it cannot separate the two groups, and the two files
order the same 2,724 triangles differently. `tools/o3d2facecolors.js` therefore
matches them on the vertex-index set and writes one Falcon RGB555X word per
polygon in O3D order, which the packet builder puts where the material used to
sit. The eyes are the PS1's own yellow and near-black again instead of a
diagnostic green that, on a head twenty pixels tall, was the most conspicuous
thing in the frame.

What is still missing is per-corner COLOUR, not per-corner brightness: exact
rendering needs three corner RGB values, interpolated and multiplied against
the texel every pixel, while the wire record carries one flat tint class plus
an interpolated brightness level. Section 4.4b has the cost of closing that
gap and why it remains unbuilt.

Keeping all exact source data resident did not fit the P/Y layout on its own:
the 3,610 normals alone need 10,830 DSP words, and packing the six vertex/
normal indices of each triangle into three words gives another 8,172, against
13,888 words in the complete `$09C0-$3FFF` window. Section 4.4a is the split
that resolved this, and it shipped — it is what makes the per-corner pass
above possible at all. Per-pixel RGB modulation, the source-exact tier this
section's own extraction facts describe below, remains a separate and larger
question, because it adds work to the pixel loop rather than the DSP; section
4.4b has that cost model.

### 4.4a The per-corner memory and protocol split — implemented

This section used to be a design proposal for keeping the PS1 Q12 corner
normals and the three-light calculation on the DSP rather than moving
lighting arithmetic back to the M68030. The split below is now the shipped
layout, verified against `TREX/dsp/trex_dsp.asm` and
`TREX/m68030/trex_m68030.s`. Three of its four points shipped as proposed;
two concrete departures from the plan are called out where they occur.

1. Each triangle's three vertex indices and three corner-normal indices pack
   into exactly three 24-bit Y words (`TRI_INDEX_BITS`/`TRI_INDEX_MASK`: word
   A = v0|v1<<12, word B = v2|n0<<12, word C = n1|n2<<12) — 8,172 words for
   all 2,724 triangles, uploaded once by `CMD_LOAD_TRIANGLES`. **Done as
   proposed.**
2. The complete 3,610-entry PS1 corner-normal table is resident, split on a
   normal index rather than a triangle boundary: `corner_normals_y` holds the
   first `NORMAL_Y_COUNT` = 1,905 normals (5,715 words, `Y:$29AC-$3FFE`)
   directly behind the now-resident `triangle_indices` (`Y:$09C0-$29AB`,
   8,172 words) — 13,887 of the Y window's 13,888 words — and
   `corner_normals_x` holds the remaining `NORMAL_X_COUNT` = 1,705 (5,115
   words, `X:$25E4-$39DE`) in the X allocation the resident UV pairs used to
   occupy. **Done as proposed**, address for address: 8,172 + 5,715 = 13,887,
   and 5,115 fits the displaced X allocation exactly. This layout does not
   depend on which mesh LOD is linked in — the corner-normal table's size
   comes from the source TMD, not from how many triangles the decimated mesh
   keeps; `triangle_indices` is sized for the full 2,724-triangle mesh and a
   smaller LOD simply leaves its tail unused (`TREX/dsp/trex_dsp.asm`, the
   occlusion-prepass allocation comment).
3. Cull and sort still happen on the DSP first, exactly as proposed. **First
   departure from the plan:** UV was proposed as a survivors-only stream —
   "stream the two packed static UV words only for survivors, after their
   identities are known." What shipped instead sends UV for the WHOLE chunk:
   `CMD_BUILD_TRIANGLES` receives the chunk's UV pairs, two packed words per
   triangle, immediately after its (count, base) header — before
   `make_triangle_area`'s backface/zero-area cull has run on a single one of
   them. At the measured 27% survival rate (section 4.1a), roughly three
   quarters of that UV traffic is for triangles the DSP is about to discard.
   Section 2 folds this into the "~32 ms" corner-lighting protocol cost as
   "chunk UV shipping" rather than accounting for the waste separately, so it
   is real but not separately measured.
4. The DSP reproduces the three source lights plus ambient once per corner
   (`shade_corner_loop` inside `make_triangle_shade`), as proposed. **Second
   departure from the plan:** it does not calculate RGB edge/span gradients.
   It quantizes each corner's own brightness level — the same 0..15 Lambert
   quantization the flat path always used — into `corner_levels`, and
   `make_triangle_span` derives the wire record's `dlvl_dx`/`dlvl_up`/
   `dlvl_low` from those three levels with the identical barycentric formula
   already used for the UV gradients (`span_dldx`, `span_dll_up`,
   `span_dll_low`). The wire carries a scalar brightness per corner, not a
   colour — the cheaper "interpolated bank index" tier section 4.4b costed
   as an alternative to true RGB, not the RGB-gradient design this point
   originally proposed.

One field is worth flagging precisely because it looks unfinished, and is:
`dlvl_dx` (w15 on the wire) is computed by `make_triangle_span` and travels on
every record, but `rasterize_packet` never reads it back — the row loop only
consumes `raster_dlvl` (whichever of `dlvl_up`/`dlvl_low` matches the active
half), added once per ROW, not once per pixel. That matches `gouraud_enabled`'s
own comment exactly: "smooth along Y, flat along each span." The DSP cycles
and the host-port word spent computing and shipping `dlvl_dx` are real and
currently unconsumed; the first thing that would read it is the per-pixel
(rather than per-row) interpolation section 4.4b costs and has not built.

The host remains responsible for unpacking, Ordering Table linkage and
framebuffer writes, as proposed; its lighting-side work is still limited to
gathering and transporting UV records, now for the whole chunk rather than
survivors only (point 3 above).

The output format for true per-corner COLOUR is the question this section
originally called "the harder performance question," and it is untouched by
any of the above, because none of it was built: a straightforward record
would still need roughly twelve additional words for top RGB plus three
channels of horizontal/upper/lower gradients — not the four words (one packed
level pair, three level gradients) the shipped scalar variant actually
spends. At 1,065 survivors that alone models to about 29.4 ms of additional
host-port traffic; packing those signed fixed-point fields two per word could
approximately halve the estimate, subject to a range proof and field-by-field
validation. True textured Gouraud modulation also adds per-pixel work to the
rasterizer — section 4.4b has the current cost model — so DSP lighting could
raise DSP utilization while still lowering overall frame rate. Cross-frame
pipelining or SSI result DMA should therefore be evaluated together with any
such record revision, not after it. This part of the section remains a
design proposal/cost model, not an implemented or measured path.

Before calling per-corner brightness PS1-exact, a PS1/GTE validation fixture
must still reproduce the source's operation order, saturation and
texture-colour modulation for selected primitives and choreography frames.
Unlike the span-setup record (section 4.1b), this lighting path has not been
field-validated against reference arithmetic — it shipped on visual review,
not a proven bit-exact match. A cheaper alternative for a future true-colour
pass is one packed 8-bit XYZ normal per source normal; it would fit
comfortably and avoid the UV displacement above, but is explicitly an
approximation and must be compared visually before consideration.

### 4.4b What full per-pixel RGB Gouraud would still cost, and why it remains deferred

Section 4.4a's span-level brightness interpolation is done and shipped; this
section is now only about the tier beyond it — continuous per-pixel RGB
colour, modulated against the texel, rather than an interpolated brightness
level that selects a preshaded bank. Section 3.5 is what made a cost model
possible at all: the pixel loop then measured 372.8 ms for 77,853 written
pixels per frame — **4.79 us per pixel, about 77 cycles at 16 MHz** — at the
742.7 ms epoch, before section 6.6's render-target resize and before any pass
of section 3.9's instruction-cache series. That is the baseline the table
below was charged against, so its absolute ms/FPS columns are historical, not
current; the relative shape — which fidelity tier costs how much more than
the next — is the part still worth reading.

**DSP side: effectively free.** Three corner normals instead of one face normal
is roughly 74 more instructions per triangle, about 4.6 us at 32 MHz, so
**~5 ms per frame** for 1,078 survivors. Against the ~15% DSP duty cycle of
section 2.2 that hides inside the host's own work. It does depend on the memory
plan above: the 3,610 Q12 normals need 10,830 DSP words and do not fit without
the repacking 4.4a describes.

**Wire: noticeable, containable.** At the documented 2.3 us per host-port word,
twelve extra words per survivor — start colour plus three channels of three
gradients — is **~30 ms per frame**, roughly half that if the fields are packed
two per word. Interpolating a single scalar instead needs four words, about
**10 ms**.

Both estimates above bracket what shipped rather than describing it exactly:
section 4.4a's scalar variant spends the ~5 ms DSP-side estimate on real
per-corner rotations and the four-word wire estimate on real `dlvl_*` fields,
and section 2's measured **~32 ms** corner-lighting protocol cost (rotations,
light sums, chunk UV shipping, four level divisions and the 18-word record
together) is consistent with those two component estimates plus the
whole-chunk UV shipping section 4.4a's first departure adds on top. The
twelve-word/~30 ms figures remain estimates for the true-RGB tier below,
which is still unbuilt.

**Pixel loop: this is where it is decided.**

| Variant | Per pixel | Pixel loop | Frame | FPS |
|---|---:|---:|---:|---:|
| Per-face, today | 4.79 us | 372.8 ms | 742.7 ms | 1.35 |
| Interpolated bank index | ~6.3 us | ~490 ms | ~865 ms | ~1.16 |
| RGB via modulation table | ~7.9 us | ~615 ms | ~990 ms | ~1.05 |
| RGB via MULU.W per channel | ~12.8 us | ~995 ms | ~1,350 ms | ~0.74 |

True RGB Gouraud needs three interpolation adds and three multiplies per pixel
to modulate the texel; `MULU.W` alone is 28 cycles on the 68030, so the loop
roughly triples and the frame rate halves. Interpolating the *bank index*
instead costs one add and one address calculation, because the preshaded banks
already carry brightness and colour class together — about 15% of the frame
rate for shading that is smooth across a triangle rather than flat, in this
table's model.

**The interpolated-bank-index row is no longer a model.** Section 4.4a shipped
it — `gouraud_enabled` defaults to 1 — and it cost far less than modeled here.
Measured against the pre-Gouraud build at its own epoch (section 2): the
interpolation itself is **+8.1 ms per frame**, not the ~117 ms
(490 - 372.8 ms) this row's pixel-loop estimate implied, and the flat path
stays selectable at 520.4 ms / 1.92 FPS on the same binary for direct
comparison. The gap is the row-versus-pixel granularity section 4.4a
describes: this table assumed a per-PIXEL bank recalculation — one add, one
address calculation, on every pixel — while the shipped rasterizer reselects
the bank once per span ROW from the interpolated left-chain level, and the
pixel loops are otherwise untouched (roadmap item 13). Almost none of the
modeled per-pixel cost was ever paid, because the design that shipped never
pays it per pixel at all. The two RGB rows above are the ones that still
require genuine per-pixel work, and they remain the only rows this table
still usefully estimates.

**Deferred, deliberately — though the sequencing this paragraph originally
waited on has since completed.** Mesh LOD (section 10, item 10) and the
pixel-loop optimization series (section 10, item 11 — sections 3.6 through
3.9c) were both still open when this section was first written; both are done
now, and the span-level Gouraud this section also deferred behind them
(roadmap item 13) has since shipped, in the order originally proposed. What
remains deferred is specifically the true-RGB tier. The reason is the same in
kind, though its baseline is not: it is real per-pixel work added to a loop
that the instruction-cache series (section 3.9) has since cut by more than
half on the LOD (376.8 to 180.7 ms rasterizer), so this table's absolute costs
would have to be re-derived against the current pixel loop, not assumed from
the 372.8 ms / 4.79 us figures above, before another modeling pass is worth
running. Building one binary that computes the interpolation and discards it,
exactly as this section originally suggested, remains the way to settle it —
measured, not modeled, against whichever pixel loop is current when it is
tried.

Everything in the table above except the 4.79 us is a model, not a
measurement, and the 4.79 us / 372.8 ms baseline it is charged against is
itself superseded by every rasterizer change since section 3.6. Read the
table as a cost shape, not a current forecast.

## 5. Recommended DSP offloads

### Priority 1: Triangle culling and clipping

The DSP should perform, per triangle:

- signed screen-space area,
- zero-area rejection,
- optional back-face rejection,
- near-plane rejection,
- bounding-box construction,
- framebuffer clipping, and
- a compact survivor flag/result.

This avoids creating and linking packets for triangles that cannot affect the
frame. It also reduces the number of triangles reaching the M68030 setup path.

This priority is active. The frontend calls `CMD_BUILD_TRIANGLES` and
`CMD_GET_TRIANGLES` in 32-triangle chunks; the M68030 still owns packet
construction, OT linking and rasterization. The exact state of each predicate
— this table is the authority if any prose elsewhere disagrees:

| Operation | Implemented | Enabled | Hardware-tested |
|---|---|---|---|
| Zero-area rejection | yes — sign of `area2 = dx01*dy02 - dy01*dx02` | yes | no |
| Back-face rejection | yes — `area2 >= 0` culls; negative is front-facing after the PS1 fixed-view handedness flip | yes | no |
| Near-plane rejection | any-vertex-behind rejects the whole triangle (see caveat) | yes | no |
| Near-plane **clipping** of mixed triangles | no | — | no |
| Fully off-screen rejection | yes — clipped bounding box comes out empty | yes | no |
| Partial screen clipping | via the clipped box; the rasterizer never visits off-screen pixels | yes | no |
| Clipped-box return to the host | yes — two packed words per survivor (section 4.1a) | yes | no |
| Two-sided primitive rule | no — every triangle is treated as single-sided | — | no |

`make_triangle_area` uses the DSP fractional MPY/MAC accumulator and normalizes
its result to a clean `A=+1/0/-1` — the sign is the winding, and backface
culling needs it. Without normalization, the fractional low word leaked into
the host-loop control value.

The sign is not arbitrary.  All 274 extracted source rotation matrices have a
positive determinant close to `4096^3`; the host's fixed-view conversion
negates their third row and all 274 camera matrices therefore have a negative
determinant.  The original positive-area rule survived that camera integration
unchanged and rendered mostly back faces.  At frame 0, source TMD normals
classify 1,091 of 1,277 negative-area triangles as camera-facing, while 1,178
of 1,447 positive-area triangles point away.  The O3D and TMD triangle lists
contain the same 2,724 uniquely matched faces with identical cyclic order, so
asset conversion is ruled out.  `JGE triangle_culled` is the corrected rule;
the protocol test carries one negative-area survivor and one positive-area
back face so it cannot silently restore the old convention.  Post-fix Hatari
validation wrote `P` for that protocol test, and the enabled full span
validator compared 9,003 survivor records with zero field mismatches.  These
are emulator results, not physical-Falcon measurements.

**Near-plane caveat — rejection is not clipping.** The current predicate drops
a triangle as soon as *any* vertex is behind the near plane. The extracted
close-ups make this materially more relevant than the former fixed camera;
mixed triangles can disappear instead of being clipped at the plane. Correct
near clipping emits zero, one or **two**
output triangles per input, so the survivors-only record stream must then
allow generated records that have no 1:1 source triangle — a protocol-shape
constraint to keep in mind for every future record revision, including the
full setup record of section 9.2.

### Priority 2: Complete triangle setup and gradients

This priority is active. The DSP generates the complete seventeen-field
semantic DDA setup plus survivor/shade and average-Z keys, packed into fourteen
wire words. The M68030 reconstructs the two UV starts from resident texture
metadata, links the Ordering Table and walks the spans; it performs no normal-
path sorting, area, slope or gradient division. The validated field contract
is in section 9.2 and transfers in pipelined 32-triangle chunks.

### Priority 3: Normal transformation and lighting

This priority is now active for per-face flat shading. The DSP performs, per
surviving triangle:

- rotation of the object-space face normal into camera space with the frame
  matrix (the translation is deliberately omitted: a normal is a direction),
- a dot product against the camera-space light direction,
- clamping of the negative half to the darkest level, and
- quantization of the 1.23 cosine to a 4-bit level by keeping its top bits.

Rotating the light into object space instead would save six of the nine MACs
per triangle, but only for an orthonormal matrix. Transforming the normal is
the same expression `transform_vertices` already uses and stays correct if the
frame matrix ever carries more than a rotation, and the saving is small: the
routine is about 45 instructions and only runs for the surviving triangles.
The measured cost of everything the feature adds to that stage — DSP shading,
the extra chunk base word and the host-side unpack together — is 2.7 ms per
frame, so the nine-MAC choice cannot be costing more than that.

The normals themselves are not the mesh's vertex normals. An O3D polygon only
references the normal of its *first* vertex, and on this mesh those sit 28
degrees off the polygon plane at the median and 58 degrees at the 90th
percentile, which turns per-face shading into noise. `tools/o3d2facenormals.js`
derives the geometric normal of each polygon offline instead, using the same
winding the backface test already relies on, and emits `trex_facenormals.bin`
for the M68030 front end to embed and upload once.

Remaining work in this area:

- per-vertex normals and true Gouraud interpolation, which the O3D polygon
  record cannot currently express (it holds one normal index, not three),
- more than one light source or a specular term,
- coloured light, which the preshaded-CLUT approach supports at the cost of one
  bank set per light colour.

### Priority 3a: Why shading is free in the pixel loop

The rasterizer does not interpolate or modulate anything per pixel. The host
holds `SHADE_LEVELS` preshaded copies of each texture page's CLUT, and the
triangle setup adds `shade * 1024` to the CLUT base pointer. In the controlled
comparison of section 2.1 the rasterizer stage is identical to the tick with
lighting on and off, and the complete feature costs 0.20% of the frame, all of
it on the DSP side.

Modulating each texel instead would have put three multiplies and three shifts
into the innermost loop of the stage that is already 86% of the frame.

### Priority 4: Ordering-Table bucket calculation

The DSP can calculate the 1,024-entry bucket index and return it with each
surviving setup record. This is technically easy, but Ordering Table insertion
is only 0.1% of the measured frame time. The DSP should not spend significant
protocol bandwidth returning linked-list pointers; those pointers belong to
M68030 memory.

Bucket calculation is worth adding only if it is part of a larger compact setup
record or if it enables a streaming/sorted pipeline.

## 6. Work that should remain on the M68030

### 6.1 Pixel coverage and framebuffer writes

The DSP has no direct Videl rasterizer interface in this implementation. A DSP
pixel engine would need to send pixels or spans to the M68030, which would
replace arithmetic cost with communication cost.

### 6.2 The Z-buffer is gone: PS1-style painter's visibility

The renderer no longer has a Z-buffer. Visibility is the Ordering Table alone:
`gpu_rasterize_ot` walks the buckets far-to-near and nearer packets overwrite
farther ones, exactly the PS1 model. Within one bucket the node list is LIFO
from submission — arbitrary but stable, the same contract a real PS1 OT gives.
The 268,800-byte 32-bit depth array, its clear, the per-pixel
address/read/compare/write chain and the entire Z interpolation (three of the
nine `DIVS.L` in the triangle setup) went with it.

Correctness was verified visually and numerically: 205 of 67,200 pixels
(0.31%) differ from the Z-buffered reference frame, at near-identical
coverage — same-bucket triangles resolving by draw order.

**The bucket key has to cover the whole camera range, and silently stops
sorting when it does not.** The key is the un-divided sum of three camera-space
z values, shifted right by `OT_KEY_SHIFT` and clamped to the last bucket. The
shift was calibrated when the object stood at z≈3000. The extracted
choreography opens at z=62000, where the key runs 174,994..247,367 — every
value far above the 32,736 a shift of 5 can represent. The result was not a
visible error message but a quiet loss of the entire mechanism: from frame 0 to
about frame 125 **all** surviving triangles clamped into the last bucket, so
the mesh was drawn in fixed submission order, which for a rotating object puts
the wrong surfaces on top. It resolved by itself around frame 130, when the
object had come close enough for the keys to drop back into range — visible in
motion as the model walking through a curtain, worst on the head, where the
mesh is densest and most self-occluding.

The fix is arithmetic, not structural: `OT_KEY_SHIFT = 8` caps at 262,143,
above the sequence maximum of 250,002, and `OT_LENGTH = 2048` because 4.5%
headroom is not enough for a failure mode that degrades without a symptom. The
spread of the key within one frame is the mesh's own depth extent, not the
distance, so it stays roughly constant: 283 buckets in the opening frame and
285 in the close shots, at least 130 in the worst frame of the run. Measured
over the whole sequence afterwards: zero clamped triangles. The change alters
25% of the model's pixels at frame 24 and 46% at frame 100.

Two lessons for any later camera work. Sorting failure is invisible in
aggregate numbers — pixel counts, survivor counts and timings all stayed
plausible while the depth order was gone. And a fixed shift only ever fits one
distance range; moving the camera further out than the opening shot needs this
recalculated, or replaced by a per-frame scale derived from the choreography's
own translation.

Measured over 64 frames, the removal alone is **not** a win — it trades the
per-pixel depth work against overdraw, and loses:

| Stage | Z-buffered | Painter's, same loop | Painter's + register pass |
|---|---:|---:|---:|
| Framebuffer (+Z) clear | 51.6 ms | 17.2 ms | 17.8 ms |
| Rasterizer | 1,228.0 ms | 1,406.5 ms | 1,147.3 ms |
| **Total** | **1,415.2 ms** | **1,559.9 ms** | **1,300.3 ms** |

Pixel writes rose from 17,072 to 25,628 per frame (overdraw factor 1.50), and
every one of the ~8.5k pixels the depth test used to reject early now runs the
full texture/CLUT path. What turned the change into a net -114.9 ms is the
register allocation the removal enabled: A3, previously the depth pointer, now
carries the texture and CLUT accesses, so A4 walks the framebuffer row as a
pointer (+2 per candidate) instead of being recomputed from
`raster_fb_row + 2*x` twice per textured pixel, and DBRA replaces the x
counter's read-modify-write, load, compare and branch. The lesson generalizes:
dropping the Z-buffer only pays together with pixel-loop work that exploits
the freed resources — budget them as one step, not two.

Semitransparency is a correctness beneficiary: the destination-reading 50/50
blend now executes in back-to-front order, which is what PS1 blending
requires. No packet sets the blend bit yet, so this is latent.

### 6.5 Present: page flip, not a copy

The renderer owns two 256x224 screen buffers and draws straight into the one
that is not on display, as a 240x224 window at the same offset the copy used
to write to. Ending a frame is three register writes — `$ffff8201`,
`$ffff8203`, `$ffff820d` — plus swapping the two pointers.

No vsync is taken. Videl latches the base at the start of the display period,
so a write mid-frame simply takes effect at the next VBL, and at well under
2 FPS waiting for it would idle away more than the copy this replaces ever
cost. The buffer just released stays untouched for a whole DSP frame
transaction afterwards, which is longer than a VBL period.

Both buffers are wiped once when the screen is taken over, before Videl is
pointed at either. The renderer only ever writes its 240x224 window, so
whatever the buffers held would stay visible as a frame around the render
target — with the buffers still in the desktop's hands that was a white
stripe, 16,000 pixels of it in a Hatari screenshot. The wipe is one linear
clear of both buffers at open, which is why the per-frame clear does not have
to touch the border.

`FRAMEBUFFER_STRIDE` is now the screen's 512 bytes rather than the render
target's own 480, and the dedicated 134,400-byte framebuffer is gone; every
consumer reads `render_base` instead. The debug dump reads
`last_rendered_base`, which is latched before the swap — without that it would
capture the next frame's target, which is exactly the bug the first version
had, and the byte-comparison against the pre-flip build is what caught it.

Measured over the 0-263 prefix: 820.2 to 784.9 ms, the whole 30.3 ms of the
present stage, with a byte-identical image and unchanged pixel and packet
counts. A Hatari screenshot confirms Videl really shows the flipped buffer,
which the framebuffer dump alone cannot prove.

### 6.6 The Videl mode is ours, not TOS's

`gpu_open` no longer asks the XBIOS for a mode. TOS offers exactly two 16-bit
modes and neither is 224 lines tall: `$0024` (320x200 RGB/TV) scanned only 200
of the 224 rendered lines, so a quarter of the render target never reached a
TV, and `$0114` (320x240 VGA) needed a drawing offset to centre in. The mode
is now built from the Videl registers directly:

| Register | RGB/TV | VGA | Meaning |
|---|---|---|---|
| `$ffff8282` | `$00c70076` | `$00fc00a9` | HHT \| HBB |
| `$ffff8286` | `$003f001e` | `$002502f3` | HBE \| HDB |
| `$ffff828a` | `$007600ab` | `$00a800c0` | HDE \| HSS |
| `$ffff82a2` | `$0271021f` | `$041903cf` | VFT \| VBB |
| `$ffff82a6` | `$005f005f` | `$004d004b` | VBE \| VDB |
| `$ffff82aa` | `$021f026b` | `$03cb0415` | VDE \| VSS |
| `$ffff820a` | `$02` | `$02` | 50 Hz |
| `$ffff82c0` | `$0185` | `$0182` | clock, bus width, monitor |
| `$ffff82c2` | `$0000` | `$0005` | cycles/pixel, line doubling |
| `$ffff8266` | `$0100` | `$0100` | true colour on |
| `$ffff8210` | `$0100` | `$0100` | 256 visible words per line |
| `$ffff820e` | `$0000` | `$0000` | no margin words |

Both sets come from F030Arcade's snowbros port
(`games/snowbros/src/atari.s`), where they present a 256x224 arcade
framebuffer 1:1; they were generated by Screenspain (Chris/AURA &
Scandion/Mugwumps) against a real Falcon. The RGB set is carried over verbatim
rather than re-derived, including its documented advantage over a hand-derived
32 MHz timing that showed on hardware — not in Hatari — as two mirrored
~64-pixel columns at the right edge. RGB/TV runs 4 cycles per pixel, which is
what makes 256 pixels cover the width 320 did; VGA runs 2 cycles per pixel
with doubled scanlines, because 4 cycles there halved the sync to
~15.8 kHz/30 Hz.

Vertical timings count half-lines, so `(VDE-VDB)/2 = 224` on both. The
horizontal arithmetic is `HDB = HBE - 33` (true colour, 4 cycles/pixel:
`(64+16*4)/4+1`) and `HDE = HBB` (the true-colour HDE offset is 0); the
reference is MiKRO's "Videl in practice".

What this buys beyond the resolution: TOS is never told about any of it, so
its own idea of the video mode still matches what the registers held on entry.
`video_save_registers` snapshots them at open and `gpu_close` writes them back,
and the desktop returns exactly as it was. Until now it returned at the demo's
resolution and that was documented as unavoidable — TOS 4.02's `VsetScreen`
reports no previous mode and `Vsetmode #-1` double bus errors — which is true
of the XBIOS, not of the hardware. `Physbase` no longer verifies anything
either, since nothing goes through TOS to be verified; the base registers are
written by the same `video_set_base` the page flip uses.

The VGA path is also no longer half-built. It used to branch past the buffer
wipe and past the `render_base` computation, leaving the renderer writing to
address 0 on a VGA machine — invisible in every run here, because Hatari is
driven with `--monitor rgb`. Both monitor types now share the whole setup and
differ only in the timing table above.

Neither half of this is provable from a framebuffer dump, so both were checked
against Hatari's own screen output. Hatari is started with
`--control-socket <path>`, which makes it connect to a listening UNIX socket;
`hatari-debug screenshot <file>` on that socket dumps the emulated display at
any point, and `hatari-event keypress 32` is what gets the demo past its
`Cconis` loop into `gpu_close` in a headless run. The demo's own screenshot is
512x468 — 256x224 at Hatari's 2x zoom, plus the status bar — and the desktop
after the exit comes back at exactly the 648x602 of a reference boot that
never ran the demo. Note that Hatari renders one buffer pixel as one host
pixel: it does not model the wide pixels, so its screenshots and `fb.res` are
both squeezed by 0.8 against a real Falcon.

### 6.7 Texture and CLUT reads

The six native T-Rex texture pages are much larger than the DSP local memory
when considered together. The DSP would also need a low-latency texture lookup
path. The current M68030-side TIM/CLUT reads are therefore the practical choice.

The texture-upload path now converts all six 256-entry CLUTs once into Falcon
RGB555X format. The indexed 8-bit pixel data remains unchanged. Each prepared
entry is one longword: the low 16 bits contain the Falcon color, bit 16 keeps
the original PS1 STP flag, and bit 17 marks a non-zero/valid PS1 palette word.
The rasterizer therefore performs one longword CLUT lookup and no longer
repeats the PS1-to-Falcon channel conversion for every covered texel.

Each page is now held at 64 colour-class/brightness banks, laid out as
`[page][bank][palette index]`.  Two host-owned prepared tables coexist because
they have different safety contracts:

| Table | Size |
|---|---:|
| Flag-bearing long CLUT: 6 * 64 * 256 * 4 | **393,216 bytes (384 KiB)** |
| Qualified-opaque RGB555X word CLUT: 6 * 64 * 256 * 2 | **196,608 bytes (192 KiB)** |
| Both prepared tables | **589,824 bytes (576 KiB)** |
| Indexed pixel data expanded to 16-bit texels (not done) | 786,432 bytes |

The M68030 texture-upload path owns and writes both tables once; raster packets
only borrow read-only bank pointers.  The 384-KiB table retains colour, STP
bit 16 and validity bit 17 for potentially transparent and semitransparent
packets.  The 192-KiB table contains the exact low RGB555X word only and is
selected exclusively through the source-triangle proof in section 3.8.
Neither table is DSP-visible or part of the wire format.  Both are anchored
after the pinned hot buffers so their addition cannot silently move the
framebuffer, packet buffer or raster state.

Prepared CLUTs are still far cheaper than expanding all six texture pages per
bank.  Bank `SHADE_MAX` is the unscaled conversion, and darker/tinted banks
are derived from it at upload time rather than by re-running the PS1 channel
arithmetic per sample.

Only the colour is scaled. STP and the validity flag describe the texel itself,
not how brightly it is lit, so they are copied unchanged into every bank.

`shade_ramp_table` holds the brightness of each level as a numerator over 16.
It is a linear ramp from a 7/16 ambient floor to full brightness, and it is the
one place to retune the look. Measured against the unshaded render of the same
22.5-degree frame, as a median pixel brightness and a count of texels crushed
to black out of 23,992: a 6/16 floor gives 0.47 and 127, the current 7/16 ramp
gives 0.50 and 118, and 8/16 gives 0.56 and 94 but visibly flattens the
modelling.

The ~6% RGB-conversion row in the rasterizer cost model is consequently a
legacy-path estimate. The latest run measures the complete rasterizer only, so
it does not isolate exactly how many of the saved cycles came from that one
operation.

### 6.8 Semitransparency

The current 50/50 blend reads the existing destination pixel. It is inherently
local to the M68030 framebuffer unless a DSP-visible framebuffer or an external
rasterizer is introduced.

### 6.9 Framebuffer clearing

The clear stage is 17.5 ms, 2.5% of the current frame, since the Z-buffer's exit
removed two thirds of its traffic. The DSP cannot directly clear the M68030
framebuffer in the present setup. A M68030 longword clear already runs; a
Falcon blitter strategy or lazy per-tile clearing would be the next options,
but at 2.1% this is far down the priority list.

## 7. Falcon SSI and crossbar findings

The important hardware detail is that Falcon audio/DSP hardware contains a
programmable connection matrix, commonly called the crossbar. The crossbar is
controlled by the Falcon DMA/sound registers and routes serial/DSP and DMA
streams between several sources and destinations.

The official 1992 Falcon030 Hardware Reference Guide describes these source
classes:

- external input,
- DSP transmit,
- DMA playback, and
- ADC input.

The destination classes include:

- DAC,
- external output,
- DSP receive, and
- DMA record.

This means that a DSP transmit stream can be routed to DMA-record and written
into a system-RAM sound buffer. Conversely, DMA playback can feed DSP receive,
and the guide explicitly says playback and record can operate in parallel. The
crossbar is therefore more capable than a simple external SSI connector.

### 7.1 Important Falcon registers

| Register | Function |
|---|---|
| `$FF8930` | Crossbar source controller |
| `$FF8932` | Crossbar destination controller |
| `$FF8934` | External clock divider |
| `$FF8935` | Internal clock/sample divider |
| `$FF8936` | Record-track selection |
| `$FF8937` | Codec input selection |
| `$FF8938` | ADC input selection |
| `$FF8939` | Input amplification |
| `$FF893A` | Output attenuation |
| `$FF893C` | Codec status |
| `$FFA200` | DSP host interface |

The register listing documents source and destination mux selections, clock
choices, handshake bits, and the special DSP transmit/receive paths.

### 7.2 XBIOS control model

The normal Falcon sound/DSP control model is:

1. configure source and destination with `Devconnect()`,
2. select clock and prescaler,
3. allocate/configure DMA buffers with the sound XBIOS calls,
4. call `Dsptristate()` to connect the DSP to the matrix, and
5. use buffer/frame interrupts or buffer pointers to consume the stream.

The sound DMA is audio-oriented: the Falcon exposes 16-bit stereo/track DMA
channels, while the DSP itself works with 24-bit words. A 3D setup stream would
therefore need a defined packing format and careful framing. In handshaked
mode, however, the Hardware Reference Guide says there is no sample-rate or
track interpretation: DMA input supplies a gated clock and transfers one word
at a time as quickly as the endpoints and memory bus permit.

The DSP56001 SSI itself is full duplex and supports programmable framing and
8-, 12-, 16-, and 24-bit word lengths. The Motorola manual gives a reference
SSI rate of 6.75 Mbit/s at 27 MHz oscillator/4. More specifically for this
machine, Atari documents the Falcon's internal 32 MHz clock divided by four as
an 8 Mbit/s bit clock, **1 MB/s**, and calls that the maximum DSP-SSI and
DMA-record/playback rate. This is still a specification, not a throughput
measurement under Videl and rasterizer bus load.

### 7.3 SSI versus the DSP host port

The current M68030/DSP protocol uses the DSP host interface. The Falcon host
interface supports dedicated DSP-word transfers and DMA modes, and is the
appropriate path for command/response traffic and arbitrary 24-bit control
records.

SSI/crossbar streaming becomes interesting for a continuous bulk stream:

```text
DSP56001
    |
    | DSP-XMIT / SSI
    v
Falcon crossbar
    |
    | DMA-RECORD
    v
System-RAM ring buffer
    |
    v
M68030 packet consumer/rasterizer
```

This can reduce synchronous host-port involvement and allow producer/consumer
overlap. It does not, by itself, make the DSP able to write the Videl
framebuffer or the M68030 Z-buffer directly.

DMA input has two distinct protocol levels which must not be conflated. The
Falcon's handshaked mode provides **transport flow control**: DMA input is the
clock source and gates the clock when its 32-byte FIFO cannot drain. That is
the required mode here; Atari explicitly warns that true-colour video can
starve non-handshaked sound DMA and lose data. It does not provide
**application framing**: frame id, record count, end marker and checksum are
still required so a complete buffer can be distinguished from a shifted or
partial stream.

Historical DSP software documentation also notes that the crossbar matrix
driver was not fully implemented in one Unix/Linux-era DSP software project.
This does not mean the Falcon hardware path is impossible, but it indicates
that software setup and validation are non-trivial.

### 7.3a Cho Ren Sha: block-gated, word-blind host-port PIO

The published 2016 Falcon build of Cho Ren Sha 68k provides a concrete stock-
machine precedent. Static inspection of `sz2.tos` (SHA-256
`2bad86f4524665b0eedc6e385f6583315fcfef6ab1078f90bce5f601ef527ce5`)
shows one host-flag decision at the block boundary (`BTST #3,$FFFFA202` and a
matching HF0 update through `$FFFFA200`). The inner RLE/restore dispatcher then
reads `$FFFFA204` and `$FFFFA206` directly. There is no RXDF status test in the
per-word path.

That distinction matters on a 16 MHz M68030:

- compared with `dsp_block_handshake`, every blind word avoids one peripheral
  status read plus at least one conditional branch, so the CPU instruction path
  is necessarily faster when the DSP is ready;
- it is a timing contract, not flow control. Cho Ren Sha performs framebuffer
  run copies between reads, giving the DSP time to prepare the next control
  word. A tight sequential receiver has less slack and must first prove that a
  tight DSP sender always stays ahead;
- the result is a static instruction-path fact, **not a measured Falcon
  throughput**. No microseconds-per-word figure is inferred from a working
  game binary.

This does not argue for non-handshaked SSI DMA. With SSI-to-record-DMA the
M68030 executes no per-word read loop at all; the handshake is hardware
back-pressure that gates the serial clock when the DMA FIFO cannot drain.
Disabling it saves no CPU instructions and reintroduces the documented risk of
FIFO overflow under true-colour Videl bus contention.

The safe host-port prototype for this renderer is therefore: one HF2/HF0
block rendezvous, a declared fixed word count, an unrolled blind receive loop,
and an end marker/checksum. It must be compared on a physical Falcon against
both the current RXDF-polled loop and handshaked SSI DMA. A word mismatch or
timeout rejects it; a Hatari timing alone cannot select it.

### 7.4 Concrete SSI/DMA span-stream contract -- offline prototype

[`tools/ssi_stream_model.py`](tools/ssi_stream_model.py) is an executable
16-bit protocol prototype and full-mesh cost/buffer model.  It deliberately
does **not** touch Falcon hardware yet.  The target hardware configuration is
nevertheless exact enough to implement without rediscovering ownership:

1. acquire the Falcon sound lock; snapshot the complete sound-DMA start/end/
   count, mode, operation, Crossbar `$FF8930/$FF8932`, divider/track
   `$FF8934..$FF8936`, DSP tristate and affected MFP interrupt state;
2. stop record DMA, select a one-shot 16-bit record buffer with `Setbuffer`,
   and configure DSP SSI for 16-bit transmit words;
3. in `$FF8930`, replace only DSP-XMIT bits 7..4 with **`$C`**: connected,
   32-MHz source, handshake enabled.  In `$FF8932`, replace only DMA-RECORD
   bits 3..0 with **`$2`**: source DSP-XMIT, handshake enabled.  In raw masked
   form those fields are `(old8930 & $FF0F) | $00C0` and
   `(old8932 & $FFF0) | $0002`.  The equivalent `Devconnect` setup must produce
   those read-back fields; DMA is single-shot, never looped;
4. arm DMA record only after the inactive buffer and DSP frame id agree.  DMA
   completion plus a valid footer, counts and checksum makes a buffer
   consumable; neither condition alone does;
5. on every normal exit, abort and error path, stop only the owned channel and
   restore the saved registers/state before releasing the sound lock.

The 32-MHz/4 SSI setting has an Atari-specified ceiling of 8 Mbit/s = 1 MB/s.
That is a wire limit, not achieved bandwidth.  Handshake remains enabled so
the DMA FIFO gates the clock under true-colour Videl contention.

Application framing is a sequence of big-endian 16-bit units:

| Record | Exact contents |
|---|---|
| Frame header, 8 words | magic `$5353`, version/flags, 32-bit frame id, mesh id, buffer generation, capacity in words, reserved |
| Packet header, 6 words | `$E000 | row_count`, source triangle, 32-bit OT key, shade/tint state, DSP packet flags |
| `ROW_ABS`, 3 words | `(x0 << 8) | (count-1)`, U Q8.8, V Q8.8; `x0 < 240` leaves `$Fxxx` for controls |
| `SET_SHADE`, 1 word | `$F100 | level`, emitted only when the exact Gouraud bank changes |
| `RUN16`, 7 words | `$F000 | (run_length-1)`, initial ABS row, signed `(dx,dcount)` bytes, signed 16-bit `du,dv`; exact modulo-16-bit recurrence, length 3..256 |
| Frame footer, 6 words | end magic `$5AA5`, 32-bit frame id, actual packet count, actual word count, CRC-16 over header through last row |

The decoder stops each packet after `row_count` reconstructed rows, so RLE
does not need a forward body-size field.  `RUN16` is selected only when seven
words beat the corresponding absolute rows; it can never expand geometry.
Shade control can add at most one word per row.  The tool round-trips absolute,
shade-change, signed-delta and 16-bit-wrap fixtures and rejects malformed or
trailing words.

Ownership is ping-pong, not a ring with ambiguous readers:

```text
buffer A: M68030 read-only, rasterizing frame N
buffer B: DMA-RECORD write-only, DSP producing frame N+1
boundary: stop/complete -> verify generation/frame/count/length/CRC -> swap
failure : do not swap; discard B and use the existing host-port/CPU path
```

Each buffer is **192 KiB**, 384 KiB total.  In all 274 recorded full-mesh
frames the conservative no-RLE stream fits: average ABS is 86,892 bytes,
the every-row shade-change bound is 111,770 bytes, and the largest observed
bound is 157,444 bytes.  No compression credit is taken.  The asset-level
geometric worst case is 2,724 x 224 rows: 3,693,772 ABS bytes or 4,914,124
bytes with a shade control on every row.  Therefore the DSP must reserve footer
space, stop before capacity, write an overflow footer and force the fallback;
192 KiB is an observed-corpus bound, never an unconditional geometry bound.

Two hardware issues prevent honest activation in this revision:

- DMA writes and 68030 data-cache reads need an explicit coherency contract.
  This task does not change CACR.  A later implementation must either obtain a
  provably cache-inhibited buffer mapping or save/alter/restore the relevant
  cache state with interrupt-safe ownership and a physical-Falcon test.
- The program currently has DSP XBIOS lifecycle macros but no sound-DMA
  save/restore owner.  Adding only the happy-path register writes would corrupt
  another sound client and make timeout recovery unsafe.

Hatari cannot close either hardware gate.  Consequently the source contains
the protocol/cost prototype but no dormant half-configured Crossbar path.  The
first hardware implementation must field-compare every decoded row against
the existing host record before it is allowed to feed the rasterizer.

## 8. When SSI/crossbar streaming is worthwhile

This section originally deferred SSI because the host still performed the
same packet construction either way, so a new transport could not pay for its
framing complexity.  **That precondition has inverted**: since the span-setup
record (sections 4.1b-4.1d) the DSP streams exactly the "compact raster-setup
records into a DMA ring buffer" this section always listed as the worthwhile
case. Earlier paragraphs retain the 475.2 ms LOD epoch for history.  The
decision authority is now the fresh 2,724-triangle full-mesh split in sections
3.5/3.8; internal transport splits remain estimates until physical-Falcon
instrumentation:

### What it would buy

The host-port transfer is programmed I/O: the M68030 services every word.
Animation transactions poll TXDE/RXDF per word, while bulk XBIOS calls and the
Cho Ren Sha pattern deliberately do not; either way, the CPU still executes
the transfer loop. `DSP-XMIT -> DMA-RECORD` through the crossbar can write
result records to ST-RAM autonomously. Combined with cross-frame pipelining,
those records could already be in memory at frame start and the CPU
would no longer service 86 result-chunk transactions. The upper bound is part
of the measured 112.7 ms triangle/readback/packet stage; exact unpack, DSP and
wire shares have not been isolated in the choreography build. Animation input
(4,933 words/frame average) would still use the host port unless a separate
host-to-DSP DMA design were added.

### The arithmetic, and its open question

The sound DMA frames 16-bit words; the record's slope fields are genuine
24-bit values and need two DMA units each. Record volume varies with survivor
count: roughly 10k-14k DSP words becomes 40-56 KB of 16-bit-framed output. At
the Falcon's specified 1 MB/s ceiling this is 40-56 ms per frame. It fits
inside the current 333.2 ms CPU rasterization window if truly asynchronous.
The open question is the achieved rate and the M68030 slowdown when DMA, Videl
and rasterizer all contend for ST-RAM; handshaking preserves data by stretching
the transfer, not by creating bandwidth.

### 8.1 Row-start DMA: the viable MUL offload

The two hot M68030 `MULS.L` operations left by section 3.7 produce exactly two
values per span row: the Q8.8 U and V at the first sampled pixel. Only their
low 16 bits are observable by the pixel loop, so this is the unusually good
SSI case: **two native 16-bit DMA words per row**, with none of the 24-to-32-bit
expansion that makes a general span record expensive.

At the delta-clear campaign's 9,043 rows per frame the payload is:

```text
9,043 rows * (u16 + v16) = 36,172 bytes/frame
```

That is 36.2 ms at the Falcon's 1 MB/s ceiling. Spread over the current 333.2
ms rasterizer window it requires only 108.6 KB/s; even a 32 MHz bit clock
divided by 24 supplies 166.7 KB/s before stalls. Transfer duration therefore
need not be on the frame's critical path. The intended ownership is
double-buffered:

```text
M68030 frame N : rasterize packets using row buffer A
DSP frame N+1  : finish projection, build survivors and final clipped U/V rows
DMA record     : DSP-XMIT -> buffer B, handshaked
frame boundary : verify frame/count/footer, then swap A and B
```

Each host packet receives a pointer into the completed row buffer while it is
built. Ordering-Table insertion may reorder packets freely because the row
data itself stays packet-local. If the DSP applies Y clipping and the left-edge
X clip before emitting a row, the stream removes not only the two normal
prestep multiplies but also the cold UV catch-up/left-clip multiplies. The
M68030 still owns the texture/CLUT accesses and pixel loop.

There are two integration stages:

1. **Same-frame proof:** emit row starts over SSI while the existing host-port
   chunk pipeline fetches and unpacks the same frame's span records. The UV
   pairs are already present on the DSP in that window. DMA must finish before
   `gpu_submit_ot`, but 36.2 ms nominal fits inside the current 112.7 ms packet
   stage. This validates packing, packet offsets and bit identity without a
   new cross-frame input path.
2. **True cross-frame overlap:** while the M68030 rasterizes N, the DSP builds
   rows for N+1 into the other buffer. Gouraud corner normals displaced the
   resident UV table, so this needs either a DSP-memory rebalance or a looping
   DMA-playback stream feeding the static UVs to DSP receive. Atari specifies
   playback and record as parallel channels, but their combined ST-RAM cost is
   a hardware measurement, not free bandwidth.

The natural extension is a complete span stream. Adding clipped `x0`, `x1`
and the Gouraud row level makes the M68030 row body a sequential record load
plus the pixel loop and removes the whole edge/ceil/clip walk. A simple five-
word representation is about 90.4 KB/frame before packet headers, 90 ms at the
specified ceiling and 271 KB/s when spread across 333.2 ms. It still fits the
window on paper, but unlike the U/V-only stream it is not merely a multiply
offload and needs a fresh current-rasterizer decomposition before being called
worthwhile.

That decomposition and the exact packed format now exist.  For the full mesh,
274 recorded frames average **12,439.35 walked rows and 1,018.96 packets**;
the observed maximum is 18,181 rows.  U/V-only is 49,757 bytes/frame, or 49.8
ms at the specified ceiling.  The section 7.4 three-word ABS row plus six-word
packet headers is 86,892 bytes/frame (86.9 ms); an adversarial shade change on
every row raises it to 111,770 bytes (111.8 ms).  `RUN16` may reduce those
figures but the budget credits **zero** compression until real DSP rows have
been captured.

**Every rasterization window quoted in this section belongs to the pre-3.9
epoch and has since shrunk by a third to a half.**  The LOD window is 180.7 ms
rather than 333.2, and the full-mesh one 272.0 ms rather than 544.3.  A stream
sized to "fit inside the window on paper" therefore has to be re-checked
against the current figures before any of these paragraphs is acted on: the
86.9-KB no-RLE full stream is 86.9 ms nominal against a 272.0 ms window, which
still fits, while the transfer duration a design may hide has fallen with it.
The payload figures themselves are unaffected -- they are counts of rows and
packets, and section 3.9 changed neither.

The full span stream was the only thing that attacked the then-measured
**303.9 ms row/span-walk** term; that term is now 112.6 ms (section 3.5), so
what a stream would recover has fallen by a factor of 2.7 while its own
transport cost has not.  It does not move texture access to the DSP: invalid
samples are only 0.16% and the DSP neither owns the 384-KiB texture pages nor
has a useful random texture path.  A texel-index RLE stream would have to feed
texture data or indices at pixel rate and would erase the transport margin.
Run coding here compresses geometric row state only.

### 8.2 Stock full-mesh 3 FPS gate

The target is **333.3 ms/frame on a stock 16-MHz Falcon030**, full 2,724-
triangle mesh and stock DSP.  The only current end-to-end split is Hatari's;
it is a planning ledger, not a stock projection, because the active core
charges much CPU arithmetic zero:

| Full-mesh component, frames 0--263 | Before 3.9 | **Current** |
|---|---:|---:|
| DSP setup + host readback + packet build | 189.1 ms | **186.3 ms** |
| Raster per-packet setup | 95.3 ms | **91.2 ms** |
| Raster row/span walk | 303.9 ms | **112.6 ms** |
| Raster pixel loops | 145.1 ms | **68.2 ms** |
| Set-frame send + clear + OT + rounding | 30.3 ms | **30.5 ms** |
| **Total** | **763.7 ms / 1.31 FPS** | **488.8 ms / 2.05 FPS** |

**Section 3.9 moved this gate by more than any transport ever proposed for
it, and it did so on the CPU side of the host port.**  The distance left to
333.3 ms is **155.5 ms**, against 430.4 ms before.  Everything below is
re-derived on the current column; the old arithmetic is kept only where it is
still the conclusion.

Removing the entire row walk now leaves **376.2 ms / 2.66 FPS** -- still short,
so the shape of the old conclusion survives: a U/V-only offload, whose
hardware ceiling is only the 68.4-ms multiply bound, cannot close three FPS.
But what it must be *combined* with has collapsed.  After ideal row removal
the design needs a further **42.9 ms**, not 126.5 ms, out of a 186.3-ms
packet/readback stage and a 91.2-ms packet setup.  That is 23% of one stage
instead of 67% of it.

The optimistic architectural envelope -- full row walk and the entire current
packet/readback stage both gone -- is now **189.9 ms / 5.27 FPS**, against a
target of 333.3.  The margin inside the envelope went from 62.6 ms to
143.4 ms, which is the first time this chain has had room for the costs the
envelope does not model: CPU packet material and OT construction cannot be
literally zero, an 86.9--111.8-KB DMA stream still writes and is later read
from ST-RAM, and DSP construction has a real cost.

Two consequences for what to build next:

- **The remaining frame is dominated by two host-side stages that are
  themselves mostly fetch**, not by the row walker the SSI stream was
  designed around.  91.2 ms of per-packet setup for 1,149 packets is
  1,270 cycles each at 16 MHz, and the NO_ROWS build proves that is
  `rasterize_packet` alone.  Applying section 3.9's own rule to it and to
  the 186.3-ms packet stage is cheaper, needs no hardware, and is where the
  next 155.5 ms is most plausibly found.
- **Roadmap item 19 got relatively more attractive, not less.**  Occlusion
  culling removes whole survivors, and a survivor now costs proportionally
  more in packet setup and wire transport than in row walking.

Revised verdict:

- **3 FPS full mesh: still not demonstrated, but no longer architecturally
  gated on SSI/DMA.**  155.5 ms is a host-side optimization target of the
  size section 3.9 just met twice over; it was a transport-architecture
  problem when the gap was 430.4 ms.
- **The former 1,600-triangle LOD reached 3 FPS, but it is removed.** Its
  319.8 ms / 3.13 FPS result remains a historical data point only; the
  supported build is the full mesh and has no 3-FPS emulator result.
- **U/V-only SSI: insufficient** even under its best arithmetic bound, and
  now by a wider margin, since the row walk it targets is 112.6 ms.
- **Five FPS is deferred.**  No optimization may spend the margin needed to
  close the stock full-mesh 3-FPS chain merely to improve a 200-ms stretch
  target.

None of this is a physical-stock FPS number.  The Hatari ledger omits CPU
arithmetic cost entirely (2.4a), and section 3.9's gain is concentrated in
exactly the term that model charges for, so a Falcon would show a smaller
relative improvement and a different balance between these stages.  The one
thing that does transfer without an emulator is the mechanism: the MC68030's
instruction cache is 256 bytes and direct-mapped on the real chip too.

#### 8.2a The gate re-measured after 3.9b/3.9c, and what is actually left

The full mesh could not be measured headlessly until the former
`trex_m68030_fullm` diagnostic target was added: `trex_full.tos` carried
`-DTREX_RUN`, which zeroed `stats_flush_enabled`, so a bounded run wrote no
`render_stats.res`. After the LOD removal, the standard `make trex_m68030`
target is the equivalent full-mesh diagnostic build, without `TREX_RUN`.

Measured over 265 frames, frame-100 `fb.res` reproducing the recorded full-mesh
checkpoint `d89958b3…3d16`, with the section 3.5 profile patches re-taken on
the same build:

| Component | ms/frame | share |
|---|---:|---:|
| DSP readback + packet build | **185.7** | 40.4% |
| Raster row/span walk | 113.4 | 24.7% |
| Raster per-packet setup | 68.3 | 14.8% |
| Raster pixel loops | 62.2 | 13.5% |
| set_frame + clear + OT + rounding | 30.4 | 6.6% |
| **Total** | **460.0 ms / 2.17 FPS** | |

The packet stage reads 185.7, 185.7 and 186.0 across the normal and both
profile builds, which is the cross-check that the patches touch only the
rasterizer.  **The distance to 333.3 ms is 126.7 ms**, down from the 155.5 ms
section 8.2 recorded before 3.9b/3.9c.

**Section 8.2's own next-step suggestion is now measured out.** It proposed
applying section 3.9's rule -- shrink the loop below the 256-byte instruction
cache -- to the 186.3 ms packet stage.  Listing accounting on the three
per-survivor host loops says there is nothing there to get: the packet builder's
body is **130 bytes**, `gpu_submit_ot`'s is **62**, and 3.9c's resolve sweep is
**118**, all comfortably inside the cache, and the record-unpack loop was
already pinned to 250 bytes by 3.9 step 4.  Whatever the 185.7 ms is, it is not
loop-body eviction.

**What it is, in the part that can be named:** the wire is about 26,800 words
per frame (1,149 survivor records at eighteen words, plus 5,448 UV words for
all 2,724 triangles, plus chunk headers and acks), or roughly 62 ms at the
2.3 us/word calibration.  Of the remainder, one item is pure duplicated work:
**every survivor's span record is handled twice.**  The unpack writes 22
expanded longwords into `dsp_triangle_rx_buffer`, and `build_gpu_shadow_packets`
then reads those 22 and writes them again into the packet through two MOVEM
pairs.  Letting the unpack write straight into the packet's span slots -- with
the source index and shade parked in two of 3.9c's resolve slots, which nothing
reads until the sweep -- removes 44 longword bus accesses per survivor, 50,556
per frame, about **25 ms** at the 8.05 cycles per longword this program
exhibits.  It is not free to build: the projected-vertex fallback and the span
validator both consume the old `rx_buffer` layout, so the copying builder has
to survive for them.

**The honest arithmetic for three FPS on the full mesh.**  That 25 ms and the
occlusion stage of item 19 are the only two levers with a named mechanism.
Occlusion at the DSP-buildable variant culls 10.5% of survivors and 11.24% of
writes (2.3a), which against the split above is roughly 14 ms of packet stage,
7 ms of per-packet setup and 20 ms of row/pixel work -- about **41 ms**, and
less than that at the 4x4 cells item 19 would have to fall back to.  Both
together are about 66 ms of the 126.7 needed, landing near **395 ms / 2.53
FPS**.  **Three FPS on the full mesh therefore does not follow from any
optimization currently identified**, and the residual ~60 ms has no mechanism
short of moving the record stream off host-port PIO entirely (item 15), which
Hatari cannot validate and which section 7.4 shows is not a small piece of
work. The retired LOD's 3-FPS result is not a supported-performance claim.

### Why this must be prototyped on hardware first

- Hardware handshaking prevents FIFO overflow, but the host-port protocol's
  application-level ack/count pairs disappear. A partial or shifted buffer
  can still desync the consumer silently. Sequence counters, declared word
  counts, a footer/checksum, DMA-end verification and double-buffered ownership
  are required — and the span validator is the natural bring-up tool: compare
  stream-delivered records field-for-field against host-port-delivered ones,
  exactly as during the record migration.
- Hatari's crossbar emulation is experimental (section 7 references), so an
  emulator success would not demonstrate hardware viability — this is the
  one optimization where emulator-first development is the wrong order.
  The historical note that a Unix-era DSP project never completed its
  matrix driver still stands as a warning about the software side.
- The host port remains the fallback transport in any case.

The first measurements on a physical Falcon should therefore use the same
fixed, checksummed stream for (a) RXDF-polled host PIO, (b) one-rendezvous blind
host PIO and (c) DSP-XMIT -> handshaked DMA-RECORD, under the active true-colour
mode. Compare total time, CPU-busy time and word integrity. This brackets the
emulator's 2.3 us/word calibration and decides separately whether blind PIO is
the best synchronous fallback and whether SSI streaming buys enough overlap to
carry its framing complexity.

The other originally listed cases — spans to an external FPGA, a second
DSP, external framebuffer hardware — remain speculative and out of scope.

## 9. Next-stage streaming protocol

The tested culling transport uses the existing host port with 32-triangle
result chunks. Compact raster setup records are already implemented and
validated; the next transport revision would move those same records to an
SSI/crossbar DMA ring without changing their semantic format.

### 9.1 DSP-side chunk input

The input side of this protocol already exists: the index list is resident
(CMD_LOAD_TRIANGLES), a chunk command is three words, and projected vertices
never leave the DSP except through GET_VERTICES, which the setup record
below finally retires.

### 9.2 DSP-side span-setup record — implemented and validated

The host-semantic record contains nineteen words. The first seventeen are
listed below; two UV starts follow. Since wire packing, all nineteen travel as
fourteen packed words (see `SPAN_RECORD_WORDS` in the DSP source for the exact
layout), and the host unpack restores this order. `SPAN_REC_*` on the host and
`make_triangle_span`'s store sequence on the DSP are the two ends of the
contract:

```text
w0   survivor key (chunk-local index | shade<<8)
w1   average-z / OT key
w2   sy0            sorted top Y
w3   rows_up        upper-half height (0 = flat top)
w4   rows_low       lower-half height (0 = flat bottom)
w5   mid            1 = middle vertex left of the long edge (cross < 0)
w6   xl0            top-vertex X, 12.12
w7   sl_long        long-edge X slope, 12.12
w8   sl_up          upper short-chain slope, 12.12 (0 when rows_up = 0)
w9   sl_low         lower short-chain slope, 12.12 (0 when rows_low = 0)
w10  x1r            middle-vertex X restart, 12.12
w11  du_dx          span U gradient, Q8.8
w12  dv_dx          span V gradient, Q8.8
w13  dul_up         left-chain U step, upper half, Q8.8
w14  dvl_up         left-chain V step, upper half, Q8.8
w15  dul_low        left-chain U step, lower half, Q8.8
w16  dvl_low        left-chain V step, lower half, Q8.8
```

With the middle vertex on the right, w13..w16 all carry the long-chain step,
so the consumer reads the up/low slots uniformly in both configurations. The
initial plain-word protocol made semantic validation easy; section 4.1d
records the later fourteen-word packing.

Validated **clean over two full revolutions**: 852,390 exact field
comparisons, zero mismatches (section 4.1b).  The two constraints called out
before implementation — sign extension of zero-extended 24-bit words, and
positioning the 48/24 dividends in the accumulator — both proved real; the
dividend one produced saturated quotients on first contact and is documented
at `span_div`.

Rejected triangles send nothing; generated triangles from a future
near-plane clipper would append records with a reserved source index, which
the survivors-only shape already accommodates.

**The switch-over is complete** (section 4.1c): `rasterize_packet` consumes
the record, the packet lost its screen coordinates, GET_VERTICES retired
from the normal path, and `span_validate_enabled` defaults off as an
on-demand regression tool.  Measured: 493.7 to 456.6 ms at byte-identical
output.

Two fields joined the record for the flip, gated through the validator like
everything else:

```text
w17  uv0pack        sorted top vertex u | v<<8
w18  uv1pack        sorted middle vertex u | v<<8
```

### 9.3 Double buffering

The intended overlap is:

```text
DSP:  prepare chunk N+1  ->  prepare chunk N+2  -> ...
CPU:  rasterize chunk N   ->  rasterize chunk N+1 -> ...
```

Ordering constraints must be handled explicitly — more than ever, because the
far-to-near OT walk is the entire visibility model now. The complete Ordering
Table must exist before the first packet is drawn; a chunk cannot be
rasterized as it arrives.

What overlap CAN do is now implemented (section 4.1d): the DSP prepares
chunk N+1 while the host unpacks chunk N, and the framebuffer clear hides
inside chunk 0's compute.  The rasterization phase itself still starts only
after the last chunk is linked, exactly as this section predicted.  The
cross-frame stage on top (roadmap item 12) moves the NEXT frame's animation
send before the rasterization and defers its FINISH ack to the next slot,
which needed no second buffer at all: the records stay DSP-resident until
fetched, and the host buffers are only live between drain and rasterize.

## 10. Recommended implementation order

1. Add real rasterizer counters for:
   - total triangle calls,
   - zero-area rejects,
   - clipped/out-of-screen rejects,
   - surviving triangles,
   - scanlines,
   - pixel candidates,
   - edge rejects,
   - Z rejects,
   - transparent texels,
   - successful color/depth writes.
2. Extend the now-tested DSP area path with bounding-box, near-plane, and
   optional back-face rejection. **Done** — see section 5, priority 1.
3. Make the static triangle index list resident instead of re-sending it every
   frame. **Done** — see section 4.1. The readback/packet-build stage dropped
   from 128.6 ms to 103.6 ms per frame at byte-identical render output, and the
   change calibrated the host port at about 2.3 us per word.
4. Return the clipped bounding box and send survivors only. **Done** — see
   section 4.1a: -88.3 ms per frame at byte-identical output (rasterizer
   -82.5 ms, transfer -7.0 ms). At this intermediate step the signed area
   still stayed on the host; step 6a later moved it with the full setup.
5. Drop the Z-buffer for PS1-authentic painter's visibility, with the pixel
   loop register pass the removal enables. **Done** — see section 6.2:
   1,415.2 to 1,300.3 ms (-114.9 ms) at a visually identical image (0.31%
   pixel difference, overdraw factor 1.50). Three of the nine setup DIVS.L
   went with the Z interpolation.
6. Convert the rasterizer to PS1-style DDA scanline spans. **Done** — see
   section 3.4: 1,147.3 to 340.4 ms rasterizer, 1,300.3 to 493.7 ms per
   frame (0.77 to 2.03 FPS), coverage verified near-identical with the
   right/bottom-exclusive convention.
6a. Compute the span-setup record on the DSP under host validation.
   **Done** — see section 4.1b: 852,390 exact field comparisons over two
   revolutions, zero mismatches, byte-identical output throughout.  The
   validator caught three real bugs (packet-stride shear, misplaced 48/24
   dividends, the fractional-MPY low-word trap) before turning clean.
6b. Flip the consumer to the record. **Done** — see section 4.1c: 493.7 to
   456.6 ms (rasterizer -70.8 ms, readback +34.1 ms) at byte-identical
   output, gated by the validator before and during the flip.
6c. Pack the wire record and pipeline the chunk protocol. **Done** — see
   section 4.1d: 456.6 to 434.0 ms.  The remaining readback stage is
   mostly DSP span arithmetic that the host no longer waits for in full.
7. The compact setup record superseded the old full-packet plan: the packet
   is the record plus command/material/key/page since section 4.1c.
   **Done.**
8. Host-port chunk double buffering. **Done** — realized as the pipelined
   chunk protocol of section 4.1d.
8a. Extract the original morph system, automatic controls, camera/object
    coordinate and scene state. **Done** — TANM v2 contains 274 verified
    records and 46 exact deduplicated gait poses.
8b. Apply the pose, target products, matrix and projection on the DSP.
    **Done** — acknowledged BEGIN/GAIT/TARGET/FINISH transactions; the
    corrected full path is measured in section 2.
8c. Correct the PS1 TMD little-endian vertex import and Falcon display aspect.
    **Done** — source components are byte-swapped before sign extension;
    projection is 625×933 and validated at frames 0, 146 and 273.

The open roadmap, in recommended order (expected effects from the section
2.2 utilization split; all Hatari figures):

9. Replace the present copy with a Videl page flip. **Done** — see section
   6.5.  The full 30.3 ms was realised and nothing else moved: 820.2 to
   784.9 ms over the 0-263 prefix at a byte-identical image.
10. Offline mesh LOD. **Removed.** The decimation tool, generated mesh and
    sidecars, selection include, build option and alternate binaries were
    removed when the reduced mesh was deprecated. The original 2,724-triangle
    O3D is now the only supported geometry.
11. Reprofile and optimize the span rasterizer. **First pass done** -- see
   section 3.6: span-accumulated counters, word-mask texel addressing with
   scaled indexing, the one-muls prestep and register DDA state removed
   140.5 ms (585.5 to 445.0 ms, 1.35 to 1.66 FPS) at byte-identical output.
   Combined U/V accumulation is rejected as not bit-exact. Section 3.7 finds
   no divide in the normal CPU path and rejects a direct DSP row stream on
   **host-port** wire and scratch cost; section 8.1 reopens the same result as
   a double-buffered SSI/DMA stream whose transfer can overlap CPU work. The
   same-size packet stride multiply is removed locally. **Second pass done** --
   section 3.8's qualified opaque scalar path removes four instructions from
   94.99% of recorded full-mesh samples and measures -28.4 ms raster/-27.8 ms
   frame in a one-byte equal-layout A/B.  The 2x unroll is measured slower and
   rejected.  **Third pass done, and it is the largest result in this
   document** -- section 3.9: the row loop was 552 bytes against a 256-byte
   direct-mapped instruction cache that TOS leaves enabled, and five steps of
   moving cold bodies out of line, hoisting packet invariants and shrinking
   the two per-item loops below 256 bytes measure **517.3 to 319.8 ms
   (1.93 to 3.13 FPS) on the LOD and 763.8 to 488.8 ms (1.31 to 2.05) on the
   full mesh**, at byte-identical output throughout.  Registerizing xr is part
   of that series (step 3).  The remaining local candidate is the per-row ceil
   incrementalization; the row walker is no longer the dominant term, so
   section 8.2's SSI conclusion has been re-derived rather than inherited.
   **Fourth pass done** -- section 3.9b measures the per-packet fetch term
   the third pass left dominant (938-988 bytes per packet by listing
   accounting) and removes 70 executed bytes of it: the dead packet-time
   CLUT pointer, fall-through classification for the qualified-opaque class,
   and a per-packet Y-clip sign flag in place of six per-half checks.
   Measured 317.4 to 309.1 ms (3.15 to 3.24 FPS) over the LOD 0-263 and
   461.6 to 445.7 ms (2.17 to 2.24) on the full mesh 0-101, byte-identical
   throughout.  ~860 bytes per packet remain; the cache-resident batch
   resolve pass over the packet buffer is the named next candidate.
   **Fifth pass done** -- the resolve pass itself, section 3.9c: six resolve
   slots per packet, a 120-byte resident sweep before the OT walk, and
   `rasterize_packet` loads its class state with one MOVEM.  Campaign total
   **302.6 ms / 3.30 FPS on the LOD 0-263 and 436.0 ms / 2.29 FPS on the
   full mesh 0-101**, byte-identical throughout.
12. Cross-frame pipelining. **Stage 1 done, stage 2 measured and rejected.**
   Stage 1 sends frame N+1's animation after frame N is fully unpacked and
   defers the FINISH ack to the next slot's `dsp_packets_begin`, so the
   1,376-vertex morph/transform/projection runs inside the rasterization
   window.  No double buffering was needed: the span records stay resident
   on the DSP until fetched, and the host-side record/packet buffers are
   only live between drain and rasterize.  Measured over 0-263 at a
   byte-identical image: animation stage 21.5 to 13.6 ms, frame 362.8 to
   **354.8 ms (2.76 to 2.82 FPS)**.

   Stage 2 — fetching the whole chunk stream from inside the OT walk via a
   non-blocking service hook and a per-chunk slot accumulator — was built,
   validated byte-identical, and measured SLOWER: 278.0 ms against stage
   1's 263.8 ms on the same 102-frame gate prefix.  The section 4.1d chunk
   pipeline already hides the DSP's per-chunk compute behind the host's
   unpack of the previous chunk, cache-warm; the accumulator broke that
   interleave (deferred unpack re-reads 59 KB cold), added hook overhead to
   the rasterizer, and the remaining genuine DSP wait after the LOD is only
   a few milliseconds.  The remaining readback stage is CPU work — unpack,
   packet build and wire PIO — which no scheduling can hide.  Conclusion:
   after stage 1 this roadmap item is exhausted on the host port; only the
   SSI/DMA transport (item 15) could remove the PIO share itself.
13. Per-corner Gouraud lighting. **Done as the span-level variant** — the
   DSP lights all three TMD corner normals (recovered offline, section
   4.4a's split layout for both mesh variants), ships three sorted Q4.8
   level starts and gradients in the 18-word record, and the rasterizer
   selects a CLUT bank per span row from the interpolated left-chain level.
   The pixel loops are untouched, which is why the measured interpolation
   cost is **+8.1 ms per frame** against the 4.4b model's 15-45% for
   per-pixel variants — smooth along Y, flat along each span, visibly
   Gouraud on the head (measured at the 300x224 render target that preceded
   the 240x224 one).  NOT PS1-exact: the source modulates
   interpolated RGB per pixel; that fidelity tier remains costed in 4.4b
   and unbuilt, alongside the 4.4a PS1/GTE fixture question.  The
   remaining epoch costs are protocol (~32 ms readback) and layout phase
   (item 16), not shading arithmetic.
14. Hardware measurement points, before more micro work: run the same fixed,
   checksummed stream through RXDF-polled host PIO, Cho Ren Sha-style
   block-gated blind host PIO and handshaked SSI record DMA in true-colour mode
   (section 7.3a/8). Record elapsed time, CPU-busy time and lost/corrupt words.
   The emulator's 2.3 us/word applies only to its measured path.  The test must
   additionally record rasterizer slowdown with DMA active, DMA completion
   latency, buffer coherency, DSP production time and end-to-end frame time;
   transfer microbenchmarks alone cannot select the 3-FPS path.
15. SSI/crossbar streaming per sections 7.4/8. **Protocol prototype done,
   hardware activation pending.**  Full mesh makes U/V 49.8 KB/frame and the
   complete no-RLE stream 86.9 KB average (111.8 KB shade bound), not the old
   LOD-derived 36.2 KB.  The executable ABS/SET_SHADE/RUN16 coder round-trips,
   2x192-KiB ownership covers every recorded frame, and overflow has a defined
   host-port fallback.  Next is the physical-Falcon owner: exact sound-state
   save/restore, handshaked DSP-XMIT -> DMA-RECORD, and cache coherency without
   an ad-hoc CACR write.  Only then may cross-frame span consumption replace
   the CPU row walker.  U/V-only is explicitly insufficient for three FPS.
16. **Closed to a measured mechanism.**  Three findings, each by scan:
   the Gouraud buffer growth moved the unpinned preshaded CLUT banks and
   cost 80 ms at an unchanged instruction stream — they are pinned now.
   The texture BLOCK phase is exonerated: eleven scan points (4-KiB
   raster, then the full 256-byte cache period of the 68030's bits-4..7
   line select in 32-byte steps) sat flat, and any cnop before the block
   costs a constant ~13 ms by rounding it against cells that move along.
   The live lever is the RASTER STATE CELLS' phase — one RMW per row
   each in the walker: their scan draws a real curve, 275.6 to 262.0 ms
   across the 256-byte period, and phase 224 pinned its minimum in that
   first, RELATIVE scan (528.5 to 515.7 ms, 1.89 to 1.94 FPS, on the full
   prefix).  **`RASTER_STATE_PHASE` is 32, not 224** — the re-measurement
   after the absolute anchoring below moved the minimum, and 32 is what the
   source has carried since commit cb769dc.  The 224 survives here only as
   the history of how the lever was found; do not read it as the setting.
   The candidate relations are now measured out: the packet buffer and
   the OT-node buffer each scanned FLAT across the full 256-byte period
   (261.6-262.3 ms, noise) — the rasterizer's entire layout sensitivity
   demonstrably lives in the raster state cells.  All three scan targets
   are anchored absolutely with a cnop 0,256, so growth in front of them
   can never re-randomize a phase again; the raster curve re-measured
   absolutely puts its minimum at phase 32 (261.8 against a 277.1 peak).
   The ~35 ms between this epoch's flat path and the pre-Gouraud
   rasterizer at equal loop code remains, now with the buffer phases
   eliminated as its cause — the remaining suspects are the grown wire
   record's unpack footprint and instruction-fetch interactions, both
   outside the data-phase mechanism this item closed.  **Reopened by one
   measurement:** deleting an eight-byte XBIOS call from `gpu_open` moved
   the rasterizer 333.2 to 361.3 ms at a byte-identical image (section 2).
   All three scan targets are absolutely anchored and cannot have moved,
   so that 28.1 ms is outside everything this item measured — the
   instruction-fetch suspect is now the one with evidence behind it.
   **Closed a second time, on that suspect, in section 3.9.**  The
   instruction cache is enabled (`CACR = $3111`, TOS sets it), it is 256
   bytes and direct-mapped on bits 4..7, and the row loop spanned 552 of
   them.  Bringing it under the line is worth 197.5 ms per frame on the LOD
   and 275.0 ms on the full mesh.  That is the residual this item chased,
   an order of magnitude larger than the 17 ms it started from, and it
   explains the two loose ends left above: an eight-byte text change moved
   the rasterizer 28.1 ms because it moved which line the row body's tail
   landed on, and the delta clear's 13.5 ms for merely existing was the same
   effect in `span_walk_half`'s neighbourhood.  Data phase was never the
   whole story; code length and code order were the rest of it.
   The new 192-KiB word CLUT is intentionally placed after all of these pinned
   hot regions and independently 4-KiB anchored; it does not reopen the data-
   phase result.  Opaque timing still uses a one-byte equal-layout gate because
   text-fetch/layout sensitivity outside those regions remains real.
   Original item: explain the residual ~17 ms of render-target layout sensitivity in
   section 2.1, or bound it.  The framebuffer/Z-buffer cache-phase
   hypothesis is measured and eliminated (a 128-byte de-phasing pad moved
   0.7 ms); CLUT and texture reads sweeping the data cache are the next
   suspect.
17. Finish the section 4.4 lighting contract. The three source lights, the
    ambient and the two original eye colours are in, and per-corner Gouraud is
    **done as the span-level variant** (item 13): section 4.4a's offline TMD
    extraction recovers all 3,610 corner normals directly, so the O3D's
    one-normal-per-triangle limit no longer bounds the representation — that
    question is closed. What is left is the fidelity tier item 13 flagged
    NOT PS1-exact: interpolated RGB modulated per pixel, not an interpolated
    brightness level selecting a preshaded bank, which section 4.4b costs and
    section 4.4a's PS1/GTE validation fixture still has to certify. Per-face
    preshaded CLUTs remain the fast fallback, not the fidelity target.
18. Decide the playback timebase explicitly. The current inspection mode
    renders every extracted record and therefore slows the 274-frame sequence
    to the achieved render rate. A PS1-time mode should advance from VBL time
    and drop choreography records when rendering cannot keep up; it preserves
    shot duration but, at ~1.2 FPS, would display only a small subset of poses.
19. DSP-side occlusion culling. **Implemented and live for the complete
    2,724-triangle mesh; build-verified and Hatari framebuffer gates passed.**
    Section 2.3f is the current authority. `-DTREX_PREPASS` classifies the full
    resident index list twice into 64 coarse depth classes (32 host OT buckets
    each), scatters at most 1,335 survivors into one order list, and walks only
    the 8x8-pixel cells overlapped by each survivor's clamped box. Two 56-word
    masks hold sealed and current-class pending coverage. Qualified opaque
    triangles stamp only when all four cell corners are inside; BUILD skips the
    resulting 114-word global kill bitmap. Coarsening only delays sealing, so
    it under-approximates the host's strictly-nearer order rather than making
    an unsafe kill.

    Mode 1 runs in the existing FINISH window and stays armed through both the
    274 authored records and the frontend's continuing gait/turn hold. Modes 2
    and 3 remain fixed two-word run-now commands for measurement. The current
    full-mesh program ends at `P:$0988`, leaving `$0989-$09BF` free before the
    resident indices at `Y:$09C0`; the X overlay ends exactly at `X:$3FFF`, and
    resident Y data ends at `Y:$3FFE`. No LOD-only relocation or alternate
    hardware map is used.

    The occluder qualification still rides in bit 23 of packed index word A,
    sourced from the same opaque sidecar as `OPAQUE_PACKET_BIT`; all DSP vertex
    extracts mask to eleven bits while normal indices retain twelve. The old
    projected-vertex command and ordered-list streamer remain retired.

    Hatari/TOS 4.02 gates are byte-identical at frame 100 and hold frame 291
    between armed and disarmed controls, with zero protocol failures or
    capacity overruns, while cumulative raster writes fall when armed. Those
    are emulator correctness results. The measured freestanding cost and yield
    are recorded in 2.3f; physical-Falcon window occupancy, end-to-end timing,
    culling yield and FPS remain unmeasured. Sections 2.3a-2.3e retain the
    predecessor designs and measurements explicitly as history, not as the
    current memory or algorithm contract.
20. Delta clearing instead of the full-window clear. **Built, measured,
    REJECTED — see section 2.5.** It saves 8.0 ms in the clear and costs
    14.4 ms in bookkeeping, a net +6.1 ms, plus 13.5 ms of layout cost merely
    for the code being present. The clear stage turns out to sit at the
    memory-bus floor (8.7 cycles per longword against a ~8-cycle hardware
    minimum), so area is the only lever and no cheap enough way to find the
    area exists on this machine. The analysis that motivated it follows,
    because the area figures are sound and it was the cost of *finding* the
    area that killed it — over the 0-263 prefix, per frame:

    | Scheme | bytes/frame | share |
    |---|---:|---:|
    | Full clear (today) | 107,520 | 100% |
    | Per-row min/max span | 35,508 | 33.0% |
    | Exact runs (Cho Ren Sha's RLE) | 34,981 | 32.5% |

    **Exact run-length coding buys 0.5 percentage points over one min/max pair
    per row**, because 243.8 runs spread over 203.7 used rows is 1.2 runs per
    row: this model is a single connected silhouette per scanline, not a field
    of scattered sprites. Cho Ren Sha 68k's RLE machinery (`create_rle_data`
    plus the computed-jump restore loop in its `graphics.s`) solves a problem
    this renderer does not have. Two bytes of min/max per row, tracked in the
    span loop where `xl`/`xr` are already known, capture essentially all of it.
    Expected saving about 9.8 ms per frame, roughly 2% — worthwhile and cheap,
    but well behind roadmap item 11 in size.
    Two constraints: the target is double-buffered, so the span table has to be
    double-buffered with it and the clear must undo what was drawn **two**
    frames ago (Cho Ren Sha's `swap_sprite_infos` exists for exactly this); and
    a missed pixel leaves a ghost from two frames back, which is a silent
    visual defect, so `fb.res` byte identity is the mandatory gate.

## 11. References

- [Atari Falcon 030 Developer Documentation, October 1992](https://bus-error.nokturnal.pl/dl5)
- [Atari Compendium, Falcon sound system, DSP, and connection matrix](https://frummel.org/~weedz/atari/docs/The_Atari_Compendium.pdf)
- [Atari Falcon030 Owner's Manual](https://www.atariworld.org/files/docs/Atari_Falcon030_Manual_en.pdf)
- [Falcon hardware register listing](https://temlib.org/AtariForumWiki/index.php/Atari_ST/STe/MSTe/TT/F030_Hardware_Register_Listing)
- [Hatari Falcon I/O register table](https://hatari.frama.io/hatari/doxygen/io_mem_tab_falcon_8c_source.html)
- [Hatari user manual: experimental Falcon crossbar emulation](https://hatari.frama.io/doc/manual.html)
- [Motorola DSP56000/DSP56001 User Manual, SSI chapter](https://www.nxp.com/docs/en/user-guide/DSP56001UM11.pdf)
- [Motorola MC68030 User's Manual, instruction timing](https://www.nxp.com/docs/en/reference-manual/MC68030UM-P2.pdf)
- [DSP56K host-port and historical crossbar software notes](https://www.nocrew.org/sites/dsp56k.nocrew.org/)
- [Cho Ren Sha 68k Falcon release archive](https://www.atarimania.com/game-atari-st-cho-ren-sha-68k-falcon030_30783.html)
