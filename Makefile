DOSBOX=dosbox
VASM=./tools/vasm/vasmm68k_mot
VLINK=./tools/vlink/vlink

.PHONY: all clean trex_m68030 trex_m68030_run trex_m68030_full trex_dsp create_dirs

all: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_m68030.tos ./TREX/m68030/trex_run.tos ./TREX/m68030/trex_full.tos ./TREX/m68030/trex_dsp.lod

trex_m68030: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_m68030.tos ./TREX/m68030/trex_dsp.lod

trex_m68030_run: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_run.tos ./TREX/m68030/trex_dsp.lod

trex_m68030_full: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_full.tos ./TREX/m68030/trex_dsp.lod

trex_dsp: create_dirs ./TREX/dsp/trex_dsp.lod

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

# Offline mesh LOD (see OPTIMIZATION.md section 10 item 10): half-edge
# collapse onto existing vertices only, so the TMD vertex set and the TANM
# animation stay byte-identical.  One tool run emits the decimated O3D, the
# inherited face colours and the TREX_PRIMITIVES include the frontend
# assembles in.  Override per build with make TREX_LOD_TRIANGLES=n (delete
# TREX/model/trex_lod.o3d first -- the count is not a file dependency).
TREX_LOD_TRIANGLES=1600

./TREX/model/trex_lod.o3d: ./TREX/model/trex.o3d ./TREX/model/trex_facecolors.bin ./TREX/model/trex_cornernormals.bin ./TREX/model/trex_animation.bin ./TREX/model/trex_animation.json ./tools/o3dlod.js
	node tools/o3dlod.js ./TREX/model/trex.o3d ./TREX/model/trex_facecolors.bin \
		./TREX/model/trex_cornernormals.bin \
		./TREX/model/trex_animation.bin ./TREX/model/trex_animation.json \
		$(TREX_LOD_TRIANGLES) $@ ./TREX/model/trex_lod_facecolors.bin \
		./TREX/model/trex_lod_cornernormals.bin ./TREX/model/trex_lod.inc

./TREX/model/trex_lod_facecolors.bin ./TREX/model/trex_lod_cornernormals.bin ./TREX/model/trex_lod.inc: ./TREX/model/trex_lod.o3d

./TREX/model/trex_lod_facenormals.bin: ./TREX/model/trex_lod.o3d ./tools/o3d2facenormals.js
	node tools/o3d2facenormals.js ./TREX/model/trex_lod.o3d $@

TREX_TEXTURE_DEPS = ./TREX/textures/trex_texture_page_10.tim \
	./TREX/textures/trex_texture_page_12.tim \
	./TREX/textures/trex_texture_page_14.tim \
	./TREX/textures/trex_texture_page_26.tim \
	./TREX/textures/trex_texture_page_28.tim \
	./TREX/textures/trex_texture_page_30.tim

# One host-owned byte per source triangle.  A set byte proves that every
# conservatively reachable palette word is non-zero, so a normal textured
# packet may use the flag-free 16-bit CLUT.  This never widens the DSP record.
./TREX/model/trex_opaque.bin: ./TREX/model/trex.o3d ./tools/o3d2opaque.py $(TREX_TEXTURE_DEPS)
	python3 tools/o3d2opaque.py $< ./TREX/textures $@

./TREX/model/trex_lod_opaque.bin: ./TREX/model/trex_lod.o3d ./tools/o3d2opaque.py $(TREX_TEXTURE_DEPS)
	python3 tools/o3d2opaque.py $< ./TREX/textures $@

TREX_MESH_DEPS = ./TREX/model/trex_lod.o3d ./TREX/model/trex_lod.inc \
	./TREX/model/trex_lod_facenormals.bin ./TREX/model/trex_lod_facecolors.bin \
	./TREX/model/trex_lod_opaque.bin ./TREX/model/trex.o3d \
	./TREX/model/trex_facenormals.bin ./TREX/model/trex_facecolors.bin \
	./TREX/model/trex_opaque.bin

./TREX/m68030/build/trex_m68030.o: ./TREX/m68030/trex_m68030.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) $< -quiet -Felf -m68030 -o $@ -L ./TREX/m68030/build/trex_m68030.lst

./TREX/m68030/trex_m68030.tos: ./TREX/m68030/build/trex_m68030.o
	$(VLINK) $^ -tos-fastload -b ataritos -s -e start -o $@

