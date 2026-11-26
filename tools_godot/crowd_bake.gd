class_name UnifiedCrowdBake
extends RefCounted
## Bakes a character for a crowd drawn as one MultiMesh: its meshes and props merged into one lighter surface that keeps
## its skin, and its clips baked as bone matrices into an Image (UnifiedCrowdClips, a runtime file) that the crowd's
## shader skins the surface from (godot_runtime/crowd_skin.gdshaderinc), so a crowd is one draw call a pass and its
## animation costs no node. What to bake, and where it goes, is a UnifiedCrowdRecipe; a game's tool script calls
## `bake(recipe, root).save()`, and UnifiedCrowdCheck proves the committed bake fresh and posing as the character does.
##
## A character is a Node3D with one Skeleton3D: meshes skinned to it, props on BoneAttachment3Ds, an AnimationPlayer
## holding the clips. A bone's matrix is the one Godot skins by, the bone's pose in the character's space times its
## skin's bind (every skin must bind a bone alike), so the baked pose is the scene's own. A prop is bound to its
## attachment's bone with weight 1, through that bone's bind, so it needs no bone of its own. A hidden mesh is left out:
## the scene doesn't draw it either.
##
## The merged surface: every surface of every mesh is a part. Positions and normals in the skeleton's bind space, UVs,
## UV2.x the part's mask (its material's index in the recipe's `masked` plus one, 0 unmasked), each vertex's four
## strongest bones (skeleton indices) in CUSTOM0 and their weights, summing to 1, in CUSTOM1, as floats (a skinned
## mesh's own bone arrays reach no shader without a skeleton). The functions below the bake's own are its steps, which
## UnifiedCrowdCheck repeats to compare.

## The bake's version: part of its inputs' hash (inputs), so a new one makes every committed bake stale. Bump it with
## any change that bakes the same inputs differently: the merge, the lightening, the matrices, the table's layout
## (UnifiedCrowdClips). A forgotten bump is caught anyway, later and less plainly: UnifiedCrowdCheck bakes again and
## compares, and fails a committed bake that differs.
const BAKE_VERSION := 2
## Weights kept per vertex: the shader skins with four.
const WEIGHTS := 4
## The angles generate_lods takes (degrees): normals closer than the first merge, farther than the second split. The
## scene importer's defaults, so the chain is the one Godot makes for a model's own LODs.
const LOD_MERGE_ANGLE := 25.0
const LOD_SPLIT_ANGLE := 60.0
## A clip's length may miss a whole number of its frames by this much (in frames): float noise.
const WHOLE_FRAMES := 0.001
## The resource types whose files a bake reads (inputs): what a character is made of. Materials, textures, shaders and
## scripts are not: they change no baked number (a masked material counts by its path, in the recipe), and a script
## that changes a pose shows in UnifiedCrowdCheck's bake now.
const INPUT_TYPES: PackedStringArray = [
	"PackedScene", "Mesh", "ArrayMesh", "ImporterMesh", "Animation", "AnimationLibrary", "Skin",
]


## Bakes `recipe`'s character: its scene instanced under `parent` (in the tree: its poses are computed), baked, and
## freed. The result carries the hash of the bake's inputs, and its errors (then no mesh or clips) when the character
## or the recipe can't be baked.
static func bake(recipe: UnifiedCrowdRecipe, parent: Node) -> Baked:
	var root: Node = null
	if ResourceLoader.exists(recipe.scene):
		var packed := load(recipe.scene) as PackedScene
		if packed != null:
			root = packed.instantiate()
	var rig := root as Node3D
	if rig == null:
		if root != null:
			root.free()
		var failed := Baked.new()
		failed.recipe = recipe
		failed.errors.append("%s: no scene with a Node3D root to bake" % recipe.scene)
		return failed
	parent.add_child(rig)
	var baked := bake_rig(rig, recipe)
	parent.remove_child(rig)
	rig.free()
	if baked.errors.is_empty():
		baked.clips.sources = inputs_hash(recipe)
	return baked


## Bakes `rig` (a character in the tree) as `recipe` says. No hash: bake() stamps it.
static func bake_rig(rig: Node3D, recipe: UnifiedCrowdRecipe) -> Baked:
	var baked := Baked.new()
	baked.recipe = recipe
	baked.errors = validate(rig, recipe)
	if not baked.errors.is_empty():
		return baked
	var shaped := shape(rig, recipe)
	baked.clips = bake_clips(rig, recipe, shaped.arrays)
	baked.mesh = ArrayMesh.new()
	baked.mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, shaped.arrays, [], {}, _format())
	baked.mesh.custom_aabb = baked.clips.bounds
	return baked


