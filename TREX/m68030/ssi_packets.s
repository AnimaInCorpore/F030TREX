	macro SsiPacketCrcUnit
	move.w \1,d6
	eor.w d0,d6
	move.w (a3,d6.l*2),d0
	endm

; SSIPROBE=2 / TREX_SSI_PIPELINE. All callers run in supervisor mode.
; phase 0 idle, 1 FINISH pending, 2 BUILD pending, 3 DMA owns chunk,
; 4 next packet page ready, -1 failed. Service is called between packets;
; D7/A2/A3 are the only live OT-walker registers and are preserved.
; A DMA window is read only after pointer AND record-stop completion and
; data-cache invalidation. Only a fully validated chunk enters the unpacker.
SSI_PACKET_UNITS = 16+DSP_TRIANGLE_CHUNK*DSP_SPAN_RECORD_WORDS*3/2
SSI_PACKET_TIMEOUT = 400
	ifd TREX_PREPASS
	fail "SSI packet image has no occlusion prepass; use the host-port target"
	endc

ssi_packets_init
	move.l #gpu_packet_buffer,ssi_render_packets
	move.l #gpu_packet_buffer,ssi_build_packets
	tst.l ssi_force_pio
	bne .init_done
	tst.l dsp_program_loaded
	beq .init_done
	lea ssi_packet_dma_a,a0
	lea SSI_PACKET_UNITS*2(a0),a1
	jsr ssi_dma_claim
	move.l d0,ssi_claim_result
	tst.l d0
	bne .init_done
	move.l #1,ssi_packets_enabled
.init_done
	bsr ssi_packets_write_status
	rts

; D0 = identity of the animation just submitted to FINISH.
ssi_packets_queue
	tst.l ssi_packets_enabled
	beq .queue_done
	tst.l ssi_packet_phase
	bne .queue_done
	move.l d0,ssi_packet_frame
	move.l #1,ssi_packet_phase
	move.l #1,ssi_reply_waiting
	move.l $4ba.w,ssi_packet_deadline
.queue_done
	rts

ssi_packets_wait_frame
.wait
	bsr ssi_packets_service
	cmpi.l #4,ssi_packet_phase
	beq .ready
	tst.l ssi_packets_enabled
	bne .wait
	moveq #0,d0
	rts
.ready
	move.l ssi_build_packets,ssi_render_packets
	cmpi.l #gpu_packet_buffer,ssi_build_packets
	bne .page_a
	move.l #ssi_packet_page_b+15,d0
	andi.l #$fffffff0,d0
	move.l d0,ssi_build_packets
	bra .swapped
.page_a
	move.l #gpu_packet_buffer,ssi_build_packets
.swapped
	clr.l ssi_packet_phase
	moveq #1,d0
	rts

ssi_packets_service
	tst.l ssi_packets_enabled
	beq .service_done
	movem.l d7/a2-a3,-(sp)
.service_again
	move.l ssi_packet_phase,d0
	beq .service_return
	cmpi.l #4,d0
	beq .service_return
	move.l $4ba.w,d1
	sub.l ssi_packet_deadline,d1
	cmpi.l #SSI_PACKET_TIMEOUT,d1
	bcc .service_failed
	cmpi.l #3,d0
	beq .dma_pending
	btst.b #DSP_HOST_ISR_RXDF,DSP_HOST_ISR
	beq .service_return
	cmpi.l #1,d0
	bne .build_pending
	bsr ssi_packet_read_pair
	tst.l d0
	beq .service_failed
	cmpi.l #DSP_ACK_FRAME,dsp_rx_buffer
	bne .service_failed
	clr.l dsp_animation_inflight
	move.l #1,ssi_projection_ready
	move.l dsp_rx_buffer+4,dsp_vertex_count_shadow
	addq.l #1,dsp_frame_upload_count
	move.l #1,dsp_direct_frame
	move.l ssi_build_packets,a1
	lea 16(a1),a1
	move.l a1,dsp_triangle_output_ptr
	clr.l dsp_triangle_output_count
	clr.l dsp_triangle_input_count
	move.l #TREX_PRIMITIVES,dsp_triangles_remaining
	bsr dsp_send_build_chunk
	move.l #1,ssi_reply_waiting
	move.l #2,ssi_packet_phase
	move.l $4ba.w,ssi_packet_deadline
	bra .service_return
