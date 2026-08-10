; -----------------------------------------------------------------------------
; T-Rex DSP geometry preprocessor for the Motorola DSP56001
;
; The Falcon/M68030 sends the base mesh once and then sends only frame state.
; This program keeps the DSP busy with the fixed-point work which otherwise
; competes with the software renderer on the M68030:
;
;   - object-space translation and 3x3 matrix transform
;   - optional per-frame animation bias
;   - perspective projection
;   - triangle average-Z keys for Ordering Table preparation
;   - per-face flat shading against a camera-space light direction
;
; The DSP does not own TMD/TIM parsing or the final rasterizer.  The host still
; owns texture/CLUT handling, packet construction and GPU/Videl submission.
;
; All values are native 24-bit DSP words.  Counts are exact counts, not
; count-minus-one values.  Host-port words are transferred in this order:
;
;   CMD_LOAD_VERTICES:
;       count, followed by count * (x,y,z)
;
;   CMD_LOAD_NORMALS:
;       count, followed by count * (nx,ny,nz)
;       one unit object-space face normal per triangle, in triangle order
;
;   CMD_SET_FRAME:
;       9 matrix words, 3 translation words, 3 animation-bias words,
;       focal length, screen centre x, screen centre y, near distance,
;       20 light words (six channel-scaled direction/intensity vectors
;       plus a 2-word ambient term; see LIGHT_COUNT below)
;
;   CMD_SET_ANIMATED_FRAME / CMD_LOAD_ANIMATION_GAIT /
;   CMD_APPLY_ANIMATION_TARGET / CMD_FINISH_ANIMATED_FRAME:
;       The PS1 choreography is split into acknowledged transactions.  BEGIN
;       receives matrix(9), translation(3), focal-x/focal-y/cx/cy/near(5)
;       and light(20).  GAIT receives first/count and count sign-extended XYZ
;       deltas; TARGET receives weight/first/count and the same raw stream.
;       FINISH transforms and projects the completed object-space work array.
;
;   CMD_GET_VERTICES:
;       returns count, followed by count * (screen-x, screen-y, z, flags)
;
;   CMD_LOAD_TRIANGLES:
;       count, followed by count * (index0 | index1<<12, index2 | normal0<<12,
;       normal1 | normal2<<12) -- three words per triangle since Gouraud,
;       the static index list, uploaded once and read by every chunk
;
;   CMD_BUILD_TRIANGLES:
;       receives count and the global index of the chunk's first triangle,
;       followed by the chunk's own UV pairs (two packed words per triangle,
;       since the corner-normal table displaced the old resident UV table --
;       see chunk_uvs); returns ACK_TRIANGLES followed by the SURVIVOR count.
;       The index records themselves are resident, so the fixed header is
;       three words in regardless of chunk size -- only the UV tail scales
;       with it -- and the ack must carry the survivor count because the
;       host sizes its GET_TRIANGLES receive before issuing it.
;
;   CMD_PREPASS:
;       receives one mode word and always returns ACK_PREPASS followed by the
;       survivor count of the last run ($ffffff after an overrun).  Mode 0
;       disarms, 1 arms the FINISH hook, and 2 or 3 runs the full prepass now.
;       The reply is always exactly two words; the old ordered-list dump was
;       removed to keep the full-mesh path inside the stock P/Y overlay.
;
;   CMD_GET_TRIANGLES:
;       returns ACK_GET_TRIANGLES, survivor count, and survivor count *
;       SPAN_RECORD_WORDS.  Rejected triangles send nothing.  Each record is
;       eighteen packed words -- see the layout at SPAN_RECORD_WORDS.
;
; The matrix layout matches rotate_translate in src/3d.asm: the nine words are
; consumed in the same order as the existing DSP implementation.
; -----------------------------------------------------------------------------

	include	'ioequ.inc'

TREX_VERTICES	= 1376
TREX_PRIMITIVES	= 2724
; Render target size.  Must match SCREEN_WIDTH/SCREEN_HEIGHT on the host: the
; bounding-box rejection below uses them to drop fully off-screen triangles.
; 240 since the host presents through a 256-pixel-wide Videl mode whose wide
; pixels cover the screen width 320 square ones used to.
SCREEN_WIDTH	= 240
SCREEN_HEIGHT	= 224
; Largest triangle chunk one BUILD_TRIANGLES call may carry.  32 since the
; span-setup record: at seventeen result words per survivor the output buffer
; is the largest X allocation after the resident arrays, and 64-triangle
; chunks would no longer fit beside the UV pairs.  There is no matching input
; buffer: the index list is resident, so a chunk command is three words.
MAX_CHUNK	= 32

; Words per survivor record, PACKED for the wire.  The host unpacks them
; into its twenty-two-field span-setup block (seventeen classic DDA fields
; plus five Gouraud level fields):
;
;   w0   slot_mid<<14 | slot_top<<12 | mid<<11 | shade<<5 | chunk-local index
;   w1   average-z / OT key
;   w2   rows_up<<12 | (sy0 & $fff)
;   w3   (sx0 & $fff)<<12 | rows_low
;   w4   sx1 & $fff
;   w5..w13  sl_long, sl_up, sl_low, du_dx, dv_dx,
;            dul_up, dvl_up, dul_low, dvl_low   (one word each)
;   w14  lvl_top<<12 | lvl_mid    (sorted corner levels, Q4.8 each)
;   w15  dlvl_dx                  (span level gradient, Q4.8)
;   w16  dlvl_up                  (left-chain level step, upper half)
;   w17  dlvl_low                 (left-chain level step, lower half)
;
; The 12-bit coordinate fields rely on the same |value| < 2048 bound the
; 12.12 slope format already imposes; the chunk-local index has five bits,
; so MAX_CHUNK must stay at most 32.  The sorted top/middle UV bytes are not
; sent at all: the host rebuilds them from its own texture metadata via the
; two slot ids.  The two level STARTS cannot be rebuilt -- they are lighting
; results -- which is why w14 carries them; both are non-negative and at
; most 15<<8, so two 12-bit fields hold them exactly.
SPAN_RECORD_WORDS	= 18

; Packing of the resident triangle index list.  Three words per triangle
; since Gouraud, each carrying two 12-bit fields (low field first):
;   word A = v0 | v1<<12
;   word B = v2 | n0<<12
;   word C = n1 | n2<<12
; TREX_VERTICES is 1376 and the corner-normal table has 3,610 entries, so 12
; bits cover both index spaces and no packed word reaches bit 23, which
; keeps it positive for LSR.
TRI_INDEX_BITS	= 12
TRI_INDEX_MASK	= $000fff

; Vertex fields need only eleven of their twelve bits (1,376 < 2,048), so the
; top bit of each is spare.  The occluder qualification the occlusion stage
; needs -- may this triangle's coverage seal anything, i.e. does it write
; opaquely everywhere -- rides in the v1 field's spare bit, which is bit 23 of
; word A.  It is host-owned (tools/o3d2opaque.py, the same sidecar the packet
; builder reads for OPAQUE_PACKET_BIT) and costs no memory here: the DSP has
; neither an X nor a Y word left for the full-mesh 114-word resident bitmap.
;
; Every vertex extraction therefore masks with TRI_VERTEX_MASK, including the
; two that come out of a shift and never used to mask at all.  Normal indices
; keep the full twelve bits and TRI_INDEX_MASK.
TRI_VERTEX_MASK	= $0007ff
TRI_OCCLUDER_BIT	= 23

; The PS1 corner-normal table, resident in full so the packed indices above
; address it directly with no remap.  It does not fit in one bank beside the
; index list: the Y window $09C0..$3FFF holds 13,888 words, the indices take
; 8,172, so the first NORMAL_Y_COUNT normals live there (5,715 words -- the
; window is full to its last-but-one word) and the remaining 1,705 sit in
; the X allocation the resident UV pairs used to occupy.  The split is on a
; NORMAL index, so the shading loop picks a bank with one compare per
; corner.  The displaced UV pairs now travel with each BUILD chunk instead.
NORMAL_TOTAL	= 3610
NORMAL_Y_COUNT	= 1905
NORMAL_X_COUNT	= NORMAL_TOTAL-NORMAL_Y_COUNT

; Flat-shading quantization.  The Lambert term is a 1.23 fraction in [0,1);
; shifting it right by SHADE_SHIFT keeps its top SHADE_BITS as an integer
; level, so SHADE_MAX means "surface pointing straight at the light".  The
; host owns the level-to-brightness ramp: it holds one preshaded CLUT bank
; per level, so shading costs the rasterizer nothing per pixel.
SHADE_BITS	= 4
SHADE_MAX	= 15
SHADE_SHIFT	= 23-SHADE_BITS
; The record carries the brightness level AND a two-bit tint class, so the
; host can index preshaded CLUT banks that carry the light's own colour.
TINT_BITS	= 2
TINT_COUNT	= 4
SHADE_FIELD_BITS	= SHADE_BITS+TINT_BITS

; Depth cueing.  The PS1 source blends every lit vertex toward a far colour of
; (0,0,0) as it recedes, via NCDS/NCDT/DPCS reading control registers RFC/GFC/
; BFC=black, DQA=-5000, DQB=$1400000, H=1000 (verified by hand-decoding
; TREX.EXE's fog-setup call chain at 0x80127700-0x80127744, which feeds
; 0x80139c18; see trex_analysis.md).  Those constants are calibrated to the
; PS1 GTE's own SZ=H/z divide, which this DSP does not compute -- reusing them
; verbatim against a different depth measure would be numerically meaningless,
; not more faithful.  make_triangle_zkey already sums the triangle's three
; un-divided camera-space Z words for painter's-algorithm sorting, so this
; refits the same "black beyond a distance, unattenuated up close" behaviour
; onto THAT key instead: read from the extracted choreography track, the
; object's camera-space Z runs from 62000 at frame 0 down to 6804 at its
; closest approach (~frame 180) and back out to 19655 at frame 273, so
; ZKEY_FOG_NEAR/RANGE below (three times those, since zkey is a sum of three)
; put frame 0 fully into the far colour and the closest approach fully lit.
; RANGE is one short of a power of two so the shift-normalize below can never
; carry into the sign bit at full scale.
ZKEY_FOG_NEAR	= 20000
ZKEY_FOG_RANGE	= 131071

CMD_PING		= 0
CMD_LOAD_VERTICES	= 1
CMD_SET_FRAME		= 2
CMD_GET_VERTICES	= 3
CMD_BUILD_TRIANGLES	= 4
CMD_GET_STATUS		= 5
CMD_GET_TRIANGLES	= 6
CMD_LOAD_NORMALS	= 7
CMD_LOAD_TRIANGLES	= 8
CMD_PREPASS		= 10
CMD_SET_ANIMATED_FRAME	= 12
CMD_LOAD_ANIMATION_GAIT	= 13
CMD_APPLY_ANIMATION_TARGET	= 14
CMD_FINISH_ANIMATED_FRAME	= 15
CMD_RESET		= $7f

ACK_PING		= $700001
ACK_LOAD		= $700002
ACK_FRAME		= $700003
ACK_VERTICES		= $700004
ACK_TRIANGLES		= $700005
ACK_STATUS		= $700006
ACK_RESET		= $700007
CULLED_MARKER		= $7fffff
ACK_GET_TRIANGLES	= $700008
ACK_NORMALS		= $700009
ACK_LOAD_TRIANGLES	= $70000a
ACK_LOAD_UVS		= $70000b
ACK_ANIMATION_BEGIN	= $70000c
ACK_ANIMATION_GAIT	= $70000d
ACK_ANIMATION_TARGET	= $70000e
ACK_PREPASS		= $70000f
ERR_BAD_COMMAND		= $7fffff

; -----------------------------------------------------------------------------
; Occlusion prepass constants
;
; The prepass reproduces the host's Ordering-Table bucket rule bit for bit so
; the order it hands to a later culling stage is the order the host actually
; draws in.  OT_LENGTH and OT_KEY_SHIFT MUST stay equal to the constants of
; the same name in TREX/m68030/trex_m68030.s; gpu_submit_ot maps a negative
; key to bucket 0 and otherwise shifts right by OT_KEY_SHIFT and saturates.
; -----------------------------------------------------------------------------
OT_LENGTH	= 2048
OT_KEY_SHIFT	= 8
PREPASS_ENTRY_BUCKET_MASK	= $000fff

; Capacity of the order list.  Two lists of PREPASS_MAX words plus the full
; triangle kill bitmap and status cells must fit from chunk_uvs to the top of
; physical X memory.  The stock full mesh needs 114 bitmap words (2,724 bits),
; leaving 723 entries for the two radix lists.  An overrun is counted and
; reported rather than assumed away, and leaves the frame unculled.
PREPASS_MAX	= 723

; LSD radix sort over the eleven bucket bits, two passes of six bits.  The
; second digit masks six bits although only five of them can ever be set:
; the entry packs the triangle index from bit 12 upwards and the bucket is at
; most 2047, so bit 11 is always clear.  One mask constant therefore serves
; both digits and the second counter bank stays 32 words.
PREPASS_RADIX_BITS	= 6
PREPASS_DIGIT_MASK	= $00003f
PREPASS_CNT_LO_COUNT	= 64
PREPASS_CNT_HI_COUNT	= 32
PREPASS_CNT_COUNT	= PREPASS_CNT_LO_COUNT+PREPASS_CNT_HI_COUNT

; Stage-2/3 occlusion working set.  A 4x4 pixel cell is the smallest mask
; that fits twice in the phase-local scratch allocation.  The two masks are
; coverage sealed by strictly nearer buckets and coverage pending in the
; current bucket; pending coverage is merged only at a bucket boundary.
OCCL_CELL_SIZE	= 4
OCCL_CELL_COLS	= SCREEN_WIDTH/OCCL_CELL_SIZE
OCCL_CELL_ROWS	= SCREEN_HEIGHT/OCCL_CELL_SIZE
OCCL_MASK_ROW_WORDS	= (OCCL_CELL_COLS+23)/24
OCCL_MASK_WORDS	= OCCL_CELL_ROWS*OCCL_MASK_ROW_WORDS

; One bit per full-mesh triangle.  The bitmap is cleared before every run and
; is read by BUILD_TRIANGLES only while the prepass is armed.
PREPASS_KILL_WORDS	= (TREX_PRIMITIVES+23)/24
PREPASS_STATUS_WORDS	= 8

; -----------------------------------------------------------------------------
; Program entry
; -----------------------------------------------------------------------------
;
; Every JMP/JSR/Jcc to a label in this file carries the "<" prefix, which
; forces the assembler's 12-bit short absolute form.  Without it the assembler
; sizes forward references in pass 1 and has to assume the long form, so each
; forward jump spends an extra extension word: 168 of them, against a program
; that must not grow past P:$09BF (see the layout note at the end of this
; file).  The short form is semantically identical -- same target, same
; condition, same stack effect -- and dropping the prefix costs code space
; without changing behaviour.
;
; The 12-bit form reaches P:$0FFF, comfortably past the $09BF ceiling the Y/P
; overlay imposes, so every legal target fits by construction.  The one cost
; is that a target out of range now aborts the assembly instead of silently
; widening; that is the intended failure mode here.
;
; JCLR/JSET are two-word instructions regardless and take no prefix.  So do
; the two "jpl *+2" delay-slot skips, which have no label operand.  The
; retired projected-vertex streamer also had one intentionally long JSR; it
; is kept only in the historical layout note below.

	org	p:$0

	jmp	<main

	org	p:$40

