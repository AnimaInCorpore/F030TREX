; -----------------------------------------------------------------------------
; Falcon SSI -> DMA-RECORD transport
;
; This file holds the sound-channel owner, the frame builders and the record
; transport.  It is linked into the optional SSI diagnostics; of those only
; TREX_SSI_DMA actually claims the channel and starts the record engine, and
; the shipping renderer contains no call into the owner at all.
;
; The setup order follows the working F030MXDRV sound path, with an explicit
; TREX safety gate for inherited activity:
;   Locksnd -> reject a RUNNING channel -> stop owned DMA -> pin matrix
;   -> buffer -> DSP route -> raw Crossbar read-back
; and every failure exits through the reverse order.
;
; State of the two hardware gates, as of the 2026-08-20 emulator run:
;
;   raw Crossbar read-back  IMPLEMENTED and passing.  The route fields are
;       written masked and then re-read; a mismatch refuses the claim.  The
;       field POSITIONS were wrong until this revision -- see the correction
;       at SSI_XBAR_SOURCE_MASK below and OPTIMIZATION.md 7.4.
;   cache coherency         IMPLEMENTED as a bulk data-cache invalidate
;       (ssi_dma_invalidate_dcache) between the completion gate and the
;       first host read.  UNVERIFIED on hardware: Hatari does not model the
;       68030 caches against DMA, so an emulator pass cannot distinguish a
;       correct contract from a missing one.
;
; Everything here is validated in emulation only.  No throughput figure this
; file can produce is a physical-Falcon result.
; -----------------------------------------------------------------------------

        include "src/xbios.s"

        global  ssi_dma_claim
        global  ssi_dma_begin
        global  ssi_dma_stop
        global  ssi_dma_release
        global  ssi_dma_get_record_ptr
        global  ssi_dma_pack_compact_record
        global  ssi_dma_shadow_begin
        global  ssi_dma_probe_begin
        global  ssi_dma_probe_append_ramp
        global  ssi_dma_shadow_capacity
        global  ssi_dma_row_shadow_begin
        global  ssi_dma_row_shadow_packet_begin
        global  ssi_dma_row_shadow_set_shade
        global  ssi_dma_row_shadow_skip_rows
        global  ssi_dma_row_shadow_append_row
        global  ssi_dma_shadow_append_record
        global  ssi_dma_shadow_finish
        global  ssi_dma_shadow_abort
        global  ssi_dma_shadow_active
        global  ssi_dma_shadow_words
        global  ssi_dma_hatari_consume_frame
        global  ssi_dma_hatari_result
        global  ssi_dma_hatari_words
        global  ssi_dma_hatari_consumed_words
        global  ssi_dma_hatari_packets
        global  ssi_dma_hatari_rows
        global  ssi_dma_hatari_skips
        global  ssi_dma_hatari_shades
        global  ssi_dma_hatari_crc
        global  ssi_dma_hatari_expected_crc
        global  ssi_dma_hatari_error_stage
        global  ssi_dma_hatari_feed_packet
        global  ssi_dma_hatari_feed_callback
        global  ssi_dma_hatari_feed_x
        global  ssi_dma_hatari_feed_count
        global  ssi_dma_hatari_feed_u
        global  ssi_dma_hatari_feed_v
        global  ssi_dma_hatari_feed_y
        global  ssi_dma_hatari_feed_shade
        global  ssi_dma_validate_route
        global  ssi_dma_arm_record
        global  ssi_dma_wait_record
        global  ssi_dma_invalidate_dcache
        global  ssi_dma_completed_bytes
        global  ssi_dma_wait_ticks
        global  ssi_dma_run_control
        global  ssi_dma_devconnect_source
        global  ssi_dma_devconnect_destination
        global  ssi_dma_armed_control
        global  ssi_dma_armed_int_control
        global  ssi_dma_armed_mode
        global  ssi_dma_armed_xbar_source
        global  ssi_dma_armed_xbar_destination
        global  ssi_dma_armed_divider
        global  ssi_dma_old_control
        global  ssi_dma_old_int_control
        global  ssi_dma_cacr_image
        global  ssi_dma_xbios_results
        global  ssi_dma_route_status
        global  ssi_dma_claim_stage
        global  ssi_dma_route_source
        global  ssi_dma_route_destination
        global  ssi_dma_owned

; XBIOS sound arguments used by the transport probe.  These values follow the
; Falcon XBIOS encoding; the raw Crossbar read-back remains a required
; physical-Falcon check and is not replaced by the XBIOS return value.
SSI_DMA_RECORD_REGION   equ     1
SSI_DMA_STOP             equ     0
SSI_DMA_RECORD_START     equ     4
SSI_DMA_STEREO16         equ     1
SSI_DMA_DSP_XMIT         equ     1
SSI_DMA_RECORD           equ     1
SSI_DMA_CLOCK_32M        equ     2
; Devconnect prescale.  0 selects the STE-compatible divider, which puts the
; Crossbar back on the STE sample clock; 1 is the fastest Falcon internal
; divider ($FF8935 = 1).  The record channel is clocked by that divider even
; in handshake mode, so the probe asks for 1 and reads $FF8935 back.
SSI_DMA_PRESCALE_FAST    equ     1
SSI_DMA_HANDSHAKE        equ     0
SSI_DMA_MATRIX_IN        equ     2
SSI_DMA_ADDER_IN         equ     4
SSI_DMA_MONITOR_PAIR0    equ     0
SSI_DMA_STATUS_RESET     equ     1
SSI_DMA_ROUTE_NOT_RUN    equ     -2
SSI_DMA_COMPACT_RECORD_MAGIC equ $d012
SSI_DMA_COMPACT_RECORD_WORDS equ 39
SSI_DMA_FRAME_MAGIC      equ     $5353
SSI_DMA_FRAME_FLAGS      equ     $8001
SSI_DMA_ROW_FRAME_FLAGS  equ     $0001
; Transport probe frames carry their own flags word so a capture of the SSI
; bring-up burst can never be decoded as a span or compact-record stream.
SSI_DMA_PROBE_FRAME_FLAGS equ    $4001
SSI_DMA_PACKET_MAGIC     equ     $e000
SSI_DMA_SHADE_MAGIC      equ     $f100
SSI_DMA_ROW_SKIP_MAGIC   equ     $f200
SSI_DMA_FRAME_FOOTER     equ     $5aa5
SSI_DMA_FRAME_HEADER_WORDS equ   8
SSI_DMA_FRAME_FOOTER_WORDS equ   6
SSI_DMA_HATARI_PACKET_CAPACITY equ 2724

; Falcon DMA/crossbar registers.  Sound DMA address registers are selected by
; bit 7 of the control register: playback when clear, record when set.  The
; Falcon sound DMA exposes three address bytes per pointer (24-bit address);
; the last byte of each address is even-aligned by the hardware.
SSI_DMA_INT_CONTROL      equ     $ffff8900
SSI_DMA_CONTROL          equ     $ffff8901
SSI_DMA_BASE_HI          equ     $ffff8903
SSI_DMA_BASE_MID         equ     $ffff8905
SSI_DMA_BASE_LO          equ     $ffff8907
SSI_DMA_COUNT_HI         equ     $ffff8909
SSI_DMA_COUNT_MID        equ     $ffff890b
SSI_DMA_COUNT_LO         equ     $ffff890d
SSI_DMA_END_HI           equ     $ffff890f
SSI_DMA_END_MID          equ     $ffff8911
SSI_DMA_END_LO           equ     $ffff8913
SSI_DMA_MODE             equ     $ffff8920

SSI_XBAR_SOURCE          equ     $ffff8930
SSI_XBAR_DESTINATION     equ     $ffff8932
SSI_XBAR_EXT_DIVIDER     equ     $ffff8934
SSI_XBAR_INT_DIVIDER     equ     $ffff8935
SSI_XBAR_RECORD_TRACKS   equ     $ffff8936
SSI_XBAR_CODEC_INPUT     equ     $ffff8937
SSI_XBAR_ADC_INPUT       equ     $ffff8938
SSI_XBAR_INPUT_GAIN      equ     $ffff8939
SSI_XBAR_OUTPUT_ATTEN    equ     $ffff893a

; $FF8901 bit assignments: bit 0 playback enable, bit 1 playback repeat,
; bit 4 record enable, bit 5 record repeat, bit 7 address-register select.
; Only the two ENABLE bits say a channel is actually moving; the repeat bits
; describe what a stopped channel would do next.  The old $000F mask both
; covered two undefined bits and missed record enable entirely, so it could
; not have rejected the one case it exists for -- an inherited RECORDING
; client -- while rejecting a repeat flag left behind by a stopped one.
SSI_DMA_ACTIVE_MASK      equ     $0011
SSI_DMA_RECORD_ENABLE    equ     $0010
SSI_DMA_RECORD_SELECT    equ     $0080

