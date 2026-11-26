class_name UnifiedCrowdCheck
extends RefCounted
## Holds a crowd's committed bake (UnifiedCrowdBake, at its UnifiedCrowdRecipe's paths) fresh and true, for a game's
## checks (its validate step, say): `UnifiedCrowdCheck.new(recipe).check(root)`, then report `problems`.
##
## - **Whole:** the table's clips are the recipe's, its texture the table's size, the mesh one surface.
## - **Fresh:** the hash of its inputs is today's, its mesh is the scene merged and lightened as the bake does it now
##   (every array bit for bit, but the normals within `normal_tolerance`: a mesh stores them compressed), and a bake
##   now gives its matrices, bounds and tops within `fresh_tolerance`.
## - **Its rules:** within the recipe's max_triangles, each vertex's bones the skeleton's and its weights summing to 1,
##   each vertex masked as the scene mesh it comes from is, a masked recipe's mask kept.
## - **Parity** (parity): the bake's vertices skinned as the shader does, from the baked matrices, stand where the live
##   Skeleton3D puts them, within `parity_tolerance`, at any time in any clip.

## How far a baked vertex may stand from where the scene puts it, in metres, by default: at a baked frame it stands
## exactly there; between two the blend of their matrices cuts each bone's arc, which a clip's rate keeps small.
const PARITY := 0.015
## How near a fresh bake's matrices, bounds and tops must come to the committed ones by default (float noise across
## machines).
const FRESH := 0.00001
## How near a fresh bake's normals must come to the committed mesh's by default.
const NORMALS := 0.01
## The seconds before a clip's start and past its end that parity also poses (a loop wraps, a one-shot holds).
const PAST := 0.3
## Parity samples every SAMPLE_EVERY-th vertex, and each bone's farthest.
const SAMPLE_EVERY := 7

## The bake's recipe.
var recipe: UnifiedCrowdRecipe
## How far a baked vertex may stand from the scene's (parity).
var parity_tolerance := PARITY
## How near a fresh bake must come to the committed one.
var fresh_tolerance := FRESH
## How near a fresh bake's normals must come to the committed mesh's.
var normal_tolerance := NORMALS
## What the checks found, each naming the file it is in.
var problems: Array[Problem] = []
## The farthest parity found a vertex from the scene's, and where (`<clip> at <seconds> s, <mesh>`).
var worst := 0.0
var worst_at := ""


func _init(crowd: UnifiedCrowdRecipe) -> void:
	recipe = crowd


## Checks the committed bake (everything above), its character instanced under `parent` for the time it takes.
## Whether it found nothing.
func check(parent: Node) -> bool:
	var clips := load(recipe.clips_path) as UnifiedCrowdClips
	var mesh := load(recipe.mesh_path) as ArrayMesh
	if clips == null or mesh == null:
		_problem("no bake here (run the game's crowd bake)", recipe.clips_path if clips == null else recipe.mesh_path)
		return false
	if clips.sources != UnifiedCrowdBake.inputs_hash(recipe):
		_problem("the crowd's bake is stale: its inputs changed (re-bake it)", recipe.clips_path)
	var packed := load(recipe.scene) as PackedScene
	var rig := packed.instantiate() as Node3D if packed != null else null
	if rig == null:
		_problem("cannot instance the character (a scene with a Node3D root)", recipe.scene)
		return false
	parent.add_child(rig)
	check_bake(rig, mesh, clips)
	parent.remove_child(rig)
	rig.free()
	return problems.is_empty()


## Checks a bake of `rig` (a character in the tree, posed as the recipe says) without its hash: whole, fresh against a
## bake now, its rules and parity. Whether it found nothing.
func check_bake(rig: Node3D, mesh: ArrayMesh, clips: UnifiedCrowdClips) -> bool:
	var found := problems.size()
	if not _whole(rig, mesh, clips):
		return false
	var errors := UnifiedCrowdBake.validate(rig, recipe)
	for error in errors:
		_problem(error, recipe.scene)
	if not errors.is_empty():
		return false
	var merged := UnifiedCrowdBake.merge(rig, recipe)
	var lightened := UnifiedCrowdBake.lighten(merged, recipe.max_error)
	var arrays := mesh.surface_get_arrays(0)
	if _same_mesh(arrays, lightened.arrays) and _mesh_rules(arrays, clips):
		var pose := UnifiedCrowdBake.posing(rig, recipe)
		_fresh(UnifiedCrowdBake.bake_clips(rig, pose, recipe, lightened.arrays), mesh, clips)
		_masks(merged, lightened.source, arrays)
		parity(rig, merged, lightened.source, arrays, clips)
	return problems.size() == found