main
	; Host-port mode, same setup as the original 3d.asm program.
	movep	#1,x:m_pbc

main_loop
	jsr	<receive_word

	; Decode the small command set by testing bits in X0.  This avoids relying
	; on accumulator word alignment for a 24-bit host-port command and keeps
	; each JCLR delay slot explicit.
	; RESET has all low seven bits set and would otherwise alias command 15
	; after the animation commands occupied 13/15.  Dispatch the high-bit
	; control range first; command $7f is its only defined member.
	jclr	#6,x0,dispatch_command_low
	nop
	jmp	<command_reset

dispatch_command_low
	jclr	#0,x0,dispatch_even
	nop

	; Odd commands: 1 = LOAD, 3 = GET, 5 = STATUS, 7 = LOAD_NORMALS,
	; 13 = LOAD_ANIMATION_GAIT, 15 = FINISH_ANIMATED_FRAME, $7f = RESET.
	jclr	#1,x0,dispatch_odd_bit1_clear
	nop
	; Command 3 was GET_VERTICES.  The span-setup record retired it from the
	; normal path (section 4.1c) and the occlusion stage needed its program
	; words, so it now answers ERR_BAD_COMMAND.  That is deliberate: a host
	; that still calls it -- span_validate_enabled, or the projected-vertex
	; fallback -- gets a wrong ack and takes its shadow path instead of
	; deadlocking on a reply that never comes.
	jclr	#2,x0,dispatch_bad_command
	nop
	jclr	#3,x0,command_load_normals
	nop
	jmp	<command_finish_animated_frame

dispatch_odd_bit1_clear
	jclr	#2,x0,command_load_vertices
	nop
	jclr	#3,x0,command_get_status
	nop
	jmp	<command_load_animation_gait

dispatch_even
	; Even commands: 0 = PING, 2 = SET_FRAME, 4 = BUILD_TRIANGLES,
	; 6 = GET_TRIANGLES, 8 = LOAD_TRIANGLES, 10 = PREPASS, and
	; 12 = SET_ANIMATED_FRAME and 14 = APPLY_ANIMATION_TARGET.
	jclr	#2,x0,dispatch_even_low
	nop
	jclr	#3,x0,dispatch_even_bit3_clear
	nop
	jclr	#1,x0,command_set_animated_frame
	nop
	jmp	<command_apply_animation_target

dispatch_even_bit3_clear
	; 4 and 6 share bit2 set / bit3 clear; bit1 separates them.
	jclr	#1,x0,command_build_triangles
	nop
	jmp	<command_get_triangles

dispatch_even_low
	jclr	#1,x0,dispatch_even_low_bit1_clear
	nop
	; 2 and 10 share bit1 set; bit 3 separates them.  Command 10 was
	; LOAD_UVS until the corner normals displaced the resident pair table;
	; the UVs ride each BUILD chunk now, which left 10 as the only leaf of
	; this tree that reached dispatch_bad_command.  CMD_PREPASS took it, so
	; it costs no extra JCLR level and no extra NOP.  9 and 11 remain
	; unusable: they are silent aliases of 1 and 3.
	jclr	#3,x0,command_set_frame
	nop
	jmp	<command_prepass

dispatch_even_low_bit1_clear
	; 0 and 8 both have bits 0..2 clear, so this level has to look at bit 3.
	; Without it command 8 would land on command_ping, which is what an
	; earlier version of this dispatcher did.
	jclr	#3,x0,command_ping
	nop
	jmp	<command_load_triangles

dispatch_bad_command
	; No leaf reaches this any more now that CMD_PREPASS occupies command
	; 10.  It is kept because every command number 0..15 is now assigned
	; and a future split of one of the JCLR levels needs the landing pad
	; back; it costs three words and never executes.
	move	#ERR_BAD_COMMAND,x0
	jsr	<send_word
	jmp	<main_loop

; -----------------------------------------------------------------------------
; Command handlers
; -----------------------------------------------------------------------------

command_ping
	move	#ACK_PING,x0
	jsr	<send_word
	jmp	<main_loop

command_load_vertices
	jsr	<receive_word
	move	x0,y:<vertex_count
	move	#base_vertices,r0

	; Three host words per vertex.  The original T-Rex mesh has 1376 vertices;
	; the buffer is deliberately sized for that mesh.
	do	x0,load_vertex_loop
	jsr	<receive_word
	move	x0,x:(r0)+
	jsr	<receive_word
	move	x0,x:(r0)+
	jsr	<receive_word
	move	x0,x:(r0)+
load_vertex_loop

	move	#ACK_LOAD,x0
	jsr	<send_word
	move	y:<vertex_count,x0
	jsr	<send_word
	jmp	<main_loop

command_load_normals
	; The complete PS1 corner-normal table, one unit object-space normal
	; per entry in TMD normal order, split across the banks as NORMAL_Y_COUNT
	; documents: the first block fills the Y window behind the index list,
	; the remainder lands in X where the resident UV pairs used to live.
	; The host sends the full table for both mesh variants; the packed
	; triangle indices address it directly.
	jsr	<receive_word
	move	x0,y:<normal_count
	move	#corner_normals_y,r0
	move	#>3*NORMAL_Y_COUNT,x0
	do	x0,load_normal_y_loop
	jsr	<receive_word
	move	x0,y:(r0)+
load_normal_y_loop

	move	#corner_normals_x,r0
	move	#>3*NORMAL_X_COUNT,x0
	do	x0,load_normal_x_loop
	jsr	<receive_word
	move	x0,x:(r0)+
load_normal_x_loop

	move	#>1,x0
	move	x0,y:<normals_loaded

	move	#ACK_NORMALS,x0
	jsr	<send_word
	move	y:<normal_count,x0
	jsr	<send_word
	jmp	<main_loop

command_load_triangles
	; The (i0,i1,i2) index list never changes for the whole run, so it is
	; uploaded once here instead of being re-sent with every chunk.  The old
	; protocol pushed 4 words per triangle per frame: 10,896 words, 49% of all
	; host-port traffic, for data that was identical every time.
	;
	; Three packed words per triangle arrive in the order the host builds
	; them -- vertex AND corner-normal indices since Gouraud; see
	; TRI_INDEX_BITS above for the field layout.  The material word is
	; gone: the DSP stored it and never read it, and the host looks its own
	; copy up by source index when it builds packets.
	jsr	<receive_word
	move	x0,y:<triangle_list_count
	move	#triangle_indices,r0

	do	x0,load_triangle_loop
	jsr	<receive_word
	move	x0,y:(r0)+
	jsr	<receive_word
	move	x0,y:(r0)+
	jsr	<receive_word
	move	x0,y:(r0)+
load_triangle_loop

	move	#>1,x0
	move	x0,y:<triangles_loaded

	move	#ACK_LOAD_TRIANGLES,x0
	jsr	<send_word
	move	y:<triangle_list_count,x0
	jsr	<send_word
	jmp	<main_loop

command_set_frame
	; Matrix is in Y memory because the MAC-heavy transform reads it there.
	move	#frame_matrix,r0
	do	#9,set_matrix_loop
	jsr	<receive_word
	move	x0,y:(r0)+
set_matrix_loop

	; Translation and animation bias are kept separately.  The bias is folded
	; into the translation before the transform, leaving a hook for a future
	; streamed per-vertex animation decoder without changing the protocol.
	move	#object_translation,r0
	do	#3,set_translation_loop
	jsr	<receive_word
	move	x0,x:(r0)+
set_translation_loop

	move	#animation_bias,r0
	do	#3,set_bias_loop
	jsr	<receive_word
	move	x0,y:(r0)+
set_bias_loop

	jsr	<receive_word
	move	x0,y:<projection_focal
	move	x0,y:<projection_focal_y
	jsr	<receive_word
	move	x0,y:<projection_cx
	jsr	<receive_word
	move	x0,y:<projection_cy
	jsr	<receive_word
	move	x0,y:<projection_near

	; Light direction in CAMERA space, so the light stays put while the
	; object turns.  The host sends a unit 1.23 vector pointing from the
	; surface towards the light.
	move	#light_direction,r0
	do	#LIGHT_COUNT*6+2,set_light_loop
	jsr	<receive_word
	move	x0,y:(r0)+
set_light_loop

	jsr	<apply_animation_bias
	jsr	<transform_vertices
	jsr	<project_vertices

	move	#ACK_FRAME,x0
	jsr	<send_word
	move	y:<vertex_count,x0
	jsr	<send_word
	jmp	<main_loop

command_set_animated_frame
	; Begin one exact Demo One choreography frame.  The data stream is split
	; into acknowledged commands because TOS 4.02's Dsp_BlkUnpacked source
	; walk cannot safely cross a 64-KiB host-address boundary.  This header is
	; followed by one or more GAIT/TARGET commands and one FINISH command.
	move	#frame_matrix,r0
	do	#9,set_animated_matrix_loop
	jsr	<receive_word
	move	x0,y:(r0)+
set_animated_matrix_loop

	move	#object_translation,r0
	do	#3,set_animated_translation_loop
	jsr	<receive_word
	move	x0,x:(r0)+
set_animated_translation_loop

	jsr	<receive_word
	move	x0,y:<projection_focal
	jsr	<receive_word
	move	x0,y:<projection_focal_y
	jsr	<receive_word
	move	x0,y:<projection_cx
	jsr	<receive_word
	move	x0,y:<projection_cy
	jsr	<receive_word
	move	x0,y:<projection_near

	move	#light_direction,r0
	do	#LIGHT_COUNT*6+2,set_animated_light_loop
	jsr	<receive_word
	move	x0,y:(r0)+
set_animated_light_loop

	move	#ACK_ANIMATION_BEGIN,x0
	jsr	<send_word
	jmp	<main_loop

command_load_animation_gait
	; first vertex, vertex count, then count signed XYZ gait deltas.  The
	; command may be repeated; each chunk expands base+gait directly into the
	; dense object-space camera allocation.
	jsr	<receive_word
	tfr	x0,a
	add	x0,a
	add	x0,a
	move	#base_vertices,x1
	add	x1,a
	move	a1,r0

	tfr	x0,a
	add	x0,a
	add	x0,a
	move	#camera_vertices,x1
	add	x1,a
	move	a1,r2

	jsr	<receive_word
	move	x0,y:<animation_vertices_remaining

set_animated_gait_loop
	jsr	<receive_animation_delta
	move	x:(r0)+,x0
	move	y:animation_delta_x,a
	add	x0,a
	move	a1,x:(r2)+
	move	x:(r0)+,x0
	move	y:animation_delta_y,a
	add	x0,a
	move	a1,x:(r2)+
	move	x:(r0)+,x0
	move	y:animation_delta_z,a
	add	x0,a
	move	a1,x:(r2)+
	move	y:<animation_vertices_remaining,a
	move	#>1,x0
	sub	x0,a
	move	a1,y:<animation_vertices_remaining
	tst	a
	jne	<set_animated_gait_loop

	move	#ACK_ANIMATION_GAIT,x0
	jsr	<send_word
	jmp	<main_loop

command_apply_animation_target
	; signed Q12 weight, first vertex, count, signed XYZ target deltas.
	jsr	<receive_word
	move	x0,y:animation_weight
	jsr	<receive_word
	; r0 = camera_vertices + 3 * first_vertex.
	tfr	x0,a
	add	x0,a
	add	x0,a
	move	#camera_vertices,x1
	add	x1,a
	move	a1,r0
	jsr	<receive_word
	move	x0,y:<animation_target_vertex_count

	move	y:<animation_target_vertex_count,x0
	move	x0,y:<animation_vertices_remaining
set_animated_target_vertex_loop
	jsr	<receive_animation_delta

	move	y:animation_delta_x,x1
	move	y:animation_weight,y1
	mpy	x1,y1,a
	rep	#11
	asl	a
	move	a1,x0
	move	x:(r0),a
	add	x0,a
	move	a1,x:(r0)+

	move	y:animation_delta_y,x1
	move	y:animation_weight,y1
	mpy	x1,y1,a
	rep	#11
	asl	a
	move	a1,x0
	move	x:(r0),a
	add	x0,a
	move	a1,x:(r0)+

	move	y:animation_delta_z,x1
	move	y:animation_weight,y1
	mpy	x1,y1,a
	rep	#11
	asl	a
	move	a1,x0
	move	x:(r0),a
	add	x0,a
	move	a1,x:(r0)+
	move	y:<animation_vertices_remaining,a
	move	#>1,x0
	sub	x0,a
	move	a1,y:<animation_vertices_remaining
	tst	a
	jne	<set_animated_target_vertex_loop

	move	#ACK_ANIMATION_TARGET,x0
	jsr	<send_word
	jmp	<main_loop

command_finish_animated_frame
	jsr	<transform_animated_vertices
	jsr	<project_vertices

	; The only point that lies inside the host's cross-frame window.  Once
	; the first send_word below has gone out the DSP blocks in the second
	; word of the acknowledgement and stops reading HRX until the host has
	; finished rasterizing, so a separate command sent after FINISH would
	; run after the rasterizer instead of beside it.
	;
	; y:prepass_armed is dc 0 and only CMD_PREPASS ever writes it.  A host
	; that never sends command 10 therefore pays three instructions per
	; frame here and nothing else.
	move	y:prepass_armed,a
	tst	a
	jeq	<finish_no_prepass
	jsr	<prepass_run
finish_no_prepass

	move	#ACK_FRAME,x0
	jsr	<send_word
	move	y:<vertex_count,x0
	jsr	<send_word
	jmp	<main_loop

; command_get_vertices lived here until the occlusion stage claimed its
; twenty-one program words.  It streamed the whole projected-vertex array back
; to the host, which the span-setup record made unnecessary on the normal path
; in section 4.1c; the dispatcher now routes command 3 to dispatch_bad_command.
; The old prepass ordered-list streamer was removed with the mode-3 dump; the
; fixed two-word PREPASS acknowledgement is the only reply path now.

command_build_triangles
	; One chunk of up to MAX_CHUNK triangles.  BUILD_TRIANGLES acknowledges
	; with the survivor count; GET_TRIANGLES then returns eighteen words per
	; survivor (the packed span-setup record).  Culled triangles cost no
	; result words at all -- at the measured 27% survival rate that is the
	; bulk of the result traffic gone.
	;
	; Since CMD_LOAD_TRIANGLES the index list is resident, so a chunk command
	; is just (count, base) and nothing is received past this point.  That
	; also retires the input buffering this routine used to need: replying
	; while the host was still pushing the same block deadlocked both sides --
	; the DSP blocked in send_word once HTX filled, stopped draining HRX, and
	; the host blocked in turn.  With three words in and everything else out,
	; each Dsp_BlkUnpacked is now one-directional by construction rather than
	; by careful sequencing.
	jsr	<receive_word
	move	x0,y:triangle_count

	; Global index of the chunk's first triangle.  It addresses the resident
	; index list, while the survivor keys the host gets back stay chunk-local.
	jsr	<receive_word
	move	x0,y:triangle_base
	; BUILD chunks arrive in ascending global order.  Reset the streaming
	; kill-bitmap cursor at the first chunk of each armed frame; the cursor is
	; kept in the otherwise-unused prepass status cells across commands.
	move	y:prepass_armed,a
	tst	a
	jeq	<build_no_kill_cursor_reset
	move	y:triangle_base,a
	tst	a
	jne	<build_no_kill_cursor_reset
	move	#prepass_kill,x0
	move	x0,x:prepass_status
	move	#>1,x1
	move	x1,x:prepass_status+1
