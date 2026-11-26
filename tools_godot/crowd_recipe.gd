class_name UnifiedCrowdRecipe
extends Resource
## What a crowd bake (UnifiedCrowdBake) makes of a character, and where the bake is kept: the character's scene, the
## clips its crowd plays in the order an instance names them, which loop, the rate each is baked at, how far its meshes
## are lightened, and the three files the bake writes. A game builds one in code (its clip names are its constants) or
## keeps it as a `.tres`; the bake, its staleness hash and its checks (UnifiedCrowdCheck) all read this one declaration.

## The frames a second a clip is baked at when `rates` is empty: a model's usual key rate.
const DEFAULT_RATE := 30.0

## The character: a scene whose root is a Node3D holding one Skeleton3D, its meshes skinned to it, props on
## BoneAttachment3Ds, and an AnimationPlayer with every clip.
@export_file("*.tscn", "*.scn") var scene := ""
## The clips, as the AnimationPlayer names them (`Library/Clip`), in the order an instance names them by index.
@export var clips: Array[StringName] = []
## The clips that loop: they wrap, and their last frame must be their first pose again. The rest are one-shots, which
## hold their first frame before their start and their last past their end.
@export var loops: Array[StringName] = []
## Per clip, the frames a second it is baked at (empty: DEFAULT_RATE each). A clip's length must be a whole number of
## its frames. The shader blends two frames' matrices linearly where the scene turns each bone along an arc, so a clip
## whose bones turn fast between keys is baked at a multiple of its keys' rate.
@export var rates: PackedFloat32Array = []
## Meshes drawn with one of these materials are marked in the bake's UV2.x (1, else 0) and never lightened: the small
## parts a crowd is read by (glowing eyes), which the game's shader draws its own way.
@export var masked: Array[Material] = []
## How far each mesh but the masked ones is lightened: the coarsest of Godot's own LODs for it whose error is within
## this (relative to the mesh's size; UnifiedCrowdBake.lighten). 0 keeps every triangle.
@export var max_error := 0.0
## The most triangles the bake may have (UnifiedCrowdCheck fails past it); 0: no limit.
@export var max_triangles := 0
## The method on the scene's root that poses it, `(clip: StringName, seconds: float)`, wrapping loops and holding a
## one-shot's ends as the game's views do. Empty: the AnimationPlayer poses it so (UnifiedCrowdBake.posing).
@export var pose_method: StringName = &""
## Where the bake is kept: the merged mesh (an ArrayMesh), the bone matrices (an Image) and the clip table
## (UnifiedCrowdClips, which refers to the Image's file).
@export_file("*.res", "*.tres") var mesh_path := ""
@export_file("*.res", "*.tres") var bones_path := ""
@export_file("*.tres", "*.res") var clips_path := ""


## The frames a second clip `clip_index` is baked at.
func rate(clip_index: int) -> float:
	return DEFAULT_RATE if rates.is_empty() else rates[clip_index]


## What the bake is made from, as text (UnifiedCrowdBake.inputs_hash): everything but where the bake is kept.
func describe() -> String:
	var looping: Array[StringName] = []
	for clip in clips:
		if clip in loops:
			looping.append(clip)
	var baked_rates := PackedFloat32Array()
	for clip_index in clips.size():
		baked_rates.append(rate(clip_index))
	var masks: PackedStringArray = []
	for material in masked:
		masks.append(material.resource_path if material != null else "")
	return var_to_str([scene, clips, looping, baked_rates, masks, max_error, pose_method])
