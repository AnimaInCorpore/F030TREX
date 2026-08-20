DOSBOX=dosbox
# Assemble the DSP-side SSI transport probe (CMD_SSI_STREAM) into the .lod.
# It costs P memory the renderer needs, so the shipping and measurement builds
# leave it out; the SSI bring-up targets set it to 1.  See trex_dsp.asm's
# "SSI transport probe" block and the P:$09BF ceiling note beside it.
SSIPROBE=0
# Assemble the cross-frame window capacity probe (2.4f).  Default on, as the
# shipping build pays only three instructions per frame for it.  The SSI
# bring-up build turns it off: both instruments together exceed P:$09BF.
WINPROBE=1
# Extra flags for the DSP assembly run.  Plain DOSBox needs none.  DOSBox-X
# opens a working-folder prompt and a menu on macOS and then never reaches
# BUILD.BAT, so it needs:
#   make DOSBOX=dosbox-x DOSBOX_FLAGS='-nopromptfolder -nogui -nomenu -defaultconf' trex_dsp
DOSBOX_FLAGS=
VASM=./tools/vasm/vasmm68k_mot
VLINK=./tools/vlink/vlink

# Timing measurements use the corrected Hatari from the sibling F030Arcade
# checkout, not a stock/Homebrew build: stock runs the Falcon DSP at twice its
# real clock, which costs this program 84 ms per frame in the packet stage
# alone (OPTIMIZATION.md 2.4b).  Override on the command line to compare.
HATARI=../F030Arcade/third_party/hatari/build/src/hatari
TOS402=../F030Arcade/third_party/tos/tos402.img
MEASURE_DIR=./TREX/m68030/measure
# 265-frame prefix on the corrected build; re-converge after any program change
# (OPTIMIZATION.md 2.4b) rather than trusting this constant.
MEASURE_VBLS=7710
# Converged VBL budgets for the three-build rasterizer split (measure_split).
# Each has to land on the SAME frame count as MEASURE_FRAMES or the averages
# are taken over different stretches of the choreography and do not subtract;
# the profile builds are faster and therefore need fewer VBLs.  Re-converge
# all four after any program change rather than trusting these constants.
MEASURE_FRAMES=265
MEASURE_SPLIT_VBLS=7605
MEASURE_SPLIT_NOPIX_VBLS=6760
MEASURE_SPLIT_NOROWS_VBLS=5270

.PHONY: measure_split_run all clean trex_m68030 trex_m68030_run trex_m68030_prepass trex_m68030_prepass_run trex_m68030_ssi_shadow trex_m68030_ssi_rows trex_m68030_ssi_hatari trex_m68030_ssi_dma ssi_dma_verify measure_split trex_ssi_loopback ssi_rows_verify ssi_hatari_verify trex_release trex_dsp ssi_stream_model_test ssi_dma_compile_test measure create_dirs

all: create_dirs $(VASM) $(VLINK) ./TREX/m68030/TREX.TOS ./TREX/m68030/TREX.LOD

trex_m68030: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_m68030.tos ./TREX/m68030/trex_dsp.lod

trex_m68030_run: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_run.tos ./TREX/m68030/trex_dsp.lod

# DSP occlusion-culling campaign binary for the one supported full mesh.
trex_m68030_prepass: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_prepass.tos ./TREX/m68030/trex_dsp.lod

# DSP occlusion-culling viewing binary.  TREX_RUN suppresses diagnostic GEMDOS
# writes so the Hatari disk indicator is not hit once per frame.
trex_m68030_prepass_run: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_prepass_run.tos ./TREX/m68030/trex_dsp.lod

# Optional host-shadow diagnostic: links the compact frame builder and the
# stopped ownership/read-back probe into a separate binary.
trex_m68030_ssi_shadow: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_ssi_shadow.tos

# Optional full-row shadow diagnostic.  It serializes the exact host packet
# setup into ROW_ABS/SET_SHADE records, but still does not start DMA.
trex_m68030_ssi_rows: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_ssi_rows.tos

# Hatari-only SSI loopback.  It consumes the completed full-row stream in
# memory and validates the same envelope/CRC/row accounting a DMA completion
# gate would publish; it does not touch Falcon SSI or Crossbar registers.
trex_m68030_ssi_hatari: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_ssi_hatari.tos

# Falcon-runnable SSI loopback package.  It exercises the complete-row
# consumer and rasterizer feed on the 68030, but deliberately does not touch
# physical SSI, Crossbar or DMA registers.  The distinct LOD name keeps the
# pair self-contained when copied to a real Falcon.
trex_ssi_loopback: create_dirs $(VASM) $(VLINK) ./TREX/m68030/TREXSSI.TOS ./TREX/m68030/TREXSSI.LOD

