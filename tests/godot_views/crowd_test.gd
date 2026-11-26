# unified's crowd bake (tools_godot/crowd_*.gd, mirrored as res://unified/tools_godot/): run headless by
# `uni test --suite godot-bindings`. A tiny character built here (three bones, a skinned body, a masked eye, a held
# prop; a looping clip and a one-shot, both asymmetric in time) is baked: its texture's header is the clip table, every
# baked frame's matrices are the skeleton's own pose at that frame, the CPU blend wraps a loop and holds a one-shot as
# the rig does, the mesh is merged and masked as the recipe says. UnifiedCrowdCheck passes the bake from its files and
# fails a stale one, and its parity fails each wrong bake: frames off by one, a clip's rows reversed, a loop baked as a
# one-shot. A recipe the bake can't follow is refused with its reason.
# Prints one line per check and "CROWD TESTS: <n> failed"; a failure fails the run.
extends UnifiedTool

const DIR := "user://crowd_test/"
const LOOP := &"Test/Loop"
const ONCE := &"Test/Once"
## How near a baked matrix must come to the skeleton's pose (float noise).
const NEAR := 0.00001
## How much larger than the poses the bounds may be (a bone's box, turned with it, holds its vertices loosely).
const LOOSE := 0.05

var failures := 0


func check(what: String, ok: bool, detail: Variant = "") -> void:
	print("%s %s %s" % ["PASS" if ok else "FAIL", what, str(detail)])
	if not ok:
		failures += 1


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var glow := StandardMaterial3D.new()
	glow.emission_enabled = true
	ResourceSaver.save(glow, DIR + "glow.tres")
	glow = load(DIR + "glow.tres")
	var built := _rig(glow)
	var packed := PackedScene.new()
	packed.pack(built)
	built.free()
	ResourceSaver.save(packed, DIR + "rig.tscn")
	var recipe := _recipe(glow)
	_refusals(recipe)

	var rig := (load(recipe.scene) as PackedScene).instantiate() as Node3D
	root.add_child(rig)
	var baked := UnifiedCrowdBake.bake_rig(rig, recipe)
	check("the character bakes", baked.errors.is_empty(), baked.errors)
	if baked.errors.is_empty():
		_check_table(baked.clips)
		_check_frames(rig, baked.clips)
		_check_blend(rig, baked.clips)
		_check_mesh(rig, baked)
		_check_parity(rig, recipe, baked)
	root.remove_child(rig)
	rig.free()
	_check_files(recipe)
	print("CROWD TESTS: %d failed" % failures)
	if failures > 0:
		fail("%d checks failed" % failures)


## The character: a Node3D (placed and turned in the world, so the bake must work in its space), its Skeleton3D a
## little above it holding three bones (root, arm, hand, a metre apart up the y axis), a 2 m column skinned across them,
## a masked eye on the hand, a prop held by a BoneAttachment3D, and the AnimationPlayer with LOOP (1 s, at 30 a second)
## and ONCE (0.5 s, at 60).
func _rig(glow: Material) -> Node3D:
	var rig := Node3D.new()
	rig.name = "Rig"
	rig.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(30)), Vector3(5, 0, 3))
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton"
	skeleton.position = Vector3(0, 0.1, 0)
	_own(rig, rig, skeleton)
	for bone: Array in [["root", -1, Vector3.ZERO], ["arm", 0, Vector3(0, 1, 0)], ["hand", 1, Vector3(0, 1, 0)]]:
		var bone_name: String = bone[0]
		var parent: int = bone[1]
		var offset: Vector3 = bone[2]
		var index := skeleton.add_bone(bone_name)
		skeleton.set_bone_parent(index, parent)
		skeleton.set_bone_rest(index, Transform3D(Basis.IDENTITY, offset))
		skeleton.reset_bone_pose(index)
	var skin := Skin.new()
	for bone in skeleton.get_bone_count():
		skin.add_named_bind(skeleton.get_bone_name(bone), skeleton.get_bone_global_rest(bone).affine_inverse())
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = _column()
	body.skin = skin
	body.skeleton = NodePath("..")
	_own(rig, skeleton, body)
	var eye := MeshInstance3D.new()
	eye.name = "Eye"
	eye.mesh = _box(Vector3(0.1, 0.1, 0.1), Vector3(0.15, 1.9, 0), 2, glow)
	eye.skin = skin
	eye.skeleton = NodePath("..")
	_own(rig, skeleton, eye)
	var hand := BoneAttachment3D.new()
	hand.name = "Hand"
	hand.bone_name = "hand"
	_own(rig, skeleton, hand)
	var prop := MeshInstance3D.new()
	prop.name = "Prop"
	var prop_mesh := BoxMesh.new()
	prop_mesh.size = Vector3(0.05, 0.6, 0.05)
	prop.mesh = prop_mesh
	prop.position = Vector3(0.2, 0.3, 0)
	_own(rig, hand, prop)
	var player := AnimationPlayer.new()
	player.name = "Player"
	var library := AnimationLibrary.new()
	library.add_animation(&"Loop", _clip(1.0, Animation.LOOP_LINEAR,
		[[0.0, 0.0, 0.0], [0.25, 60.0, -45.0], [1.0, 0.0, 0.0]]))
	library.add_animation(&"Once", _clip(0.5, Animation.LOOP_NONE,
		[[0.0, 0.0, 0.0], [0.1, 70.0, 20.0], [0.5, 90.0, 30.0]]))
	player.add_animation_library(&"Test", library)
	_own(rig, rig, player)
	return rig


