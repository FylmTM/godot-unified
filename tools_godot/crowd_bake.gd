class_name UnifiedCrowdBake
extends RefCounted
## Bakes a character for a crowd drawn as one MultiMesh: its meshes and props merged into one lighter surface that keeps
## its skin, and its clips baked as bone matrices into an Image (UnifiedCrowdClips) that the crowd's shader skins the
## surface from (crowd_skin.gdshaderinc), so a crowd is one draw call a pass and its animation costs no node. What to
## bake, and where it goes, is a UnifiedCrowdRecipe. A game's tool script calls `bake(recipe, root).save()`;
## UnifiedCrowdCheck proves the committed bake fresh and posing as the character scene does.
##
## A character is a Node3D with one Skeleton3D: meshes skinned to it, props on BoneAttachment3Ds, an AnimationPlayer
## holding the clips, and a way to pose it (UnifiedCrowdRecipe.pose_method). A bone's matrix is the one Godot skins by,
## the bone's pose in the character's space times its skin's bind (every mesh's skin must bind a bone alike), so the
## baked pose is the scene's own. A prop is bound to its attachment's bone with weight 1, through that bone's bind, so
## it needs no bone of its own. A hidden mesh is left out: the scene doesn't draw it either.
##
## The merged surface (merge): positions, normals and UVs, the masked materials' meshes marked in UV2.x, each vertex's
## four strongest bones (skeleton indices) in CUSTOM0 and their weights, summing to 1, in CUSTOM1, as floats (a skinned
## mesh's own bone arrays reach no shader without a skeleton).

## Weights kept per vertex: the shader skins with four.
const WEIGHTS := 4
## The angles generate_lods takes (degrees): normals closer than the first merge, farther than the second split. The
## scene importer's defaults, so the chain is the one Godot makes for a model's own LODs.
const LOD_MERGE_ANGLE := 25.0
const LOD_SPLIT_ANGLE := 60.0
## A clip's length may miss a whole number of its frames by this much (in frames): float noise.
const WHOLE_FRAMES := 0.001


## Bakes `recipe`'s character: its scene instanced under `parent` (in the tree: its poses are computed), baked, and
## freed. The result carries the hash of the bake's inputs, and its errors (then no mesh or clips) when the character
## or the recipe can't be baked.
static func bake(recipe: UnifiedCrowdRecipe, parent: Node) -> Baked:
	var packed := load(recipe.scene) as PackedScene
	if packed == null:
		var failed := Baked.new()
		failed.recipe = recipe
		failed.errors.append("%s: cannot load the character scene" % recipe.scene)
		return failed
	var rig := packed.instantiate() as Node3D
	if rig == null:
		var failed := Baked.new()
		failed.recipe = recipe
		failed.errors.append("%s: the scene's root is no Node3D" % recipe.scene)
		return failed
	parent.add_child(rig)
	var baked := bake_rig(rig, recipe)
	parent.remove_child(rig)
	rig.free()
	if baked.errors.is_empty():
		baked.clips.sources = inputs_hash(recipe)
	return baked


## Bakes `rig` (a character in the tree), posed by `pose` (`(clip, seconds)`; empty: posing(rig, recipe)), as `recipe`
## says. No hash: bake() stamps it.
static func bake_rig(rig: Node3D, recipe: UnifiedCrowdRecipe, pose := Callable()) -> Baked:
	var baked := Baked.new()
	baked.recipe = recipe
	baked.errors = validate(rig, recipe)
	if not baked.errors.is_empty():
		return baked
	if not pose.is_valid():
		pose = posing(rig, recipe)
	var lightened := lighten(merge(rig, recipe), recipe.max_error)
	baked.clips = bake_clips(rig, pose, recipe, lightened.arrays)
	baked.mesh = ArrayMesh.new()
	baked.mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, lightened.arrays, [], {}, format())
	baked.mesh.custom_aabb = baked.clips.bounds
	return baked