; Crossbar route fields, from the Falcon030 Hardware Reference Guide's
; $FF8930/$FF8932 bit maps.  Each register holds four four-bit fields, and
; the two this route needs are the LOW ones:
;
;   $FF8930 bits 7..4  = DSP-XMIT source: bit 7 connect (1 = to the matrix,
;                        0 = tristated for external SSI), bits 6..5 clock
;                        (10 = 32 MHz), bit 4 handshake (0 = on).
;                        Wanted field value $C -> ($FF8930 & $FF0F) | $00C0.
;   $FF8932 bits 3..0  = DMA-RECORD destination: bit 3 handshaking-on with
;                        source DSP-XMIT (0), bits 2..1 source (01 = DSP
;                        output), bit 0 handshake (0 = on).
;                        Wanted field value $2 -> ($FF8932 & $FFF0) | $0002.
;
; Bits 15..12 of $FF8930 are the A/D converter's field and bits 11..8 of
; $FF8932 are external output's; validating those instead, as this file did,
; can only ever fail on a correctly routed machine.
SSI_XBAR_SOURCE_MASK     equ     $00f0
SSI_XBAR_SOURCE_DSP_XMIT equ     $00c0
SSI_XBAR_DEST_MASK       equ     $000f
SSI_XBAR_DEST_DSP_TO_DMA equ     $0002

; 68030 CACR bit 11 clears every data-cache entry.  The cache is write-through,
; so an invalidate is the whole coherency contract for a DMA-written buffer.
SSI_DMA_CACR_CLEAR_DATA  equ     $00000800

; Default record-completion timeout in 200 Hz ticks.  Two seconds is far more
; than any window this transport declares needs at the Falcon's specified
; ceiling, and short enough that a stalled route reports instead of hanging.
SSI_DMA_DEFAULT_TIMEOUT  equ     400

; One recorded return value per claim stage, 1..13.
;
; XBIOS sound calls do not share one success convention: Locksnd answers 1,
; several answer 0, and others answer a previous setting that is a perfectly
; valid positive number.  Treating "not zero" as failure rejected a healthy
; machine at Soundcmd, so the gate is now the XBIOS-wide one -- negative is an
; error -- and every raw return is published instead of thrown away, which is
; what makes the next surprise a one-run diagnosis rather than a bisect.
SSI_DMA_CLAIM_STAGES     equ     13

        text

; Mirror one packed DSP survivor record into the compact SSI wire shape.
;
; in:   a0 = 18 host longwords containing the DSP's low 24-bit words
;       a1 = word-aligned destination for the SSI stream record
;       d0 = global source-triangle index
; out:  d0 = SSI_DMA_COMPACT_RECORD_WORDS (39) on success
;
; Wire order is marker, source index high/low, then each native DSP word as
; two 16-bit values: zero-extended high byte followed by low 16 bits.  This
; helper is intentionally independent of the live renderer; the caller can
; feed it a copy of dsp_triangle_chunk_rx before the normal unpack path.
ssi_dma_pack_compact_record:
        movem.l d1-d3,-(sp)
        move.w  #SSI_DMA_COMPACT_RECORD_MAGIC,(a1)+
        move.l  d0,d1
        swap    d1
        move.w  d1,(a1)+
        move.w  d0,(a1)+
        moveq   #17,d3
.pack_compact_word:
        move.l  (a0)+,d1
        andi.l  #$00ffffff,d1
        move.l  d1,d2
        swap    d2
        move.w  d2,(a1)+
        move.w  d1,(a1)+
        dbra    d3,.pack_compact_word
        moveq   #SSI_DMA_COMPACT_RECORD_WORDS,d0
        movem.l (sp)+,d1-d3
        rts

; Start a host-shadow compact frame in a word-aligned buffer.
;
; in:   a0 = destination buffer
;       d0 = capacity in 16-bit words (14..65535)
;       d1 = 32-bit frame id
;       d2 = mesh id (low 16 bits)
;       d3 = buffer generation (low 16 bits)
; out:  d0 = 0 on success, -1 if already active or capacity is invalid
;
; The builder reserves the six-word footer on every append.  It is therefore
; impossible for a later footer write to overrun the declared DMA window.
ssi_dma_shadow_begin:
        move.w  #SSI_DMA_FRAME_FLAGS,d5
        bra     ssi_dma_shadow_begin_mode

; Start a transport-probe frame.  Same envelope, capacity rule, footer and
; CRC as the other two builders; only the flags word differs, so a decoder
; can never mistake a probe capture for a span or compact stream.
ssi_dma_probe_begin:
        move.w  #SSI_DMA_PROBE_FRAME_FLAGS,d5
        bra     ssi_dma_shadow_begin_mode

; Start a full-row shadow frame.  It shares the same capacity, footer and
; CRC state as the compact builder, but leaves COMPACT_RECORD_FLAG clear so
; the normal packet/row decoder can consume it.
ssi_dma_row_shadow_begin:
        move.w  #SSI_DMA_ROW_FRAME_FLAGS,d5

ssi_dma_shadow_begin_mode:
        movem.l d1-d7/a0-a6,-(sp)
        tst.l   ssi_dma_shadow_active
        bne     .shadow_begin_failed
        move.l  d0,d4
        cmpi.l  #SSI_DMA_FRAME_HEADER_WORDS+SSI_DMA_FRAME_FOOTER_WORDS,d4
        bcs     .shadow_begin_failed
        cmpi.l  #$ffff,d4
        bhi     .shadow_begin_failed
        move.l  a0,ssi_dma_shadow_start
        move.l  a0,ssi_dma_shadow_ptr
        move.l  d4,ssi_dma_shadow_capacity
        move.l  d1,ssi_dma_shadow_frame_id
        move.w  d2,ssi_dma_shadow_mesh_id
        move.w  d3,ssi_dma_shadow_generation
        clr.l   ssi_dma_shadow_words
        clr.l   ssi_dma_shadow_records
        clr.l   ssi_dma_shadow_actual_words
        move.w  #$ffff,ssi_dma_shadow_crc
        move.l  #1,ssi_dma_shadow_active

        move.w  #SSI_DMA_FRAME_MAGIC,d0
        bsr     ssi_dma_shadow_emit_word
        move.w  d5,d0
        bsr     ssi_dma_shadow_emit_word
        move.l  d1,d0
        swap    d0
        bsr     ssi_dma_shadow_emit_word
        move.w  d1,d0
        bsr     ssi_dma_shadow_emit_word
        move.w  d2,d0
        bsr     ssi_dma_shadow_emit_word
        move.w  d3,d0
        bsr     ssi_dma_shadow_emit_word
        move.w  d4,d0
        bsr     ssi_dma_shadow_emit_word
        moveq   #0,d0
        bsr     ssi_dma_shadow_emit_word
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts
.shadow_begin_failed:
        moveq   #-1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Begin one packet in a full-row shadow frame.
;
; in:  a0 = 32-longword host packet (the first 26 longwords are canonical)
;      d0 = source triangle index (low 16 bits are sent)
;      d1 = visible row count for this packet
;      d2 = first visible Y row
; out: d0 = 0 on success, -1 on inactive/capacity/row-count failure
ssi_dma_row_shadow_packet_begin:
        movem.l d1-d7/a0-a6,-(sp)
        tst.l   ssi_dma_shadow_active
        beq     .row_packet_failed
        move.l  d1,d5
        tst.l   d5
        beq     .row_packet_failed
        cmpi.l  #$0fff,d5
        bhi     .row_packet_failed
        move.l  ssi_dma_shadow_words,d6
        addi.l  #9+SSI_DMA_FRAME_FOOTER_WORDS,d6
        cmp.l   ssi_dma_shadow_capacity,d6
        bhi     .row_packet_failed
        move.l  d0,d4
        move.l  a0,a5

        move.w  #SSI_DMA_PACKET_MAGIC,d0
        or.w    d5,d0
        bsr     ssi_dma_shadow_emit_word
        move.w  d4,d0
        bsr     ssi_dma_shadow_emit_word
        move.l  8(a5),d0
        swap    d0
        bsr     ssi_dma_shadow_emit_word
        move.w  10(a5),d0
        bsr     ssi_dma_shadow_emit_word
        move.w  2(a5),d0
        bsr     ssi_dma_shadow_emit_word
        moveq   #0,d0
        bsr     ssi_dma_shadow_emit_word
        move.w  54(a5),d0
        bsr     ssi_dma_shadow_emit_word
        move.w  58(a5),d0
        bsr     ssi_dma_shadow_emit_word
        move.w  d2,d0
        bsr     ssi_dma_shadow_emit_word
        addq.l  #1,ssi_dma_shadow_records
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts
.row_packet_failed:
        moveq   #-1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Emit a SET_SHADE control.  The caller only invokes this when the level