build_no_kill_cursor_reset

	; The chunk's UV pairs follow the command since the corner normals
	; displaced the resident table from X: two packed words per triangle in
	; chunk order.  make_triangle_span reads them chunk-locally, so the
	; global base plays no part in their addressing.
	move	y:triangle_count,a
	tst	a
	jeq	<build_no_uvs
	move	a1,x0
	add	x0,a
	move	a1,x0
	move	#chunk_uvs,r0
	do	x0,build_uv_loop
	jsr	<receive_word
	move	x0,x:(r0)+
build_uv_loop
build_no_uvs

	clr	a
	move	a1,y:triangle_index
	move	a1,y:triangle_out_count
	move	#triangle_out,r1

	; r2 -> triangle_indices + 3 * triangle_base
	move	y:triangle_base,a
	move	a1,x0
	add	x0,a
	add	x0,a
	move	#triangle_indices,x0
	add	x0,a
	move	a1,r2

	move	y:triangle_count,x0
	move	x0,y:triangle_remaining
	tfr	x0,a
	tst	a
	jeq	<triangle_reply
triangle_count_loop
	; Unpack the three resident words into three vertex and three corner-
	; normal indices.  LSR, not ASR: the fields are unsigned and a stray
	; sign extension would index far outside either table.
	move	y:(r2)+,x1
	move	y:(r2)+,y1
	move	#>TRI_VERTEX_MASK,x0
	tfr	x1,a
	and	x0,a
	move	a1,y:triangle_i0
	tfr	x1,a
	rep	#TRI_INDEX_BITS
	lsr	a
	; The occluder bit lands in bit 11 after this shift; mask it off or the
	; vertex lookup reads 2,048 entries past v1.
	and	x0,a
	move	a1,y:triangle_i1
	tfr	y1,a
	and	x0,a
	move	a1,y:triangle_i2
	tfr	y1,a
	rep	#TRI_INDEX_BITS
	lsr	a
	move	a1,y:triangle_n0
	move	y:(r2)+,y1
	move	#>TRI_INDEX_MASK,x0
	tfr	y1,a
	and	x0,a
	move	a1,y:triangle_n1
	tfr	y1,a
	rep	#TRI_INDEX_BITS
	lsr	a
	move	a1,y:triangle_n2

	; The armed prepass has already classified and bucket-ordered this frame.
	; Its kill bitmap is conservative and is indexed by the GLOBAL triangle
	; number, not this chunk-local survivor key.  An unarmed DSP never reads
	; the bitmap, so the normal shipping path remains unchanged.
	move	y:prepass_armed,a
	tst	a
	jeq	<build_triangle_not_killed
	move	x:prepass_status,x0
	move	x0,r0
	move	x:prepass_status+1,x1
	move	x:(r0),a
	and	x1,a
	move	a1,y:span_flip
	; Advance the streaming bit cursor inline.  This is on every armed
	; triangle, so the call/return pair costs more than the small body.
	move	x1,a
	asl	a
	move	a1,x1
	tst	a
	jne	<build_prepass_kill_advance_store
	move	#>1,x1
	move	x:prepass_status,a
	move	#>1,x0
	add	x0,a
	move	a1,x:prepass_status
build_prepass_kill_advance_store
	move	x1,x:prepass_status+1
	move	y:span_flip,a
	tst	a
	jne	<triangle_culled
build_triangle_not_killed

	jsr	<make_triangle_area
	tst	a
	; Backface culling.  The sign of the screen-space area is the winding, so
	; one comparison drops both the degenerate triangles (area 0) and the ones
	; facing away.  The PS1 fixed-view conversion negates the matrix's third
	; row, changing its determinant from positive to negative in all 274
	; choreography frames.  That handedness flip makes NEGATIVE screen area
	; front-facing.  Zero and positive area are therefore rejected here.
	jge	<triangle_culled

	; Clipped bounding box, only for the area survivors: the two culls above
	; need no box, and at 27% survival the min/max/clamp work runs a quarter
	; as often here as it would before the area test.  A box that clips
	; empty is fully off-screen and rejected -- the same set the separate
	; fully-outside pre-test used to catch before it was subsumed here.
	jsr	<make_triangle_bbox
	tst	a
	jeq	<triangle_culled

	jsr	<make_triangle_zkey
	jsr	<make_triangle_shade
	jsr	<make_triangle_span

	; Survivor record, eighteen packed words -- see SPAN_RECORD_WORDS for
	; the exact layout.  w0 composes by shifting fields in from the top:
	; slot_mid, slot_top, mid, shade, chunk-local index.  The host unpacks
	; and validates every field against its own arithmetic.
	move	y:span_slot1,a
	rep	#2
	asl	a
	move	y:span_slot0,x0
	add	x0,a
	asl	a	y:span_mid,x0
	add	x0,a
	rep	#SHADE_FIELD_BITS
	asl	a
	move	y:triangle_shade,x0
	add	x0,a
	rep	#5
	asl	a
	move	y:triangle_index,x0
	add	x0,a
	move	a1,x:(r1)+			; w0
	move	y:triangle_zkey,x0
	move	x0,x:(r1)+			; w1
	move	y:span_rows_up,a
	rep	#12
	asl	a
	move	y:span_sy0,b
	move	#>$fff,x0
	and	x0,b
	add	b,a
	move	a1,x:(r1)+			; w2
	move	y:span_sx0,a
	move	#>$fff,x0
	and	x0,a
	rep	#12
	asl	a
	move	y:span_rows_low,b
	add	b,a
	move	a1,x:(r1)+			; w3
	move	y:span_sx1,a
	move	#>$fff,x0
	and	x0,a
	move	a1,x:(r1)+			; w4
	move	y:span_sl_long,x0
	move	x0,x:(r1)+
	move	y:span_sl_up,x0
	move	x0,x:(r1)+
	move	y:span_sl_low,x0
	move	x0,x:(r1)+
	move	y:span_dudx,x0
	move	x0,x:(r1)+
	move	y:span_dvdx,x0
	move	x0,x:(r1)+
	move	y:span_dul_up,x0
	move	x0,x:(r1)+
	move	y:span_dvl_up,x0
	move	x0,x:(r1)+
	move	y:span_dul_low,x0
	move	x0,x:(r1)+
	move	y:span_dvl_low,x0
	move	x0,x:(r1)+			; w13
	; The Gouraud tail: both sorted level starts share w14 (Q4.8 each,
	; non-negative, at most 15<<8), the three gradients follow plain.
	move	y:span_sl0,a
	rep	#12+8
	asl	a				; (sl0<<8) << 12
	move	y:span_sl1,b
	rep	#8
	asl	b				; sl1 << 8
	add	b,a
	move	a1,x:(r1)+			; w14
	move	y:span_dldx,x0
	move	x0,x:(r1)+			; w15
	move	y:span_dll_up,x0
	move	x0,x:(r1)+			; w16
	move	y:span_dll_low,x0
	move	x0,x:(r1)+			; w17
	move	y:triangle_out_count,a
	move	#>1,x0
	add	x0,a
	move	a1,y:triangle_out_count
	jmp	<triangle_advance

triangle_culled
	; Survivors only: a culled triangle writes and later sends nothing.
	; The chunk-local index inside the survivor key is what lets the host
	; re-associate each record with its source triangle.
triangle_advance
	move	y:triangle_index,a
	move	#>1,x0
	add	x0,a
	move	a1,y:triangle_index

	move	y:triangle_remaining,a
	move	#>1,x0
	sub	x0,a
	move	a1,y:triangle_remaining
	tst	a
	jne	<triangle_count_loop

triangle_reply
	; The acknowledgement carries the SURVIVOR count, not the chunk size:
	; Dsp_BlkUnpacked transfers a word count fixed before the call, so the
	; host must learn the reply size here to size its GET_TRIANGLES receive.
	; A fully-culled chunk reports zero and the host skips the fetch.
	move	#ACK_TRIANGLES,x0
	jsr	<send_word
	move	y:triangle_out_count,x0
	jsr	<send_word
	jmp	<main_loop

command_get_triangles
	; Returns the survivor records buffered by the last CMD_BUILD_TRIANGLES
	; chunk: eighteen packed words each, nothing for culled triangles.
	move	#ACK_GET_TRIANGLES,x0
	jsr	<send_word
	move	y:triangle_out_count,x0
	jsr	<send_word

	move	y:triangle_out_count,a
	tst	a
	jeq	<triangle_count_done
	; Total words = survivors * SPAN_RECORD_WORDS = count*16 + count*2.
	; This shift-and-add mirrors the CONSTANT: it seared one revision when
	; the record grew to 18 while this arithmetic still computed 14 -- the
	; host then read 14*S words and unpacked them at an 18-word stride,
	; the exact shear class section 4.1b documents.
	rep	#4
	asl	a
	move	y:triangle_out_count,x0
	add	x0,a
	add	x0,a
	move	a1,y:triangle_remaining
	move	#triangle_out,r0
	nop
triangle_send_loop
	move	x:(r0)+,x0
	jsr	<send_word
	move	y:triangle_remaining,a
	move	#>1,x0
	sub	x0,a
	move	a1,y:triangle_remaining
	tst	a
	jne	<triangle_send_loop
triangle_count_done
	jmp	<main_loop

command_get_status
	move	#ACK_STATUS,x0
	jsr	<send_word
	move	y:<vertex_count,x0
	jsr	<send_word
	move	y:<frames_processed,x0
	jsr	<send_word
	move	y:<triangles_processed,x0
	jsr	<send_word
	jmp	<main_loop

command_reset
	clr	a
	move	a1,y:<vertex_count
	move	a1,y:<normal_count
	move	a1,y:<normals_loaded
	move	a1,y:<triangle_list_count
	move	a1,y:<triangles_loaded
	move	a1,y:<frames_processed
	move	a1,y:<triangles_processed
	move	#ACK_RESET,x0
	jsr	<send_word
	jmp	<main_loop

; -----------------------------------------------------------------------------
; Host-port primitives
; -----------------------------------------------------------------------------

receive_word
	jclr	#0,x:m_hsr,*
	movep	x:m_hrx,x0
	nop
	rts

send_word
	jclr	#1,x:m_hsr,*
	movep	x0,x:m_htx
	rts

receive_animation_delta
	; TOS's synchronous host-port service expects the DSP to consume words
	; promptly.  The M68030 therefore sign-extends each source int16 once and
	; sends x/y/z as three native 24-bit words; avoiding the old two-word
	; bitstream removes 64 single-bit shifts from every animated vertex.
	jsr	<receive_word
	move	x0,y:animation_delta_x
	jsr	<receive_word
	move	x0,y:animation_delta_y
	jsr	<receive_word
	move	x0,y:animation_delta_z
	rts

; -----------------------------------------------------------------------------
; Frame processing
; -----------------------------------------------------------------------------

apply_animation_bias
	; Add three frame-dependent bias words to the object translation.
	; This is intentionally cheap now; the same stage is the insertion point
	; for the T-Rex's real frame/deformation stream.
	move	x:object_translation,x0
	move	y:<animation_bias,a
	add	x0,a	x:object_translation+1,x0
	move	a1,x:object_translation

	move	y:<animation_bias+1,a
	add	x0,a	x:object_translation+2,x0
	move	a1,x:object_translation+1

	move	y:<animation_bias+2,a
	add	x0,a
	move	a1,x:object_translation+2
	rts

transform_vertices
	; This is the MAC pipeline from src/3d.asm:rotate_translate, with the
	; static T-Rex base mesh preserved and a separate camera-space output.
	;
	; Each component is rounded (RND) before the store.  MOVE A1 alone
	; truncates, and the 1.23 matrix cannot represent exactly 1.0 -- the
	; identity entry $7fffff is 1 - 2^-23 -- so a plain truncation turns
	; 1000 + 1000*$7fffff into 1999 instead of 2000.  The resulting one-unit
	; shortfall propagates into the projection and collapses vertices that
	; should stay a pixel apart.
	move	y:<vertex_count,x0
	move	#base_vertices,r0
	move	#object_translation,r1
	move	#camera_vertices,r2
	move	#frame_matrix,r4
	move	#8,n4

	move	x:(r1)+,y1
	tfr	y1,a	x:(r0)+,x1	y:(r4)+,y0

	do	x0,transform_loop
	mac	x1,y0,a	x:(r0)+,x0	y:(r4)+,y0
	mac	x0,y0,a	x:(r0)-,x0	y:(r4)+,y0
	mac	x0,y0,a	x:(r1)+,x0	y:(r4)+,y0
	rnd	a
	move	a1,x:(r2)+

	tfr	x0,a	x:(r1)-,b
	mac	x1,y0,a	x:(r0)+,x0	y:(r4)+,y0
	mac	x0,y0,a	x:(r0)-,x0	y:(r4)+,y0
	mac	x0,y0,a	y:(r4)+,y0
	rnd	a
	move	a1,x:(r2)+

	mac	x1,y0,b	x:(r0)+,x0	y:(r4)+,y0
	mac	x0,y0,b	x:(r0)+,x0
	tfr	y1,a	y:(r4)-n4,y0
	mac	x0,y0,b	x:(r0)+,x1	y:(r4)+,y0
	rnd	b
	move	b1,x:(r2)+
transform_loop

	move	y:<frames_processed,a
	move	#>1,x0
	add	x0,a
	move	a1,y:<frames_processed
	rts

transform_animated_vertices
	; camera_vertices currently contains the fully morphed object-space pose.
	; Read each XYZ triple before overwriting it, then transform in place.  The
	; fourth word per vertex remains free for project_vertices' backward
	; expansion into (screen-x, screen-y, z, flags).
	move	y:<vertex_count,x0
	move	#camera_vertices,r0
	move	#camera_vertices,r2

	do	x0,transform_animated_loop
	move	x:(r0)+,x1
	move	x1,y:animation_vertex_x
	move	x:(r0)+,x1
	move	x1,y:animation_vertex_y
	move	x:(r0)+,x1
	move	x1,y:animation_vertex_z
	move	#frame_matrix,r4

	move	x:object_translation,a
	move	y:animation_vertex_x,x1
	move	y:(r4)+,y0
	mac	x1,y0,a	y:animation_vertex_y,x1
	move	y:(r4)+,y0
	mac	x1,y0,a	y:animation_vertex_z,x1
	move	y:(r4)+,y0
	mac	x1,y0,a
	rnd	a
	move	a1,x:(r2)+

	move	x:object_translation+1,a
	move	y:animation_vertex_x,x1
	move	y:(r4)+,y0
	mac	x1,y0,a	y:animation_vertex_y,x1
	move	y:(r4)+,y0
	mac	x1,y0,a	y:animation_vertex_z,x1
	move	y:(r4)+,y0
	mac	x1,y0,a
	rnd	a
	move	a1,x:(r2)+

	move	x:object_translation+2,a
	move	y:animation_vertex_x,x1
	move	y:(r4)+,y0
	mac	x1,y0,a	y:animation_vertex_y,x1
	move	y:(r4)+,y0
	mac	x1,y0,a	y:animation_vertex_z,x1
	move	y:(r4)+,y0
	mac	x1,y0,a
	rnd	a
	move	a1,x:(r2)+
