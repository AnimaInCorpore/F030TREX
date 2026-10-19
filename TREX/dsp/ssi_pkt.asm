; Live result-record transport, SSIPROBE=2 only. The normal GET_TRIANGLES
; command remains available for recovery. This command owns no persistent
; geometry state and runs only after BUILD has finished the entire chunk.
; Header/footer follow tools/ssi_framing_model.py, flags=2, mesh_id=chunk base.
; X:chunk_uvs[0..15] is dead until the next BUILD, and holds the envelope.
; No DSP pixel renderer or approximate field packing is introduced.
command_ssi_records
	move	#chunk_uvs,r0
	move	#>$5353,x0
	move	x0,x:(r0)+
	move	#>$0102,x0
	move	x0,x:(r0)+
	jsr	<receive_word
	move	x0,x:(r0)+		; frame high 16
	jsr	<receive_word
	move	x0,x:(r0)+		; frame low 16
	move	y:triangle_base,x0
	move	x0,x:(r0)+
	jsr	<receive_word
	move	x0,x:(r0)+		; generation
	clr	a
	move	a1,x:(r0)+
	move	y:triangle_out_count,a
	move	a1,x0
	rep	#3
	asl	a
	add	x0,a
	move	a1,x0
	asl	a
	add	x0,a			; 27 units per record
	move	#>16,x0
	add	x0,a
	move	a1,x:(r0)+		; capacity == exact transaction length
	move	#>$5aa5,x0
	move	x0,x:(r0)+
	clr	a
	move	a1,x:(r0)+		; footer status
	move	x:chunk_uvs+2,x0
	move	x0,x:(r0)+
	move	x:chunk_uvs+3,x0
	move	x0,x:(r0)+
	move	y:triangle_out_count,x0
	move	x0,x:(r0)+
	clr	a
	move	a1,x:(r0)+
	move	x:chunk_uvs+7,x0
	move	x0,x:(r0)

	move	#>SSI_TDE_SPIN,x0
	move	x0,y:ssi_spin
	clr	a
	move	a1,y:ssi_status
	move	#>$ffff00,x0
	move	x0,y:ssi_crc
	movep	#0,x:m_crb
	movep	#$4000,x:m_cra
	movep	#$0140,x:m_pcc
	movep	#$0020,x:m_pcddr
	movep	#$1a00,x:m_crb
	movep	#$0020,x:m_pcd
	move	#ssi_crc_table16,r4
	move	#ssi_crc_table8,r5
	move	#>32768,y1
	move	#chunk_uvs,r0
	do	#8,ssi_record_header_end
	move	x:(r0)+,a
	rep	#8
	lsl	a
	move	a1,x0
	jsr	<ssi_record_emit
	nop
ssi_record_header_end
	move	y:triangle_out_count,a
	tst	a
	jeq	<ssi_record_payload_end
	move	a1,x0
	rep	#3
	asl	a
	add	x0,a			; nine pairs of 24-bit words per record
	move	a1,x0
	move	#triangle_out,r0
	do	x0,ssi_record_payload_loop
	; Two full 24-bit words become three units, with no range assumptions.
	move	x:(r0)+,a
	move	a1,y:ssi_word
	move	#>$ffff00,y0
	and	y0,a
	move	a1,x0
	jsr	<ssi_record_emit
	move	y:ssi_word,x1
	mpy	x1,y1,a
	move	a0,y:ssi_word		; first word's low byte in bits 23..16
	move	x:(r0)+,x1
	move	x1,x:chunk_uvs+15		; envelope-dead temporary, full 24 bits
	mpy	x1,y1,a
	move	#>$ff00,y0
	and	y0,a
	move	a1,x1
	move	y:ssi_word,a
	or	x1,a
	move	a1,x0
	jsr	<ssi_record_emit
	move	x:chunk_uvs+15,a
	rep	#8
	lsl	a
	move	a1,x0
	jsr	<ssi_record_emit
	nop
ssi_record_payload_loop
ssi_record_payload_end
	move	#chunk_uvs+8,r0
	do	#7,ssi_record_footer_end
	move	x:(r0)+,a
	rep	#8
	lsl	a
	move	a1,x0
	jsr	<ssi_record_emit
	nop
ssi_record_footer_end
	move	y:ssi_crc,x0
	jsr	<ssi_send_word		; CRC excludes its own unit
	jsr	<ssi_wait_tde
	movep	#0,x:m_pcd
	movep	#0,x:m_crb
	movep	#0,x:m_pcddr
	movep	#0,x:m_pcc
	move	#>$700044,x0
	jsr	<send_word
	move	y:ssi_status,x0
	jsr	<send_word
	jmp	<main_loop

; X0 is the next 16-bit unit in bits 23..8. CRC-16/CCITT-FALSE,
; initial FFFF, using two word-update tables. The signed MPYs extract
; high/low bytes exactly after the FF masks, including bit-23-set input.
; Clobbers A, B, X1, Y0, N4/N5; preserves R0/LC, Y1 and transmitted X0.
ssi_record_emit
	move	y:ssi_crc,a
	eor	x0,a
	move	a1,x1
	move	#>128,y0
	mpy	x1,y0,a
	move	#>$ff,y0
	and	y0,a
	move	a1,n4
	mpy	x1,y1,b
	and	y0,b
	move	b1,n5
	move	x:(r4+n4),a
	move	x:(r5+n5),x1
	eor	x1,a
	move	a1,y:ssi_crc
	jsr	<ssi_send_word
	rts
