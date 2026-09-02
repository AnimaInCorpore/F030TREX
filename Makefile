DOSBOX=dosbox
# Assemble the DSP-side SSI transport probe (CMD_SSI_STREAM) into the .lod.
# It costs P memory the renderer needs, so the shipping and measurement builds
# leave it out; the SSI bring-up targets set it to 1.  See trex_dsp.asm's
# "SSI transport probe" block and the P:$09BF ceiling note beside it.
SSIPROBE=0
# Assemble the cross-frame window capacity probe (2.4f).  Default OFF since
# the prelight pass (2.4k) took the program words it used to occupy.  To
# re-take a window-capacity sweep build WINPROBE=1 OBJLIGHTS=0, which ends
# exactly at the P:$09BF ceiling (tools/probe_units.py then patches that
# variant image, not the tracked one); WINPROBE=1 alone no longer fits.
WINPROBE=0
# Assemble the host-port per-word calibration burst (CMD_PIO_BURST, 8.2a).
# Its calibration is already taken and recorded, so the default build leaves
# it out; set to 1 to re-take it.
PIOBURST=0
# Assemble the 2.3j occlusion-prepass diagnostic counters.  Default OFF since
# the prelight pass (2.4k) needed their program words; the mode-4 readout
# keeps its seven-word reply shape and reports zeros.  Rebuild with
# PREPASSDIAG=1 OBJLIGHTS=0 (P:$09B1) to re-take a 2.3j counter measurement;
# PREPASSDIAG=1 alone no longer fits.  They are write-only --
# nothing but mode 4 reads prepass_status+2..+7 -- so dropping them cannot
# change rendered output, which the frame-100 checkpoint verifies.
PREPASSDIAG=0
# Rotate the light vectors into object space once per frame instead of
# transforming every corner normal.  Pixel-identical to OBJLIGHTS=0 over the
# 321-frame hash sweep (2.4j), and 19 program words cheaper is the reason the
# SSI bring-up build takes the 0 form.
OBJLIGHTS=1
# Light each frame's survivors inside the FINISH window (prelight_run) and
# have BUILD read the results from prelight_table, instead of calling
# make_triangle_shade per survivor in the exposed packet stage
# (OPTIMIZATION.md 2.4k).  Byte-identical output by construction; 0 restores
# the BUILD-side shading and is what the SSI bring-up configuration needs to
# fit its transport probe under P:$09BF.
PRELIGHT=1

# One generator for the assembler-visible build switches, used by every DSP
# rule so a variant can never assemble against a stale or missing config.
#
# The .lod's dependency on those switches is carried by a stamp whose NAME
# encodes them.  Changing any switch names a stamp that does not exist yet, so
# the .lod rebuilds whatever the timestamps say.  That matters here: GNU make
# 3.81 (the macOS system make) compares whole seconds only, so a build that
# lands in the same second as its own source is otherwise skipped -- and before
# the stamp existed nothing tied the image to its configuration at all, so
# asking for one variant could silently leave you the previous one.
DSPCONF_ID=$(SSIPROBE)$(WINPROBE)$(PIOBURST)$(PREPASSDIAG)$(OBJLIGHTS)$(PRELIGHT)
DSPCONF_STAMP=./TREX/dsp/build/dspconf-$(DSPCONF_ID).stamp
# Each configuration assembles to its own image, so asking for one names a file
# that either exists (and is current) or does not (and is built).  Existence is
# a signal no clock granularity can lose, which timestamps here cannot promise.
# ...and the same trick for the sources, because the switches are only half the
# input.  Hashing the DSP source into the name means an edit also names a file
# that does not exist yet, so `touch`-then-build inside one second -- which the
# whole-second comparison reads as up to date -- cannot skip the assembly.
DSPSRC_ID=$(shell cat ./TREX/dsp/trex_dsp.asm ./src/ioequ.inc 2>/dev/null | shasum -a 256 | cut -c1-8)
DSPVARIANT=./TREX/dsp/build/trex_dsp-$(DSPCONF_ID)-$(DSPSRC_ID).lod
# The identity of the default: only this configuration may write the tracked
# ./TREX/dsp/trex_dsp.lod, so a variant build can never leave the wrong image
# in the tree for `make measure` or a release to pick up.
DSPCONF_DEFAULT_ID=000011
DSPCONF=printf 'SSIPROBE\tequ\t%s\nWINPROBE\tequ\t%s\nPIOBURST\tequ\t%s\nPREPASSDIAG\tequ\t%s\nOBJLIGHTS\tequ\t%s\nPRELIGHT\tequ\t%s\n' '$(SSIPROBE)' '$(WINPROBE)' '$(PIOBURST)' '$(PREPASSDIAG)' '$(OBJLIGHTS)' '$(PRELIGHT)' > ./TREX/dsp/build/dspconf.inc
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
# (OPTIMIZATION.md 2.4b) rather than trusting this constant.  Re-converged for
# the 2.4k prelight build (459.6 ms/frame); it was 7215 for the 8.2b
# direct-unpack + 2.4j object-lights build (497.2 ms/frame).
MEASURE_VBLS=6700
# Converged VBL budgets for the three-build rasterizer split (measure_split).
# Each has to land on the SAME frame count as MEASURE_FRAMES or the averages
# are taken over different stretches of the choreography and do not subtract;
# the profile builds are faster and therefore need fewer VBLs.  Re-converge
# all four after any program change rather than trusting these constants.
# STALE since 8.2b (the split has not been re-taken on the direct-unpack
# build); the decoder's --expect-frames refuses a mismatched run, so a stale
# budget fails loudly rather than subtracting garbage.
MEASURE_FRAMES=265
MEASURE_SPLIT_VBLS=7605
MEASURE_SPLIT_NOPIX_VBLS=6760
MEASURE_SPLIT_NOROWS_VBLS=5270

