DOSBOX=dosbox
VASM=./tools/vasm/vasmm68k_mot
VLINK=./tools/vlink/vlink

.PHONY: all clean trex_m68030 trex_m68030_run trex_m68030_prepass trex_m68030_prepass_run trex_release trex_dsp create_dirs

all: create_dirs $(VASM) $(VLINK) ./TREX/m68030/TREX.TOS ./TREX/m68030/TREX.LOD

trex_m68030: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_m68030.tos ./TREX/m68030/trex_dsp.lod

trex_m68030_run: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_run.tos ./TREX/m68030/trex_dsp.lod

# DSP occlusion-culling campaign binary for the one supported full mesh.
trex_m68030_prepass: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_prepass.tos ./TREX/m68030/trex_dsp.lod

# DSP occlusion-culling viewing binary.  TREX_RUN suppresses diagnostic GEMDOS
# writes so the Hatari disk indicator is not hit once per frame.
trex_m68030_prepass_run: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_prepass_run.tos ./TREX/m68030/trex_dsp.lod

trex_dsp: create_dirs ./TREX/dsp/trex_dsp.lod

trex_release: create_dirs $(VASM) $(VLINK) ./TREX/m68030/TREX.TOS ./TREX/m68030/TREX.LOD

create_dirs:
	@mkdir -p ./TREX/m68030/build
	@mkdir -p ./TREX/dsp/build

./tools/vasm:
	tar -xf ./tools/vasm.tar.gz --directory ./tools

$(VASM): ./tools/vasm
	cd ./tools/vasm/ && $(MAKE) CPU=m68k SYNTAX=mot

./tools/vlink:
	tar -xf ./tools/vlink.tar.gz --directory ./tools

$(VLINK): ./tools/vlink
	cd ./tools/vlink/ && $(MAKE)

./TREX/model/trex.o3d: ./TREX/model/trex.obj ./tools/wavefront2object.js
	node tools/wavefront2object.js $< $@

# Per-polygon geometric normals for the flat-shading stage.  Derived from the
# O3D rather than the OBJ so the order matches the BSP-sorted polygon stream
# the M68030 front end already streams to the DSP.
./TREX/model/trex_facenormals.bin: ./TREX/model/trex.o3d ./tools/o3d2facenormals.js
	node tools/o3d2facenormals.js $< $@

# Per-polygon base colours, reordered from the TMD into O3D polygon order.
./TREX/model/trex_facecolors.bin: ./TREX/model/trex.o3d ./TREX/model/trex.tmd ./tools/o3d2facecolors.js
	node tools/o3d2facecolors.js ./TREX/model/trex.o3d ./TREX/model/trex.tmd $@

# Three TMD normal indices per polygon (Gouraud corner shading): the O3D
# discarded two of the source's three; this recovers them by vertex-set match.
./TREX/model/trex_cornernormals.bin: ./TREX/model/trex.o3d ./TREX/model/trex.tmd ./tools/tmd2cornernormals.js
	node tools/tmd2cornernormals.js ./TREX/model/trex.o3d ./TREX/model/trex.tmd $@

TREX_TEXTURE_DEPS = ./TREX/textures/trex_texture_page_10.tim \
	./TREX/textures/trex_texture_page_12.tim \
	./TREX/textures/trex_texture_page_14.tim \
	./TREX/textures/trex_texture_page_26.tim \
	./TREX/textures/trex_texture_page_28.tim \
	./TREX/textures/trex_texture_page_30.tim

# One host-owned byte per source triangle.  A set byte proves that every
# conservatively reachable palette word is non-zero, so a normal textured
# packet may use the flag-free 16-bit CLUT.  This never widens the DSP record.
./TREX/model/trex_opaque.bin: ./TREX/model/trex.o3d ./tools/o3d2opaque.js $(TREX_TEXTURE_DEPS)
	node tools/o3d2opaque.js $< ./TREX/textures $@

TREX_MESH_DEPS = ./TREX/model/trex.o3d ./TREX/model/trex_facenormals.bin \
	./TREX/model/trex_facecolors.bin ./TREX/model/trex_cornernormals.bin \
	./TREX/model/trex_opaque.bin