## What keeps `rig` from being baked as `recipe` says, a line each (none: it bakes). The recipe: its clips each an
## animation of the AnimationPlayer, once, at a rate giving a whole number of frames (at least one), looping as its
## Animation does when it says; its masked materials each drawing a part; its three paths; a bone texture within
## UnifiedCrowdClips.MAX_SIDE. The character: one skeleton its skinned meshes share, at it, binding each bone alike;
## every other mesh held by a BoneAttachment3D of a bone of it; every surface triangles with normals, and a skinned
## one's every vertex weighted.
static func validate(rig: Node3D, recipe: UnifiedCrowdRecipe) -> PackedStringArray:
	var errors: PackedStringArray = []
	for path: String in [recipe.mesh_path, recipe.bones_path, recipe.clips_path]:
		if path == "":
			errors.append("the recipe says not where to keep the bake (its mesh_path, bones_path and clips_path)")
			break
	for material in recipe.masked:
		if material == null:
			errors.append("the recipe masks a null material")
	errors.append_array(_character_problems(rig, recipe))
	if not errors.is_empty():
		return errors
	errors.append_array(_bind_disagreements(rig, skeleton_of(rig)))
	var player := _player_of(rig)
	if player == null:
		errors.append("%s: no AnimationPlayer" % rig.name)
		return errors
	if recipe.clips.is_empty():
		errors.append("the recipe has no clips")
	var rows := UnifiedCrowdClips.HEADER_ROWS
	var seen: Dictionary[StringName, bool] = {}
	for clip in recipe.clips:
		if clip == null:
			errors.append("the recipe has a null clip")
			continue
		if seen.has(clip.animation):
			errors.append("%s: twice in the recipe" % clip.animation)
		seen[clip.animation] = true
		if not player.has_animation(clip.animation):
			errors.append("%s: no clip %s" % [player.name, clip.animation])
			continue
		var animation := player.get_animation(clip.animation)
		var frames := animation.length * clip.rate
		if clip.rate <= 0.0 or frames < 0.5:
			errors.append("%s: %.2f s at %.1f a second is less than a frame" % [clip.animation, animation.length, clip.rate])
			continue
		if absf(frames - roundf(frames)) > WHOLE_FRAMES:
			errors.append("%s: %.3f frames at %.1f a second, not a whole number" % [clip.animation, frames, clip.rate])
		var animation_loops := animation.loop_mode != Animation.LOOP_NONE
		if clip.loop != UnifiedCrowdClip.Loop.FROM_ANIMATION and clip.loops(animation) != animation_loops:
			errors.append("%s: the recipe says it %s, its Animation that it %s" % [clip.animation,
				"loops" if clip.loops(animation) else "holds", "loops" if animation_loops else "holds"])
		rows += roundi(frames) + 1
	var width := maxi(skeleton_of(rig).get_bone_count() * UnifiedCrowdClips.TEXELS_PER_BONE, 1 + recipe.clips.size())
	if width > UnifiedCrowdClips.MAX_SIDE or rows > UnifiedCrowdClips.MAX_SIDE:
		errors.append("the bone texture would be %d by %d, over %d a side: fewer bones, clips or frames a second" % [
			width, rows, UnifiedCrowdClips.MAX_SIDE])
	return errors


## What the bake of `recipe` is made from: the bake's version, Godot's (a new one may import, animate or lighten a
## model otherwise), the recipe (UnifiedCrowdRecipe.describe) and a SHA-256 of each file of the character (its scene and
## every scene, mesh, animation or skin it loads, an imported one's .import and a glTF's buffers; INPUT_TYPES).
static func inputs(recipe: UnifiedCrowdRecipe) -> Dictionary:
	var files: Dictionary[String, String] = {}
	var paths := _input_files(recipe)
	paths.sort()
	for path in paths:
		files[path] = FileAccess.get_sha256(path)
	return {
		"bake": BAKE_VERSION,
		"godot": Engine.get_version_info()["string"],
		"recipe": recipe.describe(),
		"files": files,
	}


## A hash of inputs(recipe), so a check can tell a committed bake from a stale one.
static func inputs_hash(recipe: UnifiedCrowdRecipe) -> String:
	return var_to_str(inputs(recipe)).sha256_text()


# --- The bake's steps, which UnifiedCrowdCheck repeats ------------------------------------------------------------