func _own(rig: Node, parent: Node, child: Node) -> void:
	parent.add_child(child)
	child.owner = rig


## A clip turning the arm about z and the hand about x: keys of [seconds, arm degrees, hand degrees].
func _clip(clip_length: float, loop: Animation.LoopMode, keys: Array[Array]) -> Animation:
	var clip := Animation.new()
	clip.length = clip_length
	clip.loop_mode = loop
	var arm := clip.add_track(Animation.TYPE_ROTATION_3D)
	clip.track_set_path(arm, NodePath("Skeleton:arm"))
	var hand := clip.add_track(Animation.TYPE_ROTATION_3D)
	clip.track_set_path(hand, NodePath("Skeleton:hand"))
	for key: Array in keys:
		var seconds: float = key[0]
		var arm_degrees: float = key[1]
		var hand_degrees: float = key[2]
		clip.rotation_track_insert_key(arm, seconds, Quaternion(Vector3.BACK, deg_to_rad(arm_degrees)))
		clip.rotation_track_insert_key(hand, seconds, Quaternion(Vector3.RIGHT, deg_to_rad(hand_degrees)))
	return clip


## The body: a 0.2 m by 2 m column from the skeleton up, its rings weighted between the bones around them, eight
## weights a vertex.
func _column() -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = Vector3(0.2, 2, 0.2)
	box.subdivide_height = 3
	var arrays := box.get_mesh_arrays()
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	for vertex in positions.size():
		positions[vertex].y += 1.0
		var height := positions[vertex].y
		var low := 0 if height < 1.0 else 1
		var share := height - low
		# eight slots, the two that weigh last: the bake keeps a vertex's four strongest, wherever they are
		bones.append_array(PackedInt32Array([0, 0, 0, 0, 0, 0, low, low + 1]))
		weights.append_array(PackedFloat32Array([0, 0, 0, 0, 0, 0, 1.0 - share, share]))
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
	return mesh


## A box of `size` at `at`, bound to `bone` alone, drawn with `material`.
func _box(size: Vector3, at: Vector3, bone: int, material: Material) -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = size
	var arrays := box.get_mesh_arrays()
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	for vertex in positions.size():
		positions[vertex] += at
		bones.append_array(PackedInt32Array([bone, 0, 0, 0]))
		weights.append_array(PackedFloat32Array([1, 0, 0, 0]))
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh


func _recipe(glow: Material) -> UnifiedCrowdRecipe:
	var recipe := UnifiedCrowdRecipe.new()
	recipe.scene = DIR + "rig.tscn"
	recipe.clips = [LOOP, ONCE]
	recipe.loops = [LOOP]
	recipe.rates = [30.0, 60.0]
	recipe.masked = [glow]
	recipe.mesh_path = DIR + "mesh.res"
	recipe.bones_path = DIR + "bones.res"
	recipe.clips_path = DIR + "clips.tres"
	return recipe


