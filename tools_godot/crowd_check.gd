class_name UnifiedCrowdCheck
extends RefCounted
## Holds a crowd's committed bake (UnifiedCrowdBake, at its UnifiedCrowdRecipe's paths) fresh and true, for a game's
## checks (its validate step, say): `UnifiedCrowdCheck.new(recipe).check(root)`, then report `problems`.
##
## - **Whole:** the table's clips are the recipe's (their rates and looping too), its texture the table's size, the
##   mesh one surface.
## - **Fresh:** the hash of its inputs is today's (UnifiedCrowdBake.inputs); its mesh is the character merged and
##   lightened as the bake does it now (every array bit for bit, but the normals within `normal_tolerance`: a mesh
##   stores them compressed); and a bake now gives its matrices, bounds and last poses' bounds within
##   `fresh_tolerance`. The bake now is the truth the hash stands in for: it catches what no input's hash shows (a
##   pose script's change, a forgotten UnifiedCrowdBake.BAKE_VERSION bump).
## - **Its rules:** within the recipe's max_triangles, each vertex's bones the skeleton's and its weights summing to 1,
##   each vertex masked as the material of the scene part it comes from says.
## - **Parity** (parity): the bake's vertices skinned as the shader does, from the baked matrices, stand where the live
##   Skeleton3D puts them, within `parity_tolerance`, at any time in any clip.

## How far a baked vertex may stand from where the scene puts it, in metres, by default: at a baked frame it stands
## exactly there; between two the blend of their matrices cuts each bone's arc, which a clip's rate keeps small.
const PARITY := 0.015
## How near a fresh bake's matrices and bounds must come to the committed ones by default (float noise across
## machines).
const FRESH := 0.00001
## How near a fresh bake's normals must come to the committed mesh's by default.
const NORMALS := 0.01
## How near 1 a vertex's weights must sum.
const WEIGHT_SUM := 0.0001
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
	var clips: UnifiedCrowdClips = null
	if ResourceLoader.exists(recipe.clips_path):
		clips = load(recipe.clips_path) as UnifiedCrowdClips
	var mesh: ArrayMesh = null
	if ResourceLoader.exists(recipe.mesh_path):
		mesh = load(recipe.mesh_path) as ArrayMesh
	if clips == null or mesh == null:
		_problem("no bake here (run the game's crowd bake)", recipe.clips_path if clips == null else recipe.mesh_path)
		return false
	if clips.sources != UnifiedCrowdBake.inputs_hash(recipe):
		_problem("the crowd's bake is stale: its inputs changed (re-bake it)", recipe.clips_path)
	var root: Node = null
	if ResourceLoader.exists(recipe.scene):
		var packed := load(recipe.scene) as PackedScene
		if packed != null:
			root = packed.instantiate()
	var rig := root as Node3D
	if rig == null:
		if root != null:
			root.free()
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
	var errors := UnifiedCrowdBake.validate(rig, recipe)
	for error in errors:
		_problem(error, recipe.scene)
	if not errors.is_empty() or not _whole(rig, mesh, clips):
		return false
	var shaped := UnifiedCrowdBake.shape(rig, recipe)
	var arrays := mesh.surface_get_arrays(0)
	var same := _same_mesh(arrays, shaped.arrays)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if positions.size() == shaped.source.size():
		_masks(shaped, arrays)
	var rules := _mesh_rules(arrays, clips)
	_fresh(UnifiedCrowdBake.bake_clips(rig, recipe, shaped.arrays), mesh, clips)
	if same and rules:
		parity(rig, shaped, arrays, clips)
	return problems.size() == found