transform_animated_loop

	move	y:<frames_processed,a
	move	#>1,x0
	add	x0,a
	move	a1,y:<frames_processed
	rts

project_vertices
	; Perspective projection: screen = centre + focal * camera.xy / camera.z.
	; Valid host frame state must keep z >= projection_near.  The resulting
	; four-word record is (screen-x, screen-y, camera-z, flags).
	;
	; The output OVERLAYS camera_vertices: both arrays share one X address,
	; and the loop runs BACKWARD so vertex i's four-word record at 4i..4i+3
	; lands strictly above every camera triple 3j..3j+2 (j < i) still to be
	; read -- 4i > 3i-1 holds for every i.  Forward order would clobber
	; vertex ceil(4i/3) while writing vertex i.  The overlay freed the
	; 4,128 X words the resident UV pairs now occupy.
	;
	; N0/N1 fold the backward stride into the last access of each record:
	; three reads end at 3i+3, minus five reaches 3(i-1); four writes end
	; at 4i+4, minus seven reaches 4(i-1).
	move	y:<vertex_count,a
	move	a1,x0
	add	x0,a
	add	x0,a
	move	#camera_vertices-3,x0
	add	x0,a
	move	a1,r0				; camera + 3(n-1)
	move	y:<vertex_count,a
	move	a1,x0
	add	x0,a
	add	x0,a
	add	x0,a
	move	#projected_vertices-4,x0
	add	x0,a
	move	a1,r1				; projected + 4(n-1)
	move	#>-5,n0
	move	#>-7,n1

	move	y:<vertex_count,x0
	do	x0,project_loop
	move	x:(r0)+,x1
	move	x:(r0)+,y0
	move	x:(r0)+n0,x0
	move	x1,y:<project_temp_x
	move	y0,y:<project_temp_y

	; Near-plane test.  There is no triangle clipping here: a vertex closer
	; than projection_near has its divisor clamped so the division stays
	; well-defined, and is marked in the record's flags word.  The triangle
	; builder drops every triangle touching such a vertex.
	move	y:<projection_near,y1
	move	x0,a
	sub	y1,a
	jge	<project_z_ok
	move	y1,x0
	move	#>1,a
	move	a1,y:project_near_flag
	jmp	<project_z_done
project_z_ok
	clr	a
	move	a1,y:project_near_flag
project_z_done
	move	x0,y:<project_temp_z

	; screen-x
	move	y:<projection_focal,y1
	mpy	x1,y1,a	x0,x1
	move	a1,y1
	tst	a
	jpl	*+2
	neg	a
	andi	#$fe,ccr
	rep	#24
	div	x1,a
	jclr	#23,y1,*+3
	neg	a
	move	a0,x0
	move	y:<projection_cx,a
	add	x0,a
	move	a1,x:(r1)+

	; screen-y
	move	y:<project_temp_y,x1
	move	y:<projection_focal_y,y1
	mpy	x1,y1,b	y:<project_temp_z,x1
	move	b1,y1
	tst	b
	jpl	*+2
	neg	b
	andi	#$fe,ccr
	rep	#24
	div	x1,b
	jclr	#23,y1,*+3
	neg	b
	move	b0,x0
	move	y:<projection_cy,a
	add	x0,a
	move	a1,x:(r1)+

	move	y:<project_temp_z,x0
	move	x0,x:(r1)+
	move	y:project_near_flag,a
	move	a1,x:(r1)+n1
project_loop
	rts

make_triangle_zkey
	; Indexed lookup of the third word in each projected vertex record.
	; The sum is deliberately left un-divided: the host can sort using the
	; same monotonic key and avoids another DSP division.
	move	y:triangle_i0,x0
	jsr	<lookup_projected_z
	move	x0,y:triangle_z0
	move	y:triangle_i1,x0
	jsr	<lookup_projected_z
	move	x0,y:triangle_z1
	move	y:triangle_i2,x0
	jsr	<lookup_projected_z
	move	x0,y:triangle_z2

	move	y:triangle_z0,a
	move	y:triangle_z1,x0
	add	x0,a	y:triangle_z2,x0
	add	x0,a
	move	a1,y:triangle_zkey

	move	y:<triangles_processed,a
	move	#>1,x0
	add	x0,a
	move	a1,y:<triangles_processed
	rts

make_triangle_shade
	; Per-face Lambert term for the current triangle, quantized into
	; y:triangle_shade as 0..SHADE_MAX.
	;
	; The object-space face normal is rotated into camera space with the
	; frame matrix - a direction, so the translation is deliberately left
	; out - and dotted with the camera-space light direction.  Both are 1.23
	; unit vectors, so the fractional MPY/MAC pipeline yields the cosine
	; directly and only its top SHADE_BITS are kept.
	;
	; Rotating the light into object space instead would save six of the
	; nine MACs, but only for an orthonormal matrix; transforming the normal
	; is the same expression transform_vertices already uses and stays
	; correct if the frame matrix ever carries more than a rotation.
	;
	; Clobbers a, b, x0, x1, y0, y1, r0, r4, r5 and r6.  r1 and r2 belong
	; to the caller's chunk loop and are not touched.
	;
	; Gouraud corner pass: the loop below runs the rotation and the two
	; clamped light sums once per CORNER normal (bank-split load, see
	; NORMAL_Y_COUNT), quantizes each corner's own level into
	; corner_levels, and accumulates the channel sums across the corners.
	; The mean of the three (one 1/3 multiply before the same quantizer)
	; becomes the record's face level, and the tint classifies the SUMMED
	; channels -- the ratio test is scale-invariant, so no division by
	; three is needed there, only the ambient constant is pre-tripled.
	move	y:<normals_loaded,a
	tst	a
	jeq	<shade_unlit_model

	; Depth-cue attenuation for this triangle: diff = clamp(FAR-zkey, 0,
	; RANGE), then left-shifted from the RANGE=2^17-ish scale into a 1.23
	; fraction -- diff==0 (at or beyond FAR) means fully into the far
	; colour, diff==RANGE (at or inside NEAR) means unattenuated.
	move	#>ZKEY_FOG_NEAR+ZKEY_FOG_RANGE,a
	move	y:triangle_zkey,x0
	sub	x0,a
	tst	a
	jge	<shade_depth_diff_nonneg
	clr	a
shade_depth_diff_nonneg
	move	#>ZKEY_FOG_RANGE,x0
	cmp	x0,a
	jle	<shade_depth_diff_clamped
	move	x0,a
shade_depth_diff_clamped
	rep	#6
	asl	a
	move	a1,y:<shade_depth_scale

	clr	a
	move	a1,y:<shade_acc_r
	move	a1,y:<shade_acc_g
	move	#triangle_n0,r5
	move	#corner_levels,r6

	do	#3,shade_corner_loop
	; Bank-split load of this corner's normal: index below NORMAL_Y_COUNT
	; reads the Y block behind the triangle indices, at or above it the X
	; block that displaced the UV pairs.
	move	y:(r5)+,a
	move	#>NORMAL_Y_COUNT,x0
	cmp	x0,a
	jge	<shade_corner_x_bank
	move	a1,x0
	add	x0,a
	add	x0,a
	move	#corner_normals_y,x0
	add	x0,a
	move	a1,r0
	nop
	move	y:(r0)+,x1
	move	x1,y:shade_nx
	move	y:(r0)+,x1
	move	x1,y:shade_ny
	move	y:(r0),x1
	move	x1,y:shade_nz
	jmp	<shade_corner_loaded
shade_corner_x_bank
	sub	x0,a
	move	a1,x0
	add	x0,a
	add	x0,a
	move	#corner_normals_x,x0
	add	x0,a
	move	a1,r0
	nop
	move	x:(r0)+,x1
	move	x1,y:shade_nx
	move	x:(r0)+,x1
	move	x1,y:shade_ny
	move	x:(r0),x1
	move	x1,y:shade_nz
shade_corner_loaded
	move	#frame_matrix,r4

	; Camera-space normal, one matrix row at a time.  The normal lives in Y
	; memory next to the matrix, so the operands are loaded separately
	; instead of through the X/Y parallel moves transform_vertices uses.
	move	y:shade_nx,x0
	move	y:(r4)+,y0
	mpy	x0,y0,a	y:shade_ny,x0
	move	y:(r4)+,y0
	mac	x0,y0,a	y:shade_nz,x0
	move	y:(r4)+,y0
	mac	x0,y0,a
	rnd	a
	move	a1,y:shade_cx

	move	y:shade_nx,x0
	move	y:(r4)+,y0
	mpy	x0,y0,a	y:shade_ny,x0
	move	y:(r4)+,y0
	mac	x0,y0,a	y:shade_nz,x0
	move	y:(r4)+,y0
	mac	x0,y0,a
	rnd	a
	move	a1,y:shade_cy

	move	y:shade_nx,x0
	move	y:(r4)+,y0
	mpy	x0,y0,a	y:shade_ny,x0
	move	y:(r4)+,y0
	mac	x0,y0,a	y:shade_nz,x0
	move	y:(r4)+,y0
	mac	x0,y0,a
	rnd	a
	move	a1,y:shade_cz

	; Lambert sum over the three source lights.  Each contributes its own
	; clamped cosine: a face turned away from one light simply gets nothing
	; from it instead of darkening the others, which is what the PS1's
	; per-light clamp does.  The host pre-scaled the vectors so the total
	; cannot exceed 1.0 for any normal; the clamp below is the guard for
	; rounding, not for the model.
	; Red channel, then green: the same clamped-dot sum over the two scaled
	; vector sets.  R4 walks straight from the last red vector into the first
	; green one, which is why they are stored as one block.
	clr	b
	move	#light_direction,r4
	do	#LIGHT_COUNT,shade_red_loop
	move	y:shade_cx,x0
	move	y:(r4)+,y0
	mpy	x0,y0,a	y:shade_cy,x0
	move	y:(r4)+,y0
	mac	x0,y0,a	y:shade_cz,x0
	move	y:(r4)+,y0
	mac	x0,y0,a
	rnd	a
	tst	a
	jle	<shade_red_none
	add	a,b
shade_red_none
	nop
shade_red_loop
	jsr	<shade_clamp_sum
	move	a1,x0
	move	y:<shade_depth_scale,y0
	mpy	x0,y0,a
	rnd	a
	move	a1,y:<shade_sum_r

	clr	b
	do	#LIGHT_COUNT,shade_green_loop
	move	y:shade_cx,x0
	move	y:(r4)+,y0
	mpy	x0,y0,a	y:shade_cy,x0
	move	y:(r4)+,y0
	mac	x0,y0,a	y:shade_cz,x0
	move	y:(r4)+,y0
	mac	x0,y0,a
	rnd	a
	tst	a
	jle	<shade_green_none
	add	a,b
shade_green_none
	nop
shade_green_loop
	jsr	<shade_clamp_sum
	move	a1,x0
	move	y:<shade_depth_scale,y0
	mpy	x0,y0,a
	rnd	a
	move	a1,y:<shade_sum_g

	; This corner's own level from its two sums, then accumulate ONE THIRD
	; of each sum: a corner sum reaches 1.09 (see shade_clamp_sum), so the
	; raw three-corner total would exceed 1.0 and the intermediate a1
	; store would wrap exactly like the saturation bug section 4.4 of
	; OPTIMIZATION.md documents -- the brightest faces would land in the
	; darkest banks.  Thirds keep every intermediate below 1.0 except the
	; final one, which the saturation below catches, and they make the
	; accumulator the corner MEAN outright.
	jsr	<shade_quantize_level
	move	a1,y:(r6)+
	move	y:<shade_sum_r,x0
	move	#>$2aaaab,y0			; 1/3
	mpy	x0,y0,a
	rnd	a	y:<shade_acc_r,x0
	add	x0,a
	move	#>$7fffff,x0
	cmp	x0,a
	jle	<shade_acc_r_ok
	move	x0,a
shade_acc_r_ok
	move	a1,y:<shade_acc_r
	move	y:<shade_sum_g,x0
	move	#>$2aaaab,y0
	mpy	x0,y0,a
	rnd	a	y:<shade_acc_g,x0
	add	x0,a
	move	#>$7fffff,x0
	cmp	x0,a
	jle	<shade_acc_g_ok
	move	x0,a
shade_acc_g_ok
	move	a1,y:<shade_acc_g
	nop
shade_corner_loop

	; Face level for the record word: the accumulator already IS the mean
	; of the three corner sums, so it feeds the same quantizer directly --
	; the flat-consuming host sees the corner mean where it used to see
	; the face normal's level.  Brightness still comes from the DIRECT
	; light only, so the ambient floor does not eat the 16-step range.
	move	y:<shade_acc_r,x0
	move	x0,y:<shade_sum_r
	move	y:<shade_acc_g,x0
	move	x0,y:<shade_sum_g
	jsr	<shade_quantize_level
	move	a1,y:<shade_level

	; Tint class: how red the face's own light is, as three threshold tests
	; on R/G without a division.  R is halved and the thresholds are stored
	; halved too, so both operands stay below 1.0 in 1.23.  Ambient goes in
	; first -- it is what an unlit face is left with, and it is the reddest
	; term in the scene.
	; The tint classifies the corner-MEAN sums, so the plain ambient keeps
	; exactly the face model's weighting against the direct term.
	move	y:<shade_acc_r,a
	move	y:<light_ambient,x0
	add	x0,a
	asr	a
	move	a1,y:<shade_ratio_r
	move	y:<shade_acc_g,a
	move	y:<light_ambient+1,x0
	add	x0,a
	move	a1,y:<shade_ratio_g

	clr	a
	move	a1,y:<triangle_tint
	move	#tint_thresholds,r4
	do	#TINT_COUNT-1,shade_tint_loop
	move	y:<shade_ratio_g,x0
	move	y:(r4)+,y0
	mpy	x0,y0,a
	rnd	a
	move	a1,x1
	move	y:<shade_ratio_r,a
	cmp	x1,a
	jlt	<shade_tint_below
	move	y:<triangle_tint,a
	move	#>1,x0
	add	x0,a
	move	a1,y:<triangle_tint
shade_tint_below
	nop
shade_tint_loop

	move	y:<triangle_tint,a
	rep	#SHADE_BITS
	asl	a
	move	y:<shade_level,x0
	add	x0,a
	move	a1,y:triangle_shade
	rts