## `rig` merged into the crowd's surface (every part, the header says how) and lightened: each unmasked part at the
## coarsest of Godot's own LODs for it whose error is within the recipe's max_error (ImporterMesh.generate_lods, the
## scene importer's: meshoptimizer, which moves no vertex and keeps the normals' and UVs' seams, so a palette atlas
## stays exact; its error is relative to the part's size), the vertices no triangle uses dropped. Part by part, not the
## merged surface whole: on the whole one the chain halves it at each step, and a small part (an eye) collapses first.
static func shape(rig: Node3D, recipe: UnifiedCrowdRecipe) -> Shape:
	return _lighten(_merge(rig, recipe), recipe.max_error)


## `recipe`'s clips baked from `rig`, posed as `posing` says, each at its rate, with the bounds every pose sweeps
## `arrays` (the crowd's surface, shape's) through and each clip's last pose's bounds.
static func bake_clips(rig: Node3D, recipe: UnifiedCrowdRecipe, arrays: Array) -> UnifiedCrowdClips:
	var pose := posing(rig, recipe)
	var player := _player_of(rig)
	var skeleton := skeleton_of(rig)
	var bind_poses := binds(rig)
	var bone_count := bind_poses.size()
	var clip_count := recipe.clips.size()
	var first_rows := PackedInt32Array()
	var frame_counts := PackedInt32Array()
	var rows := UnifiedCrowdClips.HEADER_ROWS
	for clip in recipe.clips:
		var frames := roundi(player.get_animation(clip.animation).length * clip.rate) + 1
		first_rows.append(rows)
		frame_counts.append(frames)
		rows += frames
	var width := maxi(bone_count * UnifiedCrowdClips.TEXELS_PER_BONE, 1 + clip_count)
	var clips := UnifiedCrowdClips.new()
	clips.clips = recipe.names()
	clips.bones = Image.create_empty(width, rows, false, Image.FORMAT_RGBAF)
	clips.bones.set_pixel(0, 0, Color(clip_count, bone_count, 0, 0))
	for clip_index in clip_count:
		var looping := 1.0 if clip_loops(rig, recipe, clip_index) else 0.0
		var rate := recipe.clips[clip_index].rate
		clips.bones.set_pixel(1 + clip_index, 0, Color(first_rows[clip_index], frame_counts[clip_index], rate, looping))
	var reach := bone_reach(arrays, bind_poses)
	var bounds := AABB()
	var first := true
	for clip_index in clip_count:
		var clip := recipe.clips[clip_index]
		var clip_length := clips.length(clip_index)
		var clip_rate := clips.rate(clip_index)  # the table's: the time a player reads each frame at
		var last := frame_counts[clip_index] - 1
		for frame in frame_counts[clip_index]:
			pose.call(clip.animation, minf(frame / clip_rate, clip_length))
			var matrices := skinning(rig, skeleton, bind_poses)
			for bone in bone_count:
				var m := matrices[bone]
				for row in UnifiedCrowdClips.TEXELS_PER_BONE:
					var texel := Color(m.basis.x[row], m.basis.y[row], m.basis.z[row], m.origin[row])
					clips.bones.set_pixel(bone * UnifiedCrowdClips.TEXELS_PER_BONE + row, first_rows[clip_index] + frame, texel)
				if not reach.has(bone):
					continue  # it moves no vertex
				var box := m * bind_poses[bone].affine_inverse() * reach[bone]  # the bone's pose: reach is in its space
				bounds = box if first else bounds.merge(box)
				first = false
			if frame == last:
				clips.last_bounds.append(_pose_bounds(arrays, matrices))
	clips.bounds = bounds
	return clips


## Whether clip `clip_index` of `recipe` loops: as it says, else as its Animation does.
static func clip_loops(rig: Node3D, recipe: UnifiedCrowdRecipe, clip_index: int) -> bool:
	var clip := recipe.clips[clip_index]
	return clip.loops(_player_of(rig).get_animation(clip.animation))


## How `recipe` poses `rig`: `func(clip: StringName, seconds: float)`, its recipe's pose, else the rig's
## AnimationPlayer, a loop wrapped and a one-shot held at its ends, seeked at once. Each pose is the clip's own,
## whatever was posed before: a new clip starts from the skeleton's rest (a bone it doesn't key stands there, not where
## the last clip left it) and plays with no blend (a seek advances no time, so the player's blend time from the last
## clip would never decay: every frame would hold the last clip's pose).
static func posing(rig: Node3D, recipe: UnifiedCrowdRecipe) -> Callable:
	if recipe.pose.is_valid():
		var game_pose := recipe.pose
		return func(clip: StringName, seconds: float) -> void: game_pose.call(rig, clip, seconds)
	var player := _player_of(rig)
	var skeleton := skeleton_of(rig)
	var looping: Dictionary[StringName, bool] = {}
	for clip_index in recipe.clips.size():
		looping[recipe.clips[clip_index].animation] = clip_loops(rig, recipe, clip_index)
	return func(clip: StringName, seconds: float) -> void:
		if player.current_animation != clip:
			player.stop()
			skeleton.reset_bone_poses()
			player.play(clip, 0.0)
		var clip_length := player.get_animation(clip).length
		player.seek(fposmod(seconds, clip_length) if looping.get(clip, false) else clampf(seconds, 0.0, clip_length), true)


