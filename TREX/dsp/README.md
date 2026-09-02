# T-Rex DSP core

`trex_dsp.lod` is the DSP56001 geometry and triangle-setup core of the
Falcon030 port. The active path handles, per frame:

1. building the exact PS1 morph pose from the base vertex, the deduplicated
   gait delta and the active Q12 target weights,
2. transforming the 1,376 vertices with the extracted scene matrix,
3. perspective projection onto the 240x224 render target,
4. near-plane, degenerate-area, back-face and screen culling,
5. current per-corner Gouraud lighting (4-bit level plus 2-bit tint class),
   the Z/OT key and the full DDA span-setup record for every visible
   triangle.

The M68030 reads the 64-byte choreography records, expands the stored XYZ16
deltas into native host-port words, builds the host packets, links the
Ordering Table and rasterizes the prepared spans. It computes none of the
morph products, vertex matrices, projection, culling or span divisions.
Lighting is not yet an exact PS1 reproduction: the demo uses three coloured
lights plus a reddish ambient light, dotted against all three TMD corner
normals per triangle rather than one geometric face normal. That source data
has since been extracted. The wire/raster format carries a brightness level
per corner (Gouraud-interpolated across each span) and a colour-tint class
per face; `gouraud_enabled` (default on, `TREX/m68030/trex_m68030.s`) keeps
the earlier one-level-per-face path selectable for A/B measurement.

## Provenance of the transform and the divide

Two routines in this file are not new code and must not be treated as such.