## A recipe the character can't follow is refused, saying why.
func _refusals(recipe: UnifiedCrowdRecipe) -> void:
	var odd := recipe.duplicate() as UnifiedCrowdRecipe
	odd.rates = [30.0, 25.0]
	var refused := UnifiedCrowdBake.bake(odd, root)
	check("a clip that is no whole number of frames at its rate is refused",
		refused.errors.size() == 1 and refused.errors[0].contains("Once") and refused.mesh == null, refused.errors)
	check("a refused bake saves nothing", refused.save() == ERR_INVALID_DATA)
	var missing := recipe.duplicate() as UnifiedCrowdRecipe
	missing.clips = [LOOP, &"Test/Gone"]
	refused = UnifiedCrowdBake.bake(missing, root)
	check("a clip the AnimationPlayer lacks is refused", refused.errors.size() == 1
		and refused.errors[0].contains("Test/Gone"), refused.errors)


## The header is the clip table: the clips and bones, then each clip's first row, frames, rate and looping.
func _check_table(clips: UnifiedCrowdClips) -> void:
	check("the table names the clips in the recipe's order", clips.clips == [LOOP, ONCE], clips.clips)
	check("the header counts the clips and the skeleton's bones",
		clips.bones.get_pixel(0, 0) == Color(2, 3, 0, 0), clips.bones.get_pixel(0, 0))
	check("the loop: rows from the header's end, 31 frames at 30, looping", clips.first_row(0) == 1
		and clips.frame_count(0) == 31 and clips.rate(0) == 30.0 and clips.loops(0), clips.bones.get_pixel(1, 0))
	check("the one-shot: its rows after the loop's, 31 frames at 60, holding", clips.first_row(1) == 32
		and clips.frame_count(1) == 31 and clips.rate(1) == 60.0 and not clips.loops(1), clips.bones.get_pixel(2, 0))
	check("the texture: three texels a bone, a row a frame after the header",
		clips.bones.get_width() == 9 and clips.bones.get_height() == 63, clips.bones.get_size())
	check("lengths as baked", is_equal_approx(clips.length(0), 1.0) and is_equal_approx(clips.length(1), 0.5))
	check("a clip's index by name", clips.index(ONCE) == 1 and clips.index(&"Test/Gone") == -1)


## Every baked frame's matrices are the skeleton's pose at that frame's time: each bone's pose in the character's space
## times its inverse rest (the skin's bind).
func _check_frames(rig: Node3D, clips: UnifiedCrowdClips) -> void:
	var player := rig.get_node("Player") as AnimationPlayer
	var skeleton := rig.get_node("Skeleton") as Skeleton3D
	var worst := 0.0
	var worst_at := ""
	for clip in clips.clips.size():
		player.play(clips.clips[clip])
		for frame in clips.frame_count(clip):
			player.seek(frame / clips.rate(clip), true)
			var expected := _skeleton_matrices(rig, skeleton)
			for bone in skeleton.get_bone_count():
				var apart := _apart(clips.frame_matrix(clips.first_row(clip) + frame, bone), expected[bone])
				if apart > worst:
					worst = apart
					worst_at = "%s frame %d bone %d" % [clips.clips[clip], frame, bone]
	check("every baked frame is the skeleton's pose at its time", worst <= NEAR, "%f at %s" % [worst, worst_at])


## The CPU blend (the shader's twin) at a baked frame's time is the rig's pose; a loop wraps (before its start and past
## its end), a one-shot holds its first and last frames.
func _check_blend(rig: Node3D, clips: UnifiedCrowdClips) -> void:
	var player := rig.get_node("Player") as AnimationPlayer
	var skeleton := rig.get_node("Skeleton") as Skeleton3D
	var cases: Array[Array] = [
		# [clip, seconds asked, seconds the rig shows, what]
		[0, 0.3, 0.3, "the loop at a frame"],
		[0, 1.3, 0.3, "the loop wraps past its end"],
		[0, -0.7, 0.3, "the loop wraps before its start"],
		[0, 5.0, 0.0, "the loop's whole turns end where it starts"],
		[1, 0.25, 0.25, "the one-shot at a frame"],
		[1, -0.2, 0.0, "the one-shot holds its first frame before its start"],
		[1, 0.9, 0.5, "the one-shot holds its last frame past its end"],
	]
	for case in cases:
		var clip: int = case[0]
		var asked: float = case[1]
		var shown: float = case[2]
		var what: String = case[3]
		player.play(clips.clips[clip])
		player.seek(shown, true)
		var expected := _skeleton_matrices(rig, skeleton)
		var blended := clips.matrices(clip, asked)
		var worst := 0.0
		for bone in expected.size():
			worst = maxf(worst, _apart(blended[bone], expected[bone]))
		check(what, worst <= NEAR, worst)
	var a := clips.frame_matrix(clips.first_row(0) + 3, 1)
	var b := clips.frame_matrix(clips.first_row(0) + 4, 1)
	var between := clips.matrices(0, 3.25 / 30.0)[1]
	check("between two frames the matrices blend entry by entry",
		_apart(between, UnifiedCrowdClips.blend(a, b, 0.25)) <= NEAR)