; changes, so the row stream carries packet-local shade state compactly.
;
; in: d0 = shade level 0..15
; out: d0 = 0 on success, -1 on inactive/capacity/level failure
ssi_dma_row_shadow_set_shade:
        movem.l d1-d7/a0-a6,-(sp)
        tst.l   ssi_dma_shadow_active
        beq     .row_shade_failed
        cmpi.l  #15,d0
        bhi     .row_shade_failed
        move.l  ssi_dma_shadow_words,d1
        addi.l  #1+SSI_DMA_FRAME_FOOTER_WORDS,d1
        cmp.l   ssi_dma_shadow_capacity,d1
        bhi     .row_shade_failed
        ori.w   #SSI_DMA_SHADE_MAGIC,d0
        bsr     ssi_dma_shadow_emit_word
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts
.row_shade_failed:
        moveq   #-1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Account for one or more visible Y rows whose clipped X interval is empty.
; The control advances the packet's logical row count without carrying U/V.
;
; in: d0 = skipped rows (1..256)
; out: d0 = 0 on success, -1 on inactive/capacity/count failure
ssi_dma_row_shadow_skip_rows:
        movem.l d1-d7/a0-a6,-(sp)
        tst.l   ssi_dma_shadow_active
        beq     .row_skip_failed
        tst.l   d0
        beq     .row_skip_failed
        cmpi.l  #256,d0
        bhi     .row_skip_failed
        move.l  ssi_dma_shadow_words,d1
        addi.l  #1+SSI_DMA_FRAME_FOOTER_WORDS,d1
        cmp.l   ssi_dma_shadow_capacity,d1
        bhi     .row_skip_failed
        subq.l  #1,d0
        ori.w   #SSI_DMA_ROW_SKIP_MAGIC,d0
        bsr     ssi_dma_shadow_emit_word
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts
.row_skip_failed:
        moveq   #-1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Emit one absolute clipped row.
;
; in: d0 = x0, d1 = count (1..256), d2 = U Q8.8, d3 = V Q8.8
; out: d0 = 0 on success, -1 on inactive/capacity/geometry failure
ssi_dma_row_shadow_append_row:
        movem.l d1-d7/a0-a6,-(sp)
        tst.l   ssi_dma_shadow_active
        beq     .row_append_failed
        move.l  d0,d4
        move.l  d1,d5
        cmpi.l  #239,d4
        bhi     .row_append_failed
        tst.l   d5
        beq     .row_append_failed
        cmpi.l  #256,d5
        bhi     .row_append_failed
        move.l  d4,d6
        add.l   d5,d6
        cmpi.l  #240,d6
        bhi     .row_append_failed
        move.l  ssi_dma_shadow_words,d6
        addi.l  #3+SSI_DMA_FRAME_FOOTER_WORDS,d6
        cmp.l   ssi_dma_shadow_capacity,d6
        bhi     .row_append_failed

        move.w  d4,d0
        lsl.w   #8,d0
        move.w  d5,d6
        subq.w  #1,d6
        or.w    d6,d0
        bsr     ssi_dma_shadow_emit_word
        move.w  d2,d0
        bsr     ssi_dma_shadow_emit_word
        move.w  d3,d0
        bsr     ssi_dma_shadow_emit_word
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts
.row_append_failed:
        moveq   #-1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Append one compact record to an active shadow frame.
;
; in:   a0 = 18 host longwords containing low 24-bit DSP words
;       d0 = global source-triangle index
; out:  d0 = 0 on success, -1 if inactive or the record plus footer will not fit
ssi_dma_shadow_append_record:
        movem.l d1-d7/a0-a6,-(sp)
        tst.l   ssi_dma_shadow_active
        beq     .shadow_append_failed
        move.l  d0,d4
        move.l  a0,a5
        move.l  ssi_dma_shadow_words,d1
        addi.l  #SSI_DMA_COMPACT_RECORD_WORDS+SSI_DMA_FRAME_FOOTER_WORDS,d1
        cmp.l   ssi_dma_shadow_capacity,d1
        bhi     .shadow_append_failed

        move.w  #SSI_DMA_COMPACT_RECORD_MAGIC,d0
        bsr     ssi_dma_shadow_emit_word
        move.l  d4,d0
        swap    d0
        bsr     ssi_dma_shadow_emit_word
        move.w  d4,d0
        bsr     ssi_dma_shadow_emit_word
        moveq   #17,d6
.shadow_append_word:
        move.l  (a5)+,d4
        andi.l  #$00ffffff,d4
        move.l  d4,d0
        swap    d0
        bsr     ssi_dma_shadow_emit_word
        move.w  d4,d0
        bsr     ssi_dma_shadow_emit_word
        dbra    d6,.shadow_append_word
        addq.l  #1,ssi_dma_shadow_records
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts
.shadow_append_failed:
        moveq   #-1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Finish an active compact frame by writing the footer.
;
; out:  d0 = actual stream length in 16-bit words, or -1 if inactive/invalid
; The CRC stored in the footer is captured before any footer word is emitted,
; matching crc16_ccitt(header through last record) in the Python model.
ssi_dma_shadow_finish:
        movem.l d1-d7/a0-a6,-(sp)
        tst.l   ssi_dma_shadow_active
        beq     .shadow_finish_failed
        move.l  ssi_dma_shadow_words,d1
        addi.l  #SSI_DMA_FRAME_FOOTER_WORDS,d1
        cmp.l   ssi_dma_shadow_capacity,d1
        bhi     .shadow_finish_failed
        move.w  ssi_dma_shadow_crc,d4

        move.w  #SSI_DMA_FRAME_FOOTER,d0
        bsr     ssi_dma_shadow_emit_word
        move.l  ssi_dma_shadow_frame_id,d5
        move.l  d5,d0
        swap    d0
        bsr     ssi_dma_shadow_emit_word
        move.w  d5,d0
        bsr     ssi_dma_shadow_emit_word
        move.l  ssi_dma_shadow_records,d0
        bsr     ssi_dma_shadow_emit_word
        move.l  d1,d0
        bsr     ssi_dma_shadow_emit_word
        move.w  d4,d0
        bsr     ssi_dma_shadow_emit_word

        move.l  d1,ssi_dma_shadow_actual_words
        clr.l   ssi_dma_shadow_active
        move.l  d1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts
.shadow_finish_failed:
        moveq   #-1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Append the transport probe's payload: d0 ramp words starting at d1, each
; the previous plus one modulo 16 bits.
;
; in:   d0 = payload word count, d1 = 16-bit seed
; out:  d0 = 0 on success, -1 if the frame is inactive or the payload plus
;       the reserved footer would not fit
;
; This is the host's independent model of what the DSP will generate.  The
; whole frame -- envelope, payload and CRC -- therefore exists on the host
; BEFORE the transfer starts, so the completed capture is checked by compare
; rather than by re-deriving the expectation from the bytes that arrived.
ssi_dma_probe_append_ramp:
        movem.l d1-d7/a0-a6,-(sp)
        tst.l   ssi_dma_shadow_active
        beq     .probe_ramp_failed
        move.l  d0,d6
        beq     .probe_ramp_failed
        move.l  ssi_dma_shadow_words,d2
        add.l   d6,d2
        addi.l  #SSI_DMA_FRAME_FOOTER_WORDS,d2
        cmp.l   ssi_dma_shadow_capacity,d2
        bhi     .probe_ramp_failed
        move.l  d6,ssi_dma_shadow_records
        move.w  d1,d7
        subq.l  #1,d6
.probe_ramp_word:
        move.w  d7,d0
        bsr     ssi_dma_shadow_emit_word
        addq.w  #1,d7
        dbra    d6,.probe_ramp_word
        ; DBRA counts the low word only.  It leaves $FFFF there on fall
        ; through, so borrowing one from the high word resumes a full 65,536
        ; iteration block.  The capacity gate caps a frame at 65,535 words,
        ; so this second stage cannot run today; it is here because a silent
        ; wrap is the failure mode a word counter has.
        subi.l  #$10000,d6
        bcc     .probe_ramp_word
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts
.probe_ramp_failed:
        moveq   #-1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Abandon a shadow frame without making it consumable.
ssi_dma_shadow_abort:
        clr.l   ssi_dma_shadow_active
        moveq   #-1,d0
        rts

; Emit one 16-bit word and update the stream CRC.  This is private to the
; shadow builder; callers must perform the capacity check before entering it.
ssi_dma_shadow_emit_word:
        movem.l d1-d3/a0,-(sp)
        move.l  ssi_dma_shadow_ptr,a0
        move.w  d0,(a0)+
        move.l  a0,ssi_dma_shadow_ptr
        addq.l  #1,ssi_dma_shadow_words

        move.w  d0,d3
        move.w  d0,d1
        lsr.w   #8,d1
        andi.w  #$00ff,d1
        move.w  d1,d0
        bsr     ssi_dma_shadow_crc_byte
        move.w  d3,d0
        andi.w  #$00ff,d0
        bsr     ssi_dma_shadow_crc_byte
        movem.l (sp)+,d1-d3/a0
        rts

