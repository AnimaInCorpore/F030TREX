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
	include	'dspconf.inc'

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
; word A.  It is host-owned (tools/o3d2opaque.js, the same sidecar the packet
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

; Direct-mapped, frame-local cache of the two clamped direct-light channel sums
; produced for a corner normal.  Normal indices repeat often in the O3D
; triangle stream, while rotating a normal and evaluating six dot products is
; the dominant part of make_triangle_shade.  The tag is the full normal index;
; the low seven bits select one of 128 entries.  Cached sums are deliberately
; taken BEFORE the per-triangle depth cue, which is applied on every hit and
; miss so triangles sharing a normal but not a depth remain bit-exact.
;
; All three arrays live in the phase-local X gap after the BUILD output and
; before prepass_scratch.  cache_light_directions_x clears the tags after the
; current frame matrix/light payload is final and after the prepass has
; released the overlay.
SHADE_CACHE_ENTRIES	= 128
SHADE_CACHE_MASK	= SHADE_CACHE_ENTRIES-1

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
; Bit 6 selects the control range.  RESET is its only member with bit 0 set;
; the SSI transport probe takes the even side, so the dispatcher separates
; them with one extra JCLR and no new tree level.  The host-port calibration
; burst joins the even side with bit 1 set; one more JCLR splits $40/$42.
CMD_SSI_STREAM		= $40
CMD_PIO_BURST		= $42
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
ACK_SSI_STREAM		= $700010
ACK_PIO_BURST		= $700011

; Object-space lighting variant.  0 keeps the shipping camera-space corner
; rotation; 1 rotates the six light vectors through the frame matrix
; TRANSPOSE once per frame instead, and the Lambert loop dots the RAW
; object-space corner normal.  (R n) . l = n . (Rt l) is an identity for any
; matrix, so the change is exact in real arithmetic; what differs is where
; the fixed-point rounding lands (per-frame light components instead of
; per-corner rotated normal components), so 1 FORFEITS the byte-identical
; framebuffer gate by design and answers only to a geometric comparison.
; The Makefile's variant target rewrites this line; the checked-in source
; must keep it 0 so the shipping .lod stays byte-identical.
OBJLIGHTS	equ	0

; SSI transport probe framing.  The envelope is the same 8-word header and
; 6-word footer the span-stream contract defines; the DSP only relays it.
SSI_HEADER_WORDS	= 8
SSI_FOOTER_WORDS	= 6
SSI_ENVELOPE_WORDS	= SSI_HEADER_WORDS+SSI_FOOTER_WORDS
; Iterations the transmitter may stall before the burst is abandoned.  At four
; cycles a pass and 32 MHz this is about 8 ms, an order of magnitude more than
; the 128-CPU-cycle spacing an armed record channel clocks words at.
SSI_TDE_SPIN		= 65535
ERR_BAD_COMMAND		= $7fffff

; Cross-frame window capacity probe: outer repeats of the 32-cycle inner burn
; loop, so one probe_units step costs PROBE_OUTER*32 DSP cycles.  At the
; Falcon's 16 MIPS that is 8 us per unit and a 0..524 ms range, which has to
; overshoot the window by a wide margin -- the ms axis is only measured in the
; saturated region, where leak rises one-for-one with the load.
PROBE_OUTER	= 4

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

; Capacity of the order list.  ONE list of PREPASS_MAX words plus the two
; coverage masks, the full triangle kill bitmap and the status cells must fit
; from chunk_uvs to the top of physical X memory -- 1,569 words in the stock
; full-mesh layout.  The old radix sort needed a second, equally sized
; ping-pong list, which capped the list at 723 entries; the full mesh's
; area+box survivor count is ~1,100-1,200 in the measured choreography, so
; the classification overflowed EVERY frame, silently disabled the sweep,
; and the wrap of the $ffffff overrun marker (+1 on the next survivor) even
; hid the overflow from the host's ack check.  The two-pass counting sort
; below needs no second list, which is what makes this capacity fit the
; mesh.  An overrun is still detected -- once, after the counting pass --
; and leaves the frame unculled.
PREPASS_MAX	= 1335

; Depth classes for the counting sort.  The sweep does not need the full
; eleven-bucket-bit order: it only compares neighbouring entries for
; INEQUALITY, to know when to seal pending coverage.  Sixty-four classes of
; 32 OT buckets keep sealing strictly nearer than the host draw order and
; therefore only under-approximate kills.  The 64-word counter bank fits in
; on-chip Y RAM; the 128-class/external-SRAM experiment is rejected in
; OPTIMIZATION.md section 2.3i.
PREPASS_COARSE_BITS	= 5
PREPASS_CNT_COUNT	= OT_LENGTH/(1<<PREPASS_COARSE_BITS)

; Stage-2/3 occlusion working set.  An 8x8 pixel cell is the smallest mask
; whose two copies fit beside the single-list order allocation above.  The
; two masks are coverage sealed by strictly nearer depth classes and
; coverage pending in the current class; pending coverage is merged only at
; a class boundary.  Each mask row is two words with cell c at word c/24,
; bit c mod 24; the last word carries eighteen spare bits, which costs
; nothing and lets a row cursor start at any cell without a bias term.
OCCL_CELL_SIZE	= 8
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
	jclr	#0,x0,dispatch_control_even
	nop
	jmp	<command_reset

dispatch_control_even
	; $40 = SSI stream, $42 = host-port calibration burst; bit 1 splits
	; them.  Other even control values alias one of the two, all undefined.
	; With SSIPROBE=0 the stream arm is not assembled and $40 aliases the
	; burst, which is undefined in exactly the same way.
	IF	SSIPROBE
	jclr	#1,x0,command_ssi_stream
	nop
	ENDIF
	jmp	<command_pio_burst

dispatch_command_low
	jclr	#0,x0,dispatch_even
	nop

	; Odd commands: 1 = LOAD, 3 = GET, 5 = STATUS, 7 = LOAD_NORMALS,
	; 13 = LOAD_ANIMATION_GAIT, 15 = FINISH_ANIMATED_FRAME, $7f = RESET.
	jclr	#1,x0,dispatch_odd_bit1_clear
	nop
	; Command 3 is GET_VERTICES.  The span-setup record retired it from the
	; NORMAL path (section 4.1c) and the occlusion stage took its program
	; words, after which it answered ERR_BAD_COMMAND.  The intent was that a
	; host still calling it would take its shadow path rather than deadlock,
	; and the shadow path is exactly what made this a silent failure: the
	; span validator got a failed ack, kept an all-zero projected-vertex
	; buffer, and then reported every record as a mismatch against a DSP that
	; was fine.  Restored in section 3.12; the validator is the only caller.
	jclr	#2,x0,command_get_vertices
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

	; One focal word feeds both focal cells, then the remaining three
	; projection words stream into the consecutive cx/cy/near cells.
	jsr	<receive_word
	move	x0,y:<projection_focal
	move	x0,y:<projection_focal_y
	move	#projection_cx,r0
	do	#3,set_frame_projection_loop
	jsr	<receive_word
	move	x0,y:(r0)+
set_frame_projection_loop

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
	jsr	<cache_light_directions_x

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

	; The five projection words arrive in the exact order of the five
	; consecutive projection cells, so one pointer walk receives them all.
	move	#projection_focal,r0
	do	#5,set_animated_projection_loop
	jsr	<receive_word
	move	x0,y:(r0)+
set_animated_projection_loop

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
	; The lighting loop consumes this phase-local X copy while BUILD chunks
	; stream their normal components from Y.  It must follow prepass_run:
	; that pass owns the same overlay until it has consumed prepass_order.
	jsr	<cache_light_directions_x

	; ---- cross-frame window capacity probe ------------------------------
	; A calibrated load of settable size, placed at the very END of the
	; window so it cannot interact with the prepass/lighting overlay
	; ordering above -- prepass_run owns prepass_order until
	; cache_light_directions_x has consumed it, and this runs after both.
	; It touches NO memory: the question is how much wall-clock DSP work the
	; window absorbs, and a load with its own X/Y traffic would confound
	; that with contention.  It therefore measures the window's TIME
	; capacity and says nothing about bus effects.
	;
	; y:probe_units is dc 0, so a shipping build pays three instructions per
	; frame here and nothing else -- the same contract the prepass hook
	; above states, and the reason this can stay in the tree.
	;
	; What the sweep reads is the SHAPE of leak(units) = frame(units) -
	; frame(0), not any single run.  Below the window's spare capacity the
	; load is absorbed and the frame is flat; above it the frame rises one
	; for one with the load.  The knee is the spare capacity and the slope
	; is the per-unit cost, so the sweep calibrates its own time axis and
	; needs no freestanding run-now mode, no new host command, and no host
	; code at all.
	;
	; Thirty-two NOPs per unit rather than a REP: the 56001 forbids REP (and
	; DO) in the last three instruction words of a DO loop, and LC is
	; sixteen bits, so a one-word body would cap the probe at 65,535 cycles
	; -- 4 ms, far under the 117.7 ms the prepass already proved absorbable.
	;
	; PROBE_OUTER then multiplies the range without spending 32 more program
	; words per doubling.  The reason it must reach far past any plausible
	; window: the ms axis is only MEASURED where the load saturates the
	; window and leak rises 1:1 with it.  A 32-cycle unit alone tops out at
	; ~131 ms, which the window still partly absorbs, so that build could
	; only ever report a modelled axis.  The inner DO is the outer loop's
	; FIRST word, well clear of the last three the 56001 reserves.
	IF	WINPROBE
	move	y:probe_units,a
	tst	a
	jeq	<finish_no_probe
	move	a1,x0
	do	#PROBE_OUTER,probe_burn_outer
	do	x0,probe_burn_loop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
probe_burn_loop
	nop
	nop
	nop
probe_burn_outer
	ENDIF
finish_no_probe

	move	#ACK_FRAME,x0
	jsr	<send_word
	move	y:<vertex_count,x0
	jsr	<send_word
	jmp	<main_loop

; Restored here after the occlusion stage claimed its twenty-one program words
; (section 3.12).  The span-setup record made it unnecessary on the NORMAL path
; in 4.1c, but span_validate_enabled and the projected-vertex fallback are still
; callers, and retiring it turned 4.1b's regression gate into a tool that
; reported 100% mismatches while comparing nothing.  It runs only when the host
; sends command 3, so the shipping frame pays program words and no cycles.
command_get_vertices
	move	#ACK_VERTICES,x0
	jsr	<send_word
	move	y:<vertex_count,x0
	jsr	<send_word
	; Four words per vertex, straight out of the projection's own output
	; array: x, y, z, spare.  That is the stride load_projected_xy and
	; lookup_projected_z already index at, and the count the host sizes
	; DSP_VERTEX_OUTPUT_WORDS from -- both sides must agree or the port
	; deadlocks, exactly as the GET_TRIANGLES word count does.
	move	y:<vertex_count,a
	rep	#2
	asl	a
	move	a1,x0
	move	#projected_vertices,r0
	do	x0,vertex_send_loop
	move	x:(r0)+,x0
	jsr	<send_word
	; JSR may not close a hardware loop; the NOP is the loop's last word.
	nop
vertex_send_loop
	jmp	<main_loop

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
	; Each TFR's parallel slot stores the PREVIOUS field: the parallel
	; move reads A1 at the start of the instruction, before the transfer
	; lands -- the read-at-start rule working for us here.
	tfr	x1,a	a1,y:triangle_i0
	rep	#TRI_INDEX_BITS
	lsr	a
	; The occluder bit lands in bit 11 after this shift; mask it off or the
	; vertex lookup reads 2,048 entries past v1.
	and	x0,a
	tfr	y1,a	a1,y:triangle_i1
	and	x0,a
	tfr	y1,a	a1,y:triangle_i2
	rep	#TRI_INDEX_BITS
	lsr	a
	move	a1,y:triangle_n0
	move	y:(r2)+,y1
	move	#>TRI_INDEX_MASK,x0
	tfr	y1,a
	and	x0,a
	tfr	y1,a	a1,y:triangle_n1
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
	; Advance the streaming bit cursor inline.  This is on every armed
	; triangle, so the call/return pair costs more than the small body.
	; The TFR's parallel slot stores the PRE-transfer A1 -- the AND
	; result -- read-at-start working for us rather than against us.
	; The wrap test reads A2 bit 0 -- the bit ASL just carried out of A1.
	; The old full-accumulator TST read the SIGN EXTENSION of a bit-23
	; one-hot as "still inside the word", zeroed the cursor and silently
	; stopped consuming kills at the 24th triangle of every armed frame.
	tfr	x1,a	a1,y:span_flip
	asl	a
	move	a1,x1
	jclr	#0,a2,build_prepass_kill_advance_store
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
	move	#span_sl_long,r4
	move	a1,x:(r1)+			; w4
	; w5..w13 stream from the span scalars, which the Y layout keeps in
	; EXACT wire order so this software-pipelined XY copy moves one word
	; per instruction: the X field stores the OLD accumulator while the Y
	; field fetches the next cell.  A is the pipeline register because the
	; dual move's X field only encodes X0/X1/A/B and its Y field only
	; Y0/Y1/A/B; the Y-side load sign-extends A2, so the X-side limited
	; store passes A1 through exactly.  R4 was set two instructions back
	; to respect the AGU write-use spacing.
	move	y:(r4)+,a
	do	#8,span_record_gradients
	move	a,x:(r1)+	y:(r4)+,a
span_record_gradients
	move	a,x:(r1)+			; w13
	; The Gouraud tail: both sorted level starts share w14 (Q4.8 each,
	; non-negative, at most 15<<8); the three level gradients then
	; continue through the same cursor, which the copy above left parked
	; on span_dldx.
	move	y:span_sl0,a
	rep	#12+8
	asl	a				; (sl0<<8) << 12
	move	y:span_sl1,b
	rep	#8
	asl	b				; sl1 << 8
	add	b,a
	move	a1,x:(r1)+			; w14
	move	y:(r4)+,a
	move	a,x:(r1)+	y:(r4)+,a
	move	a,x:(r1)+	y:(r4)+,a
	move	a,x:(r1)+			; w17
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
	; One shared #>1 serves both counters; the ADD's parallel slot
	; fetches the countdown into B while A carries the index.
	move	y:triangle_index,a
	move	#>1,x0
	add	x0,a	y:triangle_remaining,b
	move	a1,y:triangle_index
	sub	x0,b
	move	b1,y:triangle_remaining
	tst	b
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
	move	a1,x0
	move	#triangle_out,r0
	do	x0,triangle_send_loop
	move	x:(r0)+,x0
	jsr	<send_word
	; JSR may not close a hardware loop; the NOP is the loop's last word.
	nop
triangle_send_loop
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

cache_light_directions_x
	; Keep the host-facing light payload in its compact, contiguous Y block,
	; then copy just the 18 direct-light words once per finished frame into
	; phase_light_directions_x.  The per-corner dot loop can then issue its
	; Y normal-component load and X light-component load in the same MPY/MAC.
	;
	; The target lies in the tail of prepass_order that is dead after the
	; prepass completes and above the maximum BUILD UV/output allocation.  It
	; is also safe for the no-prepass SET_FRAME test path: no BUILD command
	; can arrive until this routine has returned its frame acknowledgement.
	IF	OBJLIGHTS
	; Rotate each light through the matrix transpose while copying, so the
	; per-corner rotation in make_triangle_shade disappears.  Column j of
	; the row-major matrix walks with N2=3; each column restarts R2 with an
	; immediate reload, which is cheaper than rewinding a cursor for a body
	; that runs six times per frame.  R2/N2 and X1/Y1 are dead at all three
	; call sites: each falls straight through to its acknowledgement.
	move	#3,n2
	move	#light_direction,r0
	move	#phase_light_directions_x,r1
	do	#LIGHT_COUNT*2,cache_light_rotate_loop
	; Each column's R2 reload sits at least one instruction before its
	; first use: the pipeline forbids addressing through a register the
	; previous instruction wrote.
	move	#frame_matrix,r2
	move	y:(r0)+,x1
	move	y:(r0)+,y1
	move	y:(r0)+,x0
	move	y:(r2)+n2,y0
	mpy	x1,y0,a	y:(r2)+n2,y0
	mac	y1,y0,a	y:(r2),y0
	mac	x0,y0,a
	rnd	a
	move	#frame_matrix+1,r2
	move	a1,x:(r1)+
	move	y:(r2)+n2,y0
	mpy	x1,y0,a	y:(r2)+n2,y0
	mac	y1,y0,a	y:(r2),y0
	mac	x0,y0,a
	rnd	a
	move	#frame_matrix+2,r2
	move	a1,x:(r1)+
	move	y:(r2)+n2,y0
	mpy	x1,y0,a	y:(r2)+n2,y0
	mac	y1,y0,a	y:(r2),y0
	mac	x0,y0,a
	rnd	a
	move	a1,x:(r1)+
cache_light_rotate_loop
	ELSE
	move	#light_direction,r0
	move	#phase_light_directions_x,r1
	do	#LIGHT_COUNT*6,cache_light_direction_loop
	move	y:(r0)+,x0
	move	x0,x:(r1)+
cache_light_direction_loop
	ENDIF

	; R1 now points at shade_cache_tags.  Only tags need invalidating; sum
	; words are read only after an exact full-index tag match.
	move	#>-1,a
	rep	#SHADE_CACHE_ENTRIES
	move	a1,x:(r1)+
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
	;
	; The triple rides in x1/y1/x0 -- all three are legal multiplier
	; pairings against y0 -- so each row streams the matrix through Y0
	; with no staging cells and no reloads.  The translation cursor
	; rewinds through (r1)+n1 with N1 = -2, because the XY dual move
	; cannot encode (Rn)-Nn; the matrix rewinds through the single
	; parallel move (r4)-n4 exactly like transform_vertices.  Both
	; rewinds are block size MINUS ONE, since the +Nn update replaces
	; the final access's own post-increment -- an N1 of -3 walks the
	; cursor one word lower every vertex, into command_word and onward.
	; In place stays safe by construction: the three reads of a vertex
	; complete before its first write, and both cursors advance three
	; per vertex.  Same MAC chain, same RND -- the rounding is unchanged.
	move	y:<vertex_count,x0
	move	#camera_vertices,r0
	move	#camera_vertices,r2
	move	#object_translation,r1
	move	#>-2,n1
	move	#frame_matrix,r4
	move	#8,n4

	do	x0,transform_animated_loop
	move	x:(r0)+,x1
	move	x:(r0)+,y1
	move	x:(r0)+,x0

	move	x:(r1)+,a	y:(r4)+,y0
	mac	x1,y0,a	y:(r4)+,y0
	mac	y1,y0,a	y:(r4)+,y0
	mac	x0,y0,a
	rnd	a
	move	a1,x:(r2)+

	move	x:(r1)+,a	y:(r4)+,y0
	mac	x1,y0,a	y:(r4)+,y0
	mac	y1,y0,a	y:(r4)+,y0
	mac	x0,y0,a
	rnd	a
	move	a1,x:(r2)+

	move	x:(r1)+n1,a	y:(r4)+,y0
	mac	x1,y0,a	y:(r4)+,y0
	mac	y1,y0,a	y:(r4)-n4,y0
	mac	x0,y0,a
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

	; Near-plane test.  There is no triangle clipping here: a vertex closer
	; than projection_near has its divisor clamped so the division stays
	; well-defined, and is marked in the record's flags word.  The triangle
	; builder drops every triangle touching such a vertex.  The TFR and
	; SUB carry the two temp stores in their parallel slots.
	move	y:<projection_near,y1
	tfr	x0,a	x1,y:<project_temp_x
	sub	y1,a	y0,y:<project_temp_y
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
	; One cursor serves both sides: R5 reads triangle_i0..i2 while the
	; indexed (r5+n5) store lands each z six cells up in triangle_z0..z2
	; -- after the read's post-increment the gap is exactly five, hence
	; N5.  R6 then sums the triple.  Both registers are free in every
	; caller (BUILD and the classify passes).
	move	#triangle_i0,r5
	move	#5,n5
	move	#triangle_z0,r6
	do	#3,make_zkey_lookups
	move	y:(r5)+,x0
	jsr	<lookup_projected_z
	move	x0,y:(r5+n5)
make_zkey_lookups

	move	y:(r6)+,a
	move	y:(r6)+,x0
	add	x0,a	y:(r6)+,x0
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
	; Clobbers a, b, x0, x1, y0, y1, r0, r3-r7, n4 and n7.  r1 and r2
	; belong to the caller's chunk loop and are not touched.
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
	move	#shade_cx,r4
	move	#>-3,n4
	move	#>SHADE_CACHE_ENTRIES,n7

	do	#3,shade_corner_loop
	; Direct-map the full normal index through its low seven bits.  R7 keeps
	; the tag/sum slot live across the miss path; none of the rotation or
	; Lambert loops otherwise uses it.  A hit jumps over both expensive
	; stages and re-enters at the common per-triangle depth multiply.
	move	y:(r5)+,a
	move	a1,b
	move	#>SHADE_CACHE_MASK,x0
	and	x0,b
	move	#shade_cache_tags,x0
	add	x0,b
	move	b1,r7
	move	#>NORMAL_Y_COUNT,x1
	move	x:(r7),x0
	cmp	x0,a
	jeq	<shade_corner_cache_hit

	; Bank-split load of this corner's normal: index below NORMAL_Y_COUNT
	; reads the Y block behind the triangle indices, at or above it the X
	; block that displaced the UV pairs.  The three components load
	; straight into x1/y1/x0 and stay there through the whole rotation
	; below, which writes only A and Y0 -- no staging cells, no reloads.
	; Cache the full tag in the compare's parallel slot.  CMP does not write
	; A, and the move reads A1 at instruction start, so the following bank
	; address calculation still sees the same normal index.
	cmp	x1,a	a1,x:(r7)
	jge	<shade_corner_x_bank
	move	a1,x0
	add	x0,a
	add	x0,a
	move	#corner_normals_y,x0
	add	x0,a
	move	a1,r0
	nop
	move	y:(r0)+,x1
	move	y:(r0)+,y1
	move	y:(r0),x0
	jmp	<shade_corner_loaded
shade_corner_x_bank
	sub	x1,a
	move	a1,x0
	add	x0,a
	add	x0,a
	move	#corner_normals_x,x0
	add	x0,a
	move	a1,r0
	nop
	move	x:(r0)+,x1
	move	x:(r0)+,y1
	move	x:(r0),x0
shade_corner_loaded
	; Camera-space normal, one matrix row per pass into the consecutive
	; shade_cx..shade_cz cells.  x1*y0, y1*y0 and x0*y0 are all legal
	; multiplier pairings, so each row streams the matrix through Y0 and
	; needs no other memory operand at all.  R0 is dead between the normal
	; fetch above and the Lambert loops' own re-point below, so it carries
	; the row cursor.  R4 stays parked on shade_cx for the Lambert loops;
	; using R0/R3 here removes their per-corner R4/N4 reinitialization.
	IF	OBJLIGHTS
	; The cached light vectors are already object-space, so the raw corner
	; normal streams to shade_cx..cz unrotated for the Lambert loops.  The
	; R7 advance from the shared tail below sits between the R3 load and
	; its first use, which the pipeline requires anyway.
	move	#shade_cx,r3
	move	(r7)+n7
	move	x1,y:(r3)+
	move	y1,y:(r3)+
	move	x0,y:(r3)+
	ELSE
	move	#frame_matrix,r0
	move	#shade_cx,r3
	do	#3,shade_rotate_row
	move	y:(r0)+,y0
	mpy	x1,y0,a	y:(r0)+,y0
	mac	y1,y0,a	y:(r0)+,y0
	mac	x0,y0,a
	rnd	a
	move	a1,y:(r3)+
shade_rotate_row
	move	(r7)+n7
	ENDIF

	; Lambert sum over the three source lights.  Each contributes its own
	; clamped cosine: a face turned away from one light simply gets nothing
	; from it instead of darkening the others, which is what the PS1's
	; per-light clamp does.  The host pre-scaled the vectors so the total
	; cannot exceed 1.0 for any normal; the clamp below is the guard for
	; rounding, not for the model.
	; One outer pass per channel -- red then green, the same clamped-dot
	; sum over the two scaled vector sets, R3 walking the consecutive
	; shade_sum_r/g result cells.  R0 streams straight from the last red
	; vector into the first green one, and (r4)+n4 rewinds the camera-space
	; normal for every light.  cache_light_directions_x has copied the
	; direct vectors to X after projection/prepass, so each MPY/MAC
	; simultaneously fetches the next Y-resident normal component and
	; X-resident light component.  The DSP's XY move form assigns R0 to
	; the X bus and R4 to the Y bus here.
	; Advance R7 from this normal's tag to its red raw-sum slot.  N7 then
	; walks red -> green after the two channel passes.  The advance itself
	; sits at the tail of each IF branch above: the object-lights branch
	; needs it as the pipeline gap after its R3 load.
	move	#phase_light_directions_x,r0
	move	#shade_sum_r,r3
	do	#2,shade_channel_loop
	clr	b
	do	#LIGHT_COUNT,shade_light_loop
	tfr	b,a	x:(r0)+,x0	y:(r4)+,y0
	mpy	x0,y0,a	x:(r0)+,x0	y:(r4)+,y0
	mac	x0,y0,a	x:(r0)+,x0	y:(r4)+,y0
	mac	x0,y0,a
	rnd	a	(r4)+n4
	tst	a
	jle	<shade_light_none
	add	a,b
shade_light_none
	nop
shade_light_loop
	jsr	<shade_clamp_sum
	; The X:R dual move stores the cache value while copying the same limited
	; accumulator into Y0 for the depth multiply.  The stored value is the raw
	; clamped light sum; depth remains specific to this triangle and is
	; recomputed on cache hits below.
	move	a,x:(r7)	a,y0
	move	y:<shade_depth_scale,x0
	mpy	x0,y0,a
	rnd	a	(r7)+n7
	move	a1,y:(r3)+
shade_channel_loop
	jmp	<shade_corner_sums_ready

shade_corner_cache_hit
	; Tag -> red sum, then apply the identical two MPY/RND depth operations
	; the miss path uses.  Keeping the cache before this step preserves the
	; exact per-triangle depth cue and its rounding.
	move	(r7)+n7
	move	#shade_sum_r,r3
	move	y:<shade_depth_scale,y0
	do	#2,shade_cache_hit_channel
	move	x:(r7),x0
	mpy	x0,y0,a
	rnd	a	(r7)+n7
	move	a1,y:(r3)+
shade_cache_hit_channel

	; This corner's own level from its two sums, then accumulate ONE THIRD
	; of each sum: a corner sum reaches 1.09 (see shade_clamp_sum), so the
	; raw three-corner total would exceed 1.0 and the intermediate a1
	; store would wrap exactly like the saturation bug section 4.4 of
	; OPTIMIZATION.md documents -- the brightest faces would land in the
	; darkest banks.  Thirds keep every intermediate below 1.0 except the
	; final one, which the saturation below catches, and they make the
	; accumulator the corner MEAN outright.
shade_corner_sums_ready
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
	; R5 walks the consecutive triangle_i0..i2, R6 the interleaved
	; tri_x0/tri_y0.. pairs, and the three near-plane flag words
	; accumulate in B across the loop -- lookup_projected_xy touches
	; neither.  Both registers are free in every caller: BUILD sets its
	; own r5/r6 later in the shade pass, the classify loop keeps nothing
	; there, and the sweep's r5-r7 lifetimes start inside prepass_stamp.
	clr	b
	move	#triangle_i0,r5
	move	#tri_x0,r6
	do	#3,make_area_corners
	move	y:(r5)+,x0
	jsr	<lookup_projected_xy
	move	x1,y:(r6)+
	move	y1,y:(r6)+
	add	y0,b
make_area_corners

	; Any vertex behind the near plane drops the whole triangle.  Returning a
	; zero area routes it through the existing degenerate path.
	tst	b
	jeq	<tri_near_ok
	clr	a
	rts
tri_near_ok
	; The fully-outside screen test that used to sit here is subsumed by
	; make_triangle_bbox: a clipped box that comes out empty is exactly the
	; all-beyond-one-edge case.  The box runs after the cheaper area cull,
	; so it only costs work for the ~27% of triangles that survive it.

	; The delta stores continue through R6, which the corner loop left
	; parked exactly on tri_dx01, and each SUB's parallel slot fetches the
	; next pair's first operand into the other accumulator.
	move	y:tri_x1,a
	move	y:tri_x0,x0
	sub	x0,a	y:tri_y1,b
	move	a1,y:(r6)+
	move	y:tri_y0,x0
	sub	x0,b	y:tri_x2,a
	move	b1,y:(r6)+
	move	y:tri_x0,x0
	sub	x0,a	y:tri_y2,b
	move	a1,y:(r6)+
	move	y:tri_y0,x0
	sub	x0,b
	move	b1,y:(r6)+

	move	y:tri_dx01,x0
	move	y:tri_dy02,y0
	mpy	x0,y0,a	y:tri_dy01,x0
	move	y:tri_dx02,y0
	mac	-x0,y0,a
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
	; Each NEG's parallel slot stores the PRE-negation value -- the half
	; height -- while the negation itself becomes the k factor.
	move	y:span_sy1,a
	move	y:span_sy0,x0
	sub	x0,a
	neg	a	a1,y:span_rows_up
	move	a1,y:span_k2
	move	y:span_sy2,a
	move	y:span_sy1,x0
	sub	x0,a
	neg	a	a1,y:span_rows_low
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
	tst	a	b1,y:span_flip
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
; The order is a two-pass counting sort into 64 coarse depth classes of 32 OT
; buckets each (see PREPASS_COARSE_BITS): classification runs once to
; count, once more to scatter, and needs no second list -- the ping-pong
; scratch of the earlier radix sort is what limited the order list to 723
; entries, under the full mesh's real survivor count, which disabled the
; sweep on every frame it was meant to serve.  Coarse classes only merge
; neighbouring buckets, never reorder them, so sealing across class
; boundaries under-approximates the host's strictly-nearer relation and
; kills stay sound.
;
; Within one class the DSP order ascends in triangle index while the host
; draws its buckets in LIFO submission order.  That difference is legal and
; must NOT be exploited: a later stage may only let a triangle occlude
; another once the whole class has been tested, never rank by rank.  Class
; boundaries are visible at run time as an inequality between the class
; fields of two neighbouring entries, so no extra table is needed.
; -----------------------------------------------------------------------------

command_prepass
	jsr	<receive_word

	; Mode 4 (bit 2): diagnostic counter readout, checked first so the
	; bit-0/1 decode below keeps its shape.  Replies ACK_PREPASS plus the
	; six status-cell counters of the last run and computes nothing;
	; 5-7 alias it.
	jset	#2,x0,prepass_stats_reply
	nop
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
	; A standalone run-now pass uses prepass_order too. Refresh the X cache
	; before acknowledging it so a diagnostic mode-2/3 run followed by BUILD
	; cannot leave the Lambert loop reading its consumed order-list contents.
	jsr	<cache_light_directions_x
prepass_ack_exit
	move	#ACK_PREPASS,x0
	jsr	<send_word
	move	y:prepass_surv,x0
	jsr	<send_word
	jmp	<main_loop

; Mode 4: send ACK_PREPASS plus the six diagnostic counters the last run left
; in prepass_status+2..+7 -- stamp calls, stamped cells, query kills, dirty
; merges, query cells visited, stamp cells visited, in that cell order.
; Reading is non-destructive; prepass_run zeroes the cells at its next start.
; The DO closes on a NOP because JSR may not sit at a hardware loop's last
; address.
prepass_stats_reply
	move	#ACK_PREPASS,x0
	jsr	<send_word
	move	#prepass_status+2,r0
	nop
	do	#6,prepass_stats_send
	move	x:(r0)+,x0
	jsr	<send_word
	nop
prepass_stats_send
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

	; The class counters and the stage-2 kill bitmap start every run at
	; zero.  REP with a one-word move clears each in two words of program
	; memory, which matters far more here than the cycles do.
	move	#prepass_cnt_lo,r0
	nop
	rep	#PREPASS_CNT_COUNT
	move	a1,y:(r0)+
	; The six diagnostic counters in the status tail restart with them.
	move	#prepass_status+2,r0
	nop
	rep	#6
	move	a1,x:(r0)+
	jsr	<prepass_clear_kill

	; -------------------------------------------------------------------
	; Phase 0/1 -- two-pass counting sort into depth classes.  The first
	; classification pass counts survivors per class and caches each
	; survivor as one bit in the still-unused kill bitmap; an exclusive
	; prefix over the 64 counters turns them into write cursors, and the
	; second pass scatters straight from that cache -- the bit answers
	; area+bbox outright, so pass 2 re-runs only the index unpack and the
	; key for survivors.  What two passes buy is the second list the radix
	; sort ping-ponged through: the difference between 723 entries and the
	; ~1,150 the full mesh actually needs.  The cache also makes the two
	; survivor sets equal by construction rather than by bit-identical
	; re-derivation, so the scatter can never disagree with the counts.
	; -------------------------------------------------------------------
	clr	a
	move	a1,y:<prepass_occl_mode
	jsr	<prepass_classify

	; An empty frame has nothing to sort or cull; an overrun would write
	; past the order list, so it reports $ffffff and leaves the frame
	; unculled, exactly like the old per-entry capacity stop -- but
	; detected ONCE, after counting, where no wrap can ever hide it.
	move	y:prepass_surv,a
	tst	a
	jeq	<prepass_restore
	move	#>PREPASS_MAX,x0
	cmp	x0,a
	jle	<prepass_capacity_ok
	move	#>$ffffff,a
	move	a1,y:prepass_surv
	move	x0,y:prepass_flow
	; Pass 1 filled the bitmap with the survivor cache.  BUILD must never
	; read survivor bits as kills, so the overflow exit clears them and
	; leaves the frame unculled exactly as before.
	jsr	<prepass_clear_kill
	jmp	<prepass_restore
prepass_capacity_ok

	; Exclusive prefix over the class counters, biased by the order base:
	; each counter then holds the ADDRESS its next entry goes to.
	move	#>prepass_order,a
	move	#prepass_cnt_lo,r0
	nop
	do	#PREPASS_CNT_COUNT,prepass_prefix_end
	move	y:(r0),x0
	move	a1,y:(r0)+
	add	x0,a
prepass_prefix_end

	move	#>1,a
	move	a1,y:<prepass_occl_mode
	jsr	<prepass_classify

	; The cache is spent; the sweep and BUILD need the bitmap empty before
	; the first real kill lands in it.
	jsr	<prepass_clear_kill

	; The list ascends in depth class, which is near to far: class 0 is
	; the closest.  The host walks its Ordering Table from 2047 downwards
	; and therefore draws this list back to front, as painter's algorithm
	; requires.  Stage 2 tests each survivor against sealed coverage and
	; stage 3 stamps only qualified, still-visible triangles into the
	; pending mask.  BUILD consumes the resulting global kill bitmap; the
	; sorted list itself remains an internal DSP worklist.
	jsr	<prepass_occlusion

prepass_restore
	move	y:prepass_tp_save,a
	move	a1,y:<triangles_processed
	rts

; One classification pass over the resident index list.  The mode cell
; selects the pass: 0 runs the full survivor test, counts into the class
; counters and sets the survivor's bit in the still-unused kill bitmap; 1
; walks those cached bits and scatters the packed entry at the class cursor,
; re-running only the index unpack and the key -- the bit already answers
; area+bbox.  The bucket rule and the class shift are one shared code path,
; and both passes see the same survivor set by construction, which is what
; entitles pass 2 to trust pass 1's counts.
;
; R3 carries the triangle index instead of a Y cell.  Every absolute Y access
; on this DSP is a two-word instruction, and the index is touched on all
; three exits of the loop body, so an address register that survives the
; three JSRs is worth six program words here.  R4 and the short cell
; prepass_cls_bit carry the cache's streaming word/bit cursor the same way;
; nothing the loop calls touches R4.
prepass_classify
	move	#0,r3
	move	#triangle_indices,r2
	move	#2,n2
	move	#prepass_kill,r4
	move	#>1,a
	move	a1,y:<prepass_cls_bit
	move	y:<triangle_list_count,a
	tst	a
	jeq	<prepass_classify_done
	move	a1,x0
	do	x0,prepass_classify_end

	; Pass 2 asks the cache instead of the geometry.  A cached reject
	; still owes the walk two things every processed triangle pays
	; elsewhere: R2 must step past the triangle's three resident words
	; (unpack normally does that), and the shared cursor advance at
	; prepass_classify_next.
	move	y:<prepass_occl_mode,b
	tst	b
	jeq	<prepass_classify_full
	move	y:<prepass_cls_bit,x0
	move	x:(r4),a
	and	x0,a
	jne	<prepass_classify_hit
	move	(r2)+
	move	(r2)+n2
	jmp	<prepass_classify_next
prepass_classify_hit
	jsr	<prepass_unpack_indices
	jsr	<make_triangle_zkey
	jmp	<prepass_classify_key

prepass_classify_full
	; Only the three VERTEX indices matter here; the corner-normal fields
	; feed shading, which the prepass never reaches.  Word C is therefore
	; never read at all -- the +N2 post-increment steps over it while word
	; B is being fetched.
	jsr	<prepass_unpack_indices

	; The chunk pass's own survivor test, called rather than copied.  Area
	; sign first (it also absorbs the near-plane rejects), then the clipped
	; box, then the key.  R2 survives all three, which is what lets the
	; loop keep its cursor in it.
	jsr	<make_triangle_area
	tst	a
	jge	<prepass_classify_next
	jsr	<make_triangle_bbox
	tst	a
	jeq	<prepass_classify_next
	jsr	<make_triangle_zkey
prepass_classify_key

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
	; The sweep's depth class: the saturated bucket, coarsened.
	rep	#PREPASS_COARSE_BITS
	lsr	a

	move	y:<prepass_occl_mode,b
	tst	b
	jne	<prepass_classify_write

	; Count pass: one class counter, the survivor total, and the
	; survivor's cache bit.  The bitmap is dead storage until the sweep,
	; and prepass_run clears it again on every path that follows pass 1,
	; overflow included, so BUILD only ever sees real kills in it.
	move	#>prepass_cnt_lo,x0
	add	x0,a
	move	a1,r0
	move	#>1,x0
	move	y:(r0),b
	add	x0,b	y:prepass_surv,a
	move	b1,y:(r0)
	add	x0,a
	move	a1,y:prepass_surv
	move	y:<prepass_cls_bit,x0
	move	x:(r4),b
	or	x0,b
	move	b1,x:(r4)
	jmp	<prepass_classify_next

prepass_classify_write
	; Write pass: E = (triangle index << TRI_INDEX_BITS) | class, stored
	; at the class cursor, which then advances.  Ascending R3 makes the
	; within-class order ascending triangle index, the same stable order
	; the radix sort produced within a bucket.
	;
	; R3 is 16 bits and the index stays below 2,724, so whichever way the
	; register-to-register move extends it the low 16 bits are the value
	; and A1 holds it.  A2 does not matter either: the shift below feeds
	; A1 from A1 and A0, and only A1 is stored.
	move	a1,x1
	move	#>prepass_cnt_lo,x0
	add	x0,a
	move	a1,r0
	move	r3,a
	rep	#TRI_INDEX_BITS
	asl	a
	add	x1,a
	move	y:(r0),b
	move	b1,r1
	move	#>1,x0
	add	x0,b
	move	b1,y:(r0)
	move	a1,x:(r1)

prepass_classify_next
	; Advance the shared cache cursor -- every triangle, both passes, all
	; exits.  The wrap reads the carried-out bit from A2 bit 0, the same
	; idiom BUILD's kill consumer uses; a full-accumulator TST here is
	; 2.3f defect 2.
	move	y:<prepass_cls_bit,a
	asl	a
	move	a1,y:<prepass_cls_bit
	jclr	#0,a2,prepass_classify_nowrap
	move	(r4)+
	move	#>1,a
	move	a1,y:<prepass_cls_bit
prepass_classify_nowrap
	move	(r3)+
	; The loop's last word is deliberately a NOP nobody jumps to.  Every
	; exit branches to prepass_classify_next or lands on _nowrap, and
	; landing a jump directly on a hardware loop's LA is the one place
	; where the loop-back and the jump would fight over the program
	; counter.  One word buys that whole question away.
	nop
prepass_classify_end
prepass_classify_done
	rts

; Zero the kill bitmap.  Three sites need the identical clear: the run
; start, the retirement of the pass-2 survivor cache before the sweep, and
; the overflow exit that bypasses the sweep.  The bitmap may only ever
; reach BUILD holding real kills.
prepass_clear_kill
	clr	a
	move	#prepass_kill,r0
	nop
	rep	#PREPASS_KILL_WORDS
	move	a1,x:(r0)+
	rts

; The sorted list is walked once from depth class 0 (nearest) to class 63
; (farthest).  `seal` contains only complete cells from earlier classes;
; `pending` contains cells stamped by the current class.  A pending mask is
; merged only when the next entry changes class, which is the ordering rule
; that makes the result independent of the host's LIFO order within a class.
;
; Both coverage walks visit only the cells the survivor's clamped screen box
; overlaps: a cell covers pixels 8c..8c+7, so the overlapped range is exactly
; [min>>3, max>>3] on each axis.  The former cursor visited every cell of
; the whole grid for every survivor, which is what priced the sweep out of
; the synthetic hold's frame budget; the range walk is bounded by the
; survivor's own screen area instead.  The query additionally stops at the
; first unsealed cell -- one uncovered cell already proves the triangle
; visible, and most triangles meet one in their first few cells.
;
; The stamp decides full-cell coverage with three incremental edge values in
; one doubled integer domain (see prepass_stamp).  The previous revision
; asked prepass_point_inside per cell corner, and its stored A1 edge signs
; made the inside test unsatisfiable -- fractional MPY leaves a small
; product's value in A0 and only its sign extension in A1, the very trap the
; span_cross comment documents -- so no cell was ever stamped and the whole
; stage culled nothing.  The A0-based edge setup below is what makes the
; kill bitmap live for the first time.
prepass_occlusion
	move	y:prepass_surv,a
	tst	a
	jeq	<prepass_occlusion_done
	move	a1,x0
	; Both masks start the sweep empty, the pending mask has stamped
	; nothing yet, and the class sentinel can match no real class.
	clr	a
	move	#prepass_scratch,r0
	rep	#(OCCL_MASK_WORDS*2)
	move	a1,x:(r0)+
	move	a1,y:<prepass_occl_dirty
	move	#>OT_LENGTH,a
	move	a1,y:<prepass_occl_flow
	; N4 is the mask-row stride for both walks, N0 the cell-size-minus-one
	; corner shift for the stamp's anchor choice.
	move	#OCCL_MASK_ROW_WORDS,n4
	move	#OCCL_CELL_SIZE-1,n0
	move	#prepass_order,r1
	do	x0,prepass_occlusion_loop_end

prepass_occlusion_loop
	; Entry E = (triangle index << 12) | depth class.
	move	x:(r1)+,a
	move	#>PREPASS_ENTRY_BUCKET_MASK,x0
	tfr	a,b
	and	x0,b
	; AND is a 24-bit operation: it clears B1 to the class but leaves B2
	; holding the sign extension of entry bit 23, which is set exactly
	; when the packed triangle index is 2,048 or higher.  The full-width
	; CMP below then never matched for those 676 triangles, so every one
	; of their survivors spuriously took the class-change path and merged
	; pending coverage mid-class -- the 2.3f defect-2 sign-extension trap
	; in compare form, found by the 2.3j merge counter (245.6 "dirty
	; merges" per run against a sorted list's possible 63).  Reloading B
	; from B1 rebuilds the clean extension: the class is at most 63.
	move	b1,b
	rep	#TRI_INDEX_BITS
	lsr	a
	move	a1,y:<prepass_occl_index

	; The first entry has an out-of-range previous-class sentinel.  On
	; later changes, seal the completed class before testing the new one.
	move	y:<prepass_occl_flow,x0
	cmp	x0,b
	jeq	<prepass_occlusion_same_bucket
	move	b1,y:<prepass_occl_flow
	jsr	<prepass_merge_masks
prepass_occlusion_same_bucket
	; Reload the survivor and rebuild its screen scalars with the very
	; routines the chunk pass uses.  Both verdicts are known to pass --
	; phase 0 proved them -- so only tri_x/tri_y and the clamped box out
	; of make_triangle_bbox matter here.
	move	y:<prepass_occl_index,x0
	jsr	<prepass_load_triangle
	jsr	<make_triangle_area
	jsr	<make_triangle_bbox

	; Cell range of the clamped box.  X1 carries cx0 into the width count,
	; N2/N3 carry the range's top-left pixel anchor to the stamp setup,
	; and X0 holds the +1 for both inclusive-range counts.
	move	y:tri_xmin,a
	rep	#3
	lsr	a
	move	a1,x1
	rep	#3
	asl	a
	move	a1,n2
	move	y:tri_ymin,a
	rep	#3
	lsr	a
	move	a1,y0
	rep	#3
	asl	a
	move	a1,n3
	move	#>1,x0
	move	y:tri_xmax,a
	rep	#3
	lsr	a
	sub	x1,a
	add	x0,a
	move	a1,y:<prepass_occl_ncx
	move	y:tri_ymax,a
	rep	#3
	lsr	a
	sub	y0,a
	add	x0,a
	move	a1,y:<prepass_occl_nrows

	; Word and one-hot bit of the row's first cell, then the seal-mask row
	; cursor R4 = prepass_scratch + 2*cy0 + word.  cy0 rides through the
	; bit split in Y0, which prepass_bit_address never touches, and N5
	; keeps the finished row base: the stamp reuses it for the pending
	; mask, one full mask further on.
	move	x1,a
	clr	b
	jsr	<prepass_bit_address
	move	x1,y:<prepass_occl_b0
	move	y0,a
	move	a1,x0
	add	x0,a
	move	r0,x0
	add	x0,a
	move	#>prepass_scratch,x0
	add	x0,a
	move	a1,r4
	move	r4,n5

	; Query: killed iff every range cell is sealed.  B counts rows down;
	; the ENDDO exit is the common one, taken at the first unsealed cell.
	; A2 after the shift holds the bit that left A1, so the word cursor
	; advances exactly when the one-hot mask wraps out of the word.
	move	y:<prepass_occl_nrows,b
	move	#>1,y0
prepass_query_row
	move	r4,r0
	move	y:<prepass_occl_b0,x1
	do	y:<prepass_occl_ncx,prepass_query_row_end
	; Diagnostic: one query cell visited.  A is rebuilt from scratch on
	; the very next instruction, so the bump costs no live register.
	move	x:>prepass_status+6,a
	add	y0,a
	move	a1,x:>prepass_status+6
	clr	a
	move	x:(r0),a1
	and	x1,a
	jeq	<prepass_query_visible
	move	x1,a
	asl	a
	move	a1,x1
	jclr	#0,a2,prepass_query_nowrap
	move	(r0)+
	move	y0,x1
prepass_query_nowrap
	nop
prepass_query_row_end
	move	(r4)+n4
	sub	y0,b
	jne	<prepass_query_row
	; Every range cell is sealed: set the survivor's kill bit.  The packed
	; order entry stores (triangle_index << 12) | bucket, and only the
	; unpacked global index may address the bitmap -- adding the bucket
	; back once shifted every kill onto a different source triangle.
	move	y:<prepass_occl_index,a
	jsr	<prepass_kill_address
	move	x:(r0),a
	or	x1,a
	move	a1,x:(r0)
	; Diagnostic: one triangle killed by the seal query.  Y0 still holds
	; the walk's 1 -- prepass_bit_address leaves it untouched by contract.
	move	x:>prepass_status+4,a
	add	y0,a
	move	a1,x:>prepass_status+4
	jmp	<prepass_occlusion_next

prepass_query_visible
	enddo
	; A visible qualified triangle is the only thing allowed to add
	; coverage to this bucket's pending mask.  A killed triangle cannot
	; occlude a later one because it contributed no visible pixels, and an
	; unqualified one may cover none of its cells.
	move	y:<prepass_occl_mode,a
	tst	a
	jeq	<prepass_occlusion_next
	jsr	<prepass_stamp

prepass_occlusion_next
	nop
prepass_occlusion_loop_end
prepass_occlusion_done
	rts

; Unpack the two index words R2 points at into triangle_i0/i1/i2.  Word C is
; never read at all -- the +N2 post-increment steps over it while word B is
; being fetched.  The classification loop enters with N2 = 2; the sweep's
; reload below enters with N2 holding its pixel anchor, which is just as
; harmless because R2 is dead after the second read.  Word A stays in X1 for
; the callers that read the occluder qualification bit.
prepass_unpack_indices
	move	y:(r2)+,x1
	move	y:(r2)+n2,y1
	move	#>TRI_VERTEX_MASK,x0
	tfr	x1,a
	and	x0,a
	; The TFRs' parallel slots store the previous field -- read-at-start.
	tfr	x1,a	a1,y:triangle_i0
	rep	#TRI_INDEX_BITS
	lsr	a
	; Bit 11 here is the occluder qualification, not part of v1.
	and	x0,a
	tfr	y1,a	a1,y:triangle_i1
	and	x0,a
	move	a1,y:triangle_i2
	rts

; Reload one resident triangle.  X0 is the triangle number on entry.  The
; flag in word A becomes the prepass mode (0/1).
;
; The base add and the R2 store are two instructions on purpose.  A parallel
; move reads its source at the START of the instruction (see the P-overlay
; comment), so the once-folded "add x0,a a1,r2" loaded R2 with 3*index and
; the reload walked the on-chip scalars instead of the resident list --
; unobservable while the stamp predicate was unsatisfiable, fatal once the
; sweep started culling for real.
prepass_load_triangle
	move	x0,a
	add	x0,a
	add	x0,a
	move	#triangle_indices,x0
	add	x0,a
	move	a1,r2
	nop
	jsr	<prepass_unpack_indices
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
; and one-hot bit, in constant time.  The old repeated-subtraction walk paid
; up to ~113 iterations for the highest triangle indices, per killed
; triangle; floor(n/24) is one fractional multiply instead: with
; c = $55556 = ceil(2^23/24), A1 = 2*n*c >> 24 = floor(n*c/2^23) equals
; floor(n/24) exactly for every n below 524,288 -- the combined error term
; (n mod 24)/24 + 2n/(3*2^23) stays under 1 there -- and the kill bitmap's
; bit numbers stop at 2,723.  The remainder uses the doubled-integer idiom
; the stamp documents: 2*(24q) sits entirely in A0 after one ASR, since
; 48q < 2^24 for every reachable q.
;
; prepass_bit_address is the base-parameterized entry: A = bit number,
; B = word base; out come R0 = base + bit/24 and X1 = one-hot(bit mod 24).
; The sweep calls it with B = 0 to split a cell column into its mask word
; and start bit.  Y0 is deliberately untouched -- that caller keeps its row
; coordinate there across the call -- while Y1 is clobbered now; neither
; caller holds a live value in Y1.
prepass_kill_address
	move	#>prepass_kill,b
prepass_bit_address
	move	a1,x0
	move	#>$55556,y1
	mpy	x0,y1,a
	move	a1,x1
	add	x1,b
	move	#>24,y1
	mpy	x1,y1,a	b1,r0
	asr	a
	move	a0,x1
	move	x0,a
	sub	x1,a
	; One-hot(bit mod 24) by REP: that many ASLs from 1.  Zero must skip
	; -- a zero REP count repeats 65,536 times -- and keeps the preload.
	move	#>1,x1
	move	a1,x0
	tst	a
	jeq	<prepass_kill_bit_done
	move	x1,a
	rep	x0
	asl	a
	move	a1,x1
prepass_kill_bit_done
	rts

; Stamp every range cell that lies fully inside the survivor into the pending
; mask.  Three edge functions decide full coverage: a cell is inside iff none
; of them is positive at any cell corner, and for a linear function that
; maximum sits at one fixed corner -- the one shifted +3 on each axis whose
; gradient is positive.  Anchoring each accumulator at its own maximising
; corner turns the four-corner test into a single sign test, and moving one
; cell right or one row down is one add per edge.
;
; The domain is the doubled integer one: the MPY/MAC anchor products are
; read from A0 after one ASR (A0 = 2E exactly, since |E| < 2^17), gradients
; are pre-doubled from the vertex deltas, and every later step is an exact
; 24-bit add.  The verdicts equal the four-corner point test the previous
; revision intended, for every cell.
;
; The vertex ring R3/M3 hands each DO iteration one directed edge (v0->v1,
; v1->v2, v2->v0 -- the same winding make_triangle_area's cross uses);
; tri_x0 sits at a multiple of eight so the six-cell modulo ring is legal.
; Clobbers A, B, X, Y, R0, R3-R7 and N0/N1; M3 is restored on exit.
prepass_stamp
	; This bucket now owns pending coverage the next boundary must merge.
	move	#>1,a
	move	a1,y:<prepass_occl_dirty

	; Diagnostic counters: one stamp call, and the ncx*nrows cells the walk
	; below will visit -- it has no early exit, so the product is the exact
	; visit count.  The small-integer MPY leaves 2*n*m entirely in B0 (B1
	; is only its sign), so one ASR and the B0 read recover the product,
	; the same A0/B0 idiom the stamp itself documents.  A still holds the
	; dirty flag's 1 and feeds the first bump; B, X0, Y0 and X1 are all
	; overwritten by the edge setup before it reads them.
	move	x:>prepass_status+2,b
	add	a,b
	move	b1,x:>prepass_status+2
	move	y:<prepass_occl_ncx,x0
	move	y:<prepass_occl_nrows,y0
	mpy	x0,y0,b
	asr	b
	move	b0,x1
	move	x:>prepass_status+7,b
	add	x1,b
	move	b1,x:>prepass_status+7

	; Per-edge setup: doubled gradients, per-cell and per-row steps, and
	; the anchored accumulator seeds.
	move	#5,m3
	move	#tri_x0,r3
	move	#prepass_occl_e01r,r5
	move	#prepass_occl_sx,r6
	move	#prepass_occl_sy,r7
	do	#3,prepass_stamp_edges
	; The edge's two vertices; the second is read with (r3)- so the next
	; iteration starts on it, and the ring turns the third iteration's
	; second vertex back into vertex 0.
	move	y:(r3)+,x0
	move	y:(r3)+,y1
	move	y:(r3)+,b
	sub	x0,b	y:(r3)-,a
	sub	y1,a
	; gy_d = 2*dx and gx_d = -2*dy, each parked in a short Y cell -- a
	; 24-bit home, NOT an N register: N registers are sixteen bits and
	; read back zero-extended, which silently turns every negative
	; gradient positive for both the anchor sign test and the MAC below.
	; The row step is OCCL_CELL_SIZE*gy_d, the cell step the same times
	; gx_d.
	asl	b
	move	b1,y:<prepass_occl_gy
	asl	b
	asl	b
	asl	b
	move	b1,y:(r7)+
	asl	a
	neg	a
	move	a1,y:<prepass_occl_gx
	asl	a
	asl	a
	asl	a
	move	a1,y:(r6)+
	; Anchor point: the range's top-left pixel, +(cell-1) on each axis
	; whose gradient is positive there; N0 has held that constant since
	; the sweep entry.
	move	n2,b
	move	y:<prepass_occl_gx,a
	tst	a
	jle	<prepass_stamp_anchor_x
	move	n0,x1
	add	x1,b
prepass_stamp_anchor_x
	sub	x0,b
	move	b1,y0
	move	n3,b
	move	y:<prepass_occl_gy,a
	tst	a
	jle	<prepass_stamp_anchor_y
	move	n0,x1
	add	x1,b
prepass_stamp_anchor_y
	sub	y1,b
	move	b1,y1
	; E_d = (gx_d*(px-xa) + gy_d*(py-ya)) with the MPY doubling undone by
	; one ASR; the A0 read is the whole point (see the stage comment).
	move	y:<prepass_occl_gx,x1
	mpy	x1,y0,a
	move	y:<prepass_occl_gy,x1
	move	y1,y0
	mac	x1,y0,a
	asr	a
	move	a0,x1
	move	x1,a
	move	a1,y:(r5)+
prepass_stamp_edges

	; Pending-mask row cursor: the seal cursor's saved base plus one mask.
	move	n5,a
	move	#>OCCL_MASK_WORDS,x0
	add	x0,a
	move	a1,r4
	move	#>1,y0
prepass_stamp_row
	; Load this row's accumulators and advance the row-restart seeds; the
	; seed triple is consecutive on purpose so R0 can walk it here before
	; the cell loop claims it as the mask cursor.
	move	#prepass_occl_cur,r5
	move	#prepass_occl_sy,r7
	move	#prepass_occl_e01r,r0
	do	#3,prepass_stamp_row_seeds
	move	y:(r0),a
	move	a1,y:(r5)+
	move	y:(r7)+,x0
	add	x0,a
	move	a1,y:(r0)+
prepass_stamp_row_seeds
	move	r4,r0
	move	y:<prepass_occl_b0,x1
	do	y:<prepass_occl_ncx,prepass_stamp_row_end
	; One pass per cell: B collects the maximum pre-step edge value for
	; the inside test while each accumulator steps to the next cell.
	move	#prepass_occl_cur,r5
	move	#prepass_occl_sx,r6
	move	y:(r5),b
	move	y:(r6)+,x0
	tfr	b,a
	add	x0,a
	move	a1,y:(r5)+
	move	y:(r5),a
	move	y:(r6)+,x0
	cmp	a,b
	tlt	a,b
	add	x0,a
	move	a1,y:(r5)+
	move	y:(r5),a
	move	y:(r6),x0
	cmp	a,b
	tlt	a,b
	add	x0,a
	move	a1,y:(r5)
	tst	b
	jgt	<prepass_stamp_skip
	move	x:(r0),b
	or	x1,b
	move	b1,x:(r0)
	; Diagnostic: one cell actually stamped.  Y0 has held 1 since the row
	; setup; B is reloaded at the skip label either way.
	move	x:>prepass_status+3,b
	add	y0,b
	move	b1,x:>prepass_status+3
prepass_stamp_skip
	; Same wrap rule as the query walk.
	move	x1,b
	asl	b
	move	b1,x1
	jclr	#0,b2,prepass_stamp_nowrap
	move	(r0)+
	move	y0,x1
prepass_stamp_nowrap
	nop
prepass_stamp_row_end
	move	(r4)+n4
	move	y:<prepass_occl_nrows,b
	sub	y0,b
	move	b1,y:<prepass_occl_nrows
	jne	<prepass_stamp_row
	move	#>$ffff,m3
	rts

; seal |= pending, one word per mask cell, and the pending mask clears at the
; same bucket boundary -- but only when the closing bucket stamped anything.
; Most buckets hold no qualified visible occluder, and for them the whole
; 336-word external-memory pass would merge nothing.
prepass_merge_masks
	move	y:<prepass_occl_dirty,a
	tst	a
	jeq	<prepass_merge_clean
	clr	a
	move	a1,y:<prepass_occl_dirty
	; Diagnostic: one dirty merge.  X0 and B are dead here -- the loop
	; below overwrites X0 and never reads B; the sweep's caller rewrites
	; both before their next read.
	move	x:>prepass_status+5,b
	move	#>1,x0
	add	x0,b
	move	b1,x:>prepass_status+5
	move	#prepass_scratch,r0
	move	#prepass_scratch+OCCL_MASK_WORDS,r2
	move	#>OCCL_MASK_WORDS,x0
	do	x0,prepass_merge_done
	move	x:(r0),a
	move	x:(r2),x0
	or	x0,a
	move	a1,x:(r0)+
	clr	a
	move	a1,x:(r2)+
prepass_merge_done
prepass_merge_clean
	rts

	IF	SSIPROBE
; -----------------------------------------------------------------------------
; SSI transport probe -- CMD_SSI_STREAM
;
; The DSP side of the Falcon "DSP-XMIT -> Crossbar -> DMA-RECORD" route.  This
; is a transport bring-up command, not a renderer path: it runs standalone
; between frames, borrows the BUILD chunk's dead X scratch, and touches no
; state the geometry pipeline owns.
;
; Host words, in order:
;   payload_count          number of generated 16-bit ramp words, 1..65535
;   seed                   first ramp value, 16 bits
;   SSI_ENVELOPE_WORDS     the frame header then the frame footer, verbatim
;
; The DSP transmits header, payload_count ramp words (seed, seed+1, ...,
; modulo 16 bits) and footer, then replies ACK_SSI_STREAM and a status word:
; 0 = every word was clocked out, 1 = the transmitter stalled and the burst
; was abandoned to the host's timeout.
;
; The envelope is host-authored on purpose.  The whole frame is then exactly
; predictable on the host BEFORE the transfer, so verification is a compare
; against an independently built expectation rather than a re-derivation from
; whatever arrived.  The ramp is generated here so the bulk payload is not
; bounded by host-port bandwidth, and a ramp localises a transport fault --
; a dropped or duplicated word shows up as a discontinuity at a known index,
; which a pseudo-random payload plus a checksum would only report as "wrong".
;
; Alignment: the SSI transmits the TOP bits of the 24-bit word, so a 16-bit
; word length sends bits 23..8.  Every value is therefore shifted left eight
; on the way in, and the ramp is advanced in that same shifted domain -- the
; step is $000100 and the mask $FFFF00 reproduces the 16-bit wrap exactly.
;
; Handshake framing: with DMA-RECORD as the master, SC2 is not driven by the
; SSI at all.  PC5 is switched to GPIO output and raised by hand, which is
; what tells the Crossbar a word is ready.  CRB is written before PCD because
; enabling TE re-arms the transmitter's frame wait, and raising PC5 is what
; clears it.
command_ssi_stream
	jsr	<receive_word
	move	x0,y:ssi_payload_count
	jsr	<receive_word
	move	x0,a
	rep	#8
	asl	a
	move	a1,y:ssi_ramp

	move	#ssi_envelope,r0
	do	#SSI_ENVELOPE_WORDS,ssi_envelope_end
	jsr	<receive_word
	move	x0,a
	rep	#8
	asl	a
	move	a1,x:(r0)+
ssi_envelope_end

	move	#>SSI_TDE_SPIN,x0
	move	x0,y:ssi_spin
	clr	a
	move	a1,y:ssi_status

	movep	#0,x:m_crb			; transmitter off while it is set up
	movep	#$4000,x:m_cra			; 16-bit words, no frame divider
	movep	#$0140,x:m_pcc			; PC6/SCK and PC8/STD to the SSI
	movep	#$0020,x:m_pcddr		; PC5 GPIO, driven as the frame line
	; CRB copies the known-good Falcon DSP-to-Crossbar audio configuration
	; minus its interrupt enables.  Which of MOD/SYN a handshaked transmit
	; strictly needs is a PHYSICAL-hardware question this build cannot
	; settle: with SC2 driven by hand the frame wait is cleared through
	; PCD, so both settings behave identically in emulation.
	movep	#$1a00,x:m_crb			; TE, network mode, sync, clock in
	movep	#$0020,x:m_pcd			; raise the frame line

	move	#ssi_envelope,r0
	do	#SSI_HEADER_WORDS,ssi_header_end
	move	x:(r0)+,x0
	jsr	<ssi_send_word
	nop
ssi_header_end

	move	y:ssi_payload_count,a
	tst	a
	jeq	<ssi_payload_end
	; DO takes only the short absolute form for a memory count, and these
	; probe scalars sit above Y:$3F.  The count goes through X0, which the
	; loop body then reuses freely: DO latches LC at loop setup.
	move	a1,x0
	move	y:ssi_ramp,a
	move	#>$000100,x1
	move	#>$ffff00,y1
	do	x0,ssi_payload_end
	move	a1,x0
	jsr	<ssi_send_word
	add	x1,a
	and	y1,a
ssi_payload_end

	move	#ssi_envelope+SSI_HEADER_WORDS,r0
	do	#SSI_FOOTER_WORDS,ssi_footer_end
	move	x:(r0)+,x0
	jsr	<ssi_send_word
	nop
ssi_footer_end

	; The last footer word is still sitting in TX until the Crossbar clocks
	; it out.  Disabling TE before that replaces it with a zero on the wire
	; and the frame arrives one real word short, so wait for the final TDE
	; before tearing the route down.
	jsr	<ssi_wait_tde

	movep	#0,x:m_pcd
	movep	#0,x:m_crb
	movep	#0,x:m_pcddr
	movep	#0,x:m_pcc

	move	#ACK_SSI_STREAM,x0
	jsr	<send_word
	move	y:ssi_status,x0
	jsr	<send_word
	jmp	<main_loop

; x0 = one word already aligned into bits 23..8.
ssi_send_word
	jsr	<ssi_wait_tde
	movep	x0,x:m_tx
	rts

; Bounded wait for the transmitter to empty.  A route that is not armed never
; sets TDE, and an unbounded wait there costs the whole run: the DSP would sit
; here forever while the host waits on a reply that cannot come.  On the first
; timeout the status latches and the spin limit collapses to a single test, so
; abandoning the rest of a dead burst costs one status read per word instead
; of a full spin each.
ssi_wait_tde
	move	y:ssi_spin,b
	move	#>1,y0
ssi_wait_tde_loop
	jset	#m_tde,x:m_sr,ssi_wait_tde_done
	sub	y0,b
	jne	<ssi_wait_tde_loop
	move	y0,y:ssi_status
	move	y0,y:ssi_spin
ssi_wait_tde_done
	rts

	ENDIF

; -----------------------------------------------------------------------------
; CMD_PIO_BURST -- host-port per-word calibration (OPTIMIZATION.md 8.2a).
;
; The 2.3 us/word wire figure was derived pre-2.4b by removing words from the
; shipping stream, so it prices DSP production and transport together.  This
; command isolates transport: it absorbs M host words and then streams back N
; ramp words, and both loops do so little work per word (four instructions on
; the send side) that the port handshake with both parties ready is the only
; term left.  The host brackets repeated bursts with the 200 Hz clock and
; solves the two burst sizes for per-word cost against per-command overhead.
;
; Arguments, in order: M = words the host will push (absorbed and discarded),
; N = words streamed back.  BOTH MUST BE AT LEAST 1: a hardware DO with a
; zero count runs 65,536 times.  The reply is N ramp words counting from 0
; (low 16 bits are the index, so the host verifies integrity outside its
; timing bracket), then ACK_PIO_BURST.
; -----------------------------------------------------------------------------
command_pio_burst
	jsr	<receive_word
	move	x0,y1			; M, host -> DSP
	jsr	<receive_word
	move	x0,y0			; N, DSP -> host

	do	y1,pio_burst_absorb
	jsr	<receive_word
	nop
pio_burst_absorb

	clr	b
	move	#>1,x1
	do	y0,pio_burst_send
	jclr	#1,x:m_hsr,*
	movep	b1,x:m_htx
	add	x1,b
pio_burst_send

	move	#ACK_PIO_BURST,x0
	jsr	<send_word
	jmp	<main_loop

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

; The SSI transport probe's frame envelope, overlaid on the BUILD chunk's UV
; pairs.  CMD_SSI_STREAM is a standalone bring-up command that never runs
; between a BUILD chunk's UV upload and its span pass, so this costs no
; memory.  prepass_order overlays the same words for the same reason.
ssi_envelope		=	chunk_uvs

; One chunk of survivor records, SPAN_RECORD_WORDS each.  Culled triangles
; occupy nothing.  The record allocation ends at X:$3C5E; phase-local light
; and normal-result caches continue above it without touching prepass_scratch.
triangle_out
	ds	MAX_CHUNK*SPAN_RECORD_WORDS

; This phase-local cache starts immediately above the maximum BUILD output.
; The prepass order list covers it while FINISH is culling, but its tail is
; dead by the time BUILD_TRIANGLES calls make_triangle_shade.  Eighteen words
; are enough for the six RGB/green light vectors; prepass_scratch begins well
; above it, so the kill bitmap and its cursor remain untouched.
phase_light_directions_x	=	triangle_out+MAX_CHUNK*SPAN_RECORD_WORDS

; Frame-local normal-light cache.  The three 128-word arrays occupy only the
; BUILD-dead tail of prepass_order and end below prepass_scratch, so they do
; not reduce PREPASS_MAX or overlap the masks/kill bitmap that survive BUILD.
shade_cache_tags	=	phase_light_directions_x+18
shade_cache_r		=	shade_cache_tags+SHADE_CACHE_ENTRIES
shade_cache_g		=	shade_cache_r+SHADE_CACHE_ENTRIES
shade_cache_end		=	shade_cache_g+SHADE_CACHE_ENTRIES

; -----------------------------------------------------------------------------
; Occlusion prepass working set
;
; Everything from chunk_uvs to the top of physical X memory, 1,569 words.
; Deliberately NOT taken from triangle_indices' allocation and not from
; Y:$0100-$01FF (whose mapping the sources contradict each other about).
;
; prepass_order is PHASE-LOCAL: it overlays chunk_uvs and triangle_out,
; which are dead until the first BUILD chunk of the frame arrives.  The sorted
; list is consumed completely by the occlusion sweep before the first BUILD,
; so it does not need to survive chunk traffic.  prepass_scratch holds the
; two coverage masks (seal, then pending).  prepass_kill and prepass_status
; also live here and survive the BUILD chunks.  The four allocations fill the
; window to the top of physical X memory exactly; PREPASS_MAX is sized from
; that identity, so growing any of the others must shrink it.
; -----------------------------------------------------------------------------
	org	x:chunk_uvs

prepass_order
	ds	PREPASS_MAX
prepass_scratch
	ds	OCCL_MASK_WORDS*2
prepass_kill
	ds	PREPASS_KILL_WORDS
; +0/+1 are BUILD's streaming kill cursor (word pointer, one-hot bit).
; +2..+7 are the per-run diagnostic counters, zeroed by prepass_run and read
; out by PREPASS mode 4: stamp calls, stamped cells, query kills, dirty
; merges, query cells visited, stamp cells visited.
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
triangle_index
	ds	1
triangle_base
	ds	1
triangle_shade
	ds	1
triangle_out_count
	ds	1
shade_cx
	ds	1
shade_cy
	ds	1
shade_cz
	ds	1
; Eight pad words so tri_x0 sits at a multiple of eight: prepass_stamp walks
; the six projected-corner scalars below through R3 under a modulo-6 M3, and
; the DSP's modulo addressing requires the block's base aligned to the next
; power of two.  Seven of the eight are retired cells -- the shade_nx..nz
; and animation_vertex_x..z staging triples and the tri_near_flags
; accumulator -- whose values are register-resident now.
	ds	8
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
; The twelve cells from span_sl_long to span_dll_low sit in EXACT wire
; order -- w5..w13, then w15..w17 -- because the record write streams them
; through one pointer.  Moving any of them shears every later record field
; against the host's unpack; the UV staging and the sorted corner levels
; follow OUTSIDE the streamed window.
span_sl_long
	ds	1
span_sl_up
	ds	1
span_sl_low
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
span_dldx
	ds	1
span_dll_up
	ds	1
span_dll_low
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
; Gouraud level fields: the three sorted-slot corner levels, in level
; units Q4.8 wherever a fraction applies; their gradients live in the
; streamed window above.
span_sl0
	ds	1
span_sl1
	ds	1
span_sl2
	ds	1
span_flip
	ds	1

; The prepass runs after projection and before BUILD_TRIANGLES, so the
; animation/projection temporaries are dead for its whole lifetime.  Aliasing
; its hot cells onto the on-chip Y:$002A-$003E window keeps every reference
; in the one-word short form; no value crosses the command boundary and the
; normal shipping path never observes these aliases.  The three triples MUST
; stay three consecutive words each: the stamp walks the edge accumulators
; and both step sets through R5/R6/R7 as three-word blocks.
prepass_occl_e01r	= shade_sum_r		; row-restart edge accumulators
prepass_occl_e12r	= shade_sum_g
prepass_occl_e20r	= shade_depth_scale
prepass_occl_ncx	= shade_acc_r		; cells per bbox row
prepass_occl_nrows	= shade_acc_g		; bbox rows (stamp counts it down)
prepass_occl_b0	= corner_levels		; one-hot bit of a row's first cell
prepass_occl_mode	= corner_levels+1	; occluder qualification flag
prepass_occl_dirty	= shade_level		; bucket stamped pending coverage
prepass_occl_index	= shade_ratio_r		; entry's global triangle index
prepass_occl_flow	= shade_ratio_g		; previous entry's bucket
prepass_occl_gx	= corner_levels+2	; one edge's doubled gradients: 24-bit
prepass_occl_gy	= project_temp_x	; homes, deliberately not N registers
prepass_occl_sy	= triangle_tint		; per-row edge steps, 3 words
prepass_occl_cur	= projection_cx		; working edge accumulators, 3 words
prepass_occl_sx	= project_temp_y	; per-cell edge steps, 3 words
; Classify-phase alias, lifetime-disjoint from every sweep-phase alias above
; AND from the same cell's own e01r role: the one-hot of the pass-2 survivor
; cache's streaming cursor.  The stamp's first e01r write happens only after
; prepass_clear_kill has retired the cache.
prepass_cls_bit	= shade_sum_r

; Occlusion prepass state.  The class counter bank MUST stay here in on-chip
; Y RAM: it is written once per survivor in each classification pass and
; walked by the prefix, while X and Y above $01FF are external SRAM with
; wait states.  It precedes the command-persistent state below so the bank
; does not overlap it.
prepass_cnt_lo
	ds	PREPASS_CNT_COUNT

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
; Cross-frame window capacity probe.  Units of the fixed-cost burn loop that
; command_finish_animated_frame runs at the end of the window; 0 disables it
; and is what every shipping build ships.  It sits in one of the four retired
; pad words above, and it is a `dc` rather than a `ds` so the whole sweep is
; driven by patching ONE word of the .lod -- the DSP program and the host
; binary then stay byte-identical across every point of the sweep, which is a
; stronger equal-layout guarantee than the one-byte host patches of 2.3f and
; 2.4e.
	IF	WINPROBE
probe_units
	dc	0
	ENDIF

; SSI transport probe state.  These live above Y:$3F so their references use
; the long absolute form; the probe is a one-shot bring-up command and none of
; them is read on a rendering path.  They are assembled only into the SSI
; bring-up builds; the shipping and measurement .lod reclaims the four words.
	IF	SSIPROBE
ssi_payload_count
	ds	1
ssi_ramp
	ds	1
ssi_spin
	ds	1
ssi_status
	ds	1
	ENDIF
	ds	3

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
; triangle index.  Check the P extent in the assembled DSP program
; after adding code (strtonum, not "0x" concatenation: plain awk reads a
; concatenated hex string as 0 and the old one-liner therefore printed only
; the word count):
;
;   tr -d '\r' < TREX/dsp/trex_dsp.lod | awk '/^_DATA P/{s=strtonum("0x" $3); \
;     n=0;i=1;next} /^_/{if(i&&n)printf "last P = $%04X\n",s+n-1;i=0;next} \
;     {if(i)n+=NF}'
;
; The instrumented diagnostic builds are bound by the same ceiling: a
; temporary counter that pushes the extent past its active overlay gets
; overwritten by the next upload and reports garbage, which cost this stage
; one full round of contradictory measurements once.
;
; The default build (SSIPROBE=0, WINPROBE=1, OBJLIGHTS=0) ends at P:$09AE,
; leaving P:$09AF-$09BF free before the resident index list -- 17 words.  That
; is the configuration that ships and that every timing run uses.
;
; Three things here are conditional, because they do not all fit.  The SSI
; transport probe (CMD_SSI_STREAM, SSIPROBE) costs 103 words; the cross-frame
; window burn loop (WINPROBE) costs 44; the host-port calibration burst
; (CMD_PIO_BURST) costs 25 and is unconditional for now.  KNOWN STATE: the SSI
; bring-up configuration (SSIPROBE=1, WINPROBE=0) is OVER the ceiling.  It is a
; non-shipping bring-up variant whose .lod is not committed, so nothing that
; ships is affected, but it must be brought back under $09BF before it can be
; trusted -- past that address the program silently overwrites the first
; triangle index.  The OBJLIGHTS=1 variant never ships from this file (the
; Makefile's trex_dsp_objlights target rewrites the equate).
; Keep the "<" prefix on jumps and the short
; Y-scalar forms on any code added later, or the program will overwrite the
; index list without an assembler error.
; Absolute-short addressing is the largest single contributor: every data
; reference to a Y scalar below $40 carries the "<" prefix, which is the
; one-word form.  ASM56000 sizes an absolute data address long by default,
; exactly as it does a jump, so the prefix is mandatory and its absence is
; silent -- keep it on new references to those cells, and note the range is
; addresses 0..63 only.
;
; Five later movements: the eleven-bit vertex masking the occluder
; qualification bit needs cost four words, retiring command_get_vertices for
; the occlusion stage returned eighteen, folding twenty-seven standalone
; memory loads into the ALU operation in front of them returned twenty-seven
; more, forcing absolute-short data addressing returned 103 (OPTIMIZATION.md
; 2.3d), and keeping the corner normal register-resident through the shading
; rotation returned 41 more (2.3h site 1).  The frame-local normal-light cache
; then spends 29 program words to bypass repeated rotations and dot products
; (2.4d).  A parallel move reads its source at the start of the instruction,
; so only loads whose source the ALU op does not write may be folded, and a
; rep/do target must stay one word.
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
