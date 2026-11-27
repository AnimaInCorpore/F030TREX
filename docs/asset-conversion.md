# Mesh sources and Falcon conversion

This is the Windows asset workstation inventory and the handoff to the F030TREX
Blender exporters. The tool outputs are working assets. Keep the source mesh,
material images, rig and conversion settings available until the Falcon scene
has passed its export and render checks.

## Choose a tool

| Need | Local tool and handoff | Workstation check on 2026-11-27 |
| --- | --- | --- |
| Recover a game mesh or identify its LODs | `C:\Arbeit\FrostyToolsuite\release\FrostyEditor\FrostyLods.exe`. Select the Battlefront profile and export the mesh resource and its textures. | Both EA profiles indexed and exported a fresh OBJ and four decodable PNGs after the Samsung T5 became readable again. |
| Generate a mesh from an image | ComfyUI Portable on `F:` runs **TRELLIS.2** and **Hunyuan3D 2**. Use the mesh GLB output. **LATO.2** also has an image-to-OBJ path. | TRELLIS.2 GLB, Hunyuan3D standard, multiview and Turbo GLBs, and LATO.2 OBJ. |
| Run original TRELLIS | `C:\Arbeit\triflow\win_port\trellis_image.py`. Import the geometry GLB, or keep the Gaussian PLY as an appearance reference. | Standalone GLB with 580,282 faces and PLY with 474,336 Gaussians. |
| Rebuild topology from a source mesh | **LATO.2** targets vertex count. **TriFlow** uses `--face_count`. **MeshAnything V2** and the legacy V1 both accept a source mesh with `--input_type mesh` and export OBJ. | All four produced fresh OBJ meshes. Check the returned counts against the converter after fitting and cleanup. |
| Create a base-color atlas for a prepared mesh | `H:\ComfyUI\run_3d_nodes.bat`, **Hunyuan3D Wrapper**. UV unwrap if needed, render normal and position views, run Paint, bake, inpaint, apply the atlas, then export GLB. Delight can preprocess the reference image. | Single-view and multiview renders, depth, Paint, baking, inpainting, textured GLB, PBR round-trip and nvdiffrast previews. |
| Create view or appearance references | **MV-Adapter** in the 3D profile on `H:` generates multiview images. **TripoSplat** in ComfyUI Portable exports an SPZ. Use these as references or generate a polygon mesh before the Falcon export. | Six MV-Adapter views and a TripoSplat SPZ. |
| Align, reduce, bake and convert the mesh | Blender 5.3 at `C:\msys64\ucrt64\bin\blender.exe`, with Pillow for the model exporter. | The production model exporter accepted a prepared 404-vertex, 800-triangle TriFlow sample. |

ComfyUI Portable starts from `F:\ComfyUI_windows_portable\run_nvidia_gpu.bat`.
It reads the Hunyuan3D checkpoints on `H:` through its model-path config. The
separate 3D profile on `H:` uses PyTorch 2.11.0+cu128 and the native CUDA
rasterizer wheels saved in `H:\ComfyUI\3d-profile\wheels`.

### Battlefront extraction

The Frosty profiles are `starwarsbattlefront` for EA's 2015 game and
`starwarsbattlefrontii` for EA's 2017 game. Their installed game roots are
`I:\Spiele\STAR WARS Battlefront` and `I:\Spiele\STAR WARS Battlefront II`.
First list resources by filter and confirm the desired LOD. The local
headless tool takes the game executable and profile before the operation.

```powershell
$frosty = 'C:\Arbeit\FrostyToolsuite\release\FrostyEditor\FrostyLods.exe'
$game = 'I:\Spiele\STAR WARS Battlefront\starwarsbattlefront.exe'
& $frosty $game starwarsbattlefront atat "$env:TEMP/battlefront-atat.tsv"
& $frosty $game starwarsbattlefront --export "$env:TEMP/battlefront-export" 'mesh/resource/path'
```

Substitute a resource name from the TSV. `--export-geo` saves
only OBJ geometry, and `--textures` searches and exports textures separately.
The project-specific Battlefront extraction entry point and local inputs
are recorded in `three-patrol/README.md`, which stays local and untracked
because its scripts work on game data.
When asset indexing fails, try reading the selected game's `Data/layout.toc`
directly and check the Windows System log. On 2026-11-27, both direct reads
returned “device is not ready,” and NTFS event 140 on the Samsung Portable
SSD T5 logged “no media” for `I:`, most recently at 09:05:49 local time.
The drive subsequently became readable without software changes. The
underlying cause of the intermittent USB storage failure remains unknown.

After recovery, both games indexed the AT-AT filter with zero failures
(74 mesh resources in 2015 and 84 in 2017). Fresh exports were parsed as
triangle OBJ files with valid position indices, and all four PNGs from each
game decoded. These are source assets for the LOD selection and reduction
steps below.

| Game | Verified mesh resource | OBJ triangles | Texture check |
| --- | --- | ---: | --- |
| Battlefront (2015) | `objects/props/_setpieces/atat_01/atatwreck_01_mesh` | 216,526 | Four RGBA PNGs from 512×512 to 4096×4096 via `--export`. |
| Battlefront II (2017) | `objects/props/landmarks/_galacticempire/at-at_01/atat_destroyed_01/atat_destroyed_01_mesh` | 172,000 | Four 1024×1024 RGBA masks via `--textures atat_destroyed_01`. The OBJ was exported with `--export-geo`. |

### Walking AT-AT conversion fixture