ssi_dma_shadow_crc_byte:
        move.w  ssi_dma_shadow_crc,d1
        move.w  d0,d2
        andi.w  #$00ff,d2
        lsl.w   #8,d2
        eor.w   d2,d1
        moveq   #7,d2
.shadow_crc_bit:
        add.w   d1,d1
        bcc     .shadow_crc_no_poly
        eori.w  #$1021,d1
.shadow_crc_no_poly:
        dbra    d2,.shadow_crc_bit
        move.w  d1,ssi_dma_shadow_crc
        rts

; Consume a completed row stream through an in-memory Hatari DMA loopback.
;
; in:   a0 = first word of a completed framed stream
;       d0 = actual stream length in 16-bit words
; out:  d0 = 0 when the frame is consumable, -1 on a framing/CRC error
;
; This is deliberately a transport consumer, not a second renderer.  It
; models the point at which a real DMA-record buffer would become CPU-owned:
; the parser accepts only a complete header/body/footer, checks packet row
; alignment and the CRC, and publishes counters for the Hatari status file.
; No Falcon DMA, Crossbar or SSI register is touched on this path.
ssi_dma_hatari_consume_frame:
        movem.l d1-d7/a0-a6,-(sp)
        clr.l   ssi_dma_hatari_result
        clr.l   ssi_dma_hatari_consumed_words
        clr.l   ssi_dma_hatari_packets
        clr.l   ssi_dma_hatari_rows
        clr.l   ssi_dma_hatari_skips
        clr.l   ssi_dma_hatari_shades
        clr.w   ssi_dma_hatari_crc
        clr.w   ssi_dma_hatari_expected_crc
        clr.l   ssi_dma_hatari_error_stage
        move.l  d0,ssi_dma_hatari_words
        move.l  d0,ssi_dma_hatari_remaining
        move.l  a0,ssi_dma_hatari_ptr
        move.w  #$ffff,ssi_dma_hatari_crc

        cmpi.l  #SSI_DMA_FRAME_HEADER_WORDS+SSI_DMA_FRAME_FOOTER_WORDS,d0
        bcs     .hatari_fail_envelope

        bsr     ssi_dma_hatari_read_crc_word
        cmpi.l  #$5353,d0
        bne     .hatari_fail_envelope
        bsr     ssi_dma_hatari_read_crc_word
        cmpi.l  #SSI_DMA_ROW_FRAME_FLAGS,d0
        bne     .hatari_fail_envelope
        bsr     ssi_dma_hatari_read_crc_word
        move.w  d0,ssi_dma_hatari_frame_hi
        bsr     ssi_dma_hatari_read_crc_word
        move.w  d0,ssi_dma_hatari_frame_lo
        bsr     ssi_dma_hatari_read_crc_word
        bsr     ssi_dma_hatari_read_crc_word
        bsr     ssi_dma_hatari_read_crc_word
        move.w  d0,ssi_dma_hatari_capacity
        bsr     ssi_dma_hatari_read_crc_word

        move.l  ssi_dma_hatari_words,d1
        moveq   #0,d2
        move.w  ssi_dma_hatari_capacity,d2
        cmp.l   d2,d1
        bhi     .hatari_fail_envelope

.hatari_packet_or_footer
        move.l  ssi_dma_hatari_remaining,d1
        cmpi.l  #SSI_DMA_FRAME_FOOTER_WORDS,d1
        bcs     .hatari_fail_footer
        bsr     ssi_dma_hatari_read_raw_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_footer
        cmpi.l  #SSI_DMA_FRAME_FOOTER,d0
        beq     .hatari_read_footer

        move.w  d0,d4
        move.w  d0,d5
        andi.w  #$f000,d4
        cmpi.w  #SSI_DMA_PACKET_MAGIC,d4
        bne     .hatari_fail_packet
        andi.w  #$0fff,d5
        beq     .hatari_fail_packet
        bsr     ssi_dma_hatari_crc_word
        move.l  d5,ssi_dma_hatari_packet_rows_remaining

        move.l  ssi_dma_hatari_packets,d6

        ; Source and OT key.
        bsr     ssi_dma_hatari_read_crc_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_packet
        bsr     ssi_dma_hatari_read_crc_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_packet
        bsr     ssi_dma_hatari_read_crc_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_packet

        ; Shade/tint, flags, du/dv and signed y_start.  Keep the initial
        ; shade and Y anchor beside the packet body so the later OT walk can
        ; feed the rows in painter's order rather than stream order.
        bsr     ssi_dma_hatari_read_crc_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_packet
        andi.l  #$0000000f,d0
        move.l  d6,d5
        lsl.l   #2,d5
        lea     ssi_dma_hatari_packet_shades,a1
        move.l  d0,(a1,d5.l)
        bsr     ssi_dma_hatari_read_crc_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_packet
        bsr     ssi_dma_hatari_read_crc_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_packet
        bsr     ssi_dma_hatari_read_crc_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_packet
        bsr     ssi_dma_hatari_read_crc_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_packet
        ext.l   d0
        lea     ssi_dma_hatari_packet_y,a1
        move.l  d0,(a1,d5.l)

        move.l  ssi_dma_hatari_ptr,a0
        lea     ssi_dma_hatari_packet_start,a1
        move.l  a0,(a1,d5.l)
        addq.l  #1,ssi_dma_hatari_packets

.hatari_row_or_control
        tst.l   ssi_dma_hatari_packet_rows_remaining
        beq     .hatari_packet_body_done
        bsr     ssi_dma_hatari_read_crc_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_row
        move.w  d0,d4
        andi.w  #$ff00,d4
        cmpi.w  #SSI_DMA_SHADE_MAGIC,d4
        beq     .hatari_set_shade
        cmpi.w  #SSI_DMA_ROW_SKIP_MAGIC,d4
        beq     .hatari_skip_rows
        cmpi.w  #$f000,d4
        bcc     .hatari_fail_row

        ; ROW_ABS geometry: x0 is in 0..239 and count is non-zero and
        ; remains inside the 240-pixel render window.
        move.w  d0,d5
        lsr.w   #8,d5
        cmpi.w  #239,d5
        bhi     .hatari_fail_row
        move.w  d0,d5
        andi.w  #$00ff,d5
        addq.w  #1,d5
        move.w  d5,d4
        add.w   d0,d4
        andi.w  #$ff00,d4
        ; Recompute x0 + count with the two bytes separately.  This avoids
        ; accepting a wrapped 8-bit count at the right edge.
        move.w  d0,d4
        lsr.w   #8,d4
        add.w   d5,d4
        cmpi.w  #240,d4
        bhi     .hatari_fail_row
        bsr     ssi_dma_hatari_read_crc_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_row
        bsr     ssi_dma_hatari_read_crc_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_row
        subq.l  #1,ssi_dma_hatari_packet_rows_remaining
        addq.l  #1,ssi_dma_hatari_rows
        bra     .hatari_row_or_control

.hatari_packet_body_done
        move.l  ssi_dma_hatari_packets,d6
        subq.l  #1,d6
        lsl.l   #2,d6
        move.l  ssi_dma_hatari_ptr,a0
        lea     ssi_dma_hatari_packet_end,a1
        move.l  a0,(a1,d6.l)
        bra     .hatari_packet_or_footer

.hatari_set_shade
        move.w  d0,d5
        andi.w  #$000f,d5
        cmpi.w  #15,d5
        bhi     .hatari_fail_row
        addq.l  #1,ssi_dma_hatari_shades
        bra     .hatari_row_or_control

.hatari_skip_rows
        moveq   #0,d5
        move.w  d0,d5
        andi.l  #$00ff,d5
        addq.l  #1,d5
        cmp.l   ssi_dma_hatari_packet_rows_remaining,d5
        bhi     .hatari_fail_row
        sub.l   d5,ssi_dma_hatari_packet_rows_remaining
        add.l   d5,ssi_dma_hatari_rows
        add.l   d5,ssi_dma_hatari_skips
        bra     .hatari_row_or_control

.hatari_read_footer
        bsr     ssi_dma_hatari_read_raw_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_footer
        cmp.w   ssi_dma_hatari_frame_hi,d0
        bne     .hatari_fail_footer
        bsr     ssi_dma_hatari_read_raw_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_footer
        cmp.w   ssi_dma_hatari_frame_lo,d0
        bne     .hatari_fail_footer
        bsr     ssi_dma_hatari_read_raw_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_footer
        cmp.l   ssi_dma_hatari_packets,d0
        bne     .hatari_fail_footer
        bsr     ssi_dma_hatari_read_raw_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_footer
        cmp.l   ssi_dma_hatari_words,d0
        bne     .hatari_fail_footer
        bsr     ssi_dma_hatari_read_raw_word
        cmpi.l  #-1,d0
        beq     .hatari_fail_footer
        move.w  d0,ssi_dma_hatari_expected_crc
        cmp.w   ssi_dma_hatari_crc,d0
        bne     .hatari_fail_crc
        tst.l   ssi_dma_hatari_remaining
        bne     .hatari_fail_footer
        move.l  #0,ssi_dma_hatari_result
        moveq   #0,d0
        bra     .hatari_consume_return