## The skeleton `rig`'s skinned meshes are bound to (validate holds that there is one).
static func skeleton_of(rig: Node3D) -> Skeleton3D:
	for mesh_node in _meshes_of(rig):
		if mesh_node.skin != null:
			return mesh_node.get_node_or_null(mesh_node.skeleton) as Skeleton3D
	return null


## `node`'s transform in `space`'s, from their global transforms (both in the tree).
static func relative(space: Node3D, node: Node3D) -> Transform3D:
	return space.global_transform.affine_inverse() * node.global_transform


## Each bone's bind (its skins' inverse rest, mesh space to bone space; validate holds that every skin binds a bone
## alike). A bone no skin binds gets the inverse of its rest.
static func binds(rig: Node3D) -> Array[Transform3D]:
	var skeleton := skeleton_of(rig)
	var out: Array[Transform3D] = []
	for bone in skeleton.get_bone_count():
		out.append(skeleton.get_bone_global_rest(bone).affine_inverse())
	for mesh_node in _meshes_of(rig):
		if mesh_node.skin != null:
			for bind in mesh_node.skin.get_bind_count():
				out[bind_bone(skeleton, mesh_node.skin, bind)] = mesh_node.skin.get_bind_pose(bind)
	return out


## Each bone's skinning matrix in `rig`'s space as it is posed now: what a vertex bound to it is moved by.
static func skinning(rig: Node3D, skeleton: Skeleton3D, bind_poses: Array[Transform3D]) -> Array[Transform3D]:
	var to_rig := relative(rig, skeleton)
	var out: Array[Transform3D] = []
	for bone in skeleton.get_bone_count():
		out.append(to_rig * skeleton.get_bone_global_pose(bone) * bind_poses[bone])
	return out


## The skeleton bone a skin's bind binds (by name, else by index; validate holds that there is one).
static func bind_bone(skeleton: Skeleton3D, skin: Skin, bind: int) -> int:
	return _bind_bone_or_none(skeleton, skin, bind)


## Per bone that moves a vertex of `arrays` (a crowd surface), the bounds of those vertices in its bone space: a pose's
## matrix for the bone carries them where the bone is, and a skinned vertex lies within the boxes of its bones.
static func bone_reach(arrays: Array, bind_poses: Array[Transform3D]) -> Dictionary[int, AABB]:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM1]
	var out: Dictionary[int, AABB] = {}
	for vertex in positions.size():
		for k in WEIGHTS:
			if weights[vertex * WEIGHTS + k] <= 0.0:
				continue
			var bone := int(bones[vertex * WEIGHTS + k])
			var point := bind_poses[bone] * positions[vertex]
			out[bone] = out[bone].expand(point) if out.has(bone) else AABB(point, Vector3.ZERO)
	return out


## Where vertex `vertex` of `arrays` (a crowd surface) stands, skinned by `matrices` (one per bone): the shader's sum.
static func skin_vertex(arrays: Array, vertex: int, matrices: Array[Transform3D]) -> Vector3:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM1]
	var point := Vector3.ZERO
	for k in WEIGHTS:
		var weight := weights[vertex * WEIGHTS + k]
		if weight > 0.0:
			point += weight * (matrices[int(bones[vertex * WEIGHTS + k])] * positions[vertex])
	return point


# --- Private ------------------------------------------------------------------------------------------------------