Use EA Battlefront (2015)'s intact walker for conversion and motion checks.
The existing Afterglow extraction reads `gameplay/vehicles/atat/at-at_mesh`
and the Arctic and Walker Assault banks, then decodes
`C_ATAT_Stand_Walk_FWD`. Follow the Afterglow rebuild in the local `three-patrol/README.md`
and use the existing LOD4 reduction with the baked LATO.2 head for the
256×224 Falcon scene. The wreck exports above verify the extractor.

The isolated 2026-11-27 rebuild used a fresh FBX and animation bank extraction.
It decoded 101 source keys into 107 walk poses and exported 214 scene samples.
The result used 1,729 vertices, 2,299 triangles, 1,759 corner normals and two
active texture pages. The fresh 68030 executable and DSP image matched the
saved LOD4 package byte for byte. Hatari 2.6.1-devel replayed the rebuilt
package for 2,700 VBLs and exited successfully. The recording shows the
walker progressing through distinct leg poses.

### Local command-line retopology

Run these from the named tool checkout, using a scratch output folder.

```powershell
# From C:\Arbeit\LATO.2, using an input directory of meshes
& C:\Arbeit\triflow\.venv\Scripts\python.exe win_port/run.py scripts/e2e_inference.py --mesh_dir tmp_ex --out_dir "$env:TEMP/trex-lato-check" --vert_num 1000 --num_workers 0
# From C:\Arbeit\triflow, using an input directory of OBJ files
& .\.venv\Scripts\python.exe win_port/run.py inference.py -i data/dummy_input/multi_component -o "$env:TEMP/trex-triflow-check" --face_count 800
# From C:\Arbeit\MeshAnythingV2
& .\.venv\Scripts\python.exe main.py --input_type mesh --input_path examples/wand.obj --out_dir "$env:TEMP/trex-meshanything-check"
```

For LATO.2 image-to-mesh use `scripts/image_e2e_inference.py --image_dir <dir>`
in place of the mesh script and omit `--num_workers`. That path uses the
locally cached TRELLIS sparse-structure and BiRefNet checkpoints. MeshAnything
V1 uses the V2 Python environment from its own checkout. Original TRELLIS's
launcher, checkpoint layout and sample command are recorded in
`C:\Arbeit\triflow\win_port\TRELLIS.md`.

The Windows ports are committed on a local `win-port` branch in each clone,
not pushed: `LATO.2` (`win_port/` and the `tmp_ex/dragon.glb` smoke input),
`MeshAnythingV2` (eager attention instead of flash-attn) and `triflow`
(`win_port/`, with `third_party/TRELLIS` and its FlexiCubes submodule on their
own `win-port` branches so FlexiCubes runs without kaolin). Model weights,
virtual environments, outputs and the pyfqmr Cython build stay untracked. To
rebuild on another machine, clone upstream, fetch these branches and switch to
`win-port` (`git submodule update` in TriFlow).

## Handoff to the Falcon exporter

1. Import the source and candidate into Blender. Use OBJ for geometry and GLB
   when carrying UVs or material images. Fit the candidate to the original
   in the rest pose and verify axes, origin, scale, silhouette, winding and
   the parts that must move independently. Apply the dimensions to the mesh
   coordinates. The model exporter reads those coordinates and checks their
   signed 16-bit range at the scene's `falcon_units_per_metre`.
2. Set the triangle and vertex budgets before painting or baking. Inspect the
   evaluated triangulated counts after modifiers. Generated meshes can contain
   disconnected pieces, split vertices and UV seams. A Decimate ratio is a
   request. Confirm the resulting mesh, and use a retopology pass or further
   cleanup if the modifier leaves the asset over budget.
3. Rebuild or verify UVs on the intended topology and bake the source appearance
   onto it. Keep UVs in 0–1 and use at most six page images. The exporter uses
   the first image in each material as a 256×256 page with a 256-entry CLUT.
   Put the intended base-color atlas first and inspect the quantized result.
   Use the scene exporter to check that mesh topology and corner data stay
   fixed during animation.
4. For a paired static model and animation, run
   `make model_export BLEND=<scene.blend> MODEL_OBJECT=<name> MODEL_DIR=<scratch-dir>`.
   The model exporter checks vertex and index limits and actual DSP bank
   usage, which also depends on the deduplicated corner normals. Review the
   resulting TMD, OBJ, texture pages and scene assets before using the same
   `MODEL_DIR` for a Hatari preview. See [OPTIMIZATION.md §6.6h](../OPTIMIZATION.md#66h-any-blender-model-as-a-model-directory).
5. For a rigid replacement on an existing rig, reuse
   [blender_fit_external.py](../tools/blender_fit_external.py) and the
   `external=<bone>:<file.obj>` handoff in
   [blender_reduce_rigid.py](../tools/blender_reduce_rigid.py). Use the AT-AT
   procedure in [OPTIMIZATION.md §6.6j](../OPTIMIZATION.md#66j-two-walkers-on-a-snowfield-one-model-several-actors-2026-11-20)
   for the source-specific axis conversion, fit, symmetry and bake.

The textured smoke test took the scaled TriFlow sample through Blender GLB
export, Hunyuan3D Wrapper UV unwrap and Paint, then reimported the textured
GLB before Falcon export. The geometry-only export had 404 vertices and
800 triangles. The textured import had 1,955 vertices at the same 800
triangles. It produced one texture page and used 14,487 of 14,647 X words.
Validate the final imported mesh again after UV or format changes.

Record the source resource and LOD, tool and checkpoint, parameters,
export scale, final evaluated counts and the export check alongside the
asset. The workstation smoke tests establish tool operation. Falcon timing
and scene acceptance require their own runs.
