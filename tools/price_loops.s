; Time short 68030 loops under an emulator profile (OPTIMIZATION.md 3.19).
; Each loop body runs INNER*OUTER times from the instruction cache; the
; pointers are reset per outer pass.  Result file PRICELPS.RES: the number
; of loops, the iteration count, then the 200 Hz ticks of each loop, all
; big-endian longwords.  Compare with tools/m68030_cc.py.
INNER = 256
OUTER = 8192
NLOOPS = 9
	section text,code
start:
	clr.l	-(sp)
	move.w	#$20,-(sp)		; Super
	trap	#1
	addq.l	#6,sp

	; stream of absolute offsets i*257, and of deltas 257
	lea	stream,a0
	lea	deltas,a1
	moveq	#0,d0
	move.w	#INNER-1,d7
.fill	move.w	d0,(a0)+
	move.w	#257,(a1)+
	add.w	#257,d0
	dbra	d7,.fill

	lea	result+8,a6
	move.l	a6,resptr
	move.l	#NLOOPS,result
	move.l	#INNER*OUTER,result+4

	lea	loop_table,a3
	moveq	#NLOOPS-1,d7
.next	move.l	(a3)+,a2
	movem.l	d7/a3,-(sp)
	move.l	$4ba.w,d6
.sync	cmp.l	$4ba.w,d6		; start on a tick edge
	beq	.sync
	move.l	$4ba.w,d6
	move.l	d6,tick0
	jsr	(a2)
	move.l	$4ba.w,d0
	sub.l	tick0,d0
	move.l	resptr,a6
	move.l	d0,(a6)+
	move.l	a6,resptr
	movem.l	(sp)+,d7/a3
	dbra	d7,.next

	clr.w	-(sp)
	pea	name
	move.w	#$3c,-(sp)		; Fcreate
	trap	#1
	addq.l	#8,sp
	move.w	d0,d7
	pea	result
	move.l	#8+4*NLOOPS,-(sp)
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

; Common set-up: A5 texture, A6 CLUT, D0/D1 zero-extended.
setup	macro
	lea	texture,a5
	lea	clut,a6
	moveq	#0,d0
	moveq	#0,d1
	move.w	#OUTER-1,d5
	endm

; 0: DBRA alone
loop_dbra
	move.w	#OUTER-1,d5
.o	move.w	#INNER-1,d4
.i	dbra	d4,.i
	dbra	d5,.o
	rts

; 1: MULS.L Dn,Dn
loop_muls
	move.l	#12345,d2
	move.w	#OUTER-1,d5
.o	move.w	#INNER-1,d4
.i	move.l	#2047,d3
	muls.l	d2,d3
	dbra	d4,.i
	dbra	d5,.o
	rts

; 2: the same without MULS.L (control for 1)
loop_movel
	move.l	#12345,d2
	move.w	#OUTER-1,d5
.o	move.w	#INNER-1,d4
.i	move.l	#2047,d3
	dbra	d4,.i
	dbra	d5,.o
	rts

; 3: LSR.W #8 and two register moves
loop_regs
	move.w	#OUTER-1,d5
.o	move.w	#INNER-1,d4
.i	move.w	d6,d1
	move.w	d5,d0
	lsr.w	#8,d0
	move.b	d0,d1
	dbra	d4,.i
	dbra	d5,.o
	rts

; 4: span_stream_draw's pixel loop (absolute offset, indexed texel)
loop_stream
	setup
.o	lea	stream,a1
	lea	frame,a4
	move.w	#INNER-1,d4
.i	move.w	(a1)+,d1
	move.b	(0,a5,d1.l),d0
	move.w	(0,a6,d0.l*2),(a4)+
	dbra	d4,.i
	dbra	d5,.o
	rts

; 5: the delta form (ADDA.W, texel through (An))
loop_delta
	moveq	#0,d0
	lea	clut,a6
	move.w	#OUTER-1,d5
.o	lea	deltas,a1
	lea	frame,a4
	lea	texture-257,a5
	move.w	#INNER-1,d4
.i	adda.w	(a1)+,a5
	move.b	(a5),d0
	move.w	(0,a6,d0.l*2),(a4)+
	dbra	d4,.i
	dbra	d5,.o
	rts

; 6: span_walk_half's record pixel loop
loop_record
	setup
	move.l	#$100,a0
	move.l	#$100,a1
.o	lea	frame,a4
	moveq	#0,d6
	moveq	#0,d7
	move.w	#INNER-1,d4
.i	move.w	d7,d1
	move.w	d6,d0
	lsr.w	#8,d0
	move.b	d0,d1
	move.b	(0,a5,d1.l),d0
	move.w	(0,a6,d0.l*2),(a4)+
	add.l	a0,d6
	add.l	a1,d7
	dbra	d4,.i
	dbra	d5,.o
	rts

; 7: the same with both ADD.L before the store (store meets DBRA's head)
loop_record2
	setup
	move.l	#$100,a0
	move.l	#$100,a1
.o	lea	frame,a4
	moveq	#0,d6
	moveq	#0,d7
	move.w	#INNER-1,d4
.i	move.w	d7,d1
	move.w	d6,d0
	lsr.w	#8,d0
	move.b	d0,d1
	move.b	(0,a5,d1.l),d0
	add.l	a0,d6
	add.l	a1,d7
	move.w	(0,a6,d0.l*2),(a4)+
	dbra	d4,.i
	dbra	d5,.o
	rts

; 8: flat span store
loop_flat
	move.w	#$1234,d2
	move.w	#OUTER-1,d5
.o	lea	frame,a4
	move.w	#INNER-1,d4
.i	move.w	d2,(a4)+
	dbra	d4,.i
	dbra	d5,.o
	rts

	section data,data
loop_table
	dc.l	loop_dbra,loop_muls,loop_movel,loop_regs,loop_stream
	dc.l	loop_delta,loop_record,loop_record2,loop_flat
name:	dc.b	'PRICELPS.RES',0
	even
	section bss,bss
resptr	ds.l	1
tick0	ds.l	1
result	ds.l	2+NLOOPS
stream	ds.w	INNER
deltas	ds.w	INNER
clut	ds.w	256
frame	ds.w	INNER
	ds.b	512
texture	ds.b	65536+1024
