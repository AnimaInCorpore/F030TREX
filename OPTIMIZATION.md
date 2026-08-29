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

The current diagnostic baseline is the frame-local normal-light-cache build
from section 2.4d, measured over the fixed 265-frame prefix on the corrected
DSP-clock Hatari described in 2.4b:

| Stage | Time per frame | Share of frame |
|---|---:|---:|
| DSP set_frame | 13.2 ms | 2.5% |
| DSP triangle setup/readback and packet build | 252.1 ms | 47.9% |
| Framebuffer clear | 14.6 ms | 2.8% |
| Ordering Table insertion | 2.5 ms | 0.5% |
| Software span rasterizer | 243.8 ms | 46.3% |
| **Total** | **526.6 ms / 1.90 FPS** | **100.0%** |

The frame-100 framebuffer remains byte-identical to the recorded diagnostic
checkpoint `d89958b3…3d16`.  Relative to the immediately re-run 534.2 ms
baseline below, all 7.7 ms of stage saving lands in DSP readback/packet build;
the rasterizer is identical to the tick.  These are corrected-Hatari emulator
measurements, not physical-Falcon timings.

The release now keeps the occlusion implementation compiled in but defaults it
to disarmed, following 2.4c's measured +3.5 ms net loss at the current yield.
With the light cache and that default, the layout-identical two-byte timing
copy of `TREX.TOS` measures **525.5 ms / 1.90 FPS** over the same 265 frames
(251.8 ms packet stage, 242.8 ms rasterizer).  The two changes together remove
11.0 ms from the previously recorded 536.5 ms release.  Its frame-100 dump hash
changes because the release-only FPS digits now show the faster rate; the
diagnostic build without that overlay is the byte-identity correctness gate.

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
prepass/FPS options, so this table is not a release timing claim -- **the
release itself is now measured separately in section 2.4e: 511.2 ms /
1.956 FPS**, 4.8 ms behind the diagnostic build.

These are emulator timings, not a cycle-accurate benchmark and not a
measurement on physical Falcon030 hardware. **Section 2.4a is the bound on how
far they may be read**: the core that produced them charges bus traffic and IO
wait states but no instruction execution time at all, which makes the
bus-dominated stages the trustworthy ones and the arithmetic-heavy rasterizer
the least trustworthy. No figure in this document has ever been taken on a
Falcon.

**The current baseline is 506.4 ms / 1.975 FPS**, corrected emulator, after
sections 3.10 and 3.11. Every figure in this document except 2.4b, 2.4c, 2.4d,
3.10 and 3.11 was taken on a stock Hatari that ran the DSP at twice a Falcon's
clock (2.4a).

| Step | Frame | FPS |
|---|---:|---:|
| Corrected-clock baseline, as measured (2.4c) | 535.7 ms | 1.867 |
| + word CLUT data-cache phase 128 (3.10) | 532.6 ms | 1.878 |
| + unpack writes into the packet (3.11) | **506.4 ms** | **1.975** |

The table below is the corrected baseline **at the shipped-then layout**,
`OPAQUE_CLUT_PHASE = 0` and the copying builder: **535.7 ms / 1.867 FPS**.
Sections 2.4c and 2.4d were all measured there and remain internally consistent
pairs; the two changes above move the rasterizer by -3.1 ms and the packet
stage by -25.2 ms respectively when placing any of them against the shipped
binary.

Re-measured on the corrected emulator, the same binary reads
**535.7 ms / 1.867 FPS**, and the whole difference from the stock ledger lands
in one stage:

| Stage | Corrected time per frame | Share of frame |
|---|---:|---:|
| DSP triangle setup/readback and packet build | **260.40 ms** | 48.6% |
| Rasterizer (row/span walk, per-packet setup, pixel loops) | 244.61 ms | 45.7% |
| Framebuffer clear | 14.58 ms | 2.7% |
| DSP set_frame | 12.90 ms | 2.4% |
| Ordering Table insertion | 2.78 ms | 0.5% |
| **Total** | **535.7 ms / 1.867 FPS** | **100.0%** |

The packet stage is now the largest item in the frame, and section 2.4c splits
it: ~173 ms exposed DSP compute, ~73 ms host CPU work, 14.2 ms host-port wait
states. Read the stock-clock table below for the rasterizer decomposition,
which the correction does not touch, and 2.4c for anything about the packet
stage, the wire or the optimization ranking.

The stock-clock table, retained because the rasterizer split is still current
and because the rest of this document is written against it:

| Stage | Time per frame | Share of frame |
|---|---:|---:|
| DSP triangle setup/readback and packet build | 185.7 ms | 40.4% |
| Raster row/span walk | 113.4 ms | 24.7% |
| Raster per-packet setup | 68.3 ms | 14.8% |
| Raster pixel loops | 62.2 ms | 13.5% |
| Set-frame send, clear, OT and rounding | 30.4 ms | 6.6% |
| **Total** | **460.0 ms / 2.17 FPS** | **100.0%** |

**This table was taken with the DSP running at twice Falcon speed.** The
emulator that produced it grants the DSP56001 four clocks per emulated 68030
clock instead of two; section 2.4b is the re-measurement on a corrected build
and puts the same binary at **534.2 ms / 1.87 FPS**, with all 84.5 ms of the
difference in the DSP/packet row and the rasterizer rows unmoved. Read the
shares above as obsolete — on the corrected model the transport stage is 48.6%
of the frame and the rasterizer 45.7%.

The frame-100 framebuffer checkpoint was byte-identical to the recorded
full-mesh hash `d89958b3…3d16`; it still is on the corrected emulator, which
changes timing and not output. This is an emulator result, not a physical
Falcon030 timing. The former LOD shipping result, 319.8 ms / 3.13 FPS, is
historical and no longer describes a buildable configuration.

The full 2,724-triangle mesh moved from **763.8 to 488.8 ms** in section 3.9's
instruction-cache series (1.31 to 2.05 FPS) at byte-identical output. Section
8.2a then recorded the 460.0 ms diagnostic baseline after 3.9b/3.9c.  **Both
are stock-clock figures** and neither is the current baseline: 2.4b's clock
correction adds about 74 ms to the same binary, and the table at the top of
this section -- 526.6 ms / 1.90 FPS -- is what the current build measures.
The series' *gains* survive the correction because they are rasterizer gains
and the DSP clock is not a term in the rasterizer; its absolute totals do not.

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
**Superseded — see 2.4c.** That is the flat-shading, reduced-mesh epoch. On the
current build, at the corrected DSP clock, the same one-byte `lighting_enabled`
A/B measures **+52.0 ms, 9.7% of the frame**, essentially all of it on the DSP
readback stage.

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

Read from the current full-mesh state, that closing lever list is obsolete:
the reduced-mesh LOD was later removed entirely (section 2), the
pixel/row-loop campaign ran to its measured end (sections 3.6-3.9c, with
3.9a recording that further per-row whittling now measures slower), and
cross-frame pipelining landed as item 12's stage 1 while its stage 2 was
measured and rejected.  Section 8.2a carries the current accounting: the
largest stage is the 185.7 ms readback/packet build, and the two levers
with named mechanisms sit there and in item 19's yield -- not in the pixel
loop.

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

Sizes: after that compaction, the full-mesh program ended at `P:$0988` -- 50 words smaller than
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
sealing rule requires.  The 64-class result remains the active and
measured-yield authority.  The isolated 128-class/8x8-cell probe of section
2.3i was correct but rejected: its only equal-frame sample saved 2,516 writes
over 246 frames (0.030%), far below the established 64-class yield.  The
arm-2 freestanding 64-class prepass cost
75.6 ms/frame in Hatari -- the two classification passes dominate -- which
the production arm-1 inline mode hid inside the FINISH window; these are
emulator figures under the 2.4a caveats.  (**2.4c re-measures the prepass at
the corrected DSP clock: 117.9 ms/frame freestanding, and the armed inline arm
is no longer free.**)

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
rewritten culling path from 2.3f while defining `TREX_RUN`:
framebuffer/stat diagnostics and the final diagnostic flush are
disabled. The matching `TREX.LOD` is still read once at startup, so the
mounted GEMDOS volume remains necessary.

This is the single supported full-mesh package: textured Gouraud shading,
the DSP occlusion implementation retained but default-disarmed after 2.4c
measured its current yield as a net loss, and no per-frame diagnostic file
writes. Diagnostic prepass builds still default to arm 1, and the release's
one-word `prepass_arm` can still select the same validated path for yield work.
Build it with `make trex_release`; the matching `TREX.LOD` copy is placed
beside the TOS so the release directory is self-contained. The DSP protocol,
resident memory layout and `.LOD` contents are the validated production path
described above; no separate presentation-mode variants are part of the
release.

### 2.3h The DSP reserve, audited a third time -- sites and what they buy

2.3c recovered 166 words from jump encoding, 2.3d counted the parallel-move
reserve, and the light-cache revision (4.4c) has since harvested the densest
block of those pairing sites. This section is the same audit run a third
time, over the source as it stood at `P:$098C` with 51 words free. It is an
audit, not a result: word counts are read from the source, millisecond
figures are cost models under 2.4a's caveats, and except where an item is
marked implemented, nothing in it is built.

What DSP speed would even buy has to be bounded first, because it is not
frame rate. The FINISH window hides the armed prepass -- 75.6 ms/frame
freestanding in Hatari (2.3f) -- inside the ~244 ms of raster time in the
8.2a split, and the chunk protocol hides BUILD compute behind the host's
unpack of the previous chunk, with the genuine DSP wait measured at a few
milliseconds per frame when item 12's stage 2 probed it in the LOD epoch.
DSP cycles therefore buy margin: the armed hold's budget, and headroom
against a window that every rasterizer improvement narrows. Program words
buy item 19's next stage. Neither buys FPS directly.

The sites, in recommended order. Bracketed figures are static estimates of
the program-size change in words (negative frees words):

1. **Corner-normal rotation staging -- implemented, register-resident.**
   The audit planned three X staging cells beside the 4.4c cache so the
   MACs could pair X normal loads with Y matrix loads [-20]. Built, the
   staging turned out to be unnecessary: the bank-split loader drops the
   corner normal straight into x1/y1/x0 -- x1*y0, y1*y0 and x0*y0 are all
   legal multiplier pairings, and the rotation writes only A and Y0, so
   the three components survive it in registers -- and the three unrolled
   row blocks collapse into one `DO #3` streaming the matrix through Y0
   into the consecutive `shade_cx..cz`. The retired `shade_nx..nz` cells
   became alignment padding, so `tri_x0`'s multiple-of-eight anchor is
   untouched, and no lifetime constraint lands on the order-list tail.
   Result: **41 words freed** -- assembled extent `P:$098C` to `P:$0963`,
   92 words now free to the `$09BF` ceiling -- at DOSBox assembly 0
   errors/0 warnings, and the 4,000-VBL Hatari run reproduces the
   recorded frame-100 full-mesh `fb.res` checkpoint `d89958b3…3d16`
   byte-identically. The cycle effect is unmeasured (2.4a).
2. **O(1) kill-bit addressing -- implemented.** `prepass_kill_address`
   divided by 24 with repeated subtraction: up to ~113 iterations at the
   highest triangle indices, per killed triangle, plus one call per sweep
   entry.  One fractional multiply by `$55556` now computes floor(n/24)
   exactly for every n below 524,288 -- far past the 2,723 maximum -- and
   `REP x0`/`ASL` builds the one-hot remainder mask with the zero-count
   guard keeping its existing shape; Y0 stays untouched for the sweep's
   row coordinate, and Y1 is the new scratch (dead at both callers).
   Cost: 4 program words (extent `$0963` to `$0967`, 88 free).  Gates:
   DOSBox 0/0; plain and arm-2 frame-100 `fb.res` reproduce
   `d89958b3…3d16`; the armed hold run reproduces the frame-291
   checkpoint `e66d4d43…b00486` byte-identically against its disarmed
   control -- kills still land on exactly the right triangles -- with
   zero protocol failures and 62,920 fewer cumulative armed pixel writes
   (353/354 frames completed), consistent with 2.3f's recorded 61,697.
   Measured cost effect: the arm-2 freestanding prepass drops from 76.76
   to 75.98 ms/frame -- 11,500-VBL runs of 309/310 frames including the
   hold, one `.lod` swapped under one host binary (2.3f's recorded 75.6
   was 65 early frames, a different mix).  About -0.8 ms/frame, 1%: real
   but small, because the two classification passes dominate the stage --
   which is site 3's target.
3. **Pass-2 classify cache -- implemented.** The two classification passes
   ran the identical area/bbox/zkey chain twice; the kill bitmap is dead
   storage until the sweep, so pass 1 now marks every survivor's bit there
   while it counts, and pass 2 walks the bits with the same streaming
   word-pointer-plus-one-hot cursor idiom BUILD's kill consumer uses
   (A2-carry wrap, 2.3f defect 2): a cached reject advances R2 past its
   three resident words and the cursor, nothing else, while a survivor
   re-runs only the unpack and the key.  The bucket rule stays one shared
   code path, and the two passes now see the same survivor set by
   construction.  Two constraints the audit's sketch missed: rejects must
   resync R2 themselves (unpack normally advances it), and the OVERFLOW
   exit must clear the bitmap -- pass 1 has filled it with survivor bits,
   and BUILD reading those as kills would kill every survivor.  A shared
   `prepass_clear_kill` serves the run start, the pre-sweep cache
   retirement and that overflow exit.  Cost: 36 program words, not the
   estimated 15 (extent `$0967` to `$098B`, 52 free -- the sketch omitted
   the cursor advance, the R2 resync and the overflow clear).  Gates:
   DOSBox 0/0; plain and arm-2 frame-100 `fb.res` reproduce
   `d89958b3…3d16`; armed and disarmed hold runs both reproduce the
   frame-291 checkpoint `e66d4d43…b00486` with cumulative pixel counters
   identical to the site-2 validation pair to the last digit (13,426,986
   armed / 13,489,906 disarmed) -- the culling decisions are bit-equal
   across the change -- and the arm-2 survivor maximum stays exactly
   1,194, zero overflow, zero protocol failures.  Measured effect: the
   freestanding prepass falls from 75.98 to **60.28 ms/frame** (arm-2, and
   **117.9 ms/frame when re-measured at the Falcon's real DSP clock — 2.4c**,
   11,500-VBL runs of 310/318 frames, one host binary, only the `.lod`
   swapped) -- **-15.7 ms/frame, -21%**, and -16.5 against the site-1
   baseline's 76.76.  The faster `.lod` completes eight more frames in
   the same VBL budget, which corroborates the per-frame figure; the
   extra frames are hold frames near the new average, so the mix shift
   does not carry the result.
4. **`transform_animated_vertices` re-pipelined -- implemented.** The
   in-place morph transform staged every triple through three Y scalars:
   ~37 instructions per vertex, many two-word.  The triple now rides in
   x1/y1/x0 (all three are legal multiplier pairings against y0) with the
   matrix streamed through the static loop's own n4-rewind pattern and
   the translation loaded by the XY dual move that also fetches each
   row's first matrix element: 21 single-word instructions per vertex,
   and the `animation_vertex_x..z` staging cells retired into `tri_x0`'s
   alignment pad.  One encoding correction against the sketch: the XY
   dual move cannot encode (Rn)-Nn, so the translation cursor rewinds
   through `(r1)+n1` while the matrix keeps the single parallel
   `(r4)-n4`.  **N1 is -2, and the first build's -3 is worth recording.**
   A +Nn update replaces the final access's own post-increment, so the
   rewind is block size minus one -- the -3 walked the cursor one X word
   lower per vertex, and the resulting garbage frames ran so slow that
   the 4,000-VBL gate run died before its frame-100 dump.  The gate then
   read the PREVIOUS build's fb.res and passed -- only the armed run's
   fresh dump caught the corruption, and the file mtimes exposed the
   stale pass.  Every gate run now deletes its result files first; a
   missing dump is a failure, never a pass.  Result after the fix: **25
   words freed**, exactly the estimate (extent `$0964` to `$094B`, 116
   free), DOSBox 0/0, frame-100 `fb.res` freshly reproducing
   `d89958b3…3d16` and the armed hold freshly reproducing the frame-291
   checkpoint at 353 frames, zero failures.  The ~1.5 ms/frame cycle
   model stays unmeasured (2.4a); the FINISH window hides it either way.
5. **Survivor record write as a dual-move copy -- implemented.** The
   record write moved w5-w13 and w15-w17 one absolute load and one store
   at a time; the span scalars are now laid out in exact wire order --
   w5..w13 then w15..w17 contiguously, the UV staging and sorted corner
   levels moved behind them -- and both runs stream through one R4 cursor
   as a software-pipelined XY copy, with the w14 compose in its slot
   between them.  One correction against the audit's sketch: the dual
   move's X field encodes only X0/X1/A/B and its Y field only Y0/Y1/A/B,
   so `x0` cannot ride the Y side -- A is the pipeline register instead
   (`move a,x:(r1)+ y:(r4)+,a`), and because the Y-side load sign-extends
   A2, the X-side limited store passes A1 through bit-exactly.  No code
   walks the span block by pointer besides this copy (checked), the block
   sits outside the Y:$2A-$3E alias window, and `tri_x0`'s
   multiple-of-eight anchor is below and untouched.  Result: **25 words
   freed** (extent `$098B` to `$0972`, 77 free), DOSBox 0/0, frame-100
   `fb.res` reproducing `d89958b3…3d16` and the armed hold reproducing
   the frame-291 checkpoint.  Cycle effect unmeasured (2.4a); the path is
   pipelined behind host unpack either way.
6. **Red/green channel merge -- implemented.** Since 4.4c the two Lambert
   loops were textually identical except for their accumulator cell, and
   their clamp/depth-scale epilogues duplicated each other.  One outer
   `DO #2` now runs the shared loop body and epilogue with R3 walking the
   consecutive `shade_sum_r/g` result cells; R0 streams from the last red
   vector into the first green one exactly as before, `(r4)+n4` still
   rewinds the normal per light, and the inner loop keeps the shipped
   shape to the instruction, `jle`-to-LA included.  R3 joins
   `make_triangle_shade`'s clobber list (it was free: BUILD, the only
   caller, keeps nothing in it).  Result: **14 words freed** (extent
   `$0972` to `$0964`, 91 free), DOSBox 0/0, frame-100 `fb.res`
   reproducing `d89958b3…3d16` and the armed hold reproducing the
   frame-291 checkpoint.  Speed-neutral by construction: the instruction
   stream per channel is identical (one DO of setup traded against the
   duplicate block).