.build_pending
	bsr ssi_packet_read_pair
	tst.l d0
	beq .service_failed
	cmpi.l #DSP_ACK_TRIANGLES,dsp_rx_buffer
	bne .service_failed
	move.l dsp_rx_buffer+4,d0
	cmp.l dsp_triangle_chunk_count,d0
	bhi .service_failed
	move.l d0,dsp_triangle_chunk_survivors
	tst.l d0
	beq .chunk_received
	; DMA window A/B changes generation only after its previous reader left.
	addq.w #1,ssi_packet_generation
	move.l #ssi_packet_dma_a,a0
	btst #0,ssi_packet_generation+1
	beq .dma_selected
	lea ssi_packet_dma_b,a0
.dma_selected
	move.l a0,ssi_packet_buffer
	mulu.w #27,d0
	add.l #16,d0
	move.l d0,ssi_packet_units
	add.l d0,d0
	lea (a0,d0.l),a1
	jsr ssi_dma_arm_record
	tst.l d0
	bne .service_failed
	ifnd TREX_RELEASE
	cmpi.l #3,ssi_packet_inject_fault
	bne .arm_kept
	clr.l ssi_packet_inject_fault
	jsr ssi_dma_stop
.arm_kept
	endc
	lea ssi_packet_command,a0
	move.l #$44,(a0)+
	move.l ssi_packet_frame,d0
	swap d0
	andi.l #$ffff,d0
	move.l d0,(a0)+
	move.l ssi_packet_frame,d0
	andi.l #$ffff,d0
	move.l d0,(a0)+
	moveq #0,d0
	move.w ssi_packet_generation,d0
	move.l d0,(a0)
	Dsp_BlkUnpacked ssi_packet_command,#4,dsp_rx_buffer,#0
	move.l #1,ssi_reply_waiting
	move.l #3,ssi_packet_phase
	move.l $4ba.w,ssi_packet_deadline
	bra .service_return
.dma_pending
	jsr ssi_dma_poll_record
	tst.l d0
	bne .service_return
	jsr ssi_dma_stop
	jsr ssi_dma_invalidate_dcache
	bsr ssi_packet_read_pair
	tst.l d0
	beq .service_failed
	cmpi.l #$700044,dsp_rx_buffer
	bne .service_failed
	tst.l dsp_rx_buffer+4
	bne .service_failed
	ifnd TREX_RELEASE
	move.l ssi_packet_inject_fault,d0
	beq .received_intact
	clr.l ssi_packet_inject_fault
	move.l ssi_packet_buffer,a0
	cmpi.l #2,d0
	beq .inject_identity
	move.l ssi_packet_units,d0
	add.l d0,d0
	eori.w #1,-2(a0,d0.l)
	bra .received_intact
.inject_identity
	eori.l #1,4(a0)
.received_intact
	endc
	bsr ssi_packet_validate
	tst.l d0
	beq .validation_failed
	addq.l #1,ssi_packet_chunks
	move.l ssi_packet_units,d0
	add.l d0,ssi_packet_received_units
	bra .unpack
.chunk_received
	bsr ssi_packet_launch_next

.unpack
	bsr ssi_packet_unpack_chunk
	bra .service_again
.validation_failed
	cmpi.l #3,ssi_packet_phase
	beq .service_failed
	; Next BUILD may be running; snapshot only the completed DMA window.
	move.l ssi_packet_phase,-(sp)
	move.l #3,ssi_packet_phase
	bsr ssi_packets_dump_failure
	move.l (sp)+,ssi_packet_phase
.service_failed
	jsr ssi_dma_stop
	jsr ssi_dma_invalidate_dcache
	bsr ssi_packets_dump_failure
	; Stop the owned channel before dropping any page. A pending SSI command
	; has a bounded DSP TDE wait; consume its result before issuing PIO again.
	move.l ssi_packet_phase,ssi_packet_failed_phase
	jsr ssi_dma_stop
	tst.l ssi_reply_waiting
	beq .reply_drained
	bsr ssi_packet_read_pair
	tst.l d0
	bne .reply_drained
	; No safe command boundary remains: disable DSP use rather than enter
	; an unbounded legacy read against an absent reply.
	clr.l dsp_triangle_stream_ready
	clr.l dsp_program_loaded
	clr.l dsp_animation_inflight
.reply_drained
	cmpi.l #1,ssi_packet_phase
	bne .have_projection
	cmpi.l #DSP_ACK_FRAME,dsp_rx_buffer
	bne .have_projection
	clr.l dsp_animation_inflight
	move.l #1,ssi_projection_ready
