; GEMDOS 	macro definitions (c) 1994 by Sascha Springer

	macro	Cauxin
	move	#3,-(a7)
	trap	#1
	addq	#2,a7
	endm

	macro	Cauxis
	move	#18,-(a7)
	trap	#1
	addq	#2,a7
	endm

	macro	Cauxos
	move	#19,-(a7)
	trap	#1
	addq	#2,a7
	endm

	macro	Cauxout
	move	\1,-(a7)
	move	#4,-(a7)
	trap	#1
	addq	#4,a7
	endm

	macro	Cconin
	move	#1,-(a7)
	trap	#1
	addq	#2,a7
	endm

	macro	Cconis
	move	#11,-(a7)
	trap	#1
	addq	#2,a7
	endm

	macro	Cconos
	move	#16,-(a7)
	trap	#1
	addq	#2,a7
	endm

	macro	Cconout
	move	\1,-(a7)
	move	#2,-(a7)
	trap	#1
	addq	#4,a7
	endm

	macro	Cconws
	pea		\1
	move	#9,-(a7)
	trap	#1
	addq	#6,a7
	endm

	macro	Cnecin
	move	#8,-(a7)
	trap	#1
	addq	#2,a7
	endm

	macro	Fclose
	move	\1,-(a7)
	move	#62,-(a7)
	trap	#1
	addq	#4,a7
	endm

	macro	Fcreate
	move	\2,-(a7)
	pea		\1
	move	#60,-(a7)
	trap	#1
	addq	#8,a7
	endm

	macro	Fopen
	move	\2,-(a7)
	pea		\1
	move	#61,-(a7)
	trap	#1
	addq	#8,a7
	endm

	macro	Fread
	pea		\3
	move.l	\2,-(a7)
	move	\1,-(a7)
	move	#63,-(a7)
	trap	#1
	lea		12(a7),a7
	endm

	macro	Fwrite
	pea		\3
	move.l	\2,-(a7)
	move	\1,-(a7)
	move	#64,-(a7)
	trap	#1
	lea		12(a7),a7
	endm

	macro	Malloc
	move.l	\1,-(a7)
	move	#72,-(a7)
	trap	#1
	addq	#6,a7
	endm

	macro	Mfree
	pea		\1
	move	#73,-(a7)
	trap	#1
	addq	#6,a7
	endm

	macro	Mshrink
	move.l	\2,-(a7)
	pea		\1
	clr		-(a7)
	move	#74,-(a7)
	trap	#1
	lea		12(a7),a7
	endm

	macro	Pterm0
	clr		-(a7)
	trap	#1
	endm

	macro	Pterm
	move	\1,-(a7)
	move	#76,-(a7)
	trap	#1
	endm

	macro	Ptermres
	move	\2,-(a7)
	move.l	\1,-(a7)
	move	#49,-(a7)
	trap	#1
	endm

	macro Super
	pea		\1
	move	#32,-(a7)
	trap	#1
	addq	#6,a7
	endm