# Independently recompute the row DDA from the packet sidecar and compare it
# with the decoded full-row stream emitted by the optional diagnostic.
ssi_rows_verify:
	PYTHONPATH=./tools python3 ./tools/verify_ssi_rows.py ./TREX/m68030/ssi_rows.res ./TREX/m68030/ssi_rows.pkt

# Verify both the independent row DDA and the in-emulator Hatari transport
# consumer's completion sidecar.
ssi_hatari_verify:
	PYTHONPATH=./tools python3 ./tools/verify_ssi_hatari.py ./TREX/m68030/ssi_rows.res ./TREX/m68030/ssi_rows.pkt ./TREX/m68030/ssihatri.sta

trex_dsp: create_dirs ./TREX/dsp/trex_dsp.lod

ssi_stream_model_test:
	python3 ./tools/ssi_stream_model.py --self-test

# Live Falcon SSI transport probe.  The ONLY target that claims the sound
# channel, routes DSP-XMIT to DMA-RECORD and starts the record engine.  It
# runs one framed burst before the renderer starts and writes ssi_dma.res
# plus the raw capture ssi_dcap.res.
trex_m68030_ssi_dma: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_ssi_dma.tos ./TREX/m68030/trex_dsp.lod

# Decode and independently re-derive the transport probe's capture.
ssi_dma_verify:
	PYTHONPATH=./tools python3 ./tools/verify_ssi_dma.py ./TREX/m68030/ssi_dma.res ./TREX/m68030/ssi_dcap.res

# Compile-only Falcon SSI/DMA ownership scaffold.  It is intentionally not
# linked into the renderer until the physical owner snapshot/restore and cache
# coherency gates in OPTIMIZATION.md have been closed.
ssi_dma_compile_test: create_dirs $(VASM) ./TREX/m68030/build/ssi_dma.o
	@:

# Headless timing run of the full-mesh diagnostic build, then the report.
# The 8.3 filename matters: GEMDOS truncates trex_m68030.tos, so --auto would
# not find it.  Timers read the 200 Hz tick, so --benchmark does not distort
# the result -- it only stops Hatari waiting on the host's clock.
measure: trex_m68030
	@test -x "$(HATARI)" || { echo "no Hatari at $(HATARI) -- build it in F030Arcade (see its hatari.md) or pass HATARI=..."; exit 1; }
	@test -f "$(TOS402)" || { echo "no TOS 4.02 image at $(TOS402) -- pass TOS402=..."; exit 1; }
	@mkdir -p $(MEASURE_DIR)
	@cp ./TREX/m68030/trex_m68030.tos $(MEASURE_DIR)/TREX_M68.TOS
	@cp ./TREX/m68030/trex_dsp.lod $(MEASURE_DIR)/trex_dsp.lod
	@rm -f $(MEASURE_DIR)/render_stats.res $(MEASURE_DIR)/fb.res
	cd $(MEASURE_DIR) && "$(abspath $(HATARI))" \
	  --machine falcon --cpulevel 3 --cpuclock 16 --mmu true \
	  --patch-tos true --fast-boot true --tos "$(abspath $(TOS402))" \
	  --dsp emu --memsize 4 --ttram 0 --monitor rgb \
	  --frameskips 4 --sound off --benchmark --confirm-quit off \
	  --log-level warn --alert-level fatal \
	  --harddrive . --auto 'C:\TREX_M68.TOS' --run-vbls $(MEASURE_VBLS)
	@python3 ./tools/decode_render_stats.py $(MEASURE_DIR)/render_stats.res
	@echo "frame-100 checkpoint (expect d89958b3...3d16):"
	@shasum -a 256 $(MEASURE_DIR)/fb.res