## The bake's vertices (every SAMPLE_EVERY-th, and each bone's farthest) skinned from `clips`' matrices as the shader
## does, against where the scene puts the vertex each one is (`source`: the merged vertex of each of `arrays`'; the
## scene's own skins with every weight, a prop where the engine's BoneAttachment3D holds it): at each clip's ends and
## PAST beyond them, at and between its first frames, and through the pair of baked frames between which a bone's
## farthest vertex turns most (where the blend cuts the arc most). A problem past `parity_tolerance`. The farthest.
func parity(
	rig: Node3D, merged: UnifiedCrowdBake.Merged, source: PackedInt32Array, arrays: Array, clips: UnifiedCrowdClips
) -> float:
	var pose := UnifiedCrowdBake.posing(rig, recipe)
	var skeleton := UnifiedCrowdBake.skeleton_of(rig)
	var attachments := rig.find_children("*", "BoneAttachment3D", true, false)
	var bind_poses := UnifiedCrowdBake.binds(rig)
	var reach := UnifiedCrowdBake.bone_reach(arrays, bind_poses)
	var samples := _samples(arrays, bind_poses)
	var scenes: Array[SceneMesh] = []
	for mesh_node in merged.meshes:
		scenes.append(SceneMesh.new(mesh_node, skeleton))
	worst = 0.0
	worst_at = ""
	for clip in clips.clips.size():
		var clip_length := clips.length(clip)
		var frame := 1.0 / clips.rate(clip)
		var pair := _worst_pair(clips, clip, reach)
		var times: Array[float] = [-PAST, 0.0, frame, 1.5 * frame, clip_length, clip_length + PAST]
		for quarter: int in [1, 2, 3]:
			times.append((pair + quarter / 4.0) * frame)
		for seconds in times:
			pose.call(clips.clips[clip], seconds)
			for attachment in attachments:
				(attachment as BoneAttachment3D).on_skeleton_update()
			var to_rig := UnifiedCrowdBake.relative(rig, skeleton)
			var poses: Array[Transform3D] = []
			for bone in skeleton.get_bone_count():
				poses.append(to_rig * skeleton.get_bone_global_pose(bone))
			for scene in scenes:
				scene.pose(rig, poses)
			var matrices := clips.matrices(clip, seconds)
			for vertex in samples:
				var from := source[vertex]
				var mesh := merged.mesh_of(from)
				var at := scenes[mesh].position(from - merged.bases[mesh])
				var apart := UnifiedCrowdBake.skin_vertex(arrays, vertex, matrices).distance_to(at)
				if apart > worst:
					worst = apart
					worst_at = "%s at %.3f s, %s" % [clips.clips[clip], seconds, merged.meshes[mesh].name]
	if worst > parity_tolerance:
		_problem("the crowd stands %.4f m from the scene's character (%s)" % [worst, worst_at], recipe.clips_path)
	return worst


## Whether the bake's parts have the sizes the rest reads by: the recipe's clips, a top per clip, the clips' rows in
## order and the texture the table's size (its header the skeleton's bones), one surface.
func _whole(rig: Node3D, mesh: ArrayMesh, clips: UnifiedCrowdClips) -> bool:
	var skeleton := UnifiedCrowdBake.skeleton_of(rig)
	if clips.bones == null or clips.bones.get_format() != Image.FORMAT_RGBAF:
		_problem("the bone matrices are no RGBA float Image", recipe.bones_path)
		return false
	var count := clips.clips.size()
	if clips.clips != recipe.clips or int(clips.bones.get_pixel(0, 0).r) != count or clips.tops.size() != count:
		_problem("the baked clips are not the recipe's, in its order", recipe.clips_path)
		return false
	if skeleton == null or clips.bone_count() != skeleton.get_bone_count():
		_problem("the bake has %d bones, the skeleton %d" % [clips.bone_count(),
			skeleton.get_bone_count() if skeleton != null else 0], recipe.bones_path)
		return false
	var rows := UnifiedCrowdClips.HEADER_ROWS
	for clip in count:
		if clips.first_row(clip) != rows or clips.frame_count(clip) < 2:
			_problem("%s: its rows are not the table's" % clips.clips[clip], recipe.bones_path)
			return false
		if clips.loops(clip) != (clips.clips[clip] in recipe.loops) or clips.rate(clip) != recipe.rate(clip):
			_problem("%s: its looping or rate is not the recipe's" % clips.clips[clip], recipe.bones_path)
			return false
		rows += clips.frame_count(clip)
	var width := maxi(clips.bone_count() * UnifiedCrowdClips.TEXELS_PER_BONE, 1 + count)
	if clips.bones.get_height() != rows or clips.bones.get_width() != width:
		_problem("the bone texture is not the table's size", recipe.bones_path)
		return false
	if mesh.get_surface_count() != 1:
		_problem("the crowd mesh has %d surfaces, not one" % mesh.get_surface_count(), recipe.mesh_path)
		return false
	return true


