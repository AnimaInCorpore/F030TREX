; -----------------------------------------------------------------------------
; T-Rex PS1-style M68030 front end
;
; This is the Falcon030 side of a PS1-inspired renderer.  Library and GPU
; calls remain local shadows, while the DSP path uses the Falcon XBIOS DSP
; interface and the protocol implemented by TREX/dsp/trex_dsp.asm.
; -----------------------------------------------------------------------------

	include "src/gemdos.s"
	include "src/xbios.s"

	global	start

; -----------------------------------------------------------------------------
; Frame timing instrumentation
;
; _hz_200 ($4ba) is the 200 Hz system tick (5 ms resolution); _frclock ($466)
; counts VBLs.  Both live below $800, so start switches to supervisor mode for
; the whole run.  TimeAdd clobbers d0 and is only used where d0 is dead.
; -----------------------------------------------------------------------------

; The shipping file is 23 big-endian longwords.  -DTREX_PREPASS inserts
; stat_t_prepass as field 22 and NOTHING else: the prepass campaign's own
; counters go into the separate prep_sta.res sidecar (see below) exactly the
; way val_stats.res keeps the span validator out of this buffer.  Appending
; grows render_stats_buffer and shifts everything below it in the data
; section, so it happens ONLY in the prepass binary -- gate G0 covers
; trex_m68030.tos, which never sees the flag.  Inside the prepass binary the
; shift is harmless because all four measurement arms (R0/R0z/R1/R2) are the
; SAME binary with one patched data longword, which is the only comparison
; OPTIMIZATION.md 2.1 accepts anyway.  tools/decode_render_stats.py reads
; both lengths, so the existing baseline .res files stay decodable.
;
; The LAST field is dc_clear_longwords, the cumulative count of longwords the
; delta clear actually wrote.  It exists because the delta-clear campaign has
; to tell a too-wide dirty box apart from too-expensive bookkeeping, and time
; alone cannot: both show up as "the saving is smaller than expected".  Dividing
; it by the frame count and multiplying by four gives the cleared area directly,
; against the 107,520 bytes the full clear writes.  It stays 0 in the full-clear
; arm, which is itself the proof that that arm took the old path.  Field 22 in
; the shipping build, field 23 with -DTREX_PREPASS, so stat_t_prepass keeps its
; documented position and the archived .res files stay readable.
; The tail field ships unconditionally since the delta clear moved into the
; main path (2026-08-09), so only -DTREX_PREPASS still changes the length:
; 23 shipping, 24 with the prepass flag.
DC_STATS_LONGS		= 1
	ifd	TREX_PREPASS
RENDER_STATS_LONGS	= 23+DC_STATS_LONGS
	else
RENDER_STATS_LONGS	= 22+DC_STATS_LONGS
	endc

	macro	TimeMark
	move.l	$4ba.w,\1
	endm

	macro	TimeAdd
	move.l	$4ba.w,d0
	sub.l	\1,d0
	add.l	d0,\2
	endm

; Presentation and render-target geometry.
;
; Videl shows 256x224 true-colour pixels (the mode is programmed directly --
; see the Videl section below), and the renderer draws a 240x224 window
; centred inside it.  Those 256 pixels are wide ones: at four cycles per pixel
; they cover the same physical screen width the previous 320x240 mode's 320
; square pixels did, so the change is a horizontal resampling of the same
; picture, not a smaller viewport.  Everything horizontal therefore scales by
; 256/320 = 240/300 = 0.8 -- the render window, its margin, and the projection
; (PS1_PROJECTION_X below).  Vertically nothing changes: the 224 rendered
; lines are the 224 displayed lines on both monitor types, so the RGB/TV crop
; the 320x200 mode forced is gone.
VIDEO_SCREEN_WIDTH	= 256
VIDEO_SCREEN_HEIGHT	= 224
SCREEN_WIDTH		= 240
SCREEN_HEIGHT		= 224

; -----------------------------------------------------------------------------
; Delta clearing
;
; The full clear writes all 107,520 bytes of the render window every frame, but
; the T-Rex only ever touches about a third of it.  The band table below records
; the horizontal extent every rasterized packet reached, in bands of eight
; scanlines, so the next clear of THAT buffer can wipe only what was dirtied.
;
; Eight rows is the granularity the owner-bitmap campaign measured: exact
; per-row bookkeeping would clear 33.0 % of the frame, 4-row bands 33.4 %,
; 8-row bands 34.0 % and 16-row bands 35.1 %.  Eight buys nearly all of the
; saving at a quarter of the per-packet band-loop iterations of one.  The
; constant is an EQU so the 16-row variant is one edit away -- but changing it
; changes the code layout, so it needs its own A/B campaign and may not be
; compared against 8-row numbers (OPTIMIZATION.md 2.1).
;
; 224/8 divides exactly, so there is no partial band at the bottom edge.
DC_BAND_SHIFT		= 3
DC_BAND_ROWS		= 1<<DC_BAND_SHIFT
DC_BANDS		= SCREEN_HEIGHT/DC_BAND_ROWS
; One entry is two signed words: the lowest and the highest pixel column the
; band was touched at.  Both are FLOORED (asr #12) and stored UNCLAMPED -- the
; clamp to 0..SCREEN_WIDTH-1 costs four instructions and would run 600 times
; per frame in the rasterizer instead of 28 times per frame in the clear, so it
; lives on the clear side.  The right edge the clear uses is dc_xmax+1, which
; is always >= ceil(x) and therefore never too narrow.
DC_ENTRY		= 4
DC_PAGE_BYTES		= DC_BANDS*DC_ENTRY
; Empty marker: xmin = 240, xmax = -32768.  After the clear's clamp of xmin to
; 0 the right edge is -32767, which is below the left edge, so the band skips
; itself -- no separate valid bit and no extra test in either loop.
DC_EMPTY		= $00f08000

TREX_VERTICES		= 1376
TREX_NORMALS		= 3610

TREX_PRIMITIVES		= 2724

; 2048 buckets rather than 1024: with the shift below the sequence maximum
; is 250,002, which would leave only 4.5 % headroom in a 1024-entry table.
; Saturation degrades silently -- it just stops sorting -- so the table is
; sized for a camera that can move well past the opening shot.
OT_LENGTH		= 2048
; Bucket = average-Z key >> OT_KEY_SHIFT.  The key is the sum of three
; camera-space z values, so it scales with the object distance.  The shift has
; to cover the whole choreography, which opens at z=62000 and ends at z=3100:
; the key runs 174994..247367 in the opening frame and 9312..82392 in the close
; shots.  A shift of 5 caps at 32736 and put EVERY triangle of frames 0..125
; into the last bucket -- one bucket, no depth sorting at all, so the mesh was
; drawn in fixed O3D order and the head's self-occlusion came out wrong until
; the object had come close enough for the keys to drop back in range.  That
; was the visible "the T-Rex walks through a curtain" transition around frame
; 130.  A shift of 8 caps at 262143, above the sequence maximum, and still
; spreads the model's own depth extent over about 285 buckets at both ends of
; the run -- the spread is the mesh depth, not the distance, so it stays
; roughly constant.  Anything that moves the camera further out than the
; opening shot has to raise this again.
OT_KEY_SHIFT		= 8
; Twenty-six longwords: command|shade, flat colour/page token, OT key,
; native texture page, then the twenty-two span/level fields copied verbatim
; from the validated record.  Textured packets use word 1's high word for the
; byte offset into the page-pointer tables; its low word remains zero so the
; force-flat diagnostic still recognises them as texture packets.
; No screen coordinates: the record is the rasterizer's entire geometric
; input.  The stride here MUST match what build_gpu_shadow_packets actually
; writes -- a builder/stride mismatch shears every packet after the first
; into garbage, which is how the last such bug announced itself.
; Longwords 0-25 are the built packet; longwords 26-31 are the RESOLVE SLOTS
; the per-frame packet resolve pass fills before the OT walk (3.9c): span
; entry, texture base, tint base/flat colour, bank stride, shade, spare.
GPU_PACKET_WORDS	= 32
GPU_PACKET_RESOLVE	= 26*4
GPU_PACKET_BYTES	= GPU_PACKET_WORDS*4
GPU_OT_NODE_WORDS	= 2
GPU_OT_NODE_BYTES	= GPU_OT_NODE_WORDS*4
FRAMEBUFFER_BPP		= 2
; The render target is a 240x224 window inside a 256-pixel screen buffer, so
; a row advances by the screen's stride, not by its own width.
FRAMEBUFFER_STRIDE	= VIDEO_SCREEN_WIDTH*FRAMEBUFFER_BPP
FRAMEBUFFER_BYTES	= SCREEN_WIDTH*SCREEN_HEIGHT*FRAMEBUFFER_BPP
TIM_PAGE_COUNT		= 6
TIM_CLUT_ENTRIES	= 256
TIM_CLUT_DATA_OFFSET	= 20
TIM_PIXEL_DATA_OFFSET	= 544
TIM_FALCON_CLUT_PAGE_BYTES	= TIM_CLUT_ENTRIES*4
TIM_FALCON_OPAQUE_CLUT_PAGE_BYTES	= TIM_CLUT_ENTRIES*2
; Host-only packet hint.  It occupies a spare bit below the GP0 command byte,
; so the DSP span record and the 26-long host packet stride stay unchanged.
; The command parser masks the high byte exactly as before.
OPAQUE_PACKET_BIT	= $00800000

; -----------------------------------------------------------------------------
; Flat shading
;
; The DSP returns a per-triangle light level; the rasterizer turns it into a
; colour by choosing between SHADE_LEVELS preshaded copies of each texture
; page's CLUT.  Modulating every texel with the level instead would put three
; multiplies into the innermost pixel loop, which is the last place this
; renderer can afford them - the preshaded banks make shading free per pixel
; and cost one pointer addition per triangle.
;
; The price is memory: six pages * 64 banks * 256 longwords = 384 KiB for the
; flag table, plus the qualified-opaque path's parallel 192-KiB word table.
; That is still far below expanding all indexed texture pages per shade/tint
; bank, and keeps both pixel loops to one prepared colour lookup.
; -----------------------------------------------------------------------------
SHADE_LEVELS		= 16
SHADE_MAX		= SHADE_LEVELS-1
; Colour classes of the illumination itself.  The DSP sends tint<<4|level and
; each preshaded bank carries that cell's own light colour, so a face lit by
; the white lights stays neutral while one under the pink key light goes warm
; -- without a single extra instruction in the pixel loop.
SHADE_TINTS		= 4
CLUT_BANK_COUNT		= SHADE_LEVELS*SHADE_TINTS
; Denominator of the shade_ramp_table entries.  Six bits rather than four: the
; table now carries a separate factor per colour channel, and its dark end sits
; at 21/64 and 13/64, which four bits cannot resolve.
SHADE_RAMP_SHIFT	= 6
; All SHADE_LEVELS banks of one texture page, indexed by page.
TIM_FALCON_CLUT_BANK_BYTES	= TIM_FALCON_CLUT_PAGE_BYTES*CLUT_BANK_COUNT
TIM_FALCON_OPAQUE_CLUT_BANK_BYTES = TIM_FALCON_OPAQUE_CLUT_PAGE_BYTES*CLUT_BANK_COUNT
; Bit position of the shade level inside a GPU packet's command longword.  The
; PS1 GP0 command carries its base colour in the same low 24 bits.
SHADE_PACKET_MASK	= $000000ff
; Log2 distance between two preshaded CLUT banks of one page.  The
; flag-bearing table advances by 1,024 bytes and the qualified-opaque word
; table by 512.  Keeping the shift rather than the byte stride lets the row
; loop replace a signed multiply with one register-count shift.
RASTER_LVL_SHIFT_LONG	= 10
RASTER_LVL_SHIFT_WORD	= 9
; -----------------------------------------------------------------------------
; Videl presentation: 256x224 true colour, programmed directly
;
; The XBIOS modes this replaced ($0024 = 320x200 RGB/TV, $0114 = 320x240 VGA)
; are the only 16-bit modes TOS offers, and neither is 224 lines tall: the
; RGB one scanned just 200 of the 224 rendered lines, so a quarter of the
; render target was cropped away on a TV.  The register sets below are the
; ones F030Arcade's snowbros port uses (games/snowbros/src/atari.s), where
; they present a 256x224 arcade framebuffer 1:1 on both monitor types.  They
; were generated by Screenspain (Chris/AURA & Scandion/Mugwumps) against a
; real Falcon and are carried over verbatim, including the RGB set's
; documented advantage over a hand-derived 32 MHz timing, which showed on
; hardware as two mirrored ~64-pixel columns at the right edge.
;
; Register meanings and formulas: MiKRO's "Videl in practice".  Each pair is
; packed into one long (high word = even address):
;   $8282 = HHT | HBB     $8286 = HBE | HDB     $828a = HDE | HSS
;   $82a2 = VFT | VBB     $82a6 = VBE | VDB     $82aa = VDE | VSS
; with HDB = HBE - 33 (true colour at 4 cycles/pixel, divider 4:
; (64+16*4)/4+1) and HDE = HBB (true-colour HDE offset is 0).  Vertical
; timings count half-lines, so the 224 visible lines occupy (VDE-VDB)/2
; raster lines and the remaining half-lines split between the top (VBE) and
; bottom (VFT-VBB) borders.
;
; Nothing here goes through TOS: the mode, the line width and the screen base
; are all register writes, TOS's own idea of the video mode is never
; disturbed, and gpu_close puts the saved registers back -- which is why the
; desktop now returns at its original resolution instead of the demo's.
; -----------------------------------------------------------------------------
VIDEO_SCREEN_STRIDE	= VIDEO_SCREEN_WIDTH*FRAMEBUFFER_BPP
; True colour is one word per pixel, so the visible line width in $ffff8210 is
; the pixel count, and $ffff820e adds no margin words on top of it.
VIDEO_LINE_WIDTH	= VIDEO_SCREEN_WIDTH
VIDEO_LINE_OFFSET	= 0
; Centre the render window in the displayed area.  Y works out to 0 -- the
; render target is exactly as tall as the mode -- but stays derived so a
; letterboxed variant only has to change VIDEO_SCREEN_HEIGHT.
VIDEO_X_OFFSET		= (VIDEO_SCREEN_WIDTH-SCREEN_WIDTH)/2
VIDEO_Y_OFFSET		= (VIDEO_SCREEN_HEIGHT-SCREEN_HEIGHT)/2
RENDER_WINDOW_OFFSET	= (VIDEO_Y_OFFSET*VIDEO_SCREEN_STRIDE)+(VIDEO_X_OFFSET*FRAMEBUFFER_BPP)

; -----------------------------------------------------------------------------
; Frame-rate overlay (-DTREX_FPS)
;
; Fixed NN.NN, zero padded: "02.07", "09.11", "10.60".  Both halves are always
; two digits and the point never moves, so the field cannot shift sideways as
; the rate crosses 10 -- blanking the leading zero instead would make the whole
; number jump every time it did.  Two fraction digits are what make the readout
; useful at all here: the full-mesh renderer is around two fps in the recorded
; Hatari runs, so an integer field would sit on "02" and hide every variation
; worth watching.  Physical-Falcon timing is still unmeasured.
;
; Geometry is in render-window pixels: the field sits at the top-left of the
; 240x224 target, so FPS_X/FPS_Y are relative to render_base and a row step is
; VIDEO_SCREEN_STRIDE, not the field's own width.
;
; Drawn 1:1, so the whole field is 30x7 pixels.  Those 256 mode pixels are wide
; ones (see the presentation notes above), so each glyph displays about 6.25x7
; square-equivalent -- small, and on a 15 kHz TV it will be near the limit of
; what is readable.  FPS_SCALE carries the 1:1 through the derived geometry
; below (field size, cell advance, row step); doubling it also needs the
; companion MOVE.Ws in gpu_draw_fps's inner loop, which is written for 1:1.
FPS_X			= 2
FPS_Y			= 2
FPS_GLYPH_COLS		= 5
FPS_GLYPH_ROWS		= 7
FPS_SCALE		= 1
; One blank source column between cells, scaled with everything else.
FPS_CELL_ADVANCE	= (FPS_GLYPH_COLS+1)*FPS_SCALE*FRAMEBUFFER_BPP
; Two digits, the point, two more: five cells, always all five drawn.
FPS_TEXT_CHARS		= 5
FPS_FIELD_WIDTH		= FPS_TEXT_CHARS*(FPS_GLYPH_COLS+1)*FPS_SCALE
FPS_FIELD_ROWS		= FPS_GLYPH_ROWS*FPS_SCALE
; Falcon RGB555X: R bits 11..15, G bits 6..10, B bits 0..4, bit 5 unused.  Full
; white is $ffdf and not $ffff -- bit 5 is the one gpu_prepare_texture_clut
; never sets, so the overlay stays inside the pixel format the renderer emits.
; The two differ by the green LSB alone and are indistinguishable on screen.
FPS_WHITE		= $ffdf
; Font cell index past the ten digits.
FPS_GLYPH_DOT		= 10
; fps*100, so the value carries its own two fraction digits.  20000 = 200 Hz
; tick * 100.  Clamped to 9999 (99.99) because the field holds four digits.
FPS_SCALED_NUMERATOR	= 20000
FPS_MAX_CENTI		= 9999

; Vertices closer than this are flagged by the DSP and their triangles are
; dropped.  With focal 160 anything nearer produces screen coordinates far
; outside the 240x224 target anyway.
NEAR_PLANE		= 64
; Focal length and object distance are tuned together.  Both up means the same
; on-screen size with a flatter, more telephoto-like perspective; the depth
; ratio across the mesh drops from 5.28:1 at 2500/160 to 2.22:1 here.  At 275
; of the 300 pixels the render target was wide before the 256-pixel Videl
; mode, the widest rotation kept a 12-pixel margin.  Unused since the TANM
; path took over the projection; kept for protocol diagnostics.
PROJECTION_FOCAL	= 363
; Legacy fallback-matrix count.  The active path uses the extracted TANM
; matrices below; the table remains available for protocol diagnostics.
ANIMATION_MATRICES	= 32

; Extracted Demo One TANM v2 choreography.  The PS1 source renders at
; 640x240 with projection distance 1000.
;
; 933 = 1000 * 224/240 keeps the original's vertical framing in the 224-line
; render target.  The close shots fill the screen at this setting; the object
; translation comes from the choreography record, so pull the whole sequence
; back there rather than reintroducing an unwanted axis difference.
;
; X carries one, and only one, deliberate difference: the 240 pixels it
; projects into are displayed as wide as 300 of the old square ones, so the
; focal length is pre-squeezed by the same 0.8 the render window shrank by
; (933 * 240/300 = 746.4).  That is not an aspect correction -- it is the
; inverse of the display's own horizontal stretch, and it leaves the picture
; geometrically identical to the 300x224-in-320x240 version.  Any measurement
; of the axis ratio must therefore be taken on screen, not in the buffer: in
; buffer coordinates the model is now 1.25x taller than wide.
;
; The two axes were equal while the mode had square pixels, for the reason
; below, and dropping either the 0.8 here or the wide pixels puts them back
; in lockstep.  Measured on frame 24 in the old square-pixel mode, the model's
; height/width ratio was 2.18 with equal axes, 3.27 at the earlier 625/933
; and 4.49 with the PS1's own 469/933 numbers.  The PS1 framebuffer figures
; cannot be carried over directly -- its 640x240 pixels are half as wide as
; tall, and that squeeze is undone by the display, not by the projection.
PS1_PROJECTION_X	= 746
PS1_PROJECTION_Y	= 933
; Deliberate deviation, not a source value: the source's own 2000 is
; faithfully reproduced by leaving the per-frame translation untouched, but
; on request the whole choreography sits further from the camera -- opening
; shot and ending included, not only the closest stretch a per-frame floor
; would target.  Chosen by direct comparison in Hatari against 2000, 5000
; and 7000.
PS1_VIEWPOINT_Z		= 9000
TANM_FRAME_COUNT	= 274
TANM_CHOREOGRAPHY_OFFSET	= 47104
TANM_CHOREOGRAPHY_BYTES	= 64
TANM_GAIT_DATA_OFFSET	= 64640
TANM_GAIT_POSE_BYTES	= 8256
TANM_CHOREO_TRANSLATION	= 20
TANM_CHOREO_WEIGHTS	= 32
TANM_CHOREO_AUDIO_VOLUME	= 50
TANM_CHOREO_FLAGS	= 52
TANM_CHOREO_GAIT_INDEX	= 54
TANM_CHOREO_ACTIVE_MASK	= 56
TANM_TARGET_5_DELTA	= 34528
TANM_TARGET_6_DELTA	= 35412
TANM_TARGET_7_DELTA	= 38756
TANM_TARGET_8_DELTA	= 38828
TMD_VERTEX_DATA_OFFSET	= $125d8
; One displayed frame, and exactly that: both monitor types now scan the same
; 256x224 true-colour buffer, so there is no larger-of-the-two allowance left
; (153,600 bytes down to 114,688, twice over for the two buffers).
SCREEN_BUFFER_BYTES	= VIDEO_SCREEN_WIDTH*VIDEO_SCREEN_HEIGHT*FRAMEBUFFER_BPP
SCREEN_ALIGN		= 256

DSP_STATE_CLOSED	= 0
DSP_STATE_OPEN		= 1

; The X layout ends at X:$3D4B: the projection overlays the camera array in
; place, and the freed words carry the resident UV pairs plus the widened
; span-record output buffer.
DSP_X_RESERVE		= 15872
; Two resident arrays share Y: the packed triangle index list (5448 words) and
; the face normals (8172), running $09C0..$3EF3.  Neither can start lower: the
; Falcon maps Y:$0200 upwards onto the same physical words as external P
; memory, so anything below the program's end (P:$06BB today -- check the DSP
; program after edits; limit P:$09BF) would overwrite the program itself. See
; the Y-memory notes in TREX/dsp/trex_dsp.asm.  The Falcon reports 16127 free
; Y words.
DSP_Y_RESERVE		= 16120
DSP_ABILITY		= 0
DSP_LOAD_BUFFER_BYTES	= 8192

DSP_CMD_LOAD_VERTICES	= 1
DSP_CMD_SET_FRAME	= 2
DSP_CMD_GET_VERTICES	= 3
DSP_CMD_BUILD_TRIANGLES	= 4
DSP_CMD_GET_STATUS	= 5
DSP_CMD_GET_TRIANGLES	= 6
DSP_CMD_LOAD_NORMALS	= 7
DSP_CMD_LOAD_TRIANGLES	= 8
DSP_CMD_LOAD_UVS	= 10
DSP_CMD_SET_ANIMATED_FRAME	= 12
DSP_CMD_LOAD_ANIMATION_GAIT	= 13
DSP_CMD_APPLY_ANIMATION_TARGET	= 14
DSP_CMD_FINISH_ANIMATED_FRAME	= 15

DSP_ACK_LOAD		= $00700002
DSP_ACK_FRAME		= $00700003
DSP_ACK_VERTICES	= $00700004
DSP_ACK_TRIANGLES	= $00700005
DSP_ACK_GET_TRIANGLES	= $00700008
DSP_ACK_NORMALS		= $00700009
DSP_ACK_LOAD_TRIANGLES	= $0070000a
DSP_ACK_LOAD_UVS	= $0070000b
DSP_ACK_ANIMATION_BEGIN	= $0070000c
DSP_ACK_ANIMATION_GAIT	= $0070000d
DSP_ACK_ANIMATION_TARGET	= $0070000e
DSP_CULLED_MARKER	= $007fffff

; Falcon DSP host port, addressed exactly as TOS's own XBIOS routines do.
; RXDF = a word from the DSP is waiting, TXDE = the DSP has taken the last word
; and the port is free again.  See dsp_block_handshake for why this code polls
; them itself instead of leaving the block transfer to Dsp_BlkUnpacked.
DSP_HOST_ISR		= $ffffa202
DSP_HOST_DATA		= $ffffa204
DSP_HOST_ISR_RXDF	= 0
DSP_HOST_ISR_TXDE	= 1

; Packing of the resident triangle index list: i0 in bits 0..11 and i1 in bits
; 12..23 of the first word, i2 in bits 0..11 of the second.  Must match
; TRI_INDEX_BITS in TREX/dsp/trex_dsp.asm.
DSP_TRI_INDEX_BITS	= 12
DSP_TRI_INDEX_MASK	= $00000fff

; Bit 23 of the DSP's packed word A -- the spare top bit of its twelve-bit v1
; field, free because vertex indices stay below 1,376.  Carries the occluder
; qualification to the DSP occlusion stage; the DSP masks every vertex field
; to eleven bits (TRI_VERTEX_MASK there) so the flag never reaches a lookup.
DSP_TRI_OCCLUDER_BIT	= $00800000


; The survivor record arrives PACKED, eighteen words (layout mirrored from
; SPAN_RECORD_WORDS in trex_dsp.asm):
;
;   w0   slot_mid<<14 | slot_top<<12 | mid<<11 | shade<<5 | chunk-local index
;        with shade = tint<<4 | brightness level
;   w1   average-z / OT key
;   w2   rows_up<<12 | sy0(12, signed)
;   w3   sx0(12, signed)<<12 | rows_low
;   w4   sx1(12, signed)
;   w5..w13  sl_long, sl_up, sl_low, du_dx, dv_dx,
;            dul_up, dvl_up, dul_low, dvl_low
;   w14  lvl_top<<12 | lvl_mid   (sorted corner levels, Q4.8, non-negative)
;   w15..w17  dlvl_dx, dlvl_up, dlvl_low  (level gradients, Q4.8 signed)
;
; The chunk unpack expands this into the host record's 22-field span-setup
; block: the validated seventeen (sy0, rows_up, rows_low, mid, xl0,
; sl_long, sl_up, sl_low, x1r, du_dx, dv_dx, dul_up, dvl_up, dul_low,
; dvl_low, uv0pack, uv1pack -- sign-extended once, UV start packs rebuilt
; from gpu_texture_meta_buffer via the slot ids) followed by the five
; Gouraud level fields (lvl_top, lvl_mid, dlvl_dx, dlvl_up, dlvl_low).
; The level STARTS travel the wire because they are lighting results the
; host cannot rebuild.
DSP_SPAN_RECORD_WORDS	= 18

DSP_UPLOAD_WORDS	= 2+(TREX_VERTICES*3)
; Animated frames use acknowledged sub-transactions so no source block crosses
; a 64-KiB host-address boundary in TOS 4.02 Dsp_BlkUnpacked.  The largest is
; one bounded gait/target chunk: command/metadata plus three sign-extended
; native words per XYZ16 delta.  Consuming raw words promptly is more robust
; than making the synchronous driver wait through a 64-shift DSP unpacker.
DSP_ANIMATION_GAIT_CHUNK	= 512
DSP_ANIMATION_WORDS	= 4+(DSP_ANIMATION_GAIT_CHUNK*3)
DSP_TX_BUFFER_WORDS	= DSP_ANIMATION_WORDS
; One unit object-space face normal per triangle.
; The complete PS1 corner-normal table from the TMD, Q12 to 1.23-converted
; at upload.  Its size is a property of the source TMD.
TREX_TMD_NORMALS	= 3610
; File offset of the TMD normal block (object-table normal_top $150CC plus
; the 12-byte header), hard-coded like TMD_VERTEX_DATA_OFFSET above.
TMD_NORMAL_DATA_OFFSET	= $150d8
DSP_NORMAL_UPLOAD_WORDS	= 2+(TREX_TMD_NORMALS*3)
DSP_LIGHT_COUNT		= 3
; Six vectors per frame (each light scaled for red and for green) plus the two
; ambient words.
DSP_LIGHT_WORDS		= (DSP_LIGHT_COUNT*6)+2
DSP_FRAME_WORDS		= 1+9+3+3+4+DSP_LIGHT_WORDS
DSP_VERTEX_OUTPUT_WORDS	= 2+(TREX_VERTICES*4)
DSP_TRIANGLE_INPUT_WORDS	= 2+(TREX_PRIMITIVES*4)
; Culled list: (source-index, average-z, shade) plus the seventeen span-setup
; fields per survivor, densely packed -- culled triangles occupy nothing.
; Sized for the worst case where nothing is culled.  The span fields are
; sign-extended once during unpack, so every later consumer reads ready
; 32-bit values.
DSP_TRIANGLE_OUTPUT_WORDS	= 2+(TREX_PRIMITIVES*25)
DSP_TRIANGLE_CHUNK	= 32
; The one-off resident index upload: command, count, then two packed words per
; triangle.  This replaces 43 chunks * 259 words of identical data per frame.
DSP_TRIANGLE_LOAD_WORDS	= 2+(TREX_PRIMITIVES*3)
; A chunk command is now command, count and global base -- nothing else.
; Chunk command buffer capacity: three command words plus the chunk's two
; packed UV words per triangle.  The actual send length is computed per call
; from the chunk's real count.
DSP_TRIANGLE_CHUNK_TX_WORDS	= 3+(DSP_TRIANGLE_CHUNK*2)
; The one-off static UV upload: command, count, two packed words per triangle.
; Host-resident packed UV pairs, two longs per triangle: since Gouraud they
; are no longer uploaded in one block but shipped per BUILD chunk.

VAL_STATS_LONGS		= 26

	ifd	TREX_OCCL
; Occlusion measurement build (-DTREX_OCCL, target trex_occl.tos).  Everything
; guarded by this flag exists ONLY in that binary: it adds a store per written
; pixel and over 370 KB of BSS, so its text and data layout differ from the
; shipping builds and NO timing may ever be quoted from it (OPTIMIZATION.md
; 2.4).  That is also why these are plain constants rather than the equal-size
; dc.l pairs the layout-identical TREX_RUN switches use -- layout equality is
; worthless here, hard separation is not.
;
; The per-frame dump format written by occl_write_frame_dump: header, one
; record per drawn packet, the owner-id bitmap, then the trailer.
OCCL_MAGIC		= $4f434331	; 'OCC1'
OCCL_TRAILER		= $4f434345	; 'OCCE'
OCCL_HEADER_BYTES	= 64
OCCL_RECORD_BYTES	= 48
	endc

	ifd	TREX_PREPASS
; Occlusion prepass measurement build (-DTREX_PREPASS, target trex_prepass.tos,
; GEMDOS name TREX_PRE.TOS).  The DSP classifies the complete geometry,
; establishes an exact near-to-far bucket order, then runs the conservative
; 4x4-cell coverage test and writes the global BUILD kill bitmap.  The
; correctness gate is byte-identical framebuffer output plus a lower packet
; count; an order overflow leaves the bitmap clear and the frame unculled.
;
; Command 10 is the one dispatcher leaf that is free on the DSP side -- 9 and
; 11 are silent aliases of 1 and 3, so this number is not a choice.  It shares
; its value with the retired DSP_CMD_LOAD_UVS above, which no longer has a
; handler.
;
; Wire format, always exactly two words each way:
;   host -> DSP : 10, mode
;   DSP  -> host: DSP_ACK_PREPASS, N_s        (N_s = $ffffff on overflow)
; Mode 3 is accepted by the DSP as a second run-now selector for legacy
; measurement binaries, but returns only the fixed two-word acknowledgement.
;
; Modes: 0 = disarm, 1 = arm every following FINISH (sticky), 2/3 = compute
; now.  Every mode returns the same fixed two-word acknowledgement.
DSP_CMD_PREPASS		= 10
DSP_ACK_PREPASS		= $0070000f
PREPASS_MODE_DISARM	= 0
PREPASS_MODE_ARM	= 1
PREPASS_MODE_RUN	= 2
; N_s sentinel the DSP reports when the classification exceeded its 723-entry
; capacity.  The prepass then leaves its kill bitmap zeroed, so the frame is
; bit-identical to one without a prepass -- it is counted, not repaired.
PREPASS_OVERFLOW_MARK	= $00ffffff
; Entry packing, mirrored from the DSP side.  Bucket is 11 bits inside a
; 12-bit field; the mask is the full field so a stray bit 11 is caught rather
; than masked away.
; Magic plus seven counters, written next to render_stats.res.
PREPASS_STATS_LONGS	= 9
	endc

O3D_HEADER_BYTES	= 24
O3D_POINT_BYTES		= 12
O3D_NORMAL_BYTES	= 12
O3D_TEXTURE_WORDS	= 8
O3D_TEXTURE_BYTES	= O3D_TEXTURE_WORDS*2
; The same eight values are widened to longwords in gpu_texture_meta_buffer,
; so the in-memory record is twice the size of the O3D one.
GPU_TEXTURE_META_BYTES	= O3D_TEXTURE_WORDS*4
O3D_POLYGON_OFFSET	= O3D_HEADER_BYTES+(TREX_VERTICES*O3D_POINT_BYTES)+(TREX_NORMALS*O3D_NORMAL_BYTES)

; -----------------------------------------------------------------------------
; Program entry
; -----------------------------------------------------------------------------

	text

start
	move.l	sp,saved_sp

	; Supervisor mode for the whole run so the frame timers can read the
	; system clocks directly.
	clr.l	-(sp)
	move.w	#32,-(sp)
	trap	#1
	addq.l	#6,sp
	move.l	d0,saved_super

	bsr	trex_init
	bsr	trex_dummy_frame
	bsr	trex_shutdown

	move.l	saved_super,-(sp)
	move.w	#32,-(sp)
	trap	#1
	addq.l	#6,sp

	Pterm0

; -----------------------------------------------------------------------------
; High-level frame skeleton
; -----------------------------------------------------------------------------

trex_init
	movem.l	d0-d7/a0-a6,-(sp)

	Cconws	banner_text

	lea	trex_model_desc,a0
	bsr	lib_tmd_parse

	; TOS 4.02 advances only the low 16 address bits in Dsp_BlkUnpacked's
	; source walk.  Select a 64-KiB-aligned window from the overallocated
	; animation storage so every acknowledged sub-transaction stays wholly
	; inside one bank on both Hatari and a physical Falcon.
	lea	dsp_animation_tx_storage,a0
	move.l	a0,d0
	add.l	#$0000ffff,d0
	andi.l	#$ffff0000,d0
	move.l	d0,dsp_animation_tx_ptr

	bsr	lib_psyq_init
	bsr	dsp_open
	bsr	dsp_upload_mesh
	tst.l	lighting_enabled
	beq	.trex_init_unlit
	bsr	dsp_upload_face_normals
.trex_init_unlit
	bsr	dsp_build_triangle_stream
	bsr	dsp_upload_triangle_indices
	bsr	dsp_upload_uvs
	bsr	gpu_open
	bsr	lib_tim_upload_all

	; These are the state objects a real implementation would pass to the
	; Psy-Q/GTE and DSP backends.
	lea	camera_state,a0
	bsr	lib_gte_set_camera
	lea	object_state,a0
	bsr	lib_gte_set_object

	; Tell the DSP once, outside the frame loop, whether the FINISH-inline
	; prepass is armed.  Everything else this build does per frame depends
	; on prepass_arm alone; a DSP that was never armed and is never asked
	; runs no prepass at all.  This has to happen before the priming
	; dsp_set_frame in trex_dummy_frame, so arm 1 covers the very first
	; FINISH too.
	; Only with a DSP program actually running.  Every other DSP
	; transaction in this file is gated the same way (dsp_upload_mesh,
	; dsp_set_frame, dsp_finish_frame_wait); without the gate a missing or
	; failed trex_dsp.lod leaves dsp_block_handshake spinning on RXDF
	; forever, and the run produces no .res file at all instead of a result.
	ifd	TREX_PREPASS
	tst.l	dsp_program_loaded
	beq	.trex_init_no_prepass
	bsr	prepass_startup
