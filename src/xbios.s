; XBIOS 	macro definitions (c) 1994 by Sascha Springer

	macro	Gettime
	move	#23,-(a7)
	trap	#14
	addq	#2,a7
	endm

	macro	Logbase
	move	#3,-(a7)
	trap	#14
	addq	#2,a7
	endm

	macro	Physbase
	move	#2,-(a7)
	trap	#14
	addq	#2,a7
	endm

	macro	Setscreen
	move	\3,-(a7)
	pea		\2
	pea		\1
	move	#5,-(a7)
	trap	#14
	lea		12(a7),a7
	endm

	macro	Vsync
	move	#37,-(a7)
	trap	#14
	addq	#2,a7
	endm

; Falcon

	macro	Montype
	move	#89,-(a7)
	trap	#14
	addq	#2,a7
	endm

	macro	Vsetmode
	move	\1,-(a7)
	move	#88,-(a7)
	trap	#14
	addq	#4,a7
	endm

	macro	VsetScreen
	move	\4,-(a7)
	move	\3,-(a7)
	move.l	\2,-(a7)
	move.l	\1,-(a7)
	move	#5,-(a7)
	trap	#14
	lea	14(a7),a7
	endm

	macro	Dsp_Available
	pea		\2
	pea		\1
	move	#106,-(a7)
	trap	#14
	lea		10(a7),a7
	endm

	macro	Dsp_Lock
	move	#104,-(a7)
	trap	#14
	addq	#2,a7
	endm

	macro	Dsp_Unlock
	move	#105,-(a7)
	trap	#14
	addq	#2,a7
	endm

	macro	Dsp_Reserve
	move.l	\2,-(sp)
	move.l	\1,-(sp)
	move	#107,-(sp)
	trap	#14
	lea		10(sp),sp
	endm

	macro	Dsp_LoadProgram
	pea		\3
	move	\2,-(sp)
	pea		\1
	move	#108,-(sp)
	trap	#14
	lea		12(sp),sp
	endm

	macro	Dsp_ExecProg
	move	\3,-(sp)
	move	\2,-(sp)
	pea		\1
	move	#109,-(sp)
	trap	#14
	lea		12(sp),sp
	endm

	macro	Dsp_LodToBinary
	pea		\2,-(sp)
	pea		\1,-(sp)
	move	#111,-(sp)
	trap	#14
	lea		10(sp),sp
	endm

	macro	Dsp_BlkUnpacked
	move.l	\4,-(sp)
	pea		\3
	move.l	\2,-(sp)
	pea		\1
	move	#98,-(sp)
	trap	#14
	lea		$12(sp),sp
	endm