7. **Lookup triples through pointers -- implemented.** `make_triangle_area`
   and `make_triangle_zkey` unrolled three identical lookup blocks each
   over the consecutive `triangle_i0..i2`, `tri_x0..`, `triangle_z0..z2`
   cells.  Both are `DO #3` loops now: area walks R5 over the indices and
   R6 over the interleaved x/y pairs with the three near-plane flag words
   accumulating in B -- which retired the `tri_near_flags` cell (it had
   no reader outside the routine) into `tri_x0`'s alignment pad -- and
   zkey serves both sides with ONE cursor, the indexed `(r5+n5)` store
   landing each z six cells up in `triangle_z0..z2` (N5 = 5 after the
   read's post-increment), R6 then summing the triple.  R5/R6 are free in
   every caller: BUILD's shade sets its own later, classify keeps nothing
   there, and the sweep's r5-r7 lifetimes start inside `prepass_stamp`.
   Result: **38 words freed**, above the estimated 25 (extent `$094B` to
   `$0925`, 154 free), DOSBox 0/0, fresh frame-100 `fb.res` reproducing
   `d89958b3…3d16` and the armed hold freshly reproducing the frame-291
   checkpoint at 354 frames, zero failures.  Roughly speed-neutral as
   audited; these run in BUILD, both classify passes and the sweep.
8. **Cold receive paths -- implemented, one sub-item withdrawn.** The
   audit named three cuts; building them showed the first is a wash: a
   count*3 single-receive body in LOAD_VERTICES/LOAD_TRIANGLES saves four
   body words and costs exactly four premultiply words, so those loops
   stay as they are.  The other two landed: both SET_FRAME variants walk
   the consecutive projection cells through a pointer (the animated
   variant's five words in one `DO #5`; the plain variant's shared focal
   store then a `DO #3` over cx/cy/near), and the GET send loop's
   five-instruction manual counter became a hardware `DO` -- with a NOP
   as the loop's last word, since JSR may not close a hardware loop.
   Result: **12 words freed** against the estimated 20 (extent `$0925`
   to `$0919`, 166 free), DOSBox 0/0, fresh frame-100 `fb.res`
   reproducing `d89958b3…3d16` and the armed hold freshly reproducing
   the frame-291 checkpoint at 355 frames, zero failures.  One coverage
   note: the plain SET_FRAME variant is the non-animated test path that
   no gated run sends, so its three-word walk is review-verified only --
   the same status as 3.9c's transplant-verified flat arm.  The
   race-sensitive per-word GAIT/TARGET loops (2.1) were deliberately not
   touched.
9. **Residual 2.3d folds -- implemented, and the reserve is spent.** Ten
   fold groups survived the hazard check: store-previous-on-TFR in both
   index unpacks and the armed kill cursor (the parallel slot reads A1 at
   the start of the instruction, so a TFR carries the PREVIOUS result's
   store -- read-at-start working for us, where defect 4 of 2.3f is the
   same rule working against the careless), store-preNEG-value on both
   span half-height negations, the shared-constant dual-counter
   triangle_advance, the R6-walked area delta stores (the corner loop
   parks R6 exactly on tri_dx01), paired temp stores on the projection
   head's TFR/SUB, one load fold each in the classify count branch and
   span_div, and the B1-to-R0 parallel in prepass_bit_address.  The
   race-sensitive GAIT/TARGET loops were deliberately excluded.  Result:
   **24 words freed** against the audited 40-80 -- the loop restructures
   of sites 1-8 had already consumed most of what 2.3d counted -- for an
   extent of `$0919` to `$0901`, 190 free.  DOSBox 0/0; fresh frame-100
   `fb.res` reproducing `d89958b3…3d16`; the armed hold freshly
   reproducing the frame-291 checkpoint at 356 frames, zero failures.

The audit estimated 120-180 recoverable words against the 51 free at its
time.  All nine sites have since landed: **179 words freed, 40 of them
spent back on the two speed sites, the free window at 190, and the
freestanding prepass measured 19.7 ms/frame (25.6%) cheaper** -- every
step at byte-identical output against the recorded checkpoints.  That
delta was re-measured end to end on 2026-08-27, 76.88 -> 57.18 ms/frame
(section 2.4b); the 16.5 ms recorded here previously stopped at site 3,
and the later size sites turned out to buy time as well as words.  The
harvest is complete; program memory is no longer a constraint on item
19's yield work, and further P recovery would have to come from
structural changes (the chain-slope table-driving the audit deferred),
not from the instruction stream.

Three families are explicitly excluded because they change results, not
schedules:

- **Rotating the lights into object space** (the six-of-nine-MAC saving
  section 5 priority 3 already declines) rounds different intermediates,
  so quantized corner levels can move one step: an output change that
  needs a geometric re-gate, not a byte-identical optimization. The
  orthonormality caveat in the source comment stands besides.
- **Reciprocal-multiply division replacements** in `span_div` or the
  projection: the record fields are validated bit-for-bit against the
  host's own arithmetic (4.1b); truncation semantics are the contract.
- **Signed-MPY field extraction** replacing `REP`/`LSR`: packed word A
  carries the occluder flag in bit 23 and words B/C reach bit 23 whenever
  a corner-normal index is 2,048 or higher, so every use needs a pre-mask
  that eats the saving.

One data-memory note completes the audit. X and Y are exactly full by
construction -- `PREPASS_MAX` absorbs the X slack, resident Y ends at
`$3FFE` -- and the one untapped block is **Y:$0100-$01FF**: 256 words whose
mapping the sources contradict each other about (the layout note in
`trex_dsp.asm`). An empirical probe -- write, read back, verify the program
unharmed, in Hatari first and on hardware before trusting it -- would
either close the question or recover the largest free data block left. The
arithmetic that makes it interesting: 4x4 occlusion cells need a 336-word
mask pair against today's 112, and one 168-word mask fits this block whole,
with the other paid by the freed 112 plus a 56-word `PREPASS_MAX` trim to
1,279 -- still above the 1,194 measured survivor maximum, at 2.3b-style
thin headroom.

### 2.3i The 4x4-cell yield experiment -- built, measured, rejected

Item 19 and 2.3f name two suspects for the conservative yield: the
8x8-pixel cells (64 fully covered pixels before anything stamps) and the
64 coarse depth classes.  The 2.3h harvest made the first testable: its
190 freed program words are Y-addressable through the P/Y overlay, so a
4x4 configuration was built with the 168-word SEAL mask in the overlay at
`Y:$0918-$09BF` (hard program ceiling `P:$0917`), the 168-word PENDING
mask in X, and `PREPASS_MAX` trimmed 1,335 to 1,279 -- 85 over the
measured 1,194 survivor maximum, and no use of the contested
`Y:$0100-$01FF` block.  Net code cost was three words.

Every gate held: DOSBox 0/0, fresh frame-100 `fb.res` at `d89958b3…3d16`,
armed and disarmed hold runs both at `e66d4d43…b00486` -- kills stayed
invisible under the 4x finer coverage -- zero overflow, zero protocol
failures.  And for the first time both arms completed EQUAL frame counts
(357/357), which exposed a metric artifact: the recorded 8x8 yield
figures (61,697 in 2.3f, 62,920 in 2.3h site 2) came from pairs one
frame apart, and the extra disarmed frame's ~38k pixels inflated them.
The equal-frame 8x8 yield was roughly 25k pixels per run.

**The 4x4 cells measured 20,976 fewer armed pixels over 357 equal frames
-- no improvement over 8x8 -- while the freestanding prepass rose from
60.28 to 74.86 ms/frame.**  (Both figures are pre-2.4c; that section scales the
pair to roughly 118 and 147 ms/frame as arithmetic, not measurement, and the
rejection is unaffected.)  The finding: cell resolution is NOT the
binding constraint.  Sealing only happens across depth-class boundaries,
and with most of the scene collapsed into a few of the 64 coarse classes
there is nothing strictly nearer to seal against, no matter how fine the
coverage quantum.  The code is reverted; the stock 8x8/64-class
configuration stands.

The cheap first probe was built: **128 classes with the stock 8x8 masks.**
It changes `PREPASS_COARSE_BITS` from 5 to 4, so each class spans 16 host OT
buckets rather than 32; `PREPASS_MAX`, the two 56-word masks and the kill
bitmap are unchanged.  A naïve in-place 128-word counter bank would extend
from `Y:$0096` through `Y:$0115` and overwrite program memory through the
P/Y overlay.  The probe instead keeps small prepass state on-chip and places
the complete counter bank at `Y:$0940-$09BF`, immediately before the resident
indices at `Y:$09C0`.  Its active program ceiling is therefore `P:$093F`; the
candidate assembles at `P:$0901`, leaving 62 words of margin.

DOSBox assembly was clean (0 errors, 0 warnings).  A Hatari/TOS 4.02,
4-MiB-ST-RAM, DSP-emulation **correctness** gate ran 8,000 VBLs in arm-2
freestanding mode: 178 completed frames, frame-100 `fb.res` SHA-256
`d89958b3…3d16`, 741 last / 1,194 maximum area-and-box survivors, zero
prepass overflows and zero protocol failures.  This validates the counter
placement and stricter ordering rule; it was not yet a culling-yield or FPS
measurement.  The required next comparison was then run on 2026-08-28 with
the same `PREPASS.TOS`, candidate `.lod`, TOS 4.02, Falcon DSP emulation and
4 MiB ST-RAM.  Arm 0 and arm 1 were the same binary with only `prepass_arm`
patched, each under `--run-vbls 11500`.  At exactly 246 completed frames, arm
0 had written 8,355,471 pixels and arm 1 had written 8,352,955: **2,516 fewer
writes (0.030%)**.  Both had 981 packets in that final matched frame.  The
final framebuffer captures were byte-identical at SHA-256
`d89958b314c924ad6654f5e92cd29b859ab99b0c4f197170dfe8cfc0216f3d16`; both
runs reported zero overflow and zero protocol failures.

The fixed-VBL stop landed on 311 arm-0 frames and 309 arm-1 frames, so its
timers are not an equal-frame performance measurement.  They are nevertheless
an adverse indication for the external-SRAM bank: `t_packets/frame` was
50.54 versus 51.29 200-Hz ticks (about 3.7 ms/frame difference).  No physical
Falcon conclusion follows.  The negligible equal-frame yield, together with
that non-gated timing indication, does not justify the loss of on-chip memory
or the reduced P-memory ceiling.  The source and runtime LOD are therefore
reverted to the 64-class, on-chip-counter configuration.

Finer cells and finer classes together are no longer a priority: the
class-only experiment did not earn its external-memory cost.  Any later
occlusion work must use a substantially different coverage or ordering
strategy, and compare yield only between equal-frame pairs.

### 2.3j The sweep, instrumented -- why the yield is zero, and the defect the counters caught

2.3i ended with "a substantially different coverage or ordering strategy" and
no mechanism.  Before building any candidate, the sweep itself was
instrumented: six per-run counters in the previously unused prepass status
tail (`X:$3FFA-$3FFF`, `prepass_status+2..+7`), zeroed by every run and read
out by the new `CMD_PREPASS` **mode 4** (reply: `ACK_PREPASS` plus the six
words; modes 5-7 alias it; nothing is computed).  The counters are stamp
calls, stamped cells, query kills, dirty merges, query cells visited, and
stamp cells visited -- the last computed at stamp entry as ncx*nrows rather
than in the cell loop, since that walk has no early exit.  The
`-DTREX_PREPASS` host reads mode 4 after each arm-2 run, outside the
`stat_t_prepass` bracket, and writes the cumulative sums plus per-run maxima
of stamped cells and kills into `prep_sta.res`, whose magic moves to `PRE1`:
magic, frames, t_prepass, runs, surv_last, surv_max, overflow, arm, fail,
then the six sums, then the two maxima -- 17 longs.  The counter code costs
57 P words (5 of them in the query's inner loop) and is present in every
build; arms 0/1/3 never issue mode 4.

The first instrumented run measured the sweep doing something the sorted
list makes impossible, which is the second thing this section records.
Corrected emulator, `--mmu true`, arm-2, 11,500 VBLs, frame-100 `fb.res`
reproducing `d89958b3…3d16`, zero overflow, zero protocol failures; per-frame
values are the sums divided by the runs:

| per frame | pre-fix (346 fr) | **post-fix (353 fr)** |
|---|---:|---:|
| stamp calls (qualified visible survivors) | 851.0 | 842.8 |
| stamp cells visited | 5,131.6 | 5,129.5 |
| **stamp cells actually sealed** | **59.0** | **60.9** |
| query cells visited | 968.5 | 954.3 |
| query kills | 1.38 | 1.10 |
| dirty merges | **245.6** | **7.5** |
| best frame: stamped cells / kills | 194 / 31 | 194 / 31 |

**The defect: 245.6 dirty merges per run against a sorted list's possible
63.**  The sweep's class-change compare loaded the packed entry, `tfr`red it
to B and masked with `AND` -- but AND is a 24-bit operation that clears only
B1, while the full-width `CMP` against the previous class compares all 56
bits.  Entry bit 23 is triangle-index bit 11, so for the 676 triangles with
indices 2,048-2,723 the `TFR` had copied a $FF sign extension into B2, the
compare could never match, and every survivor among them spuriously took the
class-change path and merged pending coverage mid-class.  That is 2.3f
defect 2's sign-extension trap in compare form.  Beyond the wasted 112-word
merge walks, a mid-class merge is an ordering-soundness hole: it lets a
same-class, possibly farther triangle's coverage seal against a nearer
victim.  No gated frame ever showed a wrong kill -- the seal is too sparse
to reach the hazard -- but the fix is one word (`move b1,b` after the AND
rebuilds the clean extension) and it is in.  Under the standard harness form
-- same host binary, only the `.lod` swapped -- the fix moved the
freestanding instrumented prepass from 114.36 to **105.24 ms/frame**
(-9.1 ms, and 353 frames complete against 346 in the same VBL budget).
Neither figure is comparable to 2.4b's 117.70: this host binary and `.lod`
both differ from that pair, so only the delta is a result.  Kills dropped
from 1.38 to 1.10 per frame -- the removed kills are ones the premature
merges had enabled, i.e. exactly the unsound class.

**The finding item 19 needed: the stamp is the binding constraint, and it is
structural.**  843 qualified visible survivors attempt to stamp every frame;
they visit 5,130 cells and seal 61 -- 1.2% of visits, and at most 7% of the
attempting triangles can have sealed even one cell.  The mesh draws ~29
pixels per packet (2.4c) against 64-pixel cells, and triangles tile
edge-to-edge, so a cell straddling any interior mesh edge is fully inside
NEITHER neighbour: single-triangle full-cell coverage is rare at 8x8 and
does not compose across shared edges at any cell size.  The consequences are
all in the table: the seal stays so sparse that the query's
first-unsealed-cell exit fires almost immediately (954 query cells for ~900
average survivors, about 1.07 cells per query), only ~7.5 of the 64 classes
carry any pending coverage per frame, and 1.1 triangles die.  This is the
mechanical explanation for both 2.3i null results -- 4x4 cells and 128
classes each refine a mask that almost nothing can write into -- and it
disqualifies every remaining refinement of the current stamp.  A yield
mechanism has to make coverage compose across triangles (the offline model's
per-pixel union, reachable only at pixel-exact granularity, e.g. row-run
stamping with the host's own fill rule) or make single triangles big enough
to stamp (authored interior proxy occluders).  Anything else re-measures
zero.

Gates for both the instrumentation and the fix, all on the corrected
emulator with `--mmu true` and fresh result files: DOSBox assembly 0/0;
P extent `$094B` instrumented, `$094C` with the fix, against the `$09BF`
ceiling; plain-build frame-100 `fb.res` at `d89958b3…3d16` with the new
`.lod`; arm-2 frame-100 identical; armed and disarmed hold runs (dump frame
291, single-byte-verified patches at the re-derived offsets) both at
`e66d4d43…b00486` with zero failures -- armed kills stay invisible across
the fix.  The 441/437-frame pixel counters (17,534,226 disarmed,
17,318,713 armed) are not an equal-frame pair and are recorded only as the
usual armed-writes-fewer direction check.

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

Every millisecond in this document outside section 2.4b comes from the stock
Hatari **v2.6.1** release binary (compiled 2025-08-15 — the version banner
recorded in every `hatari_runs/` log), and the question of what its timing model
contains had never been asked. It was, at the source. The findings below are
verified against the Hatari source tree, which is not vendored into this
repository; the checkout used is `../F030Arcade/third_party/hatari`. They do not
make the figures wrong, but they bound what may be concluded from them.

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
- **The DSP ran at twice its real clock.** This bullet previously recorded the
  opposite — "the DSP ratio is as intended, contrary to first impression" — and
  that was wrong; it is corrected here (2026-08-27). The earlier reading stopped
  at the call sites, which do look correct: `newcpu.c` passes
  `2 * cpu_cycles * 2 / CYCLE_UNIT` from ten sites and `blitter.c` passes
  `2 * BlitterVars.op_cycles`, all already scaled to the DSP clock. But
  `DSP_Run()` then applied `DSP_CPU_FREQ_RATIO` (`src/falcon/dsp.h:29`, value 2)
  a **second** time, so the DSP56001 received 4 clocks per 68030 clock instead
  of the Falcon's 2 — 32 MIPS instead of 16. DSPBench v3.0b (dml) measured ~200%
  of a real Falcon on all four of its ALU/SRAM tests before the fix and ~100%
  after, in every P/X/Y internal/external combination; that the factor is
  uniform confirms the per-instruction cycle model and its external-memory
  penalty were already exact, and only the rate at which cycles were handed out
  was wrong. The same fix replaces the host-port wait-state model — the entire
  CPU-to-DSP timing model, since `dsp_core.c` has no cycle accounting — with a
  per-direction, per-size table charged once per access, read {3, 7, 10} and
  write {4, 3, 7} for byte/word/long, dropping RMS error over the eleven
  DSPBench host tests from 28.3pp to 10.4pp. What remains open is unchanged:
  `dsp_cpu.c:66` still states outright that cycle counting was simplified and
  the external DSP RAM's BCR wait states ignored — this program lives in that
  external RAM. Section 2.4b measures what the correction costs.
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

**Run, 2026-08-28.** Stock v2.6.1, `trex_fullm.tos`, full mesh, frame-100
`fb.res` byte-identical either way; 266 frames without `--mmu` against 274 with
it, 34,134 against 34,153 pixels per frame, so the ranges are comparable to
0.1%:

| Stage | with `--mmu` | without `--mmu` | Delta |
|---|---:|---:|---:|
| DSP readback + packet build | 176.19 ms | 178.82 ms | +2.63 |
| Rasterizer | 244.93 ms | 381.35 ms | **+136.42** |
| Framebuffer clear | 14.51 ms | 14.72 ms | +0.21 |
| DSP set_frame | 12.76 ms | 14.04 ms | +1.28 |
| Ordering Table insertion | 2.55 ms | 4.29 ms | +1.74 |
| **Total** | **451.4 ms** | **593.6 ms** | **+142.2** |

**The charge lands almost entirely on the rasterizer**, exactly where this
section predicted: +55.7% on that stage against +1.5% on the packet stage.
That is the bracket the experiment was proposed to produce. It is *not* proof
that the whole 136.4 ms is word MUL/DIV — table 23's cost model was not read,
only its effect measured — but it bounds how much arithmetic table 35 gives
away, and it says the give-away is concentrated in the one stage 2.4a already
called the least trustworthy.

**Operational consequence: `--mmu true` is load-bearing.** Every millisecond in
this document was taken with it, and omitting it inflates the full-mesh
baseline from 451.4 to 593.6 ms in a way that looks like a broken build rather
than a different core. Any run compared against a figure here must pass it.

### 2.4b What the DSP-clock fix costs, measured

The corrected emulator of 2.4a was run against the freestanding prepass
configuration used throughout 2.3h: arm-2, dump frame 100, 11,500 VBLs, TOS
4.02, 4 MB, one host binary (`PREPASS.TOS`) with only the `.lod` swapped.
"Stock" is Hatari v2.6.1, the release binary; "fixed" is v2.6.1-devel carrying
the DSP clock and host-port change. Both emulators produce a **byte-identical**
frame-100 `fb.res` (`ef53b8c2…69a6`) from the same `.lod`, so the change moves
timing only — no rendering decision depends on it.

| `.lod` | Stock v2.6.1 | Fixed v2.6.1-devel | Ratio |
|---|---|---|---|
| pre-harvest, `596fc74` | 76.88 ms/frame | not run | |
| pass-2 classify cache, `5e6428a` | 60.24 ms/frame | not run | |
| post-harvest HEAD, `261c3d3` | **57.18 ms/frame** | **117.70 ms/frame** | **2.058** |

The two stock re-measurements reproduce figures already recorded in 2.3h to
within 0.16% (76.88 against 76.76) and 0.07% (60.24 against 60.28). That
agreement is what licenses reading the fixed column against the rest of this
document rather than treating it as a separate harness.

Three results follow:

- **Every DSP-side figure in this document is optimistic by ~2.06x.** The factor
  sits slightly above the 2.00 of the clock fix alone because the host-port
  recalibration ships in the same build and the prepass is host-port heavy. The
  68030-side figures are untouched: the fix does not reach the CPU core.
- **Whole-frame cost rises by only 23.9%.** The same VBL budget completes 321
  frames under stock and 259 under the fixed build. The DSP is a minority of
  frame time — the rasterizer still dominates — so doubling DSP time does not
  double the frame. This is the number that bounds how much the correction
  actually changes the optimization picture, and it is much smaller than 2x.
- **The harvest of 2.3h is worth more than recorded, not less.** HEAD measures
  57.18 ms/frame against the 60.28 recorded at site 3, so the size sites bought
  time as well as words; 2.3h and roadmap item 21 are corrected accordingly.

These remain emulator timings, not physical-Falcon timings, and the separation
required by `AGENTS.md` still applies. What the fix buys is that the DSP side is
now calibrated against DSPBench on real hardware instead of running at double
rate; the 68030 side carries every caveat of 2.4a unchanged.

### 2.4c The whole-frame baseline at the corrected clock, and what the packet stage is made of

2.4b corrected only the freestanding prepass configuration. The **whole-frame
full-mesh baseline had never been re-taken**, so every stage share, every
optimization ranking and every SSI argument in this document rested on a ledger
where the DSP ran at twice a Falcon's clock. It has now been re-taken, and the
result reorders the roadmap.

Method: one binary, `hatari_runs/gate/TREX_M68.TOS`, byte-identical to
`TREX/m68030/trex_fullm.tos` — the binary 8.2a measured — with the committed
`trex_dsp.lod`, `--mmu true`, matched frame counts, and the frame-100 `fb.res`
reproducing `d89958b3…3d16` on every run reported here.

| Stage | Stock, DSP at 2x (274 fr) | **Corrected (272 fr)** | Delta |
|---|---:|---:|---:|
| DSP readback + packet build | 176.19 ms | **260.40 ms** | **+84.21** |
| Rasterizer | 244.93 ms | 244.61 ms | -0.32 |
| Framebuffer clear | 14.51 ms | 14.58 ms | +0.07 |
| DSP set_frame | 12.76 ms | 12.90 ms | +0.14 |
| Ordering Table insertion | 2.55 ms | 2.78 ms | +0.23 |
| **Total** | **451.4 ms / 2.215 FPS** | **535.7 ms / 1.867 FPS** | **+84.3** |

Workloads match to 0.09% (34,153 against 34,121 pixels per frame). The stock
column reproduces the 460.0 ms baseline of section 2 to 1.9% and its 243.9 ms
rasterizer to 0.4%, which is what licenses reading the corrected column against
the rest of this document.

**Every 68030-side stage is flat and the entire +84.2 ms lands in one stage.**
That is 2.4b's "the fix does not reach the CPU core" confirmed on the whole
renderer instead of one command, and it is the measurement's own control: a
result that moved the rasterizer would have meant the pair was not comparable.
A corroborating detail is that `set_frame` barely moves (+0.14 ms) while the
readback moves +84.2 — the recalibrated host-port table charges reads far more
than writes (word: read 7, write 3), the animation send is write-dominated and
the readback is read-dominated.

**The packet stage is now the largest single item in the frame — 48.6%, ahead
of the entire rasterizer at 45.7%.** On the stock ledger it was 40.4% against
59.6%.

#### The wire, measured rather than inferred

Commit `d9c734ca` exposes the host-port wait-state table through the
environment (`HATARI_DSP_WS_R1/_R2/_R4/_W1/_W2/_W4`, byte/word/long, read and
write). Sweeping it isolates the wire directly. Same binary, same `.lod`,
`--mmu true`, corrected emulator:

| Host-port wait states | frames | px/frame | packet stage | set_frame | rasterizer | frame |
|---|---:|---:|---:|---:|---:|---:|
| all 0 | 272 | 34,121 | 246.25 ms | 11.53 ms | 244.67 ms | **519.7 ms** |
| calibrated (3,7,10 / 4,3,7) | 272 | 34,121 | 260.40 ms | 12.90 ms | 244.61 ms | **535.7 ms** |
| all 10 | 270 | 34,103 | 261.87 ms | 15.31 ms | 244.39 ms | **539.4 ms** |

The rasterizer reads 244.67 / 244.61 / 244.39 and the clear 14.60 / 14.58 /
14.69 across all three — flat to 0.1%, which is the control for this sweep too.

Two numbers fall straight out:

- **The host-port wait-state budget for the entire frame is 15.5 ms** (14.15 in
  the packet stage, 1.37 in `set_frame`). A completely free host port measures
  **519.7 ms / 1.924 FPS** against 535.7 / 1.867: transport work of any kind is
  worth **+0.06 FPS** in this model.
- The 0-to-10 slope gives the access count, since each unit is one 16 MHz cycle
  charged once per access: **~25,000 host-port accesses per frame in the packet
  stage and ~6,050 in `set_frame`**. That corroborates 8.2a's ~26,800-word
  estimate and section 8's 4,933-word animation figure by an independent route,
  and it puts the calibrated cost at 9.06 cycles (0.566 us) per access.

#### The resulting split

Upstream's replaced model charged 4 per byte after the first (byte 0, word 4,
long 12) against the calibrated 3/7/10. At the measured 9.06-cycle average the
mix is long-dominated, where upstream was the *more* expensive of the two, so
the host-port recalibration accounts for roughly -2 ms and **the DSP clock
accounts for essentially all of the +84.2 ms**:

| Component of the 260.40 ms packet stage | ms | share |
|---|---:|---:|
| **Exposed DSP compute / stall** | **~173** | **66%** |
| Host CPU work: record unpack and packet build | ~73 | 28% |
| Host-port wait states | 14.2 | 5% |

The DSP figure is 168-173 ms depending on the access-size mix assumed for the
upstream comparison; the conclusion does not turn on which end is taken.
**Exposed DSP time is ~32% of the whole frame** — larger than the row/span
walk, larger than the pixel loops, second only to the rasterizer as a whole.

#### What this supersedes

**The 2.3 us/word host-port calibration is not a transport cost and must stop
being used as one.** It comes from roadmap item 3, where making the index list
resident removed 25.0 ms; that change removed the DSP's receive-and-store work
along with the wire, so the figure is an end-to-end stage delta, not a wire
rate. Multiplying it by a word count — as sections 8, 8.2 and 8.2a all do to
reach a "~62 ms wire" — overstates the transport share by roughly 4x against
the 14.2 ms measured here. Those passages are corrected in place.

#### Caveats

- 2.4a's bound is unchanged and now matters more, not less: this core charges
  **no instruction execution time**, so the TOS `Dsp_BlkUnpacked` loop's own
  instruction cost is invisible. **The 14.2 ms is the modelled wire cost and is
  therefore a floor**, not a physical-Falcon transport figure. Roadmap item 14
  remains the only thing that can size the real PIO cost.
- Neither Videl bus contention nor ST-RAM burst behaviour is modelled, so the
  ~73 ms host CPU term carries 2.4a's usual caveats in the other direction.
- The measured binary carries **no occlusion prepass**. The release adds one
  whose corrected freestanding cost is 117.70 ms/frame (2.4b), against a
  FINISH window that this section shows is DSP-bound already.
- Hatari's CPU and DSP profilers were tried first and are unusable here: the
  `DspInstr` variable reads 0, and enabling either profiler makes the corrected
  build die on continue. The wait-state sweep replaced them.

### 2.4d The scheduling question, answered: what the window absorbs, and what a cold buffer costs

2.4c showed the packet stage is ~173 ms of exposed DSP compute, and that the
case for SSI/DMA is therefore overlap rather than transport. That raised two
objections which decide whether overlap is worth building, and **both are
answerable without a Falcon**. Both were run.

#### Can the schedule hide DSP work at all? Yes -- 97.5% of it

The occlusion prepass is an ideal probe: a known quantity of DSP work, with a
known freestanding cost, switched into the FINISH window by a single byte.
`hatari_runs/arm0_fixed` and `arm1_fixed` are the same `PREPASS.TOS` differing
in exactly one byte at file offset 9604 (`prepass_arm`, 0 against 1) -- the
equal-layout A/B this document requires -- on the corrected emulator with
`--mmu true`, both reproducing the recorded hold-frame hash `e66d4d43...`:

| Stage | Disarmed (407 fr) | Armed (408 fr) | Delta |
|---|---:|---:|---:|
| DSP readback + packet build | 241.77 ms | 245.15 ms | +3.38 |
| Rasterizer | 234.32 ms | 233.65 ms | -0.67 |
| Framebuffer clear | 14.53 ms | 14.57 ms | +0.04 |
| DSP set_frame | 12.64 ms | 12.77 ms | +0.13 |
| Ordering Table insertion | 2.20 ms | 2.30 ms | +0.10 |
| **Frame** | **505.9 ms / 1.977 FPS** | **508.9 ms / 1.965 FPS** | **+3.0** |

Workloads match to 0.02% (38,510 against 38,518 pixels per frame).

The same prepass, the same `.lod`, costs **117.70 ms/frame** freestanding in
arm-2 (2.4b). Scheduled into the FINISH window it costs **3.0 ms of frame
time**: **114.7 ms hidden, 97.5% absorbed.** The window has deep spare DSP
capacity and the mechanism that exploits it -- the FINISH hook plus roadmap
item 12 stage 1's cross-frame animation send -- already exists and needed no
new transport.

#### Then why is the record work exposed? Because the DSP cannot buffer a frame

Not for want of window: the rasterizer is ~234 ms here and the record work is
~173 ms, so it would fit. The obstacle is memory. One frame of records is
**1,149 survivors x 18 words = 20,682 words**, against a *total* X space of
16,384 words that 4.2 and the DSP README show is already allocated to the top;
`triangle_out` is 576 words, exactly one 32-triangle chunk. The DSP physically
cannot hold a frame's records, which is why the chunk protocol exists.

So the records must leave the DSP as they are produced, and during the
rasterization window the host is busy and cannot service that transfer. **That
is the case for SSI/DMA, and it is a structural one rather than an arithmetic
one**: it is the only mechanism that can drain the DSP into host memory while
the CPU rasterizes. The 14.2 ms of PIO it also deletes is incidental.

#### Does a cold DMA buffer cost extra? No -- bounded at approximately zero

Roadmap item 12 stage 2 attributes its regression partly to "a deferred unpack
re-reads 59 KB cold", and an SSI record stream would hand the CPU 80.8 KiB to
read cold at the frame boundary. Disabling the 68030 data cache entirely
(`--data-cache false`, which the `--mmu` core honours through
`read_dcache030_mmu_*`) is a **stronger** perturbation than a cold buffer --
every read misses, always -- so it bounds the penalty from above. Same
`TREX_M68.TOS`, same `.lod`, gate hash clean on both:

| Stage | D-cache on (272 fr) | D-cache off (268 fr) | Delta |
|---|---:|---:|---:|
| DSP readback + packet build | 260.40 ms | 258.60 ms | **-1.80** |
| Rasterizer | 244.61 ms | **316.53 ms** | **+71.92** |
| Framebuffer clear | 14.58 ms | 14.78 ms | +0.20 |
| DSP set_frame | 12.90 ms | 12.76 ms | -0.14 |
| Ordering Table insertion | 2.78 ms | 2.74 ms | -0.04 |
| **Frame** | **535.7 ms / 1.867 FPS** | **605.8 ms / 1.651 FPS** | **+70.1** |

Workloads match to 0.04% (34,121 against 34,109 pixels per frame, 1,160 against
1,161 packets).

**The packet stage does not use the data cache.** Removing it moves the
unpack/packet-build path by -1.8 ms -- negative, inside frame-mix noise -- in
the same run where the rasterizer loses 71.9 ms. That 71.9 ms is the control:
it proves the knob works and that the model is sensitive to exactly this
effect.

The mechanism is plain once measured: the unpack writes a 2.3 KB chunk and
reads it back through a **256-byte** data cache, so by the time the read
reaches the start, the end has evicted it. Every read misses today. A DMA'd
80.8 KiB buffer read cold also misses every read. There is no cache benefit to
lose, so there is no penalty to pay.

**Consequence for item 12.** Its stated cold-re-read cause does not survive
measurement. Stage 2's 14.2 ms must come from the other causes it names -- the
service-hook overhead added to the rasterizer, and breaking 4.1d's DSP/host
chunk interleave. Both are *scheduling* effects, and neither is inherited by a
design where the transfer is done by hardware and the unpack happens in one
block at the frame boundary.

#### Separate finding: the data cache is worth 71.9 ms to the rasterizer

That is 29% of the rasterizer and 13% of the frame, and it had never been
measured. Two consequences. The rasterizer's remaining time is substantially
data-cache-bound, which is a lead for the next pass in the series of item 11
and section 3.9 -- and unlike the instruction-cache work, nothing has yet been
done about data locality in the texture/CLUT path. And any change that
disturbs that locality is expensive by the same amount, which is a sharper
version of the warning section 2 already gives about layout.

#### Where the SSI case stands after both experiments

| Question | Answer | Basis |
|---|---|---|
| Can the schedule hide DSP work? | Yes, 97.5% of 117.7 ms | prepass A/B, above |
| Is there window capacity? | ~234 ms rasterizer against ~173 ms record work | 2.4c stages |
| Why not hidden today? | DSP cannot buffer a frame: 20,682 words against a full 16,384-word X space | memory map |
| Does a cold DMA buffer cost extra? | No, bounded at ~0 | data-cache A/B, above |
| What is the transport worth? | 14.2 ms | 2.4c wait-state sweep |
| What is the overlap worth? | ~~up to ~173 ms: 362.7 ms / 2.76 FPS~~ **corrected by 2.4f: capped by the window at 112.5 ms, so 423.2 ms / 2.36 FPS** | 2.4f capacity sweep |

**Every emulator-answerable objection to the overlap design has now been
tested, and none of them killed it.**

#### What is still not answered

- **DMA bus contention is untouched and is now the only significant unknown on
  this path.** The 68030 and the DMA channel would contend for ST-RAM, and
  2.4a records that this emulator models no Videl contention either. Hardware
  only; roadmap item 14.
- **The cold-read bound is a statement about this memory model** -- but a
  better-founded one than first written. 2.4a notes ST-RAM is modelled without
  burst and flagged that a bursting Falcon would be faster than the model.
  **The Falcon does not burst** (section 3.10 and its reference): the 68030
  reaches ST-RAM over a 16-bit bus with no burst support, so a cache line fills
  a word at a time there too. The emulator is right on this point and the
  "approximately zero" transfers better than this bullet originally allowed.
  It remains an emulator result, not a Falcon measurement.
- The 2.76 FPS ceiling assumes the exposed DSP term goes to zero. Any real
  design leaves some of it, and pays whatever contention costs.

### 2.4e The release build, measured at last

Every timing in this document up to here belongs to a *diagnostic* build.
`TREX.TOS` adds `-DTREX_PREPASS -DTREX_RELEASE -DTREX_FPS` on top of
`-DTREX_RUN`, and section 2 has said since the release existed that its table
"is not a release timing claim". It is measured here.

**How, and why not the obvious way.** The release defines `TREX_RUN`, which
zeroes `stats_flush_enabled`, so it writes no `render_stats.res` and cannot be
timed as it ships. The obvious move -- rebuild without `TREX_RUN` -- is
**unsound**, and the Makefile comment asserting otherwise was wrong (it is
corrected in the same change as this section). `TREX_RUN` does keep the two
flags at equal `dc.l` size, but it *also* drops the
`bsr trex_write_render_stats` from `trex_shutdown`, which shifts the text after
it: `cmp -l` between `TREX.TOS` and the same source without `TREX_RUN` reports
**3,681 differing bytes in a 9,948-byte text section**, mostly address operands
moved by two. Section 2 records eight bytes of text moving the rasterizer
28.1 ms, so that comparison cannot carry a timing.

What is sound is patching the linked binary: setting `stats_flush_enabled` to 1
gives a binary differing from the shipped release in **exactly one byte**,
layout-identical by construction -- the same discipline as 2.3f's `prepass_arm`
patch and 3.8's one-byte opaque gate.

**The offsets are build-specific, and the ones first published here are now
stale.** They read 1,177,883 and 1,177,887 when this section was written; on
the current `TREX.TOS` the correct bytes are **1,178,137**
(`stats_flush_enabled`) and **1,178,141** (`framebuffer_dump_enabled`), 254
further on. Following the old numbers patches unrelated data, and the run then
writes no `.res` at all rather than failing loudly.

Re-derive from the link map rather than by `cmp -l` against a no-`TREX_RUN`
build -- it is cheaper, and it does not rest on a second build's layout:

```bash
./tools/vlink/vlink TREX/m68030/build/TREX.o -tos-fastload -b ataritos -s \
  -e start -M/tmp/trex.map -o /tmp/TREX_relink.TOS
cmp /tmp/TREX_relink.TOS TREX/m68030/TREX.TOS   # must be identical
grep stats_flush_enabled /tmp/trex.map          # linked address
```

File offset = linked address + 28 for the TOS header, and the flag is the
**low byte** of that longword (+3). The two flags are adjacent zero longwords,
which identifies them on sight; and a run whose patch landed writes
`render_stats.res`, which is the functional check to take before trusting any
number from it.

Measured on the corrected emulator, `--mmu true`, 270 frames on both sides,
workloads matched to 0.04% (34,103 against 34,091 pixels per frame):

| Stage | Diagnostic (3.11) | **Release** | Delta |
|---|---:|---:|---:|
| DSP readback + packet build | 235.31 ms | 239.04 ms | +3.72 |
| Rasterizer | 240.65 ms | 241.46 ms | +0.81 |
| Framebuffer clear | 14.56 ms | 14.59 ms | +0.04 |
| DSP set_frame | 13.07 ms | 13.24 ms | +0.17 |
| Ordering Table insertion | 2.39 ms | 2.39 ms | +0.00 |
| present + FPS overlay | 0.02 ms | 0.06 ms | +0.04 |
| **Frame** | **506.4 ms / 1.975 FPS** | **511.2 ms / 1.956 FPS** | **+4.8** |

**The release costs 4.8 ms over the diagnostic build**, and **3.72 ms of that
is the occlusion prepass** -- independently consistent with 2.4d's armed/
disarmed A/B, which put it at +3.38 ms in the packet stage and +3.0 ms overall
on a different binary pair. **The FPS overlay costs 0.04 ms per frame**, which
is what the design intended: it draws into the present stage, after the
rasterizer timer closes. The rasterizer's +0.81 ms is not the prepass making
work (armed culling makes slightly *less*, as 2.4d shows) but the release's own
text layout -- `TREX_RELEASE` alone changes the `.LOD` filename literal from
twelve bytes to nine -- and it sits well inside the band section 2 documents
for layout effects.

**Cross-checked against the program's own readout.** `gpu_draw_fps` is
instantaneous, `20000/ticks` at the 200 Hz tick's 5 ms resolution. Dumping
frame 100 from the release (both flag bytes patched) shows **01.86**, i.e. a
~537 ms frame, against the 511.2 ms mean over 270. That is the expected
relationship rather than a discrepancy: frame 100 is the close-up checkpoint,
chosen as the `fb.res` gate precisely because it covers an order of magnitude
more pixels than the rest of the sequence. The render is intact and the overlay
is legible, so this also confirms the release path end to end -- prepass armed,
`TREX.LOD` loaded under its release filename, page flip and overlay all working.

The caveats of 2.4a apply unchanged, and this is still an emulator figure: no
release timing has been taken on a Falcon either.

### 2.4f The cross-frame window, sized: 112.5 ms spare with the prepass armed

2.4d proved the FINISH window absorbs DSP work — 114.7 ms of the prepass's
117.70 — but it could not say **how much room is left**, and that number is
what decides roadmap item 15. A window with a few spare milliseconds makes
SSI/DMA pointless; a window with a hundred makes it the largest remaining item.
The prepass A/B cannot answer it, because it reports one point on a curve and
leaks 3.0 ms, which is equally consistent with "just barely fits" and "fits ten
times over".

#### The instrument

A calibrated load of settable size, hooked at the very END of
`command_finish_animated_frame`, after `prepass_run` and
`cache_light_directions_x` have both released the `prepass_order` overlay so it
can interact with neither. It touches **no memory at all**:
`PROBE_OUTER` x 32 NOPs per unit under a hardware `DO`. That is deliberate — a
load with its own X/Y traffic would confound window capacity with bus
contention, so this measures the window's **time** capacity and says nothing
about contention.

`y:probe_units` is a `dc` sitting in one of the four retired pad words after
`prepass_tp_save`, so **no other symbol moves** and the assembler emits it as
its own one-word `_DATA Y 00DB` block. The whole sweep is therefore driven by
patching **one word of the linked `.lod`**
([`tools/probe_units.py`](tools/probe_units.py)): every point shares a
byte-identical host binary *and* a byte-identical DSP program. That is a
stronger equal-layout guarantee than the one-byte host patches of 2.3f and
2.4e, which at least changed a host data byte.

A shipping build sets `probe_units = 0` and pays three instructions per frame,
the same contract the prepass hook states. Program extent moved `P:$094D` ->
`P:$0979`, leaving **70 words** below the `P:$09BF` ceiling of 4.2.

#### Why the sweep needs no freestanding mode

Let frame *i* have spare capacity *W_i*. A load *L* leaks `max(0, L - W_i)`, so

```text
leak(L) = E[max(0, L - W_i)]
```

which is convex, lies **above** its own asymptote everywhere, and tends to
`L - E[W]` once *L* exceeds every frame's capacity. The saturated tail is a
straight line whose **slope calibrates the millisecond axis** and whose negated
intercept **is the mean spare capacity**. Both fall out of data taken in the
measurement's own configuration, so there is no run-now mode, no new host
command, and no host code at all — the reason this probe adds nothing to the
68030 side that could move its layout.

#### Method

`trex_prepass.tos`, corrected emulator, `--mmu true`, `prepass_arm` patched at
file offset 10053 and read back. Frame-mix contamination is the trap here: the
choreography's per-frame pixel workload varies by an order of magnitude, so a
mean over 117 frames is not comparable with one over 108. The driver therefore
**searches the VBL budget until every point lands on exactly 200 frames**
rather than fixing the budget. All points below report **200 frames and an
identical 29,101 px/frame** (29,110 disarmed), and **every run in all four
sweeps produced the same `fb.res` hash `d89958b3…3d16`** — the probe changes
timing and nothing else, at loads up to 523 ms.

#### The measurement

Prepass **armed**, the shipping configuration, 128-cycle unit:

| units | load ms | frame ms | leak ms | absorbed | absorbed % |
|---:|---:|---:|---:|---:|---:|
| 0 | 0.0 | 502.45 | 0.00 | — | — |
| 8,000 | 63.9 | 503.57 | 1.12 | 62.7 | 98.2% |
| 16,000 | 127.7 | 523.75 | 21.30 | 106.4 | 83.3% |
| 24,000 | 191.6 | 581.52 | 79.07 | 112.5 | 58.7% |
| 32,000 | 255.4 | 645.42 | 142.97 | 112.5 | 44.0% |
| 48,000 | 383.1 | 773.10 | 270.65 | 112.5 | 29.4% |
| 65,535 | 523.1 | 913.08 | 410.63 | 112.5 | 21.5% |

A finer sweep on the 32-cycle build maps the region that matters:

| load ms | 8.0 | 16.0 | 23.9 | 31.9 | 47.9 | 63.9 | 79.8 | 95.8 | 111.8 | 130.8 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| leak ms | 0.07 | 0.05 | 0.12 | 0.15 | 0.32 | 1.15 | 2.45 | 6.22 | 12.67 | 23.20 |
| absorbed % | 99.1 | 99.7 | 99.5 | 99.5 | **99.3** | 98.2 | 96.9 | **93.5** | 88.7 | **82.3** |

**The rasterizer reads 230.57–231.25 ms across all 25 runs** — flat to 0.3%
while frame time nearly doubles. That is this sweep's control, and it is the
same control 2.4c's wait-state sweep used.

#### Results

- **Mean spare capacity with the prepass armed: 112.5 ms/frame.** Fitted from
  the saturated tail; the four tail points recover it as 112.53, 112.53, 112.48
  and 112.52.
- **With the prepass disarmed: 221.3 ms/frame** (tail points 221.36, 221.30,
  221.30, 221.34).
- **The millisecond axis is measured, not modelled: 7.982 and 7.981 us/unit on
  the two sweeps against a nominal 8.000** (128 cycles at 16 MIPS) — **−0.22%
  and −0.24%.** This is also an independent confirmation of commit `d9c734ca`'s
  corrected DSP clock, arrived at from frame times rather than from the
  emulator's own cycle accounting.
- **The two independently assembled probe builds agree.** 63.9 ms of load
  absorbs 62.7 ms on the 32-cycle build and 62.7 ms on the 128-cycle build.

#### Two cross-checks against previously published numbers

`E[W]` disarmed minus armed is **108.8 ms** against the prepass's 117.70 ms
freestanding cost (2.4b). These are **not** required to be equal and the
direction is predicted: since `E[max(0, W-P)] >= E[W] - P`, the apparent
reduction must be **less** than the true cost, bounded below by
221.3 − 117.7 = 103.6 ms. The measured 112.5 sits inside that bound.

Arming the prepass costs **+4.35 ms** here (498.10 -> 502.45) against 2.4d's
+3.0 ms on the hold-291 prefix — same sign, same order, different frame mix.
Armed also writes fewer pixels (29,101 against 29,110), the direction 2.3f
requires of sound culling.

#### What this changes

**The knee is soft, and that is a result, not noise.** Absorption degrades from
99% to 82% over the 48–131 ms range rather than falling off a cliff, because
window capacity varies frame to frame with the rasterizer's own load. There is
a *distribution* of capacity, not a number, and 112.5 ms is its mean. Anything
scheduled into the window should be sized against the **99% column (~48 ms)**,
not against the mean.

**2.4d's overlap ceiling is not reachable.** Its table offers "up to ~173 ms:
362.7 ms / 2.76 FPS" for a perfect transport, on the assumption that the
exposed DSP term can go to zero. It cannot: the window caps what any transport
can hide at 112.5 ms, against ~246 ms of total record compute. That row is
corrected in place. A perfect SSI/DMA transport on this workload is worth
**535.7 − 112.5 = 423.2 ms / 2.36 FPS**, not 2.76 — still the largest single
item on the open roadmap, but 0.4 FPS smaller than advertised, and that is
before the DMA bus contention of item 14, which remains unmeasured.

**The window is made of rasterizer time, so item 11 spends it.** Every
millisecond the rasterizer gives up is a millisecond of window gone. The
campaign that took the rasterizer from 517.3 to 319.8 ms also cut the capacity
of the window that item 15 wants to fill. The two items are in direct
competition and this had not been stated.

#### The resident probe costs nothing, re-measured on the release

The probe stays in the shipping `.lod` at `probe_units = 0`, so its cost had to
be shown rather than argued. The release re-measured by 2.4e's method on the
**current** artefacts -- `TREX.TOS` unchanged, `TREX.LOD` carrying the probe --
at a matched frame count:

| | 2.4e (before) | with the probe `.lod` |
|---|---:|---:|
| frames | 270 | 270 |
| px/frame | 34,103 | 34,094 |
| DSP readback + packet build | 239.04 ms | 239.87 ms |
| Rasterizer | 241.46 ms | 240.20 ms |
| Framebuffer clear | 14.59 ms | 14.52 ms |
| DSP set_frame | 13.24 ms | 13.00 ms |
| Ordering Table insertion | 2.39 ms | 2.63 ms |
| **Frame** | **511.2 ms / 1.956 FPS** | **510.83 ms / 1.958 FPS** |

Workloads match to 0.03%; the frame moves **−0.37 ms, or −0.07%**, which is
inside the run-to-run band. The neighbouring 271-frame point reads 511.13 ms /
1.956 FPS, reproducing 2.4e's figure exactly. Three DSP instructions per frame
is what it costs, as the hook's comment claims.

#### Caveats

- The load has **no memory traffic**. Real record work would contend with the
  host for ST-RAM through the same 16-bit bus, so 112.5 ms is an upper bound on
  what real DSP work would fit. Bounding that gap needs item 14's hardware.
- 2.4a applies unchanged: this core charges no instruction execution time, and
  none of this is a Falcon measurement.
- Measured on `trex_prepass.tos` over frames 0–199, not on the release binary
  over the full choreography.
### 2.4b The DSP ran at twice Falcon speed; re-measured on a corrected emulator

Section 2.4a bounded what the measuring emulator charges for and cleared the
DSP clock rate. That clearance was wrong, and it was wrong in the direction
that matters most to this pipeline: **stock Hatari grants the Falcon DSP four
clocks per emulated 68030 clock instead of two**, so the DSP56001 ran at 32
MIPS against the Falcon's 16. Every caller already scales CPU cycles by the
ratio before calling `DSP_Run` — `src/cpu/newcpu.c` passes
`2 * cpu_cycles * 2 / CYCLE_UNIT` at ten sites, `src/blitter.c` passes
`2 * BlitterVars.op_cycles` — and `DSP_Run` then applied it a second time in
`save_cycles += nHostCycles * 2`. The per-instruction cycle model was already
exact, external-RAM penalty included; only the rate at which cycles were handed
out was doubled.

The corrected emulator is the `AnimaInCorpore/hatari` build vendored in the
sibling `F030Arcade` repository at `third_party/hatari`, branch `main` at
`f0736b24` (`v2.6.1-476-gf0736b24`) with a local one-line change to
`DSP_Run()`. It carries a second, coupled fix: the CPU-to-DSP host port. Stock
charges wait states only for the second and later bytes of an access; the
corrected build replaces that with a per-direction, per-size table charged once
per access — read 3/7/10 and write 4/3/7 clocks for byte/word/long
(`DSP_HostPort_WS_Read` / `_Write` in `src/falcon/dsp.c`, overridable through
`HATARI_DSP_WS_R1`..`_W4`). Fixing the DSP without the port is not an option:
with the DSP at true speed and the port untouched, the CPU outruns it in a way
hardware never does.

**The calibration behind that build is not this repository's measurement.** It
is recorded in `F030Arcade/hatari.md` against DSPBench v3.0b with real-Falcon
reference columns: stock lands at ~200% of hardware MIPS in all four P/X/Y
internal/external combinations, the corrected build at ~100% (16.045 / 8.021 /
16.045 / 5.347 Mips against 16.000 / 8.000 / 16.000 / 5.333), and the RMS error
over the eleven host-port tests falls from 28.3pp to 10.4pp. Cite it as that
repository's result. What follows is this repository's.

#### The controlled A/B

One binary, `make trex_m68030`, byte-identical to the build from commit
`4ea4f3a` (`cmp` against a clean worktree build; the SSI work in the tree is
entirely inside `ifd TREX_SSI_*` and assembles to nothing here). One command
line. The same 265-frame prefix both times, converged exactly by adjusting
`--run-vbls` until `render_stats.res` reports 265 completed frames. **Only the
emulator binary differs.**

| Stage | stock 2.6.1 | corrected DSP + host port | Delta |
|---|---:|---:|---:|
| DSP set_frame | 12.8 ms | 13.2 ms | +0.4 ms |
| DSP readback + packet build | 175.6 ms | **259.7 ms** | **+84.1 ms** |
| Framebuffer clear | 14.5 ms | 14.5 ms | 0.0 ms |
| Ordering Table insertion | 2.6 ms | 2.3 ms | -0.3 ms |
| Software span rasterizer | 243.8 ms | 244.0 ms | +0.2 ms |
| Present | 0.0 ms | 0.0 ms | 0.0 ms |
| **Total** | **449.7 ms / 2.22 FPS** | **534.2 ms / 1.87 FPS** | **+84.5 ms (+18.8%)** |

**The entire regression is one stage.** 84.1 ms of the 84.5 ms lands on DSP
readback and packet build; every other stage moves less than half a millisecond,
and the rasterizer — 54% of the frame — moves 0.2 ms. That is the signature the
mechanism predicts, and it is the strongest available evidence that the
corrected build perturbs nothing on the CPU side. The noise floor is smaller
than the numbers being read: a straight repeat of the corrected run reproduces
534.2 ms/frame and every stage to within 0.2 ms.

Output is untouched. The frame-100 `fb.res` reproduces the recorded full-mesh
checkpoint `d89958b3…3d16` under both emulators and is byte-identical between
them; both runs write the same cumulative 9,049,666 pixels and link the same
1,149 survivor packets on the final frame. **The corrected build changes timing
only, not what the program computes.**

#### Which half of the fix costs the 84 ms

The port constants are environment-overridable, so the two mechanisms separate
cleanly. Upstream charges nothing for an access's first byte and 4 clocks for
each later one, which is exactly `R1/W1=0`, `R2/W2=4`, `R4/W4=12`: setting those
on the corrected binary gives the true DSP clock with upstream's port model.

| Configuration | packet stage | frame |
|---|---:|---:|
| stock 2.6.1 (DSP 2x fast, upstream port) | 175.6 ms | 449.7 ms / 2.22 FPS |
| corrected DSP clock, upstream port | 263.9 ms | 538.4 ms / 1.86 FPS |
| corrected DSP clock, corrected port | 259.7 ms | 534.2 ms / 1.87 FPS |
| corrected DSP clock, **no port charge at all** | 259.8 ms | 534.1 ms / 1.87 FPS |

**The DSP clock is the whole story: +88.7 ms.** The host-port recalibration is
worth **-4.2 ms** to this program — a small net *gain*, because its traffic is
dominated by block writes, and the new table charges a word write 3 instead of 4
and a long write 7 instead of 12.

The last row is the stronger statement. Setting every constant to zero — no
wait state charged on any host-port access in either direction — moves the frame
by **0.1 ms**, and leaves the packet stage where the calibrated table leaves it.
**The port's wait-state bill is not a term in this program's frame time at all.**
That upstream's model still costs +4.1 ms is consistent rather than
contradictory: the extra charge can only bite where the CPU runs ahead of the
DSP, which is the bulk `Dsp_BlkUnpacked` upload path (long write 12 against 7),
and is invisible everywhere the stage is already waiting on the DSP.

That splits the 259.7 ms stage about as far as these timers can:

| term | ms/frame | how it is known |
|---|---:|---|
| DSP-rate-sensitive | ~177 | the only part that moved when the clock halved: +88.7 ms on a doubling |
| CPU-side unpack and packet build | ~83 | the residual |
| host-port wait states | ~0 | measured directly, last table row |

The ~177 ms is a **measured-delta-derived estimate**, not a timer reading: it
assumes the rate-sensitive part scales exactly with the clock, which is what a
halved clock on a fixed instruction stream should do but is not independently
instrumented. The ~83 ms residual is bus traffic only — 2.4a's core prices
instruction execution at zero — so it is a floor for the CPU-side cost on
hardware, not an estimate of it. Any future reasoning about this program's
transport should treat the port model as neutral, the DSP rate as the term that
moved, and the CPU-side figure as understated.

#### Cross-check on the other core

Section 2.4a's "free experiment" — run without `--mmu`, which selects a core
that charges instruction execution time — doubles as a control on this result,
since it changes the CPU model while leaving the DSP model alone. Same binary,
same 265-frame prefix, `--cpu-exact --compatible --data-cache`:

| Stage | stock 2.6.1 | corrected | Delta |
|---|---:|---:|---:|
| DSP readback + packet build | 178.3 ms | 261.4 ms | +83.1 ms |
| Software span rasterizer | 381.4 ms | 379.0 ms | -2.4 ms |
| set_frame + clear + OT + present | 33.4 ms | 33.0 ms | -0.4 ms |
| **Total** | **593.6 ms / 1.68 FPS** | **673.7 ms / 1.48 FPS** | **+80.1 ms (+13.5%)** |

The packet-stage delta is +83.1 ms here against +84.1 ms on the MMU core — the
same number within noise, from a core that prices the rasterizer 56% higher
(381.4 against 243.8 ms, which is 2.4a's bracket on the word MUL/DIV and
execution-time share, now measured). **The DSP-stage regression is a property of
the DSP model and not of the CPU core**, so it survives whichever core later
work decides is the honest one.

#### What this changes in the rest of this document

- **The transport is now the largest stage in the frame.** DSP readback and
  packet build goes from 39.0% to 48.6%; the rasterizer falls from 54.2% to
  45.7%. For the whole life of this document the rasterizer has been the thing
  to optimize. On the corrected model it is no longer the biggest item.
- **The three-FPS gate roughly doubles.** The distance from the frame to
  333.3 ms was 126.7 ms against 8.2a's 460.0 ms stock-clock baseline. Against
  this build's 534.2 ms it was **200.9 ms**, and after 2.4d's light cache the
  re-measured gate in section 8.2 is **193.3 ms**. Section 8.2a already
  concluded that three FPS does not follow from any identified optimization;
  that conclusion is now much stronger, and the ~66 ms its two named levers
  would buy lands near 461 ms / 2.17 FPS rather than near 395 ms / 2.53 FPS.
- **Item 15 — moving the record stream off host-port PIO — gains, in relative
  terms.** It targets the stage that is now half the frame. Nothing measured
  here says the SSI/DMA path is easier or that section 7.4's hardware gates got
  smaller; what changed is only that the prize is larger.
- **The stage figures above 2.4b are not re-tabulated.** Deltas measured inside
  the rasterizer or the clear (3.5, 3.6, 3.8, 3.9, 2.5) are unaffected — those
  stages move less than half a millisecond between the two emulators. Deltas
  measured on the DSP or packet stage (2.3a-2.3i, 4.x) were taken with the DSP
  at double speed and should be read as lower bounds on their true cost, not
  re-scaled by a constant: none of them was re-measured here.

#### The recipe, which had never been written down

The 460.0 ms baseline's exact command line was not recorded anywhere in this
repository, which is why reproducing it required reconstructing it from 2.4a's
`--mmu true` finding. This is the recipe, and `make measure` runs it:

```sh
hatari --machine falcon --cpulevel 3 --cpuclock 16 --mmu true \
  --patch-tos true --fast-boot true --tos tos402.img \
  --dsp emu --memsize 4 --ttram 0 --monitor rgb \
  --frameskips 4 --sound off --benchmark --confirm-quit off \
  --harddrive <rundir> --auto 'C:\TREX_M68.TOS' --run-vbls 7710
```

`<rundir>` holds `TREX_M68.TOS` (the `trex_m68030` build; the 8.3 name matters,
GEMDOS truncates `trex_m68030.tos`) and `trex_dsp.lod`. 7710 VBLs is the
265-frame prefix on the corrected build, 6583 on stock; a change to the program
moves both, so re-converge rather than reusing the constant.
`tools/decode_render_stats.py` turns the resulting `render_stats.res` into the
tables above.

Reconciling with the 460.0 ms of section 2 and 8.2a: this reconstruction lands
at 449.7 ms on stock, and **10.1 ms of the 10.3 ms gap sits in the packet
stage** (175.6 against 185.7). The rasterizer reproduces to 243.8 against 243.9 ms and the
overhead stages to 29.9 against 30.4 ms. A residual confined to exactly the
stage that the DSP and host-port models drive is consistent with the original
figures having come from a different 2.6.1-devel build rather than from the
Homebrew 2.6.1 release used here; it is not explained further, and the A/B above
does not depend on it, since both of its columns were taken on this machine with
this recipe.

**Everything above is emulator timing.** The corrected build is calibrated
against a real Falcon's DSPBench figures, which makes its DSP throughput far
better founded than what it replaces, but 2.4a's bound still holds for the rest
of the model and no figure in this document has been taken on a Falcon.

### 2.4c The DSP-side A/Bs, re-taken at the corrected clock

2.4b re-measured the frame. It left every measurement that isolates *DSP* work
standing at figures taken with the DSP at double speed, and those are the ones a
halved clock should move most. This is that campaign: the same 265-frame prefix,
the same recipe, and in every case **one binary with one byte patched**, which
is the only comparison 2.1 accepts. Each variant was verified with `cmp -l` to
differ from its reference in exactly one byte before it was run.

#### The occlusion prepass

`prepass_arm` selects four configurations of `trex_m68030_prepass` — 0 off,
1 inline and armed at startup, 2 freestanding and timed per frame, 3 a null
command through the same timed bracket.

| arm | | prepass | packet stage | frame |
|---|---|---:|---:|---:|
| 0 | off, in-binary baseline | — | 259.8 ms | 533.6 ms / 1.87 FPS |
| 3 | null command, same bracket | 0.1 ms | 259.8 ms | 533.6 ms / 1.87 FPS |
| 1 | inline, armed | not separately timed | 263.6 ms | 537.1 ms / 1.86 FPS |
| 2 | freestanding, timed | **117.9 ms** | 377.8 ms | 651.5 ms / 1.53 FPS |

**The freestanding prepass costs 117.9 ms/frame against 2.3h's 60.28.** The
ratio is 1.96 — the clock halving and essentially nothing else, which is what a
pass that is pure DSP arithmetic should show. Two internal checks hold: arm 3
reproduces arm 0 to the tick, so the command protocol carries no cost of its own
and the bracket is honest; and arm 2's packet stage rises 118.0 ms over arm 0
against a prepass timer reading 117.9 ms, so the whole of the freestanding cost
lands where it is attributed. The mix differs slightly from 2.3h's figure, which
came from 11,500-VBL runs of 310 and 318 frames rather than a converged 265-frame
prefix; at a ratio this close to exactly 2 that difference is not carrying the
result.

**The armed inline prepass is no longer free, and this is the finding that
changes a conclusion rather than a number.** Arm 1 costs **+3.5 ms/frame** over
arm 0 (537.1 against 533.6), all of it on the packet stage (+3.8 ms). Sections
2.3f and 2.3h both record the FINISH window hiding the armed prepass completely,
and 2.3h's "what DSP speed would even buy" argument is built on that: the prepass
was said to sit inside the ~244 ms of raster time at no cost. At the Falcon's
real DSP clock it does not quite fit any more. The kills are still live — arm 1
writes 3,278 fewer pixels over the prefix — but that saving is 12.4 pixels per
frame and does not offset anything.

Correctness is unaffected in all four arms: every one reproduces the frame-100
checkpoint `d89958b3…3d16`, including arm 1 with kills active, which is 2.3f's
sealing rule holding. `prep_sta.res` reports `surv_max` exactly 1,194, zero
overflow and zero protocol failures, matching 2.3h's validation to the digit.

For 2.3i, the 4x4-cell experiment measured 60.28 → 74.86 ms/frame and was
rejected. Its `.lod` is not in the tree, so the pair cannot be re-run; at the
1.96 ratio measured here that comparison would scale to roughly 118 → 147
ms/frame. **That is arithmetic on this section's ratio, not a measurement**, and
it does not disturb the rejection, which rested on cell resolution not being the
binding constraint rather than on the size of the gap.

#### Lighting

`lighting_enabled`, one byte, on the shipping `trex_m68030` build:

| Stage | lighting on | lighting off | Delta |
|---|---:|---:|---:|
| DSP readback + packet build | 259.7 ms | 208.5 ms | **+51.2 ms** |
| Software span rasterizer | 244.0 ms | 243.2 ms | -0.8 ms |
| set_frame + clear + OT | 30.0 ms | 30.2 ms | +0.2 ms |
| **Total** | **534.2 ms / 1.87 FPS** | **482.2 ms / 2.07 FPS** | **+52.0 ms (+10.8%)** |

Both write the same 9,049,666 pixels and link the same 1,149 packets, so this is
shading cost alone. **Section 2.1's conclusion that "the entire cost of flat
shading is +0.20% of the frame" no longer describes this program**: the same A/B
is now 9.7% of the frame. Most of that is not the emulator. 2.1's table is the
flat-shading, reduced-mesh epoch; everything the per-corner Gouraud protocol
added in 4.4/4.4a — three rotations and light sums per survivor, four level
divisions, the 18-word record — arrived afterwards, and section 2 estimated it at
~32 ms of readback stage under the doubled clock. 51.2 ms at the corrected clock
is the same item, measured rather than estimated, on a DSP running at half the
speed that estimate assumed.

The practical consequence: **shading is the most expensive optional feature in
this frame, it is entirely DSP-side, and turning it off is the single largest
lever any A/B in this document has ever exposed.** It is not a lever anyone
wants to pull — the shading is the point — but it sizes what 4.4a's protocol
costs and it belongs in the same conversation as item 15, because it is DSP and
transport work rather than rasterizer work.

#### Gouraud bank selection

`gouraud_enabled`, one byte, same build. Section 2 records the interpolation at
**+8.1 ms**. It re-measures with the sign reversed:

| Stage | gouraud on | gouraud off | Delta |
|---|---:|---:|---:|
| DSP readback + packet build | 259.7 ms | 259.8 ms | +0.1 ms |
| Software span rasterizer | 244.0 ms | 248.5 ms | **-4.5 ms** |
| **Total** | **534.2 ms** | **538.8 ms** | **-4.6 ms** |

Per-span bank selection from the interpolated corner chain is now 4.6 ms/frame
**cheaper** than the packet's single mean-level bank. This is not an emulator
effect: it is a rasterizer figure, and 2.4b measured the rasterizer as moving
0.2 ms between the two emulators. The +8.1 ms was taken against the 428.1 ms
flat epoch, before 3.8's opaque path and 3.9's instruction-cache series rebuilt
the row loop; that rasterizer no longer exists. Layout is identical by
construction here and the repeat-run noise floor is 0.2 ms (2.4b), so -4.6 ms is
outside noise — but the mechanism is not established, and 2.1's warning about
rasterizer deltas applies to reading anything more into it.

#### The release build, measured for the first time

Everything above is a diagnostic build. The shipped `TREX.TOS` is a different
binary — `-DTREX_RUN -DTREX_PREPASS -DTREX_RELEASE -DTREX_FPS` — and 8.2a records
why it had never been timed headlessly: `TREX_RUN` zeroes `stats_flush_enabled`,
so a bounded run writes no `render_stats.res`. That flag and
`framebuffer_dump_enabled` assemble the same `dc.l` on both branches, so setting
both to 1 is a **two-byte patch that leaves the layout identical** to the shipped
file, and 2.4a already establishes that the per-frame GEMDOS writes it re-enables
cost nothing in emulated time. `cmp -l` against the released `TREX.TOS` reports
exactly those two bytes.

| Configuration | packet stage | rasterizer | frame |
|---|---:|---:|---:|
| release as shipped (`prepass_arm` 1) | 262.9 ms | 242.8 ms | **536.5 ms / 1.86 FPS** |
| release, prepass disarmed (`prepass_arm` 0) | 259.6 ms | 242.7 ms | **533.0 ms / 1.88 FPS** |

Both reproduce the same frame-100 image as each other (`a3e27e27…7b1c`, which
differs from the diagnostic checkpoint only because 2.6's FPS overlay draws into
the render target), so the kills stay invisible here too. The FPS overlay and
page flip together measure 0.2 ms.

**The armed prepass costs the release +3.5 ms/frame and returns 12.4 pixels per
frame.** That is the same +3.5 ms the diagnostic arms measured above, reproduced
in a second binary, and it is now a **net loss**: 2.3f's deliberately
conservative 8x8-cell, 64-class yield was chosen when the prepass was free
because the FINISH window swallowed it, and at the Falcon's real DSP clock the
window no longer does. Disarming it is a one-byte change to the `prepass_arm`
default and is worth **1.88 against 1.86 FPS**.

This is an emulator result and 2.4a's bounds still apply — but it is the
DSP-timing kind of question the corrected build is specifically calibrated for,
so it is the most trustworthy sort of conclusion this harness produces. The
recommendation is not to delete the prepass: it is item 19's vehicle and 2.3h
banked program words for exactly that work. It is that **the arm should follow
the yield**, and at today's yield the arm costs more than it returns.

#### The pre-normal-cache standings

Everything measured at this point on the corrected emulator, one binary per row
except where noted, all at the converged 265-frame prefix. Section 2.4d
supersedes the shippable rows with the normal-light cache and the disarmed
release default:

| Configuration | frame | FPS |
|---|---:|---:|
| lighting off — not a shippable option, sizes 4.4a's protocol | 482.2 ms | 2.07 |
| **release, prepass disarmed — one byte from shipping** | **533.0 ms** | **1.88** |
| prepass build, arm 0 / arm 3 | 533.6 ms | 1.87 |
| `trex_m68030` diagnostic, the 2.4b baseline | 534.2 ms | 1.87 |
| **release as shipped** | **536.5 ms** | **1.86** |
| prepass build, arm 1 | 537.1 ms | 1.86 |
| gouraud off | 538.8 ms | 1.86 |
| prepass build, arm 2 freestanding | 651.5 ms | 1.53 |

The spread between the fastest shippable configuration and the slowest sensible
one is 3.5 ms. Everything larger on this list is a feature being switched off,
not an optimization.

#### What could not be re-measured

Not everything DSP-side is a live configuration:

- **4.1, 4.1a, 4.1b, 4.1c, 4.1d** are protocol-migration deltas between epochs —
  resident index list, survivors-only records, the span-setup record, the
  switch-over, wire packing. Each compares a protocol that was replaced, and the
  replaced side is no longer in the tree. They stand as history.
- **2.3b through 2.3e** are labelled historical already and describe
  configurations that no longer build.
- **2.3h's nine per-site figures** were `.lod` swaps under one host binary. The
  superseded `.lod` files are generated, not tracked, so the individual site
  deltas cannot be re-run; only the post-harvest total measured here is current.
- **4.4c** records no frame-time result to re-measure.

The general rule this campaign supports: **DSP-side figures in this document
scale by about 2 and should be read that way until re-measured, and the
conclusions built on "the DSP work is hidden" need re-checking rather than
re-scaling** — the prepass is the case where the number moved by the expected
factor and the conclusion drawn from it did not survive.

### 2.4d Frame-local normal-light cache and release disarm — implemented and measured

Per-corner Gouraud evaluates three normal indices for every surviving
triangle.  Across the complete static triangle stream, those 8,172 references
name 3,609 distinct normals.  A read-only source-order simulation of the exact
sidecar gives 3,777 hits in a 128-entry direct-mapped cache (**46.22%**).  That
is a cache-locality model before culling, not a measured runtime hit rate, but
it identified a repeated calculation with a much larger body than its lookup:
one 3x3 normal rotation and two three-light dot-product passes.

`make_triangle_shade` now caches the two clamped direct-light channel sums by
full normal index.  The low seven index bits select a slot; an exact 24-bit tag
rejects collisions.  The values are cached before the triangle-specific depth
cue, so both hits and misses execute the same two depth MPY/RND operations and
the same later level/tint quantization.  A miss follows the previous rotation,
Lambert, per-light clamp and channel-clamp sequence byte for byte, then uses an
X:R parallel move to store the raw channel sum while copying it into the depth
multiply operand.  A hit bypasses only the work whose inputs are frame matrix,
light vectors and normal index.

The cache is frame-local. `cache_light_directions_x` invalidates its 128 tags
after matrix/light state is final and, when armed, only after `prepass_run` has
released the phase overlay.  Sums need no clear because no entry is read without
a matching full tag.  The exact BUILD-phase ownership is:

| X range | Words | Owner |
|---|---:|---|
| `$3C5F-$3C70` | 18 | paired direct-light vectors from 4.4c |
| `$3C71-$3CF0` | 128 | normal-cache tags |
| `$3CF1-$3D70` | 128 | red direct-light sums |
| `$3D71-$3DF0` | 128 | green direct-light sums |
| `$3DF1-$3F15` | 293 | unused BUILD-phase tail before `prepass_scratch` |

All four cache regions overlay only the already-consumed tail of
`prepass_order`; they do not reduce `PREPASS_MAX`, touch the masks, kill bitmap
or status, change the host protocol, or widen the 18-word survivor record.
The scheduling also parks R4/N4 on the rotated-normal triple across corners
and uses R0/R3 for the rotation cursors, removing two per-corner pointer resets.

The controlled A/B used the current worktree and the corrected-clock Hatari
recipe from 2.4b.  The before run reproduced the recorded baseline exactly;
the after run was re-converged to the same 265 completed frames by setting the
VBL cap to 7,604:

| Stage | Before | Normal-light cache | Delta |
|---|---:|---:|---:|
| DSP set_frame | 13.0 ms | 13.2 ms | +0.2 ms |
| DSP readback + packet build | 259.8 ms | **252.1 ms** | **-7.7 ms** |
| Clear + OT | 17.0 ms | 17.1 ms | +0.1 ms |
| Software span rasterizer | 243.8 ms | 243.8 ms | 0.0 ms |
| **Total** | **534.2 ms / 1.87 FPS** | **526.6 ms / 1.90 FPS** | **-7.6 ms (-1.4%)** |

Both runs write 9,049,666 pixels over the prefix, finish frame 264 with 1,149
packets/OT nodes, and reproduce frame 100 SHA-256
`d89958b314c924ad…3d16`.  The isolated stage movement and unchanged rasterizer
are the expected signature of DSP work removed from BUILD, but this remains an
emulator measurement, not a physical-Falcon result.

Assembly is 0 errors/0 warnings.  The program grows from `P:$0901` to
`P:$091E`, leaving 161 words at `$091F-$09BF` before the resident indices.
(Section 7.4b's transport probe has since taken 103 of those and 2.4e's
calibration burst 25 more; the program now ends at `P:$099E`.)
An armed-prepass 4,000-VBL gate completed 130 frames with zero protocol
failures and reproduced the same frame-100 hash, directly exercising the
prepass-order/cache lifetime boundary.

The release default applies 2.4c's earlier result at the same time:
`TREX_PREPASS` remains compiled in, and diagnostic prepass builds still default
to arm 1, but `TREX_RELEASE` initializes `prepass_arm` to zero.  The cache plus
that disarm measures **525.5 ms / 1.90 FPS** over 265 frames, against the
recorded 536.5 ms / 1.86 FPS armed release: **-11.0 ms/frame (-2.1%)**.  Its
9,049,666 raster pixels and 1,149 final packets remain equal.  The release
framebuffer hash is not an identity gate because its FPS overlay is designed to
change when timing changes; the overlay-free diagnostic hash above is the
correct output check.

### 2.4e Three DSP-hotspot levers, sized -- two rejected by simulation, one built and measured

This campaign (2026-08-29) took the three named levers against the 252.1 ms
packet stage in order of cost-to-try.  Two died in their first measurement,
which is the cheapest place to die; the third is built, measured at -2.4
ms/frame, and empirically output-identical.  All figures are corrected-clock
Hatari, the 2.4b recipe, the converged 265-frame prefix.

**Cache widening/rehashing: rejected without building.**
`tools/simulate_shade_cache.py` rebuilds 2.4d's source-order model from the
exact corner-normal sidecar and reproduces the recorded 3,777 hits to the
digit before any variant row is read:

| configuration | hits | rate |
|---|---:|---:|
| 128-entry low-7 (shipping) | 3,777 | 46.22% |
| 128-entry best XOR fold (>>6) | 3,778 | 46.23% |
| 256-entry low-8 | 4,064 | 49.73% |
| 512-entry low-9 | 4,285 | 52.44% |
| infinite cache (compulsory misses only) | 4,563 | 55.84% |

The ceiling is the finding: 44.16% of the 8,172 references are first touches
of one of the 3,609 distinct normals and can never hit a frame-local cache of
any size or associativity.  At 2.4d's measured ~2.0 us per hit the entire
remaining headroom is ~1.6 ms/frame, the buildable 256-entry step (+287
hits) is ~0.6 ms against 768 X words that do not exist (the BUILD tail holds
293), and rehashing at 128 entries is worth one hit -- the conflict misses
are capacity, not hash artifacts.  Rejected on 2.3i's arithmetic.

**Survivors-only/resident UV traffic: rejected by the calibration below.**
All UV upload traffic together is 5,448 words * 1.188 us = 6.5 ms/frame; the
reachable fraction is smaller, and reclaiming any of it needs the resident
UV table whose Y memory the corner normals displaced.

**The corrected per-word calibration exists now.**  `CMD_PIO_BURST` ($42, 25
program words, the even control-range neighbour of `CMD_SSI_STREAM`) absorbs
M pushed words and streams back N ramp words; `make trex_m68030_pio_cal`
brackets 16 large and 64 small bursts per direction with the 200 Hz clock
before the renderer starts, and `tools/decode_pio_cal.py` solves the pair
for per-word cost against per-command overhead.  Both directions verified
(ramp byte-exact, all acks):

| direction | per word | per-burst overhead |
|---|---:|---:|
| DSP -> host (record readback) | **1.876 us** | 36.2 us |
| host -> DSP (upload) | **1.188 us** | 2.1 us |

The burst loops do nothing else per word, so unlike the pre-2.4b 2.3 us/word
figure this prices transport with both parties ready, separated from DSP
production.  Against 8.2a's word counts the wire is 20,682 record words at
1.876 (38.8 ms) plus ~5,900 upload words at 1.188 (7.0 ms): **~46 ms/frame
of measured port floor**, replacing the 62 ms upper bound.  That floor is
what item 15's DMA stream attacks, and it bounds every traffic-shaping idea
below it.  Resolution is one 200 Hz tick on 98 (read) and 62 (write) ticks,
so about 1-1.6%.  Gate: the extended `.lod` under the unchanged host binary
reproduces `d89958b3…3d16` and 526.7 ms/frame exactly -- the probe is
dispatch-reachable only by a command no shipping path sends.

**Object-space lights: built, measured, -2.4 ms/frame.**  `(R n) . l =
n . (Rt l)` is an identity for any matrix -- no orthonormality assumption --
so rotating the six light vectors through the frame-matrix transpose once
per frame (`cache_light_directions_x`, matrix walked by columns) lets the
Lambert loops dot the raw object-space corner normal, and the 3x3 rotation
leaves the per-miss path of `make_triangle_shade` entirely.  What moves is
rounding: per-frame light components round instead of per-corner rotated
normal components, so the variant forfeits the byte-identity gate BY DESIGN
and answers to geometric comparison.  `OBJLIGHTS equ 0` stays in the source
(the checked-in `.lod` is byte-identical); `make trex_dsp_objlights` rewrites
the equate and produces `trex_dsp_ol.lod` (extent `P:$09B1`).

One `.lod` swapped under one host binary, re-converged to 265 frames:

| Stage | shipping | OBJLIGHTS=1 | Delta |
|---|---:|---:|---:|
| DSP readback + packet build | 252.1 ms | **250.0 ms** | **-2.1 ms** |
| Software span rasterizer | 243.7 ms | 243.7 ms | 0.0 ms |
| **Total** | **526.7 ms / 1.90 FPS** | **524.3 ms / 1.91 FPS** | **-2.4 ms (-0.5%)** |

Both runs write the same cumulative 9,049,666 pixels and 1,149 final
packets, and the frame-50, frame-100 and frame-200 captures are all
**byte-identical** to the shipping renderer's -- frame 100 reproduces
`d89958b3…3d16` itself.  The 24-bit rounding differences exist but never
cross a level-quantization boundary on any tested frame.  That identity is
EMPIRICAL, not by construction: it held on three checkpoints and the
whole-prefix pixel count, and a change to lights, choreography or the
quantizer could surface a one-step level difference at any time.  The
variant is therefore built and measured but NOT the shipping default;
adopting it costs either a full-choreography sweep or accepting an
empirical identity gate where a structural one used to be.

**What this leaves of the ~177 ms DSP-rate-sensitive estimate.**  With
lighting's 51.2 ms (2.4c) the only attributed phase, ~2 ms of it now
removable, the cache measured to its ceiling, and transport measured at ~46
ms, the unattributed remainder -- projection, both classify passes, span
setup, `span_div`, record packing -- still has no per-phase timer.  The
`prepass_arm=2` freestanding-and-timed bracket remains the mechanism that
could name it, and is the remaining measurement this section did not build.

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

**Every split in this section is a stock-clock measurement**, taken before
2.4b established that stock Hatari ran the DSP at twice its real rate.  The
*frame* columns above are therefore all too low.  The rasterizer terms are
not: the DSP clock is not a term in the CPU rasterizer, and the corrected
re-measurement in 8.2 reproduces the post-3.9b/3.9c rasterizer split to
0.3 ms.  **Section 8.2 carries the current split** -- 68.5 ms per-packet
setup, 112.7 ms row/span walk, 62.5 ms pixel loops, in a 526.6 ms frame --
and is the one to quote.  The deltas above remain valid as deltas, since both
of their columns share the same clock.

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

**Every absolute figure in this section is a stock-clock measurement**, taken
before 2.4b found that stock Hatari ran the DSP at twice its real rate.  The
series' deltas and percentages stand -- both sides of every A/B share one
emulator, and the term being removed is CPU instruction fetch, which the DSP
clock does not touch -- but its frame totals are all too low.  Section 8.2
carries the corrected baseline.

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

### 3.10 The data cache: what it is worth, and the one phase that was never scanned

Section 3.9's series was entirely about the **instruction** cache. 2.4d
measured the **data** cache for the first time by running the shipping binary
with `--data-cache false`: the rasterizer goes **244.61 -> 316.53 ms**, so the
data cache is currently worth **71.9 ms per frame -- 29% of the rasterizer and
13% of the frame**. This section asks how much of that is recoverable by
layout, and answers: a little, and now taken.

**Why the data path is the way it is.** The Falcon's 68030 reaches ST-RAM over
a **16-bit** bus, so a longword access is two bus cycles, and the machine has
**no burst mode** -- a cache line is filled a word at a time, and the 030's
16-byte line brings no prefetch benefit. (This also closes 2.4a's open
question in the emulator's favour: 2.4a noted Hatari fills 4 bytes rather than
16 and flagged that a bursting Falcon would be faster than the model. The
Falcon does not burst, so the model is right here and 2.4d's cold-read bound
transfers better than that caveat allowed.) The consequence is that the only
data-cache levers are alignment and conflict, not prefetch.

**Alignment is already optimal and there is nothing to win there.** The
qualified-opaque pixel loop's three accesses are a byte texel read
`move.b (0,a5,d1.l),d0`, a word CLUT read at `index*2` and a word framebuffer
write -- one bus cycle each, all naturally aligned, no longword access to
misalign. The misalignment penalty that dominates most Falcon data-path advice
does not apply to this loop.

**Conflict was the lever, and one phase had never been scanned.** The data
cache is 256 bytes: sixteen 16-byte lines, direct-mapped on address bits 4..7.
The pixel loop drives three streams through those sixteen lines every pixel.
Item 16 scanned the raster state cells (a real curve, 13.6 ms, phase 32) and
the texture BLOCK phase (flat), and pinned the word CLUT with `cnop 0,4096`
after the Gouraud growth moved it and cost 80 ms. But **pinning was done to
stop the banks moving, not to put them anywhere good** -- a 4-KiB anchor makes
every 512-byte CLUT bank start at line 0, which is one arbitrary choice out of
sixteen.

`OPAQUE_CLUT_PHASE` offsets the buffer inside the 256-byte period, with a
trailing pad restoring the total to whole periods so nothing after it moves
phase. The buffer is 768 whole periods and the pads are BSS, so **the
instruction stream is bit-identical across every point of the scan** -- all
eleven binaries are the same file size and differ only in data addresses,
which is a stronger equal-layout guarantee than the one-byte gates elsewhere
in this document. Corrected emulator, `--mmu true`, 8,400 VBLs, frame-100
`fb.res` equal to `d89958b3...` at every point:

| Phase | Frames | px/frame | Rasterizer | Frame | us / 1k px |
|---:|---:|---:|---:|---:|---:|
| 0 (shipped) | 272 | 34,121 | 244.34 ms | 535.7 ms | 7.1609 |
| 32 | 271 | 34,110 | **245.44 ms** | 536.5 ms | 7.1957 |
| 64 | 271 | 34,110 | 245.37 ms | 536.5 ms | 7.1936 |
| 96 | 272 | 34,121 | 242.72 ms | 533.8 ms | 7.1135 |
| 112 | 273 | 34,136 | 241.67 ms | 532.9 ms | 7.0795 |
| **128** | 273 | 34,136 | **241.25 ms** | **532.6 ms** | **7.0671** |
| 144 | 273 | 34,136 | 241.72 ms | 532.9 ms | 7.0811 |
| 160 | 273 | 34,136 | 241.65 ms | 532.8 ms | 7.0789 |
| 176 | 273 | 34,136 | 242.44 ms | 533.6 ms | 7.1020 |
| 192 | 272 | 34,121 | 242.61 ms | 533.8 ms | 7.1102 |
| 224 | 272 | 34,121 | 243.62 ms | 534.7 ms | 7.1398 |

A smooth single-minimum curve with a flat basin over 112--160, so **128 is
chosen for the basin rather than the tick**. The pixel-normalised column is
there because the frame counts differ by one or two: the fastest phases also
carry the *most* pixels per frame, so frame mix works against the effect and
the raw millisecond column understates it. Normalised range is **1.82%**.

**Result: `OPAQUE_CLUT_PHASE = 128`, rasterizer 244.34 -> 241.25 ms, frame
535.7 -> 532.6 ms, 1.867 -> 1.878 FPS, at byte-identical output.**

**And the honest size of it.** The data cache is worth 71.9 ms; only **4.2 ms
of that is phase-addressable**, and 3.1 ms was available from the shipped
position. **94% of the benefit is the cache simply working**, and no layout
change reaches it. The structural reason is visible in the numbers: a CLUT
bank is 256 entries x 2 bytes = **512 bytes against a 256-byte cache**, so a
bank aliases onto itself 2:1 no matter where it is placed. Phase can move
which lines the three streams contend for; it cannot make the working set fit.
Anyone hoping to repeat 3.9's order-of-magnitude result on the data side
should read that ratio first -- the instruction cache was 552 bytes of loop
against 256 and could be *made* to fit, and this cannot.

### 3.11 The unpack writes into the packet -- implemented, -25.2 ms

Section 8.2a named this and costed it; it is now built and measured. **Every
survivor's span record was handled twice.** The chunk unpack expanded the
eighteen packed wire words into 22 longwords in `dsp_triangle_rx_buffer`, and
`build_gpu_shadow_packets` then read all 22 back and wrote them again into the
packet through two MOVEM pairs -- 44 longword bus accesses per survivor,
50,556 per frame, producing no new value.

**The change.** The unpack now lands each field in its final packet slot. Its
output pointer starts at `gpu_packet_buffer` instead of the record buffer and
strides `GPU_PACKET_BYTES`; the OT key goes straight to packet word 2, the 22
span longwords to words 4--25, and the two head values the span block cannot
carry -- the global source index and the shade -- are parked in **resolve
slots 0 and 1**. `build_gpu_packet_heads` then fills only the three words that
remain: command|shade, flat colour or page-table token, and native texture
page. Nothing is copied.

**Why borrowing the resolve slots is legal.** The per-frame order is unpack ->
`build_gpu_packet_heads` -> `gpu_submit_ot` -> the 3.9c resolve sweep -> the OT
walk, and the sweep lives *inside* `gpu_rasterize_ot`. The slots are therefore
dead through the first three stages and are overwritten by the sweep before
anything reads them as resolve state. This is an ordering contract, not an
accident: moving the resolve sweep earlier, or the builder later, breaks it
silently, so both ends carry a comment saying so.

**Two builders, deliberately.** The no-DSP fallback still produces the old
contiguous 25-longword records through `build_host_triangle_stream`, so
`build_gpu_shadow_packets` survives unchanged for that arm and the DSP arm uses
the lean one. The classification body -- material lookup, flat/textured split,
opaque hint -- is duplicated rather than shared: a BSR per survivor costs more
than the bytes save, and 3.9's result is that a per-item loop body wants to be
straight-line and inside the 256-byte instruction cache. **The two must stay in
step**; any change to the material or opaque-hint rules belongs in both.

Measured on the corrected emulator, `--mmu true`, frame-100 `fb.res` equal to
`d89958b3...` on both sides, workloads matched to 0.1% (34,136 against 34,103
pixels per frame):

| Stage | Before (273 fr) | After (270 fr) | Delta |
|---|---:|---:|---:|
| **DSP readback + packet build** | 260.51 ms | **235.31 ms** | **-25.20** |
| Rasterizer | 241.25 ms | 240.65 ms | -0.60 |
| Framebuffer clear | 14.54 ms | 14.56 ms | +0.02 |
| DSP set_frame | 13.08 ms | 13.07 ms | -0.01 |
| Ordering Table insertion | 2.71 ms | 2.39 ms | -0.32 |
| **Frame** | **532.6 ms / 1.878 FPS** | **506.4 ms / 1.975 FPS** | **-26.2** |

**-25.20 ms against 8.2a's ~25 ms prediction**, which is the closest this
document has come to costing a change before building it. The rasterizer moves
-0.60 ms, inside frame mix, which is the control: this change must not touch
it. 2.4c's split predicted the result too -- it put ~73 ms of host CPU work in
the packet stage, and this removes about a third of it.

#### The span validator was dead, and it did not die here — repaired in 3.12

`span_validate_enabled` was turned on to exercise the one offset in the
validator arm that this change moved. It reports **every record as a
mismatch**: `val_records` = `val_mismatch_total`, `val_first_captured` = 0 and
all seventeen per-field counts zero -- the signature of every call taking
`validate_span_record`'s early-out, where `compute_span_reference` returns
degenerate, rather than reaching the field compare.

**Unmodified HEAD does exactly the same thing** (181,601 of 181,601, same
signature), so this is pre-existing rot and not a consequence of 3.11. **Root
cause and repair are in section 3.12**: the DSP command the validator reads its
reference vertices from had been retired, so it compared nothing and reported
everything. With that restored, the same gate runs clean over 167,176 records.

What validates 3.11 in the meantime is the stronger gate anyway: byte-identical
frame-100 output over 270 frames exercises every survivor's span fields through
the rasterizer, and a misplaced field would change the image. The one offset
that could not be exercised -- the source index the validator arm reads -- is
proven indirectly: it is the same address as the UV-lookup offset eight bytes
earlier in the same run of stores, and that one *is* exercised, because the
uv0/uv1 packs are built from the texture metadata it indexes and the image is
byte-identical.

### 3.12 The span validator was dead for two epochs -- root cause and repair

Section 3.11 turned `span_validate_enabled` on and found it reporting **every
record as a mismatch**, on unmodified HEAD as well as on the change under test.
It is repaired here, and the failure is worth recording in full because of how
it hid.

**Root cause: the DSP command it depends on was deliberately removed.** The
validator does not recompute the projection -- it compares the DSP's *span
setup* against the host's, using **the DSP's own projected vertices** as the
shared input, which is what makes a mismatch mean "the span arithmetic
disagrees" rather than "the two projections rounded differently". It gets those
vertices with `CMD_GET_VERTICES`, command 3.

Section 4.1c retired command 3 from the normal path when the span-setup record
made it unnecessary, and 2.3's occlusion stage then claimed its twenty-one
program words; the dispatcher was pointed at `dispatch_bad_command`. The DSP
source said so plainly and even named the casualty -- *"a host that still calls
it -- span_validate_enabled, or the projected-vertex fallback -- gets a wrong
ack and takes its shadow path instead of deadlocking"*. **Taking the shadow
path is exactly what made it silent.** The chain:

1. `fetch_projected_vertices` sends command 3 and gets `ERR_BAD_COMMAND`.
2. Its ack test fails, it returns 0, and `dsp_vertex_rx_buffer` stays zero.
3. `compute_span_reference` reads zero coordinates for all three vertices, so
   its cross product is zero.
4. That is the degenerate test, and `validate_span_record`'s degenerate arm
   counts **one mismatch per record and returns before comparing anything**.

The signature is unmistakable once seen: `val_records` exactly equals
`val_mismatch_total` (181,601 of 181,601), `val_first_captured` is 0 and all
seventeen per-field counters are 0 -- a 100% failure verdict in which nothing
was compared. Any reader would have concluded the DSP was broken.

**The repair, in two parts.**

*Restore the command.* `command_get_vertices` is back on the DSP, streaming
`vertex_count * 4` words straight out of the projection's own output array at
the stride `load_projected_xy` and `lookup_projected_z` already index. It costs
**seventeen program words**: the P extent moves `$0901` -> `$0912` against the
`$09BF` ceiling, leaving **173 free** where 190 were. It executes only when the
host sends command 3, which only `span_validate_enabled` and the
projected-vertex fallback do, so the shipping frame pays the words and no
cycles. The frame-100 `fb.res` is unchanged (`d89958b3...`) and the frame reads
506.6 ms against 506.4 -- inside noise, as a command nothing calls should be.

*Make the failure mode loud.* Restoring the command fixes today; the guard
fixes the class. `val_no_vertices` is a new counter, appended as `val_stats.res`
field 26 (`VAL_STATS_LONGS` 26 -> 27). When the prefetch fails, the host sets it
and `validate_span_record` returns immediately without touching a counter, so
the report reads **0 records, 0 mismatches, no_vertices = 1** -- "did not run",
which cannot be misread as either "passed" or "the DSP is broken".
`span_validate_enabled` deliberately stays set, because it is what gates the
report and a run that cannot validate still has to write the file that says so.

**Verified both ways**, corrected emulator, `--mmu true`:

| Build | `val_records` | `val_mismatch_total` | `val_no_vertices` |
|---|---:|---:|---:|
| restored `.lod` | 167,176 | **0** | 0 |
| HEAD's `.lod`, no command 3 | 0 | 0 | **1** |

**167,176 records at seventeen fields each is 2,841,992 exact field
comparisons, zero mismatches** -- against the 852,390 recorded in 4.1b when the
gate last ran clean, and now covering the eighteen-word record and the Gouraud
level fields that did not exist then.

**What this cost, and the lesson.** The gate was dead across at least the
Gouraud epoch and the occlusion epoch: 4.1b, 7.4 and roadmap item 15 all
continued to describe it as available, and item 15 planned to use it as the
SSI/DMA bring-up instrument. A diagnostic that fails by reporting failure is
worse than one that fails by refusing to run, because the first is
indistinguishable from a real defect in the thing it tests. **A retirement note
that names the callers it breaks is not enough; the callers have to be made to
say so at runtime.** Nothing here changes rendering, and none of it would have
been found without turning the tool on for an unrelated change.

### 3.13 The row/span walk: split re-taken, phase re-confirmed, one candidate rejected

The row walker is the largest rasterizer term and had not been split since
before 3.9c, 3.10 and 3.11. Re-taken with 3.5's method -- three binaries of
**identical size**, the profile patches preserving instruction lengths -- on the
current build and the corrected emulator:

| Component | ms/frame | of rasterizer | of frame |
|---|---:|---:|---:|
| **Row/span walk** | **110.88** | 46.1% | 21.9% |
| Per-packet setup | 68.45 | 28.4% | 13.5% |
| Pixel loops | 61.32 | 25.5% | 12.1% |

Close to 8.2a's 113.4 / 68.3 / 62.2, as it must be: 2.4c showed the 68030 side
is emulator-invariant, and 3.10/3.11 moved the rasterizer by well under a
millisecond between them.

**`RASTER_STATE_PHASE` re-scanned, and 32 survives.** Item 16 set it by a scan
taken before 3.10 moved the word CLUT to phase 128, and both stream through the
same sixteen data-cache lines, so the optimum could have moved with it. All
eight points across the period, frame-100 `fb.res` equal at every one:

| Phase | 0 | **32** | 64 | 96 | 128 | 160 | 192 | 224 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Rasterizer, ms | 241.93 | **240.67** | 242.68 | 243.02 | 247.35 | 249.75 | 250.36 | 244.22 |

Range **9.7 ms**, minimum still at 32. The two phases do not interact the way
the hypothesis expected; the shipped setting is re-validated rather than
improved.

#### Hoisting the chain advance -- built, measured, REJECTED

The walker reads `raster_ul`, `raster_vl` and `raster_lvl` at the top of each
row and then reads each a *second* time, as the read half of the RMW that
advanced them in `.span_row_advance`. Loading each cell once and storing its
next-row value back immediately -- while the value is already in a register --
removes one access per chain per row, 3 per row, 37,317 per frame. At the
~7.5 clocks per access the row cost implies, that predicted roughly **17 ms**.

Built, and the loop stayed inside the instruction cache: `.span_row_loop` grew
**228 to 234 bytes** against the 256-byte line, exactly the +6 predicted.
Measured at an identical workload -- 270 frames and 34,103 pixels per frame on
both sides, `fb.res` byte-identical:

| | Baseline | Hoisted | Delta |
|---|---:|---:|---:|
| Rasterizer | 240.67 ms | 240.76 ms | **+0.09** |

**Nothing. Reverted.**

**Why, and this is the useful part.** The prediction assumed both reads miss,
because the pixel loop runs between them and sweeps the data cache. It does
not -- and the reason is the phase scan immediately above. Phase 32 is the
minimum precisely because it places the state cells in the lines the pixel
loop's three streams disturb *least*, so the cells largely survive the pixel
loop and the second read was already a cache hit. Removing a hit buys nothing
in a model that charges bus traffic. The 9.7 ms range of that scan is the
measure of what the conflict costs when the phase is wrong; at the right phase
it is already paid down.

**So the 110.88 ms is not chain-cell read traffic**, and the next attempt on
this term should not assume it is. What remains named and untested inside the
row body: four write-through stores per row (`raster_ul`, `raster_vl`,
`raster_lvl`, `raster_rows` -- the 68030 data cache is write-through, so these
reach memory whatever the phase), the memory-indirect `jmp ([raster_span_entry])`,
and instruction fetch across a 234-byte hot path that has only 22 bytes of
headroom left. Item 11's per-row ceil incrementalization is **not** a candidate
here for a different reason: it removes arithmetic, and 2.4a's core charges
instruction execution nothing, so it would measure as zero regardless of what
it is worth on a Falcon.

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

**Superseded as a transport rate by 2.4c; still valid as a protocol-change
rate.** The 25.0 ms above is a *stage* delta: removing 10,896 words per frame
removed the wire traffic **and** the DSP's work to receive, unpack and store
them, and it did so on an emulator running the DSP at twice its real clock. A
direct wait-state sweep on the corrected emulator prices the entire host port
at **14.2 ms/frame in the packet stage** against ~25,000 accesses — about
0.57 µs per access, roughly a quarter of 2.3 µs. Every later section that
multiplies a word count by 2.3 µs to size *transport* therefore overstates it
by ~4x; the figures affected are flagged in sections 8, 8.2a and this document's
roadmap items 14 and 15. Use 2.3 µs/word only for what it actually measures —
the end-to-end cost of adding or removing words from the protocol, DSP-side
handling included — and 2.4c for anything that asks what the wire alone costs.

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

The current X layout has two mutually exclusive owners above the resident
arrays. BUILD uses the chunk UV/output buffers, paired light vectors and the
normal-light cache; the optional prepass first overlays that whole tail with
its order list, then leaves only the masks/kill/status region live while BUILD
runs:

| Range | Words | BUILD owner |
|---|---:|---|
| `X:$0040-$0043` | 4 | command and translation |
| `X:$0044-$1063` | 4,128 | static base vertices |
| `X:$1064-$25E3` | 5,504 | object/camera pose, then projected vertices in place |
| `X:$25E4-$39DE` | 5,115 | X half of the corner-normal table |
| `X:$39DF-$3A1E` | 64 | one chunk's packed UV pairs |
| `X:$3A1F-$3C5E` | 576 | 32 survivor records at 18 words each |
| `X:$3C5F-$3C70` | 18 | paired direct-light vectors |
| `X:$3C71-$3DF0` | 384 | 128 tag/red/green normal-light cache entries |

The prepass view is `X:$39DF-$3F15` order list (1,335 words),
`X:$3F16-$3F85` masks (112), `X:$3F86-$3FF7` kill bitmap (114), and
`X:$3FF8-$3FFF` status (8). The normal-light cache ends 293 words before the
masks and is invalidated only after the prepass releases the order overlay.
The latest run still reports 16,040 free X words and 16,127 free Y words from
the Falcon DSP system before the frontend's explicit reservations.

The resident index and normal arrays live in Y memory — and their placement is
constrained by a hardware detail that is easy to miss. The Falcon wires one
32K-word external SRAM into all three DSP address spaces. Only the low
addresses are on-chip:

| Space | On-chip | External mapping |
|---|---|---|
| P | `$0000-$01FF` | `$0200-$7FFF` -> external word `address` |
| X | `$0000-$00FF` | `$0100-$3FFF` -> external word `address + $4000` |
| Y | `$0000-$00FF` | `$0100-$3FFF` -> external word `address` |

So `Y:$0200` upwards is physically the same memory as `P:$0200` upwards, which
is where a DSP program larger than 512 words keeps its own code. Placing a
resident array at the bottom of external Y overwrites executable P words.

Both arrays therefore start above the program. The tracked LOD's first free P
address is currently **`P:$0996`** — `$094D` before 2.4f's window-capacity
probe added 44 words for its burn loop and hook, and `$0979` before 2.4d's
normal-light cache. The current exact map is:

| Array | Range | Words |
|---|---|---:|
| `triangle_indices` | `Y:$09C0-$29AB` | 8,172 (2,724 × 3 packed words) |
| `corner_normals_y` | `Y:$29AC-$3FFE` | 5,715 (1,905 × XYZ) |

`Y:$09C0` leaves **42** external words (`$0996-$09BF`) free above the default
build for code growth. That is the SSIPROBE=0 configuration; the SSI bring-up
build (SSIPROBE=1, WINPROBE=0) currently ends at `$09D0`, 17 words past the
ceiling, and is not usable until it comes back under it. The frontend reserves
16,120 Y words through `Y:$3EF7`, so only four reserved words remain above
`face_normals`.

The remaining 1,705 corner normals are the X-bank allocation above. The
on-chip scalar/counter block ends at `Y:$00DE`; `Y:$0100-$01FF` remains
deliberately unused because the available Falcon mapping descriptions
disagree about it. X memory is unaffected by the P/Y overlay: its external
portion maps to `P:$4000-$7FFF`, which no realistic program size reaches.

The two arrays use 13,620 words. That is why the index list is packed at two
words per triangle: the unpacked three-word form would need 8,172 and does not
fit in the remaining P/Y window.

Anything that grows the DSP program past `P:$09BF` silently corrupts the first
triangle indices instead of failing to assemble. Check the first free P
address in the LOD after adding DSP code:

```bash
awk '/^_DATA P 0040/{f=1;next} /^_DATA/{f=0} f{n+=NF} END{printf "first free P address: $%X\n", 0x40+n}' TREX/dsp/trex_dsp.lod
```

The current program ends at `P:$099E`, leaving 33 words `$099F-$09BF` before
`triangle_indices`: the normal-cache build ended at `P:$091E`, section
7.4b's `CMD_SSI_STREAM` transport probe added 103 words, and section 2.4e's
`CMD_PIO_BURST` calibration burst 25 more. The complete
animation-pose/transform/projection stage is 2.5% of the current frame. It is
already DSP-side except for XYZ16 expansion and programmed-I/O transport; the
remaining measured DSP lever was repeated per-corner lighting, which 2.4d now
caches. The two large remaining stages are mixed DSP/host packet construction
and the M68030 framebuffer path.

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

#### 4.4c Direct-light X cache and paired dot pipeline — implemented

The 18 direct-light words remain in their canonical compact Y-memory packet
block (`light_direction`): this change does not alter the host protocol,
light order, fixed-point values, or span-record format. Once per completed
frame, `cache_light_directions_x` copies those words to the phase-local
`X:$3C5F-$3C70` cache. For an armed frame the copy is deliberately after
`prepass_run`, because the location is the no-longer-needed tail of
`prepass_order`; for the no-prepass `SET_FRAME` path it follows projection.
The diagnostic `CMD_PREPASS` run-now path performs that same post-prepass
refresh before acknowledging the command.
It is above the maximum `triangle_out` extent and below `prepass_scratch`, so
it does not change the allocation or ownership of the kill bitmap/status
window.

`make_triangle_shade` now reads each light component through R0/X into X0 and
the matching camera-normal component through R4/Y into Y0 in one parallel XY
move on each multiply/accumulate. The dot product is unchanged because the
two fractional operands are commutative; its existing rounding and per-light
clamp remain in the same order. This is an instruction-scheduling change, not
a measured frame-time result: no Hatari or physical-Falcon timing is recorded
for it yet.

Assembly verification for this revision is 0 errors and 0 warnings. The
assembled P extent is `P:$098C` (2,381 words from `$0040`), leaving
`P:$098D-$09BF` (51 words) before the resident Y indices. That is an
assembled-layout result, not a speed measurement.

A Hatari 2.6.1/TOS 4.02 smoke run on 2026-08-13 used the rebuilt
`trex_prepass.tos`, DSP emulation and 4 MB ST-RAM for 1,800 VBLs. It completed
28 frames with the DSP open and stream-ready, normal data loaded, 1,071 DSP
packets/OT primitives and 154,396 raster pixels; the prepass protocol-failure
counter was zero. Arm mode 1 runs the prepass inside `FINISH`, so its separate
host-timed run counter and time are expected to remain zero in this capture.

A second, temporary arm-mode-2 copy of the same host binary exercised the
explicit `CMD_PREPASS` run-now path for 1,800 VBLs: 24 frames made 24 runs,
with 1,097 last/1,100 maximum survivors, zero overflow and zero protocol
failures. This directly covers the post-run cache refresh. These are
control-path smoke tests only, not framebuffer-equivalence checks or timing
results.

Section 2.4d extends this phase-local block with a second cache at
`X:$3C71-$3DF0`: 128 exact normal-index tags and two clamped direct-light sums
per entry. It reuses a rotated/lit normal across triangle corners while
leaving the triangle-specific depth MPY/RND and every downstream quantizer in
place. Unlike the original paired-load scheduling change above, this extension
has a corrected-clock fixed-prefix measurement: -7.7 ms in the mixed
DSP/packet stage and -7.6 ms/frame overall at byte-identical diagnostic output.

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

Since that list was written the area has moved past all three bullets:
section 4.4 implements the source light model -- three per-light-clamped
directional lights, the ambient term and a two-bit tint class -- section
4.4a recovers all 3,610 PS1 corner normals offline so the O3D
one-normal-per-polygon limit no longer binds, item 13 ships span-level
Gouraud from those corners, and coloured light rides the 64 preshaded CLUT
banks per page. 4.4c pairs the dot pipeline's loads through an X-side light
cache. Open in this area are only the per-pixel RGB fidelity tier section
4.4b costs and the instruction-stream reserve section 2.3h audits; a
specular term has no counterpart in the source model.

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

### 7.4 Concrete SSI/DMA span-stream contract -- model implemented, hardware pending

There are two offline models, and they answer different questions.  Neither
touches Falcon hardware.

[`tools/ssi_framing_model.py`](tools/ssi_framing_model.py) is the RECORD
stream's 16-bit framing contract: lossless 24-to-16-bit unit splitting, the
frame/footer envelope that distinguishes a complete buffer from a shifted,
truncated or duplicated one, and capacity behaviour including the geometric
worst case.  Run it directly (`python tools/ssi_framing_model.py`, 198,912
checks).  Section 7.4a is that contract and supersedes the row-stream
specification for anything scoped to "DSP -> CPU result records only".

[`tools/ssi_stream_model.py`](tools/ssi_stream_model.py) is the ROW stream's
protocol and full-mesh cost/buffer model, and is the one the SSI/DMA bring-up
tools import.  `--self-test` covers CRC failure, truncation, capacity
overflow, shade changes, `RUN16`, clipping and modulo-16-bit U/V recurrence
(`make ssi_stream_model_test`).  The rest of 7.4 -- the ABS/SET_SHADE/RUN16
coder, the 86.9-KB row figures, the 2x192-KiB row sizing -- is the row-stream
specification this file models.

The target hardware configuration is
nevertheless exact enough to implement without rediscovering ownership:

1. acquire the Falcon sound lock; snapshot the complete 24-bit sound-DMA
   start/end/count registers, mode, operation, Crossbar `$FF8930/$FF8932`, divider/track
   `$FF8934..$FF8936`, DSP tristate and affected MFP interrupt state;
2. stop record DMA, select a one-shot 16-bit record buffer with `Setbuffer`,
   and configure DSP SSI for 16-bit transmit words;
3. in `$FF8930`, replace only DSP-XMIT bits **7..4** with **`$C`**: connected,
   32-MHz source, handshake enabled.  In `$FF8932`, replace only DMA-RECORD
   bits **3..0** with **`$2`**: source DSP output, handshake enabled.  In raw
   masked form those fields are `(old8930 & $FF0F) | $00C0` and
   `(old8932 & $FFF0) | $0002`.  The equivalent XBIOS `Devconnect(1, 1, 2,
   1, 0)` setup must produce those read-back fields; DMA is single-shot, never
   looped.

   **Corrected 2026-08-20.**  Earlier revisions of this section named bits
   15..12 of `$FF8930` and 11..8 of `$FF8932`, with the field values `$C` and
   `$1`.  Both registers hold four four-bit fields and the two this route
   needs are the LOW ones: bits 15..12 of `$FF8930` are the A/D converter's
   source select and bits 11..8 of `$FF8932` are external output's.  The
   validator in `TREX/m68030/ssi_dma.s` was written against the wrong text and
   therefore could not have passed on a correctly routed machine.  The
   corrected fields are confirmed by a live transfer (below); the prescale is
   1 rather than 0 because prescale 0 selects the STE-compatible divider;
4. arm DMA record only after the inactive buffer and DSP frame id agree.  The
   stream is variable length, so the DSP sends `SSI_END` with the actual word
   count and CRC after emitting the footer.  The host waits for the DMA current
   pointer to reach `start + 2*actual_words`, stops the channel, and only then
   treats a valid footer/count/CRC as consumable; a footer without the pointer
   check, or a pointer without a valid footer, is insufficient;
5. on every normal exit, abort and error path, stop only the owned channel and
   restore the saved registers/state before releasing the sound lock.

The 32-MHz/4 SSI setting has an Atari-specified ceiling of 8 Mbit/s = 1 MB/s.
That is a wire limit, not achieved bandwidth.  Handshake remains enabled so
the DMA FIFO gates the clock under true-colour Videl contention.

Application framing is a sequence of big-endian 16-bit units:

| Record | Exact contents |
|---|---|
| Frame header, 8 words | magic `$5353`, version/flags, 32-bit frame id, mesh id, buffer generation, capacity in words, reserved |
| Packet header, 9 words | `$E000 | row_count`, source triangle, 32-bit OT key, shade/tint state, DSP packet flags, low 16 bits of `du/dx`, low 16 bits of `dv/dx`, signed packet `y_start` |
| `ROW_ABS`, 3 words | `(x0 << 8) | (count-1)`, U Q8.8, V Q8.8; `x0 < 240` leaves `$Fxxx` for controls |
| `SET_SHADE`, 1 word | `$F100 | level`, emitted only when the exact Gouraud bank changes |
| `ROW_SKIP`, 1 word | `$F200 | (skip_count-1)`, advances logical rows with no drawable X span; count 1..256 |
| `RUN16`, 7 words | `$F000 | (run_length-1)`, initial ABS row, signed `(dx,dcount)` bytes, signed 16-bit `du,dv`; exact modulo-16-bit recurrence, length 3..256 |
| Frame footer, 6 words | end magic `$5AA5`, 32-bit frame id, actual packet count, actual word count, CRC-16 over header through last row |

The decoder stops each packet after `row_count` logical rows, counting both
`ROW_ABS`/`RUN16` rows and `ROW_SKIP` rows, so RLE does not need a forward
body-size field.  `RUN16` is selected only when seven words beat the
corresponding absolute rows; it can never expand geometry.  Shade control can
add at most one word per row.  The packet header carries the horizontal U/V
gradients because the M68030 still advances U/V inside the pixel loop; their
low 16 bits are sufficient because the sampled coordinates are modulo 16
bits.  `y_start` anchors the logical row sequence, including empty rows.  The
model round-trips absolute, shade-change, signed-delta and 16-bit-wrap
fixtures, accepts an empty-row fixture, and rejects malformed or trailing
words.

The first implementation slice now also defines a **compact-record shadow
stream**.  It is deliberately a host-side mirror of the existing
`GET_TRIANGLES` result, not a second live DSP producer: the host can copy each
18-word packed DSP record before the normal 22-field unpack and compare the
two paths without changing rendering.  Its records are:

| Record | Exact contents |
|---|---|
| Compact record, 39 words | `$D012`, 32-bit global source triangle, then 18 native DSP words as `(zero-extended high byte, low 16 bits)` pairs |
| Compact frame header/footer | Same 8/6-word framing and CRC as the span stream; bit 15 of version/flags is `COMPACT_RECORD_FLAG` |

The 24-bit expansion is intentionally not presented as the final bandwidth
format.  It is word-aligned and preserves every DSP bit, which makes it a
useful transport and field-comparison baseline.  `tools/ssi_stream_model.py`
round-trips the compact frame, rejects non-zero padding or CRC corruption, and
`TREX/m68030/ssi_dma.s` exposes `ssi_dma_pack_compact_record` plus the
`ssi_dma_shadow_begin`, `ssi_dma_shadow_append_record`, `ssi_dma_shadow_finish`
and `ssi_dma_shadow_abort` state machine.  The latter
writes the same header/footer, reserves footer space on every append, and
updates CRC-16 over the payload.  At the current 1,018.96 survivor/packet
estimate this shadow is approximately **79,507 bytes/frame** (`28 + 1,018.96
* 78`), an estimate rather than a captured DMA bandwidth result.

The optional `trex_m68030_ssi_shadow` target links that builder into a separate
diagnostic binary.  Its frame path calls `begin`, appends each raw
`GET_TRIANGLES` survivor before the normal unpack, then calls `finish` or
`abort` on fallback.  The data path remains host-port-only: initialization
only runs the stopped ownership/read-back probe, and no live SSI producer or
DMA transfer is started.  Its successful link is not a hardware transport
result.

The first end-to-end host-port check passed under Hatari 2.6.1, TOS 4.02,
Falcon mode, 4 MB ST-RAM and DSP emulation on 2026-08-19.  The optional binary
wrote `TREX/m68030/ssi_shad.res` for frame 0; the Python decoder accepted its
header/footer/CRC and found 854 records in 33,320 words (66,640 bytes), with a
declared capacity of 40,000 words and footer CRC `$4F0D`.  This is an emulator
framing/copy result only.

The same optional binary now calls the owner during initialization.  It does
not start DMA; it claims the channel, performs the post-`Devconnect` raw
Crossbar read-back gate when reached, writes `TREX/m68030/ssi_route.res`, and
releases the channel before DSP shutdown.  The five signed big-endian
longwords are `claim_result`, `route_result`, `claim_stage`, raw source, and
raw destination.  The 2026-08-19 Hatari report was `[-1, -2, 2, 0, 0]`:
the conservative idle-DMA snapshot gate rejected the emulator's inherited
sound state before `Devconnect`, so `route_result=-2` means “validator not
reached.”  This is a useful safe-refusal result, not a route or DMA success;
physical Falcon read-back remains outstanding.

The separate `trex_m68030_ssi_rows` target now shadows the same validated
`gpu_packet_buffer` as complete clipped rows.  Its nine-word packet header
adds `y_start`; `ROW_SKIP` preserves thin-triangle rows whose X interval is
empty, while `ROW_ABS` carries the clipped X/count and Q8.8 U/V start.  This
target emits frame 0 once, writes `ssi_rows.res` and a six-longword
`ssi_rows.status` sidecar, and a `ssi_rows.pkt` packet sidecar for independent
verification; live SSI/DMA remains disabled just like the compact target.  A
Hatari 2.6.1/TOS 4.02/Falcon/DSP-emulation run on 2026-08-19 produced 854
packets, 4,090 logical rows, 2,257 non-empty rows and 1,833 `ROW_SKIP` rows in
16,304 words (32,608 bytes), with footer CRC `$6914`.  The Python decoder and
`make ssi_rows_verify` independently recomputed and matched every packet
header and row event.  These are measured emulator framing/copy results, not
physical DMA throughput or image-equivalence results.  Gouraud produced no
`SET_SHADE` changes in this frame.

The `trex_m68030_ssi_hatari` target now implements the first running end-to-end
transport-to-rasterizer version.  It builds the same full-row stream, hands the
completed buffer to `ssi_dma_hatari_consume_frame`, and then feeds the validated
rows into the existing resolved pixel bodies.  The consumer accepts a buffer
only after checking the row-frame header, packet markers, logical row counts, X
bounds, footer frame/count/length and CRC.  The Hatari-only handoff then walks
the existing far-to-near Ordering Table, maps each host packet to its stream
packet, and calls the direct texture/CLUT pixel entry with the SSI row's clipped
X/count/U/V/Y/shade state.  `ROW_SKIP` advances logical Y without entering a
pixel body; the normal CPU DDA is not advanced by the feed path.

The status sidecar is the 23-longword `ssihatri.sta` (an 8.3 GEMDOS name).
Fields 0-13 publish the parser result and rasterized-pixel count; fields 14-22
publish the pending-frame handoff, OT nodes visited, mapped packets, row
callbacks, status writes, resolve progress, visible-map count, map misses and
the first missing host index.  The 2026-08-19 Hatari 2.6.1/TOS 4.02/Falcon/
DSP-emulation run accepted all **16,304 words**, **854 packets**, **4,090
logical rows**, **1,833 `ROW_SKIP` rows**, and CRC `$6914`; the feed visited and
mapped **854/854 OT nodes**, reported **0 map misses**, entered **2,257
non-empty row callbacks**, and counted **4,679 rasterized pixels**.  `make
ssi_hatari_verify` independently matched the transport counters and complete
packet DDA.  These are measured Hatari/emulator results, not physical Falcon
SSI/DMA bandwidth or a physical-framebuffer result; the target still does not
start SSI/DMA or exercise Crossbar registers.

For the pixel handoff gate, paired Hatari capture builds with
`-DTREX_DUMP_FRAME=0` produced byte-identical `fb.res` files for the normal CPU
renderer and the SSI-fed renderer: `cmp` returned zero differences and both
files hashed to
`cacebce2809290265d90d2a6af044691b2a6f681e350d1d90a5d1902bbd67b5b`.  This is a
measured frame-0 emulator equivalence check; it does not establish physical
Falcon DMA/cache behavior or equivalence for the later choreography frames.

The `trex_ssi_loopback` target packages the same path as `TREXSSI.TOS` with a
matching `TREXSSI.LOD`, so it can be copied to a physical Falcon without
renaming the DSP file. This is a Falcon-runnable software loopback, not the
physical SSI implementation: the 68030 builds and consumes the in-memory
stream, while the SSI, Crossbar and record-DMA registers remain untouched.
It is intended to establish real-machine startup, memory-budget and
framebuffer behavior before the physical owner/consumer gate is enabled.
The loopback produces its frame-0 sidecars once; later frames deliberately
fall back to the normal CPU rasterizer. No physical-Falcon FPS or DMA result
is claimed by this artifact.

The feed is deliberately Hatari-gated.  The shipping CPU path retains its
normal OT walk and pixel entry, while the Hatari path keeps the resolve pass,
skips its normal OT draw, and consumes the validated row stream in painter's
order.  A real DMA consumer must preserve the same complete-buffer boundary,
generation/frame/count/length/CRC checks and fallback behavior before this
handoff can be moved onto hardware.

Ownership is ping-pong, not a ring with ambiguous readers:

```text
buffer A: M68030 read-only, rasterizing frame N
buffer B: DMA-RECORD write-only, DSP producing frame N+1
boundary: stop/complete -> verify generation/frame/count/length/CRC -> swap
failure : do not swap; discard B and use the existing host-port/CPU path
```

Each buffer is **192 KiB**, 384 KiB total.  With the corrected nine-word
packet header, the rounded full-mesh cost model is approximately 92,977 bytes
for ABS rows and 117,856 bytes with a shade control on every row, before any
`ROW_SKIP` overhead.  These are estimates from 12,439.35 rows and 1,018.96
packets per frame; no compression
credit is taken until real DSP rows have been captured.  The earlier 86,892 /
111,770 figures belonged to the superseded six-word header and must not be
used for buffer sizing.  The asset-level
geometric worst case is 2,724 x 224 rows: 3,693,772 ABS bytes or 4,914,124
bytes with a shade control on every row.  Therefore the DSP must reserve footer
space, stop before capacity, write an overflow footer and force the fallback;
192 KiB is an observed-corpus bound, never an unconditional geometry bound.

#### 7.4b The route runs: live DSP-XMIT to DMA-RECORD transfer

`make trex_m68030_ssi_dma` builds `trex_ssi_dma.tos`, the first and only
target that claims the sound channel, routes the Crossbar and **starts the
record engine**.  Every other SSI target is host-port only.  It runs one
framed burst before the renderer starts, hands the channel back, and then
renders normally through the unchanged host-port path.

Three defects had to be fixed before anything could move, and each is worth
recording because none of them would have produced a diagnosable failure:

1. **The route was validated against the wrong register fields.**  See the
   correction in step 3 above.  The gate compared `$FF8930 & $F000` with
   `$C000` and `$FF8932 & $0F00` with `$0100`, which are the A/D converter and
   external-output fields.  On a correctly routed Falcon it fails.
2. **The claim gate rejected an idle machine.**  It refused to proceed when
   any of the low four bits of `$FF8900` were set.  Those bits are
   end-of-buffer interrupt *source selects*, and their power-on value is
   `$05` -- Hatari resets the register to exactly that.  A quiescent machine
   that had never played a sound was therefore rejected before `Devconnect`,
   which is precisely the `claim_stage 2` / `route_result -2` result the
   2026-08-19 run reported.  `$FF8900` is still captured and restored, and
   `Setinterrupt` is still never called; the gate is now the two ENABLE bits
   of `$FF8901` alone.  The mask used for that was also wrong: `$000F`
   covered two undefined bits and missed **record** enable at bit 4, so it
   could not have rejected an inherited recording client -- the one case it
   exists for -- while rejecting a repeat flag left by a stopped one.  It is
   now `$0011`.
3. **Every XBIOS return was tested against zero.**  The sound XBIOS calls do
   not share one success convention: `Locksnd` answers 1, several answer 0,
   and `Soundcmd`/`Devconnect` answer a previous setting.  A healthy machine
   was rejected at `Soundcmd`, which returned `2`.  The gate is now the
   XBIOS-wide one -- negative is an error -- and all thirteen raw returns are
   published in the sidecar.

The producer is new.  `CMD_SSI_STREAM` (`$40`, in the DSP's previously
single-member bit-6 control range) configures the SSI for 16-bit transmit,
switches PC5 to a GPIO output and drives it by hand as the handshake frame
line, then transmits a host-authored 8-word header, a generated ramp payload
and a host-authored 6-word footer.  It costs 103 DSP program words; the
program now ends at P:`$0985` against the P:`$09BF` ceiling.  The frame
envelope is host-authored on purpose, so the *entire* expected frame --
including its CRC-16/CCITT-FALSE -- exists on the host before the transfer and
the capture is checked by compare rather than re-derived from whatever
arrived.  The payload is a ramp rather than a pseudo-random pattern because a
ramp localises a transport fault to an index instead of only reporting
"wrong".

Ordering is not negotiable: the record window is armed **before** the DSP is
told to transmit, because the handshake makes DMA-RECORD the master and a
stopped channel never clocks the SSI; and the DSP's reply is collected
**after** the transfer, because it does not answer until its burst is done.
Both waits are bounded -- the host on the 200 Hz tick, the DSP on a spin
count that collapses to a single test after the first stall -- so a dead
route reports rather than hanging the machine.

**Measured, Hatari 2.6.1 (corrected DSP clock), TOS 4.02, Falcon, 4 MB
ST-RAM, DSP emulation, 2026-08-20.**  A frame of **16,304 words / 32,608
bytes** -- deliberately the exact size of the measured frame-0 full-row span
stream -- moved over the route and arrived byte-exact:

| Field | Value |
|---|---|
| claim | stage 13, route validated |
| `$FF8930` / `$FF8932` read-back | `$00C0` / `$0002` |
| raw field write needed after `Devconnect` | **no** |
| pre-claim `$FF8901` / `$FF8900` | `$00` / `$05` |
| armed `$FF8901`, `$FF8935`, `$FF8920/21` | `$10`, `$01`, `$0043` |
| CACR during the transfer | `$00003111` (both caches enabled) |
| transferred | 32,608 bytes, all 16,304 words |
| elapsed | 26 ticks of the 200 Hz clock = 130 ms |
| DSP reply | `ACK_SSI_STREAM`, stall status 0 |
| capture vs. host expectation | identical, footer CRC `$0809` |

`make ssi_dma_verify` re-derives the payload, the footer counts and the CRC
from the capture's own header and confirms the same verdict independently of
the on-target compare.

The failure contract was exercised, not just written.  A fault-injected build
that skips the arm step leaves the Crossbar with nothing to clock, which is
the worst case for a route where the sink is the master.  Measured on the same
configuration: the DSP abandoned its burst and answered `ACK_SSI_STREAM` with
stall status 1; the host's wait returned -1 after its full 400-tick timeout
with **0 bytes** moved; the compare reported index 0, got `$DEAD` (the poison
the probe writes into the window beforehand), expected `$5353`; `make
ssi_dma_verify` rejected the run naming the clear record-enable bit; and the
renderer went on to complete 34 normal frames.  A bring-up probe whose failure
mode is a hung machine reports nothing, so this path matters as much as the
success path.

Two findings from that table deserve to be separated from the pass/fail:

- **TOS 4.02's `Devconnect(1, 1, 2, 1, 0)` already produces the exact raw
  fields.**  The masked read-modify-write this file specifies was a no-op on
  this configuration.  It is retained because it costs nothing and removes a
  dependency on a particular TOS revision, but the read-back gate -- not the
  forced write -- is what makes that safe to say.
- **130 ms for 32,608 bytes is 245 KB/s, and that is Hatari's number, not the
  Falcon's.**  Hatari clocks handshaked DMA-record from its sample-rate
  interrupt: one word per `CPU_Freq / rate / playTracks / 2` cycles, which at
  16 MHz, divider 1 (62,500 Hz) and one track is 128 CPU cycles per word =
  125,000 words/s = 250 KB/s.  The measurement lands on that structural
  ceiling to within the tick resolution, which is good evidence the transfer
  really is being clocked by the emulated Crossbar -- and equally good
  evidence that it says nothing about the Falcon's specified 8 Mbit/s = 1 MB/s
  wire rate.  On hardware the handshake gates a free-running serial clock
  instead.  **A physical-Falcon transfer time is still outstanding and cannot
  be obtained from this build.**

The cache coherency gate is now implemented rather than absent.  The record
engine writes system RAM without the 68030 seeing the bus cycles, so
`ssi_dma_invalidate_dcache` clears every data-cache entry (CACR bit 11, `CD`)
before the host reads the capture.  The 68030 data cache is write-through, so
there is nothing dirty to push and a bulk invalidate is the complete
contract; the CACR image above confirms the data cache was in fact enabled
during the transfer, so this is a real requirement and not a no-op.  It
covers a buffer the CPU reads *after* the transfer, which is why the
transport waits for the declared end address first; it does not make a buffer
safe to read while DMA is writing it.  **Physical-Falcon confirmation is
still outstanding**: Hatari does not model the 68030 caches' interaction with
DMA at all, so this build cannot distinguish a correct contract from a
missing one.

What Hatari still cannot close: physical SSI timing, real cache behaviour,
bus contention against true-colour Videl, and DMA data ownership on hardware.
The first hardware implementation must field-compare every decoded row
against the existing host record before it is allowed to feed the rasterizer.

#### 7.4a Implementation plan and current slice

Implementation is deliberately staged so every failure can return to the
existing host-port path:

1. **Offline model — implemented.**  `tools/ssi_stream_model.py` defines the
   canonical words, CRC-16/CCITT-FALSE, `ROW_ABS`, `ROW_SKIP`, `SET_SHADE`,
   `RUN16`, packet gradients and Y anchoring, compact 24-bit record framing,
   capacity checks and decoder self-tests.  `make
   ssi_stream_model_test` passed on 2026-08-19 in the repository environment;
   this is a host-side protocol result, not a Falcon transport measurement.
2. **Physical transport test — implemented and running in emulation.**  The
   common sound/DMA XBIOS wrappers and `TREX/m68030/ssi_dma.s` owner are
   present.  The owner captures/restores idle DMA and Crossbar state under
   `Supexec`, leaves MFP interrupts untouched, rejects an inherited *running*
   channel, and follows `F030MXDRV`'s proven lock, stop, explicit matrix setup
   and reverse cleanup.  `make trex_m68030_ssi_dma` now completes the whole
   route: claim, raw Crossbar read-back, armed one-shot record window, a DSP
   SSI producer (`CMD_SSI_STREAM`), the declared-end completion gate, the
   data-cache invalidate and a full-frame compare.  Its 2026-08-20 Hatari run
   moved 16,304 words byte-exact; section 7.4b has the table and the three
   defects that had to be fixed first.  The optional `trex_m68030_ssi_shadow`
   target still records only the claim gate and raw route fields in
   `ssi_route.res`, with the channel stopped.  The remaining hardware step is
   to run the same probe on a physical Falcon and to compare RXDF-polled PIO,
   block-gated blind PIO and handshaked SSI DMA there under true-colour Videl
   load.  `make ssi_dma_compile_test` only checks assembly; `make
   ssi_dma_verify` checks an emulator capture.  Neither is a hardware or
   throughput result.
3. **Compact-record mirror — host-shadow integration implemented.**
   Before the normal `GET_TRIANGLES` unpack, copy the 18 raw DSP longwords plus
   the global chunk base into the compact 39-word form, frame it, and validate
   it with the executable model.  The assembly packer and the
   begin/append/finish/abort builder now enforce capacity and CRC rules; the
   optional `trex_m68030_ssi_shadow` binary calls it from the chunk drain while
   the normal renderer remains unchanged.  The Python round-trip fixture and
   the Hatari-generated `ssi_shad.res` artifact both decode successfully.  The
   optional owner probe is separate and leaves DMA stopped; the live DSP-SSI
   producer and physical DMA sink remain disabled.  The next gate is to route
   this same builder's buffer through the owned record channel, then compare
   every source index, native word, footer count and CRC against the host-port
   transaction on hardware.
4. **Full-row shadow stream — host-shadow integration and independent
   verification implemented.**  The
   optional `trex_m68030_ssi_rows` target walks the exact validated packet
   setup, applies the CPU path's Y/X clipping, U/V prestep and shade clamp,
   and emits `ROW_ABS`/`ROW_SKIP` records with packet `y_start`.  Its Hatari
   frame-0 artifact decoded successfully on 2026-08-19; this validates
   framing, capacity, CRC and row-count alignment.  `tools/verify_ssi_rows.py`
   then recomputes the DDA from `ssi_rows.pkt` and matches every packet/event
   in the decoded stream.  This is still not physical SSI or byte-identical
   framebuffer output; the next gate is the same comparison over two
   revolutions and the synthetic hold.
5. **Hatari transport loopback and rasterizer feed — implemented.**  The
   `trex_m68030_ssi_hatari` target hands the completed row buffer to an
   in-memory DMA consumer, validates framing/packet-row accounting/bounds/
   footer/CRC, resolves packet texture state once, and feeds the existing
   pixel bodies in OT order.  The sidecar's 854-node/854-packet/0-miss result
   and 2,257 row callbacks are checked by `make ssi_hatari_verify`.  This closes
   the emulated transport-to-rasterizer boundary but not the Falcon SSI/DMA,
   cache-coherency or physical-framebuffer gates.
6. **Physical same-frame stream consumer.**  Port the validated Hatari handoff
   to the owned DMA buffer, retaining the complete-buffer boundary and the
   host-port rebuild fallback for overflow, timeout, CRC or cache failure.
   The transport underneath it now exists and is exercised end to end
   (7.4b); what is missing is a DSP that emits real span rows rather than a
   generated ramp, and a physical machine to measure it on.
7. **Cross-frame overlap.**  Only after same-frame correctness and hardware
   throughput are measured: DMA frame N+1 into the inactive 192-KiB buffer
   while the M68030 rasterizes frame N.  Static UV input requires either a DSP
   memory rebalance or SSI playback DMA; that combined path is a separate
   hardware gate.

The stream packet parser must build the complete OT before rasterization.  A
packet cannot be drawn as it arrives because painter's visibility depends on
the far-to-near OT walk.  DMA buffers are therefore ping-pong owned: the CPU
reads one, DMA writes the other, and a buffer swaps only after pointer,
generation, frame ID, word count and CRC validation.

### 7.4a Record-stream contract -- frozen and proved offline

This is the format for the scope the SSI plan actually calls for first,
**DSP -> CPU result records only**, with animation and control traffic left on
the host port.  It is implemented and self-testing in
[`tools/ssi_stream_model.py`](tools/ssi_stream_model.py).

**The payload is the existing 18-word packed span record, unchanged.**  Nothing
about the record's meaning is reopened: `SPAN_RECORD_WORDS` in
`TREX/dsp/trex_dsp.asm` and `DSP_SPAN_RECORD_WORDS` in `trex_m68030.s` are the
two ends of a contract already validated field-for-field over two revolutions
(4.1b).  Only the framing is new, so only the framing needs proving.

**Correction to 9.2 found while transcribing it.**  Section 9.2 states the
record travels "packed at fourteen words" and lists `uv0pack`/`uv1pack` as
wire fields.  Both are stale: the constant is **18** in both sources, and the
sorted UV byte pairs are not transmitted at all -- the host rebuilds them from
`gpu_texture_meta_buffer` through the two slot ids in w0.  8.2a's "eighteen
words" was the correct figure.

Encoding, big-endian throughout:

| Element | Units | Contents |
|---|---:|---|
| Frame header | 8 | magic `$5353`, version/flags, 32-bit frame id, mesh id, buffer generation, 32-bit capacity in units |
| Record | 36 | the 18 packed words, each as two units: `(w >> 16) & $FF`, then `w & $FFFF` |
| Frame footer | 8 | magic `$5AA5`, status, 32-bit frame id, record count, 32-bit actual unit count, CRC-16/CCITT over everything preceding |

**Two units per 24-bit word, with no width-aware packing.**  w0 is provably
16 bits, w4 is 12, and w14 is two 12-bit fields, so a tighter packing would cut
36 units to about 31 -- roughly 14%.  It is deliberately rejected: 2.4c prices
the entire host port at 14.2 ms/frame, so a width-aware format buys 14% of a
14-ms term and pays with a silent corruption mode the first time any field
outgrows its assumed width.  Two units per word is lossless for all 2^24
patterns by construction and needs no per-field range assumption.  If a future
measurement ever makes the wire matter, this is a one-constant change.

**Buffer sizing, and a real difference from the row stream.**  A record stream
is bounded by triangle count, not by coverage, so its worst case is a number
the mesh cannot exceed:

| Case | Records | Bytes | KiB |
|---|---:|---:|---:|
| Average frame (8.2a) | 1,149 | 82,760 | 80.8 |
| Armed prepass capacity (2.3f `PREPASS_MAX`) | 1,335 | 96,152 | 93.9 |
| **Geometric maximum, every triangle survives** | 2,724 | 196,160 | **191.6** |

The geometric maximum fits in 192 KiB, which the row stream could never claim
-- 7.4 had to call its 192 KiB "an observed-corpus bound, never an
unconditional geometry bound."  **But the margin is 448 bytes, 0.2% of one
buffer.**  One more 24-bit word in the record costs 10,896 bytes and overflows;
a 19-word record needs 202.2 KiB.  This pipeline has changed the record width
before (17 to 18 words for the Gouraud level starts), so **size the pair at
2 x 256 KiB if the memory map can afford it** rather than copying 192 KiB
across from the row-stream section.  The overflow path stays implemented and
tested either way: a wedged DSP or a capacity field corrupted in transit has to
fail closed.

**What the self-tests prove** (198,912 checks, fixed seed, reproducible):
lossless round-trip of the word codec over all 24-bit boundary and single-bit
patterns plus 200,000 random draws; whole-frame round-trip at 0, 1, 2, 31, 32,
33, 1,149, 1,335 and 2,724 records; and rejection of every corruption the DMA
path can produce -- truncation, one-unit shift, trailing unit, odd length,
single-bit flips at six positions, stale frame id, stale generation, a dropped
record, a torn ping-pong buffer built from two frames, a stale footer left by a
longer previous frame, and encoder-side malformed input.  Decoding is
all-or-nothing by design: there is no resynchronisation, because a half-good
buffer silently reaching the rasterizer is exactly the failure this envelope
exists to prevent.

**What it does not prove.**  Nothing about crossbar setup, DMA ownership, cache
coherency or achieved bandwidth -- 7.4's two hardware gates are untouched and
still block activation.  At the specified 1 MB/s ceiling the average frame is
82.8 ms and the geometric maximum 196.2 ms, against the 275.3 ms window outside
the packet stage (2.4c): a 30% duty cycle typically and 71% at worst, contending
for ST-RAM with a rasterizer that 2.5 already measured sitting at the memory-bus
floor.  And the framing has not been run against captured DSP output; it does
not need to be for format correctness, since the 18 words are opaque to it and
already validated, but the first hardware bring-up must still field-compare
decoded records against host-port-delivered ones exactly as 4.1b did.

**The reason to build this remains the one 2.4c established**, not the one this
chapter was written for: the transfer it replaces is worth 14.2 ms, and the
case for the stream is the ~173 ms of exposed DSP time it lets the CPU overlap.

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
would no longer service 86 result-chunk transactions. The 112.7 ms stage quoted
in the rest of this paragraph is the LOD epoch's; **section 2.4b supersedes it
and isolates the shares this sentence said had not been isolated**. Of the
current **252.1 ms** stage, about 177 ms is DSP-rate-sensitive and about 83 ms
is CPU-side unpack and packet build, while the host port's own wait states
measure **zero** — forcing every one of them to zero moves the frame 0.1 ms.
The split was taken at 259.7 ms, before 2.4d's light cache removed 7.6 ms of
it; the shares are quoted unrescaled because the cache changed what the CPU
side fetches, not how the stage divides.

That relocates the case for DMA. It is not a wait-state bill to be avoided: it
is that the frame loop schedules nothing against those ~177 ms, so the CPU holds
still through them while 243.7 ms of rasterizing waits behind. Cross-frame
overlap (7.4a step 7) is where that goes, and DMA is what makes the overlap
possible, since PIO forces the CPU to choose between transferring and
rasterizing. Note also that the direct saving looks small here partly because
2.4a's core charges nothing for executing the transfer loop and models no Videl
contention, so PIO's real cost on a Falcon is invisible to this measurement by
construction — which is a reason the comparison in 7.4 has to be run on
hardware, not a reason to discount DMA. Animation input
(4,933 words/frame average) would still use the host port unless a separate
host-to-DSP DMA design were added.

**Those shares have since been isolated, and they invert this section's
premise (2.4c).** In the corrected-clock full-mesh frame the 260.40 ms packet
stage is ~173 ms exposed DSP compute, ~73 ms host CPU unpack/packet-build and
**14.2 ms of host-port wait states**. Zeroing the host port entirely measures
519.7 ms against 535.7 — transport work of any kind is worth **+0.06 FPS**.
What SSI/DMA is worth here is therefore **not the transfer it removes but the
overlap it enables**: hiding ~173 ms of DSP time behind CPU rasterization is an
order of magnitude larger than the wire. Every paragraph below that sizes this
optimization by multiplying a word count by 2.3 us understates the DSP term and
overstates the wire by roughly 4x; they are retained as the reasoning of their
epoch, with the arithmetic corrected in 8.2a.

### The arithmetic, and its open question

The sound DMA frames 16-bit words; the record's slope fields are genuine
24-bit values and need two DMA units each. Record volume varies with survivor
count: roughly 10k-14k DSP words becomes 40-56 KB of 16-bit-framed output. At
the Falcon's specified 1 MB/s ceiling this is 40-56 ms per frame. It fits
inside the CPU rasterization window if truly asynchronous — that window is
**243.7 ms** on the corrected emulator (2.4b, re-measured for 8.2 on
2026-08-20), not the 333.2 ms of the LOD epoch this paragraph was written
against, so the margin is narrower and the conclusion unchanged.
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

**The multiplies have not moved yet, and it is worth being exact about
where they are.**  The row-stream *consumer* is already clean:
`ssi_hatari_rasterize_row` takes the Q8.8 U and V straight from the stream,
derives the framebuffer address with shifts alone (`lsl.l #8` plus two
doublings for the 512-byte stride and the 2-byte pixel) and jumps directly to
the resolved pixel body, so it never enters `span_walk_half` and executes
**zero** `MULS.L` per row.  The *producer* is not: the `TREX_SSI_ROWS` builder
runs the identical prestep pair, plus two more for the left-clip catch-up,
because in every build that exists today the **host** constructs the stream.
The multiplies therefore moved from the walker into the stream builder, on the
same CPU in the same frame -- a relocation, not an offload.  The 68.4-ms bound
below is only recovered once the DSP emits the rows (7.4a steps 6 and 7); the
7.4b transport probe transmits a generated ramp and does not move it either.

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
plus the pixel loop and removes the whole edge/ceil/clip walk. The corrected
model adds the packet's low-16-bit `du/dx` and `dv/dx` values plus a signed
`y_start` as three header words, so the rounded full-mesh estimate is
approximately 93.0 KB/frame for ABS rows and 117.9 KB with a shade control on
every row, before `ROW_SKIP` overhead. Those are 93.0 and 117.9 ms at the
specified ceiling. They fit on paper, but unlike the U/V-only
stream this is not merely a multiply offload: ST-RAM contention, CPU decode,
DSP production time and cache invalidation still require physical measurement.

That decomposition and the exact packed format now exist.  For the full mesh,
274 recorded frames average **12,439.35 walked rows and 1,018.96 packets**;
the observed maximum is 18,181 rows.  U/V-only is 49,757 bytes/frame, or 49.8
ms at the specified ceiling.  The section 7.4 three-word ABS row plus
nine-word packet headers is approximately 92,977 bytes/frame (93.0 ms) from
the rounded corpus averages, before `ROW_SKIP` overhead; an adversarial shade
change on every row raises
the model to approximately 117,856 bytes (117.9 ms).  `RUN16` may reduce those
figures but the budget credits **zero** compression until real DSP rows have
been captured.

**Every rasterization window quoted in this section belongs to the pre-3.9
epoch and has since shrunk by a third to a half.**  The LOD window is 180.7 ms
rather than 333.2, and the full-mesh one 272.0 ms rather than 544.3.  A stream
sized to "fit inside the window on paper" therefore has to be re-checked
against the current figures before any of these paragraphs is acted on: the
93.0-KB no-RLE full stream is 93.0 ms nominal against a 272.0 ms window, which
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
charges much CPU arithmetic zero.

**Re-measured on the corrected-clock emulator, 2026-08-20.**  The two older
columns were taken on stock Hatari, which ran the Falcon DSP at twice its real
rate (2.4b), and they are kept only as the shape of the 3.9 result.  The
current column is the shipping diagnostic build on the corrected emulator,
over the same converged 265-frame prefix, with the section 3.5 profile patches
re-taken on that build:

| Full-mesh component, converged prefix | Before 3.9 (stock clock) | After 3.9 (stock clock) | **Current (corrected clock)** |
|---|---:|---:|---:|
| DSP setup + host readback + packet build | 189.1 ms | 186.3 ms | **252.1 ms** |
| Raster per-packet setup | 95.3 ms | 91.2 ms | **68.5 ms** |
| Raster row/span walk | 303.9 ms | 112.6 ms | **112.7 ms** |
| Raster pixel loops | 145.1 ms | 68.2 ms | **62.5 ms** |
| Set-frame send + clear + OT + rounding | 30.3 ms | 30.5 ms | **30.8 ms** |
| **Total** | **763.7 ms / 1.31 FPS** | **488.8 ms / 2.05 FPS** | **526.6 ms / 1.90 FPS** |

`make measure_split` reproduces this.  The three patch builds measured 526.6,
464.1 and 351.2 ms per frame (normal, `TREX_PROFILE_NO_PIXELS`,
`TREX_PROFILE_NO_ROWS`), each converged to exactly 265 frames, with the normal
build's frame-100 `fb.res` reproducing `d89958b3…3d16`.  The packet stage
reads 252.1, 252.3 and 252.2 across them, which is the cross-check that the
patches touch only the rasterizer.  An independent second set of three runs
agreed on every term to 0.2 ms, which is the precision to attach to these
figures: the timers are 200 Hz ticks over 265 frames, so one tick either way
is 0.02 ms and a few ticks of scheduling jitter is all the spread there is.

**The correction lands entirely in the packet stage, exactly where 2.4b says
it must.**  Against 8.2a's stock-clock measurement of the same code family,
the three rasterizer terms reproduce to 0.7 ms -- 112.7 against 113.4, 68.5
against 68.3, 62.5 against 62.2 -- while the packet stage moves 185.7 to
252.1.  The DSP clock is not a term in the CPU rasterizer and is most of the
term in the stage that waits on the DSP.  **The total is therefore worse than
the 488.8 ms this section used to claim.**  No corrected-clock measurement of
that exact build exists, but the mechanism is not in doubt: 8.2a measured the
*same binary* at 460.0 ms stock and 534.2 ms corrected, so a Falcon-rate DSP
was always going to add something near 74 ms to the 488.8 figure as well.
That number described an emulator, not a Falcon.

**Section 3.9 still moved this gate by more than any transport ever proposed
for it, and it did so on the CPU side of the host port** -- that conclusion
was measured on the rasterizer, which the clock correction does not touch.
What changed is the distance left: **193.3 ms**, not the 155.5 ms this section
recorded against the inflated baseline.  Everything below is re-derived on the
current column.

Removing the entire row walk now leaves **413.9 ms / 2.42 FPS** -- still short,
so the shape of the old conclusion survives: a U/V-only offload, whose
hardware ceiling is only the 68.4-ms multiply bound, cannot close three FPS.
After ideal row removal the design needs a further **80.6 ms** out of a
252.1-ms packet/readback stage and a 68.5-ms packet setup -- **32% of the
packet stage**.  On the stock-clock figures that read 42.9 ms and 23%, so the
combined lever this section recommends is harder than it looked, not easier.

The optimistic architectural envelope -- full row walk and the entire current
packet/readback stage both gone -- is **161.8 ms / 6.18 FPS**, against a
target of 333.3, with **171.5 ms** of margin.  That envelope *improved* on the
corrected clock, and the improvement is an artefact rather than a gain: the
envelope assumes the packet stage away entirely, so charging more to it makes
the envelope look roomier while making the real frame slower.  Read the margin
only as headroom for what the envelope does not model -- CPU packet material
and OT construction cannot be literally zero, a 93.0--117.9-KB DMA stream
still writes and is later read from ST-RAM, and DSP construction has a real
cost.

Two consequences for what to build next:

- **The remaining frame is dominated by the packet/readback stage**, not by
  the row walker the SSI stream was designed around, and not -- as the
  stock-clock column suggested -- by per-packet setup either.  At 252.1 ms it
  is 47.9% of the frame on its own.  Per-packet setup is now **68.5 ms** for
  1,149 packets, or 953 cycles each at 16 MHz, down from the 91.2 ms and
  1,270 cycles this section used to argue from; 3.9b/3.9c already took most of
  what was there.  The 252.1-ms stage is where the next 193.3 ms has to come
  from, and 7bece90 measured its internal split: about 177 ms DSP-rate-
  sensitive, about 83 ms CPU-side unpack and packet build, and **zero** host
  port.
- **Roadmap item 19 got relatively more attractive, not less.**  Occlusion
  culling removes whole survivors, and a survivor now costs proportionally
  more in packet setup and wire transport than in row walking.

Revised verdict:

- **3 FPS full mesh: still not demonstrated.**  193.3 ms is the gap, and
  unlike the 155.5 ms figure it replaces, most of it now sits in a stage whose
  dominant term is the DSP waiting to finish -- which is an argument for
  cross-frame overlap (7.4a step 7), not against transport work.  It is no
  longer true to say the gap is purely a host-side optimization target of the
  size section 3.9 met twice over.
- **The former 1,600-triangle LOD reached 3 FPS, but it is removed.** Its
  319.8 ms / 3.13 FPS result remains a historical data point only, and a
  stock-clock one; the supported build is the full mesh and has no 3-FPS
  emulator result at any clock.
- **U/V-only SSI: insufficient** even under its best arithmetic bound, since
  the row walk it targets is 112.7 ms.
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

Measured over 265 frames on **stock Hatari**, frame-100 `fb.res` reproducing
the recorded full-mesh checkpoint `d89958b3…3d16`, with the section 3.5
profile patches re-taken on the same build:

| Component, stock clock | ms/frame | share |
|---|---:|---:|
| DSP readback + packet build | **185.7** | 40.4% |
| Raster row/span walk | 113.4 | 24.7% |
| Raster per-packet setup | 68.3 | 14.8% |
| Raster pixel loops | 62.2 | 13.5% |
| set_frame + clear + OT + rounding | 30.4 | 6.6% |
| **Total** | **460.0 ms / 2.17 FPS** | |

The packet stage reads 185.7, 185.7 and 186.0 across the normal and both
profile builds, which is the cross-check that the patches touch only the
rasterizer.

**This whole table is pre-2.4b and is retained as the stock-clock reference
only.**  Section 8.2's current column supersedes it: the same split re-taken
on the corrected emulator, after 2.4d's light cache, is 252.1 / 112.7 / 68.5 /
62.5 / 30.8 for **526.6 ms / 1.90 FPS**.  The four non-packet terms reproduce
this table to 0.7 ms, and the packet stage grows 185.7 to 252.1 -- 2.4d's
light cache removing 7.6 ms of what the clock correction added.  **The
distance to 333.3 ms is 193.3 ms**, not the 126.7 ms this section derived from
the inflated baseline.  The two named levers below total about 66 ms, which
lands near **461 ms / 2.17 FPS**, so this section's conclusion that three FPS
does not follow from any identified optimization holds with a good deal more
room to spare.

**Section 8.2's own next-step suggestion is measured out.** It proposed
applying section 3.9's rule -- shrink the loop below the 256-byte instruction
cache -- to the packet stage.  Listing accounting on the three
per-survivor host loops says there is nothing there to get: the packet builder's
body is **130 bytes**, `gpu_submit_ot`'s is **62**, and 3.9c's resolve sweep is
**118**, all comfortably inside the cache, and the record-unpack loop was
already pinned to 250 bytes by 3.9 step 4.  Whatever that stage is, it is not
loop-body eviction.  7bece90 later split it directly on the corrected build:
of 252.1 ms, about 177 ms is DSP-rate-sensitive, about 83 ms is CPU-side
unpack and packet build, and the host port's own wait states measure zero.

**What it is, in the part that can be named:** the wire is about 26,800 words
per frame (1,149 survivor records at eighteen words, plus 5,448 UV words for
all 2,724 triangles, plus chunk headers and acks), or roughly 62 ms at the
2.3 us/word calibration.  **That 62 ms is wrong and the word count is right**
(2.4c): a wait-state sweep on the corrected emulator counts ~25,000 host-port
accesses per frame in this stage -- corroborating the ~26,800 words by an
independent route -- but prices the port's *wait states* at **14.2 ms**, not
62.  The 2.3 us/word figure is an end-to-end stage delta from roadmap item 3,
which removed the DSP's receive-and-store work along with the wire, so it was
never a transport rate.

Two numbers now describe the port and they are not in conflict, because they
price different things.  The wait-state sweep isolates only the charge the
emulator adds per access; 2.4a's core prices the transfer loop's instruction
execution at zero, so that figure excludes it.  The `CMD_PIO_BURST`
calibration measures the wire end to end -- **1.876 us/word readback and
1.188 us/word upload, transport-only, a measured port floor of ~46 ms/frame**.
Read 14.2 ms as what a free host port would give back on this emulator, and
~46 ms as what the transport actually costs including the loop that drives it.
Read this paragraph as the word count it establishes; the timing conclusion
below is re-derived in 2.4c, where the stage is ~173 ms exposed DSP compute,
~73 ms host CPU work and 14.2 ms of wait states.
Of the remainder, one item is pure duplicated work:
**every survivor's span record is handled twice.**  The unpack writes 22
expanded longwords into `dsp_triangle_rx_buffer`, and `build_gpu_shadow_packets`
then reads those 22 and writes them again into the packet through two MOVEM
pairs.  Letting the unpack write straight into the packet's span slots -- with
the source index and shade parked in two of 3.9c's resolve slots, which nothing
reads until the sweep -- removes 44 longword bus accesses per survivor, 50,556
per frame, about **25 ms** at the 8.05 cycles per longword this program
exhibits.  It is not free to build: the projected-vertex fallback and the span
validator both consume the old `rx_buffer` layout, so the copying builder has
to survive for them.  **Built as section 8.2b: the stage moved -24.9 ms,
within 0.1 ms of this paragraph's estimate.**

**Built and measured: -25.20 ms (section 3.11).**  The estimate above is the
closest this document has come to costing a change before making it.  The
caveat held exactly as written -- the copying builder survives for the no-DSP
fallback and the DSP arm got a lean one -- and the packet stage went
260.51 -> 235.31 ms for a 532.6 -> 506.4 ms frame at byte-identical output.
Turning the span validator on to check the change also found it **dead on
unmodified HEAD**, reporting 100% mismatches while comparing nothing; 3.11 has
the detail, and it matters most to item 15, which had planned to use it.

**The honest arithmetic for three FPS on the full mesh.**  That 25 ms and the
occlusion stage of item 19 are the only two levers with a named mechanism.
Occlusion at the DSP-buildable variant culls 10.5% of survivors and 11.24% of
writes (2.3a), which against the split above is roughly 14 ms of packet stage,
7 ms of per-packet setup and 20 ms of row/pixel work -- about **41 ms**, and
less than that at the 4x4 cells item 19 would have to fall back to.  The
last measured prepass configuration sat far below either figure: 2.3f's
deliberately conservative 8x8-cell, 64-class configuration killed tens of
triangles per frame -- about half a percent of writes. The 128-class/8x8-cell
probe is now rejected: its 0.030% equal-frame yield did not improve that
result. The 41 ms remains conditional on a substantially different occlusion
strategy, not a class-count-only change. Both
together are about 66 ms of the 126.7 needed, landing near **395 ms / 2.53
FPS**.  **Three FPS on the full mesh therefore does not follow from any
optimization currently identified**, and the residual ~127 ms has no mechanism
short of moving the record stream off host-port PIO entirely (item 15), which
Hatari cannot validate and which section 7.4 shows is not a small piece of
work. The retired LOD's 3-FPS result is not a supported-performance claim.

**Re-derived on the corrected clock (2.4c).** The gate this section computes is
a stock-clock gate: the real baseline is 535.7 ms / 1.867 FPS, so the distance
to 333.3 ms is **202.4 ms**, not 126.7. The conclusion above survives the
correction and hardens:

- **"Moving the record stream off host-port PIO" is not the residual's
  mechanism.** The whole host port prices at 14.2 ms; deleting it entirely
  measures 519.7 ms / 1.924 FPS. This sentence should be read as naming item 15
  for the *overlap* it enables, not the transfer it removes.
- **The residual has a mechanism after all, and it is DSP time.** ~173 ms of
  the frame is exposed DSP compute. It is the largest single term outside the
  rasterizer, it was invisible while the DSP ran at double rate, and it is
  attackable two ways: making the DSP program faster (item 21's territory,
  every saving now worth 2x its recorded value), or overlapping it with CPU
  rasterization (item 15's cross-frame stage).
- The ~25 ms unpack fix is unchanged in absolute terms -- 2.4c's sweep shows
  the host CPU stages are emulator-invariant -- but it is now ~34% of the
  ~73 ms host CPU term rather than a fraction of a 185.7 ms mystery.
#### 8.2b Direct-to-packet unpack -- implemented, -27.2 ms/frame, byte-identical

8.2a's duplicated-work item is built (2026-08-29).  The frame path is decided
once per frame at chunk-pipeline start: on a direct frame the record unpack
writes the 22 span/level fields straight into each packet's own slots w4..w25
and parks (source index, OT key, shade) in resolve slots w26..w28 -- dead
until the 3.9c sweep overwrites them, which is after `gpu_submit_ot` has
consumed w2 -- and `build_gpu_packet_heads` then derives only the four head
words per packet.  The copying builder and the `rx_buffer` records survive
unchanged for everyone who needs the old layout: validation frames select
the copy path at frame begin, the projected-vertex fallback clears the frame
flag when it takes over mid-frame, and the OCCL/SSI row/shadow diagnostic
builds assemble `direct_unpack_enabled` as 0 (it is a data flag, so the A/B
stays byte-patchable).  Both unpack bodies carry their own line pin: the
copy body is unchanged at 250 bytes, the direct body assembles to 252, and
both fit the 256-byte instruction cache unconditionally.

Measured, corrected-clock recipe, converged 265-frame prefix:

| Stage | copy path | direct path | Delta |
|---|---:|---:|---:|
| DSP set_frame | 13.2 ms | 13.1 ms | -0.1 ms |
| DSP readback + packet build | 252.1 ms | **227.2 ms** | **-24.9 ms** |
| Clear + OT | 17.3 ms | 17.3 ms | 0.0 ms |
| Software span rasterizer | 243.7 ms | 241.5 ms | -2.2 ms |
| **Total** | **526.7 ms / 1.90 FPS** | **499.5 ms / 2.00 FPS** | **-27.2 ms (-5.2%)** |

The packet stage lands within 0.1 ms of 8.2a's 25 ms model, which was a bus
floor -- and on this emulator, which prices instruction execution at zero,
a bus-access count is exactly what should reproduce.  The 2.2 ms rasterizer
movement is not part of the mechanism (the raster stage reads the same
packet layout); it is the kind of cross-stage drift 2.1 warns about reading
into, and the total stands regardless.  Output gates: frame-100 `fb.res`
reproduces `d89958b3…3d16` byte-identically, cumulative pixels 9,049,666 and
1,149 final packets equal.  Regressions on the surviving copy path: the
`trex_m68030_ssi_rows` build (copy path forced) reproduces the same frame-100
hash and its row stream passes `verify_ssi_rows`; the armed-prepass build
reproduces the hash with zero protocol failures.  The shipped release,
re-timed by 2.4c's two-byte instrumentation patch (`cmp -l` confirms exactly
two bytes): **502.2 ms / 1.99 FPS** over 265 frames, against 2.4d's recorded
525.5 / 1.90.

One pre-existing condition surfaced by the regression pass, not caused by
it: with `span_validate_enabled` patched to 1, `val_stats.res` reports every
record as one mismatch -- 118,049 of 118,049 at the pre-change HEAD, and the
same pattern after -- while the frame-100 checkpoint still reproduces.  The
validator was last gated clean before later record-field changes and is
STALE AS A TOOL; its verdict is currently meaningless in both directions.
Until it is re-aligned with the current 18-word record, the byte-identity
checkpoints are the only span-record gate.

The gate arithmetic moves: 499.5 ms against 333.3 is **166.2 ms**, from
193.3.  The remaining named lever is item 19's occlusion yield (~41 ms
conditional on unbuilt yield work); the rest still has no mechanism short
of item 15.

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

> **Two figures in this paragraph are stale (corrected 2026-08-28, see 7.4a).**
> `SPAN_RECORD_WORDS` is **18**, not fourteen, in both `trex_dsp.asm` and
> `trex_m68030.s`; 8.2a's "eighteen words" is the correct count. And the two UV
> starts `uv0pack`/`uv1pack` listed below as w17/w18 **are not transmitted at
> all** -- the DSP source says so explicitly ("the sorted top/middle UV bytes
> are not sent"), and the host rebuilds them from `gpu_texture_meta_buffer`
> through the two slot ids carried in w0. The host-semantic record is still
> nineteen fields; the wire carries eighteen packed words. The field list below
> remains correct as the *semantic* record, which is what it is for.

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
comparisons, zero mismatches (section 4.1b).  Re-validated after 3.12 repaired
the gate, on the current eighteen-word record with its Gouraud level fields:
**167,176 records at seventeen fields each, 2,841,992 comparisons, zero
mismatches.**  Between those two results the gate was dead and reporting 100%
failure -- see 3.12 before trusting any archived verdict from that span.  The two constraints called out
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
   full mesh** -- stock-clock totals; see 8.2 for the corrected baseline --
   at byte-identical output throughout.  Registerizing xr is part
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
   **Sixth pass done, and it is a small one -- section 3.10.**  2.4d measured
   the DATA cache for the first time (`--data-cache false`: rasterizer
   244.61 -> 316.53 ms), so it is worth **71.9 ms/frame, 29% of the
   rasterizer**.  3.10 then scanned the one phase item 16 never did -- the word
   CLUT's, pinned by `cnop 0,4096` to stop it moving rather than to place it
   well -- across all eleven points of the 256-byte data-cache period at a
   bit-identical instruction stream and byte-identical output.  Smooth
   single-minimum curve, flat basin over 112--160: **`OPAQUE_CLUT_PHASE = 128`,
   rasterizer 244.34 -> 241.25 ms, frame 535.7 -> 532.6, 1.867 -> 1.878 FPS.**
   **Only 4.2 ms of the 71.9 is phase-addressable** and 94% is the cache simply
   working, because a 512-byte CLUT bank aliases 2:1 in a 256-byte cache no
   matter where it sits.  Alignment, the other classic Falcon data lever, has
   nothing to give here either: the pixel loop's byte texel read, `index*2` word
   CLUT read and word framebuffer write are one aligned bus cycle each.  **Do
   not expect a 3.9-sized result on the data side** -- that loop was 552 bytes
   against a 256-byte cache and could be made to fit; this working set cannot.
   **Seventh pass, on the row walk: one confirmation and one rejection
   (3.13).**  The split is re-taken at 110.88 / 68.45 / 61.32 ms;
   `RASTER_STATE_PHASE = 32` is re-scanned and survives at the new CLUT phase
   (9.7 ms range across the period); and hoisting the three chain-cell RMWs to
   their load sites -- predicted ~17 ms from removing 37,317 accesses per frame
   -- measured **+0.09 ms and was reverted**.  The reason is worth carrying
   forward: at the tuned phase those cells are already cache-RESIDENT across
   the pixel loop, so the second access was a hit, and the row walk is
   therefore **not** chain-cell read traffic.  The untested remainder is the
   four write-throughs per row, the memory-indirect span-entry jump, and
   instruction fetch across a hot path with 22 bytes of headroom.
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

   **Both of those sentences are wrong at the corrected clock (2.4c), and the
   stage-2 measurement is still right.**  "The remaining genuine DSP wait is
   only a few milliseconds" and "the remaining readback stage is CPU work" were
   concluded with the DSP at 32 MIPS.  At the real clock the stage is ~173 ms
   exposed DSP compute against ~73 ms host CPU work and 14.2 ms of wire — so
   **most of what stage 2 tried to hide is exactly the kind of thing scheduling
   can hide**, and this item is not exhausted.  What stage 2 measured remains
   valid as a *mechanism* result: its accumulator lost more than it won.

   **The cold-re-read attribution is now measured out (2.4d).**  Disabling the
   68030 data cache entirely -- a stronger perturbation than any cold buffer --
   moves the packet stage by **-1.8 ms** while moving the rasterizer by
   **+71.9 ms** in the same run.  The unpack writes a 2.3 KB chunk and reads it
   back through a 256-byte cache, so every read misses today and a cold DMA
   buffer would miss no more.  Stage 2's 14.2 ms therefore came from the other
   causes this item names -- the service-hook overhead added to the rasterizer,
   and breaking 4.1d's cache-warm chunk interleave -- both scheduling effects,
   and neither inherited by a design whose transfer is done by hardware and
   whose unpack happens in one block at the frame boundary.  2.4d also shows
   the FINISH window absorbs **97.5%** of 117.7 ms of added DSP work, so the
   scheduling capacity this item needs demonstrably exists.  What blocks it is
   not scheduling and not caches: it is that the DSP cannot buffer a frame of
   records (20,682 words against a full 16,384-word X space), which is item
   15's job to fix.

   **Sized in 2.4f.**  The window holds **112.5 ms/frame spare with the prepass
   armed**, ~48 ms of it at 99% absorption, against ~246 ms of total record
   compute.  The capacity is real but bounded: it can hide well under half the
   record work, not all of it, and the 2.76 FPS ceiling above is corrected to
   **2.36**.  2.4f also records the coupling nothing had stated — the window IS
   rasterizer time, so items 11 and 15 compete for the same milliseconds.
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
   **Sharpened by 2.4c.**  The emulator now prices its own host port at
   **14.2 ms/frame** and counts ~25,000 accesses/frame in the packet stage, so
   the bench's job is no longer "how fast is each transport" -- it is whether a
   physical Falcon's PIO loop costs materially more than the emulator's
   wait-state-only model, which charges the loop's instructions nothing (2.4a).
   Add one measurement to the list: **CPU-busy time with the DSP deliberately
   ahead of the host**, which separates real transfer cost from DSP stall.
15. SSI/crossbar streaming per sections 7.4/8. **Protocol prototype done,
   hardware activation pending.**  Full mesh makes U/V 49.8 KB/frame and the
   complete no-RLE stream 86.9 KB average (111.8 KB shade bound), not the old
   LOD-derived 36.2 KB.  The executable ABS/SET_SHADE/RUN16 coder round-trips,
   2x192-KiB ownership covers every recorded frame, and overflow has a defined
   host-port fallback.  Next is the physical-Falcon owner: exact sound-state
   save/restore, handshaked DSP-XMIT -> DMA-RECORD, and cache coherency without
   an ad-hoc CACR write.  Only then may cross-frame span consumption replace
   the CPU row walker.  U/V-only is explicitly insufficient for three FPS.
   **Re-motivated by 2.4c, and for a different reason than this item was
   written for.**  The transfer it removes is worth 14.2 ms; a free host port
   measures 519.7 ms against 535.7, i.e. **+0.06 FPS**.  The overlap it enables
   is worth up to **~173 ms**, the exposed DSP term.  This item should therefore
   be scoped and judged as a *scheduling* change whose transport is the enabling
   mechanism -- cross-frame DSP/CPU overlap first, wire saving as a rounding
   term -- and not as a transport optimization.  That also raises the bar on
   section 7.4's ownership work: it must buy real overlap, because it can no
   longer be justified by the PIO it deletes.  Note item 12 stage 2 already
   measured one host-port attempt at overlap **slower**, and its stated cause --
   a deferred unpack re-reading 59 KB cold -- applies with more force to an
   82-107 KB DMA buffer the CPU reads cold.
   **Step 2 done for the record scope (7.4a).**  The 16-bit framing of the
   existing 18-word packed record is frozen, implemented and self-testing in
   `tools/ssi_stream_model.py`: 198,912 checks covering lossless round-trip and
   rejection of truncation, one-unit shift, bit flips, stale frame id and
   generation, a dropped record, a torn ping-pong buffer and a stale trailing
   footer.  Average frame 80.8 KiB, **geometric maximum 191.6 KiB -- bounded by
   triangle count, so unlike the row stream it cannot be overflowed by
   geometry**, but with only 448 bytes of margin at 192 KiB, so size the pair at
   2 x 256 KiB.  Remaining before activation, unchanged: the sound-state
   save/restore owner, handshaked DSP-XMIT -> DMA-RECORD, cache coherency
   without an ad-hoc CACR write, and a field-for-field bring-up comparison
   against host-port-delivered records.  **None of those can be validated in
   Hatari.**

   **The bring-up instrument this item names was broken; it is repaired
   (3.12).**  3.11 found `span_validate_enabled` reporting 100% mismatches on
   unmodified HEAD while comparing nothing, because the DSP command supplying
   its reference vertices had been retired for program words.  Command 3 is
   back at a cost of seventeen words, the gate runs clean over 167,176 records,
   and a `val_no_vertices` field now makes the same failure mode announce
   itself instead of masquerading as a DSP fault.  The field-for-field
   comparison this item and 7.4 both plan to use for SSI/DMA bring-up --
   stream-delivered records against host-port-delivered ones, "exactly as
   during the record migration" -- is therefore available again.  Check
   `val_no_vertices` first in any bring-up report: zero records with zero
   mismatches means the gate did not run.

   **The scheduling question is now answered, and it clears this item (2.4d).**
   The FINISH window absorbs 97.5% of 117.7 ms of added DSP work, so overlap
   capacity exists; the cold-buffer penalty that item 12 stage 2 was blamed on
   is bounded at approximately zero; and the reason record work cannot use that
   capacity today is structural rather than economic -- **the DSP cannot hold a
   frame of records** (20,682 words against a 16,384-word X space that is
   already allocated to the top), so they must leave as they are produced,
   during a window in which the host is rasterizing and cannot service a
   transfer.  Draining the DSP autonomously in that window is the one thing
   only DMA can do, and it is the justification to build this on -- worth up to
   ~173 ms, or **362.7 ms / 2.76 FPS** if the exposed term went to zero, against
   the 14.2 ms the transport itself is worth.  Remaining unknown, hardware only:
   DMA/68030 ST-RAM contention, which no Hatari result can bound.

   **The route now runs, and the row-stream figures are corrected (7.4b).**
   The no-RLE row model is approximately 93.0 KB average (117.9 KB shade
   bound) once the packet gradients the CPU pixel loop needs are included --
   not the superseded six-word-header estimate.  Full mesh makes U/V 49.8 KB/frame and the
   corrected no-RLE model approximately 93.0 KB average (117.9 KB shade bound),
   not the superseded six-word-header estimate or old LOD-derived 36.2 KB.
   The executable ABS/SET_SHADE/RUN16 coder now round-trips its fixtures,
   including the packet gradients required by the CPU pixel loop, and the
   compact 18-word DSP-record shadow has the same CRC/framing fixture.  The
   common sound/DMA wrappers, compact pack helper and stopped ownership /
   raw-readback probe are now present, informed by `F030MXDRV`; the Hatari
   probe safely rejected its inherited state at the idle-DMA snapshot gate
   before route validation.  The next physical-Falcon gate is raw Crossbar
   read-back plus handshaked DSP-XMIT -> DMA-RECORD, variable-length pointer
   completion, and cache coherency without an ad-hoc CACR write.  Only then
   may cross-frame span consumption replace the CPU row walker.  U/V-only is
   explicitly insufficient for three FPS.
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
    and 3 remain fixed two-word run-now commands for measurement. The 64-word
    counter bank is on-chip at `Y:$0096-$00D5`; the program ends at `P:$0912`
    (`$0901` before 3.12 restored `command_get_vertices`), leaving
    `$0913-$09BF` free before the resident indices at `Y:$09C0`. The X
    overlay ends exactly at
    `X:$3FFF`, and resident Y data ends at `Y:$3FFE`. No LOD-only relocation or
    alternate hardware map is used.

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

    The first yield-raising experiment is measured and rejected: 4x4 cells
    alone bought nothing. The 128-class/8x8-cell probe was then measured and
    rejected: it saved only 0.030% of equal-frame raster writes while moving
    its counter bank out of on-chip RAM (section 2.3i). Raising the yield
    further needs a substantially different occlusion strategy; finer cells
    or classes by themselves are no longer justified by the measurements.

    **Production cost measured at last (2.4d), and it is not milliseconds.**
    Armed against disarmed on the corrected emulator, one byte apart, matched
    to 0.02% of pixels: **505.9 -> 508.9 ms/frame, +3.0 ms.**  The prepass is
    therefore *not* a frame-rate regression in the release, and the earlier
    worry that it might be one at the corrected clock is answered: the FINISH
    window absorbs 114.7 of its 117.7 ms.  Leave it armed.  Confirmed
    independently on the shipping binary in 2.4e: the release costs **+3.72 ms
    of packet stage** against the diagnostic build -- a different binary pair
    reaching the same figure.

    Its real price is the one that does not appear in that table.  It consumes
    **~118 ms of FINISH-window DSP capacity** -- the same resource item 15's
    record overlap needs, which 2.4d sizes at ~173 ms against a ~234 ms window.
    The two cannot both have it.  At the currently measured yield -- 0.02%
    fewer pixels per frame in the equal-frame pair above, consistent with the
    half-a-percent 2.3f recorded -- **the prepass loses that contest by three
    orders of magnitude** and should be disarmed the moment record overlap is
    built.  Until then it costs 3.0 ms and may stay.  This also sharpens what
    a yield-raising experiment has to beat: not 3 ms of frame time, but the
    window capacity it denies to a much larger optimization.

    **The yield question is now answered mechanically (2.3j).**  Six per-run
    counters in the status tail, read by the new PREPASS mode 4, measured the
    stamp sealing 61 of 5,130 visited cells per frame (1.2%), queries exiting
    at their first cell, and 1.1 kills per frame: the single-triangle
    full-cell stamp cannot compose coverage across the mesh's shared edges,
    which is why 2.3i's finer cells and finer classes both measured zero.
    Raising the yield requires pixel-exact coverage union or authored proxy
    occluders; every refinement of the current stamp is disqualified.  The
    same counters caught a latent sweep defect -- the class-change compare
    read B2's sign extension of entry bit 23, so the 676 triangles with
    indices >= 2,048 merged pending coverage mid-class, an ordering-soundness
    hole and ~9 ms/frame of waste -- fixed one word (`move b1,b`), all gates
    byte-identical, dirty merges 245.6 -> 7.5 per frame.
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
21. Harvest the DSP instruction-stream reserve. **Complete -- all nine
    sites implemented**; see section 2.3h.  The seven size sites freed
    179 words, and sites 2 and 3 (O(1) kill-bit addressing, the pass-2
    classify cache) spent 40 of them back to take the freestanding
    prepass from 76.76 to a measured **60.28 ms/frame**, which the size
    sites then carried to **57.18** (re-measured, section 2.4b) -- a
    quarter of the stage -- leaving **190 words free** to the `$09BF` ceiling
    (**173** since 3.12 spent seventeen restoring `command_get_vertices`, and
    **144** since 2.4d's normal-light cache took twenty-nine more)
    against 51 when the audit began, at byte-identical output
    throughout.  The
    prepass cost is hidden by the FINISH window today, and every
    rasterizer improvement narrows that window, so the return is program
    words and margin for item 19's yield work, not frame rate: the BUILD
    path's wall-clock ceiling is the few-milliseconds genuine DSP wait
    item 12's stage 2 bounded.  Gates as always: DOSBox assembly clean, P
    extent at or below `$09BF`, byte-identical frame-100 `fb.res` against
    the recorded checkpoint.
22. Cache repeated per-corner normal lighting. **Done and measured** -- see
    section 2.4d. A 128-entry direct-mapped frame-local cache keeps the two
    clamped direct-light channel sums before per-triangle depth cueing. Exact
    full-index tags make collisions harmless; invalidation follows the
    prepass/order lifetime boundary, and X:R carries each miss result into
    memory beside its depth operand transfer. Corrected-clock Hatari measures
    the mixed packet stage 259.8 to 252.1 ms and the frame 534.2 to 526.6 ms
    over the fixed 265-frame prefix, with byte-identical diagnostic output.
    Together with the now-default release prepass disarm, `TREX.TOS` measures
    525.5 ms / 1.90 FPS versus the recorded 536.5 / 1.86.

    **Reopened by 2.4c: "not frame rate" was a double-clock artefact.**  The
    "few-milliseconds genuine DSP wait" this item leans on was measured with
    the DSP running at 32 MIPS.  At the real clock the exposed DSP term is
    **~173 ms per frame, 32% of the whole frame** and the largest single item
    outside the rasterizer.  DSP instruction-stream work is therefore a
    frame-rate lever after all, and every millisecond the nine sites bought is
    worth **2x** its recorded value.  Two consequences: the 190 free P words
    are now contested between item 19's yield work and new DSP-side speed work,
    and any further harvest must be measured on the corrected emulator from the
    start.  Note the 2.4c baseline binary carries **no prepass** -- the release
    adds one costing 117.70 ms/frame freestanding (2.4b) into a FINISH window
    that is already DSP-bound, so whether it still hides is an open
    measurement, and `arm0/`/`arm1/` can answer it without new code.

## 11. References

- [Atari Falcon 030 Developer Documentation, October 1992](https://bus-error.nokturnal.pl/dl5)
- [MiKRO, "68030 and ST-RAM"](https://mikro.naprvyraz.sk/docs/mikro/030_stram.html) — the 16-bit ST-RAM bus, the absence of burst mode on the Falcon, longword/misalignment bus-cycle costs, write-through data caching and the precharge penalty. Section 3.10 uses it to bound which data-cache levers can exist at all, and it closes 2.4a's open question about whether a real Falcon bursts.
- [Atari Compendium, Falcon sound system, DSP, and connection matrix](https://frummel.org/~weedz/atari/docs/The_Atari_Compendium.pdf)
- [Atari Falcon030 Owner's Manual](https://www.atariworld.org/files/docs/Atari_Falcon030_Manual_en.pdf)
- [Falcon hardware register listing](https://temlib.org/AtariForumWiki/index.php/Atari_ST/STe/MSTe/TT/F030_Hardware_Register_Listing)
- [Hatari Falcon I/O register table](https://hatari.frama.io/hatari/doxygen/io_mem_tab_falcon_8c_source.html)
- [Hatari user manual: experimental Falcon crossbar emulation](https://hatari.frama.io/doc/manual.html)
- [Motorola DSP56000/DSP56001 User Manual, SSI chapter](https://www.nxp.com/docs/en/user-guide/DSP56001UM11.pdf)
- [Motorola MC68030 User's Manual, instruction timing](https://www.nxp.com/docs/en/reference-manual/MC68030UM-P2.pdf)
- [DSP56K host-port and historical crossbar software notes](https://www.nocrew.org/sites/dsp56k.nocrew.org/)
- [Cho Ren Sha 68k Falcon release archive](https://www.atarimania.com/game-atari-st-cho-ren-sha-68k-falcon030_30783.html)