## The bake's vertices (`arrays`: every SAMPLE_EVERY-th, and each bone's farthest) skinned from `clips`' matrices as the
## shader does, against where the scene puts the vertex each one is (`shaped`: its parts, and the merged vertex of each
## of `arrays`'; the scene's own skins with every weight, a prop where the engine's BoneAttachment3D holds it): at each
## clip's ends and PAST beyond them, at and between its first frames, and through the pair of baked frames between
## which a bone's farthest vertex turns most (where the blend cuts the arc most). A problem past `parity_tolerance`.
## The farthest.
func parity(rig: Node3D, shaped: UnifiedCrowdBake.Shape, arrays: Array, clips: UnifiedCrowdClips) -> float:
	var pose := UnifiedCrowdBake.posing(rig, recipe)
	var skeleton := UnifiedCrowdBake.skeleton_of(rig)
	var attachments := rig.find_children("*", "BoneAttachment3D", true, false)
	var bind_poses := UnifiedCrowdBake.binds(rig)
	var reach := UnifiedCrowdBake.bone_reach(arrays, bind_poses)
	var samples := _samples(arrays, bind_poses)
	var scenes: Dictionary[UnifiedCrowdBake.Part, ScenePart] = {}
	for part in shaped.parts:
		scenes[part] = ScenePart.new(part, skeleton)
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
			for part in scenes:
				scenes[part].pose(rig, poses)
			var matrices := clips.matrices(clip, seconds)
			for vertex in samples:
				var from := shaped.source[vertex]
				var part := shaped.part_of(from)
				var at := scenes[part].position(from - part.base)
				var apart := UnifiedCrowdBake.skin_vertex(arrays, vertex, matrices).distance_to(at)
				if not (apart <= worst):
					worst = apart
					worst_at = "%s at %.3f s, %s" % [clips.clips[clip], seconds, part.node.name]
	if not (worst <= parity_tolerance):
		_problem("the crowd stands %.4f m from the scene's character (%s)" % [worst, worst_at], recipe.clips_path)
	return worst


## Whether the bake's parts have the sizes the rest reads by: the recipe's clips, rates and looping, a last pose's
## bounds per clip, the clips' rows in order and the texture the table's size (its header the skeleton's bones), one
## surface.
func _whole(rig: Node3D, mesh: ArrayMesh, clips: UnifiedCrowdClips) -> bool:
	var skeleton := UnifiedCrowdBake.skeleton_of(rig)
	if clips.bones == null or clips.bones.get_format() != Image.FORMAT_RGBAF or clips.bones.get_height() < 1:
		_problem("the bone matrices are no RGBA float Image", recipe.bones_path)
		return false
	var count := clips.clips.size()
	if clips.clips != recipe.names() or int(clips.bones.get_pixel(0, 0).r) != count or clips.last_bounds.size() != count:
		_problem("the baked clips are not the recipe's, in its order (re-bake it)", recipe.clips_path)
		return false
	if clips.bone_count() != skeleton.get_bone_count():
		_problem("the bake has %d bones, the skeleton %d (re-bake it)" % [clips.bone_count(), skeleton.get_bone_count()],
			recipe.bones_path)
		return false
	var rows := UnifiedCrowdClips.HEADER_ROWS
	for clip in count:
		if clips.first_row(clip) != rows or clips.frame_count(clip) < 2:
			_problem("%s: its rows are not the table's" % clips.clips[clip], recipe.bones_path)
			return false
		var looping := UnifiedCrowdBake.clip_loops(rig, recipe, clip)
		if clips.loops(clip) != looping or clips.rate(clip) != recipe.clips[clip].rate:
			_problem("%s: its looping or rate is not the recipe's (re-bake it)" % clips.clips[clip], recipe.bones_path)
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
		Mesh.ARRAY_VERTEX: "positions", Mesh.ARRAY_TEX_UV: "UVs", Mesh.ARRAY_TEX_UV2: "masks",
		Mesh.ARRAY_CUSTOM0: "bones", Mesh.ARRAY_CUSTOM1: "weights", Mesh.ARRAY_INDEX: "triangles",
	}
	for array in named:
		if arrays[array] != fresh[array]:
			_problem("the crowd mesh's %s are not a bake's now (re-bake it)" % named[array], recipe.mesh_path)
			same = false
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var fresh_normals: PackedVector3Array = fresh[Mesh.ARRAY_NORMAL]
	if normals.size() != fresh_normals.size():
		return false
	for vertex in normals.size():
		if not (normals[vertex].distance_to(fresh_normals[vertex]) <= normal_tolerance):
			_problem("the crowd mesh's normal %d is not a bake's now (re-bake it)" % vertex, recipe.mesh_path)
			return false
	return same