## What keeps `rig` from being baked as `recipe` says, a line each (none: it bakes): one skeleton its skinned meshes
## share, each mesh one surface, skinned at its skeleton or held by a BoneAttachment3D, the skins binding each bone
## alike, an AnimationPlayer with every clip, each clip's length a whole number of its frames, a rate per clip.
static func validate(rig: Node3D, recipe: UnifiedCrowdRecipe) -> PackedStringArray:
	var errors: PackedStringArray = []
	if recipe.clips.is_empty():
		errors.append("the recipe has no clips")
	if not recipe.rates.is_empty() and recipe.rates.size() != recipe.clips.size():
		errors.append("the recipe has %d rates for %d clips" % [recipe.rates.size(), recipe.clips.size()])
		return errors
	if recipe.pose_method != &"" and not rig.has_method(recipe.pose_method):
		errors.append("%s: no method %s to pose it" % [rig.name, recipe.pose_method])
	var skeleton: Skeleton3D = null
	for mesh_node in meshes_of(rig):
		if mesh_node.mesh == null or mesh_node.mesh.get_surface_count() != 1:
			errors.append("%s: a crowd's mesh takes one surface a mesh" % mesh_node.name)
		if mesh_node.skin == null:
			if _attachment_of(mesh_node, rig) == null:
				errors.append("%s: neither skinned nor held by a BoneAttachment3D" % mesh_node.name)
			continue
		var bound := mesh_node.get_node_or_null(mesh_node.skeleton) as Skeleton3D
		if bound == null:
			errors.append("%s: skinned to no Skeleton3D" % mesh_node.name)
		elif skeleton != null and bound != skeleton:
			errors.append("%s: skinned to another skeleton" % mesh_node.name)
		else:
			skeleton = bound
			if not relative(skeleton, mesh_node).is_equal_approx(Transform3D.IDENTITY):
				errors.append("%s: a skinned mesh sits at its skeleton" % mesh_node.name)
			for bind in mesh_node.skin.get_bind_count():
				if _bind_bone_or_none(skeleton, mesh_node.skin, bind) < 0:
					errors.append("%s: a bind to no bone of the skeleton (%s)" % [mesh_node.name, mesh_node.skin.get_bind_name(bind)])
	if skeleton == null:
		errors.append("%s: no mesh skinned to a Skeleton3D" % rig.name)
		return errors
	for mesh_node in meshes_of(rig):
		var attachment := _attachment_of(mesh_node, rig)
		if mesh_node.skin == null and attachment != null and skeleton.find_bone(attachment.bone_name) < 0:
			errors.append("%s: held by %s, of no bone of the skeleton" % [mesh_node.name, attachment.name])
	if not errors.is_empty():
		return errors
	errors.append_array(_bind_disagreements(rig, skeleton))
	var player := player_of(rig)
	if player == null:
		errors.append("%s: no AnimationPlayer" % rig.name)
		return errors
	for clip_index in recipe.clips.size():
		var clip := recipe.clips[clip_index]
		if not player.has_animation(clip):
			errors.append("%s: no clip %s" % [player.name, clip])
			continue
		var clip_length := player.get_animation(clip).length
		var frames := clip_length * recipe.rate(clip_index)
		if clip_length <= 0.0:
			errors.append("%s: a clip of no length" % clip)
		elif absf(frames - roundf(frames)) > WHOLE_FRAMES:
			errors.append("%s: %.3f frames at %.1f a second, not a whole number" % [clip, frames, recipe.rate(clip_index)])
	return errors


## How `recipe` poses `rig`: its pose_method, else the rig's AnimationPlayer, a loop wrapped and a one-shot held at its
## ends, seeked at once.
static func posing(rig: Node3D, recipe: UnifiedCrowdRecipe) -> Callable:
	if recipe.pose_method != &"":
		return Callable(rig, recipe.pose_method)
	var player := player_of(rig)
	var loops := recipe.loops
	return func(clip: StringName, seconds: float) -> void:
		if player.current_animation != clip:
			player.play(clip)
		var clip_length := player.get_animation(clip).length
		player.seek(fposmod(seconds, clip_length) if clip in loops else clampf(seconds, 0.0, clip_length), true)


