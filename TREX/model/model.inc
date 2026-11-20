; Mesh sizes of the model in this directory, for trex_m68030.s (found through
; the -I$(MODEL_DIR) include path, see the Makefile's MODEL_DIR). This one is
; the PS1 T-Rex; tools/blender_export_model.py writes the same file for any
; other Blender model.
TREX_VERTICES		= 1376		; TMD vertices
TREX_NORMALS		= 3610		; O3D (OBJ "vn") normals
TREX_PRIMITIVES		= 2724		; triangles
TREX_TMD_NORMALS	= 3610		; TMD corner-normal table
TMD_VERTEX_DATA_OFFSET	= $125d8	; TMD vertex block, file offset
TMD_NORMAL_DATA_OFFSET	= $150d8	; TMD normal block, file offset
MODEL_PS1_TREX		= 1		; the TANM choreography builds need this mesh