## Whether the mesh holds its rules: within max_triangles, each vertex's bones whole and the skeleton's, its weights
## summing to 1.
func _mesh_rules(arrays: Array, clips: UnifiedCrowdClips) -> bool:
	var ok := true
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var bones: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM1]
	var triangles := indices.size() / 3.0
	if recipe.max_triangles > 0 and triangles > recipe.max_triangles:
		_problem("the crowd mesh has %d triangles, over %d" % [triangles, recipe.max_triangles], recipe.mesh_path)
		ok = false
	for vertex in roundi(bones.size() / float(UnifiedCrowdBake.WEIGHTS)):
		var total := 0.0
		for k in UnifiedCrowdBake.WEIGHTS:
			var bone := bones[vertex * UnifiedCrowdBake.WEIGHTS + k]
			total += weights[vertex * UnifiedCrowdBake.WEIGHTS + k]
			if not (bone == roundf(bone) and bone >= 0 and bone < clips.bone_count()):
				_problem("vertex %d is bound to bone %f" % [vertex, bone], recipe.mesh_path)
				return false
		if not (absf(total - 1.0) <= WEIGHT_SUM):
			_problem("vertex %d's weights sum to %f" % [vertex, total], recipe.mesh_path)
			return false
	return ok


## Every vertex of `arrays` is masked as the material of the scene part it comes from says (`shaped`: the merged vertex
## each one is, and its part): that material's index in the recipe's masked plus one, else 0.
func _masks(shaped: UnifiedCrowdBake.Shape, arrays: Array) -> void:
	var masks: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	for vertex in masks.size():
		var part := shaped.part_of(shaped.source[vertex])
		var material := part.node.get_active_material(part.surface)
		var expected := 0
		for index in recipe.masked.size():
			var mask := recipe.masked[index]
			if material == null:
				break
			var same_file := mask.resource_path != "" and mask.resource_path == material.resource_path
			if mask == material or same_file:
				expected = index + 1
				break
		if masks[vertex].x != expected:
			_problem("crowd vertex %d is masked %d, its scene part (%s, surface %d) %d" % [vertex, masks[vertex].x,
				part.node.name, part.surface, expected], recipe.mesh_path)
			return


## A bake now (`fresh`) gives the committed matrices, bounds and last poses' bounds, and the mesh's custom_aabb is its
## bounds.
func _fresh(fresh: UnifiedCrowdClips, mesh: ArrayMesh, clips: UnifiedCrowdClips) -> void:
	if fresh.bones.get_size() != clips.bones.get_size():
		_problem("a bake now is %s texels, the committed one %s (re-bake it)" % [fresh.bones.get_size(),
			clips.bones.get_size()], recipe.bones_path)
		return
	var drift := 0.0
	for y in clips.bones.get_height():
		for x in clips.bones.get_width():
			var a := clips.bones.get_pixel(x, y)
			var b := fresh.bones.get_pixel(x, y)
			drift = maxf(drift, maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), maxf(absf(a.b - b.b), absf(a.a - b.a))))
			if is_nan(a.r + a.g + a.b + a.a):
				drift = INF
	if not (drift <= fresh_tolerance):
		_problem("a bake now differs from the committed one by %f (re-bake it)" % drift, recipe.bones_path)
	if not _near(fresh.bounds, clips.bounds) or not _near(clips.bounds, mesh.custom_aabb):
		_problem("the bounds differ: a bake now %s, the table %s, the mesh %s (re-bake it)" % [fresh.bounds, clips.bounds,
			mesh.custom_aabb], recipe.clips_path)
	for clip in clips.clips.size():
		if not _near(fresh.last_bounds[clip], clips.last_bounds[clip]):
			_problem("%s: its last pose's bounds are %s, a bake now %s (re-bake it)" % [clips.clips[clip],
				clips.last_bounds[clip], fresh.last_bounds[clip]], recipe.clips_path)


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


## A part of the scene's character as parity reads it: its surface's arrays once, and its vertices where the scene puts
## them as posed now (its skin's own binds with every weight it has; a prop where the engine has placed its node).
class ScenePart:
	## The mesh's node.
	var node: MeshInstance3D
	## Its vertices, bones (bind indices) and weights, as the surface holds them.
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

	func _init(part: UnifiedCrowdBake.Part, skeleton: Skeleton3D) -> void:
		node = part.node
		var arrays := node.mesh.surface_get_arrays(part.surface)
		positions = arrays[Mesh.ARRAY_VERTEX]
		if node.skin == null:
			return
		bones = arrays[Mesh.ARRAY_BONES]
		weights = arrays[Mesh.ARRAY_WEIGHTS]
		per_vertex = roundi(float(bones.size()) / positions.size())
		for bind in node.skin.get_bind_count():
			bind_bones.append(UnifiedCrowdBake.bind_bone(skeleton, node.skin, bind))

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