shade_clamp_sum
	; B holds one channel's sum of clamped dot products, and it CAN exceed 1.0:
	; the vectors are normalised on luminance, and the key light is redder than
	; its own luminance, so a face pointing straight at it reaches 1.09 in red.
	; Storing B1 alone would drop the extension byte and wrap that to -0.91,
	; putting the brightest faces in the darkest bank -- a shadow exactly where
	; the light is strongest, on a flat patch of the snout.  Saturating here is
	; also what the PS1 does; it clamps every colour channel to 255.
	tfr	b,a
	move	#>$7fffff,x0
	cmp	x0,a
	jle	<shade_clamp_done
	move	x0,a
shade_clamp_done
	rts

shade_quantize_level
	; Luminance of the sums in shade_sum_r/g, clamped and quantized to a
	; SHADE_BITS level in a1.  Shared by the three corner passes and the
	; mean-level computation; clobbers x0, y0 and a.
	move	y:<shade_sum_r,x0
	move	#>$2cccbb,y0			; 0.299
	mpy	x0,y0,a	y:<shade_sum_g,x0
	move	#>$59ba5e,y0			; 0.701
	mac	x0,y0,a
	rnd	a
	tst	a
	jgt	<shade_level_positive
	clr	a
	rts
shade_level_positive
	move	#>$7fffff,x0
	cmp	x0,a
	jle	<shade_level_clamped
	move	x0,a
shade_level_clamped
	rep	#SHADE_SHIFT
	asr	a
	rts

shade_unlit_model
	; No normals uploaded: keep the unshaded full-brightness look instead of
	; lighting the model with whatever happens to be in Y memory.
	move	#>SHADE_MAX,a
	move	a1,y:triangle_shade
	move	a1,y:<corner_levels
	move	a1,y:<corner_levels+1
	move	a1,y:<corner_levels+2
	rts

lookup_projected_xy
	; x0 = vertex index; returns screen x in x1, screen y in y1 and the
	; record's flags word in y0.  Layout is (x, y, z, flags).
	move	x0,a
	add	x0,a
	add	x0,a
	add	x0,a
	move	#projected_vertices,x1
	add	x1,a
	move	a1,r0
	nop
	move	x:(r0)+,x1
	move	x:(r0)+,y1
	move	(r0)+
	move	x:(r0),y0
	rts

make_triangle_area
	; Twice the signed screen-space area, left in A.  Screen coordinates are
	; small integers, so the fractional MPY/MAC pair stays exact and only the
	; zero test matters for culling.
	clr	a
	move	a1,y:tri_near_flags
	move	y:triangle_i0,x0
	jsr	<lookup_projected_xy
	move	x1,y:tri_x0
	move	y1,y:tri_y0
	move	y0,a
	move	y:tri_near_flags,x0
	add	x0,a
	move	a1,y:tri_near_flags
	move	y:triangle_i1,x0
	jsr	<lookup_projected_xy
	move	x1,y:tri_x1
	move	y1,y:tri_y1
	move	y0,a
	move	y:tri_near_flags,x0
	add	x0,a
	move	a1,y:tri_near_flags
	move	y:triangle_i2,x0
	jsr	<lookup_projected_xy
	move	x1,y:tri_x2
	move	y1,y:tri_y2
	move	y0,a
	move	y:tri_near_flags,x0
	add	x0,a
	move	a1,y:tri_near_flags

	; Any vertex behind the near plane drops the whole triangle.  Returning a
	; zero area routes it through the existing degenerate path.
	tst	a
	jeq	<tri_near_ok
	clr	a
	rts
tri_near_ok
	; The fully-outside screen test that used to sit here is subsumed by
	; make_triangle_bbox: a clipped box that comes out empty is exactly the
	; all-beyond-one-edge case.  The box runs after the cheaper area cull,
	; so it only costs work for the ~27% of triangles that survive it.

	move	y:tri_x1,a
	move	y:tri_x0,x0
	sub	x0,a
	move	a1,y:tri_dx01
	move	y:tri_y1,a
	move	y:tri_y0,x0
	sub	x0,a
	move	a1,y:tri_dy01
	move	y:tri_x2,a
	move	y:tri_x0,x0
	sub	x0,a
	move	a1,y:tri_dx02
	move	y:tri_y2,a
	move	y:tri_y0,x0
	sub	x0,a
	move	a1,y:tri_dy02

	move	y:tri_dx01,x0
	move	y:tri_dy02,y0
	mpy	x0,y0,a	y:tri_dy01,x0
	move	y:tri_dx02,y0
	mac	-x0,y0,a
	move	a1,y:<prepass_occl_word_offset
	; MPY/MAC uses the fractional accumulator format, whose non-zero low word
	; would otherwise survive into the caller's integer loop counter.  The
	; result is normalized to a clean scalar -- but to +1/-1/0, not +1/0: the
	; SIGN is the triangle's winding and backface culling needs it.
	tst	a
	jeq	<triangle_area_zero
	jlt	<triangle_area_back
	move	#>1,x0
	move	x0,a
	rts
triangle_area_back
	move	#>-1,x0
	move	x0,a
	rts
triangle_area_zero
	clr	a
	rts

make_triangle_bbox
	; Clipped screen-space bounding box of the projected triangle, from the
	; tri_x/tri_y scalars make_triangle_area already fetched.  Returns A=1
	; with the four clamped scalars y:tri_xmin, y:tri_xmax, y:tri_ymin and
	; y:tri_ymax set (unpacked, one word each -- nothing is bit-packed here,
	; since the host never receives the box; see the comment below), or A=0
	; when the clipped box is empty, i.e. the triangle lies entirely beyond
	; one screen edge.
	;
	; Tcc takes only register operands, so the clamp constants pass through
	; X1.  min(a,x1) after CMP is TGT (replace a if it is the larger);
	; max is TLT.  Clamped values are 0..SCREEN_WIDTH-1, so the packed
	; fields are non-negative and the 12-bit shift cannot carry a sign.
	move	y:tri_x0,a
	move	y:tri_x1,x1
	cmp	x1,a
	tgt	x1,a
	move	y:tri_x2,x1
	cmp	x1,a
	tgt	x1,a
	move	#>0,x1
	cmp	x1,a
	tlt	x1,a
	move	a1,y:tri_xmin

	move	y:tri_x0,a
	move	y:tri_x1,x1
	cmp	x1,a
	tlt	x1,a
	move	y:tri_x2,x1
	cmp	x1,a
	tlt	x1,a
	move	#>SCREEN_WIDTH-1,x1
	cmp	x1,a
	tgt	x1,a
	move	a1,y:tri_xmax

	; A still holds x_max; empty means x_min ended up above it, which can
	; only happen when all three x lie off the same side of the screen.
	move	y:tri_xmin,x1
	cmp	x1,a
	jlt	<make_bbox_reject

	move	y:tri_y0,a
	move	y:tri_y1,x1
	cmp	x1,a
	tgt	x1,a
	move	y:tri_y2,x1
	cmp	x1,a
	tgt	x1,a
	move	#>0,x1
	cmp	x1,a
	tlt	x1,a
	move	a1,y:tri_ymin

	move	y:tri_y0,a
	move	y:tri_y1,x1
	cmp	x1,a
	tlt	x1,a
	move	y:tri_y2,x1
	cmp	x1,a
	tlt	x1,a
	move	#>SCREEN_HEIGHT-1,x1
	cmp	x1,a
	tgt	x1,a
	move	a1,y:tri_ymax

	move	y:tri_ymin,x1
	cmp	x1,a
	jlt	<make_bbox_reject

	; The clamped box is used only as this cull now -- since the span-setup
	; record the host never receives it, so nothing is packed here.
	move	#>1,a
	rts
make_bbox_reject
	clr	a
	rts

make_triangle_span
	; Build the seventeen span-setup fields for the current survivor: the
	; Y-sorted vertex chains, their 12.12 X slopes, and the Q8.8 affine UV
	; gradients and left-chain steps -- everything rasterize_packet derives
	; per packet on the host today.  The host validates every field against
	; its own arithmetic before the rasterizer consumes any of them.
	;
	; Sorted working copy.  The slot ids ride along so the UV fetch reads
	; the right vertex's bytes; the three compare-and-swap steps mirror the
	; host's BLE-stable sort exactly, ties included.
	move	y:tri_x0,x0
	move	x0,y:span_sx0
	move	y:tri_y0,x0
	move	x0,y:span_sy0
	move	y:tri_x1,x0
	move	x0,y:span_sx1
	move	y:tri_y1,x0
	move	x0,y:span_sy1
	move	y:tri_x2,x0
	move	x0,y:span_sx2
	move	y:tri_y2,x0
	move	x0,y:span_sy2
	clr	a
	move	a1,y:span_slot0
	move	#>1,x0
	move	x0,y:span_slot1
	move	#>2,x0
	move	x0,y:span_slot2

	move	y:span_sy0,a
	move	y:span_sy1,x1
	cmp	x1,a
	jle	<span_sort_01_ok
	move	y:span_sx0,x0
	move	y:span_sx1,x1
	move	x1,y:span_sx0
	move	x0,y:span_sx1
	move	y:span_sy0,x0
	move	y:span_sy1,x1
	move	x1,y:span_sy0
	move	x0,y:span_sy1
	move	y:span_slot0,x0
	move	y:span_slot1,x1
	move	x1,y:span_slot0
	move	x0,y:span_slot1
span_sort_01_ok
	move	y:span_sy1,a
	move	y:span_sy2,x1
	cmp	x1,a
	jle	<span_sort_12_ok
	move	y:span_sx1,x0
	move	y:span_sx2,x1
	move	x1,y:span_sx1
	move	x0,y:span_sx2
	move	y:span_sy1,x0
	move	y:span_sy2,x1
	move	x1,y:span_sy1
	move	x0,y:span_sy2
	move	y:span_slot1,x0
	move	y:span_slot2,x1
	move	x1,y:span_slot1
	move	x0,y:span_slot2
span_sort_12_ok
	move	y:span_sy0,a
	move	y:span_sy1,x1
	cmp	x1,a
	jle	<span_sort_done
	move	y:span_sx0,x0
	move	y:span_sx1,x1
	move	x1,y:span_sx0
	move	x0,y:span_sx1
	move	y:span_sy0,x0
	move	y:span_sy1,x1
	move	x1,y:span_sy0
	move	x0,y:span_sy1
	move	y:span_slot0,x0
	move	y:span_slot1,x1
	move	x1,y:span_slot0
	move	x0,y:span_slot1
span_sort_done

	; Half heights, and the opposite-edge dy factors the gradients reuse:
	; k0 = sy1-sy2 = -rows_low, k1 = sy2-sy0 = dy_long, k2 = sy0-sy1.
	move	y:span_sy1,a
	move	y:span_sy0,x0
	sub	x0,a
	move	a1,y:span_rows_up
	neg	a
	move	a1,y:span_k2
	move	y:span_sy2,a
	move	y:span_sy1,x0
	sub	x0,a
	move	a1,y:span_rows_low
	neg	a
	move	a1,y:span_k0
	move	y:span_rows_up,a
	move	y:span_rows_low,x0
	add	x0,a
	move	a1,y:span_k1

	; Signed cross product of the sorted triangle: twice the area, and the
	; middle vertex's side in one value.  MPY leaves products doubled, so
	; one ASR restores the integer cross.
	move	y:span_sx1,a
	move	y:span_sx0,x0
	sub	x0,a
	move	a1,x0
	move	y:span_k1,y0
	mpy	x0,y0,a
	move	y:span_sx2,b
	move	y:span_sx0,x0
	sub	x0,b
	move	b1,x0
	move	y:span_rows_up,y1
	mpy	x0,y1,b
	sub	b,a
	asr	a
	; The integer cross sits in the accumulator's LOW word after the ASR:
	; storing A1 here is the classic fractional-MPY trap the area routine's
	; normalization comment warns about, and it fed the gradient divides a
	; divisor of 0 or -1 -- instant saturation, caught by the validator.
	move	a0,y:span_cross

	clr	b
	tst	a
	jge	<span_mid_stored
	move	#>1,b
span_mid_stored
	move	b1,y:span_mid

	; Long-edge X slope: (dx<<12)/dy_long.  span_div expects the dividend
	; doubled to match the MPY convention, hence the thirteenth shift.
	move	y:span_sx2,a
	move	y:span_sx0,x0
	sub	x0,a
	rep	#11
	asr	a
	move	y:span_k1,x1
	jsr	<span_div
	move	a1,y:span_sl_long

	; Short-chain slopes; an empty half stores zero, matching the host.
	clr	a
	move	y:span_rows_up,b
	tst	b
	jeq	<span_sl_up_store
	move	y:span_sx1,a
	move	y:span_sx0,x0
	sub	x0,a
	rep	#11
	asr	a
	move	b1,x1
	jsr	<span_div
span_sl_up_store
	move	a1,y:span_sl_up
	clr	a
	move	y:span_rows_low,b
	tst	b
	jeq	<span_sl_low_store
	move	y:span_sx2,a
	move	y:span_sx1,x0
	sub	x0,a
	rep	#11
	asr	a
	move	b1,x1
	jsr	<span_div
span_sl_low_store
	move	a1,y:span_sl_low

	; This chunk's UV pair of the triangle, then the bytes per sorted slot.
	; chunk_uvs is chunk-local: the pairs arrived with the BUILD command in
	; chunk order, so the global base plays no part here.
	move	y:triangle_index,a
	move	a1,x0
	add	x0,a
	move	#chunk_uvs,x0
	add	x0,a
	move	a1,r0
	nop
	move	x:(r0)+,x0
	move	x0,y:span_uva
	move	x:(r0),x0
	move	x0,y:span_uvb

	move	y:span_slot0,a
	jsr	<span_uv_fetch
	move	x0,y:span_su0
	move	x1,y:span_sv0
	move	y:span_slot1,a
	jsr	<span_uv_fetch
	move	x0,y:span_su1
	move	x1,y:span_sv1
	move	y:span_slot2,a
	jsr	<span_uv_fetch
	move	x0,y:span_su2
	move	x1,y:span_sv2

	; Corner levels per sorted slot, straight from the shading pass.  The
	; raw 0..15 integers feed the same gradient formulas the UV bytes use,
	; so every derived field lands in level units <<8 -- Q4.8.
	move	#corner_levels,x0
	move	y:span_slot0,a
	add	x0,a
	move	a1,r0
	nop
	move	y:(r0),x1
	move	x1,y:span_sl0
	move	y:span_slot1,a
	add	x0,a
	move	a1,r0
	nop
	move	y:(r0),x1
	move	x1,y:span_sl1
	move	y:span_slot2,a
	add	x0,a
	move	a1,r0
	nop
	move	y:(r0),x1
	move	x1,y:span_sl2

	; Affine span gradients: (su0*k0 + su1*k1 + su2*k2) << 8, over the
	; signed cross.  The MAC chain leaves the sum doubled; seven more
	; shifts complete the <<8 in span_div's doubled convention.
	move	y:span_su0,x0
	move	y:span_k0,y0
	mpy	x0,y0,a	y:span_su1,x0
	move	y:span_k1,y0
	mac	x0,y0,a	y:span_su2,x0
	move	y:span_k2,y0
	mac	x0,y0,a
	rep	#8
	asl	a
	move	y:span_cross,x1
	jsr	<span_div
	move	a1,y:span_dudx

	move	y:span_sv0,x0
	move	y:span_k0,y0
	mpy	x0,y0,a	y:span_sv1,x0
	move	y:span_k1,y0
	mac	x0,y0,a	y:span_sv2,x0
	move	y:span_k2,y0
	mac	x0,y0,a
	rep	#8
	asl	a
	move	y:span_cross,x1
	jsr	<span_div
	move	a1,y:span_dvdx

	; Span level gradient: the same barycentric expression over the three
	; sorted corner levels, so the result is level units in Q4.8.
	move	y:span_sl0,x0
	move	y:span_k0,y0
	mpy	x0,y0,a	y:span_sl1,x0
	move	y:span_k1,y0
	mac	x0,y0,a	y:span_sl2,x0
	move	y:span_k2,y0
	mac	x0,y0,a
	rep	#8
	asl	a
	move	y:span_cross,x1
	jsr	<span_div
	move	a1,y:span_dldx

	; Left-chain UV steps, Q8.8.  Middle vertex on the right: the left
	; chain is the long edge and both half slots carry the same step.
	; Middle vertex on the left: one step pair per short segment, zero for
	; an empty half -- the exact uniform semantics the host consumes.
	move	y:span_mid,a
	tst	a
	jne	<span_chain_left

	move	y:span_su2,a
	move	y:span_su0,x0
	sub	x0,a
	rep	#15
	asr	a
	move	y:span_k1,x1
	jsr	<span_div
	move	a1,y:span_dul_up
	move	a1,y:span_dul_low
	move	y:span_sv2,a
	move	y:span_sv0,x0
	sub	x0,a
	rep	#15
	asr	a
	move	y:span_k1,x1
	jsr	<span_div
	move	a1,y:span_dvl_up
	move	a1,y:span_dvl_low
	move	y:span_sl2,a
	move	y:span_sl0,x0
	sub	x0,a
	rep	#15
	asr	a
	move	y:span_k1,x1
	jsr	<span_div
	move	a1,y:span_dll_up
	move	a1,y:span_dll_low
	rts

