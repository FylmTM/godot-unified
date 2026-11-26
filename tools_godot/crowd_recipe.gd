class_name UnifiedCrowdRecipe
extends Resource
## What a crowd bake (UnifiedCrowdBake) makes of a character, and where the bake is kept: the character's scene, the
## clips its crowd plays in the order an instance names them, the materials whose parts are kept whole and marked, how
## far the rest is lightened, and the three files the bake writes. A game builds one in its tool scripts (its clip names
## are its constants) or keeps it as a `.tres`; the bake, its staleness hash and its check (UnifiedCrowdCheck) all read
## this one declaration. It is bake-time tooling: nothing a running game loads names it.

## The character: a scene whose root is a Node3D holding one Skeleton3D, its meshes skinned to it, props on
## BoneAttachment3Ds, and an AnimationPlayer with every clip.
@export_file("*.tscn", "*.scn") var scene := ""
## The clips, in the order an instance names them by index.
@export var clips: Array[UnifiedCrowdClip] = []
## Parts drawn with one of these materials are kept whole (never lightened) and marked in the bake's UV2.x by the
## material's index here plus one (0: unmarked), so a game's shader can draw each its own way (glowing eyes, a
## team-coloured cloak). A single masked material marks its parts 1.
@export var masked: Array[Material] = []
## How far each unmarked part is lightened: the coarsest of Godot's own LODs for it whose error is within this
## (relative to the part's size; the scene importer's simplifier). 0 keeps every triangle.
@export var max_error := 0.0
## The most triangles the bake may have (UnifiedCrowdCheck fails past it); 0: no limit.
@export var max_triangles := 0
## Where the bake is kept: the merged mesh (an ArrayMesh), the bone matrices (an Image) and the clip table
## (UnifiedCrowdClips, which refers to the Image's file).
@export_file("*.res", "*.tres") var mesh_path := ""
@export_file("*.res", "*.tres") var bones_path := ""
@export_file("*.tres", "*.res") var clips_path := ""
## How the character is posed, `func(rig: Node3D, clip: StringName, seconds: float)`, as the game's views pose it
## (a loop wrapped, a one-shot held at its ends). Empty: its AnimationPlayer, seeked so. Set in code: a Callable is not
## saved with the resource.
var pose := Callable()


## The clips' animation names, in order (UnifiedCrowdClips.clips).
func names() -> Array[StringName]:
	var out: Array[StringName] = []
	for clip in clips:
		out.append(clip.animation if clip != null else &"")
	return out


## What the bake is made from, as text (UnifiedCrowdBake.inputs): everything but where the bake is kept and how it is
## posed (a pose that changes is caught by the check's bake now).
func describe() -> String:
	var described: Array = []
	for clip in clips:
		described.append([clip.animation, clip.rate, clip.loop] if clip != null else [])
	var masks: PackedStringArray = []
	for material in masked:
		masks.append(material.resource_path if material != null else "")
	return var_to_str([scene, described, masks, max_error])