## Every part of `rig` merged into one surface's arrays, in its skeleton's bind space (the header says what each array
## holds). A prop is bound to its attachment's bone with weight 1, placed through that bone's bind where the attachment
## holds it (its place under the attachment: whatever the pose), its normals turned with it.
static func _merge(rig: Node3D, recipe: UnifiedCrowdRecipe) -> Shape:
	var shaped := Shape.new()
	var skeleton := skeleton_of(rig)
	var bind_poses := binds(rig)
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var masks := PackedVector2Array()
	var bones := PackedFloat32Array()
	var weights := PackedFloat32Array()
	for mesh_node in _meshes_of(rig):
		var place := Transform3D.IDENTITY
		var bone_map := PackedInt32Array()
		if mesh_node.skin != null:
			for bind in mesh_node.skin.get_bind_count():
				bone_map.append(bind_bone(skeleton, mesh_node.skin, bind))
		else:
			var attachment := _attachment_of(mesh_node, rig)
			var bone := skeleton.find_bone(attachment.bone_name)
			place = bind_poses[bone].affine_inverse() * _local_to(attachment, mesh_node)
			bone_map.append(bone)
		var turn := place.basis.inverse().transposed()  # normals turn by the inverse transpose
		for surface in mesh_node.mesh.get_surface_count():
			var arrays := mesh_node.mesh.surface_get_arrays(surface)
			var source_positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var source_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var source_uvs := PackedVector2Array()
			if arrays[Mesh.ARRAY_TEX_UV] != null:
				source_uvs = arrays[Mesh.ARRAY_TEX_UV]
			var source_indices := PackedInt32Array()
			if arrays[Mesh.ARRAY_INDEX] != null:
				source_indices = arrays[Mesh.ARRAY_INDEX]
			if source_indices.is_empty():  # an unindexed surface: its vertices in order
				for vertex in source_positions.size():
					source_indices.append(vertex)
			var part := Part.new()
			part.node = mesh_node
			part.surface = surface
			part.mask = _mask_of(mesh_node.get_active_material(surface), recipe)
			part.base = positions.size()
			var source_bones := PackedInt32Array()
			var source_weights := PackedFloat32Array()
			var per_vertex := 0
			if mesh_node.skin != null:
				source_bones = arrays[Mesh.ARRAY_BONES]
				source_weights = arrays[Mesh.ARRAY_WEIGHTS]
				per_vertex = roundi(float(source_bones.size()) / source_positions.size())
			for vertex in source_positions.size():
				positions.append(place * source_positions[vertex])
				normals.append((turn * source_normals[vertex]).normalized())
				uvs.append(source_uvs[vertex] if vertex < source_uvs.size() else Vector2.ZERO)
				masks.append(Vector2(part.mask, 0.0))
				if per_vertex == 0:
					bones.append_array(PackedFloat32Array([bone_map[0], 0, 0, 0]))
					weights.append_array(PackedFloat32Array([1, 0, 0, 0]))
					continue
				var strongest: Array[Vector2] = []  # (weight, bone)
				for k in per_vertex:
					var weight := source_weights[vertex * per_vertex + k]
					strongest.append(Vector2(weight, bone_map[source_bones[vertex * per_vertex + k]]))
				strongest.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x > b.x)
				while strongest.size() < WEIGHTS:
					strongest.append(Vector2.ZERO)
				var total := 0.0
				for k in WEIGHTS:
					total += strongest[k].x
				for k in WEIGHTS:
					bones.append(strongest[k].y if strongest[k].x > 0 else 0.0)
					weights.append(strongest[k].x / total)
			for index in source_indices:
				part.indices.append(part.base + index)
			shaped.parts.append(part)
	shaped.arrays.resize(Mesh.ARRAY_MAX)
	shaped.arrays[Mesh.ARRAY_VERTEX] = positions
	shaped.arrays[Mesh.ARRAY_NORMAL] = normals
	shaped.arrays[Mesh.ARRAY_TEX_UV] = uvs
	shaped.arrays[Mesh.ARRAY_TEX_UV2] = masks
	shaped.arrays[Mesh.ARRAY_CUSTOM0] = bones
	shaped.arrays[Mesh.ARRAY_CUSTOM1] = weights
	for vertex in positions.size():
		shaped.source.append(vertex)
	return shaped