## The mesh: one surface in the crowd format, every visible mesh merged, the eye masked and nothing else, weights
## summing to 1, the prop bound to the hand, its bounds every pose's.
func _check_mesh(rig: Node3D, baked: UnifiedCrowdBake.Baked) -> void:
	var mesh := baked.mesh
	var arrays := mesh.surface_get_arrays(0)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var masks: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var bones: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM1]
	var sources := 0
	for mesh_node in UnifiedCrowdBake.meshes_of(rig):
		sources += (mesh_node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	check("one surface, bones and weights in CUSTOM0 and CUSTOM1",
		mesh.get_surface_count() == 1 and mesh.surface_get_format(0) & UnifiedCrowdBake.format() == UnifiedCrowdBake.format())
	check("every vertex of the body, the eye and the prop", positions.size() == sources, [positions.size(), sources])
	var masked := 0
	var whole := true
	for vertex in positions.size():
		masked += int(masks[vertex].x == 1.0)
		var total := 0.0
		for k in UnifiedCrowdBake.WEIGHTS:
			total += weights[vertex * UnifiedCrowdBake.WEIGHTS + k]
		whole = whole and absf(total - 1.0) < 0.0001
	check("the eye's 24 vertices are masked, no other", masked == 24, masked)
	check("every vertex's weights sum to 1", whole)
	var last := positions.size() - 1  # the prop is merged last: its bone the hand, weight 1
	check("the prop is bound to the hand alone",
		bones[last * UnifiedCrowdBake.WEIGHTS] == 2.0 and weights[last * UnifiedCrowdBake.WEIGHTS] == 1.0)
	check("the mesh's bounds are the clips' (culling)", mesh.custom_aabb == baked.clips.bounds)
	var bounds := baked.clips.bounds.grow(NEAR)
	var outside := ""
	var top := -INF
	for clip in baked.clips.clips.size():
		for frame in baked.clips.frame_count(clip):
			var matrices := baked.clips.matrices(clip, frame / baked.clips.rate(clip))
			for vertex in positions.size():
				var at := UnifiedCrowdBake.skin_vertex(arrays, vertex, matrices)
				top = maxf(top, at.y)
				if outside == "" and not bounds.has_point(at):
					outside = "%s frame %d vertex %d at %s" % [baked.clips.clips[clip], frame, vertex, at]
	check("every vertex in every baked pose is within the bounds", outside == "", outside)
	check("the bounds reach about as high as the highest pose", absf(baked.clips.bounds.end.y - top) <= LOOSE,
		[baked.clips.bounds.end.y, top])
	check("a top per clip, the one-shot's last pose lower than the upright loop's",
		baked.clips.tops.size() == 2 and baked.clips.tops[1] < baked.clips.tops[0], baked.clips.tops)


## Parity passes the bake, and fails each wrong one: every frame a row late (off by one), the loop's rows reversed (a
## wrong row order), the loop's header saying one-shot (a loop that holds instead of wrapping).
func _check_parity(rig: Node3D, recipe: UnifiedCrowdRecipe, baked: UnifiedCrowdBake.Baked) -> void:
	var good := UnifiedCrowdCheck.new(recipe)
	check("the checks pass the bake", good.check_bake(rig, baked.mesh, baked.clips), _messages(good))
	check("parity: the baked crowd stands where the skeleton puts it", good.worst <= UnifiedCrowdCheck.PARITY,
		"%f at %s" % [good.worst, good.worst_at])
	var merged := UnifiedCrowdBake.merge(rig, recipe)
	var lightened := UnifiedCrowdBake.lighten(merged, recipe.max_error)
	var arrays := baked.mesh.surface_get_arrays(0)
	var wrongs: Dictionary[String, UnifiedCrowdClips] = {}
	var late := _copy(baked.clips)
	for clip in late.clips.size():
		var first := late.first_row(clip)
		for frame in late.frame_count(clip) - 1:
			_copy_row(baked.clips.bones, first + frame + 1, late.bones, first + frame)
	wrongs["frames off by one"] = late
	var reversed := _copy(baked.clips)
	var frames := reversed.frame_count(0)
	for frame in frames:
		_copy_row(baked.clips.bones, reversed.first_row(0) + frame, reversed.bones, reversed.first_row(0) + frames - 1 - frame)
	wrongs["a clip's rows reversed"] = reversed
	var held := _copy(baked.clips)
	var header := held.bones.get_pixel(1, 0)
	held.bones.set_pixel(1, 0, Color(header.r, header.g, header.b, 0.0))
	wrongs["a loop baked as a one-shot"] = held
	for what in wrongs:
		var wrong := UnifiedCrowdCheck.new(recipe)
		var apart := wrong.parity(rig, merged, lightened.source, arrays, wrongs[what])
		check("parity fails a wrong bake: " + what, apart > UnifiedCrowdCheck.PARITY and wrong.problems.size() == 1,
			"%f at %s" % [apart, wrong.worst_at])


## From files: a bake saved where the recipe says passes the full check, and the check calls it stale once the recipe
## changes.
func _check_files(recipe: UnifiedCrowdRecipe) -> void:
	var baked := UnifiedCrowdBake.bake(recipe, root)
	check("the bake from the scene file is stamped with its inputs' hash",
		baked.errors.is_empty() and baked.clips.sources == UnifiedCrowdBake.inputs_hash(recipe))
	check("it saves where the recipe says", baked.save() == OK)
	var saved := load(recipe.clips_path) as UnifiedCrowdClips
	check("the saved table refers to the saved bones", saved != null and saved.bones.resource_path == recipe.bones_path)
	var fresh := UnifiedCrowdCheck.new(recipe)
	check("the full check passes the saved bake", fresh.check(root), _messages(fresh))
	var changed := recipe.duplicate() as UnifiedCrowdRecipe
	changed.masked = []
	var stale := UnifiedCrowdCheck.new(changed)
	stale.check(root)
	check("a changed recipe makes the bake stale",
		_messages(stale).any(func(message: String) -> bool: return message.contains("stale")), _messages(stale))
	check("the include's path is where tools_godot is mirrored",
		FileAccess.file_exists("res://unified/tools_godot/crowd_skin.gdshaderinc"))


func _skeleton_matrices(rig: Node3D, skeleton: Skeleton3D) -> Array[Transform3D]:
	var to_rig := rig.global_transform.affine_inverse() * skeleton.global_transform
	var out: Array[Transform3D] = []
	for bone in skeleton.get_bone_count():
		out.append(to_rig * skeleton.get_bone_global_pose(bone) * skeleton.get_bone_global_rest(bone).affine_inverse())
	return out


## The largest difference between two matrices' entries.
func _apart(a: Transform3D, b: Transform3D) -> float:
	var most := 0.0
	for column in 4:
		var x: Vector3 = a.basis[column] if column < 3 else a.origin
		var y: Vector3 = b.basis[column] if column < 3 else b.origin
		most = maxf(most, (x - y).abs()[(x - y).abs().max_axis_index()])
	return most


func _copy(clips: UnifiedCrowdClips) -> UnifiedCrowdClips:
	var copy := clips.duplicate() as UnifiedCrowdClips
	copy.bones = clips.bones.duplicate() as Image
	return copy


func _copy_row(from: Image, from_row: int, to: Image, to_row: int) -> void:
	for x in from.get_width():
		to.set_pixel(x, to_row, from.get_pixel(x, from_row))


func _messages(crowd_check: UnifiedCrowdCheck) -> Array[String]:
	var out: Array[String] = []
	for problem in crowd_check.problems:
		out.append("%s: %s" % [problem.path, problem.message])
	return out