.have_projection
	clr.l ssi_packets_enabled
	clr.l dsp_pipeline_active
	move.l #-1,ssi_packet_phase
	addq.l #1,ssi_packet_failures
	jsr ssi_dma_release
.service_return
	movem.l (sp)+,d7/a2-a3
.service_done
	rts

; Only called when the first word is ready, or on bounded error recovery.
ssi_packet_read_pair
	lea dsp_rx_buffer,a1
	moveq #1,d2
	move.l $4ba.w,d3
.word
	btst.b #DSP_HOST_ISR_RXDF,DSP_HOST_ISR
	bne .received
	move.l $4ba.w,d0
	sub.l d3,d0
	cmpi.l #SSI_PACKET_TIMEOUT,d0
	bcs .word
	moveq #0,d0
	rts
.received
	move.l DSP_HOST_DATA,(a1)+
	dbra d2,.word
	clr.l ssi_reply_waiting
	moveq #1,d0
	rts

ssi_packet_launch_next
	move.l dsp_triangle_input_count,d0
	move.l d0,dsp_triangle_unpack_base
	add.l dsp_triangle_chunk_count,d0
	move.l d0,dsp_triangle_input_count
	tst.l dsp_triangles_remaining
	beq .no_next_chunk
	bsr dsp_send_build_chunk
	move.l #1,ssi_reply_waiting
	move.l #2,ssi_packet_phase
	move.l $4ba.w,ssi_packet_deadline
	rts
.no_next_chunk
	move.l #4,ssi_packet_phase	rts

ssi_packet_unpack_chunk
	DspUnpackChunk .empty
.empty
	rts

; Envelope, stopped-DMA length, IDs, count and CRC gate precede
; every write to the packet page. CRC is table-driven, not a bit loop.
ssi_packet_validate
	move.l ssi_packet_buffer,a0
	cmpi.w #$5353,(a0)
	bne .bad
	cmpi.w #$0102,2(a0)
	bne .bad
	move.l ssi_packet_frame,d0
	cmp.l 4(a0),d0
	bne .bad
	move.l dsp_triangle_input_count,d0
	cmp.w 8(a0),d0
	bne .bad
	move.w ssi_packet_generation,d0
	cmp.w 10(a0),d0
	bne .bad
	move.l ssi_packet_units,d0
	cmp.l 12(a0),d0
	bne .bad
	add.l d0,d0
	cmp.l ssi_dma_completed_bytes,d0
	bne .bad
	lea -16(a0,d0.l),a1
	cmpi.w #$5aa5,(a1)
	bne .bad
	tst.w 2(a1)
	bne .bad
	move.l ssi_packet_frame,d1
	cmp.l 4(a1),d1
	bne .bad
	move.l dsp_triangle_chunk_survivors,d1
	cmp.w 8(a1),d1
	bne .bad
	move.l ssi_packet_units,d1
	cmp.l 10(a1),d1
	bne .bad
	move.w 14(a1),ssi_packet_expected_crc
	; Launch next BUILD at the proven command boundary, before CRC/expansion.
	; CRC rejection drains that BUILD ack and discards the private packet page.
	bsr ssi_packet_launch_next
	move.l ssi_packet_buffer,a0
	; Single read of each received unit: CRC and RX expansion share registers.
	; No packet-page write is allowed until the final CRC compare succeeds.
	move.w #$ffff,d0
	moveq #0,d6		; high index word stays zero for every scaled lookup
	lea ssi_packet_crc_word_table,a3
	moveq #7,d4
.header_crc
	moveq #0,d1
	move.w (a0)+,d1
	eor.w d0,d1
	move.w (a3,d1.l*2),d0
	dbra d4,.header_crc
	lea dsp_triangle_chunk_rx+8,a1
	move.l dsp_triangle_chunk_survivors,d4
	mulu.w #9,d4
	subq.w #1,d4
.payload_crc
	moveq #0,d1
	move.w (a0)+,d1
	SsiPacketCrcUnit d1
	lsl.l #8,d1
	moveq #0,d2
	move.w (a0)+,d2
	SsiPacketCrcUnit d2
	move.w d2,d3
	lsr.w #8,d2
	or.l d2,d1
	move.l d1,(a1)+
	moveq #0,d1
	move.b d3,d1
	swap d1
	move.w (a0)+,d1
	SsiPacketCrcUnit d1
	move.l d1,(a1)+
	dbra d4,.payload_crc
	moveq #6,d4