.hatari_fail_envelope
        move.l  #1,ssi_dma_hatari_error_stage
        bra     .hatari_consume_failed
.hatari_fail_packet
        move.l  #2,ssi_dma_hatari_error_stage
        bra     .hatari_consume_failed
.hatari_fail_row
        move.l  #3,ssi_dma_hatari_error_stage
        bra     .hatari_consume_failed
.hatari_fail_footer
        move.l  #4,ssi_dma_hatari_error_stage
        bra     .hatari_consume_failed
.hatari_fail_crc
        move.l  #5,ssi_dma_hatari_error_stage
.hatari_consume_failed
        move.l  ssi_dma_hatari_words,d1
        sub.l   ssi_dma_hatari_remaining,d1
        move.l  d1,ssi_dma_hatari_consumed_words
        move.l  #-1,ssi_dma_hatari_result
        moveq   #-1,d0
        bra     .hatari_consume_return

.hatari_consume_return
        move.l  ssi_dma_hatari_words,d1
        sub.l   ssi_dma_hatari_remaining,d1
        move.l  d1,ssi_dma_hatari_consumed_words
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Feed one validated packet's rows to the Hatari rasterizer callback.
;
; in:   d0 = stream packet index, in the order recorded by the consumer
; out:  d0 = 0 on success, -1 if the index or packet body is invalid
;
; The caller chooses painter's order by walking the existing Ordering Table
; and passing the corresponding stream index.  This keeps application
; framing/transport order separate from visibility order, exactly as a real
; DMA consumer must do before touching the framebuffer.
ssi_dma_hatari_feed_packet:
        movem.l d1-d7/a0-a6,-(sp)
        tst.l   ssi_dma_hatari_result
        bne     .hatari_feed_failed
        move.l  d0,d7
        tst.l   d7
        bmi     .hatari_feed_failed
        cmp.l   ssi_dma_hatari_packets,d7
        bcc     .hatari_feed_failed
        move.l  d7,d5
        lsl.l   #2,d5
        lea     ssi_dma_hatari_packet_start,a1
        move.l  (0,a1,d5.l),a0
        lea     ssi_dma_hatari_packet_end,a1
        move.l  (0,a1,d5.l),a1
        lea     ssi_dma_hatari_packet_y,a2
        move.l  (0,a2,d5.l),d2
        lea     ssi_dma_hatari_packet_shades,a2
        move.l  (0,a2,d5.l),d3
        move.l  ssi_dma_hatari_feed_callback,a2

.hatari_feed_row_or_control
        cmp.l   a1,a0
        beq     .hatari_feed_done
        bcc     .hatari_feed_failed
        moveq   #0,d0
        move.w  (a0)+,d0
        move.w  d0,d4
        andi.w  #$ff00,d4
        cmpi.w  #SSI_DMA_SHADE_MAGIC,d4
        beq     .hatari_feed_shade
        cmpi.w  #SSI_DMA_ROW_SKIP_MAGIC,d4
        beq     .hatari_feed_skip
        cmpi.w  #$f000,d4
        bcc     .hatari_feed_failed

        move.w  d0,d4
        lsr.w   #8,d4
        move.l  d4,ssi_dma_hatari_feed_x
        moveq   #0,d4
        move.w  d0,d4
        andi.l  #$00ff,d4
        addq.l  #1,d4
        move.l  d4,ssi_dma_hatari_feed_count
        moveq   #0,d4
        move.w  (a0)+,d4
        move.l  d4,ssi_dma_hatari_feed_u
        moveq   #0,d4
        move.w  (a0)+,d4
        move.l  d4,ssi_dma_hatari_feed_v
        move.l  d2,ssi_dma_hatari_feed_y
        move.l  d3,ssi_dma_hatari_feed_shade
        tst.l   a2
        beq     .hatari_feed_row_advance
        movem.l d2-d3/a0-a1,-(sp)
        jsr     (a2)
        movem.l (sp)+,d2-d3/a0-a1
.hatari_feed_row_advance
        addq.l  #1,d2
        bra     .hatari_feed_row_or_control

.hatari_feed_shade
        andi.l  #$0000000f,d0
        move.l  d0,d3
        bra     .hatari_feed_row_or_control

.hatari_feed_skip
        moveq   #0,d4
        move.w  d0,d4
        andi.l  #$00ff,d4
        addq.l  #1,d4
        add.l   d4,d2
        bra     .hatari_feed_row_or_control

.hatari_feed_done
        moveq   #0,d0
        bra     .hatari_feed_return
.hatari_feed_failed
        moveq   #-1,d0
.hatari_feed_return
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Read one raw DMA word without touching the application CRC.
ssi_dma_hatari_read_raw_word
        tst.l   ssi_dma_hatari_remaining
        beq     .hatari_raw_eof
        move.l  ssi_dma_hatari_ptr,a0
        moveq   #0,d0
        move.w  (a0)+,d0
        move.l  a0,ssi_dma_hatari_ptr
        subq.l  #1,ssi_dma_hatari_remaining
        rts
.hatari_raw_eof
        moveq   #-1,d0
        rts

; Read one word and include its big-endian bytes in the frame CRC.
ssi_dma_hatari_read_crc_word
        bsr     ssi_dma_hatari_read_raw_word
        cmpi.l  #-1,d0
        beq     .hatari_crc_read_eof
        bsr     ssi_dma_hatari_crc_word
.hatari_crc_read_eof
        rts

ssi_dma_hatari_crc_word
        movem.l d0-d3,-(sp)
        move.w  d0,d3
        move.w  d0,d1
        lsr.w   #8,d1
        andi.w  #$00ff,d1
        move.w  d1,d0
        bsr     ssi_dma_hatari_crc_byte
        move.w  d3,d0
        andi.w  #$00ff,d0
        bsr     ssi_dma_hatari_crc_byte
        movem.l (sp)+,d0-d3
        rts

ssi_dma_hatari_crc_byte
        movem.l d1-d2,-(sp)
        move.w  ssi_dma_hatari_crc,d1
        move.w  d0,d2
        andi.w  #$00ff,d2
        lsl.w   #8,d2
        eor.w   d2,d1
        moveq   #7,d2
.hatari_crc_bit
        add.w   d1,d1
        bcc     .hatari_crc_no_poly
        eori.w  #$1021,d1
.hatari_crc_no_poly
        dbra    d2,.hatari_crc_bit
        move.w  d1,ssi_dma_hatari_crc
        movem.l (sp)+,d1-d2
        rts

; Claim and configure the record channel.
;
; in:  a0 = first byte of the one-shot record buffer
;      a1 = byte immediately after the buffer
; out: d0 = 0 on setup, -1 on a failed XBIOS call
;
; The caller must not pass a buffer that is visible through a write-back data
; cache.  That gate is deliberately outside this scaffold until a physical
; Falcon mapping/flush test chooses the contract.
; ssi_dma_claim_stage records the last gate entered: 1=Locksnd,
; 2=idle-DMA snapshot, 3=Buffoper stop, 4=Sndstatus, 5=Soundcmd,
; 6=Setmode, 7=Settracks, 8=Setmontracks, 9=Setbuffer, 10=Dsptristate,
; 11=Devconnect, 12=raw Crossbar field write, 13=raw Crossbar validation.
ssi_dma_claim:
        movem.l d1-d7/a0-a6,-(sp)
        tst.l   ssi_dma_owned
        bne     .claim_failed
        clr.l   ssi_dma_claim_stage
        move.l  #SSI_DMA_ROUTE_NOT_RUN,ssi_dma_route_status
        clr.w   ssi_dma_route_source
        clr.w   ssi_dma_route_destination
        move.l  a0,ssi_dma_buffer_start
        move.l  a1,ssi_dma_buffer_end

        lea     ssi_dma_xbios_results,a2
        moveq   #SSI_DMA_CLAIM_STAGES-1,d7
        move.l  #-999,d6