.PHONY: dspconf measure_split_run all clean trex_m68030 trex_m68030_run trex_m68030_prepass trex_m68030_prepass_run trex_m68030_ssi_shadow trex_m68030_ssi_rows trex_m68030_ssi_hatari trex_m68030_ssi_dma ssi_dma_verify measure_split trex_ssi_loopback ssi_rows_verify ssi_hatari_verify trex_release trex_dsp ssi_stream_model_test ssi_dma_compile_test measure create_dirs

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

# Camera-space lights A/B reference (OBJLIGHTS rewritten 1 -> 0): the
# pre-adoption per-corner rotation, kept rebuildable because it is the
# measured baseline of the 2.4e object-lights A/B.  Produces
# trex_dsp_cam.lod; rename it to trex_dsp.lod beside a diagnostic host
# binary to run it -- no host-side change exists or is needed.  The
# 321-frame TREX_FRAME_HASH sweep measured the two pixel-identical.
# Write the assembler-visible build switches, and stamp which set they are.
# Old stamps are removed so exactly one is present and it always describes the
# dspconf.inc sitting beside it.
$(DSPCONF_STAMP): | create_dirs
	@rm -f ./TREX/dsp/build/dspconf-*.stamp
	@$(DSPCONF)
	@touch $@

dspconf: $(DSPCONF_STAMP)

trex_dsp_camlights: create_dirs
	@command -v $(DOSBOX) >/dev/null 2>&1 || { echo "DOSBOX ($(DOSBOX)) not found"; exit 1; }
	cp ./TREX/dsp/trex_dsp.asm ./TREX/dsp/BUILD.BAT ./src/ioequ.inc ./tools/asm56k/ASM56000.EXE ./tools/asm56k/CLDLOD.EXE ./tools/asm56k/DOS4GW.EXE ./TREX/dsp/build/
	$(MAKE) --no-print-directory OBJLIGHTS=0 dspconf
	grep -q 'OBJLIGHTS	equ	0' ./TREX/dsp/build/dspconf.inc
	SDL_VIDEODRIVER=dummy $(DOSBOX) $(DOSBOX_FLAGS) -exit ./TREX/dsp/build/BUILD.BAT
	[ -s ./TREX/dsp/build/trex_dsp.lod ]
	cp ./TREX/dsp/build/trex_dsp.lod ./TREX/dsp/trex_dsp_cam.lod

# Assemble the configuration named by the switches.  Depending on $(DSPVARIANT)
# rather than on the tracked .lod is what makes a switch change reliable: the
# variant either exists or it does not, and make cannot mistake that for
# up-to-date the way it can with two files written in the same second.
trex_dsp: create_dirs
	@if ! command -v $(DOSBOX) >/dev/null 2>&1; then \
		$(MAKE) --no-print-directory ./TREX/dsp/trex_dsp.lod; \
	elif [ "$(DSPCONF_ID)" = "$(DSPCONF_DEFAULT_ID)" ]; then \
		$(MAKE) --no-print-directory $(DSPVARIANT) && \
		{ cmp -s $(DSPVARIANT) ./TREX/dsp/trex_dsp.lod || cp $(DSPVARIANT) ./TREX/dsp/trex_dsp.lod; }; \
	else \
		$(MAKE) --no-print-directory $(DSPVARIANT) && \
		{ echo "configuration $(DSPCONF_ID) assembled to $(DSPVARIANT)"; \
		  echo "  the tracked ./TREX/dsp/trex_dsp.lod is the default build and is left untouched"; }; \
	fi

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