./TREX/m68030/build/trex_m68030.o: ./TREX/m68030/trex_m68030.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) $< -quiet -Felf -m68030 -o $@ -L ./TREX/m68030/build/trex_m68030.lst

./TREX/m68030/trex_m68030.tos: ./TREX/m68030/build/trex_m68030.o
	$(VLINK) $^ -tos-fastload -b ataritos -s -e start -o $@

# Viewing build: -DTREX_RUN zeroes stats_flush_enabled and
# framebuffer_dump_enabled, so the frame loop performs no GEMDOS writes.
#
# NOT layout-identical, and this comment used to claim it was.  The two flags
# do assemble the same dc.l on both branches, but TREX_RUN ALSO drops the
# `bsr trex_write_render_stats` from trex_shutdown, and that shifts the text
# after it: cmp -l between TREX.TOS and the same source built without
# TREX_RUN reports 3,681 differing bytes in a 9,948-byte text section, mostly
# address operands moved by two.  Section 2 of OPTIMIZATION.md records eight
# bytes of text moving the rasterizer 28.1 ms, so timings must NOT be carried
# across this flag.
#
# To time a build whose shipping form defines TREX_RUN, patch the flag byte in
# the linked binary instead -- one byte, layout-identical by construction.
# OPTIMIZATION.md 2.4e does exactly that for the release and gives the offsets.
./TREX/m68030/build/trex_run.o: ./TREX/m68030/trex_m68030.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) $< -quiet -Felf -m68030 -DTREX_RUN -o $@ -L ./TREX/m68030/build/trex_run.lst

./TREX/m68030/trex_run.tos: ./TREX/m68030/build/trex_run.o
	$(VLINK) $^ -tos-fastload -b ataritos -s -e start -o $@

./TREX/m68030/build/trex_prepass.o: ./TREX/m68030/trex_m68030.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) $< -quiet -Felf -m68030 -DTREX_PREPASS -o $@ -L ./TREX/m68030/build/trex_prepass.lst

./TREX/m68030/trex_prepass.tos: ./TREX/m68030/build/trex_prepass.o
	$(VLINK) $^ -tos-fastload -b ataritos -s -e start -o $@

./TREX/m68030/build/trex_prepass_run.o: ./TREX/m68030/trex_m68030.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) $< -quiet -Felf -m68030 -DTREX_PREPASS -DTREX_RUN -o $@ -L ./TREX/m68030/build/trex_prepass_run.lst

./TREX/m68030/trex_prepass_run.tos: ./TREX/m68030/build/trex_prepass_run.o
	$(VLINK) $^ -tos-fastload -b ataritos -s -e start -o $@

# TREX_FPS draws the NN.NN fps overlay in the render window's top-left corner.
# It is on the release target ONLY: it writes into the framebuffer, so any
# binary whose output is compared or dumped (trex_prepass*, the fb.res capture
# path, the span validator) must stay without it.
./TREX/m68030/build/TREX.o: ./TREX/m68030/trex_m68030.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) $< -quiet -Felf -m68030 -DTREX_RUN -DTREX_PREPASS -DTREX_RELEASE -DTREX_FPS -o $@ -L ./TREX/m68030/build/TREX.lst

./TREX/m68030/TREX.TOS: ./TREX/m68030/build/TREX.o ./TREX/m68030/TREX.LOD
	$(VLINK) ./TREX/m68030/build/TREX.o -tos-fastload -b ataritos -s -e start -o $@

# The release DSP copy is named to match the executable for a self-contained
# Falcon deployment directory.
./TREX/m68030/TREX.LOD: ./TREX/dsp/trex_dsp.lod
	cp $< $@