span_chain_left
	move	y:span_rows_up,b
	tst	b
	jne	<span_chain_left_up
	clr	a
	move	a1,y:span_dul_up
	move	a1,y:span_dvl_up
	move	a1,y:span_dll_up
	jmp	<span_chain_left_low
span_chain_left_up
	move	y:span_su1,a
	move	y:span_su0,x0
	sub	x0,a
	rep	#15
	asr	a
	move	b1,x1
	jsr	<span_div
	move	a1,y:span_dul_up
	move	y:span_rows_up,b
	move	y:span_sv1,a
	move	y:span_sv0,x0
	sub	x0,a
	rep	#15
	asr	a
	move	b1,x1
	jsr	<span_div
	move	a1,y:span_dvl_up
	move	y:span_rows_up,b
	move	y:span_sl1,a
	move	y:span_sl0,x0
	sub	x0,a
	rep	#15
	asr	a
	move	b1,x1
	jsr	<span_div
	move	a1,y:span_dll_up
span_chain_left_low
	move	y:span_rows_low,b
	tst	b
	jne	<span_chain_left_low_go
	clr	a
	move	a1,y:span_dul_low
	move	a1,y:span_dvl_low
	move	a1,y:span_dll_low
	rts
span_chain_left_low_go
	move	y:span_su2,a
	move	y:span_su1,x0
	sub	x0,a
	rep	#15
	asr	a
	move	b1,x1
	jsr	<span_div
	move	a1,y:span_dul_low
	move	y:span_rows_low,b
	move	y:span_sv2,a
	move	y:span_sv1,x0
	sub	x0,a
	rep	#15
	asr	a
	move	b1,x1
	jsr	<span_div
	move	a1,y:span_dvl_low
	move	y:span_rows_low,b
	move	y:span_sl2,a
	move	y:span_sl1,x0
	sub	x0,a
	rep	#15
	asr	a
	move	b1,x1
	jsr	<span_div
	move	a1,y:span_dll_low
	rts

span_div
	; Signed division with the quotient truncated toward zero, using the
	; same 48/24 accumulator idiom as the projection.  The 24 DIV steps
	; compute A48/(2*X1), so the caller must position the dividend as N<<1
	; across the full 48-bit accumulator: a value LOADED into A sits at
	; <<24 and shifts RIGHT into place (24-1-k for a <<k numerator), while
	; MAC-built sums already carry a <<1 and shift LEFT by the remaining k.
	; Getting this wrong saturates the quotient at $7FFFxx -- exactly what
	; the validation frames caught on first contact.
	; Returns the quotient in A1.  Clobbers B, X1 and Y0.
	clr	b
	move	b1,y:span_flip
	tst	a
	jpl	<span_div_n_ok
	neg	a
	move	#>1,b
	move	b1,y:span_flip
span_div_n_ok
	tfr	x1,b
	tst	b
	jpl	<span_div_d_ok
	neg	b
	move	b1,x1
	move	y:span_flip,b
	move	#>1,y0
	eor	y0,b
	move	b1,y:span_flip
span_div_d_ok
	andi	#$fe,ccr
	rep	#24
	div	x1,a
	move	a0,y0
	move	y0,a
	move	y:span_flip,b
	tst	b
	jeq	<span_div_done
	neg	a
span_div_done
	rts

span_uv_fetch
	; A = sorted slot id (0..2); returns that vertex's u in X0 and v in X1
	; from the packed pair (u0|v0<<8|u1<<16, v1|u2<<8|v2<<16).  LSR shifts
	; A1 only, which is exactly where the packed word sits.
	move	#>$ff,y1
	move	#>1,x1
	cmp	x1,a
	jeq	<span_uv_slot1
	jgt	<span_uv_slot2
	move	y:span_uva,a
	and	y1,a
	move	a1,x0
	move	y:span_uva,a
	rep	#8
	lsr	a
	and	y1,a
	move	a1,x1
	rts
span_uv_slot1
	move	y:span_uva,a
	rep	#16
	lsr	a
	and	y1,a
	move	a1,x0
	move	y:span_uvb,a
	and	y1,a
	move	a1,x1
	rts
span_uv_slot2
	move	y:span_uvb,a
	rep	#8
	lsr	a
	and	y1,a
	move	a1,x0
	move	y:span_uvb,a
	rep	#16
	lsr	a
	and	y1,a
	move	a1,x1
	rts

lookup_projected_z
	; x0 = vertex index, returns z in x0.  The record base must be folded
	; into the address: writing the scaled index straight into R0 would
	; address X:$0002 upwards instead of the projected-vertex array.
	move	x0,a
	add	x0,a
	add	x0,a
	add	x0,a
	move	#projected_vertices+2,x1
	add	x1,a
	move	a1,r0
	nop
	move	x:(r0),x0
	rts

; -----------------------------------------------------------------------------
; Occlusion prepass
;
; One sweep over the whole resident index list that answers, before the first
; BUILD chunk of the frame arrives, two questions the chunk pass answers only
; piecemeal: WHICH triangles survive, and in WHAT near-to-far order the host
; will draw them.  The order is the part the DSP could not previously know --
; it is created host-side in gpu_submit_ot, long after the DSP is done -- and
; without it no occlusion decision taken here can be sound.
;
; Survival is decided by calling make_triangle_area, make_triangle_bbox and
; make_triangle_zkey, the very routines CMD_BUILD_TRIANGLES calls, in the very
; same order.  Nothing is reimplemented, so the two passes cannot drift apart:
; the survivor set of the prepass is the survivor set of the chunk pass by
; construction, and the host's cross-check has something to fail on rather
; than a tautology.
;
; The order is an LSD radix sort over the eleven bucket bits in two six-bit
; passes, ping-ponging between prepass_order and prepass_scratch.  A radix
; sort is exact and stable and does not care how the keys are distributed, so
; the bucket relation survives intact -- no two buckets are merged and none is
; split.  A counting sort over all 2,048 buckets would need 4,208 words and
; fits in no safe allocation; a coarser key would silently weaken the very
; relation this pass exists to reproduce.
;
; Cost is dominated by geometry, not by ordering: at ~600 survivors the sort
; is roughly 25k instructions against ~300k for the classification.  That is
; why the exact sort is worth its code.
;
; Within one bucket the DSP order ascends in triangle index while the host
; draws in descending submission order (the OT node list is LIFO).  That
; difference is legal and must NOT be exploited: a later stage may only let a
; triangle occlude another once the whole bucket has been tested, never rank
; by rank.  Bucket boundaries are visible at run time as an inequality between
; the bucket fields of two neighbouring entries, so no extra table is needed.
; -----------------------------------------------------------------------------

command_prepass
	jsr	<receive_word

	; Mode word.  Bit 1 separates the two acting modes (2 = run now,
	; 3 = dump) from the two arming modes (0 = disarm, 1 = arm), and bit 0
	; separates the pair, so the decode needs no compare constants.
	jclr	#1,x0,prepass_arm
	nop
	jclr	#0,x0,prepass_run_now
	nop
	; Mode 3 is retained as a second run-now selector for old measurement
	; binaries.  It has the same fixed two-word reply as mode 2.
	jmp	<prepass_run_now

prepass_arm
	; Modes 0 and 1 share one path because the flag IS the mode word.
	; Arming is sticky: it holds for every following FINISH until mode 0
	; clears it.
	move	x0,y:prepass_armed
	jmp	<prepass_ack_exit

prepass_run_now
	jsr	<prepass_run
prepass_ack_exit
	move	#ACK_PREPASS,x0
	jsr	<send_word
	move	y:prepass_surv,x0
	jsr	<send_word
	jmp	<main_loop

prepass_run
	; make_triangle_zkey bumps y:triangles_processed, which CMD_GET_STATUS
	; reports.  Save it here and restore it on every exit path, otherwise
	; an armed run silently inflates the host's status figure by 2,724 per
	; frame.
	move	y:<triangles_processed,a
	move	a1,y:prepass_tp_save

	clr	a
	move	a1,y:prepass_surv
	move	a1,y:prepass_flow

	; The radix counters and the stage-2 kill bitmap start every run at
	; zero.  REP with a one-word move clears both banks in four words of
	; program memory, which matters far more here than the cycles do.
	move	#prepass_cnt_lo,r0
	nop
	rep	#PREPASS_CNT_COUNT
	move	a1,y:(r0)+
	move	#prepass_kill,r0
	nop
	rep	#PREPASS_KILL_WORDS
	move	a1,x:(r0)+

	; -------------------------------------------------------------------
	; Phase 0 -- classification.  One pass over the resident index list,
	; writing one entry per survivor and histogramming both radix digits
	; on the way, so the sort needs no separate counting pass.
	; -------------------------------------------------------------------
	; R3 carries the triangle index instead of a Y cell.  Every absolute
	; Y access on this DSP is a two-word instruction, and the index is
	; touched on all three exits of the loop body, so an address register
	; that survives the three JSRs is worth six program words here.
	; -------------------------------------------------------------------
	move	#0,r3
	move	#triangle_indices,r2
	move	#2,n2
	move	#prepass_order,r1
	move	y:<triangle_list_count,x0
	tfr	x0,a
	tst	a
	jeq	<prepass_restore
	do	x0,prepass_class_end

	; Only the three VERTEX indices matter here; the corner-normal fields
	; feed shading, which the prepass never reaches.  Word C is therefore
	; never read at all -- the +N2 post-increment steps over it while word
	; B is being fetched.
	move	y:(r2)+,x1
	move	y:(r2)+n2,y1
	move	#>TRI_VERTEX_MASK,x0
	tfr	x1,a
	and	x0,a
	move	a1,y:triangle_i0
	tfr	x1,a
	rep	#TRI_INDEX_BITS
	lsr	a
	; Bit 11 here is the occluder qualification, not part of v1.  Word A is
	; still in X1 for the stage that reads that flag.
	and	x0,a
	move	a1,y:triangle_i1
	tfr	y1,a
	and	x0,a
	move	a1,y:triangle_i2

	; The chunk pass's own survivor test, called rather than copied.  Area
	; sign first (it also absorbs the near-plane rejects), then the clipped
	; box, then the key.  R1 and R2 survive all three, which is what lets
	; the loop keep its pointers in them.
	jsr	<make_triangle_area
	tst	a
	jge	<prepass_class_next
	jsr	<make_triangle_bbox
	tst	a
	jeq	<prepass_class_next
	jsr	<make_triangle_zkey

	; The host's bucket rule, reproduced bit for bit: shift right by
	; OT_KEY_SHIFT, saturate at OT_LENGTH-1.  The key is treated as an
	; UNSIGNED 24-bit value, because that is what the host does -- and it
	; does so by accident rather than by choice.  Dsp_BlkUnpacked zero-fills
	; a 24-bit word into a longword, and the unpacker hands w1 through
	; without the "btst #23 / ori.l #$ff000000" sign extension it applies to
	; every other signed DSP field.  The host's own "tst.l / bmi bucket 0"
	; branch is therefore unreachable code: a key with bit 23 set arrives
	; positive and saturates into bucket 2047, the FARTHEST bucket.  A DSP
	; that mapped that case to bucket 0 -- the nearest -- would order such a
	; triangle exactly backwards, make it an occluder for the whole scene,
	; and cull geometry the host draws visibly on top of it.
	;
	; "clr a" before loading A1 is what makes it unsigned: a plain
	; "move y:...,a" sign-extends bit 23 into the A2 extension, and the
	; CMP below compares the full accumulator, so the saturation would then
	; never fire.  Writing A1 alone leaves the cleared extension in place.
	;
	; REP/LSR, never a fractional MPY by 2^-8: the host shifts with LSR.L
	; and a multiply rounds differently in the low bits.  That would break
	; the bucket equality in a handful of frames only -- the worst kind of
	; failure to find later.
	clr	a
	move	y:triangle_zkey,a1
	rep	#OT_KEY_SHIFT
	lsr	a
	move	#>OT_LENGTH-1,x1
	cmp	x1,a
	tgt	x1,a

	; Capacity.  The entry after the last one would land in the kill
	; bitmap, so recording stops here and the whole run is invalidated
	; below.  Checked before the store, never after.
	move	y:prepass_surv,b
	move	#>PREPASS_MAX,x0
	cmp	x0,b
	jge	<prepass_class_full

	; Entry E = (triangle index << TRI_INDEX_BITS) | bucket.  The index is
	; below 2,724 and the bucket below 2,048.  The index can set bit 23 in E,
	; but the logical shifts and six-bit digit masks below operate on the raw
	; packed word and remain exact.
	move	a1,x0
	; R3 is 16 bits and the index stays below 2,724, so whichever way the
	; register-to-register move extends it the low 16 bits are the value
	; and A1 holds it.  A2 does not matter either: the shift below feeds
	; A1 from A1 and A0, and only A1 is stored.
	move	r3,a
	rep	#TRI_INDEX_BITS
	asl	a
	add	x0,a
	move	a1,x:(r1)+

	; Both radix digits in one go.  The counter banks are on-chip Y: they
	; are touched twice per survivor plus 96 times per pass, and every
	; other word this routine handles already pays external-SRAM wait
	; states.
	move	#>PREPASS_DIGIT_MASK,x0
	move	#>1,y0
	tfr	a,b
	and	x0,b
	move	#>prepass_cnt_lo,y1
	add	y1,b
	move	b1,r0
	; The second bank's base fills the slot the address pipeline needs
	; between writing R0 and addressing through it, so no NOP is spent.
	move	#>prepass_cnt_hi,y1
	move	y:(r0),b
	add	y0,b
	move	b1,y:(r0)

	tfr	a,b
	rep	#PREPASS_RADIX_BITS
	lsr	b
	and	x0,b
	add	y1,b
	move	b1,r0
	nop
	move	y:(r0),b
	add	y0,b
	move	b1,y:(r0)

	move	y:prepass_surv,b
	add	y0,b
	move	b1,y:prepass_surv
	jmp	<prepass_class_next