.claim_clear_results:
        move.l  d6,(a2)+
        dbra    d7,.claim_clear_results

        move.l  #1,ssi_dma_claim_stage
        Locksnd
        move.l  d0,ssi_dma_xbios_results
        cmpi.w  #1,d0
        bne     .claim_failed_no_lock

        ; Capture the complete idle DMA/crossbar image in supervisor mode.
        ; An active playback/record client is rejected before any matrix or
        ; buffer mutation: the Falcon exposes the moving count pointer for
        ; observation, but not a portable way to resume it at that exact byte.
        move.l  #2,ssi_dma_claim_stage
        Supexec ssi_dma_snapshot_super
        move.l  d0,ssi_dma_xbios_results+(1*4)
        tst.l   d0
        bne     .claim_failed_snapshot
        move.l  #1,ssi_dma_owned

        ; Stop another program's playback/record operation before changing
        ; the shared matrix.  This also makes a stale DMA request harmless
        ; while the new buffer and route are being installed.
        move.l  #3,ssi_dma_claim_stage
        Buffoper #SSI_DMA_STOP
        move.l  d0,ssi_dma_xbios_results+(2*4)
        tst.l   d0
        bmi     .claim_failed_owned
        move.l  #4,ssi_dma_claim_stage
        Sndstatus #SSI_DMA_STATUS_RESET
        move.l  d0,ssi_dma_xbios_results+(3*4)
        tst.l   d0
        bmi     .claim_failed_owned
        move.l  #5,ssi_dma_claim_stage
        Soundcmd #SSI_DMA_ADDER_IN,#SSI_DMA_MATRIX_IN
        move.l  d0,ssi_dma_xbios_results+(4*4)
        tst.l   d0
        bmi     .claim_failed_owned
        move.l  #6,ssi_dma_claim_stage
        Setmode #SSI_DMA_STEREO16
        move.l  d0,ssi_dma_xbios_results+(5*4)
        tst.l   d0
        bmi     .claim_failed_owned
        move.l  #7,ssi_dma_claim_stage
        Settracks #0,#0
        move.l  d0,ssi_dma_xbios_results+(6*4)
        tst.l   d0
        bmi     .claim_failed_owned
        move.l  #8,ssi_dma_claim_stage
        Setmontracks #SSI_DMA_MONITOR_PAIR0
        move.l  d0,ssi_dma_xbios_results+(7*4)
        tst.l   d0
        bmi     .claim_failed_owned
        move.l  #9,ssi_dma_claim_stage
        Setbuffer #SSI_DMA_RECORD_REGION,ssi_dma_buffer_start,ssi_dma_buffer_end
        move.l  d0,ssi_dma_xbios_results+(8*4)
        tst.l   d0
        bmi     .claim_failed_owned

        ; Connect DSP transmit to DMA record with transport handshaking.  The
        ; exact source/destination fields must be read back on hardware; the
        ; physical probe rejects a mismatch instead of trusting the XBIOS
        ; return value alone.
        move.l  #10,ssi_dma_claim_stage
        Dsptristate #1,#0
        move.l  d0,ssi_dma_xbios_results+(9*4)
        tst.l   d0
        bmi     .claim_failed_owned
        move.l  #11,ssi_dma_claim_stage
        Devconnect #SSI_DMA_DSP_XMIT,#SSI_DMA_RECORD,#SSI_DMA_CLOCK_32M,#SSI_DMA_PRESCALE_FAST,#SSI_DMA_HANDSHAKE
        move.l  d0,ssi_dma_xbios_results+(10*4)
        tst.l   d0
        bmi     .claim_failed_owned
        move.l  #12,ssi_dma_claim_stage
        Supexec ssi_dma_force_route_super
        move.l  d0,ssi_dma_xbios_results+(11*4)
        move.l  #13,ssi_dma_claim_stage
        Supexec ssi_dma_validate_route_super
        move.l  d0,ssi_dma_xbios_results+(12*4)
        tst.l   d0
        bne     .claim_failed_owned

        clr.l   ssi_dma_running
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

.claim_failed_owned:
        Dsptristate #0,#0
        Buffoper #SSI_DMA_STOP
        Supexec ssi_dma_restore_super
        Unlocksnd
        clr.l   ssi_dma_owned
        bra     .claim_failed
.claim_failed_snapshot:
        ; Locksnd succeeded, but the pre-state was unsafe to claim.  No
        ; owner flag was published, so only release the lock we acquired.
        Unlocksnd
.claim_failed_no_lock:
.claim_failed:
        moveq   #-1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Read back the route selected by Devconnect.  The caller may invoke this
; wrapper independently; claim uses the supervisor leaf directly so the
; comparison and the shared-register read happen in one supervisor window.
ssi_dma_validate_route:
        movem.l d1-d7/a0-a6,-(sp)
        Supexec ssi_dma_validate_route_super
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Supervisor-only raw Crossbar gate.  The source and destination fields are
; stored even on mismatch, making a probe failure actionable instead of just
; reporting a generic XBIOS error.
ssi_dma_validate_route_super:
        move.w  SSI_XBAR_SOURCE,ssi_dma_route_source
        move.w  SSI_XBAR_DESTINATION,ssi_dma_route_destination
        move.w  ssi_dma_route_source,d1
        andi.w  #SSI_XBAR_SOURCE_MASK,d1
        cmpi.w  #SSI_XBAR_SOURCE_DSP_XMIT,d1
        bne     .route_mismatch
        move.w  ssi_dma_route_destination,d1
        andi.w  #SSI_XBAR_DEST_MASK,d1
        cmpi.w  #SSI_XBAR_DEST_DSP_TO_DMA,d1
        bne     .route_mismatch
        moveq   #0,d0
        move.l  d0,ssi_dma_route_status
        rts
.route_mismatch:
        moveq   #-1,d0
        move.l  d0,ssi_dma_route_status
        rts

; Supervisor-only masked write of exactly the two route fields this transport
; owns, leaving the DAC, external-output, DSP-receive, external-input and
; DMA-playback fields of the shared registers as Devconnect left them.
;
; Devconnect is still called first: it owns the clock divider, track and
; adder selections, and a Crossbar written behind XBIOS's back would leave
; the OS view inconsistent with the hardware.  This is the read-modify-write
; the Hardware Reference Guide's field map specifies, applied afterwards so
; the probe does not depend on a particular TOS revision producing the exact
; handshake bits.  Its pre-image is published so a run can tell "Devconnect
; already did it" from "the forced write did it".
ssi_dma_force_route_super:
        move.w  SSI_XBAR_SOURCE,ssi_dma_devconnect_source
        move.w  SSI_XBAR_DESTINATION,ssi_dma_devconnect_destination
        move.w  ssi_dma_devconnect_source,d1
        andi.w  #~SSI_XBAR_SOURCE_MASK&$ffff,d1
        ori.w   #SSI_XBAR_SOURCE_DSP_XMIT,d1
        move.w  d1,SSI_XBAR_SOURCE
        move.w  ssi_dma_devconnect_destination,d1
        andi.w  #~SSI_XBAR_DEST_MASK&$ffff,d1
        ori.w   #SSI_XBAR_DEST_DSP_TO_DMA,d1
        move.w  d1,SSI_XBAR_DESTINATION
        moveq   #0,d0
        rts

; Point the owned record channel at an exact byte window and arm it.
;
; in:  a0 = first byte of the record window, a1 = byte after its last
; out: d0 = 0 on arm, -1 if unowned/already running/Setbuffer or Buffoper
;      failed.
;
; The window is re-declared on every transaction because the transfer is
; one-shot: Setbuffer latches start/end, Buffoper starts the channel, and the
; hardware clears record enable itself when the end address is reached.  A
; caller that reuses the claim-time window still has to call this, because a
; completed one-shot leaves the pointer at the end.
ssi_dma_arm_record:
        movem.l d1-d7/a0-a6,-(sp)
        tst.l   ssi_dma_owned
        beq     .arm_failed
        tst.l   ssi_dma_running
        bne     .arm_failed
        cmpa.l  a0,a1
        bls     .arm_failed
        move.l  a0,ssi_dma_buffer_start
        move.l  a1,ssi_dma_buffer_end
        Buffoper #SSI_DMA_STOP
        Setbuffer #SSI_DMA_RECORD_REGION,ssi_dma_buffer_start,ssi_dma_buffer_end
        tst.l   d0
        bne     .arm_failed
        clr.l   ssi_dma_completed_bytes
        clr.l   ssi_dma_wait_ticks
        Buffoper #SSI_DMA_RECORD_START
        tst.l   d0
        bne     .arm_failed
        move.l  #1,ssi_dma_running
        Supexec ssi_dma_snapshot_armed_super
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts
.arm_failed:
        moveq   #-1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Wait for the one-shot record window to fill, then stop the channel.