.trex_init_no_prepass
	endc

	movem.l	(sp)+,d0-d7/a0-a6
	rts

trex_dummy_frame
	movem.l	d0-d7/a0-a6,-(sp)

	clr.l	frame_number
	clr.l	animation_frame

	; Zero the timing accumulators, then bracket the whole loop with both
	; system clocks.  stat_frames counts what actually ran.
	lea	stat_block,a0
	moveq	#0,d0
	moveq	#STAT_LONGS-1,d1
.clear_stats
	move.l	d0,(a0)+
	dbra	d1,.clear_stats

	move.l	$466.w,stat_vbl_start
	move.l	$4ba.w,stat_hz200_start

	; Prime the overlay's reference tick from the same clock read the run is
	; bracketed with.  Without this the first frame would subtract zero from
	; the boot-time tick and display the clamp, 9999.
	ifd	TREX_FPS
	move.l	$4ba.w,fps_last_tick
	endc

	; Prime the cross-frame pipeline: send frame 0's animation before the
	; first slot, so every iteration -- including the first -- begins by
	; collecting a FINISH ack.  The first collect simply waits the full
	; transform out; every later one finds it long since done.
	bsr	dsp_set_frame

	; Play the 274 extracted automatic-demo records until a key is pressed,
	; then hold on frame 273.  The original hands off to PS1 interactive
	; control there instead, but its own choreography already decelerates
	; rotation and translation to zero over frames 253-273 (see
	; extract_trex_animation.py's AUTOPLAY_LAST_FRAME handling), so the
	; automatic path is already at rest by the last frame -- holding it is
	; the faithful stand-in for a control handoff this port does not
	; implement, rather than the jump cut back to frame 0's distant opening
	; shot that wrapping produced.
	;
	; No loop counter in d7: build_gpu_shadow_packets, build_host_triangle_stream,
	; gpu_submit_ot and gpu_rasterize_ot all use d7 as their own counter and
	; leave it at -1.  That is what once turned this into a 65536-iteration
	; loop that never reached trex_shutdown.
.frame_loop
	bsr	lib_psyq_begin_frame
	bsr	dsp_begin_frame

	; GTE-like library stages (shadow counters only).
	bsr	lib_gte_set_rotation
	bsr	lib_gte_rot_trans_vertices
	bsr	lib_gte_light_vertices
	bsr	lib_gte_avsz3

	; PS1-style primitive path: create packets and sort them into an OT.
	; dsp_packets_begin first collects the FINISH ack of the animation sent
	; last slot -- its morph/transform/projection ran inside the previous
	; frame's rasterization window (cross-frame pipelining, roadmap 12).
	bsr	lib_gs_sort_object
	TimeMark	stat_mark_packets
	bsr	dsp_packets_begin
	TimeAdd	stat_mark_packets,stat_t_packets

	; The framebuffer clear runs while the DSP computes the first span
	; chunk: dsp_packets_begin has already launched it.
	TimeMark	stat_mark_clear
	bsr	gpu_clear_ot
	TimeAdd	stat_mark_clear,stat_t_clear

	TimeMark	stat_mark_packets
	bsr	dsp_packets_finish
	TimeAdd	stat_mark_packets,stat_t_packets

	; Frame N is fully unpacked and linked; hand the NEXT frame's animation
	; to the DSP before rasterizing, so its morph, transform and projection
	; run inside the rasterization window below instead of being waited on.
	; The advance runs here because dsp_set_frame reads animation_frame --
	; the counter leads the rendered frame by one from now on.
	addq.l	#1,animation_frame
	cmpi.l	#TANM_FRAME_COUNT,animation_frame
	bcs	.animation_advance_ready
	move.l	#TANM_FRAME_COUNT-1,animation_frame

	; Deliberate addition beyond the source: camera, rotation and the
	; targets-5..8 weights hold at frame 273 (above), but frames 46..273
	; already replay gait poses 14..45 on a 32-pose loop -- seven full
	; repeats plus a partial eighth ending at pose 17, read straight from
	; trex_animation.bin, not invented -- so continuing that exact loop here
	; keeps the walk going instead of freezing mid-stride.  The source has
	; no frame past 273 to compare this against.
	move.l	gait_hold_index,d0
	bne	.gait_hold_advance
	move.l	#17,d0			; frame 273's own gait index, continued from
.gait_hold_advance
	addq.l	#1,d0
	cmpi.l	#46,d0
	bcs	.gait_hold_ready
	move.l	#14,d0
.gait_hold_ready
	move.l	d0,gait_hold_index

	move.l	y_spin_index,d0
	addq.l	#1,d0
	cmpi.l	#Y_SPIN_STEPS,d0
	bcs	.z_spin_ready
	moveq	#0,d0
.z_spin_ready
	move.l	d0,y_spin_index
	; The prepass now stays armed through the synthetic hold as well.  The
	; one-shot disarm that used to fire here guarded against the former DSP
	; sweep, whose full-grid cell cursor visited all 3,360 mask cells per
	; survivor and overran the frame budget on the hold's right-edge poses;
	; the range-restricted sweep is bounded by each survivor's own screen
	; box and removes the overrun with the arm left on.
.animation_advance_ready
	TimeMark	stat_mark_setframe
	bsr	dsp_set_frame
	TimeAdd	stat_mark_setframe,stat_t_setframe
	bsr	gpu_submit_ot

	; Occlusion dump, before anything else touches the frame's state: the
	; packet buffer, the OT and the owner-id bitmap of the frame just drawn
	; are all still valid here, and gpu_present_frame has already latched
	; last_rendered_base for the swap.
	ifd	TREX_OCCL
	bsr	occl_write_frame_dump
	endc

	; Optional headless capture.  tools/fb2png.py turns fb.res into an image.
	; The data value selects any extracted choreography checkpoint without
	; changing code layout.  Frame 0 is the distant head-on opening shot.
	tst.l	framebuffer_dump_enabled
	beq	.no_framebuffer_dump
	move.l	framebuffer_dump_frame,d0
	cmp.l	frame_number,d0
	bne	.no_framebuffer_dump
	bsr	trex_write_framebuffer_debug
.no_framebuffer_dump

	bsr	lib_psyq_end_frame
	bsr	lib_psyq_vsync

	addq.l	#1,stat_frames
	addq.l	#1,frame_number

	; Close the clocks every frame, and flush the stats file with them while
	; stats_flush_enabled is set, so a run that is cut short by the emulator's
	; VBL budget still yields usable timings.
	move.l	$466.w,stat_vbl_end
	move.l	$4ba.w,stat_hz200_end
	tst.l	stats_flush_enabled
	beq	.no_stats_flush
	bsr	trex_write_render_stats
.no_stats_flush

	; Cconis returns non-zero once a key is waiting.  A headless run never
	; sees one and is bounded by Hatari's --run-vbls instead; render_stats.res
	; is flushed every frame, so its report stays valid either way.
	Cconis
	tst.w	d0
	beq	.frame_loop

	; Swallow the key so it does not land on the desktop after Pterm0.
	Cconin

	; One animation is still in flight for the frame that will never
	; render; collect its ack so the DSP is idle and in protocol sync
	; before trex_shutdown talks to it.
	bsr	dsp_finish_frame_wait

	movem.l	(sp)+,d0-d7/a0-a6
	rts

trex_shutdown
	movem.l	d0-d7/a0-a6,-(sp)

	ifd	TREX_RUN
	; Viewing builds intentionally perform no GEMDOS writes, including the
	; final diagnostic flush on a clean keypress exit.
	else
	bsr	trex_write_render_stats
	endc
	bsr	gpu_close
	bsr	dsp_close
	bsr	lib_psyq_shutdown

	movem.l	(sp)+,d0-d7/a0-a6
	rts

; Headless Hatari diagnostic: write the final renderer counters next to the
; executable so a long software-rasterizer run can be distinguished from an
; empty DSP stream without relying on a live screen capture.
; Dump the frame timers and renderer counters as 20 big-endian longwords.
; tools/decode_render_stats.py turns the file into a readable report.
trex_write_render_stats
	lea	render_stats_buffer,a0
	move.l	stat_frames,(a0)+
	move.l	stat_vbl_start,(a0)+
	move.l	stat_vbl_end,(a0)+
	move.l	stat_hz200_start,(a0)+
	move.l	stat_hz200_end,(a0)+
	move.l	stat_t_setframe,(a0)+
	move.l	stat_t_packets,(a0)+
	move.l	stat_t_clear,(a0)+
	move.l	stat_t_otinsert,(a0)+
	move.l	stat_t_raster,(a0)+
	move.l	stat_t_present,(a0)+
	move.l	raster_pixel_count,(a0)+
	move.l	gpu_ot_node_count,(a0)+
	move.l	dsp_packet_count_shadow,(a0)+
	move.l	ot_primitive_count,(a0)+
	move.l	dsp_triangle_stream_ready,(a0)+
	move.l	dsp_state,(a0)+
	move.l	video_mode_active,(a0)+
	move.l	video_monitor_type_shadow,(a0)+
	move.l	dsp_x_available,(a0)+
	move.l	dsp_y_available,(a0)+
	move.l	dsp_normals_loaded,(a0)+
	ifd	TREX_PREPASS
	move.l	stat_t_prepass,(a0)+		; field 22, prepass build only
	endc
	move.l	dc_clear_longwords,(a0)+
	; last field: delta-clear area


	Fcreate	render_stats_path,#0
	tst.l	d0
	bmi	.trex_stats_done
	move.w	d0,d7
	Fwrite	d7,#(RENDER_STATS_LONGS*4),render_stats_buffer
	Fclose	d7
.trex_stats_done
	; Span-record validation report, rewritten with the render stats so an
	; interrupted run still yields a verdict.  Only when the validation ran:
	; without it the counters are all zero and the file said nothing, yet it
	; cost a second GEMDOS create/write/close per frame.
	tst.l	span_validate_enabled
	beq	.trex_val_done
	lea	val_stats_buffer,a0
	move.l	#$56414c30,(a0)+		; 'VAL0'
	move.l	val_records,(a0)+
	move.l	val_mismatch_total,(a0)+
	move.l	val_first_captured,(a0)+
	move.l	val_first_frame,(a0)+
	move.l	val_first_tri,(a0)+
	move.l	val_first_field,(a0)+
	move.l	val_first_host,(a0)+
	move.l	val_first_dsp,(a0)+
	lea	val_field_counts,a1
	moveq	#16,d0
.copy_val_counts
	move.l	(a1)+,(a0)+
	dbra	d0,.copy_val_counts
	Fcreate	val_stats_path,#0
	tst.l	d0
	bmi	.trex_val_done
	move.w	d0,d7
	Fwrite	d7,#(VAL_STATS_LONGS*4),val_stats_buffer
	Fclose	d7
.trex_val_done
	; Prepass campaign counters, in their own file for the same reason
	; val_stats.res exists: render_stats.res is a positional format with a
	; decoder and a baseline archive behind it, and a measurement-only
	; build has no business widening it by nine longwords.
	ifd	TREX_PREPASS
	lea	prepass_stats_buffer,a0
	move.l	#$50524530,(a0)+		; 'PRE0'
	move.l	stat_frames,(a0)+
	move.l	stat_t_prepass,(a0)+
	move.l	prepass_run_count,(a0)+
	move.l	prepass_surv_last,(a0)+
	move.l	prepass_surv_max,(a0)+
	move.l	prepass_overflow_count,(a0)+
	move.l	prepass_arm,(a0)+
	; Protocol failures MUST be visible.  A wrong ack or a lost word makes
	; prepass_send_mode return early, so the timed bracket then contains
	; four wire words and nothing else -- t_prepass collapses towards zero
	; and the campaign would report "the prepass costs nothing measurable".
	; This counter is the only thing that separates that from the real
	; result, so it is written out and the decoder gates on it.
	move.l	prepass_fail_count,(a0)+
	Fcreate	prepass_stats_path,#0
	tst.l	d0
	bmi	.trex_prepass_done
	move.w	d0,d7
	Fwrite	d7,#(PREPASS_STATS_LONGS*4),prepass_stats_buffer
	Fclose	d7
.trex_prepass_done
	endc
	rts

; Write the last rendered frame to fb.res for headless inspection.  Reads
; last_rendered_base, which is latched before the Videl flip -- see section
; 6.5 of OPTIMIZATION.md for the bug that latch prevents.
trex_write_framebuffer_debug
	Fcreate	framebuffer_debug_path,#0
	tst.l	d0
	bmi	.trex_fb_debug_done
	move.w	d0,d7
	; The render target is a window in a wider buffer now, so the dump walks
	; rows instead of writing one block.  tools/fb2png.py still sees exactly
	; SCREEN_WIDTH*SCREEN_HEIGHT pixels.
	move.l	last_rendered_base,a0
	move.w	#SCREEN_HEIGHT-1,d6
.trex_fb_debug_row
	movem.l	d6-d7/a0,-(sp)
	Fwrite	d7,#(SCREEN_WIDTH*2),(a0)
	movem.l	(sp)+,d6-d7/a0
	adda.l	#VIDEO_SCREEN_STRIDE,a0
	dbra	d6,.trex_fb_debug_row
	Fclose	d7
.trex_fb_debug_done
	rts

; -----------------------------------------------------------------------------
; Dummy library layer
;
; Register convention for these placeholders:
;   A0 = object/state pointer when applicable
;   D0 = scalar/count when applicable
;   D1 = secondary scalar
;
; Each routine records its invocation.  No external Psy-Q library is required.
; -----------------------------------------------------------------------------

lib_psyq_init
	addq.l	#1,lib_call_count
	move.l	#1,lib_state
	rts

lib_psyq_shutdown
	addq.l	#1,lib_call_count
	clr.l	lib_state
	rts

lib_psyq_begin_frame
	addq.l	#1,lib_call_count
	move.l	frame_number,last_lib_frame
	rts

lib_psyq_end_frame
	addq.l	#1,lib_call_count
	rts

lib_psyq_vsync
	addq.l	#1,lib_call_count
	; Real version: Vsync or a display-list synchronization call.
	rts

lib_tmd_parse
	addq.l	#1,lib_call_count
	move.l	(a0),tmd_id_shadow
	move.l	8(a0),runtime_vertex_count
	move.l	12(a0),runtime_normal_count
	move.l	16(a0),runtime_primitive_count
	move.l	20(a0),tmd_ptr_shadow
	move.l	24(a0),tmd_length_shadow
	move.l	28(a0),texture_table_ptr_shadow
	rts

lib_tim_upload_all
	addq.l	#1,lib_call_count
	clr.l	texture_page_count_shadow
	move.l	texture_table_ptr_shadow,a0
	move.l	(a0)+,texture_ptr_shadow
	move.l	(a0)+,texture_length_shadow
	bsr	gpu_upload_tim_shadow
	move.l	(a0)+,texture_ptr_shadow
	move.l	(a0)+,texture_length_shadow
	bsr	gpu_upload_tim_shadow
	move.l	(a0)+,texture_ptr_shadow
	move.l	(a0)+,texture_length_shadow
	bsr	gpu_upload_tim_shadow
	move.l	(a0)+,texture_ptr_shadow
	move.l	(a0)+,texture_length_shadow
	bsr	gpu_upload_tim_shadow
	move.l	(a0)+,texture_ptr_shadow
	move.l	(a0)+,texture_length_shadow
	bsr	gpu_upload_tim_shadow
	move.l	(a0)+,texture_ptr_shadow
	move.l	(a0)+,texture_length_shadow
	bsr	gpu_upload_tim_shadow
	rts

lib_gte_set_camera
	addq.l	#1,lib_call_count
	move.l	a0,camera_ptr_shadow
	rts

lib_gte_set_object
	addq.l	#1,lib_call_count
	move.l	a0,object_ptr_shadow
	rts

lib_gte_set_rotation
	addq.l	#1,lib_call_count
	rts

lib_gte_rot_trans_vertices
	addq.l	#1,lib_call_count
	move.l	runtime_vertex_count,dsp_vertex_count_shadow
	; Real version: submit matrix/vector work to the DSP or execute a local
	; M68030 fixed-point fallback.
	rts

lib_gte_light_vertices
	addq.l	#1,lib_call_count
	move.l	runtime_normal_count,dsp_normal_count_shadow
	; Per-vertex lighting has no host-side stage: the DSP shades per face
	; inside the culling pass, using the normals dsp_upload_face_normals sent
	; once.  This placeholder is where per-vertex Gouraud colours would be
	; requested if the O3D ever carried three normal indices per polygon.
	rts

lib_gte_avsz3
	addq.l	#1,lib_call_count
	; Real version: average the three projected Z values per triangle.
	rts

lib_gs_sort_object
	addq.l	#1,lib_call_count
	move.l	runtime_primitive_count,ot_primitive_count
	; Real version: insert primitive packets into an Ordering Table by Z.
	rts

; -----------------------------------------------------------------------------
; Falcon DSP interface
; -----------------------------------------------------------------------------

dsp_open
	addq.l	#1,dsp_call_count

	; Lock the DSP before reserving memory or loading the program.  If this
	; target is run on a non-Falcon emulator, the error path leaves the local
	; renderer shadows usable.
	Dsp_Lock
	tst.w	d0
	bne	.dsp_open_failed
	move.l	#1,dsp_lock_state

	Dsp_Available	dsp_x_available,dsp_y_available
	Dsp_Reserve	#DSP_X_RESERVE,#DSP_Y_RESERVE
	tst.w	d0
	bne	.dsp_unlock_failed

	; Dsp_LoadProg converts the ASCII LOD and starts the resident DSP
	; program.  The scratch buffer must not cross a 64-KiB boundary (see
	; its definition), so the call gets the aligned window inside the
	; overallocated block -- 8 KiB used, 64 KiB alignment, same defence as
	; the animation transfer buffer.
	lea	dsp_load_buffer,a0
	move.l	a0,d0
	add.l	#$0000ffff,d0
	andi.l	#$ffff0000,d0
	move.l	d0,-(sp)
	move.w	#DSP_ABILITY,-(sp)
	pea	trex_dsp_lod_path
	move	#108,-(sp)
	trap	#14
	lea	12(sp),sp
	tst.w	d0
	bne	.dsp_unlock_failed

	move.l	#DSP_STATE_OPEN,dsp_state
	move.l	#1,dsp_program_loaded
	rts

.dsp_unlock_failed
	Dsp_Unlock
	clr.l	dsp_lock_state
.dsp_open_failed
	move.l	#DSP_STATE_CLOSED,dsp_state
	clr.l	dsp_program_loaded
	clr.l	dsp_mesh_loaded
	rts

dsp_close
	addq.l	#1,dsp_call_count
	tst.l	dsp_lock_state
	beq	.dsp_close_no_lock
	Dsp_Unlock
	clr.l	dsp_lock_state
.dsp_close_no_lock
	move.l	#DSP_STATE_CLOSED,dsp_state
	clr.l	dsp_program_loaded
	clr.l	dsp_mesh_loaded
	rts

dsp_begin_frame
	addq.l	#1,dsp_call_count
	move.l	frame_number,dsp_frame_shadow
	rts

dsp_set_frame
	addq.l	#1,dsp_call_count
	tst.l	dsp_mesh_loaded
	beq	.dsp_set_frame_shadow

	; Locate the 64-byte choreography record for this automatic-demo frame.
	; Matrices are the exact Q12 output of PS1 routine 0x80144894.  The fixed
	; PS1 view looks from (0,0,2000) towards the origin, so its screen-space Z
	; row and translation are folded into the DSP transform here.
	move.l	animation_frame,d0
	lsl.l	#6,d0
	lea	trex_animation_data+TANM_CHOREOGRAPHY_OFFSET,a4
	adda.l	d0,a4

	move.l	dsp_animation_tx_ptr,a5
	move.l	a5,a0
	move.l	#DSP_CMD_SET_ANIMATED_FRAME,(a0)+
	; gait_hold_index is nonzero exactly during the held state (see the hold
	; branch in trex_dummy_frame), same as the gait-pose override below --
	; reused here so the matrix source switches to the Y-spin table there too.
	tst.l	gait_hold_index
	beq	.matrix_source_choreo
	move.l	y_spin_index,d1
	mulu.w	#18,d1			; 9 words * 2 bytes per matrix entry
	lea	y_spin_matrices,a3
	adda.l	d1,a3
	; Frames 253-273 show the source doing the same thing: as this same
	; matrix's own row0-col2 entry (sin of the yaw, Q12) grows, X translation
	; tracks it almost exactly one-for-one (tx/entry ratio climbs from ~3400
	; to ~4067 as the angle grows, converging on the entry's own Q12 unit,
	; 4096) -- the source is recentring the screen position as the object
	; turns, not holding X still.  Continuing the spin without continuing
	; that recentring is what drifted the head off-centre; stashed here from
	; the SAME table entry so it stays in lockstep with the matrix below.
	move.w	4(a3),d1
	ext.l	d1
	move.l	d1,y_spin_tx
	bra	.matrix_source_ready
.matrix_source_choreo
	move.l	a4,a3
.matrix_source_ready
	moveq	#5,d7
.copy_ps1_matrix_xy
	move.w	(a3)+,d1
	ext.l	d1
	lsl.l	#8,d1
	lsl.l	#3,d1
	cmpi.l	#$00800000,d1
	bne	.ps1_matrix_xy_ready
	subq.l	#1,d1			; +1.0 -> largest positive Q1.23
.ps1_matrix_xy_ready
	move.l	d1,(a0)+
	dbra	d7,.copy_ps1_matrix_xy

	moveq	#2,d7
.copy_ps1_matrix_z
	move.w	(a3)+,d1
	ext.l	d1
	neg.l	d1			; fixed view faces towards negative world Z
	lsl.l	#8,d1
	lsl.l	#3,d1
	cmpi.l	#$00800000,d1
	bne	.ps1_matrix_z_ready
	subq.l	#1,d1
.ps1_matrix_z_ready
	move.l	d1,(a0)+
	dbra	d7,.copy_ps1_matrix_z

	tst.l	gait_hold_index
	beq	.translation_x_choreo
	move.l	y_spin_tx,(a0)+
	bra	.translation_x_done
.translation_x_choreo
	move.l	TANM_CHOREO_TRANSLATION(a4),(a0)+
.translation_x_done
	move.l	TANM_CHOREO_TRANSLATION+4(a4),(a0)+
	move.l	#PS1_VIEWPOINT_Z,d1
	sub.l	TANM_CHOREO_TRANSLATION+8(a4),d1
	move.l	d1,(a0)+

	move.l	#PS1_PROJECTION_X,(a0)+
	move.l	#PS1_PROJECTION_Y,(a0)+
	move.l	#SCREEN_WIDTH/2,(a0)+		; screen centre x
	move.l	#SCREEN_HEIGHT/2,(a0)+		; screen centre y
	move.l	#NEAR_PLANE,(a0)+		; near distance

	; Camera-space light direction.  Sending it per frame rather than baking
	; it into the DSP keeps the light fixed relative to the viewer while the
	; object turns, and leaves room for a moving light later.
	moveq	#DSP_LIGHT_WORDS-1,d7
	lea	dsp_light_direction,a3
.copy_light_word
	move.l	(a3)+,(a0)+
	dbra	d7,.copy_light_word

	; Keep the extracted non-visual state visible to future audio/scene code.
	move.l	a4,animation_choreo_record
	moveq	#0,d0
	move.w	TANM_CHOREO_AUDIO_VOLUME(a4),d0
	move.l	d0,animation_audio_volume
	moveq	#0,d0
	move.w	TANM_CHOREO_FLAGS(a4),d0
	move.l	d0,animation_scene_flags
	moveq	#0,d0
	move.w	TANM_CHOREO_ACTIVE_MASK(a4),d0
	move.l	d0,animation_active_mask

	; BEGIN is deliberately a small acknowledged transaction.  TOS 4.02's
	; Dsp_BlkUnpacked source walk wraps at a 64-KiB host-address boundary;
	; keeping every animation sub-transaction below 4.5 KiB is independent of
	; the program's load address and also gives failures an exact stage.
	move.l	a0,d3
	sub.l	a5,d3
	lsr.l	#2,d3
	move.l	a5,a0
	move.l	d3,d0
	lea	dsp_rx_buffer,a1
	moveq	#1,d1
	bsr	dsp_block_handshake
	cmpi.l	#DSP_ACK_ANIMATION_BEGIN,dsp_rx_buffer
	bne	.dsp_set_frame_shadow

	; The extractor deduplicates the 274 autoplay frames to 46 full-body gait
	; deltas.  Send the 1,376 vertices in bounded chunks; the source pointer is
	; derived from the vertex index each time, so no XBIOS register-preservation
	; assumption leaks into the loop.
	;
	; gait_hold_index is nonzero only once the hold state (trex_dummy_frame)
	; has started advancing it; that takes priority over the now-frozen
	; choreography record's own field so the walk cycle keeps looping there.
	move.l	gait_hold_index,d0
	bne	.dsp_set_frame_gait_selected
	moveq	#0,d0
	move.w	TANM_CHOREO_GAIT_INDEX(a4),d0
.dsp_set_frame_gait_selected
	mulu.w	#TANM_GAIT_POSE_BYTES,d0
	lea	trex_animation_data+TANM_GAIT_DATA_OFFSET,a1
	adda.l	d0,a1
	move.l	a1,animation_gait_pose_ptr
	clr.l	animation_chunk_first
.dsp_set_frame_gait_chunk
	move.l	animation_chunk_first,d0
	move.l	#TREX_VERTICES,d1
	sub.l	d0,d1
	cmpi.l	#DSP_ANIMATION_GAIT_CHUNK,d1
	bls	.dsp_set_frame_gait_count_ready
	move.l	#DSP_ANIMATION_GAIT_CHUNK,d1
.dsp_set_frame_gait_count_ready
	move.l	d1,animation_chunk_count
	move.l	d0,d2
	mulu.w	#6,d2
	move.l	animation_gait_pose_ptr,a1
	adda.l	d2,a1
	bsr	animation_send_gait_chunk
	tst.l	d0
	bne	.dsp_set_frame_shadow
	move.l	animation_chunk_count,d0
	add.l	d0,animation_chunk_first
	cmpi.l	#TREX_VERTICES,animation_chunk_first
	bcs	.dsp_set_frame_gait_chunk

	; Targets 0..3 are already combined in the gait pose; target 4 is unused
	; by autoplay.  Send only non-zero targets 5..8, retaining the original
	; raw deltas and signed Q12 weights for the DSP.
	move.l	animation_choreo_record,a4
	move.w	TANM_CHOREO_WEIGHTS+10(a4),d0
	ext.l	d0
	moveq	#0,d1
	move.l	#147,d2
	lea	trex_animation_data+TANM_TARGET_5_DELTA,a1
	bsr	animation_send_target
	tst.l	d0
	bne	.dsp_set_frame_shadow

	move.l	animation_choreo_record,a4
	move.w	TANM_CHOREO_WEIGHTS+12(a4),d0
	ext.l	d0
	moveq	#0,d1
	move.l	#557,d2
	lea	trex_animation_data+TANM_TARGET_6_DELTA,a1
	bsr	animation_send_target
	tst.l	d0
	bne	.dsp_set_frame_shadow

	move.l	animation_choreo_record,a4
	move.w	TANM_CHOREO_WEIGHTS+14(a4),d0
	ext.l	d0
	move.l	#78,d1
	move.l	#12,d2
	lea	trex_animation_data+TANM_TARGET_7_DELTA,a1
	bsr	animation_send_target
	tst.l	d0
	bne	.dsp_set_frame_shadow

	move.l	animation_choreo_record,a4
	move.w	TANM_CHOREO_WEIGHTS+16(a4),d0
	ext.l	d0
	moveq	#0,d1
	move.l	#557,d2
	lea	trex_animation_data+TANM_TARGET_8_DELTA,a1
	bsr	animation_send_target
	tst.l	d0
	bne	.dsp_set_frame_shadow

	; FINISH is sent fire-and-forget: the DSP morphs, transforms and
	; projects the 1,376-vertex pose while the CPU rasterizes the PREVIOUS
	; frame, and dsp_finish_frame_wait collects the two ack words at the
	; start of the next slot's dsp_packets_begin.  The pending ack sits
	; safely in the DSP-side TX path meanwhile: the DSP polls HTDE before
	; every write and has nothing further to say until the next command.
	move.l	dsp_animation_tx_ptr,a5
	move.l	#DSP_CMD_FINISH_ANIMATED_FRAME,(a5)
	move.l	a5,a0
	moveq	#1,d0
	lea	dsp_rx_buffer,a1
	moveq	#0,d1				; send only, ack deferred
	bsr	dsp_block_handshake
	move.l	#1,dsp_animation_inflight
.dsp_set_frame_shadow
	rts

; Collect the deferred FINISH ack of the animation sent last slot.  Returns
; D0 = 1 when a complete pose is transformed and projected on the DSP, and
; D0 = 0 when nothing is in flight or the ack was wrong -- the caller then
; leaves the chunk pipeline inactive and dsp_packets_finish falls back to
; the host stream, exactly the pre-pipelining failure behaviour.
dsp_finish_frame_wait
	tst.l	dsp_animation_inflight
	beq	.finish_wait_none
	clr.l	dsp_animation_inflight
	moveq	#0,d0				; nothing to send
	lea	dsp_rx_buffer,a1
	moveq	#2,d1
	bsr	dsp_block_handshake
	move.l	dsp_rx_buffer,dsp_protocol_shadow
	cmpi.l	#DSP_ACK_FRAME,dsp_protocol_shadow
	bne	.finish_wait_none
	move.l	dsp_rx_buffer+4,dsp_vertex_count_shadow
	addq.l	#1,dsp_frame_upload_count
	moveq	#1,d0
	rts
.finish_wait_none
	moveq	#0,d0
	rts

animation_send_gait_chunk
	; D0 = first vertex, D1 = vertex count, A1 = XYZ16 source.
	move.l	dsp_animation_tx_ptr,a5
	move.l	a5,a0
	move.l	#DSP_CMD_LOAD_ANIMATION_GAIT,(a0)+
	move.l	d0,(a0)+
	move.l	d1,(a0)+
	move.l	d1,d7
	subq.w	#1,d7
	bsr	animation_expand_delta_stream
	move.l	a0,d3
	sub.l	a5,d3
	lsr.l	#2,d3
	move.l	a5,a0
	move.l	d3,d0
	lea	dsp_rx_buffer,a1
	moveq	#1,d1
	bsr	dsp_block_handshake
	cmpi.l	#DSP_ACK_ANIMATION_GAIT,dsp_rx_buffer
	bne	animation_send_failed
	moveq	#0,d0
	rts

animation_send_target
	; D0 = signed Q12 weight, D1 = first vertex, D2 = vertex count,
	; A1 = XYZ16 source.  Zero weights need no transaction; larger
	; sparse targets are divided into the same bounded blocks as the gait.
	tst.l	d0
	beq	.animation_send_ok
	move.l	d0,animation_target_weight
	move.l	d1,animation_target_first
	move.l	d2,animation_target_remaining
	move.l	a1,animation_target_source
.animation_send_target_chunk
	move.l	animation_target_remaining,d2
	tst.l	d2
	beq	.animation_send_ok
	cmpi.l	#DSP_ANIMATION_GAIT_CHUNK,d2
	bls	.animation_target_count_ready
	move.l	#DSP_ANIMATION_GAIT_CHUNK,d2
.animation_target_count_ready
	move.l	d2,animation_chunk_count
	move.l	dsp_animation_tx_ptr,a5
	move.l	a5,a0
	move.l	#DSP_CMD_APPLY_ANIMATION_TARGET,(a0)+
	move.l	animation_target_weight,(a0)+
	move.l	animation_target_first,(a0)+
	move.l	d2,(a0)+
	move.l	d2,d7
	subq.w	#1,d7
	move.l	animation_target_source,a1
	bsr	animation_expand_delta_stream
	move.l	a1,animation_target_source
	move.l	animation_chunk_count,d2
	add.l	d2,animation_target_first
	sub.l	d2,animation_target_remaining
	move.l	a0,d3
	sub.l	a5,d3
	lsr.l	#2,d3
	move.l	a5,a0
	move.l	d3,d0
	lea	dsp_rx_buffer,a1
	moveq	#1,d1
	bsr	dsp_block_handshake
	cmpi.l	#DSP_ACK_ANIMATION_TARGET,dsp_rx_buffer
	bne	animation_send_failed
	bra	.animation_send_target_chunk
.animation_send_ok
	moveq	#0,d0
	rts
animation_send_failed
	moveq	#-1,d0
	rts

; Send D0 longwords from (A0) to the DSP host port, then read D1 longwords back
; into (A1), polling the port before every single word.
;
; This replaces Dsp_BlkUnpacked for the animation transactions.  TOS 4.02 tests
; TXDE once and then DBFs straight back onto the write instruction, so it blasts
; the whole block at CPU speed (verified in ROM at $e05176..$e05182).  The
; DSP56001 host port is a single register: a word written while TXDE is clear
; overwrites the one the DSP has not fetched yet, and that word is simply gone.
; Any command whose DSP-side loop does real work between two reads can lose one
; -- the animation target loop, with its Q12 multiply-accumulate per component,
; does.  The DSP then waits for a word that never arrives while the host waits
; for the reply, and the frame never completes.
;
; Whether the race is lost at all depends on cycle-exact timing, so it moves
; with unrelated code-layout changes: the committed build survives it, the same
; build with 16 to 128 bytes of padding added anywhere in the text section
; deadlocks on animation frame 1.  A missing word was caught in the host-port
; trace: target 7 sends 36 deltas, the DSP received 35, and the value at index
; 25 was the one at index 26.
;
; Clobbers D0, D1, A0 and A1.
dsp_block_handshake
	tst.l	d0
	beq	.dsp_block_receive
.dsp_block_send
	btst.b	#DSP_HOST_ISR_TXDE,DSP_HOST_ISR
	beq	.dsp_block_send			; DSP has not taken the last word
	move.l	(a0)+,DSP_HOST_DATA
	subq.l	#1,d0
	bne	.dsp_block_send
.dsp_block_receive
	tst.l	d1
	beq	.dsp_block_done
.dsp_block_recv
	btst.b	#DSP_HOST_ISR_RXDF,DSP_HOST_ISR
	beq	.dsp_block_recv			; DSP has not produced a word yet
	move.l	DSP_HOST_DATA,(a1)+
	subq.l	#1,d1
	bne	.dsp_block_recv
.dsp_block_done
	rts

animation_expand_delta_stream
	; Expand three big-endian signed-16 source components to three native DSP
	; words.  This is a cheap sequential pass on the M68030 and lets the DSP
	; consume the synchronous host stream without a shift-heavy wire decoder.
	move.w	(a1)+,d1
	ext.l	d1
	move.l	d1,(a0)+
	move.w	(a1)+,d1
	ext.l	d1
	move.l	d1,(a0)+
	move.w	(a1)+,d1
	ext.l	d1
	move.l	d1,(a0)+
	dbra	d7,animation_expand_delta_stream
	rts

dsp_upload_mesh
	addq.l	#1,dsp_call_count
	tst.l	dsp_program_loaded
	beq	.dsp_upload_shadow

	; Morph targets and choreography are defined in the original TMD object
	; space, so upload the unscaled signed-16 TMD base vertices.  The O3D copy
	; remains the host's triangle/UV representation only.
	lea	dsp_tx_buffer,a1
	move.l	#DSP_CMD_LOAD_VERTICES,(a1)+
	move.l	#TREX_VERTICES,(a1)+
	lea	trex_tmd_data+TMD_VERTEX_DATA_OFFSET,a0
	move.l	#TREX_VERTICES-1,d0
.copy_vertex
	move.w	(a0)+,d1
	ror.w	#8,d1			; PS1 TMD is little-endian
	ext.l	d1
	move.l	d1,(a1)+
	move.w	(a0)+,d1
	ror.w	#8,d1
	ext.l	d1
	move.l	d1,(a1)+
	move.w	(a0)+,d1
	ror.w	#8,d1
	ext.l	d1
	move.l	d1,(a1)+
	addq.l	#2,a0			; discard SVECTOR pad
	dbra	d0,.copy_vertex

	Dsp_BlkUnpacked	dsp_tx_buffer,#DSP_UPLOAD_WORDS,dsp_rx_buffer,#2
	move.l	dsp_rx_buffer,dsp_protocol_shadow
	cmpi.l	#DSP_ACK_LOAD,dsp_protocol_shadow
	bne	.dsp_upload_shadow
	cmpi.l	#TREX_VERTICES,dsp_rx_buffer+4
	bne	.dsp_upload_shadow
	move.l	#1,dsp_mesh_loaded
	move.l	dsp_rx_buffer+4,dsp_vertex_count_shadow
.dsp_upload_shadow
	rts

; Send the per-triangle face normals the flat shader needs.  They are derived
; from the O3D by tools/o3d2facenormals.js and embedded below, already in the
; DSP's 24-bit 1.23 fractional format and in triangle order, so this is a
; straight copy into the transaction buffer.
;
; The mesh's own vertex normals are not usable here: an O3D polygon only
; references the normal of its first vertex, which on this model sits up to 58
; degrees off the polygon plane and turns per-face shading into noise.
dsp_upload_face_normals
	; Gouraud: the complete PS1 corner-normal table straight from the TMD's
	; own normal block -- little-endian Q12 SVECTORs, byte-swapped and
	; shifted into 1.23 here, no offline sidecar involved.  The DSP splits
	; the table across its Y and X banks (NORMAL_Y_COUNT there).
	addq.l	#1,dsp_call_count
	tst.l	dsp_program_loaded
	beq	.dsp_upload_normals_shadow

	lea	dsp_normal_tx_buffer,a1
	move.l	#DSP_CMD_LOAD_NORMALS,(a1)+
	move.l	#TREX_TMD_NORMALS,(a1)+
	lea	trex_tmd_data+TMD_NORMAL_DATA_OFFSET,a0
	move.l	#TREX_TMD_NORMALS-1,d0
	moveq	#11,d2
.copy_corner_normal
	moveq	#3-1,d3
.copy_corner_component
	move.w	(a0)+,d1
	ror.w	#8,d1			; PS1 TMD is little-endian
	ext.l	d1
	lsl.l	d2,d1			; Q12 -> 1.23
	cmpi.l	#$00800000,d1
	bne	.corner_component_ready
	subq.l	#1,d1			; +1.0 -> largest positive, as the
					; matrix conversion does: +4096 would
					; otherwise wrap to -1.0
.corner_component_ready
	move.l	d1,(a1)+
	dbra	d3,.copy_corner_component
	addq.l	#2,a0			; discard SVECTOR pad
	dbra	d0,.copy_corner_normal

	Dsp_BlkUnpacked	dsp_normal_tx_buffer,#DSP_NORMAL_UPLOAD_WORDS,dsp_rx_buffer,#2
	move.l	dsp_rx_buffer,dsp_protocol_shadow
	cmpi.l	#DSP_ACK_NORMALS,dsp_protocol_shadow
	bne	.dsp_upload_normals_shadow
	cmpi.l	#TREX_TMD_NORMALS,dsp_rx_buffer+4
	bne	.dsp_upload_normals_shadow
	move.l	#1,dsp_normals_loaded
	move.l	dsp_rx_buffer+4,dsp_face_normal_count_shadow
.dsp_upload_normals_shadow
	rts

dsp_build_triangle_stream
	addq.l	#1,dsp_call_count
	tst.l	dsp_mesh_loaded
	beq	.dsp_triangle_stream_shadow

	; O3D polygons are all triangles here.  Each record is
	; (point-count, material, normal, back, front, i0*3, i1*3, i2*3,
	;  u0, v0, u1, v1, u2, v2, clut, tpage).
	lea	dsp_triangle_tx_buffer,a1
	move.l	#DSP_CMD_BUILD_TRIANGLES,(a1)+
	move.l	#TREX_PRIMITIVES,(a1)+
	lea	trex_o3d_data+O3D_POLYGON_OFFSET,a0
	lea	gpu_texture_meta_buffer,a3
	move.l	#TREX_PRIMITIVES-1,d7
.copy_triangle
	bsr	read_be_word
	move.w	d0,d6			; point count (3 for this mesh)
	bsr	read_be_word		; material
	move.l	d0,d5
	bsr	read_be_word		; normal offset
	bsr	read_be_word		; back link
	bsr	read_be_word		; front link
	bsr	read_be_word
	divu.w	#3,d0
	andi.l	#$0000ffff,d0
	move.l	d0,(a1)+			; i0
	bsr	read_be_word
	divu.w	#3,d0
	andi.l	#$0000ffff,d0
	move.l	d0,(a1)+			; i1
	bsr	read_be_word
	divu.w	#3,d0
	andi.l	#$0000ffff,d0
	move.l	d0,(a1)+			; i2
	move.l	d5,(a1)+			; material
	move.l	#O3D_TEXTURE_WORDS-1,d6
.copy_texture_metadata
	bsr	read_be_word
	move.l	d0,(a3)+
	dbra	d6,.copy_texture_metadata

	; The O3D CLUT word in this host-side record is otherwise dead.  Replace
	; it once, at load time, with a packet token: the byte offset (0,4,...20)
	; into the texture page pointer tables, stored in the high word.  The
	; native TPAGE remains in the following longword for diagnostics and
	; occlusion dumps.  Unsupported pages map to page zero, exactly like the
	; retired per-packet linear search did.
	move.l	d0,d1			; last copied word = TPAGE
	andi.l	#$1f,d1
	lea	texture_page_offset_by_tpage,a2
	moveq	#0,d2
	move.b	(0,a2,d1.l),d2
	swap	d2				; table byte offset -> high word
	move.l	d2,-8(a3)			; overwrite the dead CLUT slot
	dbra	d7,.copy_triangle

	move.l	#1,dsp_triangle_stream_ready
.dsp_triangle_stream_shadow
	rts

; Upload the static (i0,i1,i2) list to the DSP once.  It used to be re-sent
; with every chunk of every frame -- 2724 * 4 = 10,896 words, 49% of all
; host-port traffic -- for a list that dsp_build_triangle_stream builds once
; from the O3D and never touches again.
;
; The DSP holds it packed at two words per triangle: the unpacked 8172-word
; form does not fit beside the equally large face-normal array in Y memory.
; dsp_triangle_tx_buffer keeps the unpacked host-side copy, because
; build_gpu_shadow_packets still looks up indices and material there by source
; index.
dsp_upload_triangle_indices
	addq.l	#1,dsp_call_count
	tst.l	dsp_triangle_stream_ready
	beq	.dsp_upload_indices_shadow

	; Three packed words per triangle since Gouraud: v0|v1<<12, v2|n0<<12,
	; n1|n2<<12.  Vertex indices come from the O3D stream as before, the
	; corner-normal indices from the offline-recovered sidecar
	; (tools/tmd2cornernormals.js), both walked in the same O3D order.
	lea	dsp_triangle_load_tx_buffer,a1
	move.l	#DSP_CMD_LOAD_TRIANGLES,(a1)+
	move.l	#TREX_PRIMITIVES,(a1)+
	lea	dsp_triangle_tx_buffer+8,a0
	lea	trex_corner_normal_data,a2
	lea	trex_opaque_triangle_data,a3
	moveq	#DSP_TRI_INDEX_BITS,d4
	moveq	#0,d5				; source triangle index
	move.l	#TREX_PRIMITIVES-1,d0
.pack_triangle_indices
	move.l	(a0)+,d1			; i0
	move.l	(a0)+,d2			; i1
	move.l	(a0)+,d3			; i2
	addq.l	#4,a0				; material stays host-side
	andi.l	#DSP_TRI_INDEX_MASK,d1
	andi.l	#DSP_TRI_INDEX_MASK,d2
	lsl.l	d4,d2				; LSL.L takes 1..8 as an immediate only
	or.l	d2,d1
	; Occluder qualification for the DSP occlusion stage, in the v1 field's
	; spare top bit (bit 23).  Same sidecar byte and same meaning as
	; OPAQUE_PACKET_BIT in the packet builder: the triangle's conservative UV
	; footprint touches no transparent texel, so its coverage may seal.  This
	; is deliberately independent of opaque_path_enabled -- that flag is the
	; rasterizer A/B gate, while sealing soundness is not optional.
	tst.b	(a3,d5.l)
	beq	.pack_no_occluder
	ori.l	#DSP_TRI_OCCLUDER_BIT,d1
.pack_no_occluder
	addq.l	#1,d5
	move.l	d1,(a1)+			; v0 | v1<<12 | occluder<<23
	andi.l	#DSP_TRI_INDEX_MASK,d3
	moveq	#0,d1
	move.w	(a2)+,d1			; n0, big-endian sidecar word
	lsl.l	d4,d1
	or.l	d1,d3
	move.l	d3,(a1)+			; v2 | n0<<12
	moveq	#0,d1
	move.w	(a2)+,d1			; n1
	moveq	#0,d2
	move.w	(a2)+,d2			; n2
	lsl.l	d4,d2
	or.l	d2,d1
	move.l	d1,(a1)+			; n1 | n2<<12
	dbra	d0,.pack_triangle_indices

	Dsp_BlkUnpacked	dsp_triangle_load_tx_buffer,#DSP_TRIANGLE_LOAD_WORDS,dsp_rx_buffer,#2
	move.l	dsp_rx_buffer,dsp_protocol_shadow
	cmpi.l	#DSP_ACK_LOAD_TRIANGLES,dsp_protocol_shadow
	bne	.dsp_upload_indices_shadow
	cmpi.l	#TREX_PRIMITIVES,dsp_rx_buffer+4
	bne	.dsp_upload_indices_shadow
	move.l	#1,dsp_triangle_indices_loaded
.dsp_upload_indices_shadow
	rts

; Upload the static UV bytes once, packed two words per triangle:
; u0|v0<<8|u1<<16 and v1|u2<<8|v2<<16.  They come from the same
; gpu_texture_meta_buffer the packet builder and the span validator read, so
; every consumer of a UV byte sees identical data.
dsp_upload_uvs
	; Since Gouraud this packs but no longer uploads: the corner normals
	; displaced the resident UV table from DSP X memory, so the packed
	; pairs stay host-side and dsp_send_build_chunk ships each chunk's two
	; words per triangle with the BUILD command instead.  The routine name
	; and its dsp_uvs_loaded flag keep their place in the init chain and
	; the pipeline gate.
	addq.l	#1,dsp_call_count
	tst.l	dsp_triangle_stream_ready
	beq	.dsp_upload_uvs_shadow

	lea	dsp_uv_tx_buffer,a1
	lea	gpu_texture_meta_buffer,a0
	move.l	#TREX_PRIMITIVES-1,d0
.pack_uv_pair
	move.l	(a0)+,d1			; u0
	move.l	(a0)+,d2			; v0
	move.l	(a0)+,d3			; u1
	andi.l	#$ff,d1
	andi.l	#$ff,d2
	andi.l	#$ff,d3
	lsl.l	#8,d2
	or.l	d2,d1
	swap	d3
	or.l	d3,d1
	move.l	d1,(a1)+
	move.l	(a0)+,d1			; v1
	move.l	(a0)+,d2			; u2
	move.l	(a0)+,d3			; v2
	addq.l	#8,a0				; skip CLUT and TPAGE
	andi.l	#$ff,d1
	andi.l	#$ff,d2
	andi.l	#$ff,d3
	lsl.l	#8,d2
	or.l	d2,d1
	swap	d3
	or.l	d3,d1
	move.l	d1,(a1)+
	dbra	d0,.pack_uv_pair

	move.l	#1,dsp_uvs_loaded
.dsp_upload_uvs_shadow
	rts

; The chunk protocol is PIPELINED across these two entry points: begin
; launches the first BUILD and returns while the DSP computes it -- the frame
; loop clears the framebuffer in that window -- and finish drains the
; pipeline, reading each chunk's ack, fetching its records, immediately
; launching the next chunk and only then unpacking, so the DSP always
; computes chunk N+1 while the host expands chunk N.  The DSP program is
; untouched: only the order of host transactions changed.
dsp_packets_begin
	addq.l	#1,dsp_call_count
	clr.l	dsp_pipeline_active
	tst.l	dsp_triangle_stream_ready
	beq	.begin_done
	; Cross-frame pipelining: the animation for THIS slot's geometry was
	; sent before the previous frame rasterized; collect its FINISH ack
	; first.  Without a validly transformed pose there is nothing to build.
	bsr	dsp_finish_frame_wait
	tst.l	d0
	beq	.begin_done
	; The projected vertex copy is only needed by the validator's reference
	; arithmetic and by the host fallback stream.  If this prefetch fails,
	; the pipeline stays inactive and the finish pass repeats the fetch for
	; its fallback, reproducing the old shadow behaviour.
	clr.l	dsp_vertices_fetched
	; The occlusion build needs the projected vertices every frame for the
	; record's clipped vertex box, but not the validator's field-by-field
	; comparison that normally comes with them -- so it takes the fetch and
	; leaves span_validate_enabled at 0.
	ifd	TREX_OCCL
	bsr	fetch_projected_vertices
	bra	.begin_no_prefetch
	endc
	tst.l	span_validate_enabled
	beq	.begin_no_prefetch
	bsr	fetch_projected_vertices
.begin_no_prefetch
	tst.l	dsp_triangle_indices_loaded
	beq	.begin_done
	tst.l	dsp_uvs_loaded
	beq	.begin_done
	; The one place a standalone prepass command may be issued: the FINISH
	; ack is in, so the DSP is back in its main loop and reads the host
	; port; this frame's projection is complete; and chunk_uvs/triangle_out
	; -- which the prepass scratch overlays -- are still dead because the
	; first BUILD chunk has not been sent.  Moving this after
	; dsp_send_build_chunk destroys the chunk in flight.
	ifd	TREX_PREPASS
	bsr	prepass_frame_call
	endc
	lea	dsp_triangle_rx_buffer+8,a1
	move.l	a1,dsp_triangle_output_ptr
	clr.l	dsp_triangle_output_count
	move.l	#TREX_PRIMITIVES,dsp_triangles_remaining
	clr.l	dsp_triangle_input_count
	bsr	dsp_send_build_chunk
	move.l	#1,dsp_pipeline_active
.begin_done
	rts

; Three words out, nothing back: the DSP starts computing the chunk and the
; pipeline's next ack read is the synchronization point.  The chunk is
; deducted from the not-yet-sent pool at send time.
dsp_send_build_chunk
	move.l	dsp_triangles_remaining,d4
	cmpi.l	#DSP_TRIANGLE_CHUNK,d4
	bls	.send_chunk_sized
	move.l	#DSP_TRIANGLE_CHUNK,d4
.send_chunk_sized
	move.l	d4,dsp_triangle_chunk_count
	move.l	#DSP_CMD_BUILD_TRIANGLES,dsp_triangle_chunk_tx
	move.l	d4,dsp_triangle_chunk_tx+4
	move.l	dsp_triangle_input_count,d6
	move.l	d6,dsp_triangle_chunk_tx+8
	; The chunk's UV pairs follow the three command words: two packed
	; words per triangle, copied from the host-resident pack at this
	; chunk's base.  The DSP stores them chunk-locally (chunk_uvs).
	move.l	dsp_triangles_remaining,d5
	sub.l	d4,d5
	move.l	d5,dsp_triangles_remaining
	lea	dsp_triangle_chunk_tx+12,a1
	lea	dsp_uv_tx_buffer,a0
	move.l	d6,d5
	lsl.l	#3,d5				; base * 2 longs * 4 bytes
	adda.l	d5,a0
	move.l	d4,d5
	add.l	d5,d5				; 2 * count uv words
	subq.l	#1,d5
.chunk_uv_copy
	move.l	(a0)+,(a1)+
	dbra	d5,.chunk_uv_copy
	move.l	d4,d5
	add.l	d5,d5
	addq.l	#3,d5				; total words: 3 + 2*count
	Dsp_BlkUnpacked	dsp_triangle_chunk_tx,d5,dsp_rx_buffer,#0
	rts

dsp_packets_finish
	addq.l	#1,dsp_call_count
	tst.l	dsp_triangle_stream_ready
	beq	.finish_shadow
	tst.l	dsp_pipeline_active
	beq	.finish_fallback
	bsr	dsp_drain_chunk_pipeline
	tst.l	d0
	bne	.finish_build
.finish_fallback
	tst.l	dsp_vertices_fetched
	bne	.finish_have_vertices
	bsr	fetch_projected_vertices
	tst.l	d0
	beq	.finish_shadow
.finish_have_vertices
	bsr	build_host_triangle_stream
.finish_build
	lea	gpu_packet_buffer,a1
	move.l	a1,gpu_packet_ptr
	bsr	build_gpu_shadow_packets
.finish_shadow
	rts

; GET_VERTICES plus the one-off sign extension of the received words: DSP
; words arrive zero-extended in 32-bit longs, and screen coordinates go
; negative at the screen edge.  Returns D0=1 on success and marks the frame
; so validator and fallback never fetch twice.
fetch_projected_vertices
	move.l	#DSP_CMD_GET_VERTICES,dsp_control_tx
	Dsp_BlkUnpacked	dsp_control_tx,#1,dsp_vertex_rx_buffer,#DSP_VERTEX_OUTPUT_WORDS
	move.l	dsp_vertex_rx_buffer,dsp_protocol_shadow
	cmpi.l	#DSP_ACK_VERTICES,dsp_protocol_shadow
	bne	.fetch_vertices_failed
	lea	dsp_vertex_rx_buffer+8,a0
	move.l	#(TREX_VERTICES*4)-1,d1
.sign_extend_loop
	move.l	(a0),d0
	btst	#23,d0
	beq	.sign_extend_next
	ori.l	#$ff000000,d0
	move.l	d0,(a0)
.sign_extend_next
	addq.l	#4,a0
	dbra	d1,.sign_extend_loop
	move.l	#1,dsp_vertices_fetched
	moveq	#1,d0
	rts
.fetch_vertices_failed
	moveq	#0,d0
	rts

; Produce the same (source-index, average-z, shade) list the DSP culling path
; would return, with nothing culled.  Without the DSP there are no transformed
; normals, so every triangle gets full brightness and the render falls back to
; the unshaded look; off-screen and degenerate triangles are handled by the
; span rasterizer's own clipping and cross-product guard.
build_host_triangle_stream
	lea	dsp_triangle_tx_buffer+8,a0
	lea	dsp_triangle_rx_buffer+8,a1
	clr.l	dsp_triangle_output_count
	moveq	#0,d6
	move.l	#TREX_PRIMITIVES-1,d7
.host_triangle_loop
	move.l	(a0)+,d1
	move.l	(a0)+,d2
	move.l	(a0)+,d3
	addq.l	#4,a0				; material stays where it is
	move.l	d1,d0
	bsr	load_projected_z
	move.l	d0,d5
	move.l	d2,d0
	bsr	load_projected_z
	add.l	d0,d5
	move.l	d3,d0
	bsr	load_projected_z
	add.l	d0,d5
	; Span fields via the shared reference arithmetic.  A degenerate
	; triangle emits no record at all: the record consumer has no
	; area guard of its own any more.
	move.l	d6,d1
	bsr	compute_span_reference
	tst.l	d0
	beq	.host_triangle_skip
	move.l	d6,(a1)+			; source triangle index
	move.l	d5,(a1)+			; average-z key
	move.l	#SHADE_MAX,(a1)+		; unlit fallback: full brightness
	lea	val_ref,a2
	moveq	#16,d0
.host_copy_ref
	move.l	(a2)+,(a1)+
	dbra	d0,.host_copy_ref
	; Unlit fallback level fields: both starts at full brightness, flat
	; gradients -- the Gouraud consumer then renders exactly the unshaded
	; look the fallback always had.
	move.l	#SHADE_MAX<<8,(a1)+		; 17: lvl_top
	move.l	#SHADE_MAX<<8,(a1)+		; 18: lvl_mid
	clr.l	(a1)+				; 19: dlvl_dx
	clr.l	(a1)+				; 20: dlvl_up
	clr.l	(a1)+				; 21: dlvl_low
	addq.l	#1,dsp_triangle_output_count
.host_triangle_skip
	addq.l	#1,d6
	dbra	d7,.host_triangle_loop
	rts


; Submit the prepared triangle records in host-port-safe chunks.  The DSP
; first drains each complete chunk into X memory, then performs area culling
; and Z-key calculation, so the M68030 never shares a live transfer with the
; relatively slow fixed-point geometry path.
;
; Return D0 = 1 when every chunk completed, or D0 = 0 when the caller should
; use the host fallback above.
; Drain the pipelined chunk protocol dsp_packets_begin launched: read the ack
; for the chunk in flight, fetch its records, immediately launch the next
; chunk, and only then unpack -- the DSP computes chunk N+1 while the host
; expands chunk N, and the frame's framebuffer clear already hid inside
; chunk 0's compute.  Every failure point sits between transactions, so the
; fallback never collides with a pending reply.
;
; Returns D0 = 1 when every chunk completed, or D0 = 0 for the host fallback.
dsp_drain_chunk_pipeline
.dsp_cull_chunk
	; Ack of the chunk in flight; zero words go out.
	Dsp_BlkUnpacked	dsp_control_tx,#0,dsp_rx_buffer,#2
	move.l	dsp_rx_buffer,d0
	cmpi.l	#DSP_ACK_TRIANGLES,d0
	bne	.dsp_cull_failed
	; The ack carries the chunk's SURVIVOR count.  It has to: the records
	; are survivors-only now, and Dsp_BlkUnpacked transfers a word count
	; fixed before the call, so the reply size must be known first.
	move.l	dsp_rx_buffer+4,d0
	cmp.l	dsp_triangle_chunk_count,d0
	bhi	.dsp_cull_failed		; more survivors than inputs: protocol error
	move.l	d0,dsp_triangle_chunk_survivors
	tst.l	d0
	beq	.dsp_cull_launch_next		; fully culled chunk: nothing to fetch

	move.l	#DSP_CMD_GET_TRIANGLES,dsp_control_tx
	move.l	d0,d3
	lsl.l	#4,d3
	add.l	d0,d3
	add.l	d0,d3				; eighteen words per survivor record --
						; BOTH sides of this count are shift-and-
						; add (the DSP's is at its send loop);
						; disagreeing sizes deadlock the port
	addq.l	#2,d3
	Dsp_BlkUnpacked	dsp_control_tx,#1,dsp_triangle_chunk_rx,d3
	move.l	dsp_triangle_chunk_survivors,d5
	move.l	dsp_triangle_chunk_rx,d0
	cmpi.l	#DSP_ACK_GET_TRIANGLES,d0
	bne	.dsp_cull_failed
	move.l	dsp_triangle_chunk_rx+4,d0
	cmp.l	d5,d0
	bne	.dsp_cull_failed

.dsp_cull_launch_next
	; This chunk's records are in the host buffer (or it had none), so the
	; DSP's output buffer is free: advance the base bookkeeping and launch
	; the next chunk NOW.  The unpack below then overlaps its compute.
	move.l	dsp_triangle_input_count,d0
	move.l	d0,dsp_triangle_unpack_base
	add.l	dsp_triangle_chunk_count,d0
	move.l	d0,dsp_triangle_input_count
	clr.l	dsp_chunk_inflight
	tst.l	dsp_triangles_remaining
	beq	.dsp_cull_unpack
	bsr	dsp_send_build_chunk
	move.l	#1,dsp_chunk_inflight
.dsp_cull_unpack
	move.l	dsp_triangle_chunk_survivors,d5
	tst.l	d5
	beq	.dsp_cull_chunk_next
	move.l	dsp_triangle_unpack_base,d6
	move.l	dsp_triangle_output_ptr,a1
	lea	dsp_triangle_chunk_rx+8,a2
	move.l	d5,d0
	subq.l	#1,d0
	; Sign-extension constants, held for the whole chunk.  x ^ m - m with
	; m = the field's sign bit is the branchless 12- and 24-bit sign extend,
	; and it is four bytes where btst/beq/ori was twelve.  That matters here
	; for one reason: this body is fetched from ST-RAM once per survivor, so
	; its LENGTH is its cost, and 256 bytes is where the 68030 stops paying.
	move.l	#$800,d7
	move.l	#$800000,d5
	lea	gpu_texture_meta_buffer,a0
	; Unpack each survivor's leading pair into the host's three-longword
	; record.  The fifteen span-setup fields that follow go through the
	; validator, which checks every one against the host's own arithmetic;
	; the rasterizer neither stores nor reads them until the validated
	; switch-over.
	;
	; The loop body below is 250 bytes.  At that length its start phase
	; decides whether it fits the 256-byte direct-mapped instruction cache:
	; any start above (mod 16) = 6 makes the first and last line share a
	; cache slot and the loop evicts itself once per survivor.  Pinning the
	; start to a line boundary makes the fit unconditional -- 0+250 <= 256 --
	; and immune to every text change in front of it (the delta-clear
	; move into the main path shifted it from phase 4 to 10, which is what
	; this cnop repairs).
	cnop	0,16
.dsp_cull_copy_output
	move.l	(a2)+,d1			; w0: slots | mid | shade | local
	move.l	d1,d2
	andi.l	#$1f,d2
	add.l	d6,d2
	move.l	d2,(a1)+			; global source index
	move.l	(a2)+,(a1)+			; w1: average-z key
	move.l	d1,d2
	lsr.l	#5,d2
	andi.l	#$3f,d2
	move.l	d2,(a1)+			; tint<<4 | brightness level

	; Expand the packed geometry into the seventeen-field block the packet
	; builder and rasterizer consume, sign-extending each signed field
	; exactly once.  D1 keeps w0 alive for the mid flag and the slot ids.
	move.l	(a2)+,d3			; w2: rows_up<<12 | sy0
	move.l	d3,d2
	andi.l	#$fff,d2
	eor.l	d7,d2
	sub.l	d7,d2
	move.l	d2,(a1)+			; 0: sy0
	lsr.l	#8,d3
	lsr.l	#4,d3
	move.l	d3,(a1)+			; 1: rows_up
	move.l	(a2)+,d3			; w3: sx0<<12 | rows_low
	move.l	d3,d2
	andi.l	#$fff,d2
	move.l	d2,(a1)+			; 2: rows_low
	move.l	d1,d2
	lsr.l	#8,d2
	lsr.l	#3,d2
	andi.l	#1,d2
	move.l	d2,(a1)+			; 3: mid
	lsr.l	#8,d3
	lsr.l	#4,d3
	eor.l	d7,d3
	sub.l	d7,d3
	lsl.l	#8,d3
	lsl.l	#4,d3
	move.l	d3,(a1)+			; 4: xl0 = sx0<<12
	move.l	(a2)+,d4			; w4: sx1, staged for field 8
	moveq	#2,d2				; w5..w7: the three slopes
.ux_slope
	move.l	(a2)+,d3
	eor.l	d5,d3
	sub.l	d5,d3
	move.l	d3,(a1)+			; 5..7: sl_long, sl_up, sl_low
	dbra	d2,.ux_slope
	andi.l	#$fff,d4
	eor.l	d7,d4
	sub.l	d7,d4
	lsl.l	#8,d4
	lsl.l	#4,d4
	move.l	d4,(a1)+			; 8: x1r = sx1<<12
	moveq	#5,d2				; w8..w13: gradients and chain steps
.ux_grad
	move.l	(a2)+,d3
	eor.l	d5,d3
	sub.l	d5,d3
	move.l	d3,(a1)+			; 9..14
	dbra	d2,.ux_grad

	; UV start packs from the resident texture metadata via the slot ids --
	; they never travel the wire.  Meta layout: u,v longs per vertex slot.
	; A1 is 18 longs into the record here (head plus fields 0..14), so the
	; source index sits at -72, not the -80 it reaches once both packs are
	; stored -- the validator caught the difference on first contact.
	move.l	-72(a1),d3			; global source index
	lsl.l	#5,d3
	lea	(a0,d3.l),a3
	move.l	d1,d2
	lsr.l	#8,d2
	lsr.l	#4,d2
	andi.w	#3,d2				; slot_top
	lsl.l	#3,d2
	moveq	#0,d3
	move.b	3(a3,d2.l),d3
	moveq	#0,d4
	move.b	7(a3,d2.l),d4
	lsl.l	#8,d4
	or.l	d4,d3
	move.l	d3,(a1)+			; 15: uv0 pack
	move.l	d1,d2
	lsr.l	#8,d2
	lsr.l	#6,d2
	andi.w	#3,d2				; slot_mid
	lsl.l	#3,d2
	moveq	#0,d3
	move.b	3(a3,d2.l),d3
	moveq	#0,d4
	move.b	7(a3,d2.l),d4
	lsl.l	#8,d4
	or.l	d4,d3
	move.l	d3,(a1)+			; 16: uv1 pack

	; Validate against the UNPACKED fields: this checks the DSP arithmetic
	; and the pack/unpack round trip in one comparison.
	tst.l	span_validate_enabled
	bne	.dsp_cull_validate
.dsp_cull_no_validate
	; Gouraud tail, written AFTER the validator block so its established
	; negative offsets over the 20-long prefix stay untouched: both level
	; starts from w14 (12-bit fields, always non-negative), then the three
	; signed Q4.8 gradients.
	move.l	(a2)+,d3			; w14: lvl_top<<12 | lvl_mid
	move.l	d3,d2
	lsr.l	#8,d2
	lsr.l	#4,d2
	move.l	d2,(a1)+			; 17: lvl_top, Q4.8
	andi.l	#$fff,d3
	move.l	d3,(a1)+			; 18: lvl_mid, Q4.8
	moveq	#2,d2
.ux_lgrad
	move.l	(a2)+,d3
	eor.l	d5,d3
	sub.l	d5,d3
	move.l	d3,(a1)+			; 19..21: dlvl_dx, dlvl_up, dlvl_low
	dbra	d2,.ux_lgrad
	dbra	d0,.dsp_cull_copy_output
	bra	.dsp_cull_unpack_done

	; Out of the unpack body on purpose -- see the note at the constants.
	; validate_span_record owns d0-d7, so the two sign-extension constants
	; are re-established before the body resumes.
.dsp_cull_validate
	move.l	-80(a1),d1			; global source index
	movem.l	d0/a2,-(sp)
	lea	-68(a1),a2			; the seventeen unpacked fields
	bsr	validate_span_record
	movem.l	(sp)+,d0/a2
	move.l	#$800,d7
	move.l	#$800000,d5
	lea	gpu_texture_meta_buffer,a0
	bra	.dsp_cull_no_validate

.dsp_cull_unpack_done
	move.l	a1,dsp_triangle_output_ptr
	move.l	dsp_triangle_chunk_survivors,d0
	add.l	d0,dsp_triangle_output_count

.dsp_cull_chunk_next
	; The pool bookkeeping advanced at launch time; loop while a chunk is
	; still computing on the DSP.
	tst.l	dsp_chunk_inflight
	bne	.dsp_cull_chunk
	moveq	#1,d0
	rts

.dsp_cull_failed
	moveq	#0,d0
	rts

; Convert dense survivor records into rasterizer packets: command, flat
; colour/page token, OT key and native texture page, then the seventeen
; span-setup fields verbatim
; (already sign-extended by the unpack).  No coordinate lookups, no stack
; juggling -- the record carries everything geometric.
build_gpu_shadow_packets
	lea	dsp_triangle_rx_buffer+8,a0
	move.l	gpu_packet_ptr,a1
	clr.l	dsp_packet_count_shadow
	move.l	dsp_triangle_output_count,d7
	beq	.build_gpu_packets_count
	subq.l	#1,d7
.build_gpu_packet
	move.l	(a0)+,d6			; global source triangle index
	move.l	(a0)+,d0			; average-z key
	move.l	(a0)+,d1			; flat shade level
	addq.l	#1,dsp_packet_count_shadow
	; Remember which source triangle this submit slot came from: the OT walk
	; later only knows the packet address, and the record wants the index.
	ifd	TREX_OCCL
	bsr	occl_note_source
	endc
	; TPage from the texture metadata.  For textured packets word 1 carries
	; the page-table token prepared once by dsp_build_triangle_stream.  The
	; face-colour table is touched only by the 136 genuinely flat polygons,
	; rather than by every textured survivor just to fetch a known zero.
	move.l	d6,d5
	lsl.l	#5,d5
	lea	gpu_texture_meta_buffer,a3
	adda.l	d5,a3
	move.l	28(a3),d5			; native TPAGE, retained in packet word 3

	tst.l	d5
	beq	.flat_gpu_shadow
	move.l	24(a3),d4			; page-table byte offset in high word
	move.l	#$34000000,d2
	bra	.gpu_command_done
.flat_gpu_shadow
	; The O3D's material word is the same 0x0020 for every polygon and cannot
	; tell the two untextured colour groups apart, so the PS1 RGB is reordered
	; into O3D order offline instead -- see tools/o3d2facecolors.js.
	move.l	d6,d4
	lsl.l	#2,d4
	lea	trex_face_colour_data,a2
	move.l	(a2,d4.l),d4			; native Falcon base colour
	move.l	#$30000000,d2
.gpu_command_done
	; Source identity is already host-resident in d6.  The offline sidecar is
	; deliberately NOT a DSP field: one byte lookup here marks packets whose
	; complete conservative UV footprint references non-zero palette words.
	; opaque_path_enabled is the equal-layout A/B gate; zero leaves every
	; packet and every pixel on the original flag-bearing longword path.
	tst.l	d5
	beq	.gpu_opaque_hint_done
	tst.l	opaque_path_enabled
	beq	.gpu_opaque_hint_done
	lea	trex_opaque_triangle_data,a2
	tst.b	(a2,d6.l)
	beq	.gpu_opaque_hint_done
	ori.l	#OPAQUE_PACKET_BIT,d2
.gpu_opaque_hint_done
	or.l	d1,d2
	move.l	d2,(a1)+			; w0 command | shade
	move.l	d4,(a1)+			; w1 flat colour / page-table token
	move.l	d0,(a1)+			; w2 average-z / OT key
	move.l	d5,(a1)+			; w3 native texture page
	; Copy the 22 already-expanded span/level longwords in two MOVEM blocks.
	; A0/A1 and the outer DBRA counter D7 are deliberately excluded.
	movem.l	(a0)+,d0-d6/a2-a6		; 12 longwords
	movem.l	d0-d6/a2-a6,(a1)
	lea	48(a1),a1
	movem.l	(a0)+,d0-d6/a2-a4		; 10 longwords
	movem.l	d0-d6/a2-a4,(a1)
	lea	64(a1),a1			; 10 written + the 6 resolve slots
	dbra	d7,.build_gpu_packet
.build_gpu_packets_count
	move.l	dsp_packet_count_shadow,ot_primitive_count
	move.l	a1,gpu_packet_ptr
	rts

; -----------------------------------------------------------------------------
; Span-record validation.  For every survivor the DSP now ships the fifteen
; span-setup fields; this routine recomputes each one from the projected
; vertices and the texture metadata with the host's own arithmetic -- the
; same formulas rasterize_packet uses -- and compares them EXACTLY.  Field
; semantics and order are the SPAN_REC_* constants.  The rasterizer keeps
; consuming its own setup until this comparison has been clean over full
; revolutions (OPTIMIZATION.md 9.2).
;
; In: D1 = global source triangle index, A2 -> the fifteen record fields.
; Preserves all registers.
; -----------------------------------------------------------------------------
compute_span_reference
	; Fill val_ref[0..16] with the host-computed span-setup fields for
	; source triangle D1, exactly as the record consumer needs them.
	; Returns D0=1, or D0=0 for a degenerate zero-cross triangle with
	; val_ref undefined.  Shared by the validator, which compares the
	; result against the DSP record, and by the host fallback stream,
	; which emits it as the record.  Preserves everything but D0.
	movem.l	d1-d7/a0-a6,-(sp)

	; Vertex indices from the host copy of the triangle stream.
	move.l	d7,d0
	lsl.l	#4,d0
	lea	dsp_triangle_tx_buffer+8,a0
	adda.l	d0,a0
	move.l	(a0)+,d0			; i0
	bsr	load_projected_xy
	move.l	d0,val_x0
	move.l	d1,val_y0
	move.l	(a0)+,d0			; i1
	bsr	load_projected_xy
	move.l	d0,val_x1
	move.l	d1,val_y1
	move.l	(a0)+,d0			; i2
	bsr	load_projected_xy
	move.l	d0,val_x2
	move.l	d1,val_y2

	; UV bytes from the metadata record, masked exactly like the upload.
	move.l	d7,d0
	lsl.l	#5,d0
	lea	gpu_texture_meta_buffer,a0
	adda.l	d0,a0
	move.l	(a0)+,d0
	andi.l	#$ff,d0
	move.l	d0,val_u0
	move.l	(a0)+,d0
	andi.l	#$ff,d0
	move.l	d0,val_v0
	move.l	(a0)+,d0
	andi.l	#$ff,d0
	move.l	d0,val_u1
	move.l	(a0)+,d0
	andi.l	#$ff,d0
	move.l	d0,val_v1
	move.l	(a0)+,d0
	andi.l	#$ff,d0
	move.l	d0,val_u2
	move.l	(a0)+,d0
	andi.l	#$ff,d0
	move.l	d0,val_v2

	; BLE-stable sort by Y, carrying x, u and v -- the DSP mirrors this
	; compare/swap structure exactly, ties included.
	move.l	val_y0,d0
	cmp.l	val_y1,d0
	ble	.val_sort_01_ok
	move.l	val_y1,d1
	move.l	d0,val_y1
	move.l	d1,val_y0
	move.l	val_x0,d0
	move.l	val_x1,d1
	move.l	d1,val_x0
	move.l	d0,val_x1
	move.l	val_u0,d0
	move.l	val_u1,d1
	move.l	d1,val_u0
	move.l	d0,val_u1
	move.l	val_v0,d0
	move.l	val_v1,d1
	move.l	d1,val_v0
	move.l	d0,val_v1
.val_sort_01_ok
	move.l	val_y1,d0
	cmp.l	val_y2,d0
	ble	.val_sort_12_ok
	move.l	val_y2,d1
	move.l	d0,val_y2
	move.l	d1,val_y1
	move.l	val_x1,d0
	move.l	val_x2,d1
	move.l	d1,val_x1
	move.l	d0,val_x2
	move.l	val_u1,d0
	move.l	val_u2,d1
	move.l	d1,val_u1
	move.l	d0,val_u2
	move.l	val_v1,d0
	move.l	val_v2,d1
	move.l	d1,val_v1
	move.l	d0,val_v2
.val_sort_12_ok
	move.l	val_y0,d0
	cmp.l	val_y1,d0
	ble	.val_sort_done
	move.l	val_y1,d1
	move.l	d0,val_y1
	move.l	d1,val_y0
	move.l	val_x0,d0
	move.l	val_x1,d1
	move.l	d1,val_x0
	move.l	d0,val_x1
	move.l	val_u0,d0
	move.l	val_u1,d1
	move.l	d1,val_u0
	move.l	d0,val_u1
	move.l	val_v0,d0
	move.l	val_v1,d1
	move.l	d1,val_v0
	move.l	d0,val_v1
.val_sort_done

	; References, in record-field order.
	lea	val_ref,a1
	move.l	val_y0,(a1)+			; 0: sy0
	move.l	val_y1,d2
	sub.l	val_y0,d2
	move.l	d2,(a1)+			; 1: rows_up
	move.l	val_y2,d3
	sub.l	val_y1,d3
	move.l	d3,(a1)+			; 2: rows_low
	move.l	d2,d4
	add.l	d3,d4				; d4 = dy_long

	; cross and the mid flag
	move.l	val_x1,d0
	sub.l	val_x0,d0
	muls.l	d4,d0
	move.l	val_x2,d1
	sub.l	val_x0,d1
	muls.l	d2,d1
	sub.l	d1,d0
	move.l	d0,val_cross
	beq	.compute_degenerate
	moveq	#0,d1
	tst.l	d0
	bge	.val_mid_ok
	moveq	#1,d1
.val_mid_ok
	move.l	d1,(a1)+			; 3: mid

	move.l	val_x0,d0
	moveq	#12,d5
	lsl.l	d5,d0
	move.l	d0,(a1)+			; 4: xl0

	move.l	val_x2,d0
	sub.l	val_x0,d0
	lsl.l	d5,d0
	divs.l	d4,d0
	move.l	d0,(a1)+			; 5: sl_long

	moveq	#0,d0
	tst.l	d2
	beq	.val_sl_up_done
	move.l	val_x1,d0
	sub.l	val_x0,d0
	lsl.l	d5,d0
	divs.l	d2,d0
.val_sl_up_done
	move.l	d0,(a1)+			; 6: sl_up

	moveq	#0,d0
	tst.l	d3
	beq	.val_sl_low_done
	move.l	val_x2,d0
	sub.l	val_x1,d0
	lsl.l	d5,d0
	divs.l	d3,d0
.val_sl_low_done
	move.l	d0,(a1)+			; 7: sl_low

	move.l	val_x1,d0
	lsl.l	d5,d0
	move.l	d0,(a1)+			; 8: x1r

	; du/dx and dv/dx: barycentric over the sorted cross.
	move.l	val_y1,d5
	sub.l	val_y2,d5			; k0
	move.l	val_y0,d6
	sub.l	val_y1,d6			; k2
	move.l	val_u0,d0
	muls.l	d5,d0
	move.l	val_u1,d1
	muls.l	d4,d1
	add.l	d1,d0
	move.l	val_u2,d1
	muls.l	d6,d1
	add.l	d1,d0
	lsl.l	#8,d0
	divs.l	val_cross,d0
	move.l	d0,(a1)+			; 9: du_dx
	move.l	val_v0,d0
	muls.l	d5,d0
	move.l	val_v1,d1
	muls.l	d4,d1
	add.l	d1,d0
	move.l	val_v2,d1
	muls.l	d6,d1
	add.l	d1,d0
	lsl.l	#8,d0
	divs.l	val_cross,d0
	move.l	d0,(a1)+			; 10: dv_dx

	; Left-chain UV steps with the uniform up/low semantics.
	move.l	val_ref+12,d0			; mid flag
	bne	.val_chain_left
	move.l	val_u2,d0
	sub.l	val_u0,d0
	lsl.l	#8,d0
	divs.l	d4,d0
	move.l	d0,(a1)+			; 11: dul_up
	move.l	d0,val_chain_tmp
	move.l	val_v2,d0
	sub.l	val_v0,d0
	lsl.l	#8,d0
	divs.l	d4,d0
	move.l	d0,(a1)+			; 12: dvl_up
	move.l	val_chain_tmp,d1
	move.l	d1,(a1)+			; 13: dul_low
	move.l	d0,(a1)+			; 14: dvl_low
	bra	.val_uvrefs
.val_chain_left
	moveq	#0,d0
	moveq	#0,d1
	tst.l	d2
	beq	.val_cl_up_done
	move.l	val_u1,d0
	sub.l	val_u0,d0
	lsl.l	#8,d0
	divs.l	d2,d0
	move.l	val_v1,d1
	sub.l	val_v0,d1
	lsl.l	#8,d1
	divs.l	d2,d1
.val_cl_up_done
	move.l	d0,(a1)+			; 11: dul_up
	move.l	d1,(a1)+			; 12: dvl_up
	moveq	#0,d0
	moveq	#0,d1
	tst.l	d3
	beq	.val_cl_low_done
	move.l	val_u2,d0
	sub.l	val_u1,d0
	lsl.l	#8,d0
	divs.l	d3,d0
	move.l	val_v2,d1
	sub.l	val_v1,d1
	lsl.l	#8,d1
	divs.l	d3,d1
.val_cl_low_done
	move.l	d0,(a1)+			; 13: dul_low
	move.l	d1,(a1)+			; 14: dvl_low

.val_uvrefs
	; Sorted top and middle vertex UV bytes, u|v<<8, matching the record's
	; two start-value words.
	move.l	val_v0,d0
	lsl.l	#8,d0
	or.l	val_u0,d0
	move.l	d0,(a1)+			; 15: uv0 pack
	move.l	val_v1,d0
	lsl.l	#8,d0
	or.l	val_u1,d0
	move.l	d0,(a1)+			; 16: uv1 pack

	movem.l	(sp)+,d1-d7/a0-a6
	moveq	#1,d0
	rts
.compute_degenerate
	movem.l	(sp)+,d1-d7/a0-a6
	moveq	#0,d0
	rts

; In: D1 = global source triangle index, A2 -> the seventeen UNPACKED record
; fields (already sign-extended by the chunk unpack).  Recomputes every field
; via compute_span_reference and compares EXACTLY -- which validates the
; DSP arithmetic and the wire pack/unpack round trip in one stroke.
; Preserves all registers.
validate_span_record
	movem.l	d0-d7/a0-a6,-(sp)
	move.l	d1,d7				; source index
	move.l	a2,a6				; record fields
	addq.l	#1,val_records
	bsr	compute_span_reference
	tst.l	d0
	bne	.val_compare
	; The DSP sent a record for a triangle the host calls degenerate --
	; that is itself a mismatch worth counting.
	addq.l	#1,val_mismatch_total
	bra	.val_record_done

.val_compare
	; Field-for-field exact comparison against the unpacked record.
	lea	val_ref,a0
	moveq	#0,d5				; field index
.val_compare_loop
	move.l	d5,d0
	lsl.l	#2,d0
	move.l	(a6,d0.l),d1			; unpacked record field
	move.l	(a0,d0.l),d2			; host reference
	cmp.l	d2,d1
	beq	.val_field_ok
	addq.l	#1,val_mismatch_total
	lea	val_field_counts,a2
	addq.l	#1,(a2,d0.l)
	tst.l	val_first_captured
	bne	.val_field_ok
	move.l	#1,val_first_captured
	move.l	frame_number,val_first_frame
	move.l	d7,val_first_tri
	move.l	d5,val_first_field
	move.l	d2,val_first_host
	move.l	d1,val_first_dsp
.val_field_ok
	addq.l	#1,d5
	cmpi.l	#17,d5
	blt	.val_compare_loop
.val_record_done
	movem.l	(sp)+,d0-d7/a0-a6
	rts

; Input d0 = vertex index.  Output d0 = projected x, d1 = projected y.
load_projected_xy
	lsl.l	#4,d0				; four longwords per DSP vertex record
	lea	dsp_vertex_rx_buffer+8,a2
	adda.l	d0,a2
	move.l	(a2),d0
	move.l	4(a2),d1
	rts

; Input d0 = vertex index.  Output d0 = projected camera-space z.
load_projected_z
	lsl.l	#4,d0
	lea	dsp_vertex_rx_buffer+8,a2
	adda.l	d0,a2
	move.l	8(a2),d0
	rts

; Read one big-endian 16-bit value from the embedded O3D stream.
read_be_word
	moveq	#0,d0
	move.b	(a0)+,d0
	lsl.l	#8,d0
	moveq	#0,d1
	move.b	(a0)+,d1
	or.l	d1,d0
	rts

; Safe stand-in for a host-port write retained for diagnostics.
dsp_write_host_shadow
	move.l	d0,dsp_host_tx_shadow
	addq.l	#1,dsp_word_count
	rts

; -----------------------------------------------------------------------------
; Dummy GPU interface
; -----------------------------------------------------------------------------

gpu_open
	addq.l	#1,gpu_call_count
	move.l	#1,gpu_state
	lea	gpu_packet_buffer,a0
	move.l	a0,gpu_packet_ptr

	; A colour-capable monitor is the only prerequisite left: the mode itself
	; is built from Videl registers below, so neither Vsetmode (which has a
	; known TOS 4.02 issue from ST compatibility) nor VsetScreen is involved
	; any more.  Montype 2 is VGA, everything else non-negative gets the
	; RGB/TV timing.
	Montype
	move.w	d0,video_monitor_type_shadow
	tst.w	d0
	bmi	.gpu_video_unavailable

	; Own the screen instead of borrowing the desktop's: TOS's screen is only
	; as large as the desktop's own mode, and presenting into it ran past its
	; end and halted the machine.  The buffer below is static ST-RAM (BSS of a
	; normally-loaded .TOS), which is what Videl can DMA from, and is aligned
	; to 256 bytes for the video base register.
	lea	screen_buffer_raw,a0
	move.l	a0,d0
	add.l	#SCREEN_ALIGN-1,d0
	andi.l	#$ffffff00,d0
	move.l	d0,video_screen_base
	add.l	#SCREEN_BUFFER_BYTES,d0
	move.l	d0,video_back_base

	; Remember where TOS was pointing so gpu_close can hand it back.  TOS's
	; own screen sysvars are never changed -- nothing here goes through the
	; XBIOS -- so only the three base registers need restoring; the logical
	; base is recorded for diagnostics and has no counterpart in gpu_close.
	;
	; Do not "clean up" the Logbase call: dropping its eight bytes shifts the
	; text section and cost 28.1 ms per frame in the rasterizer at a
	; byte-identical image (section 2 of OPTIMIZATION.md).
	Physbase
	move.l	d0,video_old_physbase
	Logbase
	move.l	d0,video_old_logbase
	bsr	video_save_registers

	; Wipe both buffers once, before Videl is pointed at either.  The
	; renderer only ever writes its 240x224 window, so whatever the buffers
	; held would otherwise stay visible as a frame around the render target.
	; The two are contiguous, so this is one linear clear.  DBRA cannot count
	; 57,344 longwords, hence the 32-bit loop.
	move.l	video_screen_base,a0
	move.l	#((2*SCREEN_BUFFER_BYTES)/4),d0
	moveq	#0,d1
.gpu_clear_screen_buffers
	move.l	d1,(a0)+
	subq.l	#1,d0
	bne	.gpu_clear_screen_buffers

	; Both buffers are provably background now, so both delta-clear band
	; tables are empty.  They already assemble as DC_EMPTY in the data
	; section, which is what makes a cold start correct with no runtime
	; preparation at all; this repeats it so a warm restart -- the same
	; loaded image entered a second time -- cannot inherit the previous
	; run's dirty list and skip a band that is no longer background.
	; 56 stores, once per program run.
	lea	dc_band_table,a0
	move.l	#DC_EMPTY,d1
	moveq	#(DC_BANDS*2)-1,d0
.gpu_clear_band_tables
	move.l	d1,(a0)+
	dbra	d0,.gpu_clear_band_tables


	; Window origin inside the back buffer.
	move.l	video_back_base,d0
	add.l	#RENDER_WINDOW_OFFSET,d0
	move.l	d0,render_base

	; In Falcon true-colour mode (>8bpp) Videl takes the border colour from
	; palette register 0 of the EXTENDED Falcon CLUT at $ffff9800 (a
	; longword: R in byte 0, G in byte 1, B in byte 3) -- NOT from the STE
	; register at $ff8240, which true-colour modes never read back (see
	; Hatari's VIDEL_UpdateColors, videl.c).  The desktop leaves it light
	; grey.  The frame around the display is not ours to draw into, so this
	; is the only way to blacken it.  video_restore_registers puts the old
	; value back.
	clr.l	$ffff9800.w

	move.l	video_screen_base,d0
	bsr	video_set_base

	; --- monitor-specific Videl timing, from snowbros (see the constants) ---
	cmpi.w	#2,video_monitor_type_shadow
	beq	.gpu_set_vga_mode

	; RGB/TV: 256x224 true colour, 50.0 Hz, 15625 Hz.  25.175 MHz clock at
	; 4 cycles/pixel (divider 4), which is what makes the 256 pixels cover
	; the width the old mode's 320 did.
	move.l	#$c70076,$ffff8282.w		; HHT=$0c7  HBB=$076
	move.l	#$3f001e,$ffff8286.w		; HBE=$03f  HDB=$01e (=HBE-33)
	move.l	#$7600ab,$ffff828a.w		; HDE=$076  HSS=$0ab
	move.l	#$271021f,$ffff82a2.w		; VFT=$271  VBB=$21f
	move.l	#$5f005f,$ffff82a6.w		; VBE=$05f  VDB=$05f
	move.l	#$21f026b,$ffff82aa.w		; VDE=$21f  VSS=$26b
	move.w	#$200,$ffff820a.w		; 50 Hz
	move.w	#$185,$ffff82c0.w		; 64-cyc offset, 32-bit bus, 25.175 MHz, RGB
	move.w	#$0,d0				; 4 cycles/pixel, no interlace/doubling
	bra	.gpu_videl_common

.gpu_set_vga_mode
	; VGA (31 kHz monitor): the same 256x224, with each of the 224 lines
	; drawn twice to fill the taller VGA frame ($82c2 bit 0) and 2
	; cycles/pixel off the 32 MHz clock for the same wide pixels.  4
	; cycles/pixel here halved the VGA sync to ~15.8 kHz/30 Hz.
	move.l	#$fc00a9,$ffff8282.w		; HHT=$0fc  HBB=$0a9
	move.l	#$2502f3,$ffff8286.w		; HBE=$025  HDB=$2f3
	move.l	#$a800c0,$ffff828a.w		; HDE=$0a8  HSS=$0c0
	move.l	#$41903cf,$ffff82a2.w		; VFT=$419  VBB=$3cf
	move.l	#$4d004b,$ffff82a6.w		; VBE=$04d  VDB=$04b
	move.l	#$3cb0415,$ffff82aa.w		; VDE=$3cb  VSS=$415
	move.w	#$200,$ffff820a.w
	move.w	#$182,$ffff82c0.w		; 64-cyc offset, 32-bit bus, 32 MHz (bit2=0), VGA
	move.w	#$5,d0				; 2 cycles/pixel, doubled lines

.gpu_videl_common
	; $8266 is cleared first because Videl re-derives the mode from it on the
	; write, which is also how TOS's own Vsetmode sequences it.
	clr.w	$ffff8266.w
	move.w	#$100,$ffff8266.w		; true colour on
	move.w	d0,$ffff82c2.w
	move.w	#VIDEO_LINE_WIDTH,$ffff8210.w
	move.w	#VIDEO_LINE_OFFSET,$ffff820e.w

	move.l	#1,video_mode_active
	bra	.gpu_open_done
.gpu_video_unavailable
	clr.l	video_mode_active
.gpu_open_done
	rts

gpu_close
	addq.l	#1,gpu_call_count
	tst.l	video_mode_active
	beq	.gpu_close_no_video
	bsr	video_restore_registers
	clr.l	video_mode_active
.gpu_close_no_video
	clr.l	gpu_state
	rts

; -----------------------------------------------------------------------------
; Videl register ownership
;
; Every register the mode setup writes is saved here and written back by
; gpu_close, in the reverse order.  TOS is never told about any of it, so its
; idea of the video mode still matches what these registers held on entry --
; which is the whole point: the desktop comes back exactly as it was, instead
; of at the demo's resolution as it did while the mode came from VsetScreen
; (TOS 4.02 reports no previous mode, and Vsetmode #-1 double bus errors).
; -----------------------------------------------------------------------------

video_save_registers
	move.b	$ffff8260.w,video_save_st_shift
	move.w	$ffff8266.w,video_save_spshift
	move.w	$ffff820a.w,video_save_sync
	move.l	$ffff820e.w,video_save_offset_width	; $820e offset, $8210 width
	move.l	$ffff8264.w,video_save_hscroll
	movem.l	$ffff8282.w,d0-d3
	movem.l	d0-d3,video_save_htiming
	movem.l	$ffff82a2.w,d0-d3
	movem.l	d0-d3,video_save_vtiming
	move.l	$ffff82c0.w,video_save_control		; $82c0 control, $82c2 mode
	move.l	$ffff9800.w,video_old_border
	rts

video_restore_registers
	move.l	video_old_border,$ffff9800.w
	movem.l	video_save_htiming,d0-d3
	movem.l	d0-d3,$ffff8282.w
	movem.l	video_save_vtiming,d0-d3
	movem.l	d0-d3,$ffff82a2.w
	move.l	video_save_control,$ffff82c0.w
	move.l	video_save_hscroll,$ffff8264.w
	move.l	video_save_offset_width,$ffff820e.w
	clr.w	$ffff8266.w
	move.w	video_save_spshift,$ffff8266.w
	move.b	video_save_st_shift,$ffff8260.w
	move.w	video_save_sync,$ffff820a.w
	move.l	video_old_physbase,d0
	bra	video_set_base

; Point Videl at the buffer in d0.  Clobbers d0.
video_set_base
	move.b	d0,$ffff820d.w			; bits 7..0
	lsr.l	#8,d0
	move.b	d0,$ffff8203.w			; bits 15..8
	lsr.l	#8,d0
	move.b	d0,$ffff8201.w			; bits 23..16
	rts

gpu_clear_ot
	addq.l	#1,gpu_call_count
	lea	ordering_table,a0
	moveq	#0,d0
	move.w	#OT_LENGTH-1,d1
.clear_loop
	move.l	d0,(a0)+
	dbra	d1,.clear_loop
	clr.l	gpu_ot_node_count

	; Clear the 16-bit offscreen target used by the Falcon scanline backend.
	; This is the whole clear now: visibility is PS1-style painter's order
	; through the Ordering Table, so there is no Z-buffer to wipe -- that
	; used to be two thirds of this stage's memory traffic.
	;
	; Both arms are assembled; delta_clear_enabled picks one.  With the flag
	; off the delta path costs exactly one tst.l and one untaken branch per
	; frame, and the full-clear text below is byte-for-byte the loop that
	; shipped before -- same registers, same counters, same shape -- so the
	; off arm is the old behaviour and not merely an equivalent of it.
	tst.l	delta_clear_enabled
	bne	.clear_delta

	move.l	render_base,a0
	moveq	#0,d0
	move.w	#SCREEN_HEIGHT-1,d2
.clear_framebuffer_row
	move.w	#(SCREEN_WIDTH/2)-1,d1
.clear_framebuffer_loop
	move.l	d0,(a0)+
	dbra	d1,.clear_framebuffer_loop
	adda.l	#(VIDEO_SCREEN_STRIDE-(SCREEN_WIDTH*2)),a0
	dbra	d2,.clear_framebuffer_row
	bra	.clear_fb_done
.clear_delta
	bsr	delta_clear_bands

.clear_fb_done
	; The owner-id bitmap shadows the same window and needs the same wipe:
	; without it the previous frame's ranks survive under this frame's
	; background and every visibility count is wrong.
	;
	; It stays a FULL clear on purpose, in both arms.  -DTREX_OCCL is a
	; layout-foreign binary no timing is ever quoted from, and a completely
	; wiped owner bitmap keeps every future occlusion count valid no matter
	; what the colour clear does; a second delta mechanism here would only add
	; a way to be silently wrong.  Consequence to remember when reading an
	; occlusion run: its t_clear shows the delta saving only by half.
	ifd	TREX_OCCL
	bsr	occl_clear_owner
	endc
	rts

; -----------------------------------------------------------------------------
; Delta clear: wipe only the bands this buffer was drawn into last time.
;
; "Last time" is two frames ago under the page flip, which is exactly why the
; band table is double-buffered.  The page is derived from render_base rather
; than from a frame parity counter: gpu_present_frame only swaps when
; present_enabled AND video_mode_active are both set, so a parity counter would
; be wrong in every configuration that renders single-buffered, while reading
; the actual base is right in both.  It is the same derivation
; occl_write_frame_dump uses to name its buffer half; a single btst will not do
; because SCREEN_BUFFER_BYTES ($1c000) is not a one-bit mask.
;
; The derivation runs once per frame and lands in dc_table_base, which the
; rasterizer's bookkeeping then reads.  Clear and rasterizer therefore cannot
; disagree about which page they are on.
;
; Each band is emptied in the SAME pass that reads it -- the DC_EMPTY store
; sits ahead of every path that skips the wipe -- so no band can be marked
; dirty by frame N, skipped as empty, and left unwiped for frame N+2.
;
; Alignment: render_base is the 256-aligned buffer plus RENDER_WINDOW_OFFSET
; (16), so it is longword aligned; the left column is rounded down to an even
; pixel, making its byte offset a multiple of four.  Every store below is an
; aligned longword, exactly like the full clear's.
;
; Clobbers d0 and a0 like the full clear did; d1-d7/a1-a2 are saved because
; gpu_clear_ot's callers were only ever promised d0-d2/a0.  One movem pair per
; frame is unmeasurable and cheaper than re-auditing the frame loop the next
; time it changes.
delta_clear_bands
	movem.l	d1-d7/a1-a2,-(sp)
	move.l	render_base,d0
	sub.l	#screen_buffer_raw,d0
	lea	dc_band_table,a1
	cmpi.l	#SCREEN_BUFFER_BYTES,d0
	bcs	.dcb_page0
	lea	DC_PAGE_BYTES(a1),a1
.dcb_page0
	move.l	a1,dc_table_base		; the rasterizer marks into this page
	move.l	render_base,a0			; row 0 of band 0
	moveq	#0,d0				; fill value
	move.w	#DC_BANDS-1,d2
.dcb_band
	move.w	(a1),d3				; xmin, floored, unclamped
	move.w	2(a1),d4			; xmax, floored, unclamped
	move.l	#DC_EMPTY,(a1)+			; empty it in the same pass
	addq.w	#1,d4				; conservative right edge: floor+1
	tst.w	d3
	bge	.dcb_lo
	moveq	#0,d3
.dcb_lo
	cmpi.w	#SCREEN_WIDTH-1,d4
	ble	.dcb_hi
	move.w	#SCREEN_WIDTH-1,d4
.dcb_hi
	; An empty band arrives as xmin=240, right edge -32767 and fails here;
	; so does any band whose extent lies wholly off one side of the window.
	cmp.w	d3,d4
	blt	.dcb_next
	andi.w	#$fffe,d3			; round out to whole longwords
	ori.w	#1,d4
	move.l	a0,a2
	move.w	d3,d5
	add.w	d5,d5
	adda.w	d5,a2				; first pixel of the band's first row
	; Zero d6 whole, not just its low word: the count leaves this register
	; as a LONGWORD addend below, and the word arithmetic in between never
	; touches the upper half.
	moveq	#0,d6
	move.w	d4,d6
	sub.w	d3,d6
	addq.w	#1,d6
	lsr.w	#1,d6				; longwords per row, always >= 1
	; The row loop below runs DC_BAND_ROWS times, so a band writes eight
	; times this count.  Accounting for one row here made the measurement
	; field exactly a factor of eight too small -- and gate G5, which reads
	; it as the cleared area, would have failed on a correct clear.  d5 is
	; dead from here until .dcb_row reloads it.
	move.l	d6,d5
	lsl.l	#3,d5				; * DC_BAND_ROWS
	add.l	d5,dc_clear_longwords		; measurement field, cumulative
	move.w	d6,d7
	lsl.w	#2,d7
	neg.w	d7
	add.w	#VIDEO_SCREEN_STRIDE,d7		; row remainder step, 32..508
	subq.w	#1,d6
	moveq	#DC_BAND_ROWS-1,d1
.dcb_row
	move.w	d6,d5
.dcb_lw
	move.l	d0,(a2)+
	dbra	d5,.dcb_lw
	adda.w	d7,a2
	dbra	d1,.dcb_row
.dcb_next
	adda.w	#DC_BAND_ROWS*VIDEO_SCREEN_STRIDE,a0
	dbra	d2,.dcb_band
	movem.l	(sp)+,d1-d7/a1-a2
	rts

; Safe GP0 shadow write.  No Falcon video register is touched here.
gpu_write_gp0_shadow
	move.l	d0,gpu_gp0_shadow
	addq.l	#1,gpu_word_count
	rts

gpu_upload_tim_shadow
	addq.l	#1,gpu_call_count
	move.l	texture_ptr_shadow,gpu_texture_ptr_shadow
	move.l	texture_length_shadow,gpu_texture_length_shadow
	bsr	gpu_prepare_texture_clut
	addq.l	#1,texture_page_count_shadow
	; Real version: issue GP0 image-load commands and copy the TIM/CLUT data
	; into PS1 VRAM.  The native TIM bytes are embedded below unchanged.
	rts

; Convert one native PS1 RGB555 CLUT into SHADE_LEVELS banks of Falcon RGB555X
; entries.  The low word is the Falcon framebuffer color; bit 16 preserves PS1
; STP and bit 17 marks a non-zero/valid PS1 palette word.  Keeping those two
; flags alongside the color lets the inner rasterizer use one longword lookup.
;
; The unscaled conversion lands in a scratch buffer and every bank is derived
; from it rather than re-running the PS1 channel arithmetic per level.
gpu_prepare_texture_clut
	movem.l	d0-d7/a0-a6,-(sp)
	move.l	texture_page_count_shadow,d0
	cmpi.l	#TIM_PAGE_COUNT,d0
	bcc	.gpu_prepare_texture_clut_done
	moveq	#16,d1				; * 64 KiB per page, too wide for MULU.W
	lsl.l	d1,d0
	lea	texture_page_falcon_clut_buffer,a1
	adda.l	d0,a1
	move.l	a1,gpu_clut_page_base
	lea	gpu_clut_unscaled,a1
	move.l	texture_ptr_shadow,a0
	lea	TIM_CLUT_DATA_OFFSET(a0),a0
	move.w	#(TIM_CLUT_ENTRIES-1),d7
.gpu_prepare_texture_clut_loop
	moveq	#0,d2
	move.w	(a0)+,d2			; original PS1 RGB555/STP word
	; TIM palette words are little-endian PS1 data; MOVE.W reads them
	; big-endian, so the two bytes must be swapped back.  The old per-pixel
	; path did this implicitly by reading the low byte first.
	ror.w	#8,d2
	moveq	#0,d4
	tst.w	d2
	beq	.gpu_prepare_texture_clut_no_valid
	ori.l	#$00020000,d4			; non-zero palette word
.gpu_prepare_texture_clut_no_valid
	move.l	d2,d3
	andi.l	#$00008000,d3
	beq	.gpu_prepare_texture_clut_no_stp
	ori.l	#$00010000,d4			; PS1 STP flag
.gpu_prepare_texture_clut_no_stp

	; R: PS1 bits 0..4 -> Falcon bits 11..15.
	move.l	d2,d5
	andi.l	#$0000001f,d5
	lsl.l	#8,d5
	lsl.l	#3,d5
	; G: PS1 bits 5..9 -> Falcon bits 6..10.
	move.l	d2,d6
	lsr.l	#5,d6
	andi.l	#$0000001f,d6
	lsl.l	#6,d6
	or.l	d6,d5
	; B: PS1 bits 10..14 -> Falcon bits 0..4.
	move.l	d2,d6
	lsr.l	#8,d6
	lsr.l	#2,d6
	andi.l	#$0000001f,d6
	or.l	d6,d5
	or.l	d4,d5
	move.l	d5,(a1)+
	dbra	d7,.gpu_prepare_texture_clut_loop

	; Derive every bank from the unscaled conversion.  Only the colour is
	; scaled: STP and validity describe the texel itself, not how brightly or
	; in what colour it is lit.
	moveq	#CLUT_BANK_COUNT-1,d7
.gpu_shade_bank_loop
	move.l	gpu_clut_page_base,a1
	move.l	d7,d0
	lsl.l	#8,d0
	lsl.l	#2,d0				; * TIM_FALCON_CLUT_PAGE_BYTES
	adda.l	d0,a1
	; Parallel flag-free word table for packets whose sidecar proves that the
	; validity branch can never fire.  It lives at the end of BSS so adding
	; 192 KiB does not move the pinned framebuffer, long CLUT, packet buffer,
	; or raster state.  Page stride is 32 KiB, bank stride 512 bytes.
	lea	texture_page_falcon_opaque_clut_buffer,a2
	move.l	texture_page_count_shadow,d0
	lsl.l	#8,d0
	lsl.l	#7,d0				; page * 32 KiB
	adda.l	d0,a2
	move.l	d7,d0
	lsl.l	#8,d0
	add.l	d0,d0				; bank * 512 bytes
	adda.l	d0,a2
	lea	gpu_clut_unscaled,a0
	move.w	#(TIM_CLUT_ENTRIES-1),d6
.gpu_shade_entry_loop
	move.l	(a0)+,d5
	move.l	d5,d0
	andi.l	#$0000ffff,d0
	move.l	d7,d1
	bsr	shade_falcon_color
	andi.l	#$0000ffff,d0
	andi.l	#$ffff0000,d5
	or.l	d5,d0
	move.l	d0,(a1)+
	move.w	d0,(a2)+			; exact RGB555X low word, no flags
	dbra	d6,.gpu_shade_entry_loop
	dbra	d7,.gpu_shade_bank_loop
.gpu_prepare_texture_clut_done
	movem.l	(sp)+,d0-d7/a0-a6
	rts

; D0 = Falcon RGB555X colour in the low word, D1 = shade level 0..SHADE_MAX.
; Returns the colour scaled by that level's brightness in D0.
;
; Falcon 16-bit is RRRRRGGG GGXBBBBB; bit 5 is the overlay bit and stays clear,
; exactly as in the PS1-to-Falcon conversion above.
;
; A channel that is non-zero in the texel stays non-zero at every shade level.
; The ramp starts at 7/16, so channel values 1 and 2 otherwise round down to 0,
; and a texel whose three channels all round away is stored as pure black --
; indistinguishable from the cleared framebuffer.  Those pixels read as holes in
; the model, worst where flat shading puts whole triangles on level 0 (the open
; mouth in the opening frames) and worst at distance, where the model is small
; enough for a few dozen such pixels to matter.  The floor costs nothing per
; pixel: it runs once per CLUT entry when the preshaded banks are built.
;
; Clobbers D1, D2, D3 and A4.
shade_falcon_color
	lea	shade_ramp_table,a4
	mulu.w	#6,d1				; three channel factors per bank
	adda.l	d1,a4

	; R: Falcon bits 11..15.
	move.l	d0,d2
	lsr.l	#8,d2
	lsr.l	#3,d2
	andi.l	#$1f,d2
	beq	.shade_red_ready		; black channel stays black
	mulu.w	(a4),d2
	lsr.l	#SHADE_RAMP_SHIFT,d2
	bne	.shade_red_ready
	moveq	#1,d2				; darkest visible instead of black
.shade_red_ready
	lsl.l	#8,d2
	lsl.l	#3,d2

	; G: Falcon bits 6..10.
	move.l	d0,d3
	lsr.l	#6,d3
	andi.l	#$1f,d3
	beq	.shade_green_ready
	mulu.w	2(a4),d3
	lsr.l	#SHADE_RAMP_SHIFT,d3
	bne	.shade_green_ready
	moveq	#1,d3
.shade_green_ready
	lsl.l	#6,d3
	or.l	d3,d2

	; B: Falcon bits 0..4.
	move.l	d0,d3
	andi.l	#$1f,d3
	beq	.shade_blue_ready
	mulu.w	4(a4),d3
	lsr.l	#SHADE_RAMP_SHIFT,d3
	bne	.shade_blue_ready
	moveq	#1,d3
.shade_blue_ready
	or.l	d3,d2

	move.l	d2,d0
	rts

gpu_submit_ot
	addq.l	#1,gpu_call_count
	TimeMark	stat_mark_otinsert
	move.l	#OT_LENGTH,ot_length_shadow
	lea	ordering_table,a0
	move.l	a0,gpu_submit_ptr_shadow
	lea	gpu_packet_buffer,a1
	lea	gpu_ot_node_buffer,a2
	move.l	dsp_packet_count_shadow,d7
	beq	.gpu_submit_ot_done
	move.l	d7,gpu_ot_node_count
	move.l	#OT_LENGTH-1,d2		; minimum touched bucket
	moveq	#0,d3				; maximum touched bucket
	subq.l	#1,d7

	; Build a conventional front-end OT.  The DSP returns the sum of the
	; projected Z values; shifting by OT_KEY_SHIFT gives useful buckets for the
	; current 240x224 camera range.  Values outside the 2048 buckets saturate.
.gpu_submit_ot_loop
	move.l	8(a1),d0			; packet word 2 = average-Z key
	tst.l	d0
	bmi	.gpu_ot_bucket_zero
	lsr.l	#OT_KEY_SHIFT,d0
	cmpi.l	#OT_LENGTH-1,d0
	bls	.gpu_ot_bucket_ready
	move.l	#OT_LENGTH-1,d0
	bra	.gpu_ot_bucket_ready
.gpu_ot_bucket_zero
	moveq	#0,d0
.gpu_ot_bucket_ready
	cmp.l	d2,d0
	bge	.gpu_ot_min_ready
	move.l	d0,d2
.gpu_ot_min_ready
	cmp.l	d3,d0
	ble	.gpu_ot_max_ready
	move.l	d0,d3
.gpu_ot_max_ready

	; a4 = &ordering_table[bucket], and each node stores
	; { packet pointer, next node pointer }.  The 68020+ scaled index folds
	; the old copy/shift/add sequence into one address calculation.
	lea	(0,a0,d0.l*4),a4
	move.l	(a4),d1			; previous head
	move.l	a1,(a2)
	move.l	d1,4(a2)
	move.l	a2,(a4)
	addq.l	#GPU_OT_NODE_BYTES,a2
	adda.l	#GPU_PACKET_BYTES,a1
	dbra	d7,.gpu_submit_ot_loop
	move.l	d2,gpu_ot_bucket_min
	move.l	d3,gpu_ot_bucket_max
.gpu_submit_ot_done
	TimeAdd	stat_mark_otinsert,stat_t_otinsert
	TimeMark	stat_mark_raster
	bsr	gpu_rasterize_ot
	TimeAdd	stat_mark_raster,stat_t_raster
	TimeMark	stat_mark_present
	; Keep this call site exactly one word-sized BSR in both release variants.
	; Diagnostic targets retain their original short BSR and byte layout.  The rasterizer is
	; below it in the text section and its instruction-cache phase is acutely
	; layout-sensitive; inserting a second release-only call here would move
	; the whole hot path.  The FPS entry draws, then tail-branches through the
	; normal presenter so the release still performs the same page flip.
	ifd	TREX_FPS
	bsr.w	gpu_draw_fps
	else
	ifd	TREX_RELEASE
	bsr.w	gpu_present_frame
	else
	bsr	gpu_present_frame
	endc
	endc
	TimeAdd	stat_mark_present,stat_t_present
	rts

; Show the 240x224 true-colour render target.  Both monitor types scan all
; 224 lines of the buffer, so the whole render target is displayed and there
; is nothing left to crop or shift -- the scan starts at the buffer itself.
gpu_present_frame
	; Page flip instead of a copy.  The frame was drawn straight into the back
	; buffer, so all that is left is to point Videl at it and swap the two.
	;
	; Videl latches the base at the start of the display period, so writing the
	; three registers mid-frame simply takes effect at the next VBL -- no wait
	; is needed, and none is taken: at well under 2 fps a vsync would idle away
	; more than the copy this replaces ever cost.  The next thing to touch the
	; released buffer is the clear, and a whole DSP frame transaction runs
	; before it, which is longer than a VBL period.
	; Remember what was just drawn before anything swaps, so the framebuffer
	; dump reads the finished frame rather than the next target.
	move.l	render_base,last_rendered_base

	tst.l	present_enabled
	beq	.gpu_present_done
	tst.l	video_mode_active
	beq	.gpu_present_done

	move.l	video_back_base,d0
	bsr	video_set_base

	; Swap: what was drawn is now shown, what was shown becomes the target.
	move.l	video_screen_base,d0
	move.l	video_back_base,d1
	move.l	d1,video_screen_base
	move.l	d0,video_back_base
	add.l	#RENDER_WINDOW_OFFSET,d0
	move.l	d0,render_base
.gpu_present_done
	rts

; Walk the OT from far to near and invoke the software triangle backend for
; every linked packet.  The packet/node format is deliberately independent of
; the eventual Videl presentation mode, so this can later be replaced by a
; blitter or a hardware-specific submitter.
gpu_rasterize_ot
	; PS1-style painter's order: the OT is walked from FAR to near and later
	; (nearer) packets overwrite earlier ones.  This is the entire visibility
	; model -- there is no Z-buffer -- and it is also the order that makes
	; destination-reading semitransparency correct once packets carry the GP0
	; blend bit $02000000.
	;
	; Within one bucket the node list is LIFO from gpu_submit_ot, so equal-
	; key triangles draw in reverse submission order: arbitrary but stable,
	; the same contract a real PS1 Ordering Table gives.
	;
	; The near-to-far walk this replaces was an early-out optimization
	; against the software depth buffer (981 vs 1299 ms in its day); without
	; a depth test it has no meaning.
	; Only the touched bucket interval can contain nodes.  The table is still
	; fully cleared for simple correctness, but the far-to-near walk skips the
	; hundreds or thousands of guaranteed-empty buckets outside that interval.
	tst.l	gpu_ot_node_count
	beq	.gpu_raster_ot_done
	; The bucket cursor walks in a2: rasterize_packet preserves a2/a3/d7
	; for its caller, so the node loop needs no per-packet save of its
	; own state.  a2 is otherwise dead here; one save per frame keeps the
	; caller's value.
	move.l	a2,-(sp)

	; ---- packet resolve pass -------------------------------------------
	; Classification, the page lookup, the CLUT/tint arithmetic and the
	; flat colour used to run inside rasterize_packet, whose text is
	; refetched once per packet (3.9b) -- every byte of them cost about
	; two cycles per packet.  This sweep does the same work for all
	; packets in one loop that stays inside the instruction cache and
	; parks the results in the packet's six resolve slots; the rasterizer
	; then loads them with one MOVEM.  Minority classes sit below the
	; DBRA, off the resident straight line.
	lea	gpu_packet_buffer,a1
	move.l	dsp_packet_count_shadow,d7
	subq.l	#1,d7
.gpu_resolve_packet
	move.l	(a1),d0				; command | shade
	move.l	d0,d5
	andi.l	#SHADE_PACKET_MASK,d5		; resolved shade
	move.l	d0,d1
	andi.l	#$ff000000,d1
	; Diagnostic: raster_force_flat renders every packet with the flat
	; colour, bypassing all texture handling.  Lets a broken texture path
	; be told apart from broken geometry.
	tst.l	raster_force_flat
	bne	.gpu_resolve_flat
	cmpi.l	#$34000000,d1
	bne	.gpu_resolve_flat
	move.l	4(a1),d6
	swap	d6				; byte offset into the page tables
	; Semi-transparency still wins outright: the opaque hint is host-only
	; and only valid for normal textured packets, and a future producer
	; that combines it with the GP0 bit must stay on the longword table
	; because bit 16 still selects blending there.
	move.l	d0,d1
	andi.l	#$02000000,d1			; GP0 semi-transparency command bit
	bne	.gpu_resolve_semi
	move.l	d0,d1
	andi.l	#OPAQUE_PACKET_BIT,d1
	beq	.gpu_resolve_tex
	; Qualified-opaque word CLUT, 88-95% of all packets (section 3.8).
	lea	texture_page_pixels_table,a4
	move.l	(0,a4,d6.l),d2			; texture base
	lea	texture_page_opaque_clut_table,a4
	move.l	(0,a4,d6.l),d3
	move.l	d5,d0
	andi.l	#$30,d0
	lsl.l	#8,d0
	add.l	d0,d0				; tint * 512-byte word banks
	add.l	d0,d3				; tint's bank-zero base
	lea	span_walk_half\.span_tex_opaque_loop,a4
	move.l	a4,d1
	moveq	#RASTER_LVL_SHIFT_WORD,d4
.gpu_resolve_store
	movem.l	d1-d5,GPU_PACKET_RESOLVE(a1)
	lea	GPU_PACKET_BYTES(a1),a1
	dbra	d7,.gpu_resolve_packet
	bra	.gpu_resolve_done

.gpu_resolve_semi
	lea	span_walk_half\.span_semi,a4
	bra	.gpu_resolve_long_clut
.gpu_resolve_tex
	lea	span_walk_half\.span_tex_loop,a4
.gpu_resolve_long_clut
	move.l	a4,d1
	lea	texture_page_pixels_table,a4
	move.l	(0,a4,d6.l),d2			; texture base
	lea	texture_page_clut_table,a4
	move.l	(0,a4,d6.l),d3
	move.l	d5,d0
	andi.l	#$30,d0
	lsl.l	#8,d0
	lsl.l	#2,d0				; tint * 1,024-byte long banks
	add.l	d0,d3
	moveq	#RASTER_LVL_SHIFT_LONG,d4
	bra	.gpu_resolve_store

.gpu_resolve_flat
	; The packet's own PS1 base colour, already converted to Falcon
	; RGB555X.  It is zero only for a textured packet, which lands here
	; just when the raster_force_flat diagnostic is on -- keep that one
	; visible.  The flat body reads neither texture base nor a real tint
	; base, so the shaded colour rides the tint slot.
	move.l	4(a1),d0
	andi.l	#$0000ffff,d0
	bne	.gpu_resolve_flat_shade
	move.l	#$07c0,d0			; green, diagnostic renders only
.gpu_resolve_flat_shade
	move.l	d5,d1
	bsr	shade_falcon_color		; d0 = shaded RGB, clobbers d1-d3/a4
	move.l	d0,d3				; flat colour in the tint slot
	moveq	#0,d2				; no texture base
	lea	span_walk_half\.span_flat,a4
	move.l	a4,d1
	moveq	#RASTER_LVL_SHIFT_LONG,d4
	bra	.gpu_resolve_store
.gpu_resolve_done

	lea	ordering_table,a2
	move.l	gpu_ot_bucket_max,d0
	addq.l	#1,d0
	lsl.l	#2,d0
	adda.l	d0,a2
	move.l	gpu_ot_bucket_max,d7
	sub.l	gpu_ot_bucket_min,d7		; DBRA count = range length - 1
.gpu_raster_ot_bucket
	move.l	-(a2),a1
.gpu_raster_ot_node
	tst.l	a1
	beq	.gpu_raster_ot_next_bucket
	move.l	4(a1),a3			; save next node across rasterize_packet
	move.l	(a1),a0			; A0 = packet
	; One draw rank per packet, in exactly this far-to-near walk order --
	; no reconstruction of the bucket or LIFO logic is needed anywhere.
	ifd	TREX_OCCL
	bsr	occl_begin_packet
	endc
	bsr	rasterize_packet
	ifd	TREX_OCCL
	bsr	occl_end_packet
	endc
	move.l	a3,a1
	bra	.gpu_raster_ot_node
.gpu_raster_ot_next_bucket
	dbra	d7,.gpu_raster_ot_bucket
	move.l	(sp)+,a2
.gpu_raster_ot_done
	rts

; A0 points at one 32-longword packet: command, flat colour/page token, OT
; key, native texture page, the twenty-two span/level fields the DSP
; computed, and the six resolve slots the per-frame resolve pass filled
; before this walk.  The span/level fields are what the host
; validated field-for-field (section 9.2).  The rasterizer derives nothing
; geometric any more -- no sort, no cross product, not a single division:
; it loads the chain state and walks the spans.  Producers guarantee
; non-degenerate records, so there is no area guard here either.
rasterize_packet
	move.l	d7,-(sp)
	move.l	a3,-(sp)
	move.l	a2,-(sp)			; span_walk_half keeps DDA state in a2/a3

	; Stash the packet pointer for the delta-clear bookkeeping at the end of
	; this routine.  A0 is DEAD by then: both lower-half paths call
	; span_walk_half without saving it and the walker overwrites it with
	; raster_du_dx -- the same trap occl_end_packet documents.  This one
	; store runs unconditionally, in both switch arms, so it counts against
	; the baseline as well and cannot flatter the A/B result.
	move.l	a0,dc_packet


	; Everything class-derivable arrived precomputed from the packet
	; resolve pass's cache-resident sweep (3.9c): span entry, texture
	; base, CLUT tint base -- a flat packet's shaded colour rides that
	; same slot, and each consumer reads only its own -- bank stride and
	; shade.  One MOVEM plus the cell stores replaces the parse, the
	; classification, the page lookup and the CLUT arithmetic that ran
	; here once per packet.
	movem.l	GPU_PACKET_RESOLVE(a0),d1-d5
	move.l	d1,raster_span_entry
	move.l	d2,a5
	move.l	d3,raster_clut_tint_base
	move.w	d3,raster_flat_color
	move.w	d4,raster_lvl_shift
	move.l	d5,raster_shade

	; -------------------------------------------------------------------
	; Chain state, consumed verbatim from the record fields.  All values
	; are host-validated equal to what the old in-place setup computed, so
	; the walk below produces byte-identical spans.
	; -------------------------------------------------------------------
	move.l	52(a0),raster_du_dx
	move.l	56(a0),raster_dv_dx
	move.l	84(a0),raster_lvl		; sorted top level, Q4.8

	move.l	32(a0),d1			; xl0, 12.12
	move.l	d1,raster_xl
	move.l	d1,raster_xr
	move.l	76(a0),d1			; top vertex u|v<<8
	moveq	#0,d0
	move.b	d1,d0
	lsl.l	#8,d0
	move.l	d0,raster_ul
	lsr.l	#8,d1
	andi.l	#$ff,d1
	lsl.l	#8,d1
	move.l	d1,raster_vl
	move.l	16(a0),d1			; sy0
	move.l	d1,raster_y_current
	; Y-clip decision for BOTH halves, once per packet: together they walk
	; exactly [sy0, sy0+rows_up+rows_low), so neither the top catch-up nor
	; the bottom shorten can fire when that interval lies inside
	; [0, SCREEN_HEIGHT].  sign(sy0 | (SCREEN_HEIGHT - y_end)) is negative
	; exactly when one of them must run; the walker then takes its
	; out-of-line clamp block, which is the old per-half code unchanged.
	move.l	20(a0),d0			; rows_up
	add.l	24(a0),d0			; + rows_low
	add.l	d1,d0				; = y_end, exclusive
	move.l	#SCREEN_HEIGHT,d2
	sub.l	d0,d2
	or.l	d1,d2
	move.l	d2,raster_walk_clip
	; FRAMEBUFFER_STRIDE is exactly 512.  Shift/add is the same four bytes as
	; the immediate multiply, preserves every following address, and removes
	; one CPU multiply per packet without adding a DSP protocol word.
	lsl.l	#8,d1
	add.l	d1,d1
	move.l	render_base,a4
	adda.l	d1,a4
	move.l	a4,raster_fb_row

	move.l	28(a0),d0			; mid flag
	bne	.raster_mid_left

	; ---- middle vertex on the RIGHT: the long edge is the left chain ----
	move.l	36(a0),raster_sl		; sl_long
	move.l	60(a0),raster_dul		; long-chain steps (both slots equal)
	move.l	64(a0),raster_dvl
	move.l	20(a0),d7			; rows_up
	beq	.raster_mr_lower		; flat top: no upper half
	move.l	40(a0),raster_sr		; sl_up
	move.l	96(a0),raster_dlvl		; level chain, upper
	move.l	d7,raster_rows
	move.l	a0,-(sp)
	ifd	TREX_PROFILE_NO_ROWS
	nop
	nop
	else
	bsr	span_walk_half
	endc
	move.l	(sp)+,a0
.raster_mr_lower
	; The right chain restarts at the middle vertex; everything on the
	; left -- position and UV -- continues along the long edge.
	move.l	24(a0),d7			; rows_low
	beq	.raster_packet_done		; flat bottom: no lower half
	move.l	48(a0),raster_xr		; x1r
	move.l	44(a0),raster_sr		; sl_low
	move.l	100(a0),raster_dlvl		; level chain, lower
	move.l	d7,raster_rows
	ifd	TREX_PROFILE_NO_ROWS
	nop
	nop
	else
	bsr	span_walk_half
	endc
	bra	.raster_packet_done

.raster_mid_left
	; ---- middle vertex on the LEFT: the long edge is the right chain ----
	move.l	36(a0),raster_sr		; sl_long
	move.l	20(a0),d7			; rows_up
	beq	.raster_ml_lower		; flat top: no upper half
	move.l	40(a0),raster_sl		; sl_up
	move.l	60(a0),raster_dul		; dul_up
	move.l	64(a0),raster_dvl
	move.l	96(a0),raster_dlvl		; level chain, upper
	move.l	d7,raster_rows
	move.l	a0,-(sp)
	ifd	TREX_PROFILE_NO_ROWS
	nop
	nop
	else
	bsr	span_walk_half
	endc
	move.l	(sp)+,a0
.raster_ml_lower
	; The left chain -- position AND UV -- restarts exactly at the middle
	; vertex; the right continues along the long edge.
	move.l	24(a0),d7			; rows_low
	beq	.raster_packet_done		; flat bottom: no lower half
	move.l	48(a0),raster_xl		; x1r
	move.l	80(a0),d1			; middle vertex u|v<<8
	moveq	#0,d0
	move.b	d1,d0
	lsl.l	#8,d0
	move.l	d0,raster_ul
	lsr.l	#8,d1
	andi.l	#$ff,d1
	lsl.l	#8,d1
	move.l	d1,raster_vl
	move.l	44(a0),raster_sl		; sl_low
	move.l	68(a0),raster_dul		; dul_low
	move.l	72(a0),raster_dvl
	move.l	88(a0),raster_lvl		; level restarts at the middle
	move.l	100(a0),raster_dlvl		; level chain, lower
	move.l	d7,raster_rows
	ifd	TREX_PROFILE_NO_ROWS
	nop
	nop
	else
	bsr	span_walk_half
	endc

.raster_packet_done
	; Delta-clear bookkeeping, once per packet -- never per span row.  The
	; full-mesh corpus is large enough that a per-row min/max would cost about
	; as much as the whole clear saves.
	; d7/a2/a3 are already on the stack and a5/a6 are finished with, so the
	; call may clobber d0-d7 and a0-a4 freely.
	tst.l	delta_clear_enabled
	beq	.raster_no_delta
	bsr	delta_mark_packet
.raster_no_delta
	move.l	(sp)+,a2
	move.l	(sp)+,a3
	move.l	(sp)+,d7
	rts

; -----------------------------------------------------------------------------
; Widen the band table by this packet's screen extent.  No multiply anywhere:
; every value needed is either a packet field or a DDA chain end the walk just
; left behind.
;
; X: the triangle's three corner columns are x0 (packet field xl0), x1 (packet
; field x1r) and x2, which is NOT in the packet -- but both DDA chains run to
; exactly x2, so raster_xl/raster_xr deliver it for free.  min/max over those
; four therefore encloses all three corners and all four segment ends, which is
; the whole triangle because xl and xr are linear within a segment.
;
; Under Y clipping it stays correct and only grows more conservative: a
; top-clipped triangle starts on the segment between xl0 and the segment end,
; both of which are in the set; a bottom-clipped one leaves the chains standing
; on the clip row, which is exactly as far as anything was drawn; a flat-bottom
; one ends a chain in the upper half, and x1r -- a real corner -- is in the set
; regardless.  When both halves clipped away entirely the row test below throws
; the packet out before a band index is ever formed, and raster_xl is still
; written by the top-clamp block in that case, so it is never garbage.
;
; Deliberate slack, NOT compensated: span_walk_half advances the chains once
; more after the last drawn row, so raster_xl/xr overshoot by one slope step --
; a pixel or two normally, more for a flat sliver with dy=1.  That is always
; conservative, so it can only over-clear, never leave a ghost.  Subtracting
; the step back would be wrong: after a lower half that Y-clipping emptied,
; raster_sl/sr in memory hold the slope that was never applied, and the box
; would come out too SMALL -- precisely the silent failure class this whole
; feature must not have.
;
; Y comes from the packet: y0 = sy0, y_end = sy0+rows_up+rows_low, clamped to
; 0..SCREEN_HEIGHT exactly the way span_walk_half clamps them.  Reading
; raster_y_current at the walker's entry and exit would be more exact but would
; run per HALF, up to 1,200 times a frame instead of 600.
;
; Clobbers d0-d4, a0, a1.
delta_mark_packet
	move.l	dc_packet,a0
	moveq	#12,d4
	move.l	32(a0),d0			; xl0 = sx0<<12, seeds the minimum
	move.l	d0,d1				;               and the maximum
	move.l	48(a0),d2			; x1r = sx1<<12
	cmp.l	d2,d0
	ble	.dm_min1
	move.l	d2,d0
.dm_min1
	cmp.l	d2,d1
	bge	.dm_max1
	move.l	d2,d1
.dm_max1
	move.l	raster_xl,d2			; left chain end = third corner
	cmp.l	d2,d0
	ble	.dm_min2
	move.l	d2,d0
.dm_min2
	move.l	raster_xr,d2			; right chain end
	cmp.l	d2,d1
	bge	.dm_max2
	move.l	d2,d1
.dm_max2
	asr.l	d4,d0				; floor to a pixel column
	asr.l	d4,d1				; floor too; the clear adds the +1
	move.l	16(a0),d2			; sy0, signed
	move.l	20(a0),d3			; rows_up
	add.l	24(a0),d3			; + rows_low
	add.l	d2,d3				; y_end, exclusive
	tst.l	d2
	bge	.dm_top_ok
	moveq	#0,d2
.dm_top_ok
	cmpi.l	#SCREEN_HEIGHT,d3
	blt	.dm_bot_ok
	move.l	#SCREEN_HEIGHT,d3
.dm_bot_ok
	subq.l	#1,d3				; last row, inclusive
	cmp.l	d2,d3
	blt	.dm_out				; nothing on screen
	lsr.l	#DC_BAND_SHIFT,d2		; first band (d2 is >= 0 by now)
	lsr.l	#DC_BAND_SHIFT,d3		; last band
	sub.l	d2,d3				; band count - 1
	lsl.l	#2,d2				; DC_ENTRY = 4 bytes per band
	move.l	dc_table_base,a1
	adda.l	d2,a1
.dm_band
	cmp.w	(a1),d0
	bge	.dm_band_lo
	move.w	d0,(a1)
.dm_band_lo
	cmp.w	2(a1),d1
	ble	.dm_band_hi
	move.w	d1,2(a1)
.dm_band_hi
	addq.l	#4,a1
	dbra	d3,.dm_band
.dm_out
	rts



; Walk raster_rows scanline spans from the DDA state in raster_xl/xr/sl/sr,
; raster_ul/vl/dul/dvl, raster_y_current and raster_fb_row.  The state is
; consumed and advanced in place, so the second trapezoid half continues
; exactly where the first stopped -- that continuity keeps the long-edge
; chain's rounding constant across the split.
;
; Clobbers d0-d7 and a0-a4.  a5 carries the texture page pointer through
; from the packet setup; a6 is the walker's own register -- the row
; prologue's bank select derives it from raster_clut_tint_base before any
; pixel body reads it, so packet setup leaves no value in it any more.
; a3 walks the left chain X and a2
; the framebuffer row, both loaded from and stored back to the raster_*
; state so the second trapezoid half still continues seamlessly.
; d7 accumulates this half's written
; pixels and lands on raster_pixel_count once at the end: one add per span
; plus one subtract per transparent texel replaces the absolute-address
; read-modify-write the pixel loops used to pay per written pixel.
; rasterize_packet reloads its row count after every call and restores the OT
; walker's d7 from the stack when the packet is done, so the clobber is safe.
span_walk_half
	moveq	#0,d7
	; Screen clipping in Y, decided once per packet: rasterize_packet's
	; sign flag says whether either clamp can fire for this packet's
	; interval, and the out-of-line block below .span_walk_empty then runs
	; the same checks and catch-up this entry always ran.  Neither clamp
	; runs for the current camera, but the walker must never scribble
	; outside the framebuffer.  The call sites' rows_up/rows_low tests
	; keep a zero row count off the hot path.
	tst.l	raster_walk_clip
	bmi	.span_y_clip
.span_y_ready
	; Row-persistent DDA state: the left chain X and the framebuffer row
	; live in a3/a2 for the whole half instead of taking a memory
	; read-modify-write per row each.  xr, the UV chain and the row count
	; stay in memory for want of spare registers.  y_current is never read
	; inside the loop, so the walked row count advances it once at the end.
	; Keep both X chains biased by 4095 while they live in registers.  Their
	; arithmetic is otherwise unchanged, but ceil(x) is then just an ASR #12;
	; the bias is removed before the state is written back for the next half
	; and for delta-clear bookkeeping.
	move.l	raster_xl,a3
	lea	4095(a3),a3
	move.l	raster_fb_row,a2
	move.l	raster_xr,d3
	add.l	#$00000fff,d3
	; du/dx and dv/dx do not change inside a packet.  Out here they cost the
	; row loop nothing; inside it they were two absolute-long reads per row.
	move.l	raster_du_dx,a0
	move.l	raster_dv_dx,a1
	; A flat build has no per-row level, and the bank select below is no
	; longer a branch.  Give it the packet's own level and a zero step, so it
	; reproduces on every row exactly the single fixed bank rasterize_packet
	; would have left in a6.  Runs once per half, never per row.
	tst.l	gouraud_enabled
	bne	.span_level_live
	move.l	raster_shade,d0
	andi.l	#$0f,d0
	lsl.l	#8,d0
	move.l	d0,raster_lvl
	clr.l	raster_dlvl
.span_level_live
	move.l	raster_rows,-(sp)

.span_row_loop
	; Integer span from the 12.12 chain positions: left is ceil(xl) and
	; right is ceil(xr)-1.  Right-exclusive, like the PS1 GPU: a pixel
	; exactly on the right edge belongs to the neighbour.
	move.l	a3,d0
	asr.l	#8,d0
	asr.l	#4,d0
	move.l	d3,d1
	asr.l	#8,d1
	asr.l	#4,d1
	subq.l	#1,d1

	; U/V at the span start, Q8.8 from the left chain.  The chain carries the
	; value at the un-snapped position XL, but the first texel is sampled at
	; ceil(XL), so step U/V over that fraction of a pixel first.  Without the
	; prestep the sample sits up to one full DU/DX away, and DU/DX is several
	; texels per pixel on a thin, heavily minified triangle: the walk leaves
	; the polygon's own patch in the texture atlas and picks up whatever is
	; next door.  The product exceeds 32 bits for such slivers, but sampling
	; only ever reads bits 8-15 of the Q8.8 sum (the pixel loops mask v to
	; $ff00 and shift u's bits 8-15 down) and everything downstream of this
	; sum is an addition, so congruence mod 2^16 is all that has to
	; survive.  muls.l's single longword is the product mod 2^32, and the
	; carry bits the >>12 discards against the retired 64-bit sequence are
	; multiples of 2^20 -- zero mod 2^16.  The sampled texel is therefore
	; bit-identical; fb.res of the frame-100 close-up gates that claim.
	; d3 keeps the biased right chain, d4 is free until the span length below.
	move.l	raster_ul,d5
	move.l	raster_vl,d6
	; With A3 holding xl+4095, the prestep fraction is the 12-bit
	; complement of A3's fractional part: 4095-((xl+4095)&4095).
	move.l	a3,d2
	not.l	d2
	andi.l	#$00000fff,d2			; 0 <= fraction < 4096
	beq	.span_prestep_done		; span starts on a pixel boundary
	move.l	a0,d4
	muls.l	d2,d4				; fraction * du/dx mod 2^32
	asr.l	#8,d4
	asr.l	#4,d4				; product >> 12, bits 0-19 exact
	add.l	d4,d5
	move.l	a1,d4
	muls.l	d2,d4
	asr.l	#8,d4
	asr.l	#4,d4
	add.l	d4,d6
.span_prestep_done

	; Gouraud span level: one bank select per row from the left-chain
	; level, clamped against interpolation rounding overshoot.  Which bank
	; stride applies is a packet constant, so it arrives pre-resolved in
	; raster_lvl_shift and the row pays one register-count shift instead of the
	; previous signed multiply.  The flat build is not a branch here either --
	; see the dlvl = 0 setup above.
	move.l	raster_lvl,d2
	asr.l	#8,d2
	bpl	.span_level_lo_ok
	moveq	#0,d2
.span_level_lo_ok
	cmpi.l	#15,d2
	ble	.span_level_hi_ok
	moveq	#15,d2
.span_level_hi_ok
	move.w	raster_lvl_shift,d4
	lsl.l	d4,d2
	add.l	raster_clut_tint_base,d2
	move.l	d2,a6

	; X clipping.  Both edge corrections are OUT OF LINE, below the walker:
	; neither runs for the current camera, and every byte lying between
	; .span_row_loop and its closing branch competes for the 68030's 256-byte
	; direct-mapped instruction cache against code that does run on every row.
	; Only the two tests stay here.
	tst.l	d0
	blt	.span_left_clip
.span_xl_ok
	cmpi.l	#SCREEN_WIDTH-1,d1
	bgt	.span_right_clip
.span_xr_ok
	move.l	d1,d4
	sub.l	d0,d4				; span length minus one, for DBRA
	ifd	TREX_PROFILE_NO_PIXELS
	bra	.span_row_advance		; same-size profiling patch
	else
	bmi	.span_row_advance		; empty row
	endc
	add.l	d4,d7				; pre-count the span as written;
	addq.l	#1,d7				; transparent texels subtract below
	; This is the only point the row walker reaches for a non-empty row, so
	; folding d0/d1 and the row address in here yields exactly the packet's
	; clipped span box.
	ifd	TREX_OCCL
	bsr	occl_track_row
	endc

	move.l	a2,a4
	add.l	d0,d0
	adda.l	d0,a4				; first pixel of the span

	; Which pixel body runs is a packet constant.  rasterize_packet resolved
	; it once; the row loop must not spend three absolute-long reads and
	; three branches per row re-deriving the same answer.
	jmp	([raster_span_entry])

	; ---- qualified opaque textured span: fetch and write, no flag test ----
	; A6 addresses the parallel word CLUT, so the indexed source and the
	; postincrementing framebuffer destination fit in one MOVE.W.  This is
	; still one CLUT read plus one 16-bit ST-RAM write per pixel; no claim is
	; made that a long framebuffer store would save bus transfers.
.span_tex_opaque_loop
	; D0 and D1 keep zero upper words for the whole span.  MOVE.W replaces
	; their low words, and MOVE.B then splices U into V's low byte.  This
	; removes two per-pixel clears plus the mask/OR pair from the dominant
	; qualified-opaque path.
	moveq	#0,d0
	moveq	#0,d1
.span_tex_opaque_pixel
	move.w	d6,d1				; low word = V integer | V fraction
	move.w	d5,d0
	lsr.w	#8,d0				; low byte = U integer
	move.b	d0,d1				; low word = V integer | U integer
	move.b	(0,a5,d1.l),d0		; D0 remains zero-extended palette index
	ifd	TREX_OCCL
	move.w	occl_owner_id,(OCCL_OWNER_DELTA.l,a4)
	endc
	move.w	(0,a6,d0.l*2),(a4)+
	add.l	a0,d5
	add.l	a1,d6
	dbra	d4,.span_tex_opaque_pixel
	; falls through into .span_row_advance -- the hot path is contiguous

.span_row_advance
	adda.l	raster_sl,a3
	add.l	raster_sr,d3
	move.l	raster_dul,d0
	add.l	d0,raster_ul
	move.l	raster_dvl,d0
	add.l	d0,raster_vl
	move.l	raster_dlvl,d0
	add.l	d0,raster_lvl
	adda.w	#FRAMEBUFFER_STRIDE,a2
	subq.l	#1,raster_rows
	bne	.span_row_loop
	; Chain state back to memory for the second trapezoid half, and
	; y_current advances by the complete walked row count in one step.
	lea	-4095(a3),a3
	sub.l	#$00000fff,d3
	move.l	a3,raster_xl
	move.l	d3,raster_xr
	move.l	a2,raster_fb_row
	move.l	(sp)+,d0
	add.l	d0,raster_y_current
.span_walk_done
	add.l	d7,raster_pixel_count
	rts
.span_walk_empty
	rts

; Y clamp, out of line: the per-half top catch-up and bottom shorten exactly
; as they always ran, entered only when the packet's Y interval leaves the
; screen.  A start above the screen advances the whole DDA state n rows in
; one multiply each; rows below the bottom edge only shorten the count.
.span_y_clip
	move.l	raster_y_current,d0
	bge	.span_y_top_ok
	move.l	d0,d1
	neg.l	d1
	cmp.l	raster_rows,d1
	ble	.span_catchup_bounded
	move.l	raster_rows,d1
.span_catchup_bounded
	sub.l	d1,raster_rows
	add.l	d1,raster_y_current
	move.l	raster_sl,d0
	muls.l	d1,d0
	add.l	d0,raster_xl
	move.l	raster_sr,d0
	muls.l	d1,d0
	add.l	d0,raster_xr
	move.l	raster_dul,d0
	muls.l	d1,d0
	add.l	d0,raster_ul
	move.l	raster_dvl,d0
	muls.l	d1,d0
	add.l	d0,raster_vl
	muls.l	#FRAMEBUFFER_STRIDE,d1
	add.l	d1,raster_fb_row
.span_y_top_ok
	move.l	raster_y_current,d0
	add.l	raster_rows,d0
	cmpi.l	#SCREEN_HEIGHT,d0
	ble	.span_y_bot_ok
	move.l	#SCREEN_HEIGHT,d0
	sub.l	raster_y_current,d0
	move.l	d0,raster_rows
.span_y_bot_ok
	tst.l	raster_rows
	ble	.span_walk_empty
	bra	.span_y_ready

; -----------------------------------------------------------------------------
; Out-of-line row bodies.
;
; Everything below runs per row like the code inside the walker does, but it is
; kept OUTSIDE the loop's address range on purpose: the 68030's instruction
; cache is 256 bytes, direct-mapped on address bits 4..7, so a byte that merely
; SITS between .span_row_loop and its closing branch evicts a byte that runs on
; every row.  The qualified-opaque body is the one the shipping mesh takes for
; 88% of its packets (section 3.8) and is the only one left inline.
; -----------------------------------------------------------------------------

; A left clip advances U/V by the clipped distance.  Never entered by the
; current camera; the walker must still never scribble outside the framebuffer.
; D3 carries the right chain across the whole half now, so the scratch here is
; D4 -- dead until the span length is taken a few instructions later.
.span_left_clip
	move.l	d0,d2
	neg.l	d2
	move.l	a0,d4
	muls.l	d2,d4
	add.l	d4,d5
	move.l	a1,d4
	muls.l	d2,d4
	add.l	d4,d6
	moveq	#0,d0
	bra	.span_xl_ok

.span_right_clip
	move.l	#SCREEN_WIDTH-1,d1
	bra	.span_xr_ok

	; ---- potentially transparent textured span: fetch, test, write ----
	; The texel offset is v*256+u over the integer parts, and both integer
	; parts are bits 8-15 of their Q8.8 register: v's land on 8-15 by a
	; single word mask, u's drop to 0-7 by one word shift.  Scaled indexed
	; addressing then folds the pointer arithmetic and the CLUT's lsl #2
	; into the two fetches -- a3 is out of the loop entirely.
.span_tex_loop
	moveq	#0,d0
	moveq	#0,d1
.span_tex_pixel
	move.w	d6,d1
	move.w	d5,d0
	lsr.w	#8,d0
	move.b	d0,d1
	move.b	(0,a5,d1.l),d0
	move.l	(0,a6,d0.l*4),d2
	btst	#17,d2
	beq	.span_tex_transparent		; invalid/transparent PS1 CLUT word
	move.w	d2,(a4)
	; Owner id of the pixel just written.  MOVE.W (xxx).L,(bd.l,An) is a
	; 68020+ mode that needs no register at all, which is what lets the same
	; instruction serve the semitransparent path below where d3 is taken.
	; It sits behind the bit-17 test, so a transparent texel takes neither
	; the colour nor the ownership.
	ifd	TREX_OCCL
	move.w	occl_owner_id,(OCCL_OWNER_DELTA.l,a4)
	endc
.span_tex_skip
	add.l	a0,d5
	add.l	a1,d6
	addq.l	#2,a4
	dbra	d4,.span_tex_pixel
	bra	.span_row_advance
.span_tex_transparent
	subq.l	#1,d7				; take the pre-count back
	ifd	TREX_OCCL
	addq.l	#1,occl_drop_count		; only the CCR moves, and the bra ignores it
	endc
	bra	.span_tex_skip

	; ---- flat span: one prepared colour, no per-pixel decisions ----
.span_flat
	move.w	raster_flat_color,d2
.span_flat_loop
	; Ahead of the postincrementing colour store, while a4 still addresses
	; the target pixel.  The existing store is not rewritten.
	ifd	TREX_OCCL
	move.w	occl_owner_id,(OCCL_OWNER_DELTA.l,a4)
	endc
	move.w	d2,(a4)+
	dbra	d4,.span_flat_loop
	bra	.span_row_advance

	; ---- semitransparent textured span ----
	; Back-to-front painter's order makes the destination read correct.
	; STP-flagged texels blend 50/50; others write opaquely.  D4 is the
	; span countdown out here, so the blend scratch borrows it.
.span_semi
	moveq	#0,d0
	moveq	#0,d1
.span_semi_pixel
	move.w	d6,d1
	move.w	d5,d0
	lsr.w	#8,d0
	move.b	d0,d1				; v*256+u, as in the opaque loop
	move.b	(0,a5,d1.l),d0
	move.l	(0,a6,d0.l*4),d2
	btst	#17,d2
	beq	.span_semi_transparent
	btst	#16,d2				; PS1 STP flag selects blending
	beq	.span_semi_write
	; D3 is the half's right chain and D4 the span countdown; the blend
	; borrows both and hands them back before the next pixel.
	movem.l	d3-d4,-(sp)
	moveq	#0,d0
	move.w	(a4),d0				; existing Falcon RGB555X pixel

	; Red: (src + dst) / 2, Falcon bits 11..15.
	move.l	d2,d1
	lsr.l	#8,d1
	lsr.l	#3,d1
	andi.l	#$1f,d1
	move.l	d0,d3
	lsr.l	#8,d3
	lsr.l	#3,d3
	andi.l	#$1f,d3
	add.l	d3,d1
	lsr.l	#1,d1
	lsl.l	#8,d1
	lsl.l	#3,d1

	; Green: (src + dst) / 2, Falcon bits 6..10.  Bit 5 (overlay) stays 0.
	move.l	d2,d3
	lsr.l	#6,d3
	andi.l	#$1f,d3
	move.l	d0,d4
	lsr.l	#6,d4
	andi.l	#$1f,d4
	add.l	d4,d3
	lsr.l	#1,d3
	lsl.l	#6,d3
	or.l	d3,d1

	; Blue: (src + dst) / 2, Falcon bits 0..4.
	move.l	d2,d3
	andi.l	#$1f,d3
	move.l	d0,d4
	andi.l	#$1f,d4
	add.l	d4,d3
	lsr.l	#1,d3
	or.l	d3,d1
	move.l	d1,d2
	movem.l	(sp)+,d3-d4
.span_semi_write
	move.w	d2,(a4)
	; Dead in the current build -- build_gpu_shadow_packets never sets the
	; $02000000 blend bit -- but instrumented anyway, so the measurement's
	; exactness does not rest on it staying dead.
	ifd	TREX_OCCL
	move.w	occl_owner_id,(OCCL_OWNER_DELTA.l,a4)
	endc
.span_semi_skip
	add.l	a0,d5
	add.l	a1,d6
	addq.l	#2,a4
	dbra	d4,.span_semi_pixel
	bra	.span_row_advance
.span_semi_transparent
	subq.l	#1,d7				; take the pre-count back
	ifd	TREX_OCCL
	addq.l	#1,occl_drop_count
	endc
	bra	.span_semi_skip

	ifd	TREX_OCCL
; -----------------------------------------------------------------------------
; Occlusion instrumentation (-DTREX_OCCL only, target trex_occl.tos).
;
; The question this answers is "which transmitted survivor leaves no visible
; pixel at all".  Without a Z-buffer and in strict painter's order that is the
; same as "no pixel carries this packet's draw rank once the frame is done", so
; one extra store per written pixel settles it exactly -- nothing is
; re-rasterized offline.  Each drawn packet gets a rank from the far-to-near OT
; walk, writes that rank into a parallel 16-bit owner bitmap alongside every
; colour store, and contributes one 48-byte record; the finished bitmap plus
; the records are dumped per frame as OCnnnn.RES.
;
; Every routine here saves and restores what it touches, so the instrumented
; paths behave exactly like the uninstrumented ones apart from the writes.
; -----------------------------------------------------------------------------

; Wipe this frame's owner ids and open a new frame's record set.  Called from
; the tail of gpu_clear_ot, which runs before anything of this frame is
; rasterized, so the counter marks latched here bracket exactly this frame.
occl_clear_owner
	movem.l	d0-d2/a0,-(sp)
	move.l	render_base,a0
	adda.l	#OCCL_OWNER_DELTA,a0
	moveq	#0,d0
	move.w	#SCREEN_HEIGHT-1,d2
.occl_clear_row
	move.w	#(SCREEN_WIDTH/2)-1,d1
.occl_clear_loop
	move.l	d0,(a0)+
	dbra	d1,.occl_clear_loop
	adda.l	#(VIDEO_SCREEN_STRIDE-(SCREEN_WIDTH*2)),a0
	dbra	d2,.occl_clear_row

	clr.l	occl_rank
	clr.w	occl_owner_id
	move.l	#occl_record_buffer,occl_record_ptr
	move.l	raster_pixel_count,occl_frame_written_mark
	move.l	occl_drop_count,occl_frame_dropped_mark
	movem.l	(sp)+,d0-d2/a0
	rts

; Fold one non-empty rasterized row into the current packet's span box.
; In: D0 = first column, D1 = last column (both already clipped), A2 = the row
; walker's framebuffer row pointer.  Preserves everything.
occl_track_row
	movem.l	d0-d3/a0-a2,-(sp)
	move.l	occl_span_x0,d2
	cmp.l	d0,d2
	ble	.occl_row_x0_ok
	move.l	d0,occl_span_x0
.occl_row_x0_ok
	move.l	occl_span_x1,d2
	cmp.l	d1,d2
	bge	.occl_row_x1_ok
	move.l	d1,occl_span_x1
.occl_row_x1_ok
	; The row index is the only thing a2 is needed for, and render_base is
	; the window origin the walker started from.
	move.l	a2,d2
	sub.l	render_base,d2
	divu.w	#FRAMEBUFFER_STRIDE,d2
	andi.l	#$ffff,d2
	move.l	occl_span_y0,d3
	cmp.l	d2,d3
	ble	.occl_row_y0_ok
	move.l	d2,occl_span_y0
.occl_row_y0_ok
	move.l	occl_span_y1,d3
	cmp.l	d2,d3
	bge	.occl_row_y1_ok
	move.l	d2,occl_span_y1
.occl_row_y1_ok
	movem.l	(sp)+,d0-d3/a0-a2
	rts

; Open one packet's record.  In: A0 = the packet about to be rasterized.
; Preserves everything -- the OT walker's a0/a1/a3/d7 must survive.
occl_begin_packet
	movem.l	d0-d7/a0-a6,-(sp)
	move.l	a0,occl_packet_ptr
	addq.l	#1,occl_rank
	move.l	occl_rank,d0
	move.w	d0,occl_owner_id
	move.l	raster_pixel_count,occl_written_mark
	move.l	occl_drop_count,occl_dropped_mark
	; Empty-box sentinels: a packet whose every row clips away leaves these
	; untouched, and x1 < x0 is then what marks the box empty.
	move.l	#255,occl_span_x0
	clr.l	occl_span_x1
	move.l	#255,occl_span_y0
	clr.l	occl_span_y1
	movem.l	(sp)+,d0-d7/a0-a6
	rts

; Record the submit slot's source triangle.  In: D6 = global source triangle
; index, called straight after dsp_packet_count_shadow was incremented.
occl_note_source
	movem.l	d0-d7/a0-a6,-(sp)
	move.l	dsp_packet_count_shadow,d0
	subq.l	#1,d0
	lsl.l	#2,d0
	lea	occl_source_index,a0
	move.l	d6,(a0,d0.l)
	movem.l	(sp)+,d0-d7/a0-a6
	rts

; Fold one projected vertex (D0 = x, D1 = y) into the running box D2..D5.
occl_bbox_fold
	cmp.l	d0,d2
	ble	.occl_fold_xmin_ok
	move.l	d0,d2
.occl_fold_xmin_ok
	cmp.l	d0,d3
	bge	.occl_fold_xmax_ok
	move.l	d0,d3
.occl_fold_xmax_ok
	cmp.l	d1,d4
	ble	.occl_fold_ymin_ok
	move.l	d1,d4
.occl_fold_ymin_ok
	cmp.l	d1,d5
	bge	.occl_fold_ymax_ok
	move.l	d1,d5
.occl_fold_ymax_ok
	rts

; Clipped screen bounding box of one source triangle, rebuilt from this
; frame's projected vertices with exactly the clamp and the reject rule
; make_triangle_bbox applies on the DSP (trex_dsp.asm).  The vertex indices
; come from the host copy of the triangle stream, as in compute_span_reference.
;
; In: D0 = global source triangle index.  Out: D0 = 1 and D2/D3 = x min/max,
; D4/D5 = y min/max, or D0 = 0 for a box that clipped away entirely.
; Clobbers D0-D5 and A2/A3.
occl_vertex_bbox
	lsl.l	#4,d0				; four longwords per triangle record
	lea	dsp_triangle_tx_buffer+8,a3
	adda.l	d0,a3
	move.l	(a3)+,d0			; i0
	bsr	load_projected_xy
	move.l	d1,d4				; y before x: load_projected_xy
	move.l	d1,d5				; returns y in d1, which becomes xmin
	move.l	d0,d2
	move.l	d0,d3
	move.l	(a3)+,d0			; i1
	bsr	load_projected_xy
	bsr	occl_bbox_fold
	move.l	(a3)+,d0			; i2
	bsr	load_projected_xy
	bsr	occl_bbox_fold

	tst.l	d2
	bpl	.occl_bbox_xmin_ok
	moveq	#0,d2
.occl_bbox_xmin_ok
	cmpi.l	#SCREEN_WIDTH-1,d3
	ble	.occl_bbox_xmax_ok
	move.l	#SCREEN_WIDTH-1,d3
.occl_bbox_xmax_ok
	cmp.l	d2,d3
	blt	.occl_bbox_empty
	tst.l	d4
	bpl	.occl_bbox_ymin_ok
	moveq	#0,d4
.occl_bbox_ymin_ok
	cmpi.l	#SCREEN_HEIGHT-1,d5
	ble	.occl_bbox_ymax_ok
	move.l	#SCREEN_HEIGHT-1,d5
.occl_bbox_ymax_ok
	cmp.l	d4,d5
	blt	.occl_bbox_empty
	moveq	#1,d0
	rts
.occl_bbox_empty
	moveq	#0,d0
	rts

; Close one packet's record and advance the write pointer.  Preserves
; everything.
occl_end_packet
	movem.l	d0-d7/a0-a6,-(sp)
	move.l	occl_record_ptr,a1
	; rasterize_packet loads raster_du_dx into a0, so the packet address is
	; taken from the cell occl_begin_packet latched, never from the register.
	move.l	occl_packet_ptr,a0
	moveq	#0,d7				; rec_flags accumulator

	move.l	occl_rank,d0
	move.w	d0,(a1)			; +0  draw_rank
	move.l	a0,d0
	sub.l	#gpu_packet_buffer,d0
	divu.w	#GPU_PACKET_BYTES,d0
	andi.l	#$ffff,d0			; quotient only, the packet stride is exact
	move.w	d0,2(a1)			; +2  submit slot
	lsl.l	#2,d0
	lea	occl_source_index,a2
	move.l	(a2,d0.l),d6
	move.l	d6,4(a1)			; +4  source triangle
	move.l	8(a0),d0
	move.l	d0,8(a1)			; +8  OT key
	move.l	raster_pixel_count,d0
	sub.l	occl_written_mark,d0
	move.l	d0,12(a1)			; +12 framebuffer writes
	move.l	occl_drop_count,d0
	sub.l	occl_dropped_mark,d0
	move.l	d0,16(a1)			; +16 bit-17 rejects

	move.l	occl_span_x1,d0
	cmp.l	occl_span_x0,d0
	bge	.occl_end_span_ok
	bset	#3,d7				; span box empty
.occl_end_span_ok
	move.l	occl_span_x0,d0
	move.b	d0,20(a1)
	move.l	occl_span_x1,d0
	move.b	d0,21(a1)
	move.l	occl_span_y0,d0
	move.b	d0,22(a1)
	move.l	occl_span_y1,d0
	move.b	d0,23(a1)

	; Clipped vertex box.  Without a projected-vertex fetch this frame there
	; is nothing to derive it from, and the record says so rather than
	; shipping a plausible-looking wrong box.
	tst.l	dsp_vertices_fetched
	beq	.occl_end_vbox_invalid
	move.l	d6,d0
	bsr	occl_vertex_bbox
	tst.l	d0
	beq	.occl_end_vbox_empty
	move.w	d2,24(a1)
	move.w	d3,26(a1)
	move.w	d4,28(a1)
	move.w	d5,30(a1)
	bra	.occl_end_vbox_done
.occl_end_vbox_invalid
	bset	#5,d7
	bra	.occl_end_vbox_none
.occl_end_vbox_empty
	bset	#4,d7
.occl_end_vbox_none
	moveq	#-1,d0
	move.w	d0,24(a1)
	move.w	d0,26(a1)
	move.w	d0,28(a1)
	move.w	d0,30(a1)
.occl_end_vbox_done

	move.l	(a0),d0			; command | shade
	move.l	d0,d1
	andi.l	#$ff000000,d1
	cmpi.l	#$34000000,d1
	bne	.occl_end_not_textured
	bset	#0,d7
.occl_end_not_textured
	move.l	d0,d1
	andi.l	#$02000000,d1
	beq	.occl_end_not_semi
	bset	#1,d7
.occl_end_not_semi
	tst.l	raster_force_flat
	beq	.occl_end_flags_ready
	bset	#2,d7
.occl_end_flags_ready
	move.w	d7,32(a1)			; +32 rec_flags
	andi.l	#SHADE_PACKET_MASK,d0
	move.w	d0,34(a1)			; +34 tint<<4 | level

	move.l	16(a0),d0
	move.w	d0,36(a1)			; +36 sy0, unclamped
	move.l	20(a0),d0
	move.w	d0,38(a1)			; +38 rows_up
	move.l	24(a0),d0
	move.w	d0,40(a1)			; +40 rows_low
	move.l	28(a0),d0
	move.w	d0,42(a1)			; +42 mid
	move.l	12(a0),d0
	move.l	d0,44(a1)			; +44 texture page

	adda.l	#OCCL_RECORD_BYTES,a1
	move.l	a1,occl_record_ptr
	movem.l	(sp)+,d0-d7/a0-a6
	rts

; Rewrite the four decimal digits of OCnnnn.RES in place, nnnn = frame_number
; modulo 10000.  Preserves everything.
occl_patch_filename
	movem.l	d0-d2/a0,-(sp)
	move.l	frame_number,d0
	divu.w	#10000,d0
	clr.w	d0
	swap	d0				; remainder, quotient discarded
	lea	occl_dump_path+6,a0
	moveq	#3,d2
.occl_patch_digit
	divu.w	#10,d0
	move.l	d0,d1
	swap	d1
	andi.l	#$0f,d1
	addi.l	#'0',d1
	move.b	d1,-(a0)
	andi.l	#$ffff,d0			; carry only the quotient forward
	dbra	d2,.occl_patch_digit
	movem.l	(sp)+,d0-d2/a0
	rts

; Write this frame's OCnnnn.RES: header, the N records, the owner bitmap row
; by row, then the trailer.  Fcreate truncates, so there is one create/write/
; close per frame and no positioning -- the same shape as the other dumps.
; Only a file of the exact expected length that ends in the trailer counts as
; complete, which is what protects the analysis from a run killed mid-write.
occl_write_frame_dump
	movem.l	d0-d7/a0-a6,-(sp)
	move.l	frame_number,d0
	cmp.l	occl_dump_first,d0
	blt	.occl_dump_done
	cmp.l	occl_dump_last,d0
	bgt	.occl_dump_done
	bsr	occl_patch_filename

	lea	occl_header_buffer,a0
	move.l	#OCCL_MAGIC,(a0)+
	move.l	#1,(a0)+			; format version
	move.l	frame_number,(a0)+
	move.l	dsp_packet_count_shadow,(a0)+	; N
	move.w	#SCREEN_WIDTH,(a0)+
	move.w	#SCREEN_HEIGHT,(a0)+
	move.w	#OCCL_RECORD_BYTES,(a0)+
	move.w	#OCCL_HEADER_BYTES,(a0)+
	; Which double-buffer half the owner bitmap just dumped belongs to --
	; the proof that the constant delta applies to the half being read.
	move.l	last_rendered_base,d0
	sub.l	#screen_buffer_raw,d0
	move.l	d0,(a0)+
	move.l	#OCCL_OWNER_DELTA,(a0)+
	move.l	raster_pixel_count,d0
	sub.l	occl_frame_written_mark,d0
	move.l	d0,(a0)+
	move.l	occl_drop_count,d0
	sub.l	occl_frame_dropped_mark,d0
	move.l	d0,(a0)+
	move.l	raster_pixel_count,(a0)+	; cumulative, for the cross-frame check
	move.l	gpu_ot_node_count,(a0)+
	move.l	animation_frame,(a0)+

	moveq	#0,d0
	tst.l	gouraud_enabled
	beq	.occl_flag_gouraud_done
	bset	#0,d0
.occl_flag_gouraud_done
	tst.l	raster_force_flat
	beq	.occl_flag_flat_done
	bset	#1,d0
.occl_flag_flat_done
	tst.l	span_validate_enabled
	beq	.occl_flag_validate_done
	bset	#2,d0
.occl_flag_validate_done
	tst.l	dsp_vertices_fetched
	beq	.occl_flag_vertices_done
	bset	#3,d0
.occl_flag_vertices_done
	tst.l	lighting_enabled
	beq	.occl_flag_light_done
	bset	#4,d0
.occl_flag_light_done
	tst.l	present_enabled
	beq	.occl_flag_present_done
	bset	#5,d0
.occl_flag_present_done
	tst.l	delta_clear_enabled
	beq	.occl_flag_delta_done
	bset	#6,d0
.occl_flag_delta_done
	move.l	d0,(a0)+
	move.l	#TREX_PRIMITIVES,(a0)+
	move.l	dsp_triangle_output_count,(a0)+

	Fcreate	occl_dump_path,#0
	tst.l	d0
	bmi	.occl_dump_done
	move.w	d0,d7
	; GEMDOS destroys registers, so the handle and every loop variable are
	; bracketed exactly like trex_write_framebuffer_debug does.
	movem.l	d6-d7/a0,-(sp)
	Fwrite	d7,#OCCL_HEADER_BYTES,occl_header_buffer
	movem.l	(sp)+,d6-d7/a0

	move.l	dsp_packet_count_shadow,d6
	mulu.w	#OCCL_RECORD_BYTES,d6
	beq	.occl_dump_owner
	movem.l	d6-d7/a0,-(sp)
	Fwrite	d7,d6,occl_record_buffer
	movem.l	(sp)+,d6-d7/a0

.occl_dump_owner
	; The owner bitmap of the frame just finished, read through the same
	; latched window origin the framebuffer dump uses, row by row over the
	; wider screen stride.
	move.l	last_rendered_base,a0
	adda.l	#OCCL_OWNER_DELTA,a0
	move.w	#SCREEN_HEIGHT-1,d6
.occl_dump_row
	movem.l	d6-d7/a0,-(sp)
	Fwrite	d7,#(SCREEN_WIDTH*2),(a0)
	movem.l	(sp)+,d6-d7/a0
	adda.l	#VIDEO_SCREEN_STRIDE,a0
	dbra	d6,.occl_dump_row

	move.l	#OCCL_TRAILER,occl_header_buffer
	movem.l	d6-d7/a0,-(sp)
	Fwrite	d7,#4,occl_header_buffer
	movem.l	(sp)+,d6-d7/a0
	Fclose	d7
.occl_dump_done
	movem.l	(sp)+,d0-d7/a0-a6
	rts
	endc

	ifd	TREX_PREPASS
; -----------------------------------------------------------------------------
; DSP occlusion prepass, host side (-DTREX_PREPASS only, target
; trex_prepass.tos).
;
; Two questions are being measured, and they need different arms of the SAME
; binary -- switched by patching prepass_arm in the .tos, never by rebuilding,
; because eight bytes of dead text once moved the rasterizer by 28 ms
; (OPTIMIZATION.md 2.1):
;
;   0  off.  No per-frame command at all.  The in-binary baseline.
;   1  inline.  Mode 1 is sent once at startup and the DSP runs its prepass
;      inside command_finish_animated_frame, in the ~350 ms window during
;      which it is otherwise blocked writing the FINISH ack.  No per-frame
;      host traffic, so t_packets is the falsifiable quantity: if the prepass
;      outlasts the window, t_packets rises by exactly the overhang.
;   2  freestanding.  Mode 2 per frame at the call site below, bracketed into
;      stat_t_prepass.  This puts the prepass on the critical path on purpose:
;      it is the only way to price it.
;   3  null command.  Mode 0 through the SAME call site and the SAME bracket,
;      four words on the wire and no DSP arithmetic.  t_prepass(arm 2) minus
;      t_prepass(arm 3) is the DSP compute time with the host port PIO
;      subtracted out -- gate G10 wants the arm-3 baseline under 0.05 ms per
;      frame.
;
; The correctness gate is the existing framebuffer and packet-count pair:
; the DSP consumes the same full geometry and the BUILD-side kill bitmap is
; only enabled when the rendered bytes remain identical.  The former mode-3
; ordering dump was removed to keep the full-mesh DSP producer inside stock P.
; -----------------------------------------------------------------------------

; Send one prepass command and collect its two-word ack.
;
; In: D0 = mode.  Out: D0 = 1 when the ack was DSP_ACK_PREPASS, else 0.
; prepass_surv_last always holds the reported N_s afterwards.
;
; dsp_block_handshake rather than Dsp_BlkUnpacked: this command does real DSP
; work between the two command words in mode 2, which is exactly the case TOS
; 4.02's unchecked block write loses a word on (see dsp_block_handshake).
; Clobbers D0/D1/A0/A1/A5.
prepass_send_mode
	move.l	dsp_animation_tx_ptr,a5
	move.l	#DSP_CMD_PREPASS,(a5)
	move.l	d0,4(a5)
	move.l	a5,a0
	moveq	#2,d0
	lea	dsp_rx_buffer,a1
	moveq	#2,d1
	bsr	dsp_block_handshake
	move.l	dsp_rx_buffer,dsp_protocol_shadow
	cmpi.l	#DSP_ACK_PREPASS,dsp_protocol_shadow
	bne	.prepass_send_failed
	move.l	dsp_rx_buffer+4,d0
	move.l	d0,prepass_surv_last
	cmpi.l	#PREPASS_OVERFLOW_MARK,d0
	beq	.prepass_send_overflow
	cmp.l	prepass_surv_max,d0
	bls	.prepass_send_ok
	move.l	d0,prepass_surv_max
.prepass_send_ok
	moveq	#1,d0
	rts
.prepass_send_overflow
	; Counted, not repaired: the DSP culls nothing in this state, so the
	; frame stays correct.  surv_max deliberately does not absorb the
	; sentinel -- gate G8 reads it as a real survivor count.
	addq.l	#1,prepass_overflow_count
	moveq	#1,d0
	rts
.prepass_send_failed
	addq.l	#1,prepass_fail_count
	moveq	#0,d0
	rts

; One-off arming, called from trex_init.  Only arm 1 arms the DSP; every other
; arm explicitly disarms it, so a binary switched from 1 to 0 by a byte patch
; does not inherit a sticky flag from a previous run's DSP state.
prepass_startup
	movem.l	d0-d7/a0-a6,-(sp)
	moveq	#PREPASS_MODE_DISARM,d0
	cmpi.l	#1,prepass_arm
	bne	.prepass_startup_send
	moveq	#PREPASS_MODE_ARM,d0
.prepass_startup_send
	bsr	prepass_send_mode
	movem.l	(sp)+,d0-d7/a0-a6
	rts

; Per-frame entry, called from dsp_packets_begin while the DSP is idle.
; Preserves every register -- the caller's chunk bookkeeping follows straight
; after.
prepass_frame_call
	movem.l	d0-d7/a0-a6,-(sp)
	move.l	prepass_arm,d0
	cmpi.l	#2,d0
	beq	.prepass_call_run
	cmpi.l	#3,d0
	bne	.prepass_call_done
	; Arm 3: the null command.  Same site, same bracket, same four words on
	; the wire, no DSP arithmetic behind them.
	moveq	#PREPASS_MODE_DISARM,d0
	bra	.prepass_call_timed
.prepass_call_run
	moveq	#PREPASS_MODE_RUN,d0
.prepass_call_timed
	TimeMark	stat_mark_prepass
	bsr	prepass_send_mode
	TimeAdd	stat_mark_prepass,stat_t_prepass
	addq.l	#1,prepass_run_count
.prepass_call_done
	movem.l	(sp)+,d0-d7/a0-a6
	rts

	endc

	ifd	TREX_FPS
; -----------------------------------------------------------------------------
; Frame-rate overlay.  This is appended after all existing render and prepass
; code deliberately: enabling the release-only feature must not move
; gpu_rasterize_ot, rasterize_packet, span_walk_half, or any other measured hot
; text.  The release build substitutes its word-sized present BSR with a
; same-width BSR here; after drawing, this entry tail-branches through
; gpu_present_frame.
;
; The field therefore lands in the back buffer the flip is about to show and
; the tick delta it samples spans one whole frame, present included.  It is
; inside the release-only present timing bracket, but TREX_RUN emits no stats
; file; diagnostic targets retain their original call and byte layout.
;
; Plain CPU stores throughout -- no Blitter.  The field is drawn 1:1, so a set
; source pixel is one MOVE.W immediate straight into the framebuffer.
;
; Direct work is bounded: a 30x7 wipe (105 longword stores) plus at most
; 5*7*5 = 175 tested source pixels.  No end-to-end performance claim follows
; from that count; the release has not been timed on physical Falcon hardware.
;
; Deliberately NOT gated on video_mode_active, present_enabled or
; dsp_program_loaded: the field is drawn into the render target either way.
; With no DSP geometry it therefore remains visible on the black framebuffer,
; distinguishing a live frontend from a failed packet path.
; -----------------------------------------------------------------------------
gpu_draw_fps
	movem.l	d0-d7/a0-a6,-(sp)

	; Frame period from the 200 Hz tick.  Sampled here rather than in the
	; frame loop so the mark and the drawing that consumes it cannot drift
	; apart if either moves.
	move.l	$4ba.w,d0
	move.l	d0,d1
	sub.l	fps_last_tick,d1
	move.l	d0,fps_last_tick

	; fps*100 = 20000/ticks, so the quotient carries its own two fraction
	; digits and no second division is needed.  Both ends need a guard: a
	; frame that finished inside one 5 ms tick would divide by zero, and a
	; long stall would overflow DIVU.W's 16-bit divisor.
	moveq	#0,d0			; the "too slow to measure" reading, 00.00
	tst.l	d1
	beq	.fps_peg
	cmpi.l	#FPS_SCALED_NUMERATOR,d1
	bhi	.fps_value_ready
	move.l	#FPS_SCALED_NUMERATOR,d0
	divu.w	d1,d0
	andi.l	#$0000ffff,d0
	cmpi.l	#FPS_MAX_CENTI,d0
	bls	.fps_value_ready
.fps_peg
	move.l	#FPS_MAX_CENTI,d0	; peg at 99.99 rather than wrap
.fps_value_ready

	; Fixed NN.NN, zero padded and never blanked: every cell is always a
	; glyph, so the point and both digit pairs hold their column no matter
	; what the rate does.  DIVU.W leaves the remainder in the high word and
	; the quotient in the low one; the clamp above keeps every step in range.
	divu.w	#10,d0
	move.l	d0,d1
	swap	d1
	move.b	d1,fps_text+4		; hundredths
	andi.l	#$0000ffff,d0
	divu.w	#10,d0
	move.l	d0,d1
	swap	d1
	move.b	d1,fps_text+3		; tenths
	andi.l	#$0000ffff,d0
	divu.w	#10,d0
	move.l	d0,d1
	swap	d1
	move.b	d1,fps_text+1		; units
	andi.l	#$0000ffff,d0
	move.b	d0,fps_text		; tens, 0..9 because the value is clamped
	move.b	#FPS_GLYPH_DOT,fps_text+2

	; Repaint the field's own background first.  The full clear would have
	; wiped it already, but delta_clear_enabled is documented as a byte patch
	; applied to the built file: with the delta clear armed the frame clear
	; only touches bands the geometry dirtied, and last frame's digits would
	; survive underneath this frame's.  An unconditional 210-pixel wipe is
	; cheaper than teaching the delta tracker about the overlay.
	move.l	render_base,a0
	adda.l	#(FPS_Y*VIDEO_SCREEN_STRIDE)+(FPS_X*FRAMEBUFFER_BPP),a0
	moveq	#0,d0
	moveq	#FPS_FIELD_ROWS-1,d1
.fps_wipe_row
	move.l	a0,a1
	moveq	#(FPS_FIELD_WIDTH/2)-1,d2
.fps_wipe_loop
	move.l	d0,(a1)+
	dbra	d2,.fps_wipe_loop
	adda.l	#VIDEO_SCREEN_STRIDE,a0
	dbra	d1,.fps_wipe_row

	; Blit the five cells.
	move.l	render_base,a1
	adda.l	#(FPS_Y*VIDEO_SCREEN_STRIDE)+(FPS_X*FRAMEBUFFER_BPP),a1
	lea	fps_text,a2
	moveq	#FPS_TEXT_CHARS-1,d7
.fps_char_loop
	moveq	#0,d1
	move.b	(a2)+,d1
	move.l	d1,d5			; index*FPS_GLYPH_ROWS
	lsl.l	#3,d5
	sub.l	d1,d5
	lea	fps_font,a0
	adda.l	d5,a0

	move.l	a1,a3			; row cursor inside this cell
	moveq	#FPS_GLYPH_ROWS-1,d6
.fps_row_loop
	move.b	(a0)+,d2
	move.l	a3,a4
	moveq	#FPS_GLYPH_COLS-1,d4
.fps_col_loop
	add.b	d2,d2			; leftmost pixel out into carry
	bcc	.fps_col_clear
	move.w	#FPS_WHITE,(a4)
.fps_col_clear
	addq.l	#FPS_SCALE*FRAMEBUFFER_BPP,a4
	dbra	d4,.fps_col_loop
	adda.l	#FPS_SCALE*VIDEO_SCREEN_STRIDE,a3
	dbra	d6,.fps_row_loop

	adda.l	#FPS_CELL_ADVANCE,a1
	dbra	d7,.fps_char_loop

	movem.l	(sp)+,d0-d7/a0-a6
	; Tail-call the existing presenter.  Its RTS consumes gpu_submit_ot's
	; original BSR return address, so the release has exactly one call here.
	bra.w	gpu_present_frame
	; Keep total TREX_FPS text size equal to the merged implementation: the
	; following alignment NOP is skipped by the tail branch.
	nop
	endc

; -----------------------------------------------------------------------------
; Data
; -----------------------------------------------------------------------------

	data

banner_text
	dc.b	27,'E',10,13
	dc.b	'T-Rex M68030 front end',10,13
	dc.b	'Falcon DSP geometry / GPU shadow call graph',10,13
	dc.b	0

	even

; Dsp_LoadProg reads the LOD from the current GEMDOS directory.  The Makefile
; copies the runtime LOD next to this executable.
trex_dsp_lod_path
	ifd TREX_RELEASE
	dc.b	'TREX.LOD',0
	else
	dc.b	'trex_dsp.lod',0
	endc

render_stats_path
	dc.b	'render_stats.res',0

val_stats_path
	dc.b	'val_stats.res',0

	even

; Compare every DSP span-record field against the host's own reference
; arithmetic (compute_span_reference) before the rasterizer consumes it.
; The switch-over is complete and gated clean twice over two revolutions
; each, so this now defaults OFF as an on-demand regression tool: set 1,
; rebuild, and val_stats.res delivers the verdict.  Validation also fetches
; GET_VERTICES again, which the record pipeline otherwise never needs.
span_validate_enabled
	dc.l	0

; 1 = the row loop selects a CLUT bank per span from the interpolated
; corner-level chain (Gouraud, smooth along Y, flat along each span);
; 0 = the packet's single mean-level bank, the pre-Gouraud look.  A data
; flag so both variants remain byte-patchable for A/B measurement.
gouraud_enabled
	dc.l	1

	ifd	TREX_PREPASS
; The prepass A/B arms, in the gouraud_enabled/lighting_enabled tradition: a
; plain longword so all four configurations are ONE binary and switching
; between them is a byte patch verified with cmp -l, never a rebuild.
;   0 = off (baseline)   1 = inline, armed at startup
;   2 = freestanding, timed per frame   3 = null command through the same
;                                            bracket (protocol-cost baseline)
prepass_arm
	dc.l	1

; Deliberately NOT in stat_block: trex_dummy_frame clears that block, and it
; does so after prepass_startup has already run.  A command that failed at
; arming time would be erased before the first frame -- exactly the failure
; the counter exists to catch.
prepass_fail_count
	dc.l	0

prepass_stats_path
	dc.b	'prep_sta.res',0

	even
	endc


framebuffer_debug_path
	dc.b	'fb.res',0

	even

; ANIMATION_MATRICES yaw matrices in 1.23 fixed point, selected by
; frame_number & (ANIMATION_MATRICES-1).  Values go out as 24-bit DSP words,
; negatives in 24-bit two's complement ($00800001 = -1.0).  Note that
; $007fffff is 1-2^-23, not exactly 1.0.
dsp_animation_matrices
	; 0.00 degrees
	dc.l	$7fffff,0,$000000
	dc.l	0,$007fffff,0
	dc.l	$000000,0,$7fffff
	; 11.25 degrees
	dc.l	$7d8a5e,0,$18f8b8
	dc.l	0,$007fffff,0
	dc.l	$e70748,0,$7d8a5e
	; 22.50 degrees
	dc.l	$7641ae,0,$30fbc5
	dc.l	0,$007fffff,0
	dc.l	$cf043b,0,$7641ae
	; 33.75 degrees
	dc.l	$6a6d98,0,$471cec
	dc.l	0,$007fffff,0
	dc.l	$b8e314,0,$6a6d98
	; 45.00 degrees
	dc.l	$5a8279,0,$5a8279
	dc.l	0,$007fffff,0
	dc.l	$a57d87,0,$5a8279
	; 56.25 degrees
	dc.l	$471cec,0,$6a6d98
	dc.l	0,$007fffff,0
	dc.l	$959268,0,$471cec
	; 67.50 degrees
	dc.l	$30fbc5,0,$7641ae
	dc.l	0,$007fffff,0
	dc.l	$89be52,0,$30fbc5
	; 78.75 degrees
	dc.l	$18f8b8,0,$7d8a5e
	dc.l	0,$007fffff,0
	dc.l	$8275a2,0,$18f8b8
	; 90.00 degrees
	dc.l	$000000,0,$7fffff
	dc.l	0,$007fffff,0
	dc.l	$800001,0,$000000
	; 101.25 degrees
	dc.l	$e70748,0,$7d8a5e
	dc.l	0,$007fffff,0
	dc.l	$8275a2,0,$e70748
	; 112.50 degrees
	dc.l	$cf043b,0,$7641ae
	dc.l	0,$007fffff,0
	dc.l	$89be52,0,$cf043b
	; 123.75 degrees
	dc.l	$b8e314,0,$6a6d98
	dc.l	0,$007fffff,0
	dc.l	$959268,0,$b8e314
	; 135.00 degrees
	dc.l	$a57d87,0,$5a8279
	dc.l	0,$007fffff,0
	dc.l	$a57d87,0,$a57d87
	; 146.25 degrees
	dc.l	$959268,0,$471cec
	dc.l	0,$007fffff,0
	dc.l	$b8e314,0,$959268
	; 157.50 degrees
	dc.l	$89be52,0,$30fbc5
	dc.l	0,$007fffff,0
	dc.l	$cf043b,0,$89be52
	; 168.75 degrees
	dc.l	$8275a2,0,$18f8b8
	dc.l	0,$007fffff,0
	dc.l	$e70748,0,$8275a2
	; 180.00 degrees
	dc.l	$800001,0,$000000
	dc.l	0,$007fffff,0
	dc.l	$000000,0,$800001
	; 191.25 degrees
	dc.l	$8275a2,0,$e70748
	dc.l	0,$007fffff,0
	dc.l	$18f8b8,0,$8275a2
	; 202.50 degrees
	dc.l	$89be52,0,$cf043b
	dc.l	0,$007fffff,0
	dc.l	$30fbc5,0,$89be52
	; 213.75 degrees
	dc.l	$959268,0,$b8e314
	dc.l	0,$007fffff,0
	dc.l	$471cec,0,$959268
	; 225.00 degrees
	dc.l	$a57d87,0,$a57d87
	dc.l	0,$007fffff,0
	dc.l	$5a8279,0,$a57d87
	; 236.25 degrees
	dc.l	$b8e314,0,$959268
	dc.l	0,$007fffff,0
	dc.l	$6a6d98,0,$b8e314
	; 247.50 degrees
	dc.l	$cf043b,0,$89be52
	dc.l	0,$007fffff,0
	dc.l	$7641ae,0,$cf043b
	; 258.75 degrees
	dc.l	$e70748,0,$8275a2
	dc.l	0,$007fffff,0
	dc.l	$7d8a5e,0,$e70748
	; 270.00 degrees
	dc.l	$000000,0,$800001
	dc.l	0,$007fffff,0
	dc.l	$7fffff,0,$000000
	; 281.25 degrees
	dc.l	$18f8b8,0,$8275a2
	dc.l	0,$007fffff,0
	dc.l	$7d8a5e,0,$18f8b8
	; 292.50 degrees
	dc.l	$30fbc5,0,$89be52
	dc.l	0,$007fffff,0
	dc.l	$7641ae,0,$30fbc5
	; 303.75 degrees
	dc.l	$471cec,0,$959268
	dc.l	0,$007fffff,0
	dc.l	$6a6d98,0,$471cec
	; 315.00 degrees
	dc.l	$5a8279,0,$a57d87
	dc.l	0,$007fffff,0
	dc.l	$5a8279,0,$5a8279
	; 326.25 degrees
	dc.l	$6a6d98,0,$b8e314
	dc.l	0,$007fffff,0
	dc.l	$471cec,0,$6a6d98
	; 337.50 degrees
	dc.l	$7641ae,0,$cf043b
	dc.l	0,$007fffff,0
	dc.l	$30fbc5,0,$7641ae
	; 348.75 degrees
	dc.l	$7d8a5e,0,$e70748
	dc.l	0,$007fffff,0
	dc.l	$18f8b8,0,$7d8a5e
; Native host-side descriptor.  The TMD and TIM payloads below are embedded
; verbatim with INCBIN; the descriptor uses native big-endian M68030 values.
trex_model_desc
	dc.l	$00000041		; TMD identifier
	dc.l	1			; object count
	dc.l	TREX_VERTICES
	dc.l	TREX_NORMALS
	dc.l	TREX_PRIMITIVES
	dc.l	trex_tmd_data
	dc.l	trex_tmd_data_end-trex_tmd_data
	dc.l	texture_table

texture_table
	dc.l	trex_texture_page_10,trex_texture_page_10_end-trex_texture_page_10
	dc.l	trex_texture_page_12,trex_texture_page_12_end-trex_texture_page_12
	dc.l	trex_texture_page_14,trex_texture_page_14_end-trex_texture_page_14
	dc.l	trex_texture_page_26,trex_texture_page_26_end-trex_texture_page_26
	dc.l	trex_texture_page_28,trex_texture_page_28_end-trex_texture_page_28
	dc.l	trex_texture_page_30,trex_texture_page_30_end-trex_texture_page_30

	even

; Original PS1 assets.  The six TIM files are the native 8-bit indexed pages;
; the derived PNG atlas is intentionally not embedded in this target.
trex_tmd_data
	incbin	"TREX/model/trex.tmd"
trex_tmd_data_end

; Big-endian host-side model representation used to build DSP input streams.
trex_o3d_data
	incbin	"TREX/model/trex.o3d"
trex_o3d_data_end

	even

; One unit object-space face normal per polygon, in polygon order, as three
; 24-bit 1.23 words zero-extended into big-endian longwords.  Derived from the
; O3D by tools/o3d2facenormals.js, which is also where the winding convention
; is documented.
trex_face_normal_data
	incbin	"TREX/model/trex_facenormals.bin"
trex_face_normal_data_end

	even

; One Falcon RGB555X base colour per O3D polygon, zero for textured ones.
; The 136 untextured primitives are the eyes: 120 in the PS1's (255,230,110)
; and 16 in (35,30,0).
trex_face_colour_data
	incbin	"TREX/model/trex_facecolors.bin"
trex_face_colour_data_end

	even

; Three big-endian TMD normal indices per polygon (Gouraud corner shading),
; recovered offline by tools/tmd2cornernormals.js.  Packed into the
; triangle-index upload with the vertex indices; the normals themselves go up
; straight from the TMD block.
trex_corner_normal_data
	incbin	"TREX/model/trex_cornernormals.bin"
trex_corner_normal_data_end

	even

; TANM v2: exact 274-frame PS1 morph weights, coordinate matrices,
; translations, audio-fade state, and 46 deduplicated full-body gait poses.
trex_animation_data
	incbin	"TREX/model/trex_animation.bin"
trex_animation_data_end

; NOT pinned, and measured to stay that way: an eleven-point phase scan
; over a cnop+pad here (4-KiB raster first, then the full 256-byte cache
; period in 32-byte steps -- the 68030 line select is address bits 4..7)
; sat flat at ~285 ms rasterizer while the unpadded build measures ~272.
; The texture BLOCK phase is therefore not the layout lever, and any cnop
; before this label costs a constant ~13 ms by rounding the block against
; the unpinned raster state cells that shift along with it.  Roadmap item
; 16 records where the sensitivity actually lives.
trex_texture_page_10
	incbin	"TREX/textures/trex_texture_page_10.tim"
trex_texture_page_10_end

trex_texture_page_12
	incbin	"TREX/textures/trex_texture_page_12.tim"
trex_texture_page_12_end

trex_texture_page_14
	incbin	"TREX/textures/trex_texture_page_14.tim"
trex_texture_page_14_end

trex_texture_page_26
	incbin	"TREX/textures/trex_texture_page_26.tim"
trex_texture_page_26_end

trex_texture_page_28
	incbin	"TREX/textures/trex_texture_page_28.tim"
trex_texture_page_28_end

trex_texture_page_30
	incbin	"TREX/textures/trex_texture_page_30.tim"
trex_texture_page_30_end

; One host-owned byte per source triangle.  A value of one permits the
; flag-free word-CLUT path for a normal textured packet.  The table follows
; all TIM payloads deliberately: adding it cannot move the measured texture
; block's unpinned phase.  tools/o3d2opaque.js owns the proof and
; tools/opaque_selftest.py cross-checks recorded rasterizer drops.
trex_opaque_triangle_data
	incbin	"TREX/model/trex_opaque.bin"
trex_opaque_triangle_data_end

	even

; Equal-layout timing gate.  Patch this longword to zero in a copy of the
; linked binary: packet construction then emits no opaque hints, while code,
; tables, addresses and every unrelated byte stay identical.
opaque_path_enabled
	ifd	TREX_OPAQUE_BASELINE
	dc.l	0
	else
	dc.l	1
	endc

; Falcon-side lookup tables for the embedded TIM payloads.  All six files use
; the same 8-bit TIM layout: native CLUT at byte 20 and 256x256 pixel data at
; byte 544.  The CLUT table below is filled during texture upload with one
; preconverted Falcon longword per palette entry.
texture_page_ids
	dc.w	10,12,14,26,28,30
	even

; TPAGE low-five-bit value -> byte offset into each six-entry pointer table.
; Unlisted values are zero, preserving the old fallback to page 0.
texture_page_offset_by_tpage
	dc.b	0,0,0,0,0,0,0,0,0,0,0,0,4,0,8,0
	dc.b	0,0,0,0,0,0,0,0,0,0,12,0,16,0,20,0
	even

texture_page_pixels_table
	dc.l	trex_texture_page_10+TIM_PIXEL_DATA_OFFSET
	dc.l	trex_texture_page_12+TIM_PIXEL_DATA_OFFSET
	dc.l	trex_texture_page_14+TIM_PIXEL_DATA_OFFSET
	dc.l	trex_texture_page_26+TIM_PIXEL_DATA_OFFSET
	dc.l	trex_texture_page_28+TIM_PIXEL_DATA_OFFSET
	dc.l	trex_texture_page_30+TIM_PIXEL_DATA_OFFSET

; One entry per page, pointing at that page's darkest bank.  The rasterizer
; adds shade * TIM_FALCON_CLUT_PAGE_BYTES to reach the bank it needs.
texture_page_clut_table
	dc.l	texture_page_falcon_clut_buffer
	dc.l	texture_page_falcon_clut_buffer+(1*TIM_FALCON_CLUT_BANK_BYTES)
	dc.l	texture_page_falcon_clut_buffer+(2*TIM_FALCON_CLUT_BANK_BYTES)
	dc.l	texture_page_falcon_clut_buffer+(3*TIM_FALCON_CLUT_BANK_BYTES)
	dc.l	texture_page_falcon_clut_buffer+(4*TIM_FALCON_CLUT_BANK_BYTES)
	dc.l	texture_page_falcon_clut_buffer+(5*TIM_FALCON_CLUT_BANK_BYTES)

; Parallel flag-free word banks for qualified opaque packets.
texture_page_opaque_clut_table
	dc.l	texture_page_falcon_opaque_clut_buffer
	dc.l	texture_page_falcon_opaque_clut_buffer+(1*TIM_FALCON_OPAQUE_CLUT_BANK_BYTES)
	dc.l	texture_page_falcon_opaque_clut_buffer+(2*TIM_FALCON_OPAQUE_CLUT_BANK_BYTES)
	dc.l	texture_page_falcon_opaque_clut_buffer+(3*TIM_FALCON_OPAQUE_CLUT_BANK_BYTES)
	dc.l	texture_page_falcon_opaque_clut_buffer+(4*TIM_FALCON_OPAQUE_CLUT_BANK_BYTES)
	dc.l	texture_page_falcon_opaque_clut_buffer+(5*TIM_FALCON_OPAQUE_CLUT_BANK_BYTES)

; Brightness numerator over SHADE_LEVELS for every shade level: a linear ramp
; from 7/16 ambient at level 0 to full brightness at SHADE_MAX.  Level 0 is
; never fully black, so a surface facing away from the light still shows its
; texture instead of a silhouette.
;
; The ambient floor is the one number to turn when the model reads too flat or
; too murky.  Measured against the unshaded render of the same 22.5-degree
; frame, as a median pixel brightness and a count of texels crushed to black
; out of 23,992: 6/16 gives 0.47 and 127, this 7/16 ramp gives 0.50 and 118,
; and 8/16 gives 0.56 and 94 but visibly flattens the modelling.
; Colour of the illumination: one R,G,B factor over 64 per (tint, level) cell,
; sixteen levels per tint class.  The level is the geometric term the DSP
; derives from the direct light; the tint is which of the four R/G classes the
; face's own light colour falls into.  Each entry is the median actual colour of
; the faces that landed in that cell, taken over every eighth choreography frame
; under the source light model -- a fit to the PS1 lighting, not a hand ramp.
;
; Level 0 of every class sits near the PS1 ambient (0.333, 0.200, 0.200): warm
; and clearly red, which is what an unlit face is left with.  Red saturates
; towards the top of each class, so highlights come out near neutral exactly as
; the PS1's per-channel clamp makes them.  Cells no face ever reaches take their
; nearest neighbour's value.
shade_ramp_table
	dc.w	32,29,29	; T0 L 0  R/G 1.36  R/G 1.10
	dc.w	32,29,29	; T0 L 1  R/G 1.36  R/G 1.10
	dc.w	32,29,29	; T0 L 2  R/G 1.36  R/G 1.10
	dc.w	36,32,32	; T0 L 3  R/G 1.32  R/G 1.12
	dc.w	39,36,36	; T0 L 4  R/G 1.28  R/G 1.08
	dc.w	44,42,42	; T0 L 5  R/G 1.24  R/G 1.05
	dc.w	46,45,45	; T0 L 6  R/G 1.23  R/G 1.02
	dc.w	52,51,51	; T0 L 7  R/G 1.21  R/G 1.02
	dc.w	56,56,56	; T0 L 8  R/G 1.19  R/G 1.00
	dc.w	60,58,58	; T0 L 9  R/G 1.21  R/G 1.03
	dc.w	64,60,60	; T0 L10  R/G 1.29  R/G 1.07
	dc.w	64,63,63	; T0 L11  R/G 1.22  R/G 1.02
	dc.w	64,62,62	; T0 L12  R/G 1.23  R/G 1.03
	dc.w	64,62,62	; T0 L13  R/G 1.23  R/G 1.03
	dc.w	64,62,62	; T0 L14  R/G 1.23  R/G 1.03
	dc.w	64,62,62	; T0 L15  R/G 1.23  R/G 1.03
	dc.w	25,19,19	; T1 L 0  R/G 1.52  R/G 1.32
	dc.w	27,21,21	; T1 L 1  R/G 1.46  R/G 1.29
	dc.w	30,26,26	; T1 L 2  R/G 1.40  R/G 1.15
	dc.w	38,31,31	; T1 L 3  R/G 1.45  R/G 1.23
	dc.w	43,35,35	; T1 L 4  R/G 1.46  R/G 1.23
	dc.w	48,39,39	; T1 L 5  R/G 1.47  R/G 1.23
	dc.w	52,43,43	; T1 L 6  R/G 1.47  R/G 1.21
	dc.w	58,48,48	; T1 L 7  R/G 1.46  R/G 1.21
	dc.w	64,51,51	; T1 L 8  R/G 1.49  R/G 1.25
	dc.w	64,52,52	; T1 L 9  R/G 1.44  R/G 1.23
	dc.w	64,55,55	; T1 L10  R/G 1.39  R/G 1.16
	dc.w	64,55,55	; T1 L11  R/G 1.39  R/G 1.16
	dc.w	64,55,55	; T1 L12  R/G 1.39  R/G 1.16
	dc.w	64,55,55	; T1 L13  R/G 1.39  R/G 1.16
	dc.w	64,55,55	; T1 L14  R/G 1.39  R/G 1.16
	dc.w	64,55,55	; T1 L15  R/G 1.39  R/G 1.16
	dc.w	24,18,18	; T2 L 0  R/G 1.58  R/G 1.33
	dc.w	29,21,21	; T2 L 1  R/G 1.59  R/G 1.38
	dc.w	35,26,26	; T2 L 2  R/G 1.56  R/G 1.35
	dc.w	40,30,30	; T2 L 3  R/G 1.56  R/G 1.33
	dc.w	45,33,33	; T2 L 4  R/G 1.58  R/G 1.36
	dc.w	49,37,37	; T2 L 5  R/G 1.58  R/G 1.32
	dc.w	55,42,42	; T2 L 6  R/G 1.55  R/G 1.31
	dc.w	60,44,44	; T2 L 7  R/G 1.60  R/G 1.36
	dc.w	64,49,49	; T2 L 8  R/G 1.58  R/G 1.31
	dc.w	64,49,49	; T2 L 9  R/G 1.58  R/G 1.31
	dc.w	64,49,49	; T2 L10  R/G 1.58  R/G 1.31
	dc.w	64,49,49	; T2 L11  R/G 1.58  R/G 1.31
	dc.w	64,49,49	; T2 L12  R/G 1.58  R/G 1.31
	dc.w	64,49,49	; T2 L13  R/G 1.58  R/G 1.31
	dc.w	64,49,49	; T2 L14  R/G 1.58  R/G 1.31
	dc.w	64,49,49	; T2 L15  R/G 1.58  R/G 1.31
	dc.w	22,15,15	; T3 L 0  R/G 1.67  R/G 1.47
	dc.w	29,20,20	; T3 L 1  R/G 1.67  R/G 1.45
	dc.w	37,25,25	; T3 L 2  R/G 1.71  R/G 1.48
	dc.w	41,29,29	; T3 L 3  R/G 1.72  R/G 1.41
	dc.w	48,33,33	; T3 L 4  R/G 1.71  R/G 1.45
	dc.w	53,37,37	; T3 L 5  R/G 1.72  R/G 1.43
	dc.w	58,40,40	; T3 L 6  R/G 1.71  R/G 1.45
	dc.w	64,44,44	; T3 L 7  R/G 1.72  R/G 1.45
	dc.w	64,44,44	; T3 L 8  R/G 1.72  R/G 1.45
	dc.w	64,44,44	; T3 L 9  R/G 1.72  R/G 1.45
	dc.w	64,44,44	; T3 L10  R/G 1.72  R/G 1.45
	dc.w	64,44,44	; T3 L11  R/G 1.72  R/G 1.45
	dc.w	64,44,44	; T3 L12  R/G 1.72  R/G 1.45
	dc.w	64,44,44	; T3 L13  R/G 1.72  R/G 1.45
	dc.w	64,44,44	; T3 L14  R/G 1.72  R/G 1.45
	dc.w	64,44,44	; T3 L15  R/G 1.72  R/G 1.45

; The three lights Demo One's own setup routine (0x80127764) installs, each
; stored twice: once scaled for the RED channel and once for GREEN, which
; equals BLUE for every light here.  Camera space has +X right, +Y DOWN - the
; O3D converter negates the OBJ's Y - and +Z away from the viewer, which is the
; PS1's convention too, so the source directions transfer unchanged:
;
;   key   (20,-100,-100) colour (255,144,144) - above, slightly right, towards
;                                               the camera; the warm one
;   back  (20,-50,-100)  colour (128,128,128) - above and behind the model
;   fill  (-20,20,100)   colour (128,128,128) - from below and left
;
; back and fill were hand-transcribed wrong in an earlier pass (values below
; were corrected against sub_80127764 in the PS1 disassembly): back's z was
; misread as 0x80 (0d128), which is $s0 reused for the RGB bytes *after* the
; real z store (`sw $s0,0x6038($at)` at disasm.s:1578, still -100 at that
; point; the reassignment to 0x80 is the next instruction).  fill's y and z
; were transposed.  Neither error is visible from the rendered image alone --
; both lights stay grey (128,128,128), so only the shading gradient shifts.
; Each vector is the unit direction times the light's own length (the PS1 keeps
; intensity in the light matrix, not in a separate term) times that colour
; channel over 128, normalised so the brightest reachable face reaches
; luminance 1.0.  Two clamped-dot sums over the two sets give the DSP the
; face's own light colour: its luminance picks the brightness level, its R/G
; ratio picks the tint class.
dsp_light_direction
	dc.l	$00139bf6,$009df432,$009df432	; red   key
	dc.l	$0009d7d3,$00e76471,$00cec8e2	; red   back
	dc.l	$00f6282d,$0009d7d3,$0031371e	; red   fill
	dc.l	$000b12cd,$00c8a1fe,$00c8a1fe	; green key
	dc.l	$0009d7d3,$00e76471,$00cec8e2	; green back
	dc.l	$00f6282d,$0009d7d3,$0031371e	; green fill
	dc.l	$002aa800,$00199800		; PS1 ambient, red and green

present_enabled
	dc.l	1

; 1 = flat-colour diagnostic render (no texturing at all).
raster_force_flat
	dc.l	0

; 1 = delta clearing: the frame clear wipes only the eight-row bands this
; buffer was drawn into two frames ago, and every rasterized packet widens the
; band table for the next time round.  0 = the full clear across all 224 rows.
; Both arms are in the binary and no byte of text moves between them, which is
; the only comparison OPTIMIZATION.md 2.1 accepts -- see lighting_enabled below
; for what happens when a feature is toggled by editing the source instead.
;
; Ships as 0.  The mechanism moved into the main path on 2026-08-09 and was
; re-measured post-3.9 over the identical 0-263 prefix, one-byte arms: the
; clear drops 14.6 -> 6.3 ms exactly as modelled, but delta_mark_packet still
; costs +14.7 ms of per-packet instruction fetch -- the walker sweeps far more
; than the 256-byte cache between two calls, so 3.9's loop work changed
	; nothing about THIS term -- for a net +13.4 ms on the full mesh. The 2.5
	; verdict therefore stands. A batched variant (spill
; raster_xl/xr per packet, compute all hulls in one tight per-frame loop that
; stays cache-resident) is the open idea that could invert the sign.
; -DTREX_DELTA_ON (target trex_delta.tos) assembles the same dc.l sized 1,
; the TREX_RUN pattern, so the A/B stays a byte patch, never a layout change.
;
; NEVER write this at runtime, and there is deliberately no code that does.
; The band table of the page about to be cleared was filled two frames ago; if
; the flag flipped from 0 to 1 between frames, that table would be empty while
; the buffer was not, and the leftovers of a frame nobody recorded would show
; through as ghosts.  The switch is a byte patch on the file, before the run.
delta_clear_enabled
	ifd	TREX_DELTA_ON
	dc.l	1
	else
	dc.l	0
	endc

; Per-buffer dirty-band tables, two pages of DC_BANDS entries.  In data rather
; than bss so they are DC_EMPTY in the loaded image: a cold start is then
; correct with no runtime preparation whatsoever, and the first two frames
; simply clear nothing, which is right because gpu_open wiped both buffers.
;
; Entry layout, two signed words: floored xmin, floored xmax.  Signed WORDS,
; and this is the one place that would break silently rather than loudly.  The
; range is safe today with a factor of five to spare: sx is a 12-bit screen
; value from the DSP wire format (|x| <= 2048), the steepest slope is dx<<12/dy
; with dy >= 1 and therefore at most 4096 columns per row, so a chain end plus
; its one-step overshoot cannot pass ~6144.  Widen the projection range or
; change the 12-bit wire encoding and the high bits drop off here, the box
; comes out too SMALL, and the result is a stale pixel -- not a crash.
dc_band_table
	rept	DC_BANDS*2
	dc.l	DC_EMPTY
	endr

; The page the current frame belongs to, derived from render_base once per
; frame by delta_clear_bands.  Rasterizer and clear both read this cell, so
; they cannot end up on different pages.
dc_table_base
	dc.l	0

; The packet pointer rasterize_packet saves on entry, because A0 no longer
; holds it when the bookkeeping runs.
dc_packet
	dc.l	0

; Cumulative longwords written by the delta clear, reported as the last field
; of render_stats.res.  Never reset: it lives outside stat_block on purpose --
; nothing clears it and nothing needs to, because gpu_clear_ot first runs after
; trex_dummy_frame has already zeroed the timing block.
dc_clear_longwords
	dc.l	0

; 1 = per-face flat shading.  0 skips the face-normal upload, so the DSP
; reports full brightness for every triangle and the render falls back to the
; unshaded look.
;
; This is a data flag rather than a source edit on purpose.  Commenting the
; upload call out instead shortens the text section by the four bytes of its
; BSR, which shifts every later instruction - including the rasterizer's inner
; loops - by two bytes.  Measured on the 64-frame headless run, that alignment
; shift alone moved the rasterizer by 78 ms per frame, an order of magnitude
; more than the feature being measured.  Toggling a longword here keeps both
; configurations byte-identical in code layout.
lighting_enabled
	dc.l	1

; 1 = rewrite render_stats.res after every frame.  That is what makes a run
; measurable while it is still going -- OPTIMIZATION.md 2.1 compares equal
; frame counts by snapshotting the file mid-run -- so it stays on for
; development.  It is a GEMDOS create/write/close per frame, which is free
; under Hatari's host-side emulation but a real disk access on hardware, so a
; release build sets this to 0 and keeps only the write in trex_shutdown.
; TREX_RUN (vasm -DTREX_RUN, targets trex_run.tos and
; trex_prepass_run.tos) is the viewing build: both capture flags 0, so the
; frame loop performs no GEMDOS traffic, and trex_shutdown also skips the
; final diagnostic flush.  Both variants assemble the same dc.l, so the
; binaries stay layout-identical except for these two data longwords.
stats_flush_enabled
	ifd	TREX_RUN
	dc.l	0
	else
	dc.l	1
	endc

; 1 = write the render target to fb.res (headless inspection).
framebuffer_dump_enabled
	ifd	TREX_RUN
	dc.l	0
	else
	dc.l	1
	endc

; Capture the frame-100 close-up checkpoint by default: it covers an order of
; magnitude more pixels than the distant frame 0, which makes it the stronger
; byte-identity gate for pixel-loop changes.  A data value keeps other
; choreography checkpoints available without changing code alignment;
; -DTREX_DUMP_FRAME=n selects one at assembly time for checkpoint captures.
framebuffer_dump_frame
	ifd	TREX_DUMP_FRAME
	dc.l	TREX_DUMP_FRAME
	else
	dc.l	100
	endc

	ifd	TREX_OCCL
; Inclusive frame window for the occlusion dump.  A pilot run captures a
; handful of frames with -DTREX_OCC_FIRST=n -DTREX_OCC_LAST=m; the default
; window covers anything the emulator's VBL budget can reach.
occl_dump_first
	ifd	TREX_OCC_FIRST
	dc.l	TREX_OCC_FIRST
	else
	dc.l	0
	endc
occl_dump_last
	ifd	TREX_OCC_LAST
	dc.l	TREX_OCC_LAST
	else
	dc.l	100000
	endc

; One file per rendered frame.  occl_patch_filename rewrites the four digits
; in place before every Fcreate, so the name stays 8.3-legal for GEMDOS.
occl_dump_path
	dc.b	'OC0000.RES',0

	even
	endc

camera_state
	dc.l	0,0,0

object_state
	; Legacy library shadow only.  The active object translation comes from
	; each TANM choreography record and is sent by dsp_set_frame.
	dc.l	0,-55,1300

render_stats_buffer
	ds.l	RENDER_STATS_LONGS

; Deliberate addition, no source equivalent: a slow turntable yaw around the
; vertical (Y) axis during the held state, tested on request.  Each entry is
; Ry(-step*3deg) . M273, composed offline in Q12 -- M273 = (3782,0,-1567,
; 0,4096,0, 1567,0,3782), frame 273's own frozen matrix (already read
; straight from trex_animation.bin) and itself a pure Y rotation, so step 0
; is exactly that matrix.  Turning it further the SAME way the ending's own
; last 20 frames already do read as backwards once continued past a full
; loop; negated on request so the visible turn keeps going the way it looks
; like it should.  A full cycle is 120 steps.
Y_SPIN_STEPS	= 120
y_spin_matrices
	dc.w	3782,0,-1567,0,4096,0,1567,0,3782			; step 0, 0.0 deg
	dc.w	3695,0,-1763,0,4096,0,1763,0,3695			; step 1, -3.0 deg
	dc.w	3597,0,-1954,0,4096,0,1954,0,3597			; step 2, -6.0 deg
	dc.w	3490,0,-2139,0,4096,0,2139,0,3490			; step 3, -9.0 deg
	dc.w	3374,0,-2319,0,4096,0,2319,0,3374			; step 4, -12.0 deg
	dc.w	3248,0,-2492,0,4096,0,2492,0,3248			; step 5, -15.0 deg
	dc.w	3113,0,-2659,0,4096,0,2659,0,3113			; step 6, -18.0 deg
	dc.w	2969,0,-2818,0,4096,0,2818,0,2969			; step 7, -21.0 deg
	dc.w	2818,0,-2970,0,4096,0,2970,0,2818			; step 8, -24.0 deg
	dc.w	2658,0,-3113,0,4096,0,3113,0,2658			; step 9, -27.0 deg
	dc.w	2492,0,-3248,0,4096,0,3248,0,2492			; step 10, -30.0 deg
	dc.w	2318,0,-3374,0,4096,0,3374,0,2318			; step 11, -33.0 deg
	dc.w	2139,0,-3491,0,4096,0,3491,0,2139			; step 12, -36.0 deg
	dc.w	1953,0,-3598,0,4096,0,3598,0,1953			; step 13, -39.0 deg
	dc.w	1762,0,-3695,0,4096,0,3695,0,1762			; step 14, -42.0 deg
	dc.w	1566,0,-3782,0,4096,0,3782,0,1566			; step 15, -45.0 deg
	dc.w	1366,0,-3859,0,4096,0,3859,0,1366			; step 16, -48.0 deg
	dc.w	1162,0,-3925,0,4096,0,3925,0,1162			; step 17, -51.0 deg
	dc.w	955,0,-3981,0,4096,0,3981,0,955			; step 18, -54.0 deg
	dc.w	746,0,-4025,0,4096,0,4025,0,746			; step 19, -57.0 deg
	dc.w	534,0,-4059,0,4096,0,4059,0,534			; step 20, -60.0 deg
	dc.w	321,0,-4081,0,4096,0,4081,0,321			; step 21, -63.0 deg
	dc.w	107,0,-4092,0,4096,0,4092,0,107			; step 22, -66.0 deg
	dc.w	-108,0,-4092,0,4096,0,4092,0,-108			; step 23, -69.0 deg
	dc.w	-322,0,-4081,0,4096,0,4081,0,-322			; step 24, -72.0 deg
	dc.w	-535,0,-4059,0,4096,0,4059,0,-535			; step 25, -75.0 deg
	dc.w	-746,0,-4025,0,4096,0,4025,0,-746			; step 26, -78.0 deg
	dc.w	-956,0,-3981,0,4096,0,3981,0,-956			; step 27, -81.0 deg
	dc.w	-1163,0,-3925,0,4096,0,3925,0,-1163			; step 28, -84.0 deg
	dc.w	-1367,0,-3859,0,4096,0,3859,0,-1367			; step 29, -87.0 deg
	dc.w	-1567,0,-3782,0,4096,0,3782,0,-1567			; step 30, -90.0 deg
	dc.w	-1763,0,-3695,0,4096,0,3695,0,-1763			; step 31, -93.0 deg
	dc.w	-1954,0,-3597,0,4096,0,3597,0,-1954			; step 32, -96.0 deg
	dc.w	-2139,0,-3490,0,4096,0,3490,0,-2139			; step 33, -99.0 deg
	dc.w	-2319,0,-3374,0,4096,0,3374,0,-2319			; step 34, -102.0 deg
	dc.w	-2492,0,-3248,0,4096,0,3248,0,-2492			; step 35, -105.0 deg
	dc.w	-2659,0,-3113,0,4096,0,3113,0,-2659			; step 36, -108.0 deg
	dc.w	-2818,0,-2969,0,4096,0,2969,0,-2818			; step 37, -111.0 deg
	dc.w	-2970,0,-2818,0,4096,0,2818,0,-2970			; step 38, -114.0 deg
	dc.w	-3113,0,-2658,0,4096,0,2658,0,-3113			; step 39, -117.0 deg
	dc.w	-3248,0,-2492,0,4096,0,2492,0,-3248			; step 40, -120.0 deg
	dc.w	-3374,0,-2318,0,4096,0,2318,0,-3374			; step 41, -123.0 deg
	dc.w	-3491,0,-2139,0,4096,0,2139,0,-3491			; step 42, -126.0 deg
	dc.w	-3598,0,-1953,0,4096,0,1953,0,-3598			; step 43, -129.0 deg
	dc.w	-3695,0,-1762,0,4096,0,1762,0,-3695			; step 44, -132.0 deg
	dc.w	-3782,0,-1566,0,4096,0,1566,0,-3782			; step 45, -135.0 deg
	dc.w	-3859,0,-1366,0,4096,0,1366,0,-3859			; step 46, -138.0 deg
	dc.w	-3925,0,-1162,0,4096,0,1162,0,-3925			; step 47, -141.0 deg
	dc.w	-3981,0,-955,0,4096,0,955,0,-3981			; step 48, -144.0 deg
	dc.w	-4025,0,-746,0,4096,0,746,0,-4025			; step 49, -147.0 deg
	dc.w	-4059,0,-534,0,4096,0,534,0,-4059			; step 50, -150.0 deg
	dc.w	-4081,0,-321,0,4096,0,321,0,-4081			; step 51, -153.0 deg
	dc.w	-4092,0,-107,0,4096,0,107,0,-4092			; step 52, -156.0 deg
	dc.w	-4092,0,108,0,4096,0,-108,0,-4092			; step 53, -159.0 deg
	dc.w	-4081,0,322,0,4096,0,-322,0,-4081			; step 54, -162.0 deg
	dc.w	-4059,0,535,0,4096,0,-535,0,-4059			; step 55, -165.0 deg
	dc.w	-4025,0,746,0,4096,0,-746,0,-4025			; step 56, -168.0 deg
	dc.w	-3981,0,956,0,4096,0,-956,0,-3981			; step 57, -171.0 deg
	dc.w	-3925,0,1163,0,4096,0,-1163,0,-3925			; step 58, -174.0 deg
	dc.w	-3859,0,1367,0,4096,0,-1367,0,-3859			; step 59, -177.0 deg
	dc.w	-3782,0,1567,0,4096,0,-1567,0,-3782			; step 60, -180.0 deg
	dc.w	-3695,0,1763,0,4096,0,-1763,0,-3695			; step 61, -183.0 deg
	dc.w	-3597,0,1954,0,4096,0,-1954,0,-3597			; step 62, -186.0 deg
	dc.w	-3490,0,2139,0,4096,0,-2139,0,-3490			; step 63, -189.0 deg
	dc.w	-3374,0,2319,0,4096,0,-2319,0,-3374			; step 64, -192.0 deg
	dc.w	-3248,0,2492,0,4096,0,-2492,0,-3248			; step 65, -195.0 deg
	dc.w	-3113,0,2659,0,4096,0,-2659,0,-3113			; step 66, -198.0 deg
	dc.w	-2969,0,2818,0,4096,0,-2818,0,-2969			; step 67, -201.0 deg
	dc.w	-2818,0,2970,0,4096,0,-2970,0,-2818			; step 68, -204.0 deg
	dc.w	-2658,0,3113,0,4096,0,-3113,0,-2658			; step 69, -207.0 deg
	dc.w	-2492,0,3248,0,4096,0,-3248,0,-2492			; step 70, -210.0 deg
	dc.w	-2318,0,3374,0,4096,0,-3374,0,-2318			; step 71, -213.0 deg
	dc.w	-2139,0,3491,0,4096,0,-3491,0,-2139			; step 72, -216.0 deg
	dc.w	-1953,0,3598,0,4096,0,-3598,0,-1953			; step 73, -219.0 deg
	dc.w	-1762,0,3695,0,4096,0,-3695,0,-1762			; step 74, -222.0 deg
	dc.w	-1566,0,3782,0,4096,0,-3782,0,-1566			; step 75, -225.0 deg
	dc.w	-1366,0,3859,0,4096,0,-3859,0,-1366			; step 76, -228.0 deg
	dc.w	-1162,0,3925,0,4096,0,-3925,0,-1162			; step 77, -231.0 deg
	dc.w	-955,0,3981,0,4096,0,-3981,0,-955			; step 78, -234.0 deg
	dc.w	-746,0,4025,0,4096,0,-4025,0,-746			; step 79, -237.0 deg
	dc.w	-534,0,4059,0,4096,0,-4059,0,-534			; step 80, -240.0 deg
	dc.w	-321,0,4081,0,4096,0,-4081,0,-321			; step 81, -243.0 deg
	dc.w	-107,0,4092,0,4096,0,-4092,0,-107			; step 82, -246.0 deg
	dc.w	108,0,4092,0,4096,0,-4092,0,108			; step 83, -249.0 deg
	dc.w	322,0,4081,0,4096,0,-4081,0,322			; step 84, -252.0 deg
	dc.w	535,0,4059,0,4096,0,-4059,0,535			; step 85, -255.0 deg
	dc.w	746,0,4025,0,4096,0,-4025,0,746			; step 86, -258.0 deg
	dc.w	956,0,3981,0,4096,0,-3981,0,956			; step 87, -261.0 deg
	dc.w	1163,0,3925,0,4096,0,-3925,0,1163			; step 88, -264.0 deg
	dc.w	1367,0,3859,0,4096,0,-3859,0,1367			; step 89, -267.0 deg
	dc.w	1567,0,3782,0,4096,0,-3782,0,1567			; step 90, -270.0 deg
	dc.w	1763,0,3695,0,4096,0,-3695,0,1763			; step 91, -273.0 deg
	dc.w	1954,0,3597,0,4096,0,-3597,0,1954			; step 92, -276.0 deg
	dc.w	2139,0,3490,0,4096,0,-3490,0,2139			; step 93, -279.0 deg
	dc.w	2319,0,3374,0,4096,0,-3374,0,2319			; step 94, -282.0 deg
	dc.w	2492,0,3248,0,4096,0,-3248,0,2492			; step 95, -285.0 deg
	dc.w	2659,0,3113,0,4096,0,-3113,0,2659			; step 96, -288.0 deg
	dc.w	2818,0,2969,0,4096,0,-2969,0,2818			; step 97, -291.0 deg
	dc.w	2970,0,2818,0,4096,0,-2818,0,2970			; step 98, -294.0 deg
	dc.w	3113,0,2658,0,4096,0,-2658,0,3113			; step 99, -297.0 deg
	dc.w	3248,0,2492,0,4096,0,-2492,0,3248			; step 100, -300.0 deg
	dc.w	3374,0,2318,0,4096,0,-2318,0,3374			; step 101, -303.0 deg
	dc.w	3491,0,2139,0,4096,0,-2139,0,3491			; step 102, -306.0 deg
	dc.w	3598,0,1953,0,4096,0,-1953,0,3598			; step 103, -309.0 deg
	dc.w	3695,0,1762,0,4096,0,-1762,0,3695			; step 104, -312.0 deg
	dc.w	3782,0,1566,0,4096,0,-1566,0,3782			; step 105, -315.0 deg
	dc.w	3859,0,1366,0,4096,0,-1366,0,3859			; step 106, -318.0 deg
	dc.w	3925,0,1162,0,4096,0,-1162,0,3925			; step 107, -321.0 deg
	dc.w	3981,0,955,0,4096,0,-955,0,3981			; step 108, -324.0 deg
	dc.w	4025,0,746,0,4096,0,-746,0,4025			; step 109, -327.0 deg
	dc.w	4059,0,534,0,4096,0,-534,0,4059			; step 110, -330.0 deg
	dc.w	4081,0,321,0,4096,0,-321,0,4081			; step 111, -333.0 deg
	dc.w	4092,0,107,0,4096,0,-107,0,4092			; step 112, -336.0 deg
	dc.w	4092,0,-108,0,4096,0,108,0,4092			; step 113, -339.0 deg
	dc.w	4081,0,-322,0,4096,0,322,0,4081			; step 114, -342.0 deg
	dc.w	4059,0,-535,0,4096,0,535,0,4059			; step 115, -345.0 deg
	dc.w	4025,0,-746,0,4096,0,746,0,4025			; step 116, -348.0 deg
	dc.w	3981,0,-956,0,4096,0,956,0,3981			; step 117, -351.0 deg
	dc.w	3925,0,-1163,0,4096,0,1163,0,3925			; step 118, -354.0 deg
	dc.w	3859,0,-1367,0,4096,0,1367,0,3859			; step 119, -357.0 deg

	ifd	TREX_FPS
; -----------------------------------------------------------------------------
; Overlay font: 5x7 cells, one byte per row, leftmost pixel in bit 7.  The low
; three bits of every byte are unused padding.  Cells are indexed 0..9 for the
; digits, then FPS_GLYPH_DOT.  There is no blank cell: the NN.NN field is zero
; padded, so all five positions always hold a real glyph.
;
; At the end of the data section deliberately: the texture pages above depend
; on their measured cache phase (see the layout note at the TIM payloads), and
; appending here cannot move any of them.
; -----------------------------------------------------------------------------
fps_font
	dc.b	%01110000		; 0
	dc.b	%10001000
	dc.b	%10001000
	dc.b	%10001000
	dc.b	%10001000
	dc.b	%10001000
	dc.b	%01110000

	dc.b	%00100000		; 1
	dc.b	%01100000
	dc.b	%00100000
	dc.b	%00100000
	dc.b	%00100000
	dc.b	%00100000
	dc.b	%01110000

	dc.b	%01110000		; 2
	dc.b	%10001000
	dc.b	%00001000
	dc.b	%00010000
	dc.b	%00100000
	dc.b	%01000000
	dc.b	%11111000

	dc.b	%11110000		; 3
	dc.b	%00001000
	dc.b	%00001000
	dc.b	%01110000
	dc.b	%00001000
	dc.b	%00001000
	dc.b	%11110000

	dc.b	%10001000		; 4
	dc.b	%10001000
	dc.b	%10001000
	dc.b	%11111000
	dc.b	%00001000
	dc.b	%00001000
	dc.b	%00001000

	dc.b	%11111000		; 5
	dc.b	%10000000
	dc.b	%11110000
	dc.b	%00001000
	dc.b	%00001000
	dc.b	%10001000
	dc.b	%01110000

	dc.b	%01110000		; 6
	dc.b	%10001000
	dc.b	%10000000
	dc.b	%11110000
	dc.b	%10001000
	dc.b	%10001000
	dc.b	%01110000

	dc.b	%11111000		; 7
	dc.b	%00001000
	dc.b	%00010000
	dc.b	%00100000
	dc.b	%00100000
	dc.b	%00100000
	dc.b	%00100000

	dc.b	%01110000		; 8
	dc.b	%10001000
	dc.b	%10001000
	dc.b	%01110000
	dc.b	%10001000
	dc.b	%10001000
	dc.b	%01110000

	dc.b	%01110000		; 9
	dc.b	%10001000
	dc.b	%10001000
	dc.b	%01111000
	dc.b	%00001000
	dc.b	%10001000
	dc.b	%01110000

	dc.b	%00000000		; . (FPS_GLYPH_DOT)
	dc.b	%00000000
	dc.b	%00000000
	dc.b	%00000000
	dc.b	%00000000
	dc.b	%01100000
	dc.b	%01100000

	even
	endc


	bss

saved_sp
	ds.l	1
saved_super
	ds.l	1

; -----------------------------------------------------------------------------
; Frame timing accumulators.  stat_block .. stat_block+STAT_LONGS is zeroed at
; the top of trex_dummy_frame, so every counter below must live inside it.
; -----------------------------------------------------------------------------

stat_block
stat_frames
	ds.l	1
stat_vbl_start
	ds.l	1
stat_vbl_end
	ds.l	1
stat_hz200_start
	ds.l	1
stat_hz200_end
	ds.l	1
stat_t_setframe
	ds.l	1
stat_t_packets
	ds.l	1
stat_t_clear
	ds.l	1
stat_t_otinsert
	ds.l	1
stat_t_raster
	ds.l	1
stat_t_present
	ds.l	1
stat_mark_setframe
	ds.l	1
stat_mark_packets
	ds.l	1
stat_mark_clear
	ds.l	1
stat_mark_otinsert
	ds.l	1
stat_mark_raster
	ds.l	1
stat_mark_present
	ds.l	1
	ifd	TREX_PREPASS
; Inside stat_block on purpose: these are per-run counters and the block-clear
; at the top of trex_dummy_frame is what guarantees they start at zero.
stat_t_prepass
	ds.l	1
stat_mark_prepass
	ds.l	1
prepass_run_count
	ds.l	1
prepass_surv_last
	ds.l	1
prepass_surv_max
	ds.l	1
prepass_overflow_count
	ds.l	1
	endc
stat_block_end

STAT_LONGS		= (stat_block_end-stat_block)/4

frame_number
	ds.l	1
animation_frame
	ds.l	1
animation_audio_volume
	ds.l	1
animation_scene_flags
	ds.l	1
animation_active_mask
	ds.l	1
animation_choreo_record
	ds.l	1
animation_gait_pose_ptr
	ds.l	1
; Zero until the hold state starts, then the walk-cycle pose index (14..45)
; to use INSTEAD of the frozen choreography record's own gait index -- see
; the hold branch in trex_dummy_frame and dsp_set_frame's gait pointer setup.
gait_hold_index
	ds.l	1
; Current step (0..Y_SPIN_STEPS-1) into y_spin_matrices; advances alongside
; gait_hold_index in the same hold branch.
y_spin_index
	ds.l	1
; This step's X-translation recentring, stashed by the matrix source setup
; in dsp_set_frame for the translation send further down to pick up.
y_spin_tx
	ds.l	1
dsp_animation_tx_ptr
	ds.l	1
animation_chunk_first
	ds.l	1
animation_chunk_count
	ds.l	1
animation_target_weight
	ds.l	1
animation_target_first
	ds.l	1
animation_target_remaining
	ds.l	1
animation_target_source
	ds.l	1

lib_state
	ds.l	1
lib_call_count
	ds.l	1
last_lib_frame
	ds.l	1

tmd_id_shadow
	ds.l	1
tmd_ptr_shadow
	ds.l	1
tmd_length_shadow
	ds.l	1
texture_table_ptr_shadow
	ds.l	1
runtime_vertex_count
	ds.l	1
runtime_normal_count
	ds.l	1
runtime_primitive_count
	ds.l	1
camera_ptr_shadow
	ds.l	1
object_ptr_shadow
	ds.l	1
ot_primitive_count
	ds.l	1
ot_length_shadow
	ds.l	1

dsp_state
	ds.l	1
dsp_call_count
	ds.l	1
dsp_lock_state
	ds.l	1
dsp_program_loaded
	ds.l	1
dsp_mesh_loaded
	ds.l	1
dsp_normals_loaded
	ds.l	1
dsp_triangle_stream_ready
	ds.l	1
dsp_triangle_indices_loaded
	ds.l	1
dsp_uvs_loaded
	ds.l	1
dsp_vertices_fetched
	ds.l	1
dsp_frame_upload_count
	ds.l	1
dsp_frame_shadow
	ds.l	1
dsp_vertex_count_shadow
	ds.l	1
dsp_normal_count_shadow
	ds.l	1
; Face normals actually accepted by the DSP: one per triangle, not the mesh's
; own per-vertex normal count above.
dsp_face_normal_count_shadow
	ds.l	1
dsp_packet_count_shadow
	ds.l	1
dsp_host_tx_shadow
	ds.l	1
dsp_word_count
	ds.l	1
dsp_protocol_shadow
	ds.l	1
dsp_x_available
	ds.l	1
dsp_y_available
	ds.l	1
dsp_triangles_remaining
	ds.l	1
dsp_triangle_chunk_count
	ds.l	1
dsp_triangle_chunk_survivors
	ds.l	1
dsp_triangle_input_count
	ds.l	1
dsp_triangle_output_count
	ds.l	1
dsp_triangle_output_ptr
	ds.l	1
dsp_triangle_unpack_base
	ds.l	1
dsp_pipeline_active
	ds.l	1
dsp_chunk_inflight
	ds.l	1
dsp_animation_inflight
	ds.l	1

; Span-record validation state: scratch for one triangle's reference values,
; the mismatch counters, and the report buffer.
val_x0
	ds.l	1
val_y0
	ds.l	1
val_x1
	ds.l	1
val_y1
	ds.l	1
val_x2
	ds.l	1
val_y2
	ds.l	1
val_u0
	ds.l	1
val_v0
	ds.l	1
val_u1
	ds.l	1
val_v1
	ds.l	1
val_u2
	ds.l	1
val_v2
	ds.l	1
val_cross
	ds.l	1
val_chain_tmp
	ds.l	1
val_ref
	ds.l	17
val_records
	ds.l	1
val_mismatch_total
	ds.l	1
val_first_captured
	ds.l	1
val_first_frame
	ds.l	1
val_first_tri
	ds.l	1
val_first_field
	ds.l	1
val_first_host
	ds.l	1
val_first_dsp
	ds.l	1
val_field_counts
	ds.l	17
val_stats_buffer
	ds.l	VAL_STATS_LONGS

; Temporary buffer required by Dsp_LoadProg while converting ASCII LOD.
; Overallocated by 64 KiB - 1 and used through the aligned window dsp_open
; computes, like the animation transfer buffer: the ROM's program bootstrap
; walks this buffer with the same unthrottled host-port loop family as
; Dsp_BlkUnpacked (section 2.1), and mesh-budget changes move the BSS
; freely.  This is a defensive alignment by analogy, NOT a measured
; failure: the one observed LoadProg failure blamed on layout turned out
; to be an empty trex_dsp.lod (the Makefile trap its rule now guards
; against).
dsp_load_buffer
	ds.b	DSP_LOAD_BUFFER_BYTES+65535

; Longword arrays are used by Dsp_BlkUnpacked; only the low 24 bits are sent.
dsp_tx_buffer
	ds.l	DSP_UPLOAD_WORDS

; The face-normal upload is the largest single transaction of the whole run,
; so it gets its own buffer instead of resizing the vertex one.
dsp_normal_tx_buffer
	ds.l	DSP_NORMAL_UPLOAD_WORDS

; Overallocate once and choose a 64-KiB-aligned DSP_ANIMATION_WORDS window at
; startup.  See trex_init: TOS 4.02's unpacked-block source address wraps at
; the bank edge even though the transfer count itself is a longword.
dsp_animation_tx_storage
	ds.b	$ffff+(DSP_TX_BUFFER_WORDS*4)

dsp_rx_buffer
	ds.l	2

dsp_control_tx
	ds.l	1

dsp_vertex_rx_buffer
	ds.l	DSP_VERTEX_OUTPUT_WORDS

dsp_triangle_tx_buffer
	ds.l	DSP_TRIANGLE_INPUT_WORDS

dsp_triangle_rx_buffer
	ds.l	DSP_TRIANGLE_OUTPUT_WORDS

; One host-port transaction at a time.  The outgoing chunk is command/count/
; base; the records themselves are resident on the DSP.
dsp_triangle_chunk_tx
	ds.l	DSP_TRIANGLE_CHUNK_TX_WORDS
dsp_triangle_chunk_rx
	ds.l	(2+(DSP_TRIANGLE_CHUNK*DSP_SPAN_RECORD_WORDS))

; One eight-word native texture record per O3D polygon:
; u0,v0,u1,v1,u2,v2,CLUT,TPAGE.
gpu_texture_meta_buffer
	ds.l	O3D_TEXTURE_WORDS*TREX_PRIMITIVES

; Six prepared CLUTs, each held at SHADE_LEVELS brightnesses.  Every entry is a
; longword: low 16 bits are Falcon RGB555X, bit 16 is PS1 STP, and bit 17 marks
; a valid/non-transparent word.  Layout is [page][shade level][palette index].
;
; Pinned to a 4-KiB page like the render targets (section 2.1): the pixel
; loop sweeps these banks and the framebuffer through the same sixteen
; direct-mapped data-cache lines every few texels, so their RELATIVE page
; phase is performance-critical.  Growing the buffers above them by +64 KB
; for the Gouraud records moved the unpinned banks and cost 80 ms of
; rasterizer time at an unchanged instruction stream -- the exact residual
; sensitivity item 16 of the roadmap kept open.
	cnop	0,4096
texture_page_falcon_clut_buffer
	ds.l	TIM_PAGE_COUNT*CLUT_BANK_COUNT*TIM_CLUT_ENTRIES

; One page's Falcon colours before any lighting; every bank of that page is
; derived from it.
gpu_clut_unscaled
	ds.l	TIM_CLUT_ENTRIES

gpu_state
	ds.l	1
gpu_call_count
	ds.l	1
gpu_word_count
	ds.l	1
gpu_gp0_shadow
	ds.l	1
gpu_packet_ptr
	ds.l	1
gpu_clut_page_base
	ds.l	1
gpu_submit_ptr_shadow
	ds.l	1
texture_ptr_shadow
	ds.l	1
texture_length_shadow
	ds.l	1
texture_page_count_shadow
	ds.l	1
gpu_texture_ptr_shadow
	ds.l	1
gpu_texture_length_shadow
	ds.l	1

video_monitor_type_shadow
	ds.l	1
video_mode_active
	ds.l	1
video_screen_base
	ds.l	1
video_old_physbase
	ds.l	1
video_old_logbase
	ds.l	1
; Falcon true-colour palette register 0 ($ffff9800) as the desktop left it;
; Videl draws the border with it in >8bpp modes.
video_old_border
	ds.l	1

; The Videl state gpu_open takes over, as the desktop left it.  Written back
; by video_restore_registers -- see the Videl section near the top.
video_save_st_shift
	ds.b	1
	even
video_save_spshift
	ds.w	1
video_save_sync
	ds.w	1
video_save_offset_width
	ds.l	1
video_save_hscroll
	ds.l	1
video_save_htiming
	ds.l	4
video_save_vtiming
	ds.l	4
video_save_control
	ds.l	1

gpu_ot_node_count
	ds.l	1

ordering_table
	ds.l	OT_LENGTH

; Software OT node format: packet address followed by next-node address.
; The final GPU/rasterizer backend can walk each bucket from far to near.
; Scannable absolute cache phase like the raster state cells below.
OT_NODE_PHASE = 0
	cnop	0,256
	ds.b	OT_NODE_PHASE
	even
gpu_ot_node_buffer
	ds.l	GPU_OT_NODE_WORDS*TREX_PRIMITIVES

; Software rasterizer state.  All coordinates are integer pixels; UV and
; horizontal interpolation values use Q8.8 fixed point where indicated.
;
; The row walker pays one memory RMW per row on several of these cells, so
; their 256-byte cache phase against the pinned framebuffer, the pinned
; CLUT banks and the texture pages is performance-relevant (roadmap item
; 16); this pad makes that phase explicit and scannable.  The cnop makes it
; ABSOLUTE within the 256-byte cache period, so pads and buffers growing in
; front of this point can no longer recalibrate it -- every scanned phase
; in this file is independent for the same reason.
RASTER_STATE_PHASE = 32
	cnop	0,256
	ds.b	RASTER_STATE_PHASE
	even
; Dead since the packet parse resolved raster_span_entry directly, and kept
; only as reserved space: every cell below them has a measured cache phase
; (OPTIMIZATION.md 2.1 and roadmap item 16), so removing four bytes here would
; move all of them.
raster_textured
	ds.l	1
raster_semitrans
	ds.l	1
; Flat shade level of the packet being rasterized, 0..SHADE_MAX.
raster_shade
	ds.l	1
raster_flat_color
	ds.l	1

; Span rasterizer DDA state, loaded per packet from the record fields:
; xl/xr and the slopes are 12.12, ul/vl and their steps Q8.8 along the left
; chain.  span_walk_half consumes and advances these in place.
raster_xl
	ds.l	1
raster_xr
	ds.l	1
raster_sl
	ds.l	1
raster_sr
	ds.l	1
raster_ul
	ds.l	1
raster_vl
	ds.l	1
raster_dul
	ds.l	1
raster_dvl
	ds.l	1
raster_rows
	ds.l	1
raster_y_current
	ds.l	1
; Edge values at the first pixel of the current row, stepped by dE/dy.
raster_du_dx
	ds.l	1
raster_dv_dx
	ds.l	1
; Gouraud span-level chain state (Q4.8) and the tint's bank-zero CLUT base
; the row loop adds the level bank offset to.
raster_lvl
	ds.l	1
raster_dlvl
	ds.l	1
raster_clut_tint_base
	ds.l	1
raster_fb_row
	ds.l	1
raster_pixel_count
	ds.l	1
; Host-side source qualification for the packet currently being walked.
; Appended after every pre-existing state cell so their measured cache phase
; and offsets remain unchanged; the framebuffer's 4-KiB anchor follows.
; Dead for the same reason as raster_textured above, reserved for the same one.
raster_opaque
	ds.l	1
; Which pixel body the row loop runs, and the log2 CLUT bank stride that goes
; with it (9 for the opaque word table, 10 for the long one).  Both are packet
; constants that the walker used to re-derive on every row.  Appended after
; every pre-existing cell for the same reason raster_opaque was.
raster_span_entry
	ds.l	1
raster_lvl_shift
	ds.w	1
	even
; Sign flag: negative when the packet's Y interval leaves the screen and
; span_walk_half must run its out-of-line clamp.  Appended after every
; pre-existing cell for the same reason raster_opaque was.
raster_walk_clip
	ds.l	1



; Pin the render target to a 4 KB boundary.  The framebuffer otherwise moves
; whenever the code or any buffer above it changes size, and the rasterizer's
; cost depends measurably on where it lands (OPTIMIZATION.md 2.1).
	cnop	0,4096

; Two Falcon screen buffers, owned by gpu_open and handed back by gpu_close.
; The renderer draws straight into the one that is not on display and the
; frame ends by pointing Videl at it, so there is no present copy any more.
screen_buffer_raw
	ds.b	(2*SCREEN_BUFFER_BYTES)+SCREEN_ALIGN

; Top-left corner of the 240x224 window inside the buffer being drawn into.
; Every consumer of the old dedicated framebuffer reads this instead.
render_base
	ds.l	1

; The buffer currently on display, and the one being drawn into.  They swap
; every frame in gpu_present_frame.
video_back_base
	ds.l	1

; Window origin of the frame that was finished last, for the debug dump.
last_rendered_base
	ds.l	1

; Scannable absolute cache phase like the raster state cells above: the
; builder writes and the rasterizer reads 26 longs here per packet.
PACKET_BUFFER_PHASE = 0
	cnop	0,256
	ds.b	PACKET_BUFFER_PHASE
	even
gpu_packet_buffer
	ds.l	GPU_PACKET_WORDS*TREX_PRIMITIVES

; The packed index list, built once by dsp_upload_triangle_indices and sent
; once.  Only the low 24 bits of each longword go out.
;
; Declared here, after the render target, deliberately: bulk data inserted
; anywhere above framebuffer shifts it, and the rasterizer is measurably
; sensitive to where it lands -- up to 70 ms per frame, more than this
; buffer's whole reason for existing saves.  New bulk buffers belong at the
; end of the section.
dsp_triangle_load_tx_buffer
	ds.l	DSP_TRIANGLE_LOAD_WORDS

; The host-resident packed UV pairs, built once from gpu_texture_meta_buffer
; and shipped chunk-wise with every BUILD command since Gouraud.  Bulk
; buffers go at the end of the section (see the layout note above).
dsp_uv_tx_buffer
	ds.l	TREX_PRIMITIVES*2

; Six pages x 64 shade/tint banks x 256 exact Falcon RGB555X words = 192 KiB.
; Bulk storage belongs after the pinned render target, packet buffer and every
; pre-existing hot cell.  Its own 4-KiB anchor gives the word CLUT the same
; stable page phase as the flag-bearing long CLUT and framebuffer.
;
; OPAQUE_CLUT_PHASE is the DATA-cache phase lever.  The 68030's data cache is
; 256 bytes, sixteen 16-byte lines, direct-mapped on address bits 4..7, and the
; qualified-opaque pixel loop drives three streams through it every pixel: the
; byte texel read, this word CLUT read at index*2, and the framebuffer write.
; The 4-KiB anchor above makes every 512-byte CLUT bank start at line 0, which
; is stable but arbitrary -- the anchor was added to stop the banks MOVING
; (roadmap item 16's 80 ms), never to put them anywhere good.  This offsets the
; buffer inside the 256-byte cache period; the trailing pad restores the total
; to a whole number of periods so nothing after it changes cache phase, exactly
; the isolation item 16 used for the raster state cells.  Section 3.10 has the
; scan.  The buffer is 768 whole periods, so only the pads move phase.
;
; MEASURED, eleven points across the period, frame-100 fb.res byte-identical at
; every one of them: the rasterizer draws a smooth single-minimum curve from
; 245.44 ms at phase 32 to 241.25 ms at phase 128, with a flat basin over
; 112..160.  128 is that minimum and is chosen for the basin, not the tick.
; Against the shipped phase 0 it is -3.09 ms of rasterizer and -3.1 ms of
; frame.  Do not "clean this up" back to a bare cnop: phase 0 is 3.1 ms slow
; and 32/64 are 4.2 ms slow, and the value is not derivable, only measured.
OPAQUE_CLUT_PHASE = 128
	cnop	0,4096
	ds.b	OPAQUE_CLUT_PHASE
texture_page_falcon_opaque_clut_buffer
	ds.w	TIM_PAGE_COUNT*CLUT_BANK_COUNT*TIM_CLUT_ENTRIES
	ds.b	256-OPAQUE_CLUT_PHASE

; Active Ordering Table interval for the current frame.  Kept after all
; pre-existing shipping buffers so no measured cache phase moves.
gpu_ot_bucket_min
	ds.l	1
gpu_ot_bucket_max
	ds.l	1

	ifd	TREX_OCCL
; Occlusion instrumentation storage, at the very end of the section like every
; other bulk buffer.  Roughly 371 KB, which only this binary carries.
;
; One 16-bit owner id per screen-buffer pixel, covering BOTH double-buffer
; halves: that is what makes OCCL_OWNER_DELTA a single assembly-time constant
; usable from the pixel loops, whichever half is being drawn into.
; Sized with the same SCREEN_ALIGN slack as screen_buffer_raw, because
; gpu_open rounds the video base up inside that slack: the owner buffer has to
; tolerate the identical offset, or the second half's last rows would write
; past its end.
occl_owner_raw
	ds.b	(2*SCREEN_BUFFER_BYTES)+SCREEN_ALIGN
OCCL_OWNER_DELTA	= occl_owner_raw-screen_buffer_raw

; One 48-byte record per drawn packet, filled in far-to-near OT walk order.
occl_record_buffer
	ds.b	OCCL_RECORD_BYTES*TREX_PRIMITIVES

; Global source triangle index per submit slot, written by occl_note_source
; while the packets are built and read back during the walk.
occl_source_index
	ds.l	TREX_PRIMITIVES

occl_header_buffer
	ds.l	16

; Draw rank of the packet being rasterized, held twice: as the counter and as
; the 16-bit value the pixel loops store without touching a register.
occl_rank
	ds.l	1
occl_owner_id
	ds.w	1
	even
occl_record_ptr
	ds.l	1
occl_packet_ptr
	ds.l	1
; Cumulative count of texels the bit-17 transparency test rejected, the
; companion of raster_pixel_count.
occl_drop_count
	ds.l	1
occl_written_mark
	ds.l	1
occl_dropped_mark
	ds.l	1
occl_span_x0
	ds.l	1
occl_span_x1
	ds.l	1
occl_span_y0
	ds.l	1
occl_span_y1
	ds.l	1
occl_frame_written_mark
	ds.l	1
occl_frame_dropped_mark
	ds.l	1
	endc

	ifd	TREX_PREPASS
; Prepass storage, at the very end of the section like every other bulk buffer
; (see the layout note above dsp_triangle_load_tx_buffer).  About 13 KB, and
; only the prepass binary carries it.
;
prepass_stats_buffer
	ds.l	PREPASS_STATS_LONGS
	endc

	ifd	TREX_FPS
; Overlay state, placed after every bulk buffer so enabling the flag cannot
; shift the pinned framebuffer, CLUT or raster regions above it.  TOS clears
; BSS on load, so fps_last_tick starts at zero and trex_dummy_frame primes it
; with the real clock before the first frame is drawn.
fps_last_tick
	ds.l	1
; One font-cell index per character, not ASCII.
fps_text
	ds.b	FPS_TEXT_CHARS
	even
	endc

	end
