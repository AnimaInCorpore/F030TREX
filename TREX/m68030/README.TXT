========================================
  T-REX  -  Atari Falcon030 benchmark
  DSP56001 geometry + 68030 raster
========================================

A Falcon030 port of the T-Rex sequence
from the PlayStation disc "Demo One"
(SCES-00048).  The model, the morph
animation and the texture pages are
the original PS1 data, extracted for
this port.  Everything that moves and
draws them is new Falcon code: the
DSP56001 runs the geometry, the 68030
rasterizes in software.

It is built to be a benchmark.  Both
processors are worked hard, the frame
rate is on screen, and the workload is
identical on every run, which makes it
a yardstick for accelerated machines.

It needs none of them.  A stock 16 MHz
Falcon030 runs it exactly as it is,
and a stock result is as worth having
as an accelerated one - there is no
measurement from any real Falcon yet.


FILES
-----
  TREX.TOS    the demo
  TREX.LOD    DSP56001 program
  README.TXT  this file

Keep the files together.  TREX.TOS
loads TREX.LOD from the current
directory when it starts.


REQUIREMENTS
------------
Atari Falcon030 with a working
DSP56001.  The DSP is not optional:
every triangle comes from it.

4 MB RAM.  The program needs about
3 MB and lives in ST RAM only, so a
1 MB or 2 MB machine cannot run it.

TOS 4.02.  NOT TOS 4.04: on 4.04 the
DSP is never opened, no triangles are
produced and the screen stays black.
The renderer is fine, the DSP load
path is what fails there.

RGB/TV or VGA.  Both are supported and
both show all 224 rendered lines.

No accelerator and no extra DSP RAM
needed.  This is plain 68030 code and
the DSP program fits the stock 96 KB.


RUNNING IT
----------
Start TREX.TOS from the desktop or a
shell, out of the folder it lives in.

Press any key to quit.  The video mode
is put back the way it was.

Nothing is written to disk.

If TREX.LOD is missing, or another
program is holding the DSP, the demo
still runs but the screen stays empty.


WHAT YOU SEE
------------
The 274 frames of the original PS1
choreography, played once.  After the
last one the walk cycle and a slow
turn carry on, so the demo keeps
running until you stop it.

Top left is the frame rate, NN.NN
frames per second, measured over the
frame you are looking at.  The field
is fixed width, so the digits never
jump sideways as the rate changes.


UNDER THE HOOD
--------------
Screen
  240x224 true colour inside a 256x224
  Videl mode, programmed by register,
  double buffered and page flipped, so
  no frame is ever copied.

Mesh
  1376 vertices and 2724 triangles,
  full detail, no reduced model.

Animation
  46 full gait poses plus sparse morph
  targets, rebuilt on the DSP from the
  extracted PS1 data.

DSP56001
  Morph, transform, projection, near
  plane, back face, area and screen
  culling, per corner Gouraud light,
  span setup, and a screen space
  occlusion prepass that kills hidden
  triangles before they are sent.

68030
  Packet build, ordering table and a
  textured Gouraud span rasterizer in
  painter's order, no Z buffer.

Light
  Three coloured lights and a reddish
  ambient, resolved into 16 levels by
  4 tint classes of preshaded palettes,
  so the shading costs nothing per
  pixel.


SPEED
-----
On a stock 16 MHz Falcon030 this is a
slide show, and it is meant to be one:
2724 triangles are lit, projected and
filled in software every single frame.

The only figures recorded so far come
from Hatari, whose timing only
approximates a real machine: about 2.3
frames per second for this build, with
roughly half the frame spent in the
rasterizer and about 40 percent in DSP
readback and packet building.

Nothing has been measured on real
hardware yet.  The number on your own
Falcon is the interesting one.


BENCHMARKING
------------
The workload is the same on every run:
same 274 frames, same mesh, no input,
no random element, no disk access.  So
the readout compares machines
directly: stock against stock, one
accelerator against another, or the
two against each other.

Both processors are loaded.  Raster
and packet work scale with the CPU,
the bus and the caches.  Morph,
transform, lighting and span setup
scale with the DSP.  The host port
sits between the two.

Two phases are worth reporting:

  Frames 0 to 273, the flyby, with
  occlusion culling armed.

  The walk after it, which draws the
  full mesh with culling switched off
  and is the heavier, steadier load.

A stock machine needs nothing special:
that is what this was written and
tuned on.  The code is assembled for
the 68030 and avoids the instructions
the 68040 and 68060 dropped, but it
has never been run on an accelerated
machine.  Reports from either kind,
good or bad, are welcome.


CREDITS
-------
PS1 forensics and programming
  ChatGPT 5.6, Claude Opus 5 and
  Claude Fable 5.  Working out the PS1
  model, animation and texture formats
  and writing all of the 68030 code and
  most of the DSP code was done by AI.

Direction, ideas, and the two inner
loops of the DSP core
  Sascha Springer.  The per vertex
  transform and the perspective divide
  come from the Falcon DSP 3D engine
  he wrote in 1994: the MAC pipeline
  is unchanged apart from three added
  rounding instructions, and it still
  runs 1376 times a frame.  Everything
  beyond that is the AI's work.

Model, animation and textures
  Sony "Demo One" (SCES-00048),
  extracted for this port

256x224 Videl register sets
  Screenspain, Chris/AURA and
  Scandion/Mugwumps, from the
  F030Arcade snowbros port

Source and documentation
  github.com/AnimaInCorpore/F030TREX

A non commercial hobby port.  The
original PS1 assets belong to their
owners.