prepass_class_full
	; Any non-zero value marks the run as overrun, and X0 still holds
	; PREPASS_MAX -- cheaper than loading a literal 1.
	move	#>$ffffff,a
	move	a1,y:prepass_surv
	move	x0,y:prepass_flow

prepass_class_next
	move	(r3)+
	; The loop's last word is deliberately a NOP nobody jumps to.  Both
	; cull paths and the survivor path branch to prepass_class_next, and
	; landing a jump directly on a hardware loop's LA is the one place
	; where the loop-back and the jump would fight over the program
	; counter.  One word buys that whole question away.
	nop
prepass_class_end

	; An overrun leaves the order list truncated, so nothing may be sorted
	; from it and nothing may be culled with it.  The run reports $ffffff,
	; the kill bitmap stays cleared, and the frame comes out bit-identical
	; to a frame without the prepass.
	move	y:prepass_flow,a
	tst	a
	jne	<prepass_restore
	move	y:prepass_surv,a
	tst	a
	jeq	<prepass_restore

	; -------------------------------------------------------------------
	; Phase 1 -- exclusive prefix sums over the two counter banks, each
	; biased by the base address its pass writes to.  A counter cell then
	; holds the ADDRESS its next entry goes to rather than an index, which
	; removes both the base add and the separate running index from the
	; two scatter bodies below.
	;
	; The digit mask and the constant 1 the scatters need are loaded here:
	; the prefix loops touch neither Y0 nor X1, so one load serves both
	; passes.
	; -------------------------------------------------------------------
	move	#>PREPASS_DIGIT_MASK,y0
	move	#>1,x1
	move	#>prepass_scratch,a
	move	#prepass_cnt_lo,r0
	nop
	do	#PREPASS_CNT_LO_COUNT,prepass_prefix_lo_end
	move	y:(r0),x0
	move	a1,y:(r0)+
	add	x0,a
prepass_prefix_lo_end
	move	#>prepass_order,a
	do	#PREPASS_CNT_HI_COUNT,prepass_prefix_hi_end
	move	y:(r0),x0
	move	a1,y:(r0)+
	add	x0,a
prepass_prefix_hi_end

	; -------------------------------------------------------------------
	; Phase 2 -- scatter on the low digit, prepass_order -> prepass_scratch
	; -------------------------------------------------------------------
	move	#>prepass_cnt_lo,y1
	move	#prepass_order,r2
	move	y:prepass_surv,x0
	nop
	do	x0,prepass_scatter_lo_end
	move	x:(r2)+,a
	tfr	a,b
	and	y0,b
	add	y1,b
	move	b1,r0
	nop
	move	y:(r0),b
	move	b1,r4
	add	x1,b
	move	b1,y:(r0)
	move	a1,x:(r4)
prepass_scatter_lo_end

	; -------------------------------------------------------------------
	; Phase 3 -- scatter on the high digit, prepass_scratch -> prepass_order
	;
	; Two stable passes over disjoint halves of the key leave the list
	; exactly ascending in the bucket, which is near to far: bucket 0 is
	; the closest.  The host walks its Ordering Table from 2047 downwards
	; and therefore draws this list back to front, as painter's algorithm
	; requires.  Equal buckets keep ascending triangle index.
	; -------------------------------------------------------------------
	move	#>prepass_cnt_hi,y1
	move	#prepass_scratch,r2
	move	y:prepass_surv,x0
	nop
	do	x0,prepass_scatter_hi_end
	move	x:(r2)+,a
	tfr	a,b
	rep	#PREPASS_RADIX_BITS
	lsr	b
	and	y0,b
	add	y1,b
	move	b1,r0
	nop
	move	y:(r0),b
	move	b1,r4
	add	x1,b
	move	b1,y:(r0)
	move	a1,x:(r4)
prepass_scatter_hi_end

	; The list is now exact near-to-far order.  Stage 2 tests each survivor
	; against sealed coverage and stage 3 stamps only qualified, still-visible
	; triangles into the pending mask.  BUILD consumes the resulting global
	; kill bitmap; the sorted list itself remains an internal DSP worklist.
	jsr	<prepass_occlusion

prepass_restore
	move	y:prepass_tp_save,a
	move	a1,y:<triangles_processed
	rts

; The sorted list is walked once from bucket 0 (nearest) to bucket 2047
; (farthest).  `seal` contains only complete cells from earlier buckets;
; `pending` contains cells stamped by the current bucket.  A pending mask is
; merged only when the next entry changes bucket, which is the ordering rule
; that makes the result independent of the host's LIFO order within a bucket.
prepass_occlusion
	move	y:prepass_surv,a
	tst	a
	jeq	<prepass_occlusion_done
	move	a1,x0
	clr	a
	move	#prepass_order,r1
	move	#prepass_scratch,r0
	rep	#(OCCL_MASK_WORDS*2)
	move	a1,x:(r0)+
	move	#>OT_LENGTH,a
	move	a1,y:<prepass_occl_flow
	do	x0,prepass_occlusion_loop_end

prepass_occlusion_loop
	move	x:(r1)+,a
	tfr	a,b
	move	#>PREPASS_ENTRY_BUCKET_MASK,x0
	and	x0,b
	move	b1,y:<prepass_occl_base
	rep	#TRI_INDEX_BITS
	lsr	a
	move	a1,y:<prepass_occl_index

	; The first entry has a negative previous-bucket sentinel.  On later
	; changes, seal the completed bucket before testing the new one.  The
	; merge also clears pending, so the two masks stay paired at the
	; boundary without a second full-mask pass here.
	move	y:<prepass_occl_flow,x0
	cmp	x0,b
	jeq	<prepass_occlusion_same_bucket
	move	b1,y:<prepass_occl_flow
	jsr	<prepass_merge_masks
prepass_occlusion_same_bucket
	move	y:<prepass_occl_index,x0
	jsr	<prepass_load_triangle
	jsr	<make_triangle_area
	jsr	<make_triangle_bbox
	; The third directed edge is derived once; the four-corner stamp reuses
	; these two deltas for every cell corner.
	move	y:tri_dx02,a
	move	y:tri_dx01,x0
	sub	x0,a	y:tri_dy01,x0
	move	a1,y:<prepass_occl_dx12
	move	y:tri_dy02,a
	sub	x0,a
	move	a1,y:<prepass_occl_dy12
	; triangle_count is the cell-walk mode: zero queries seal, one stamps
	; pending.  Keep the qualification bit in span_flip across the query.
	move	y:<prepass_occl_mode,a
	move	a1,y:<prepass_occl_aux
	clr	a
	move	a1,y:<prepass_occl_mode
	move	#prepass_scratch,r0
	jsr	<prepass_mask_walk
	tst	a
	jne	<prepass_occlusion_kill

	; A visible qualified triangle is the only thing allowed to add coverage
	; to this bucket's pending mask.  A killed triangle cannot occlude a later
	; triangle because it contributed no visible pixels.
	move	y:<prepass_occl_aux,a
	tst	a
	jeq	<prepass_occlusion_next
	move	#>1,a
	move	a1,y:<prepass_occl_mode
	move	#prepass_scratch+OCCL_MASK_WORDS,r0
	jsr	<prepass_mask_walk
	jmp	<prepass_occlusion_next

prepass_occlusion_kill
	jsr	<prepass_set_kill

prepass_occlusion_next
	nop
prepass_occlusion_loop_end
prepass_occlusion_done
	rts

; Reload one resident triangle.  X0 is the triangle number on entry.  The
; flag in word A becomes the prepass mode (0/1); only vertex fields are needed
; by this stage, so word C is skipped entirely.
prepass_load_triangle
	move	x0,a
	add	x0,a
	add	x0,a
	move	#triangle_indices,x0
	add	x0,a	a1,r2
	nop
	move	y:(r2)+,x1
	move	y:(r2)+,y1
	move	#>TRI_VERTEX_MASK,x0
	tfr	x1,a
	and	x0,a
	move	a1,y:triangle_i0
	tfr	x1,a
	rep	#TRI_INDEX_BITS
	lsr	a
	and	x0,a
	move	a1,y:triangle_i1
	tfr	y1,a
	and	x0,a
	move	a1,y:triangle_i2
	clr	a
	jclr	#TRI_OCCLUDER_BIT,x1,prepass_load_not_occluder
	nop
	move	#>1,a
	; fall through to the common mode store
prepass_load_not_occluder
prepass_load_done
	move	a1,y:<prepass_occl_mode
	rts

; Convert triangle_count (a global triangle number) to a kill-word pointer
; and one-hot bit.  Repeated subtraction is only paid for a kill/query and
; keeps the common BUILD test small without another resident table.
prepass_kill_address
	move	#>prepass_kill,b
	move	#>24,x0
	move	#>1,x1
prepass_kill_word_loop
	cmp	x0,a
	jlt	<prepass_kill_word_done
	sub	x0,a
	add	x1,b
	jmp	<prepass_kill_word_loop
prepass_kill_word_done
	move	b1,r0
	move	a1,x0
	tst	a
	jeq	<prepass_kill_bit_done
	do	x0,prepass_kill_bit_end
	move	x1,a
	asl	a
	move	a1,x1
	nop
prepass_kill_bit_end
prepass_kill_bit_done
	rts

prepass_set_kill
	; The packed order entry stores (triangle_index << 12) | bucket.
	; prepass_occl_base is the bucket used for bucket-boundary sealing; it
	; must not be added to the global triangle index when addressing the kill
	; bitmap.  Adding it shifted every kill onto a different source triangle.
	move	y:<prepass_occl_index,a
	jsr	<prepass_kill_address
	move	x:(r0),a
	or	x1,a
	move	a1,x:(r0)
	rts

; Common cell operation and walk.  triangle_count=0 queries seal and
; triangle_count=1 tests the four corners and stamps pending.  Outside cells
; are a no-op in either mode, so one cursor loop serves both stages.
prepass_mask_cell
	move	y:<prepass_occl_cell_sy,a
	move	y:tri_ymax,y1
	cmp	y1,a
	jgt	<prepass_mask_cell_outside
	move	#>3,x0
	add	x0,a	y:tri_ymin,y1
	cmp	y1,a
	jlt	<prepass_mask_cell_outside
	move	y:<prepass_occl_cell_sx,a
	move	y:tri_xmax,y1
	cmp	y1,a
	jgt	<prepass_mask_cell_outside
	add	x0,a	y:tri_xmin,y1
	cmp	y1,a
	jlt	<prepass_mask_cell_outside
	move	y:<prepass_occl_mode,a
	tst	a
	jne	<prepass_stamp_cell
	move	x:(r0),a
	and	x1,a
	tst	a
	jeq	<prepass_mask_cell_uncovered
prepass_mask_cell_done
	move	#>1,a
	rts
prepass_mask_cell_uncovered
	clr	a
	move	a1,y:<prepass_occl_found
	rts
prepass_mask_cell_outside
	clr	a
	rts

prepass_stamp_cell
	move	y:<prepass_occl_cell_sx,a
	move	a1,y:<prepass_occl_point_sx
	move	y:<prepass_occl_cell_sy,a
	move	a1,y:<prepass_occl_point_sy
	jsr	<prepass_point_inside
	tst	a
	jeq	<prepass_mask_cell_done
	move	y:<prepass_occl_cell_sx,a
	move	#>3,x0
	add	x0,a
	move	a1,y:<prepass_occl_point_sx
	jsr	<prepass_point_inside
	tst	a
	jeq	<prepass_mask_cell_done
	move	y:<prepass_occl_cell_sy,a
	move	#>3,x0
	add	x0,a
	move	a1,y:<prepass_occl_point_sy
	jsr	<prepass_point_inside
	tst	a
	jeq	<prepass_mask_cell_done
	move	y:<prepass_occl_cell_sx,a
	move	a1,y:<prepass_occl_point_sx
	jsr	<prepass_point_inside
	tst	a
	jeq	<prepass_mask_cell_done
	move	x:(r0),a
	or	x1,a
	move	a1,x:(r0)
	move	#>1,a
	rts

prepass_mask_walk
	clr	a
	move	a1,y:<prepass_occl_cell_sx
	move	a1,y:<prepass_occl_cell_sy
	move	#>1,a
	move	a1,y:<prepass_occl_found
	; Sixty cells are 12 + 24 + 24 bits.  Starting each row at bit 12
	; makes the final 24-cell word wrap naturally into the next row, so no
	; fourth padded word or row-boundary pointer fixup is needed.
	move	#>$1000,x1
	move	#>OCCL_CELL_COLS*OCCL_CELL_ROWS,x0
	do	x0,prepass_mask_loop_end
	jsr	<prepass_mask_cell
	jsr	<prepass_cell_advance
	nop
prepass_mask_loop_end
	move	y:<prepass_occl_found,a
	rts

; Advance the cell cursor and the mask pointer.  A=1 means a row ended; the
; caller uses the row counter to stop after all 56 rows.  The point routine
; deliberately leaves X1 and R0 untouched, so the same cursor serves both
; the query and stamp walks.
prepass_cell_advance
	move	y:<prepass_occl_cell_sx,a
	move	#>4,x0
	add	x0,a
	move	a1,y:<prepass_occl_cell_sx
	move	x1,a
	asl	a
	move	a1,x1
	tst	a
	jne	<prepass_cell_no_word
	move	x:(r0)+,a
	move	#>1,x1
prepass_cell_no_word
	move	y:<prepass_occl_cell_sx,a
	move	#>240,x0
	cmp	x0,a
	jne	<prepass_cell_continue
	clr	a
	move	a1,y:<prepass_occl_cell_sx
	move	y:<prepass_occl_cell_sy,a
	move	#>4,x0
	add	x0,a
	move	a1,y:<prepass_occl_cell_sy
	move	#>$1000,x1
	rts
prepass_cell_continue
	clr	a
	rts

; seal |= pending, one word per mask cell.  The pending mask itself is
; cleared here at the same bucket boundary.
prepass_merge_masks
	move	#prepass_scratch,r0
	move	#prepass_scratch+OCCL_MASK_WORDS,r2
	move	#>OCCL_MASK_WORDS,x0
	do	x0,prepass_merge_done
	move	x:(r0),a
	move	x:(r2)+,x0
	or	x0,a
	move	a1,x:(r0)+
	clr	a
	move	a1,x:(r2)+
prepass_merge_done
	rts