## The surface format a crowd mesh is made with: its bones' indices in CUSTOM0 and their weights in CUSTOM1, as floats.
static func format() -> int:
	return (
		(Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
	)


## The first AnimationPlayer under `rig`, or null.
static func player_of(rig: Node) -> AnimationPlayer:
	var found := rig.find_children("*", "AnimationPlayer", true, false)
	return null if found.is_empty() else found[0] as AnimationPlayer


## The skeleton `rig`'s skinned meshes are bound to (validate holds that there is one).
static func skeleton_of(rig: Node3D) -> Skeleton3D:
	for mesh_node in meshes_of(rig):
		if mesh_node.skin != null:
			return mesh_node.get_node_or_null(mesh_node.skeleton) as Skeleton3D
	return null


## The meshes a bake merges: every visible MeshInstance3D under `rig`, in tree order.
static func meshes_of(rig: Node3D) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for found in rig.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := found as MeshInstance3D
		if mesh_node.is_visible_in_tree():
			out.append(mesh_node)
	return out


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
	for mesh_node in meshes_of(rig):
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


## The skeleton bone a skin's bind binds (by name, else by index).
static func bind_bone(skeleton: Skeleton3D, skin: Skin, bind: int) -> int:
	var bone := _bind_bone_or_none(skeleton, skin, bind)
	assert(bone >= 0, "a bind to no bone of the skeleton: %s" % skin.get_bind_name(bind))
	return bone


## Every mesh of `rig` (meshes_of) merged into one surface's arrays, in its skeleton's bind space (the header says
## what each array holds). A prop is bound to its attachment's bone with weight 1, placed through that bone's bind where
## the attachment holds it.
static func merge(rig: Node3D, recipe: UnifiedCrowdRecipe) -> Merged:
	var merged := Merged.new()
	var skeleton := skeleton_of(rig)
	var bind_poses := binds(rig)
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var masks := PackedVector2Array()
	var bones := PackedFloat32Array()
	var weights := PackedFloat32Array()
	var indices := PackedInt32Array()
	for mesh_node in meshes_of(rig):
		var arrays := mesh_node.mesh.surface_get_arrays(0)
		var source_positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var source_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var source_uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var source_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if source_indices.is_empty():  # an unindexed surface: its vertices in order
			source_indices.resize(source_positions.size())
			for vertex in source_positions.size():
				source_indices[vertex] = vertex
		if source_uvs.is_empty():
			source_uvs.resize(source_positions.size())
		var masked := is_masked(mesh_node.get_active_material(0), recipe)
		var base := positions.size()
		var place := Transform3D.IDENTITY
		var bone_map := PackedInt32Array()
		var source_bones := PackedInt32Array()
		var source_weights := PackedFloat32Array()
		var per_vertex := 0
		if mesh_node.skin != null:
			for bind in mesh_node.skin.get_bind_count():
				bone_map.append(bind_bone(skeleton, mesh_node.skin, bind))
			source_bones = arrays[Mesh.ARRAY_BONES]
			source_weights = arrays[Mesh.ARRAY_WEIGHTS]
			per_vertex = roundi(float(source_bones.size()) / source_positions.size())
		else:
			var attachment := _attachment_of(mesh_node, rig)
			var bone := skeleton.find_bone(attachment.bone_name)
			place = bind_poses[bone].affine_inverse() * relative(attachment, mesh_node)
			bone_map.append(bone)
		var turn := place.basis.inverse().transposed()  # normals turn by the inverse transpose
		for vertex in source_positions.size():
			positions.append(place * source_positions[vertex])
			normals.append((turn * source_normals[vertex]).normalized())
			uvs.append(source_uvs[vertex])
			masks.append(Vector2(1.0 if masked else 0.0, 0.0))
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
		var part := PackedInt32Array()
		for index in source_indices:
			part.append(base + index)
		merged.parts.append(part)
		merged.masked.append(masked)
		merged.meshes.append(mesh_node)
		merged.bases.append(base)
		indices.append_array(part)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = positions
	out[Mesh.ARRAY_NORMAL] = normals
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_TEX_UV2] = masks
	out[Mesh.ARRAY_CUSTOM0] = bones
	out[Mesh.ARRAY_CUSTOM1] = weights
	out[Mesh.ARRAY_INDEX] = indices
	merged.arrays = out
	return merged


## Whether a mesh drawn with `material` is one of `recipe`'s masked ones (the same resource, or the same file).
static func is_masked(material: Material, recipe: UnifiedCrowdRecipe) -> bool:
	if material == null:
		return false
	for mask in recipe.masked:
		if mask == material or (mask != null and mask.resource_path != "" and mask.resource_path == material.resource_path):
			return true
	return false