# The DSP program is assembled by DOS tools under DOSBox.  trex_dsp.lod is
# checked in so the M68030 side builds without that toolchain: when DOSBOX is
# not available this rule keeps the committed file instead of failing, which
# also stops a plain checkout (which makes the .asm look newer) from breaking
# `make trex_m68030`.  Rebuild the DSP explicitly with
#   make DOSBOX=/path/to/DOSBox trex_dsp
./TREX/dsp/trex_dsp.lod: ./TREX/dsp/trex_dsp.asm ./TREX/dsp/BUILD.BAT ./src/ioequ.inc ./tools/asm56k/ASM56000.EXE ./tools/asm56k/CLDLOD.EXE ./tools/asm56k/DOS4GW.EXE
	@if command -v $(DOSBOX) >/dev/null 2>&1; then \
		cp ./TREX/dsp/trex_dsp.asm ./TREX/dsp/BUILD.BAT ./src/ioequ.inc ./tools/asm56k/ASM56000.EXE ./tools/asm56k/CLDLOD.EXE ./tools/asm56k/DOS4GW.EXE ./TREX/dsp/build/ && \
		SDL_VIDEODRIVER=dummy $(DOSBOX) -exit ./TREX/dsp/build/BUILD.BAT && \
		[ -s ./TREX/dsp/build/trex_dsp.lod ] && \
		cp ./TREX/dsp/build/trex_dsp.lod $@; \
	else \
		echo "DOSBOX ($(DOSBOX)) not found - keeping the checked-in $@"; \
		echo "  rebuild with: make DOSBOX=/path/to/DOSBox trex_dsp"; \
		[ -s $@ ] && touch $@; \
	fi
	@[ -s $@ ] || { echo "ERROR: $@ is missing or EMPTY -- restore it" \
		"(git checkout -- $@) before any DSP-dependent run: TOS" \
		"Dsp_LoadProg reads its size via Fsfirst, calls Malloc(0) and" \
		"fails with -1, leaving every run silently DSP-less."; exit 1; }

./TREX/m68030/trex_dsp.lod: ./TREX/dsp/trex_dsp.lod
	@[ -s $< ] || { echo "ERROR: $< is empty, refusing to copy"; exit 1; }
	cp $< $@

# Real recipe commands, not $(shell ...): $(shell ...) is a make FUNCTION
# and is evaluated while make reads/expands the makefile, not when the
# recipe actually runs -- so the old version of this target deleted files
# even under `make -n` (dry run), which is supposed to only print what would
# happen (verified: it emptied files under -n). Plain recipe lines below are
# ordinary shell commands and respect -n like every other rule in this file.
#
# TREX/dsp/trex_dsp.lod is deliberately NOT removed here. It is checked into
# git and rebuilding it needs DOSBox plus the DOS-era assembler in
# tools/asm56k, which most checkouts will not have (see the rule for it
# above); deleting it here would strand anyone without DOSBox. Everything
# else below is cheaply regenerable with only node, or is copied
# from that file by the build.
clean:
	rm -f ./TREX/model/trex_facenormals.bin
	rm -f ./TREX/model/trex_cornernormals.bin
	rm -f ./TREX/model/trex_opaque.bin
	rm -f ./TREX/m68030/trex_m68030.tos
	rm -f ./TREX/m68030/build/trex_m68030.o
	rm -f ./TREX/m68030/build/trex_m68030.lst
	rm -f ./TREX/m68030/trex_run.tos
	rm -f ./TREX/m68030/build/trex_run.o
	rm -f ./TREX/m68030/build/trex_run.lst
	rm -f ./TREX/m68030/trex_prepass.tos
	rm -f ./TREX/m68030/build/trex_prepass.o
	rm -f ./TREX/m68030/build/trex_prepass.lst
	rm -f ./TREX/m68030/trex_prepass_run.tos
	rm -f ./TREX/m68030/build/trex_prepass_run.o
	rm -f ./TREX/m68030/build/trex_prepass_run.lst
	rm -f ./TREX/m68030/TREX.TOS
	rm -f ./TREX/m68030/build/TREX.o
	rm -f ./TREX/m68030/build/TREX.lst
	rm -f ./TREX/m68030/TREX.LOD
	rm -f ./TREX/m68030/trex_dsp.lod
	rm -f ./TREX/dsp/build/*
