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
| `Y:$09C0-$29AB` | 8,172 | packed resident triangle indices |
| `Y:$29AC-$3FFE` | 5,715 | Y half of the corner-normal table (`corner_normals_y`) |

The resident UV-pair table this used to describe no longer exists: the
corner-normal table (needed for Gouraud shading) displaced it, and each
BUILD chunk now carries its own UV pairs instead (`chunk_uvs`, above).

The `-DTREX_PREPASS` overlay uses the same X window before BUILD traffic:
`X:$39DF-$3CB1` is the 723-word phase-local order list, `X:$3CB2-$3F84` is
the 723-word radix scratch/mask area, `X:$3F85-$3FF6` is the 114-word
full-mesh kill bitmap (one bit per 2,724 triangles), and `X:$3FF7-$3FFE` is
prepass status. The two masks use the first 336 words of the scratch area.
The order list overlays the dead UV/output window deliberately: the occlusion
sweep consumes it before the first BUILD chunk, so no sorted-list storage is
needed after that point. This is the stock-hardware-safe lifetime boundary.

The coverage sweep keeps its per-run clear and order cursor outside the
per-entry loop, advances the cell cursor for both covered and uncovered cells,
and returns whether the query found sealed coverage. This matters at edge
poses: without those invariants the culling build could make the displayed
animation appear to stop when the head crossed the right border.

The authored choreography ends at frame 273. The frontend-added post-source
hold still renders the full 2,724-triangle mesh, but sends one PREPASS disarm
when that hold starts: the per-triangle pending-coverage stamp sweep otherwise
exceeds the stock DSP frame budget in the synthetic right-edge poses. Culling
remains the standard path for the authored animation, while the hold uses the
correct unculled BUILD path. With the custom Hatari/TOS 4.02 harness, armed and
disarmed frame-273 captures are byte-identical, and a guarded frame-291 capture
matches the disarmed control with no polygon corruption or stall.

The frontend reserves `X:$0000-$3DFF` and `Y:$0000-$3EF7`. The full-mesh
program occupies P from `$0040` and ends at `$09BA`, leaving five safe words
at `$09BB-$09BF` before the Y indices begin at `$09C0`. This bound has to be checked
after every DSP change, because an overflow overwrites the index list without
an assembler error -- recompute it from the assembled `.lod` rather than
trusting this figure, with the check command in the end-of-file comment of
`trex_dsp.asm`.

The `trex_m68030_prepass_run` viewing target keeps the same full-mesh DSP
occlusion path while disabling the host-side diagnostic flushes. It still
reads `trex_dsp.lod` once during startup; it does not write `render_stats.res`,
`prep_sta.res` or `fb.res` during playback or shutdown.

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
    cmd, mode -> ACK_PREPASS, survivor_count
```

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
immediately. Both acting modes return only the fixed two-word acknowledgement.
The pass sorts the full 2,724-triangle survivor list by the exact 2,048-bucket
OT key, queries sealed 4x4-cell coverage, and stamps only qualified opaque
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
make trex_m68030
make trex_m68030_fullm
make trex_m68030_prepass
```

The non-prepass DSP core has been validated against an independent TOS test harness
(not included in this repository): it reserves the production X/Y layout
and checks `RESET`, the one-time vertex/index/UV uploads, `SET_FRAME`,
projection, survivors-only culling and a full 18-word span record. The
culling case deliberately includes a negative front face and a positive
back face, matching the handedness of the PS1 camera matrix. A headless
Hatari 2.6.1 run on 2026-08-06 wrote `P` to `dsp_test.res`; in addition, the
enabled span validator compared 9,003 records with zero field mismatches.
That is emulator validation; a run on real Falcon hardware is still
outstanding. The current full-mesh prepass has been assembler-checked with
zero errors and warnings and its P/X/Y extents fit the stock overlay. The
standard host build has `prepass_arm = 1`, so FINISH runs the prepass inline.
With TOS 4.02, Falcon DSP emulation, 4 MB ST-RAM and the runtime `.lod` mounted,
the frame-100 arm-1 dump matched the disarmed control byte-for-byte:
`d89958b314c924ad6654f5e92cd29b859ab99b0c4f197170dfe8cfc0216f3d16`.
This is emulator validation only: culling yield and timing on a physical Falcon
remain unmeasured.

The DSP assembler runs under DOSBox; the result is `TREX/dsp/trex_dsp.lod`,
which is then adopted as the runtime copy at `TREX/m68030/trex_dsp.lod`.
Hatari measurements and measurements on real Falcon hardware must be
documented strictly separately.