# The section 3.5 rasterizer split: per-packet setup, row/span walk and pixel
# loops, from three builds over one identical prefix.  NO_ROWS keeps only the
# per-packet setup; NO_PIXELS keeps setup plus the row walk.  Both patches
# preserve the replaced instruction lengths, and the unpatched profile build
# is byte-identical to the normal one -- which is why the split subtracts.
# OPTIMIZATION.md 8.2 holds the current result.
measure_split: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_m68030.tos \
		./TREX/m68030/trex_profile_nopix.tos \
		./TREX/m68030/trex_profile_norows.tos ./TREX/m68030/trex_dsp.lod
	@test -x "$(HATARI)" || { echo "no Hatari at $(HATARI) -- see the measure target"; exit 1; }
	@$(MAKE) --no-print-directory measure_split_run TAG=normal BIN=./TREX/m68030/trex_m68030.tos VBLS=$(MEASURE_SPLIT_VBLS)
	@$(MAKE) --no-print-directory measure_split_run TAG=nopix BIN=./TREX/m68030/trex_profile_nopix.tos VBLS=$(MEASURE_SPLIT_NOPIX_VBLS)
	@$(MAKE) --no-print-directory measure_split_run TAG=norows BIN=./TREX/m68030/trex_profile_norows.tos VBLS=$(MEASURE_SPLIT_NOROWS_VBLS)
	@python3 ./tools/decode_render_stats.py --split \
		$(MEASURE_DIR)/normal/render_stats.res \
		$(MEASURE_DIR)/nopix/render_stats.res \
		$(MEASURE_DIR)/norows/render_stats.res \
		--expect-frames $(MEASURE_FRAMES)
	@echo "frame-100 checkpoint (expect d89958b3...3d16):"
	@shasum -a 256 $(MEASURE_DIR)/normal/fb.res

measure_split_run:
	@mkdir -p $(MEASURE_DIR)/$(TAG)
	@cp $(BIN) $(MEASURE_DIR)/$(TAG)/TREX_M68.TOS
	@cp ./TREX/m68030/trex_dsp.lod $(MEASURE_DIR)/$(TAG)/trex_dsp.lod
	@rm -f $(MEASURE_DIR)/$(TAG)/render_stats.res $(MEASURE_DIR)/$(TAG)/fb.res
	@cd $(MEASURE_DIR)/$(TAG) && "$(abspath $(HATARI))" \
	  --machine falcon --cpulevel 3 --cpuclock 16 --mmu true \
	  --patch-tos true --fast-boot true --tos "$(abspath $(TOS402))" \
	  --dsp emu --memsize 4 --ttram 0 --monitor rgb \
	  --frameskips 4 --sound off --benchmark --confirm-quit off \
	  --log-level fatal --alert-level fatal \
	  --harddrive . --auto 'C:\TREX_M68.TOS' --run-vbls $(VBLS) >/dev/null 2>&1

./TREX/m68030/build/trex_profile_nopix.o: ./TREX/m68030/trex_m68030.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) $< -quiet -Felf -m68030 -DTREX_PROFILE_NO_PIXELS -o $@ -L ./TREX/m68030/build/trex_profile_nopix.lst

./TREX/m68030/trex_profile_nopix.tos: ./TREX/m68030/build/trex_profile_nopix.o
	$(VLINK) $^ -tos-fastload -b ataritos -s -e start -o $@

./TREX/m68030/build/trex_profile_norows.o: ./TREX/m68030/trex_m68030.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) $< -quiet -Felf -m68030 -DTREX_PROFILE_NO_ROWS -o $@ -L ./TREX/m68030/build/trex_profile_norows.lst

./TREX/m68030/trex_profile_norows.tos: ./TREX/m68030/build/trex_profile_norows.o
	$(VLINK) $^ -tos-fastload -b ataritos -s -e start -o $@

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

./TREX/m68030/build/ssi_dma.o: ./TREX/m68030/ssi_dma.s ./src/xbios.s
	$(VASM) $< -quiet -Felf -m68030 -o $@ -L ./TREX/m68030/build/ssi_dma.lst

./TREX/m68030/build/trex_ssi_dma.o: ./TREX/m68030/trex_m68030.s ./TREX/m68030/ssi_dma.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) ./TREX/m68030/trex_m68030.s -quiet -Felf -m68030 -DTREX_SSI_DMA -o $@ -L ./TREX/m68030/build/trex_ssi_dma.lst

./TREX/m68030/trex_ssi_dma.tos: ./TREX/m68030/build/trex_ssi_dma.o ./TREX/m68030/build/ssi_dma.o
	$(VLINK) $^ -tos-fastload -b ataritos -s -e start -o $@

./TREX/m68030/build/trex_ssi_shadow.o: ./TREX/m68030/trex_m68030.s ./TREX/m68030/ssi_dma.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) ./TREX/m68030/trex_m68030.s -quiet -Felf -m68030 -DTREX_SSI_SHADOW -o $@ -L ./TREX/m68030/build/trex_ssi_shadow.lst

./TREX/m68030/trex_ssi_shadow.tos: ./TREX/m68030/build/trex_ssi_shadow.o ./TREX/m68030/build/ssi_dma.o
	$(VLINK) $^ -tos-fastload -b ataritos -s -e start -o $@