`transform_vertices` is the MAC pipeline of `rotate_translate` from
`src/3d.asm` of the predecessor repository `f030dsp3d` ("3d routines (c) 1994
by Sascha Springer"): 18 of that routine's 21 instructions are present
verbatim, including the `move #8,n4` prologue, the register contract (`r0`
vertices, `r1` position, `r2` output, `r4` matrix in Y memory), the A/B
accumulator ping-pong and the `tfr y1,a y:(r4)-n4,y0` matrix rewind that
starts the next vertex while the previous MAC is still in flight. The nine-word
matrix layout the host sends is that routine's layout, so changing it breaks
the frontend's `SET_FRAME` packet as well. `transform_animated_vertices` is the
same pipeline adapted to transform in place.

Three instructions were added, all of them `rnd` before a store. They are not
cosmetic: `MOVE A1` alone truncates, and a 1.23 matrix cannot represent 1.0
exactly -- the identity entry is `$7fffff`, or 1 - 2^-23 -- so truncation turns
1000 + 1000*`$7fffff` into 1999 instead of 2000, and that one-unit shortfall
propagates into the projection and collapses vertices that should stay a pixel
apart.

The signed division idiom (`jpl *+2` / `neg` / `andi #$fe,ccr` / `rep #24` /
`div x1,a` / `jclr #23,y1,*+3` / `neg`) is from the same 1994 source and is
used in three places: the two perspective divides per vertex, and the DDA span
slope divide per visible triangle.

Both sequences are shaped around the DSP56001's parallel X/Y moves so that
every MAC issues in one cycle, and they sit in the innermost loops of the
frame -- the transform runs 1,376 times per frame. Rewriting either for
readability, or dropping a `rnd`, costs measured frame time or correctness.
Re-measure before touching them, and record the result in `OPTIMIZATION.md`.

## Memory budget

The Falcon gives the DSP 32K words of external 24-bit RAM. P and Y address
space overlap from `$0200` onward, so the resident Y arrays only start above
the program.

| Range | Words | Purpose |
|---|---:|---|
| `X:$0040-$0043` | 4 | command and translation |
| `X:$0044-$1063` | 4,128 | static base vertices |
| `X:$1064-$25E3` | 5,504 | object/camera pose, then projected vertices in place |
| `X:$25E4-$39DE` | 5,115 | X half of the corner-normal table (`corner_normals_x`) |
| `X:$39DF-$3A1E` | 64 | one BUILD chunk's UV pairs (`chunk_uvs`) |
| `X:$3A1F-$3C5E` | 576 | 32 packed span records at 18 words each |
| `X:$3C5F-$3C70` | 18 | phase-local paired direct-light vectors after the prepass |
| `X:$3C71-$3CF0` | 128 | frame-local normal-light cache tags |
| `X:$3CF1-$3D70` | 128 | cached red direct-light sums |
| `X:$3D71-$3DF0` | 128 | cached green direct-light sums |
| `Y:$0096-$00D5` | 64 | on-chip 64-class prepass counters |
| `Y:$09C0-$29AB` | 8,172 | packed resident triangle indices |
| `Y:$29AC-$3FFE` | 5,715 | Y half of the corner-normal table (`corner_normals_y`) |

The resident UV-pair table this used to describe no longer exists: the
corner-normal table (needed for Gouraud shading) displaced it, and each
BUILD chunk now carries its own UV pairs instead (`chunk_uvs`, above).

The `-DTREX_PREPASS` overlay uses the same X window before BUILD traffic:
`X:$39DF-$3F15` is the 1,335-word phase-local order list, `X:$3F16-$3F85`
holds the two 56-word coverage masks (seal, then pending), `X:$3F86-$3FF7`
is the 114-word full-mesh kill bitmap (one bit per 2,724 triangles), and
`X:$3FF8-$3FFF` holds prepass status — `+0/+1` are BUILD's streaming kill
cursor, `+2..+7` the six per-run diagnostic counters mode 4 reads out; the
four allocations fill the window
to the top of physical X memory exactly. The order list overlays the dead
UV/output window deliberately: the occlusion sweep consumes it before the
first BUILD chunk, so no sorted-list storage is needed after that point.
This is the stock-hardware-safe lifetime boundary.

`phase_light_directions_x` aliases `X:$3C5F-$3C70`, the tail of that order
list above the maximum BUILD output. `cache_light_directions_x` copies the 18
direct-light words from their canonical Y packet block only after the prepass
has consumed the list (or after projection in the no-prepass test path); the
explicit `CMD_PREPASS` run-now path refreshes it after the same overlay use.
BUILD's Lambert loop then pairs each X light-component fetch with the
corresponding Y normal-component fetch. The cache must remain after the
prepass lifetime boundary and below `prepass_scratch`; it is not a persistent
third copy of the host protocol payload.

The following 384 words are a separate 128-entry direct-mapped cache keyed by
the full corner-normal index. A miss performs the normal 3x3 rotation and both
three-light channel sums, then an X:R dual move stores each clamped direct
sum. A hit skips that repeated work but still performs the triangle-specific
depth multiply/round and all level/tint quantization. Only the tag array is
cleared when the frame's matrix/lights become final. The cache ends at
`X:$3DF0`, 293 words before `prepass_scratch`; it overlays only the consumed
order-list tail and does not reduce `PREPASS_MAX`.

The active class-resolution path produces the order with a two-pass counting
sort into 64 depth classes of 32 OT buckets each: classification runs once to
count and once to scatter,
so no radix ping-pong list exists. That second list is what previously
capped the order list at 723 entries -- below the full mesh's real
1,100-1,200 area/box survivor count, so the old classification overflowed
and self-disabled on every frame. The coverage sweep walks only the 8x8
cells each survivor's clamped screen box overlaps, exits its seal query at
the first uncovered cell, stamps full cells with three incrementally
stepped edge values read from A0 (the A1 word of a small fractional product
is only its sign extension), and merges pending coverage only for classes
that stamped anything.

The authored choreography ends at frame 273 and the frontend-added hold
continues past it. When enabled, the prepass stays armed through that hold: the
one-shot disarm the frontend used to send existed to protect the stock DSP
frame budget from the former full-grid cell cursor, which visited all
3,360 4x4 cells for every survivor, and the range-restricted sweep removed
that cost class. With the custom Hatari/TOS 4.02 harness, armed and
disarmed captures are byte-identical at frame 100 and at hold frame 291,
with zero prepass protocol failures or capacity overruns across the hold.

The frontend reserves `X:$0000-$3DFF` and `Y:$0000-$3EF7`. The full-mesh
program occupies P from `$0040` and, in the default build, ends at `$09AC`,
leaving the words at `$09AD-$09BF` free before the Y indices at `$09C0` — 19
words, after `command_get_vertices` was restored for the span validator at a
cost of seventeen (`OPTIMIZATION.md` 3.12), the 2.3j diagnostic counters,
their mode-4 readout and the flow-compare sign fix took 58 more, the 2.4f
window-capacity probe took 44 and 2.4i's normal-light cache took its own
share.

Seven switches in the generated `dspconf.inc` select what is assembled,
because it no longer all fits — `SSIPROBE` (the `CMD_SSI_STREAM` transport
probe, 103 words), `PRELIGHT` (the FINISH-window lighting pass and BUILD's
table read, 66), `WINPROBE` (the window burn loop, 44), `PREPASSDIAG` (2.3j's
counter increments, 30), `PIOBURST` (the host-port calibration burst, 25),
`PHASEPROBE` (2.4l's per-phase BUILD timing ladder, 21) and `OBJLIGHTS`
(object-space lighting, 19). The default build takes `OBJLIGHTS` and
`PRELIGHT` and ends at `P:$09A6`; the SSI transport bring-up build
(`SSIPROBE=1 WINPROBE=0 PIOBURST=0 PREPASSDIAG=0 OBJLIGHTS=0 PRELIGHT=0`)
trades everything else for the probe and ends at `$09B8` with 7 words free.

`PHASEPROBE` is the only instrument that fits **beside** the shipping
configuration: `$09BB`, 4 words free, with `OBJLIGHTS` and `PRELIGHT` at
their shipping values. That is what makes its ladder a measurement of the
BUILD body `TREX.TOS` actually runs rather than of a substitute. It adds
seven `JCLR`s against `phase_mask` inside the per-triangle body, so the
image that carries it is measurably slower in the exposed packet stage —
no whole-frame or `t_packets` figure may be taken from it, and its arm-2
control run exists to price those guards.

`phase_mask` lives in the short-addressable Y page, in the slot of the
write-only `triangles_loaded` flag, because `JCLR` has no long-absolute
form: its second word *is* the jump address, so the operand must be short
absolute, I/O short or register indirect, and no address register survives
`make_triangle_area`/`bbox`/`zkey`/`span`. The `phase_mask` equate names
that address directly (the Y section is assembled after every use of it, and
a forward reference cannot be sized short) and the Y section asserts the two
agree with `FAIL`.

`PREPASSDIAG` guards only the counter *increments*. The mode-4 dispatch and
its reply are unconditional in every configuration, because a guarded-out
dispatch would send a mode-4 command into `prepass_arm` — silently arming the
prepass with the value 4 and answering two words where the host expects seven.
With `PREPASSDIAG=0` mode 4 still replies `ACK_PREPASS` plus six cells, and
they read honest zeros. `OBJLIGHTS=0` is pixel-identical to 1 over the
321-frame hash sweep, so the bring-up build streams the same records the
shipping build would.

This bound has to
be checked after every DSP change, because an overflow overwrites the index
list without an assembler error -- recompute it from the assembled `.lod`
rather than trusting this figure, with the check command in the end-of-file
comment of `trex_dsp.asm`.

`command_finish_animated_frame` ends with the **cross-frame window capacity
probe** (`OPTIMIZATION.md` 2.4f): `y:probe_units` iterations of a memory-free
32-NOP burn loop, run inside the window the host spends rasterizing. It is
`dc 0` in a retired pad word, so a shipping build pays three instructions per
frame and the cell is the only thing that changes across a whole capacity
sweep — patch it with `tools/probe_units.py` rather than rebuilding, which
keeps the DSP program and the host binary byte-identical at every point.
Leave it at 0 in anything shipped or timed for another purpose.

The `TREX.TOS` release keeps the full-mesh DSP occlusion path while
disabling the host-side diagnostic flushes. It reads `TREX.LOD` once during
startup and does not write `render_stats.res`, `prep_sta.res` or `fb.res`
during playback or shutdown.

The full animation targets are not DSP-resident. The frontend sends exactly
one of 46 full gait poses per frame, plus only the actually active, sparse
targets 5-8. The existing `camera_vertices` allocation first serves as the
object pose, then as the camera/projection buffer; no further vertex array
is needed.

## Host protocol

All transport values are native 24-bit DSP words. Animation data is
transferred in acknowledged partial transactions; a chunk holds at most 512
vertices.

```text
LOAD_VERTICES:
    cmd, count, count * (x, y, z)

SET_ANIMATED_FRAME:
    cmd, matrix[9], translation[3], focal_x, focal_y, centre_x, centre_y,
    near, light[20]
    -> ACK_ANIMATION_BEGIN

LOAD_ANIMATION_GAIT:
    cmd, first_vertex, count, count * (delta_x, delta_y, delta_z)
    -> ACK_ANIMATION_GAIT

APPLY_ANIMATION_TARGET:
    cmd, signed_q12_weight, first_vertex, count,
    count * (delta_x, delta_y, delta_z)
    -> ACK_ANIMATION_TARGET

FINISH_ANIMATED_FRAME:
    cmd -> ACK_FRAME, vertex_count

LOAD_NORMALS:
    cmd, count, count * (nx, ny, nz) -> ACK_NORMALS, count

LOAD_TRIANGLES:
    cmd, count, count * (i0 | i1<<12, i2 | n0<<12, n1 | n2<<12)
    -> ACK_LOAD_TRIANGLES, count

BUILD_TRIANGLES:
    cmd, count, first_triangle, count * (u0 | v0<<8 | u1<<16,
                                          v1 | u2<<8 | v2<<16)
    -> ACK_TRIANGLES, survivor_count

GET_TRIANGLES:
    cmd -> ACK_GET_TRIANGLES, survivor_count,
           survivor_count * 18-word packed span record

PREPASS:
    cmd, mode -> ACK_PREPASS, survivor_count       (modes 0-3)
    cmd, 4    -> ACK_PREPASS, stamp_calls, stamped_cells, query_kills,
                 dirty_merges, query_cells_visited, stamp_cells_visited
    cmd, $100|mask -> ACK_PREPASS, survivor_count  (only with PHASEPROBE=1)

SSI_STREAM ($40), only when assembled with SSIPROBE=1:
    cmd, payload_count, seed, 8 header words, 6 footer words
    -> ACK_SSI_STREAM, stall_status
```

Mode `$100|mask` is the per-phase BUILD timing ladder of `OPTIMIZATION.md`
2.4l. It only stores `phase_mask` and acknowledges — it runs nothing, and the
survivor count it returns is the occlusion prepass's, which the ladder never
sets. Bit 8 is the selector because modes 0..7 are the whole low octal range
the arming and counter decodes already occupy, so a mask sent to a build
without `PHASEPROBE` would arm the prepass or draw the seven-word counter
reply instead. A clear bit in bits 0..6 makes BUILD's per-triangle body jump
to `triangle_advance` at that phase, so a mask of `(1<<N)-1` executes the
first N phases for exactly the triangles BUILD would run them on: both cull
branches stay inside the ladder. The mask defaults to `$7f`, so an image
whose host never sends the mode word builds complete records.

`SSI_STREAM` exists only with `SSIPROBE=1`.  In any other image the
dispatcher's control-range leaf falls through to `command_reset`, so a host
that sends `$40` to the wrong `.lod` resets the DSP and is told `ACK_RESET`.
That is why the `TREX_SSI_DMA` build loads `TREXDMA.LOD` rather than
`trex_dsp.lod` and why `make ssi_dma_package` gates the pair on the image's
`P:$09B8` extent before it can be shipped to a Falcon.

`SSI_STREAM` is the only command that does not answer over the host port
immediately. It is the DSP half of the Falcon SSI transport probe: it
configures the SSI for 16-bit transmit, drives PC5 by hand as the DMA-RECORD
handshake frame line, and transmits the host's envelope with a generated ramp
between the header and the footer. It answers only once the burst is over,
so the host must arm the record channel first and collect the reply last.
Both waits are bounded; a stalled transmitter returns status 1 rather than
hanging. See OPTIMIZATION.md section 7.4b.

The light payload is six Q1.23 direction-and-intensity vectors (three source
lights, red channel then green -- green also serves blue in this scene) plus
a 2-word red/green ambient term: 6*3 + 2 = 20 words.

`LOAD_TRIANGLES` packs three words per triangle, not two: the third carries
the two corner-normal indices needed for Gouraud shading (`n1 | n2<<12`), in
addition to the vertex/corner-normal indices packed into the first two.

Word A additionally carries the **occluder qualification** in bit 23, the
spare top bit of its twelve-bit `v1` field (vertex indices stay below 1,376,
so eleven bits carry them). Set means the triangle writes opaquely everywhere
its conservative UV footprint reaches, so its coverage may seal for occlusion
culling; the host takes it from the same `o3d2opaque.js` sidecar that drives
`OPAQUE_PACKET_BIT`. Every vertex extraction on the DSP masks to eleven bits
(`TRI_VERTEX_MASK`) -- including the two taken from a shift, which previously
needed no mask at all -- while normal indices keep the full twelve.

`BUILD_TRIANGLES`'s fixed header (count, first_triangle) is three words in
regardless of chunk size, as it always was, but it is now followed by the
chunk's own UV pairs -- two packed words per triangle -- since the
corner-normal table displaced the old resident UV table. The tail therefore
does scale with chunk size even though the header does not.

`PREPASS` mode 0 disarms, 1 arms the FINISH hook, and 2/3 run the prepass
immediately. All four return only the fixed two-word acknowledgement.
Mode 4 (5-7 alias it) computes nothing and returns the six diagnostic
counters the last run left in `prepass_status+2..+7` -- stamp calls, stamped
cells, query kills, dirty merges, query cells visited, stamp cells visited
-- which every run resets; the `-DTREX_PREPASS` host reads them per frame in
arm 2 and writes the sums to `prep_sta.res` (`OPTIMIZATION.md` 2.3j).
The pass sorts the full 2,724-triangle survivor list into 64 conservative
32-bucket depth classes, queries sealed 8x8-cell coverage, and stamps only qualified opaque
triangles when all four cell corners are inside the front-facing triangle.
BUILD skips the resulting global kill flags. Command code 10 was `LOAD_UVS`
until the corner-normal table displaced the resident UV table that command
uploaded; UVs now ride each `BUILD_TRIANGLES` chunk instead (above), which
freed slot 10 for `PREPASS`. See `OPTIMIZATION.md` section 2.3 for the design
and current validation status.

`BUILD_TRIANGLES`/`GET_TRIANGLES` run in 32-triangle chunks. The frontend
starts chunk N+1 before it unpacks chunk N, so the DSP keeps working during
framebuffer clear and host packet construction. The 18-word wire record is
expanded back into the semantic 22-field span-setup record on the M68030 (17
classic DDA fields plus 5 Gouraud level fields). Format, validation and
measurements are in `OPTIMIZATION.md`.

The older `SET_FRAME` protocol remains in place for the independent protocol
test and the host fallback, but it is not the normal animation and raster path.
`GET_VERTICES` (command 3) is **gone**: the span-setup record retired it from
the normal path and the occlusion stage claimed its eighteen program words, so
the dispatcher now answers it with `ERR_BAD_COMMAND`. A host that still issues
it -- the span validator, or the projected-vertex fallback -- sees the wrong
acknowledgement and takes its shadow path instead of waiting for a reply that
never comes.

## Building and testing

```sh
make DOSBOX=/Applications/dosbox.app/Contents/MacOS/DOSBox trex_dsp
make trex_release
```

`trex_release` emits `TREX.TOS`, the full-mesh viewing package with textured
Gouraud shading and no per-frame diagnostic writes. The occlusion code remains
compiled in, but the release defaults it to disarmed because the current yield
measures as a 3.5 ms/frame net loss at the corrected DSP clock. The
frontend copies the same DSP program to `TREX.LOD` beside it, so the
package can be moved to a Falcon directory without renaming a shared runtime
file.  No DSP protocol or DSP memory-layout variant is required.

The non-prepass DSP core has been validated against an independent TOS test harness
(not included in this repository): it reserves the production X/Y layout
and checks `RESET`, the one-time vertex/index/UV uploads, `SET_FRAME`,
projection, survivors-only culling and a full 18-word span record. The
culling case deliberately includes a negative front face and a positive
back face, matching the handedness of the PS1 camera matrix. A headless
Hatari 2.6.1 run on 2026-08-06 wrote `P` to `dsp_test.res`; in addition, the
enabled span validator compared 9,003 records with zero field mismatches.
That is emulator validation; a run on real Falcon hardware is still
outstanding. The 128-class/8x8-cell prepass probe was assembler-checked and
framebuffer-gated, then rejected: on an equal 246-frame Hatari sample it saved
only 2,516 raster writes (0.030%). The active 64-class build keeps its
counters on-chip at `Y:$0096-$00D5`; the resident indices start at `Y:$09C0`
and the last program word of the default build is `P:$0995`, below the
`$09BF` ceiling. The diagnostic prepass build has
`prepass_arm = 1`, so FINISH runs the prepass inline
and it stays armed through the synthetic hold; `TREX_RELEASE` defaults the
same longword to 0. With TOS 4.02, Falcon DSP
emulation, 4 MB ST-RAM and the runtime `.lod` mounted, the armed dumps
matched the disarmed controls byte-for-byte at frame 100
(`d89958b314c924ad6654f5e92cd29b859ab99b0c4f197170dfe8cfc0216f3d16`) and at
hold frame 291
(`e66d4d433360c9e63938bc78efdf774716c31dbaf22679b6ac0ffd1f42b00486`), with
zero prepass protocol failures or capacity overruns, while the armed run
wrote measurably fewer raster pixels -- the kill bitmap is live and its
kills are invisible, as the sealing rule requires. This is emulator
validation only: culling yield and timing on a physical Falcon remain
unmeasured.

The DSP assembler runs under DOSBox; the result is `TREX/dsp/trex_dsp.lod`,
which is then adopted as the runtime copy at `TREX/m68030/trex_dsp.lod`.

Each configuration assembles to its own cached image under
`TREX/dsp/build/trex_dsp-<switches>-<source hash>.lod`, and **only the default
configuration writes the tracked `TREX/dsp/trex_dsp.lod`** — building a variant
tells you where its image landed and leaves the tracked file alone, so a
`make measure` or a release can never pick up a bring-up image by accident.
The name carries both the switch settings and a hash of the DSP source because
the system `make` is 3.81, which compares whole seconds: a rebuild finishing in
the same second as its own source reads as up to date and is skipped. Keying on
a filename makes the decision existence-based, which no clock granularity can
lose. Build a variant with, for example:

```
make SSIPROBE=1 WINPROBE=0 PIOBURST=0 PREPASSDIAG=0 OBJLIGHTS=0 \
     DOSBOX=/Applications/dosbox.app/Contents/MacOS/DOSBox trex_dsp
```
DOSBox-X needs extra flags to reach `BUILD.BAT` headlessly:

```
make DOSBOX=dosbox-x DOSBOX_FLAGS='-nopromptfolder -nogui -nomenu -defaultconf' trex_dsp
```

Hatari measurements and measurements on real Falcon hardware must be
documented strictly separately.

## Measuring this program

Use the DSP-cycle-corrected Hatari, not stock 2.6.1: stock double-applies
`DSP_CPU_FREQ_RATIO` and runs the DSP at 32 MIPS instead of the Falcon's 16, so
**every DSP timing taken on it is about 2x optimistic** (`OPTIMIZATION.md`
2.4a/2.4b). `--mmu true` is also mandatory for any figure compared against
`OPTIMIZATION.md`; without it the CPU core changes and the rasterizer inflates
by ~136 ms/frame (2.4a).

This matters more than it used to. `OPTIMIZATION.md` 2.4c re-took the
whole-frame full-mesh baseline on the corrected emulator and measured
**535.7 ms/frame, of which ~173 ms is exposed DSP time -- about 32% of the
frame and the largest single term outside the rasterizer.** The earlier
conclusion that DSP-side savings buy program words rather than frame rate was
an artefact of the double clock; at the real clock, work removed from this
program is frame time removed from the render.

`OPTIMIZATION.md` 2.4l then divides that exposed term per phase.
`make measure_phase` sweeps the whole mesh through the BUILD chunk protocol
once per phase prefix, with `GET_TRIANGLES` omitted so every level moves the
same words and the all-clear level subtracts the transport, and all eight
levels run inside the same frame so the deltas are paired.  Over the 265-frame
prefix, of **130.4 ms** of DSP compute per frame: `make_triangle_span`
(`span_div` included) **70.1 ms**, `make_triangle_area` 22.3, the chunk loop
and index unpack 13.3, the record pack 11.2, `make_triangle_bbox` 6.3,
`make_triangle_zkey` 5.1, the prelight fetch 2.1.  Span setup is over half of
it and is where a DSP-side lever has to look next.  `make
measure_phase_control` re-runs the top level against an image built *without*
the ladder and prices the seven guards at ~2 ms/frame (1.2-1.5%), which puts
the guard-free compute at 128.1 ms; decode either with
`tools/decode_phase_stats.py`.  The probe host loads `TREXPHAS.LOD` rather
than `trex_dsp.lod`: an image without the ladder decodes the mask as a
`CMD_PREPASS` *arming* mode, so the distinct name makes the wrong pairing
fail to load instead of measuring the wrong thing.