## Whether the committed mesh's `arrays` are `fresh` (a bake's now), but its normals within normal_tolerance.
func _same_mesh(arrays: Array, fresh: Array) -> bool:
	var same := true
	var named: Dictionary[int, String] = {
		Mesh.ARRAY_VERTEX: "positions", Mesh.ARRAY_TEX_UV: "UVs", Mesh.ARRAY_TEX_UV2: "mask",
		Mesh.ARRAY_CUSTOM0: "bones", Mesh.ARRAY_CUSTOM1: "weights", Mesh.ARRAY_INDEX: "triangles",
	}
	for array in named:
		if arrays[array] != fresh[array]:
			_problem("the crowd mesh's %s are not a bake's now (re-bake it)" % named[array], recipe.mesh_path)
			same = false
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var fresh_normals: PackedVector3Array = fresh[Mesh.ARRAY_NORMAL]
	if same and normals.size() == fresh_normals.size():
		for vertex in normals.size():
			if normals[vertex].distance_to(fresh_normals[vertex]) > normal_tolerance:
				_problem("the crowd mesh's normal %d is not a bake's now (re-bake it)" % vertex, recipe.mesh_path)
				return false
	return same


## Whether the mesh holds its rules: within max_triangles, each vertex's bones whole and the skeleton's, its weights
## summing to 1, and some vertex masked when the recipe masks a material.
func _mesh_rules(arrays: Array, clips: UnifiedCrowdClips) -> bool:
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var masks: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var bones: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM1]
	var triangles := indices.size() / 3.0
	if recipe.max_triangles > 0 and triangles > recipe.max_triangles:
		_problem("the crowd mesh has %d triangles, over %d" % [triangles, recipe.max_triangles], recipe.mesh_path)
	var masked := 0
	for vertex in masks.size():
		masked += int(masks[vertex].x > 0.5)
		var total := 0.0
		for k in UnifiedCrowdBake.WEIGHTS:
			var bone := bones[vertex * UnifiedCrowdBake.WEIGHTS + k]
			total += weights[vertex * UnifiedCrowdBake.WEIGHTS + k]
			if bone != roundf(bone) or bone < 0 or bone >= clips.bone_count():
				_problem("vertex %d is bound to bone %f" % [vertex, bone], recipe.mesh_path)
				return false
		if absf(total - 1.0) > 0.0001:
			_problem("vertex %d's weights sum to %f" % [vertex, total], recipe.mesh_path)
			return false
	if not recipe.masked.is_empty() and masked == 0:
		_problem("the crowd mesh lost its masked parts (no vertex masked)", recipe.mesh_path)
	return true


## A bake now (`fresh`) gives the committed matrices, bounds and tops, and the mesh's custom_aabb is its bounds.
func _fresh(fresh: UnifiedCrowdClips, mesh: ArrayMesh, clips: UnifiedCrowdClips) -> void:
	var drift := 0.0
	for y in clips.bones.get_height():
		for x in clips.bones.get_width():
			var a := clips.bones.get_pixel(x, y)
			var b := fresh.bones.get_pixel(x, y)
			drift = maxf(drift, maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), maxf(absf(a.b - b.b), absf(a.a - b.a))))
	if drift > fresh_tolerance:
		_problem("a bake now differs from the committed one by %f (re-bake it)" % drift, recipe.bones_path)
	if not _near(fresh.bounds, clips.bounds) or not _near(clips.bounds, mesh.custom_aabb):
		_problem("the bounds differ: a bake now %s, the table %s, the mesh %s" % [fresh.bounds, clips.bounds,
			mesh.custom_aabb], recipe.clips_path)
	for clip in clips.clips.size():
		if absf(fresh.tops[clip] - clips.tops[clip]) > fresh_tolerance:
			_problem("%s: its last pose's top is %f, a bake now %f" % [clips.clips[clip], clips.tops[clip],
				fresh.tops[clip]], recipe.clips_path)


## Every vertex of `arrays` is masked as the scene mesh it comes from (`source`: its merged vertex) is.
func _masks(merged: UnifiedCrowdBake.Merged, source: PackedInt32Array, arrays: Array) -> void:
	var masks: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	for vertex in masks.size():
		var masked := merged.masked[merged.mesh_of(source[vertex])]
		if (masks[vertex].x > 0.5) != masked:
			_problem("crowd vertex %d is %s, its scene mesh %s" % [vertex, "masked" if masks[vertex].x > 0.5 else
				"not masked", "is" if masked else "isn't"], recipe.mesh_path)
			return