## `merged` (_merge's) lightened as shape() says: its arrays and indices replaced, `source` mapping each kept vertex to
## its merged one.
static func _lighten(merged: Shape, max_error: float) -> Shape:
	var arrays := merged.arrays
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var kept := PackedInt32Array()
	for part in merged.parts:
		if part.mask > 0 or max_error <= 0.0:
			kept.append_array(part.indices)
			continue
		var local := _compact(part.indices)  # the part alone: its LOD errors are relative to its size
		var lod_shape := []
		lod_shape.resize(Mesh.ARRAY_MAX)
		var part_positions := PackedVector3Array()
		var part_normals := PackedVector3Array()
		var part_uvs := PackedVector2Array()
		for vertex in local[0]:
			part_positions.append(positions[vertex])
			part_normals.append(normals[vertex])
			part_uvs.append(uvs[vertex])
		lod_shape[Mesh.ARRAY_VERTEX] = part_positions
		lod_shape[Mesh.ARRAY_NORMAL] = part_normals
		lod_shape[Mesh.ARRAY_TEX_UV] = part_uvs
		lod_shape[Mesh.ARRAY_INDEX] = local[1]
		var chain := ImporterMesh.new()
		chain.add_surface(Mesh.PRIMITIVE_TRIANGLES, lod_shape)
		chain.generate_lods(LOD_MERGE_ANGLE, LOD_SPLIT_ANGLE, [])
		var lightest: PackedInt32Array = local[1]
		for lod in chain.get_surface_lod_count(0):
			if chain.get_surface_lod_size(0, lod) > max_error:
				break
			lightest = chain.get_surface_lod_indices(0, lod)
		for local_index in lightest:
			kept.append(local[0][local_index])
	var compacted := _compact(kept)
	var lightened := Shape.new()
	lightened.parts = merged.parts
	lightened.source = compacted[0]
	lightened.arrays.resize(Mesh.ARRAY_MAX)
	var masks: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var kept_positions := PackedVector3Array()
	var kept_normals := PackedVector3Array()
	var kept_uvs := PackedVector2Array()
	var kept_masks := PackedVector2Array()
	for old in lightened.source:
		kept_positions.append(positions[old])
		kept_normals.append(normals[old])
		kept_uvs.append(uvs[old])
		kept_masks.append(masks[old])
	lightened.arrays[Mesh.ARRAY_VERTEX] = kept_positions
	lightened.arrays[Mesh.ARRAY_NORMAL] = kept_normals
	lightened.arrays[Mesh.ARRAY_TEX_UV] = kept_uvs
	lightened.arrays[Mesh.ARRAY_TEX_UV2] = kept_masks
	for array: int in [Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1]:
		var whole: PackedFloat32Array = arrays[array]
		var picked := PackedFloat32Array()
		for old in lightened.source:
			picked.append_array(whole.slice(old * WEIGHTS, old * WEIGHTS + WEIGHTS))
		lightened.arrays[array] = picked
	lightened.arrays[Mesh.ARRAY_INDEX] = compacted[1]
	return lightened


## What keeps `rig`'s meshes from merging, a line each (validate).
static func _character_problems(rig: Node3D, recipe: UnifiedCrowdRecipe) -> PackedStringArray:
	var errors: PackedStringArray = []
	var skeleton: Skeleton3D = null
	var used: Dictionary[int, bool] = {}
	for mesh_node in _meshes_of(rig):
		if mesh_node.skin == null:
			var attachment := _attachment_of(mesh_node, rig)
			if attachment == null:
				errors.append("%s: neither skinned nor held by a BoneAttachment3D" % mesh_node.name)
				continue
		else:
			var bound := mesh_node.get_node_or_null(mesh_node.skeleton) as Skeleton3D
			if bound == null:
				errors.append("%s: skinned to no Skeleton3D" % mesh_node.name)
				continue
			if skeleton != null and bound != skeleton:
				errors.append("%s: skinned to another skeleton" % mesh_node.name)
				continue
			skeleton = bound
			if not relative(skeleton, mesh_node).is_equal_approx(Transform3D.IDENTITY):
				errors.append("%s: a skinned mesh sits at its skeleton" % mesh_node.name)
			for bind in mesh_node.skin.get_bind_count():
				if _bind_bone_or_none(skeleton, mesh_node.skin, bind) < 0:
					errors.append("%s: a bind to no bone of the skeleton (%s)" % [mesh_node.name,
						mesh_node.skin.get_bind_name(bind)])
		for surface in mesh_node.mesh.get_surface_count():
			errors.append_array(_surface_problems(mesh_node, surface))
			var mask := _mask_of(mesh_node.get_active_material(surface), recipe)
			if mask > 0:
				used[mask] = true
	if skeleton == null:
		errors.append("%s: no mesh skinned to a Skeleton3D" % rig.name)
		return errors
	for mesh_node in _meshes_of(rig):
		var attachment := _attachment_of(mesh_node, rig)
		if mesh_node.skin == null and attachment != null and skeleton.find_bone(attachment.bone_name) < 0:
			errors.append("%s: held by %s, of no bone of the skeleton" % [mesh_node.name, attachment.name])
	for index in recipe.masked.size():
		if recipe.masked[index] != null and not used.has(index + 1):
			errors.append("masked material %d (%s) draws no part of %s" % [index, recipe.masked[index].resource_path,
				rig.name])
	return errors


