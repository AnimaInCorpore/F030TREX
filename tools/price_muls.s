; Price one register-form MULS.L under an emulator profile.
; Loop A runs the old prestep channel without its multiply, loop B with it;
; both run 1,048,576 times from the instruction cache.  Result file: three
; big-endian longwords, 200 Hz ticks for A, for B, and the iteration count.
ITER_OUTER = 16
	section text,code
start:
	clr.l	-(sp)
	move.w	#$20,-(sp)		; Super
	trap	#1
	addq.l	#6,sp

	move.l	#12345,a0		; du/dx
	move.l	#2047,d2		; fraction
	moveq	#0,d5

	move.l	$4ba.w,d6
.sync_a	cmp.l	$4ba.w,d6		; start on a tick edge
	beq	.sync_a
	move.l	$4ba.w,d6
	moveq	#ITER_OUTER-1,d7
.outer_a
	moveq	#-1,d3
.loop_a
	move.l	a0,d4
	asr.l	#8,d4
	asr.l	#4,d4
	add.l	d4,d5
	dbra	d3,.loop_a
	dbra	d7,.outer_a
	move.l	$4ba.w,d0
	sub.l	d6,d0
	move.l	d0,result

	move.l	$4ba.w,d6
.sync_b	cmp.l	$4ba.w,d6
	beq	.sync_b
	move.l	$4ba.w,d6
	moveq	#ITER_OUTER-1,d7
.outer_b
	moveq	#-1,d3
.loop_b
	move.l	a0,d4
	muls.l	d2,d4
	asr.l	#8,d4
	asr.l	#4,d4
	add.l	d4,d5
	dbra	d3,.loop_b
	dbra	d7,.outer_b
	move.l	$4ba.w,d0
	sub.l	d6,d0
	move.l	d0,result+4
	move.l	#ITER_OUTER*65536,result+8

	clr.w	-(sp)
	pea	name
	move.w	#$3c,-(sp)		; Fcreate
	trap	#1
	addq.l	#8,sp
	move.w	d0,d7
	pea	result
	move.l	#12,-(sp)
	move.w	d7,-(sp)
	move.w	#$40,-(sp)		; Fwrite
	trap	#1
	lea	12(sp),sp
	move.w	d7,-(sp)
	move.w	#$3e,-(sp)		; Fclose
	trap	#1
	addq.l	#4,sp
	clr.w	-(sp)
	trap	#1

	section data,data
name:	dc.b	'MULPRICE.RES',0
	even
	section bss,bss
result:	ds.l	3
