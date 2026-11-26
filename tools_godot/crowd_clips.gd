class_name UnifiedCrowdClips
extends Resource
## A crowd's baked clips (UnifiedCrowdBake): the bone matrices of every frame of each clip in one RGBA float Image, and
## what is known of each clip by name. The crowd's shader skins from the Image alone (crowd_skin.gdshaderinc), so its
## material needs one texture (apply) and no table of uniforms, and a crowd takes as many clips as the Image is wide.
##
## The Image: row 0 is the header, texel 0 `(clips, bones, 0, 0)` and texel 1 + c clip c's `(first row, frames,
## frames a second, loops 0 or 1)`; then a row per frame, TEXELS_PER_BONE texels per bone, the three rows of its 3x4
## skinning matrix (the bone's pose in the character's space times its bind: what Godot skins by). A clip's frames are
## 0 to its length at its rate, both ends included: a looping clip's last frame is its first pose again, so a blend never
## wraps. A pose is a clip and the seconds into it: a loop wraps, a one-shot holds its first frame before its start and
## its last past its end, and between two frames the matrices blend entry by entry (matrices, the shader's twin).
##
## A running game loads this table (its `apply`, `index`, `tops`) and its shader the skinning include: both are
## runtime files, unlike the rest of tools_godot.

## The texels a bone takes in a row.
const TEXELS_PER_BONE := 3
## The header's rows, before the first frame's.
const HEADER_ROWS := 1
## The shader parameter apply() sets: the include's uniform.
const BONES_PARAMETER := &"unified_crowd_bones"

## The matrices and their header (above), RGBA float.
@export var bones: Image
## The clips, as the character's AnimationPlayer names them, in the order an instance names them by index.
@export var clips: Array[StringName] = []
## Per clip: the height of its last pose's highest point in the mesh's space (how deep a sink must go to hide the end of
## a one-shot, say).
@export var tops: PackedFloat32Array = []
## Every pose's bounds in the crowd mesh's space (a MultiMesh's culling: the mesh's custom_aabb is these).
@export var bounds: AABB
## What the bake was made from (UnifiedCrowdBake.inputs_hash), so a check can tell it is stale.
@export var sources := ""


## The index of `clip` (an instance's clip number), or -1.
func index(clip: StringName) -> int:
	return clips.find(clip)


## The skeleton's bones, as the header says.
func bone_count() -> int:
	return int(bones.get_pixel(0, 0).g)


## Clip `clip_index`'s first frame's row in `bones`.
func first_row(clip_index: int) -> int:
	return int(_clip_texel(clip_index).r)


## Clip `clip_index`'s frames (its length times its rate, plus one).
func frame_count(clip_index: int) -> int:
	return int(_clip_texel(clip_index).g)


## The frames a second clip `clip_index` is baked at.
func rate(clip_index: int) -> float:
	return _clip_texel(clip_index).b


## Whether clip `clip_index` loops.
func loops(clip_index: int) -> bool:
	return _clip_texel(clip_index).a > 0.5


## Clip `clip_index`'s length in seconds, as baked.
func length(clip_index: int) -> float:
	return float(frame_count(clip_index) - 1) / rate(clip_index)


## A new texture of `bones`, for a crowd material.
func texture() -> ImageTexture:
	return ImageTexture.create_from_image(bones)


## Sets what a crowd material's shader (one including crowd_skin.gdshaderinc) skins by: its bone texture.
func apply(material: ShaderMaterial) -> void:
	material.set_shader_parameter(BONES_PARAMETER, texture())


## Every bone's skinning matrix in clip `clip_index` at `seconds` into it, blended between its two frames: what the
## shader computes, on the CPU.
func matrices(clip_index: int, seconds: float) -> Array[Transform3D]:
	var frames := frame_count(clip_index)
	var clip_length := length(clip_index)
	var held := fposmod(seconds, clip_length) if loops(clip_index) else clampf(seconds, 0.0, clip_length)
	var at := held * rate(clip_index)
	var frame := clampi(floori(at), 0, frames - 2)
	var weight := at - frame
	var row := first_row(clip_index) + frame
	var out: Array[Transform3D] = []
	for bone in bone_count():
		out.append(blend(frame_matrix(row, bone), frame_matrix(row + 1, bone), weight))
	return out


## Bone `bone`'s matrix in row `row` of `bones`, as baked.
func frame_matrix(row: int, bone: int) -> Transform3D:
	var x := bone * TEXELS_PER_BONE
	var r0 := bones.get_pixel(x, row)
	var r1 := bones.get_pixel(x + 1, row)
	var r2 := bones.get_pixel(x + 2, row)
	return Transform3D(
		Basis(Vector3(r0.r, r1.r, r2.r), Vector3(r0.g, r1.g, r2.g), Vector3(r0.b, r1.b, r2.b)), Vector3(r0.a, r1.a, r2.a)
	)


## Two matrices blended entry by entry, as the shader blends two frames (not along an arc).
static func blend(a: Transform3D, b: Transform3D, weight: float) -> Transform3D:
	return Transform3D(
		Basis(a.basis.x.lerp(b.basis.x, weight), a.basis.y.lerp(b.basis.y, weight), a.basis.z.lerp(b.basis.z, weight)),
		a.origin.lerp(b.origin, weight)
	)


func _clip_texel(clip_index: int) -> Color:
	return bones.get_pixel(1 + clip_index, 0)