## What keeps one surface from merging: not triangles, no normals, a skinned one without bones or with a vertex no
## weight moves.
static func _surface_problems(mesh_node: MeshInstance3D, surface: int) -> PackedStringArray:
	var errors: PackedStringArray = []
	var where := "%s, surface %d" % [mesh_node.name, surface]
	var array_mesh := mesh_node.mesh as ArrayMesh
	if array_mesh != null and array_mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
		errors.append("%s: not triangles" % where)
		return errors
	var arrays := mesh_node.mesh.surface_get_arrays(surface)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals := PackedVector3Array()
	if arrays[Mesh.ARRAY_NORMAL] != null:
		normals = arrays[Mesh.ARRAY_NORMAL]
	if normals.size() != positions.size():
		errors.append("%s: no normals" % where)
	if mesh_node.skin == null:
		return errors
	var vertex_weights := PackedFloat32Array()
	if arrays[Mesh.ARRAY_WEIGHTS] != null and arrays[Mesh.ARRAY_BONES] != null:
		vertex_weights = arrays[Mesh.ARRAY_WEIGHTS]
	if vertex_weights.is_empty():
		errors.append("%s: skinned, with no bones or weights" % where)
		return errors
	var per_vertex := roundi(float(vertex_weights.size()) / positions.size())
	for vertex in positions.size():
		var total := 0.0
		for k in per_vertex:
			total += vertex_weights[vertex * per_vertex + k]
		if not (total > 0.0):
			errors.append("%s: vertex %d has no weight" % [where, vertex])
			break
	return errors


## Where two skins bind a bone apart, a line each.
static func _bind_disagreements(rig: Node3D, skeleton: Skeleton3D) -> PackedStringArray:
	var errors: PackedStringArray = []
	var bound: Dictionary[int, Transform3D] = {}
	for mesh_node in _meshes_of(rig):
		if mesh_node.skin == null:
			continue
		for bind in mesh_node.skin.get_bind_count():
			var bone := _bind_bone_or_none(skeleton, mesh_node.skin, bind)
			var bind_pose := mesh_node.skin.get_bind_pose(bind)
			if bound.has(bone) and not bound[bone].is_equal_approx(bind_pose):
				errors.append("two skins bind %s apart" % skeleton.get_bone_name(bone))
			bound[bone] = bind_pose
	return errors


## The files of `recipe`'s character (inputs): its scene, and each scene, mesh, animation or skin it loads (INPUT_TYPES,
## as each dependency names its type), with an imported one's .import and a glTF's buffers.
static func _input_files(recipe: UnifiedCrowdRecipe) -> PackedStringArray:
	var out: PackedStringArray = []
	var pending: PackedStringArray = [recipe.scene]
	while not pending.is_empty():
		var path := pending[pending.size() - 1]
		pending.remove_at(pending.size() - 1)
		if path in out:
			continue
		out.append(path)
		if FileAccess.file_exists(path + ".import"):
			out.append(path + ".import")
		if path.get_extension() == "gltf":
			for buffer in _gltf_buffers(path):
				if buffer not in out:
					out.append(buffer)
		for dependency in ResourceLoader.get_dependencies(path):
			var slices := dependency.get_slice_count("::")
			var dependency_path := dependency.get_slice("::", slices - 1)
			var dependency_type := dependency.get_slice("::", slices - 2) if slices >= 2 else ""
			if dependency_path.begins_with("uid://"):
				dependency_path = ResourceUID.uid_to_path(dependency_path)
			if dependency_type in INPUT_TYPES and dependency_path not in out:
				pending.append(dependency_path)
	return out