;
; in:  d0 = timeout in 200 Hz ticks (0 selects SSI_DMA_DEFAULT_TIMEOUT)
; out: d0 = 0 when the hardware reached the declared end, -1 on timeout
;
; Completion is the AND of two independent facts, per the section 7.4 gate:
; the hardware cleared record enable in $FF8901, and the record pointer
; reached the declared end address.  Either one alone is not completion -- a
; stopped channel can sit anywhere, and a pointer can be read mid-word --
; so both are required and both are published for the sidecar.  The observed
; byte count is recorded either way, which is what makes a timeout tell you
; how far the transfer actually got.
ssi_dma_wait_record:
        movem.l d1-d7/a0-a6,-(sp)
        move.l  d0,d3
        bne     .wait_have_timeout
        move.l  #SSI_DMA_DEFAULT_TIMEOUT,d3
.wait_have_timeout:
        tst.l   ssi_dma_owned
        beq     .wait_failed
        move.l  $4ba.w,d4               ; 200 Hz system tick at entry
.wait_poll:
        Supexec ssi_dma_poll_record_super
        move.l  d0,d5
        move.l  $4ba.w,d6
        sub.l   d4,d6
        move.l  d6,ssi_dma_wait_ticks
        tst.l   d5
        beq     .wait_complete
        cmp.l   d3,d6
        bcs     .wait_poll

        ; Timed out.  Stop the channel so a half-finished transfer cannot
        ; keep writing behind the validator, and report the distance.
        Buffoper #SSI_DMA_STOP
        clr.l   ssi_dma_running
        Supexec ssi_dma_poll_record_super
        moveq   #-1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts
.wait_complete:
        Buffoper #SSI_DMA_STOP
        clr.l   ssi_dma_running
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts
.wait_failed:
        moveq   #-1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Invalidate the whole 68030 data cache.
;
; The record channel writes system RAM without the 68030 seeing the bus
; cycles, so a line this program touched before the transfer would satisfy a
; later read from stale data.  The 68030's data cache is write-through, so
; there is nothing dirty to push out and a bulk invalidate is the complete
; contract: CACR bit 11 (CD) clears every data-cache entry.  Bit 8 (ED) is
; read back unchanged, so this neither enables nor disables the cache.
;
; This closes the coherency gate for a buffer the CPU only READS after the
; transfer.  It does not make a buffer safe to read WHILE DMA is writing it,
; which is why the transport waits for the declared end address first.
ssi_dma_invalidate_dcache:
        movem.l d1-d7/a0-a6,-(sp)
        Supexec ssi_dma_invalidate_dcache_super
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

ssi_dma_invalidate_dcache_super:
        movec   cacr,d0
        move.l  d0,ssi_dma_cacr_image
        ori.l   #SSI_DMA_CACR_CLEAR_DATA,d0
        movec   d0,cacr
        moveq   #0,d0
        rts

; Supervisor-only record-position poll.  d0 = 0 once the hardware has both
; cleared record enable and moved the pointer to the declared end.
ssi_dma_poll_record_super:
        moveq   #0,d1
        move.b  SSI_DMA_CONTROL,d1
        andi.w  #$00ff,d1
        move.w  d1,ssi_dma_run_control
        ori.b   #SSI_DMA_RECORD_SELECT,d1
        move.b  d1,SSI_DMA_CONTROL
        ; The three count bytes are read separately, so a live channel can
        ; hand back a torn address.  That is why record enable, not the
        ; pointer, is the authoritative half of the completion test: the
        ; pointer only has to confirm the channel stopped at the END rather
        ; than somewhere else.
        moveq   #0,d2
        move.b  SSI_DMA_COUNT_HI,d2
        lsl.l   #8,d2
        move.b  SSI_DMA_COUNT_MID,d2
        lsl.l   #8,d2
        move.b  SSI_DMA_COUNT_LO,d2
        andi.l  #$00fffffe,d2
        move.b  ssi_dma_run_control+1,SSI_DMA_CONTROL
        sub.l   ssi_dma_buffer_start,d2
        bcc     .poll_have_bytes
        moveq   #0,d2
.poll_have_bytes:
        move.l  d2,ssi_dma_completed_bytes
        move.w  ssi_dma_run_control,d1
        andi.w  #SSI_DMA_RECORD_ENABLE,d1
        bne     .poll_running
        move.l  ssi_dma_buffer_end,d1
        sub.l   ssi_dma_buffer_start,d1
        cmp.l   d1,d2
        bcs     .poll_running
        moveq   #0,d0
        rts
.poll_running:
        moveq   #-1,d0
        rts

; Supervisor-only image of the register state an armed channel is running
; under.  Captured once at arm time so a failed transfer can be diagnosed
; from the sidecar without a second run.
ssi_dma_snapshot_armed_super:
        move.b  SSI_DMA_CONTROL,ssi_dma_armed_control
        move.b  SSI_DMA_INT_CONTROL,ssi_dma_armed_int_control
        move.w  SSI_DMA_MODE,ssi_dma_armed_mode
        move.w  SSI_XBAR_SOURCE,ssi_dma_armed_xbar_source
        move.w  SSI_XBAR_DESTINATION,ssi_dma_armed_xbar_destination
        move.b  SSI_XBAR_INT_DIVIDER,ssi_dma_armed_divider
        moveq   #0,d0
        rts

; Start one one-shot record transaction after the DSP has published the
; matching frame id/generation in the inactive buffer.
ssi_dma_begin:
        movem.l d1-d7/a0-a6,-(sp)
        tst.l   ssi_dma_owned
        beq     .begin_failed
        tst.l   ssi_dma_running
        bne     .begin_failed
        Buffoper #SSI_DMA_RECORD_START
        tst.l   d0
        bne     .begin_failed
        move.l  #1,ssi_dma_running
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts
.begin_failed:
        moveq   #-1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Stop only the channel owned by this scaffold.  The caller still has to
; validate the DMA current pointer and the SSI_END footer before swapping a
; buffer into the renderer.
ssi_dma_stop:
        movem.l d1-d7/a0-a6,-(sp)
        tst.l   ssi_dma_owned
        beq     .stop_done
        Buffoper #SSI_DMA_STOP
        clr.l   ssi_dma_running
.stop_done:
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Read the current record pointer for variable-length SSI_END completion.
; out: d0 = current record address, or -1 when unowned/Buffptr failed.
; The caller compares it with buffer_start + 2*actual_words before accepting
; the footer and CRC; a footer by itself is not completion proof.
ssi_dma_get_record_ptr:
        movem.l d1-d7/a0-a6,-(sp)
        tst.l   ssi_dma_owned
        beq     .record_ptr_failed
        Buffptr ssi_dma_ptrs
        tst.l   d0
        bne     .record_ptr_failed
        move.l  ssi_dma_ptrs+4,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts
.record_ptr_failed:
        moveq   #-1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Quiesce and release.  The snapshot was taken while the sound system was
; locked, and release restores the idle DMA/crossbar image before unlocking.
; This scaffold never enables Setinterrupt, so no MFP state is changed.  An
; already-active DMA client is rejected by the snapshot routine instead of
; pretending its moving count pointer can be resumed exactly.
ssi_dma_release:
        movem.l d1-d7/a0-a6,-(sp)
        tst.l   ssi_dma_owned
        beq     .release_done
        Buffoper #SSI_DMA_STOP
        Dsptristate #0,#0
        Supexec ssi_dma_restore_super
        Unlocksnd
        clr.l   ssi_dma_running
        clr.l   ssi_dma_owned
.release_done:
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; -----------------------------------------------------------------------------
; Supervisor-only raw state capture/restore
; -----------------------------------------------------------------------------

; Capture both Falcon DMA register sets plus the shared Crossbar.  The count
; pointers are retained for diagnostics and for the future active-client
; policy, but are read-only; claim therefore accepts only an idle pre-state.
ssi_dma_snapshot_super:
        movem.l d1-d7/a0-a6,-(sp)

        move.w  SSI_XBAR_SOURCE,ssi_dma_old_xbar_source
        move.w  SSI_XBAR_DESTINATION,ssi_dma_old_xbar_destination
        lea     ssi_dma_old_xbar_bytes,a0
        move.b  SSI_XBAR_EXT_DIVIDER,(a0)+
        move.b  SSI_XBAR_INT_DIVIDER,(a0)+
        move.b  SSI_XBAR_RECORD_TRACKS,(a0)+
        move.b  SSI_XBAR_CODEC_INPUT,(a0)+
        move.b  SSI_XBAR_ADC_INPUT,(a0)+
        move.b  SSI_XBAR_INPUT_GAIN,(a0)+
        move.b  SSI_XBAR_OUTPUT_ATTEN,(a0)+

        move.b  SSI_DMA_INT_CONTROL,ssi_dma_old_int_control
        move.b  SSI_DMA_CONTROL,ssi_dma_old_control
        move.w  SSI_DMA_MODE,ssi_dma_old_mode

        moveq   #0,d1
        move.b  ssi_dma_old_control,d1
        move.b  d1,d2
        andi.b  #$7f,d2
        move.b  d2,SSI_DMA_CONTROL
        lea     ssi_dma_old_play_base,a0
        bsr     ssi_dma_snapshot_regs

        ori.b   #SSI_DMA_RECORD_SELECT,d2
        move.b  d2,SSI_DMA_CONTROL
        lea     ssi_dma_old_record_base,a0
        bsr     ssi_dma_snapshot_regs

        move.b  ssi_dma_old_control,SSI_DMA_CONTROL

        ; Do not steal a live sound client.  The gate is the pair of ENABLE
        ; bits in $FF8901 and nothing else.
        ;
        ; $FF8900 is deliberately NOT a rejection criterion.  Its power-on
        ; value already selects end-of-buffer interrupt sources -- Hatari
        ; resets it to $05, matching the documented Falcon default -- so a
        ; quiescent machine that has never played a sound fails an
        ; "interrupts configured" test.  That is exactly what happened: the
        ; 2026-08-19 probe run reported claim_stage 2 and never reached
        ; Devconnect on an idle emulator.  The register is still captured and
        ; restored, and Setinterrupt is still never called, so nothing this
        ; scaffold does can leave an interrupt source altered.
        moveq   #0,d0
        move.b  ssi_dma_old_control,d0
        andi.l  #SSI_DMA_ACTIVE_MASK,d0
        bne     .snapshot_failed
        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