# Whole-choreography output gate: hashes every rendered frame into
# frmhash.res (OPTIMIZATION.md 2.4e).  Compare two runs' sidecars with cmp.
# NO timing figure may be taken from this build.
trex_m68030_framehash: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_framehash.tos ./TREX/m68030/trex_dsp.lod

# Host-port per-word calibration (OPTIMIZATION.md 8.2a).  Runs four
# CMD_PIO_BURST configurations before the renderer starts and writes
# pio_cal.res; decode with tools/decode_pio_cal.py.
trex_m68030_pio_cal: create_dirs $(VASM) $(VLINK) ./TREX/m68030/trex_pio_cal.tos ./TREX/m68030/trex_dsp.lod

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

./TREX/m68030/build/trex_framehash.o: ./TREX/m68030/trex_m68030.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) ./TREX/m68030/trex_m68030.s -quiet -Felf -m68030 -DTREX_FRAME_HASH -o $@ -L ./TREX/m68030/build/trex_framehash.lst

./TREX/m68030/trex_framehash.tos: ./TREX/m68030/build/trex_framehash.o
	$(VLINK) $^ -tos-fastload -b ataritos -s -e start -o $@

./TREX/m68030/build/trex_pio_cal.o: ./TREX/m68030/trex_m68030.s ./src/gemdos.s ./src/xbios.s $(TREX_MESH_DEPS) ./TREX/model/trex_animation.bin
	$(VASM) ./TREX/m68030/trex_m68030.s -quiet -Felf -m68030 -DTREX_PIO_CAL -o $@ -L ./TREX/m68030/build/trex_pio_cal.lst

./TREX/m68030/trex_pio_cal.tos: ./TREX/m68030/build/trex_pio_cal.o
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
$(DSPVARIANT): ./TREX/dsp/trex_dsp.asm ./TREX/dsp/BUILD.BAT ./src/ioequ.inc ./tools/asm56k/ASM56000.EXE ./tools/asm56k/CLDLOD.EXE ./tools/asm56k/DOS4GW.EXE $(DSPCONF_STAMP)
	@command -v $(DOSBOX) >/dev/null 2>&1 || { \
		echo "DOSBOX ($(DOSBOX)) not found - cannot assemble configuration $(DSPCONF_ID)"; \
		echo "  install DOSBox, or pass DOSBOX=/path/to/DOSBox"; exit 1; }
	@rm -f ./TREX/dsp/build/trex_dsp-$(DSPCONF_ID)-*.lod
	@cp ./TREX/dsp/trex_dsp.asm ./TREX/dsp/BUILD.BAT ./src/ioequ.inc ./tools/asm56k/ASM56000.EXE ./tools/asm56k/CLDLOD.EXE ./tools/asm56k/DOS4GW.EXE ./TREX/dsp/build/
	@SDL_VIDEODRIVER=dummy $(DOSBOX) $(DOSBOX_FLAGS) -exit ./TREX/dsp/build/BUILD.BAT
	@[ -s ./TREX/dsp/build/trex_dsp.lod ] || { \
		echo "ERROR: assembly of configuration $(DSPCONF_ID) produced no image"; exit 1; }
	@cp ./TREX/dsp/build/trex_dsp.lod $@

# The tracked default image.  Its rule exists so an edit to the DSP source
# rebuilds it on the way to a host target, and so a checkout without the DOS
# toolchain keeps the committed file rather than failing -- that is why the
# .lod is committed at all.
./TREX/dsp/trex_dsp.lod: ./TREX/dsp/trex_dsp.asm ./TREX/dsp/BUILD.BAT ./src/ioequ.inc ./tools/asm56k/ASM56000.EXE ./tools/asm56k/CLDLOD.EXE ./tools/asm56k/DOS4GW.EXE $(DSPCONF_STAMP)
	@if ! command -v $(DOSBOX) >/dev/null 2>&1; then \
		echo "DOSBOX ($(DOSBOX)) not found - keeping the checked-in $@"; \
		echo "  rebuild with: make DOSBOX=/path/to/DOSBox trex_dsp"; \
		[ -s $@ ] && touch $@; \
	elif [ "$(DSPCONF_ID)" != "$(DSPCONF_DEFAULT_ID)" ]; then \
		echo "configuration $(DSPCONF_ID) is not the default - $@ left untouched"; \
		echo "  build it with: make SSIPROBE=.. trex_dsp   (writes $(DSPVARIANT))"; \
		touch $@; \
	else \
		$(MAKE) --no-print-directory $(DSPVARIANT) && cp $(DSPVARIANT) $@; \
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