## The files a .gltf's buffers are in (its `buffers[].uri`, beside it; an embedded `data:` buffer is in the file).
static func _gltf_buffers(path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		return out
	var document: Dictionary = parsed
	var buffers: Variant = document.get("buffers", [])
	if not buffers is Array:
		return out
	var listed: Array = buffers
	for buffer: Variant in listed:
		if not buffer is Dictionary:
			continue
		var entry: Dictionary = buffer
		var uri: Variant = entry.get("uri", "")
		if not uri is String:
			continue
		var file: String = uri
		if file != "" and not file.begins_with("data:"):
			out.append(path.get_base_dir().path_join(file.uri_decode()))
	return out


## The surface format a crowd mesh is made with: its bones' indices in CUSTOM0 and their weights in CUSTOM1, as floats.
static func _format() -> int:
	return (
		(Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
	)


## The first AnimationPlayer under `rig`, or null.
static func _player_of(rig: Node) -> AnimationPlayer:
	var found := rig.find_children("*", "AnimationPlayer", true, false)
	return null if found.is_empty() else found[0] as AnimationPlayer


## The meshes a bake merges: every visible MeshInstance3D under `rig`, in tree order.
static func _meshes_of(rig: Node3D) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for found in rig.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := found as MeshInstance3D
		if mesh_node.is_visible_in_tree() and mesh_node.mesh != null:
			out.append(mesh_node)
	return out


## A part drawn with `material`'s mask: its index in `recipe`'s masked plus one (the same resource, or the same
## file), 0 unmasked.
static func _mask_of(material: Material, recipe: UnifiedCrowdRecipe) -> int:
	if material == null:
		return 0
	for index in recipe.masked.size():
		var mask := recipe.masked[index]
		if mask == material or (mask != null and mask.resource_path != "" and mask.resource_path == material.resource_path):
			return index + 1
	return 0


## The bounds of `arrays` (a crowd surface) skinned by `matrices`.
static func _pose_bounds(arrays: Array, matrices: Array[Transform3D]) -> AABB:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var box := AABB(skin_vertex(arrays, 0, matrices), Vector3.ZERO)
	for vertex in range(1, positions.size()):
		box = box.expand(skin_vertex(arrays, vertex, matrices))
	return box


## The vertices `indices` use, in first-use order, and the indices renumbered to them: [vertices, indices].
static func _compact(indices: PackedInt32Array) -> Array[PackedInt32Array]:
	var numbered: Dictionary[int, int] = {}
	var vertices := PackedInt32Array()
	var renumbered := PackedInt32Array()
	for index in indices:
		if not numbered.has(index):
			numbered[index] = vertices.size()
			vertices.append(index)
		renumbered.append(numbered[index])
	return [vertices, renumbered]


## The skeleton bone a skin's bind binds (by name, else by index), or -1.
static func _bind_bone_or_none(skeleton: Skeleton3D, skin: Skin, bind: int) -> int:
	var bind_name := skin.get_bind_name(bind)
	var bone := skeleton.find_bone(bind_name) if bind_name != &"" else skin.get_bind_bone(bind)
	return bone if bone < skeleton.get_bone_count() else -1


## `node`'s transform in `ancestor`'s, from the local transforms between them: the same whatever the pose (one from
## global transforms carries the pose's float noise into the bake).
static func _local_to(ancestor: Node3D, node: Node3D) -> Transform3D:
	var out := Transform3D.IDENTITY
	var current := node
	while current != ancestor:
		out = current.transform * out
		current = current.get_parent() as Node3D
	return out


## The BoneAttachment3D holding `node` (its nearest such ancestor below `rig`), or null.
static func _attachment_of(node: Node, rig: Node) -> BoneAttachment3D:
	var current := node.get_parent()
	while current != null and current != rig:
		if current is BoneAttachment3D:
			return current as BoneAttachment3D
		current = current.get_parent()
	return null


## One surface of one of a character's meshes, as merged (shape): the crowd surface's vertices from `base` on are its.
class Part:
	## The mesh's node.
	var node: MeshInstance3D
	## Its surface.
	var surface: int
	## Its mask in UV2.x (a masked material's index plus one; 0: unmasked).
	var mask: int
	## Its first vertex in the merged surface.
	var base: int
	## Its triangles' indices into the merged surface.
	var indices := PackedInt32Array()


## A character as a crowd surface (shape): the surface's arrays, its parts, and for each of its vertices the merged
## vertex it is (lightening drops some).
class Shape:
	## The crowd surface's arrays (Mesh.ARRAY_*).
	var arrays: Array = []
	## Every part merged, in order.
	var parts: Array[Part] = []
	## Per vertex of `arrays`: the merged vertex it is.
	var source := PackedInt32Array()

	## The part merged vertex `vertex` comes from.
	func part_of(vertex: int) -> Part:
		var found := parts[0]
		for part in parts:
			if part.base <= vertex:
				found = part
		return found


## A character's bake: its mesh (one surface, its custom_aabb every pose's bounds) and its clips, or the errors that
## kept it from baking (then neither).
class Baked:
	## The recipe it was baked by (save() writes where it says).
	var recipe: UnifiedCrowdRecipe
	## The merged, lightened mesh.
	var mesh: ArrayMesh
	## The clip table and its bone matrices.
	var clips: UnifiedCrowdClips
	## Why it didn't bake; empty when it did.
	var errors: PackedStringArray = []

	## Writes the bake where its recipe says: the mesh and the bones as binary resources, the table as text referring to
	## the bones' file. OK, or the first save's error (ERR_INVALID_DATA: nothing was baked).
	func save() -> Error:
		if not errors.is_empty():
			return ERR_INVALID_DATA
		for path: String in [recipe.mesh_path, recipe.bones_path, recipe.clips_path]:
			DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var saved := ResourceSaver.save(mesh, recipe.mesh_path)
		if saved != OK:
			return saved
		saved = ResourceSaver.save(clips.bones, recipe.bones_path)
		if saved != OK:
			return saved
		clips.bones.take_over_path(recipe.bones_path)  # the table refers to the image's file, not a copy of it
		return ResourceSaver.save(clips, recipe.clips_path)