; Point-in-triangle test for the current point (span_sx1, span_sy1).  The
; front-facing area is negative, so all three directed edge signs must be
; non-positive.  MPY/MAC supplies the cross products in the DSP fractional
; domain; only their signs matter and no integer conversion is performed.
prepass_point_inside
	move	y:<prepass_occl_point_sy,a
	move	y:tri_y0,x0
	sub	x0,a	y:tri_dx01,x0
	move	a1,y0
	move	y:tri_dy01,y1
	mpy	x0,y0,a	y:<prepass_occl_point_sx,b
	move	y:tri_x0,x0
	sub	x0,b
	move	b1,y0
	mac	-y1,y0,a
	move	a1,y:<prepass_occl_col_end
	tst	a
	jgt	<prepass_point_outside
	move	y:<prepass_occl_point_sy,a
	move	y:tri_y1,x0
	sub	x0,a	y:<prepass_occl_point_sx,b
	move	a1,y0
	move	y:tri_x1,x0
	sub	x0,b	y:<prepass_occl_dx12,x0
	mpy	x0,y0,a
	move	b1,y0
	move	y:<prepass_occl_dy12,y1
	mac	-y1,y0,a
	tst	a
	jgt	<prepass_point_outside
	move	y:<prepass_occl_col_end,x0
	add	x0,a
	move	y:<prepass_occl_word_offset,x0
	cmp	x0,a
	jlt	<prepass_point_outside
	move	#>1,a
	rts
prepass_point_outside
	clr	a
	rts

; -----------------------------------------------------------------------------
; X memory
; -----------------------------------------------------------------------------

	; Falcon XBIOS keeps the first 64 X words for DSP interrupt vectors.
	org	x:$40

command_word
	ds	1
object_translation
	ds	3

; Static T-Rex data is sent by the M68030 after parsing trex.tmd.
base_vertices
	ds	TREX_VERTICES*3

; Camera-space transform output, OVERLAID by the projection result: the
; backward-running project_vertices rewrites each three-word camera triple
; into the four-word (screen-x, screen-y, z, flags) record in place, so one
; allocation sized for the larger record serves both.  The source mesh in
; base_vertices remains intact for the next frame.
camera_vertices
	ds	TREX_VERTICES*4
projected_vertices	equ	camera_vertices

; The X half of the corner-normal table (entries NORMAL_Y_COUNT and up),
; occupying the allocation the resident UV pairs held before Gouraud.
corner_normals_x
	ds	NORMAL_X_COUNT*3

; One BUILD chunk's UV pairs, received with the command in chunk order and
; read chunk-locally by the span-setup pass.  Two packed words per triangle:
;   word A = u0 | v0<<8 | u1<<16
;   word B = v1 | u2<<8 | v2<<16
chunk_uvs
	ds	MAX_CHUNK*2

; One chunk of survivor records, SPAN_RECORD_WORDS each.  Culled triangles
; occupy nothing.  This is the last X allocation; the layout ends at X:$3C5E,
; inside the host's 15,872-word reservation.
triangle_out
	ds	MAX_CHUNK*SPAN_RECORD_WORDS

; -----------------------------------------------------------------------------
; Occlusion prepass working set
;
; Everything from chunk_uvs to the top of physical X memory, 1,569 words.
; Deliberately NOT taken from the unused tail of triangle_indices (that only
; exists in the LOD build and vanishes under -DTREX_FULL_MESH) and not from
; Y:$0100-$01FF (whose mapping the sources contradict each other about).
;
; prepass_order is PHASE-LOCAL: it overlays chunk_uvs and triangle_out,
; which are dead until the first BUILD chunk of the frame arrives.  The sorted
; list is consumed completely by the occlusion sweep before the first BUILD,
; so it does not need to survive chunk traffic.  prepass_scratch is the
; external-X work area above the old layout end; it holds the intermediate
; radix list and the two coverage masks.  prepass_kill and prepass_status also
; live there and survive the BUILD chunks.
; -----------------------------------------------------------------------------
	org	x:chunk_uvs

prepass_order
	ds	PREPASS_MAX
prepass_scratch
	ds	PREPASS_MAX
prepass_kill
	ds	PREPASS_KILL_WORDS
prepass_status
	ds	PREPASS_STATUS_WORDS

; -----------------------------------------------------------------------------
; Y memory
; -----------------------------------------------------------------------------

	org	y:$0

vertex_count
	ds	1
normal_count
	ds	1
normals_loaded
	dc	0
triangle_list_count
	ds	1
triangles_loaded
	dc	0
frames_processed
	ds	1
triangles_processed
	ds	1

frame_matrix
	ds	9
animation_bias
	ds	3

; The three PS1 light directions in camera space, replaced every frame.  Each
; is the source direction scaled by that light's own intensity and colour
; luminance and normalised so the brightest reachable face reaches 1.0, so the
; shading loop below is a plain sum of clamped dot products.  The default is a
; single light pointing at the camera, so a host that never sends one still
; lights the front of the model.
; Six vectors: the three source directions scaled for the RED channel, then
; the same three scaled for GREEN (which equals BLUE for every light and for
; the ambient in this scene).  Each is unit direction * light length * colour
; channel / 128, normalised so the brightest reachable face reaches 1.0 in
; luminance.  Two clamped-dot sums over those two sets give the face's own
; light colour, which is what the tint classification below needs.
LIGHT_COUNT	= 3
light_direction
	dc	0,0,$800001
	dc	0,0,0
	dc	0,0,0
	dc	0,0,$800001
	dc	0,0,0
	dc	0,0,0

; PS1 ambient term, red and green, added to every face before the ratio test.
light_ambient
	dc	$2aa800,$199800

; R/G class boundaries, stored halved to keep them inside 1.23.  They are the
; quartiles of the ratio over every face of every choreography frame under the
; source light model: 1.378, 1.529, 1.649.  A face below the first is lit
; mostly by the two white lights, one above the last has only the warm ambient
; or the pink key light on it.
tint_thresholds
	dc	$582f83,$61de69,$698c7d

shade_sum_r
	ds	1
shade_sum_g
	ds	1
; This triangle's depth-cue attenuation, a 1.23 fraction in [0, ~1.0):
; 0 = fully into the far colour (black), ~1.0 = unattenuated.  Computed once
; per triangle from triangle_zkey and applied to both channel sums.
shade_depth_scale
	ds	1
; Corner-pass state: the channel sums accumulated across the triangle's
; three corners, and the three quantized per-corner levels the Gouraud
; record revision will ship.
shade_acc_r
	ds	1
shade_acc_g
	ds	1
corner_levels
	ds	3
shade_level
	ds	1
shade_ratio_r
	ds	1
shade_ratio_g
	ds	1
triangle_tint
	ds	1

projection_focal
	dc	160
projection_focal_y
	dc	160
projection_cx
	dc	150
projection_cy
	dc	112
projection_near
	dc	1

project_temp_x
	ds	1
project_temp_y
	ds	1
project_temp_z
	ds	1

animation_target_vertex_count
	ds	1
animation_vertices_remaining
	ds	1
animation_weight
	ds	1
animation_delta_x
	ds	1
animation_delta_y
	ds	1
animation_delta_z
	ds	1
animation_vertex_x
	ds	1
animation_vertex_y
	ds	1
animation_vertex_z
	ds	1

triangle_count
	ds	1
triangle_i0
	ds	1
triangle_i1
	ds	1
triangle_i2
	ds	1
triangle_n0
	ds	1
triangle_n1
	ds	1
triangle_n2
	ds	1
triangle_z0
	ds	1
triangle_z1
	ds	1
triangle_z2
	ds	1
triangle_zkey
	ds	1
triangle_remaining
	ds	1
project_near_flag
	ds	1
tri_near_flags
	ds	1
triangle_index
	ds	1
triangle_base
	ds	1
triangle_shade
	ds	1
triangle_out_count
	ds	1
shade_nx
	ds	1
shade_ny
	ds	1
shade_nz
	ds	1
shade_cx
	ds	1
shade_cy
	ds	1
shade_cz
	ds	1
tri_x0
	ds	1
tri_y0
	ds	1
tri_x1
	ds	1
tri_y1
	ds	1
tri_x2
	ds	1
tri_y2
	ds	1
tri_dx01
	ds	1
tri_dy01
	ds	1
tri_dx02
	ds	1
tri_dy02
	ds	1
tri_xmin
	ds	1
tri_xmax
	ds	1
tri_ymin
	ds	1
tri_ymax
	ds	1

; Span-setup working set (make_triangle_span).  All on-chip Y scalars.
span_sx0
	ds	1
span_sy0
	ds	1
span_sx1
	ds	1
span_sy1
	ds	1
span_sx2
	ds	1
span_sy2
	ds	1
span_slot0
	ds	1
span_slot1
	ds	1
span_slot2
	ds	1
span_rows_up
	ds	1
span_rows_low
	ds	1
span_k0
	ds	1
span_k1
	ds	1
span_k2
	ds	1
span_cross
	ds	1
span_mid
	ds	1
span_sl_long
	ds	1
span_sl_up
	ds	1
span_sl_low
	ds	1
span_uva
	ds	1
span_uvb
	ds	1
span_su0
	ds	1
span_sv0
	ds	1
span_su1
	ds	1
span_sv1
	ds	1
span_su2
	ds	1
span_sv2
	ds	1
span_dudx
	ds	1
span_dvdx
	ds	1
span_dul_up
	ds	1
span_dvl_up
	ds	1
span_dul_low
	ds	1
span_dvl_low
	ds	1
; Gouraud level fields: the three sorted-slot corner levels and their
; gradients, in level units Q4.8 wherever a fraction applies.
span_sl0
	ds	1
span_sl1
	ds	1
span_sl2
	ds	1
span_dldx
	ds	1
span_dll_up
	ds	1
span_dll_low
	ds	1
span_flip
	ds	1

; The prepass runs after projection and before BUILD_TRIANGLES, so the
; animation/projection temporaries are dead for its whole lifetime.  Aliasing
; its hot cursor fields onto the on-chip Y:$0028-$003F window keeps the new
; references in the one-word short form; no value crosses the command
; boundary and the normal shipping path never observes these aliases.
prepass_occl_base	= shade_acc_r
prepass_occl_index	= shade_acc_g
prepass_occl_mode	= corner_levels+1
prepass_occl_dx12	= shade_ratio_r
prepass_occl_dy12	= shade_ratio_g
prepass_occl_aux	= triangle_tint
prepass_occl_cell_sx	= projection_focal
prepass_occl_cell_sy	= projection_focal_y
prepass_occl_point_sx	= projection_cx
prepass_occl_point_sy	= projection_cy
prepass_occl_col_end	= projection_near
prepass_occl_found	= animation_target_vertex_count
prepass_occl_word_offset	= animation_vertices_remaining
prepass_occl_flow	= project_temp_x

; Occlusion prepass state.  The two counter banks MUST stay here in on-chip
; Y RAM: they are read and written twice per survivor and 96 times per prefix
; pass, while X and Y above $01FF are external SRAM with wait states.  These
; allocations fill the on-chip window Y:$0095-$00FF exactly.
prepass_cnt_lo
	ds	PREPASS_CNT_LO_COUNT
prepass_cnt_hi
	ds	PREPASS_CNT_HI_COUNT

; Sticky arming flag, written only by CMD_PREPASS.  It starts at zero, so an
; unmodified host never runs the prepass at all.
prepass_armed
	dc	0
; Survivor count of the last run, $ffffff after an overrun.  This is the only
; result the prepass puts on the wire.
prepass_surv
	dc	0
; Per-run overrun flag and the cumulative overrun count.
prepass_flow
	dc	0
prepass_overflow
	dc	0
; y:triangles_processed across the run.  The running triangle index needs no
; cell: it lives in R3 for the length of the classification loop.
prepass_tp_save
	ds	1
	ds	4

; -----------------------------------------------------------------------------
; Large Y allocations and the P-memory overlay
;
; The Falcon wires one 32K-word external SRAM into all three DSP address
; spaces.  Only the low addresses are on-chip: P:$0000-$01FF, X:$0000-$00FF and
; Y:$0000-$00FF.  Above that the mapping is
;
;   Y:$0200-$3FFF  ==  P:$0200-$3FFF   (the same physical words)
;   X:$0000-$3FFF  ==  P:$4000-$7FFF
;
; so Y memory from $0200 upwards IS this program's own external code space.
; The scalars above all live in on-chip Y RAM and are unaffected, but a bulk
; array placed there overwrites the program: filling Y:$0200 upwards with face
; normals made the DSP execute normal[151].z as an instruction at P:$0202.
;
; Both resident arrays therefore start above the program.  Y:$09C0 leaves
; room for the span-setup code the record revision added, and the Gouraud
; layout fills the window to its last-but-one word:
;
;   triangle_indices   $09C0 - $29AB   2724 * 3 =  8172 words
;   corner_normals_y   $29AC - $3FFE   1905 * 3 =  5715 words
;
; That is 13,887 of the window's 13,888 words; the other 1,705 normals live
; in X (corner_normals_x), where the resident UV pairs used to be.
;
; Anything that grows the program past P:$09BF silently corrupts the first
; triangle indices instead of failing to assemble.  Check the P extent in the
; LOD after adding code:
;
;   tr -d '\r' < TREX/dsp/trex_dsp.lod | awk '/^_DATA P/{s=$3;n=0;i=1;next} \
;     /^_/{if(i)printf "letzte P = $%04X\n",("0x" s)+n-1;i=0;next} {if(i)n+=NF}'
;
; The current full-mesh program ends at P:$09BA, leaving P:$09BB-$09BF free
; before the resident indices.  Keep the "<" prefix on jumps and the short
; Y-scalar forms on any code added later, or the program will overwrite the
; first triangle indices without an assembler error.
; Absolute-short addressing is the largest single contributor: every data
; reference to a Y scalar below $40 carries the "<" prefix, which is the
; one-word form.  ASM56000 sizes an absolute data address long by default,
; exactly as it does a jump, so the prefix is mandatory and its absence is
; silent -- keep it on new references to those cells, and note the range is
; addresses 0..63 only.
;
; Four later movements: the eleven-bit vertex masking the occluder
; qualification bit needs cost four words, retiring command_get_vertices for
; the occlusion stage returned eighteen, and folding twenty-seven standalone
; memory loads into the ALU operation in front of them returned twenty-seven
; more, and forcing absolute-short data addressing returned 103 -- see
; OPTIMIZATION.md 2.3d.  A parallel move reads its source at the
; start of the instruction, so only loads whose source the ALU op does not
; write may be folded, and a rep/do target must stay one word.
; -----------------------------------------------------------------------------

	org	y:$09c0

; Packed vertex AND corner-normal indices per triangle, uploaded once by
; CMD_LOAD_TRIANGLES and read by every chunk afterwards.  See TRI_INDEX_BITS
; for the three-word field layout.
triangle_indices
	ds	TREX_PRIMITIVES*3

; The Y half of the corner-normal table (entries 0 .. NORMAL_Y_COUNT-1),
; uploaded by CMD_LOAD_NORMALS together with the X half.
corner_normals_y
	ds	NORMAL_Y_COUNT*3

; -----------------------------------------------------------------------------
	end