.footer_crc
	moveq #0,d1
	move.w (a0)+,d1
	eor.w d0,d1
	move.w (a3,d1.l*2),d0
	dbra d4,.footer_crc
	move.w d0,ssi_packet_actual_crc
	cmp.w ssi_packet_expected_crc,d0
	bne .bad
	moveq #1,d0
	rts
.bad
	moveq #0,d0
	rts

ssi_packets_shutdown
	tst.l ssi_packets_enabled
	beq .shutdown_done
	tst.l ssi_packet_phase
	beq .release
	bsr ssi_packets_wait_frame
.release
	jsr ssi_dma_release
	clr.l ssi_packets_enabled
	bsr ssi_packets_write_status
.shutdown_done
	rts

; Bring-up only: capture the rejected DMA window and independently retrieve
; the unchanged DSP chunk over PIO. A release with flushing off does neither.
ssi_packets_dump_failure
	tst.l stats_flush_enabled
	beq .dump_done
	cmpi.l #3,ssi_packet_phase
	bne .dump_done
	movem.l d0-d7/a0-a6,-(sp)
	Fcreate ssi_packet_capture_path,#0
	tst.w d0
	bmi .dump_pio
	move.w d0,d7
	move.l ssi_packet_buffer,-(sp)
	move.l ssi_packet_units,d0
	add.l d0,d0
	move.l d0,-(sp)
	move.w d7,-(sp)
	move.w #$40,-(sp)
	trap #1
	lea 12(sp),sp
	Fclose d7
.dump_pio
	; Only at a proven command boundary; a timeout must not enter XBIOS's
	; unbounded readback. The successful read_pair cleared this flag.
	tst.l ssi_reply_waiting
	bne .dump_return
	cmpi.l #$700044,dsp_rx_buffer
	bne .dump_return
	move.l #DSP_CMD_GET_TRIANGLES,dsp_control_tx
	move.l dsp_triangle_chunk_survivors,d3
	mulu.w #18,d3
	addq.l #2,d3
	Dsp_BlkUnpacked dsp_control_tx,#1,dsp_triangle_chunk_rx,d3
	Fcreate ssi_packet_pio_path,#0
	tst.w d0
	bmi .dump_return
	move.w d0,d7
	move.l dsp_triangle_chunk_survivors,d1
	mulu.w #72,d1
	addq.l #8,d1
	Fwrite d7,d1,dsp_triangle_chunk_rx
	Fclose d7
.dump_return
	movem.l (sp)+,d0-d7/a0-a6
.dump_done
	rts

ssi_packets_write_status
	ifd TREX_RELEASE
	rts
	else
	movem.l d0-d7/a0-a6,-(sp)
	Fcreate ssi_packet_status_path,#0
	tst.w d0
	bmi .status_done
	move.w d0,d7
	Fwrite d7,#48,ssi_packets_enabled
	Fclose d7
.status_done
	movem.l (sp)+,d0-d7/a0-a6
	rts

	endc
	section data,data
ssi_render_packets: dc.l 0
ssi_build_packets: dc.l 0
ssi_force_pio: dc.l 0
	ifnd TREX_RELEASE
ssi_packet_inject_fault: dc.l 0	; diagnostic only: 1 CRC, 2 identity, 3 stopped DMA
	endc
ssi_packet_status_path: dc.b 'ssi_pipe.res',0
ssi_packet_capture_path: dc.b 'ssi_pkt.res',0
ssi_packet_pio_path: dc.b 'ssi_pio.res',0
	even
ssi_packet_crc_table:
	include "TREX/m68030/ssi_crc_table.i"
	section bss,bss
ssi_packets_enabled: ds.l 1
ssi_packet_phase: ds.l 1
ssi_packet_frame: ds.l 1
ssi_packet_deadline: ds.l 1
ssi_projection_ready: ds.l 1
ssi_packet_buffer: ds.l 1
ssi_packet_units: ds.l 1
ssi_claim_result: ds.l 1
ssi_packet_failed_phase: ds.l 1
ssi_packet_failures: ds.l 1
ssi_packet_chunks: ds.l 1
ssi_packet_received_units: ds.l 1
ssi_packet_generation: ds.w 1
ssi_packet_expected_crc: ds.w 1
ssi_packet_actual_crc: ds.w 1
	even
ssi_reply_waiting: ds.l 1
ssi_packet_command: ds.l 4
ssi_packet_dma_a: ds.w SSI_PACKET_UNITS
ssi_packet_dma_b: ds.w SSI_PACKET_UNITS
ssi_packet_page_b: ds.b TREX_PRIMITIVES*GPU_PACKET_BYTES+16
	section text,code