# Viewing build: -DTREX_RUN zeroes stats_flush_enabled and
# framebuffer_dump_enabled, so the frame loop performs no GEMDOS writes.
# Same dc.l sizes on both branches -- the binary is layout-identical to
# trex_m68030.tos except for those two data longwords (verify with cmp -l),
# so every timing measured against the main build carries over.
./TREX/m68030/build/trex_run.o: ./TREX/m68030/trex_m68030.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) $< -quiet -Felf -m68030 -DTREX_RUN -o $@ -L ./TREX/m68030/build/trex_run.lst

./TREX/m68030/trex_run.tos: ./TREX/m68030/build/trex_run.o
	$(VLINK) $^ -tos-fastload -b ataritos -s -e start -o $@

# Full-detail build: the original 2,724-triangle assets behind
# -DTREX_FULL_MESH, combined with the no-write TREX_RUN flags -- for visual
# comparison against the 1,600-triangle LOD mesh the renderer ships with.
./TREX/m68030/build/trex_full.o: ./TREX/m68030/trex_m68030.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) $< -quiet -Felf -m68030 -DTREX_RUN -DTREX_FULL_MESH -o $@ -L ./TREX/m68030/build/trex_full.lst

./TREX/m68030/trex_full.tos: ./TREX/m68030/build/trex_full.o
	$(VLINK) $^ -tos-fastload -b ataritos -s -e start -o $@

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

clean:
	$(shell [ -f ./TREX/model/trex_facenormals.bin ] && rm ./TREX/model/trex_facenormals.bin)
	$(shell [ -f ./TREX/model/trex_lod.o3d ] && rm ./TREX/model/trex_lod.o3d)
	$(shell [ -f ./TREX/model/trex_lod.inc ] && rm ./TREX/model/trex_lod.inc)
	$(shell [ -f ./TREX/model/trex_lod_facenormals.bin ] && rm ./TREX/model/trex_lod_facenormals.bin)
	$(shell [ -f ./TREX/model/trex_lod_facecolors.bin ] && rm ./TREX/model/trex_lod_facecolors.bin)
	$(shell [ -f ./TREX/model/trex_cornernormals.bin ] && rm ./TREX/model/trex_cornernormals.bin)
	$(shell [ -f ./TREX/model/trex_lod_cornernormals.bin ] && rm ./TREX/model/trex_lod_cornernormals.bin)
	$(shell [ -f ./TREX/model/trex_opaque.bin ] && rm ./TREX/model/trex_opaque.bin)
	$(shell [ -f ./TREX/model/trex_lod_opaque.bin ] && rm ./TREX/model/trex_lod_opaque.bin)
	$(shell [ -f ./TREX/m68030/trex_m68030.tos ] && rm ./TREX/m68030/trex_m68030.tos)
	$(shell [ -f ./TREX/m68030/build/trex_m68030.o ] && rm ./TREX/m68030/build/trex_m68030.o)
	$(shell [ -f ./TREX/m68030/build/trex_m68030.lst ] && rm ./TREX/m68030/build/trex_m68030.lst)
	$(shell [ -f ./TREX/m68030/trex_run.tos ] && rm ./TREX/m68030/trex_run.tos)
	$(shell [ -f ./TREX/m68030/build/trex_run.o ] && rm ./TREX/m68030/build/trex_run.o)
	$(shell [ -f ./TREX/m68030/build/trex_run.lst ] && rm ./TREX/m68030/build/trex_run.lst)
	$(shell [ -f ./TREX/m68030/trex_full.tos ] && rm ./TREX/m68030/trex_full.tos)
	$(shell [ -f ./TREX/m68030/build/trex_full.o ] && rm ./TREX/m68030/build/trex_full.o)
	$(shell [ -f ./TREX/m68030/build/trex_full.lst ] && rm ./TREX/m68030/build/trex_full.lst)
	$(shell [ -f ./TREX/dsp/trex_dsp.lod ] && rm ./TREX/dsp/trex_dsp.lod)
	$(shell [ -f ./TREX/m68030/trex_dsp.lod ] && rm ./TREX/m68030/trex_dsp.lod)
	$(shell [ -d ./TREX/dsp/build ] && rm -f ./TREX/dsp/build/*)