./TREX/m68030/build/trex_ssi_rows.o: ./TREX/m68030/trex_m68030.s ./TREX/m68030/ssi_dma.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) ./TREX/m68030/trex_m68030.s -quiet -Felf -m68030 -DTREX_SSI_ROWS -o $@ -L ./TREX/m68030/build/trex_ssi_rows.lst

./TREX/m68030/trex_ssi_rows.tos: ./TREX/m68030/build/trex_ssi_rows.o ./TREX/m68030/build/ssi_dma.o
	$(VLINK) $^ -tos-fastload -b ataritos -s -e start -o $@

./TREX/m68030/build/trex_ssi_hatari.o: ./TREX/m68030/trex_m68030.s ./TREX/m68030/ssi_dma.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) ./TREX/m68030/trex_m68030.s -quiet -Felf -m68030 -DTREX_SSI_ROWS -DTREX_SSI_HATARI -o $@ -L ./TREX/m68030/build/trex_ssi_hatari.lst

./TREX/m68030/trex_ssi_hatari.tos: ./TREX/m68030/build/trex_ssi_hatari.o ./TREX/m68030/build/ssi_dma.o
	$(VLINK) $^ -tos-fastload -b ataritos -s -e start -o $@

./TREX/m68030/build/TREXSSI.o: ./TREX/m68030/trex_m68030.s ./TREX/m68030/ssi_dma.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) ./TREX/m68030/trex_m68030.s -quiet -Felf -m68030 -DTREX_RUN -DTREX_FPS -DTREX_SSI_ROWS -DTREX_SSI_HATARI -DTREX_SSI_LOOPBACK -o $@ -L ./TREX/m68030/build/TREXSSI.lst

./TREX/m68030/TREXSSI.TOS: ./TREX/m68030/build/TREXSSI.o ./TREX/m68030/build/ssi_dma.o
	$(VLINK) $^ -tos-fastload -b ataritos -s -e start -o $@

./TREX/m68030/TREXSSI.LOD: ./TREX/dsp/trex_dsp.lod
	cp $< $@

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
		printf 'SSIPROBE\tequ\t%s\nWINPROBE\tequ\t%s\n' '$(SSIPROBE)' '$(WINPROBE)' > ./TREX/dsp/build/dspconf.inc && \
		SDL_VIDEODRIVER=dummy $(DOSBOX) $(DOSBOX_FLAGS) -exit ./TREX/dsp/build/BUILD.BAT && \
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
	rm -f ./TREX/m68030/build/ssi_dma.o
	rm -f ./TREX/m68030/build/ssi_dma.lst
	rm -f ./TREX/m68030/build/trex_profile_nopix.o
	rm -f ./TREX/m68030/build/trex_profile_nopix.lst
	rm -f ./TREX/m68030/trex_profile_nopix.tos
	rm -f ./TREX/m68030/build/trex_profile_norows.o
	rm -f ./TREX/m68030/build/trex_profile_norows.lst
	rm -f ./TREX/m68030/trex_profile_norows.tos
	rm -f ./TREX/m68030/build/trex_ssi_dma.o
	rm -f ./TREX/m68030/build/trex_ssi_dma.lst
	rm -f ./TREX/m68030/trex_ssi_dma.tos
	rm -f ./TREX/m68030/ssi_dma.res
	rm -f ./TREX/m68030/ssi_dcap.res
	rm -f ./TREX/m68030/build/trex_ssi_shadow.o
	rm -f ./TREX/m68030/build/trex_ssi_shadow.lst
	rm -f ./TREX/m68030/trex_ssi_shadow.tos
	rm -f ./TREX/m68030/build/trex_ssi_rows.o
	rm -f ./TREX/m68030/build/trex_ssi_rows.lst
	rm -f ./TREX/m68030/trex_ssi_rows.tos
	rm -f ./TREX/m68030/build/trex_ssi_hatari.o
	rm -f ./TREX/m68030/build/trex_ssi_hatari.lst
	rm -f ./TREX/m68030/trex_ssi_hatari.tos
	rm -f ./TREX/m68030/build/TREXSSI.o
	rm -f ./TREX/m68030/build/TREXSSI.lst
	rm -f ./TREX/m68030/TREXSSI.TOS
	rm -f ./TREX/m68030/TREXSSI.LOD
	rm -f ./TREX/m68030/ssi_shad.res
	rm -f ./TREX/m68030/ssi_rows.res
	rm -f ./TREX/m68030/ssi_rows.status
	rm -f ./TREX/m68030/ssi_rows.pkt
	rm -f ./TREX/m68030/ssihatri.sta
	rm -f ./TREX/m68030/ssi_route.res
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
	rm -rf $(MEASURE_DIR)
	rm -f ./TREX/dsp/build/*