## A merged character lightened: each of its meshes but the masked ones at the coarsest of Godot's own LODs for it
## whose error is within `max_error` (ImporterMesh.generate_lods, the scene importer's: meshoptimizer, which moves no
## vertex and keeps the normals' and UVs' seams, so a palette atlas stays exact; its error is relative to the mesh's
## size), the vertices no triangle uses dropped. Mesh by mesh, not the merged surface whole: on the whole one the chain
## halves it at each step, and a small part (an eye) collapses first.
static func lighten(merged: Merged, max_error: float) -> Lightened:
	var arrays := merged.arrays
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var kept := PackedInt32Array()
	for index in merged.parts.size():
		var part := merged.parts[index]
		if merged.masked[index] or max_error <= 0.0:
			kept.append_array(part)
			continue
		var local := _compact(part)  # the part alone: its LOD errors are relative to its size
		var shape := []
		shape.resize(Mesh.ARRAY_MAX)
		var part_positions := PackedVector3Array()
		var part_normals := PackedVector3Array()
		var part_uvs := PackedVector2Array()
		for vertex in local[0]:
			part_positions.append(positions[vertex])
			part_normals.append(normals[vertex])
			part_uvs.append(uvs[vertex])
		shape[Mesh.ARRAY_VERTEX] = part_positions
		shape[Mesh.ARRAY_NORMAL] = part_normals
		shape[Mesh.ARRAY_TEX_UV] = part_uvs
		shape[Mesh.ARRAY_INDEX] = local[1]
		var chain := ImporterMesh.new()
		chain.add_surface(Mesh.PRIMITIVE_TRIANGLES, shape)
		chain.generate_lods(LOD_MERGE_ANGLE, LOD_SPLIT_ANGLE, [])
		var lightest: PackedInt32Array = local[1]
		for lod in chain.get_surface_lod_count(0):
			if chain.get_surface_lod_size(0, lod) > max_error:
				break
			lightest = chain.get_surface_lod_indices(0, lod)
		for local_index in lightest:
			kept.append(local[0][local_index])
	var compacted := _compact(kept)
	var lightened := Lightened.new()
	lightened.source = compacted[0]
	lightened.arrays.resize(Mesh.ARRAY_MAX)
	var masks: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var bones: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM1]
	var new_positions := PackedVector3Array()
	var new_normals := PackedVector3Array()
	var new_uvs := PackedVector2Array()
	var new_masks := PackedVector2Array()
	var new_bones := PackedFloat32Array()
	var new_weights := PackedFloat32Array()
	for old in lightened.source:
		new_positions.append(positions[old])
		new_normals.append(normals[old])
		new_uvs.append(uvs[old])
		new_masks.append(masks[old])
		new_bones.append_array(bones.slice(old * WEIGHTS, old * WEIGHTS + WEIGHTS))
		new_weights.append_array(weights.slice(old * WEIGHTS, old * WEIGHTS + WEIGHTS))
	lightened.arrays[Mesh.ARRAY_VERTEX] = new_positions
	lightened.arrays[Mesh.ARRAY_NORMAL] = new_normals
	lightened.arrays[Mesh.ARRAY_TEX_UV] = new_uvs
	lightened.arrays[Mesh.ARRAY_TEX_UV2] = new_masks
	lightened.arrays[Mesh.ARRAY_CUSTOM0] = new_bones
	lightened.arrays[Mesh.ARRAY_CUSTOM1] = new_weights
	lightened.arrays[Mesh.ARRAY_INDEX] = compacted[1]
	return lightened


## `recipe`'s clips baked from `rig`, posed by `pose` (`(clip, seconds)`) as the scene shows them, each at its rate,
## with the bounds every pose sweeps `arrays` (the crowd's surface) through and each clip's last pose's top.
static func bake_clips(rig: Node3D, pose: Callable, recipe: UnifiedCrowdRecipe, arrays: Array) -> UnifiedCrowdClips:
	var player := player_of(rig)
	var skeleton := skeleton_of(rig)
	var bind_poses := binds(rig)
	var bone_count := bind_poses.size()
	var clip_count := recipe.clips.size()
	var first_rows := PackedInt32Array()
	var frame_counts := PackedInt32Array()
	var rows := UnifiedCrowdClips.HEADER_ROWS
	for clip_index in clip_count:
		var frames := roundi(player.get_animation(recipe.clips[clip_index]).length * recipe.rate(clip_index)) + 1
		first_rows.append(rows)
		frame_counts.append(frames)
		rows += frames
	var width := maxi(bone_count * UnifiedCrowdClips.TEXELS_PER_BONE, 1 + clip_count)
	var clips := UnifiedCrowdClips.new()
	clips.clips = recipe.clips.duplicate()
	clips.bones = Image.create_empty(width, rows, false, Image.FORMAT_RGBAF)
	clips.bones.set_pixel(0, 0, Color(clip_count, bone_count, 0, 0))
	for clip_index in clip_count:
		var looping := 1.0 if recipe.clips[clip_index] in recipe.loops else 0.0
		var header := Color(first_rows[clip_index], frame_counts[clip_index], recipe.rate(clip_index), looping)
		clips.bones.set_pixel(1 + clip_index, 0, header)
	var reach := bone_reach(arrays, bind_poses)
	var bounds := AABB()
	var first := true
	for clip_index in clip_count:
		var clip_length := clips.length(clip_index)
		var last := frame_counts[clip_index] - 1
		for frame in frame_counts[clip_index]:
			pose.call(recipe.clips[clip_index], minf(frame / recipe.rate(clip_index), clip_length))
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
				clips.tops.append(_top(arrays, matrices))
	clips.bounds = bounds
	return clips


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