.snapshot_failed:
        moveq   #-1,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; a0 = three-byte base, three-byte count, three-byte end destinations
ssi_dma_snapshot_regs:
        move.b  SSI_DMA_BASE_HI,(a0)+
        move.b  SSI_DMA_BASE_MID,(a0)+
        move.b  SSI_DMA_BASE_LO,(a0)+
        move.b  SSI_DMA_COUNT_HI,(a0)+
        move.b  SSI_DMA_COUNT_MID,(a0)+
        move.b  SSI_DMA_COUNT_LO,(a0)+
        move.b  SSI_DMA_END_HI,(a0)+
        move.b  SSI_DMA_END_MID,(a0)+
        move.b  SSI_DMA_END_LO,(a0)+
        rts

; Restore both idle DMA register sets and the shared Crossbar.  The DMA
; control byte is restored last so addresses are stable before any prior mode
; is visible again.
ssi_dma_restore_super:
        movem.l d1-d7/a0-a6,-(sp)

        ; Force the currently selected set off while its address registers are
        ; restored.  The caller has already stopped our record operation, but
        ; this makes the helper safe on every failure edge.
        moveq   #0,d1
        move.b  SSI_DMA_CONTROL,d1
        andi.b  #$f0,d1
        move.b  d1,SSI_DMA_CONTROL

        moveq   #0,d1
        move.b  ssi_dma_old_control,d1
        move.b  d1,d2
        andi.b  #$7f,d2
        move.b  d2,SSI_DMA_CONTROL
        lea     ssi_dma_old_play_base,a0
        bsr     ssi_dma_restore_regs

        ori.b   #SSI_DMA_RECORD_SELECT,d2
        move.b  d2,SSI_DMA_CONTROL
        lea     ssi_dma_old_record_base,a0
        bsr     ssi_dma_restore_regs

        move.b  ssi_dma_old_int_control,SSI_DMA_INT_CONTROL
        move.w  ssi_dma_old_mode,SSI_DMA_MODE
        move.b  ssi_dma_old_control,SSI_DMA_CONTROL

        move.w  ssi_dma_old_xbar_source,SSI_XBAR_SOURCE
        move.w  ssi_dma_old_xbar_destination,SSI_XBAR_DESTINATION
        lea     ssi_dma_old_xbar_bytes,a0
        move.b  (a0)+,SSI_XBAR_EXT_DIVIDER
        move.b  (a0)+,SSI_XBAR_INT_DIVIDER
        move.b  (a0)+,SSI_XBAR_RECORD_TRACKS
        move.b  (a0)+,SSI_XBAR_CODEC_INPUT
        move.b  (a0)+,SSI_XBAR_ADC_INPUT
        move.b  (a0)+,SSI_XBAR_INPUT_GAIN
        move.b  (a0)+,SSI_XBAR_OUTPUT_ATTEN

        moveq   #0,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; a0 = three-byte base, three-byte count, three-byte end sources
ssi_dma_restore_regs:
        move.b  (a0)+,SSI_DMA_BASE_HI
        move.b  (a0)+,SSI_DMA_BASE_MID
        move.b  (a0)+,SSI_DMA_BASE_LO
        addq.l  #3,a0
        move.b  (a0)+,SSI_DMA_END_HI
        move.b  (a0)+,SSI_DMA_END_MID
        move.b  (a0)+,SSI_DMA_END_LO
        rts

        bss

ssi_dma_owned:
        ds.l    1
ssi_dma_running:
        ds.l    1
ssi_dma_buffer_start:
        ds.l    1
ssi_dma_buffer_end:
        ds.l    1
ssi_dma_old_xbar_source:
        ds.w    1
ssi_dma_old_xbar_destination:
        ds.w    1
ssi_dma_old_xbar_bytes:
        ds.b    7
ssi_dma_old_int_control:
        ds.b    1
ssi_dma_old_control:
        ds.b    1
ssi_dma_old_mode:
        ds.w    1
ssi_dma_old_play_base:
        ds.b    9
ssi_dma_old_record_base:
        ds.b    9
ssi_dma_ptrs:
        ds.l    4
ssi_dma_route_status:
        ds.l    1
ssi_dma_completed_bytes:
        ds.l    1
ssi_dma_wait_ticks:
        ds.l    1
ssi_dma_cacr_image:
        ds.l    1
ssi_dma_xbios_results:
        ds.l    SSI_DMA_CLAIM_STAGES
ssi_dma_run_control:
        ds.w    1
ssi_dma_devconnect_source:
        ds.w    1
ssi_dma_devconnect_destination:
        ds.w    1
ssi_dma_armed_control:
        ds.b    1
ssi_dma_armed_int_control:
        ds.b    1
ssi_dma_armed_divider:
        ds.b    1
        ds.b    1
ssi_dma_armed_mode:
        ds.w    1
ssi_dma_armed_xbar_source:
        ds.w    1
ssi_dma_armed_xbar_destination:
        ds.w    1
ssi_dma_claim_stage:
        ds.l    1
ssi_dma_route_source:
        ds.w    1
ssi_dma_route_destination:
        ds.w    1
ssi_dma_shadow_active:
        ds.l    1
ssi_dma_shadow_start:
        ds.l    1
ssi_dma_shadow_ptr:
        ds.l    1
ssi_dma_shadow_capacity:
        ds.l    1
ssi_dma_shadow_frame_id:
        ds.l    1
ssi_dma_shadow_mesh_id:
        ds.w    1
ssi_dma_shadow_generation:
        ds.w    1
ssi_dma_shadow_words:
        ds.l    1
ssi_dma_shadow_records:
        ds.l    1
ssi_dma_shadow_actual_words:
        ds.l    1
ssi_dma_shadow_crc:
        ds.w    1
        even

ssi_dma_hatari_result:
        ds.l    1
ssi_dma_hatari_words:
        ds.l    1
ssi_dma_hatari_consumed_words:
        ds.l    1
ssi_dma_hatari_packets:
        ds.l    1
ssi_dma_hatari_rows:
        ds.l    1
ssi_dma_hatari_skips:
        ds.l    1
ssi_dma_hatari_shades:
        ds.l    1
ssi_dma_hatari_crc:
        ds.w    1
ssi_dma_hatari_expected_crc:
        ds.w    1
ssi_dma_hatari_error_stage:
        ds.l    1
ssi_dma_hatari_ptr:
        ds.l    1
ssi_dma_hatari_remaining:
        ds.l    1
ssi_dma_hatari_capacity:
        ds.w    1
ssi_dma_hatari_frame_hi:
        ds.w    1
ssi_dma_hatari_frame_lo:
        ds.w    1
        even
ssi_dma_hatari_packet_rows_remaining:
        ds.l    1
ssi_dma_hatari_packet_start:
        ds.l    SSI_DMA_HATARI_PACKET_CAPACITY
ssi_dma_hatari_packet_end:
        ds.l    SSI_DMA_HATARI_PACKET_CAPACITY
ssi_dma_hatari_packet_y:
        ds.l    SSI_DMA_HATARI_PACKET_CAPACITY
ssi_dma_hatari_packet_shades:
        ds.l    SSI_DMA_HATARI_PACKET_CAPACITY
ssi_dma_hatari_feed_callback:
        ds.l    1
ssi_dma_hatari_feed_x:
        ds.l    1
ssi_dma_hatari_feed_count:
        ds.l    1
ssi_dma_hatari_feed_u:
        ds.l    1
ssi_dma_hatari_feed_v:
        ds.l    1
ssi_dma_hatari_feed_y:
        ds.l    1
ssi_dma_hatari_feed_shade:
        ds.l    1

        end