## The vertices parity samples: every SAMPLE_EVERY-th, and each bone's farthest from it (a blade's tip, a hand, a
## foot: where a turn moves a vertex most).
func _samples(arrays: Array, bind_poses: Array[Transform3D]) -> PackedInt32Array:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	var farthest: Dictionary[int, Vector2] = {}  # bone: (distance, vertex)
	var out := PackedInt32Array()
	for vertex in positions.size():
		if vertex % SAMPLE_EVERY == 0:
			out.append(vertex)
		var bone := int(bones[vertex * UnifiedCrowdBake.WEIGHTS])
		var distance := (bind_poses[bone] * positions[vertex]).length()
		if not farthest.has(bone) or distance > farthest[bone].x:
			farthest[bone] = Vector2(distance, vertex)
	for bone in farthest:
		if int(farthest[bone].y) % SAMPLE_EVERY != 0:
			out.append(int(farthest[bone].y))
	return out


## The baked frame (its index in clip `clip`) after which the blend to the next one cuts a bone's arc most: per bone,
## how far its farthest vertex lies from it times how much a turn of the angle between the two frames shortens the
## chord (1 - cos(angle / 2)).
func _worst_pair(clips: UnifiedCrowdClips, clip: int, reach: Dictionary[int, AABB]) -> int:
	var radius: Dictionary[int, float] = {}
	for bone in reach:
		var far := 0.0
		for corner in 8:
			far = maxf(far, reach[bone].get_endpoint(corner).length())
		radius[bone] = far
	var most := -1.0
	var most_frame := 0
	var first := clips.first_row(clip)
	for frame in clips.frame_count(clip) - 1:
		for bone in radius:
			var a := clips.frame_matrix(first + frame, bone).basis.get_rotation_quaternion()
			var b := clips.frame_matrix(first + frame + 1, bone).basis.get_rotation_quaternion()
			var cut := radius[bone] * (1.0 - cos(a.angle_to(b) / 2.0))
			if cut > most:
				most = cut
				most_frame = frame
	return most_frame


## Whether two boxes are the same within fresh_tolerance.
func _near(a: AABB, b: AABB) -> bool:
	return a.position.distance_to(b.position) <= fresh_tolerance and a.end.distance_to(b.end) <= fresh_tolerance


func _problem(message: String, path: String) -> void:
	var problem := Problem.new()
	problem.message = message
	problem.path = path
	problems.append(problem)


## A check's finding: what is wrong, and the file it is in.
class Problem:
	## What is wrong.
	var message: String
	## The file it is in.
	var path: String


## A mesh of the scene's character as parity reads it: its arrays once, and its vertices where the scene puts them as
## posed now (its skin's own binds with every weight it has; a prop where the engine has placed its node).
class SceneMesh:
	## The mesh's node.
	var node: MeshInstance3D
	## Its vertices, bones (bind indices) and weights, as the mesh holds them.
	var positions: PackedVector3Array
	var bones: PackedInt32Array
	var weights: PackedFloat32Array
	## Weights per vertex (0: a prop).
	var per_vertex := 0
	## Per bind: its skeleton bone.
	var bind_bones: PackedInt32Array = []
	## Per bind: its skinning matrix as posed (pose).
	var matrices: Array[Transform3D] = []
	## A prop's place in the character's space as posed.
	var placed: Transform3D

	func _init(mesh_node: MeshInstance3D, skeleton: Skeleton3D) -> void:
		node = mesh_node
		var arrays := mesh_node.mesh.surface_get_arrays(0)
		positions = arrays[Mesh.ARRAY_VERTEX]
		if mesh_node.skin == null:
			return
		bones = arrays[Mesh.ARRAY_BONES]
		weights = arrays[Mesh.ARRAY_WEIGHTS]
		per_vertex = roundi(float(bones.size()) / positions.size())
		for bind in mesh_node.skin.get_bind_count():
			bind_bones.append(UnifiedCrowdBake.bind_bone(skeleton, mesh_node.skin, bind))

	## Takes the pose: `poses` are the skeleton's bones in the character's space.
	func pose(rig: Node3D, poses: Array[Transform3D]) -> void:
		if node.skin == null:
			placed = UnifiedCrowdBake.relative(rig, node)
			return
		matrices.clear()
		for bind in bind_bones.size():
			matrices.append(poses[bind_bones[bind]] * node.skin.get_bind_pose(bind))

	## Where vertex `vertex` stands as posed.
	func position(vertex: int) -> Vector3:
		if node.skin == null:
			return placed * positions[vertex]
		var point := Vector3.ZERO
		for k in per_vertex:
			point += weights[vertex * per_vertex + k] * (matrices[bones[vertex * per_vertex + k]] * positions[vertex])
		return point