## A hash of what `recipe`'s bake is made from: Godot's version (a new one may import, animate or lighten a model
## otherwise), the recipe (UnifiedCrowdRecipe.describe) and the bytes of its input_files, so a check can tell a
## committed bake from a stale one.
static func inputs_hash(recipe: UnifiedCrowdRecipe) -> String:
	var files := input_files(recipe)
	files.sort()
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	var version: String = Engine.get_version_info()["string"]
	hashing.update(version.to_utf8_buffer())
	hashing.update(recipe.describe().to_utf8_buffer())
	for path in files:
		hashing.update(path.to_utf8_buffer())
		hashing.update(FileAccess.get_file_as_bytes(path))
	return hashing.finish().hex_encode()


## The files `recipe`'s bake reads: its scene, everything that loads (each imported file's source, its .import and a
## glTF's buffer), its masked materials' files, and this script (the bake's code).
static func input_files(recipe: UnifiedCrowdRecipe) -> PackedStringArray:
	var out: PackedStringArray = [(UnifiedCrowdBake as Script).resource_path]
	var pending: PackedStringArray = [recipe.scene]
	for material in recipe.masked:
		if material != null and material.resource_path.begins_with("res://"):
			pending.append(material.resource_path)
	while not pending.is_empty():
		var path := pending[pending.size() - 1]
		pending.remove_at(pending.size() - 1)
		if path in out:
			continue
		out.append(path)
		for extra: String in [path + ".import", path.get_basename() + ".bin"]:
			if FileAccess.file_exists(extra) and extra not in out:
				out.append(extra)
		for dependency in ResourceLoader.get_dependencies(path):
			var dependency_path := dependency.get_slice("::", dependency.get_slice_count("::") - 1)
			if dependency_path.begins_with("uid://"):
				dependency_path = ResourceUID.uid_to_path(dependency_path)
			if dependency_path not in out:
				pending.append(dependency_path)
	return out


## The highest point of `arrays` (a crowd surface) skinned by `matrices`.
static func _top(arrays: Array, matrices: Array[Transform3D]) -> float:
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var top := -INF
	for vertex in positions.size():
		top = maxf(top, skin_vertex(arrays, vertex, matrices).y)
	return top


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


## Where two skins bind a bone apart, a line each.
static func _bind_disagreements(rig: Node3D, skeleton: Skeleton3D) -> PackedStringArray:
	var errors: PackedStringArray = []
	var bound: Dictionary[int, Transform3D] = {}
	for mesh_node in meshes_of(rig):
		if mesh_node.skin == null:
			continue
		for bind in mesh_node.skin.get_bind_count():
			var bone := _bind_bone_or_none(skeleton, mesh_node.skin, bind)
			var bind_pose := mesh_node.skin.get_bind_pose(bind)
			if bound.has(bone) and not bound[bone].is_equal_approx(bind_pose):
				errors.append("two skins bind %s apart" % skeleton.get_bone_name(bone))
			bound[bone] = bind_pose
	return errors


## The BoneAttachment3D holding `node` (its nearest such ancestor below `rig`), or null.
static func _attachment_of(node: Node, rig: Node) -> BoneAttachment3D:
	var current := node.get_parent()
	while current != null and current != rig:
		if current is BoneAttachment3D:
			return current as BoneAttachment3D
		current = current.get_parent()
	return null


## A character's meshes merged (merge): one surface's arrays; each mesh's triangles in it (indices into them), whether
## it is masked, its node, and its first vertex in the arrays.
class Merged:
	## The merged surface's arrays (Mesh.ARRAY_*).
	var arrays: Array
	## Per mesh: its triangles' indices into `arrays`.
	var parts: Array[PackedInt32Array] = []
	## Per mesh: whether it is drawn with a masked material.
	var masked: Array[bool] = []
	## Per mesh: its node.
	var meshes: Array[MeshInstance3D] = []
	## Per mesh: its first vertex in `arrays`.
	var bases: PackedInt32Array = []

	## The mesh (its index in `meshes`) merged vertex `vertex` comes from.
	func mesh_of(vertex: int) -> int:
		var mesh := 0
		while mesh + 1 < bases.size() and bases[mesh + 1] <= vertex:
			mesh += 1
		return mesh


## A merged character lightened (lighten): the crowd surface's arrays, and for each of its vertices the merged vertex it
## is.
class Lightened:
	## The crowd surface's arrays (Mesh.ARRAY_*).
	var arrays: Array = []
	## Per vertex of `arrays`: the merged vertex it is.
	var source: PackedInt32Array = []


## A character's bake: its mesh (one surface, its custom_aabb every pose's bounds) and its clips, or the errors that kept
## it from baking (then neither).
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
