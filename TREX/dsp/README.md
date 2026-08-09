# T-Rex DSP core

`trex_dsp.lod` is the DSP56001 geometry and triangle-setup core of the
Falcon030 port. The active path handles, per frame:

1. building the exact PS1 morph pose from the base vertex, the deduplicated
   gait delta and the active Q12 target weights,
2. transforming the 1,376 vertices with the extracted scene matrix,
3. perspective projection onto the 300x224 render target,
4. near-plane, degenerate-area, back-face and screen culling,
5. current 4-bit flat lighting, the Z/OT key and the full DDA span-setup
   record for every visible triangle.

The M68030 reads the 64-byte choreography records, expands the stored XYZ16
deltas into native host-port words, builds the host packets, links the
Ordering Table and rasterizes the prepared spans. It computes none of the
morph products, vertex matrices, projection, culling or span divisions.
Flat lighting is not yet an exact PS1 reproduction: the TMD references three
normals per triangle, and the demo uses three coloured lights plus a reddish
ambient light. That source data has since been extracted; the current
wire/raster format, however, carries only one brightness value per face.

## Memory budget

The Falcon gives the DSP 32K words of external 24-bit RAM. P and Y address
space overlap from `$0200` onward, so the resident Y arrays only start above
the program.

| Range | Words | Purpose |
|---|---:|---|
| `X:$0040-$0043` | 4 | command and translation |
| `X:$0044-$1063` | 4,128 | static base vertices |
| `X:$1064-$25E3` | 5,504 | object/camera pose, then projected vertices in place |
| `X:$25E4-$3B2B` | 5,448 | resident UV pairs |
| `X:$3B2C-$3CEB` | 448 | 32 packed span records at 14 words each |
| `Y:$09C0-$1F07` | 5,448 | packed resident triangle indices |
| `Y:$1F08-$3EF3` | 8,172 | resident face normals |

The frontend reserves `X:$0000-$3DFF` and `Y:$0000-$3EF7`. The current LOD
occupies P from `$0040`; the first free P address is `$075B`. That leaves
613 words of code headroom before the Y indices begin at `$09C0`. This bound
has to be checked after every DSP change, because an overflow overwrites the
index list without an assembler error.

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
    near, light[3]
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
    cmd, count, count * (i0 | i1<<12, i2) -> ACK_LOAD_TRIANGLES, count

LOAD_UVS:
    cmd, count, count * (u0 | v0<<8 | u1<<16,
                         v1 | u2<<8 | v2<<16)
    -> ACK_LOAD_UVS, count

BUILD_TRIANGLES:
    cmd, count, first_triangle -> ACK_TRIANGLES, survivor_count

GET_TRIANGLES:
    cmd -> ACK_GET_TRIANGLES, survivor_count,
           survivor_count * 14-word packed span record
```

`BUILD_TRIANGLES`/`GET_TRIANGLES` run in 32-triangle chunks. The frontend
starts chunk N+1 before it unpacks chunk N, so the DSP keeps working during
framebuffer clear and host packet construction. The 14-word wire record is
expanded back into the semantic 17-field DDA record on the M68030. Format,
validation and measurements are in `OPTIMIZATION.md`.

The older `SET_FRAME`/`GET_VERTICES` protocol remains in place for the
independent protocol test and the host fallback, but it is not the normal
animation and raster path.

## Building and testing

```sh
make DOSBOX=/Applications/dosbox.app/Contents/MacOS/DOSBox trex_dsp
make trex_m68030
```

The DSP core has been validated against an independent TOS test harness
(not included in this repository): it reserves the production X/Y layout
and checks `RESET`, the one-time vertex/index/UV uploads, `SET_FRAME`,
projection, survivors-only culling and a full 14-word span record. The
culling case deliberately includes a negative front face and a positive
back face, matching the handedness of the PS1 camera matrix. A headless
Hatari 2.6.1 run on 2026-08-06 wrote `P` to `dsp_test.res`; in addition, the
enabled span validator compared 9,003 records with zero field mismatches.
That is emulator validation; a run on real Falcon hardware is still
outstanding.

The DSP assembler runs under DOSBox; the result is `TREX/dsp/trex_dsp.lod`,
which is then adopted as the runtime copy at `TREX/m68030/trex_dsp.lod`.
Hatari measurements and measurements on real Falcon hardware must be
documented strictly separately.
