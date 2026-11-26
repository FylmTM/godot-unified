# unified's crowd bake (tools_godot/crowd_*.gd and godot_runtime/crowd_*, mirrored under res://unified/): run headless
# by `uni test --suite godot-bindings`. A small character built here (three bones; a two-surface skinned body, one
# surface of eight weights a vertex and one masked with more than four; a dense head; a masked eye; a hidden mesh; a
# turned prop on a BoneAttachment3D; a looping clip, a one-shot, a snap and a hand-only clip at a rate no 32-bit float
# holds, each asymmetric in time) is baked and checked against its skeleton: the header, every frame (each clip's own,
# though the player blends between them), the CPU blend's wrap and hold, the mesh (parts, masks, weights, normals,
# bounds), the lightening, the refusals, the hash of its inputs, and the check passing the bake and failing each wrong
# one. The skinning include compiles in a spatial shader.
# Prints one line per check and "CROWD TESTS: <n> failed"; a failure fails the run.
extends UnifiedTool

const DIR := "user://crowd_test/"
const LOOP := &"Test/Loop"
const ONCE := &"Test/Once"
const SNAP := &"Test/Snap"
const WAVE := &"Test/Wave"
## WAVE's rate, which no 32-bit float holds exactly (the bone texture's header keeps it in one).
const ODD_RATE := 29.97
## How near a baked matrix must come to the skeleton's pose (float noise).
const NEAR := 0.00001
## How much larger than the poses the bounds may be (a bone's box, turned with it, holds its vertices loosely).
const LOOSE := 0.25
## The prop's turn on its attachment: its normals must turn with it.
const PROP_TURN := Vector3(0, 0, 1)
## How near a baked normal must come to the expected one (a mesh stores its normals compressed).
const NORMALS := 0.01
## The band's weights, six a vertex: the bake keeps the strongest four (the two it drops are too light for parity to
## see) and makes them sum to 1.
const BAND_WEIGHTS: Array[float] = [0.5, 0.3, 0.19, 0.008, 0.001, 0.001, 0, 0]
const INCLUDE := "res://unified/godot_runtime/crowd_skin.gdshaderinc"

var failures := 0
var _glow: Material
var _team: Material


func check(what: String, ok: bool, detail: Variant = "") -> void:
	print("%s %s %s" % ["PASS" if ok else "FAIL", what, str(detail)])
	if not ok:
		failures += 1


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	_glow = _saved_material("glow", Color(1, 1, 0.2))
	_team = _saved_material("team", Color(0.2, 0.3, 1))
	_save_rig()
	var recipe := _recipe()
	_check_shader()
	_refusals(recipe)
	var rig := _instance(recipe)
	var baked := UnifiedCrowdBake.bake_rig(rig, recipe)
	check("the character bakes", baked.errors.is_empty(), baked.errors)
	if baked.errors.is_empty():
		_check_table(baked.clips)
		_check_frames(rig, baked.clips)
		_check_blend(rig, baked.clips)
		_check_mesh(rig, baked)
		_check_lightening(rig, recipe, baked)
		_check_parity(rig, recipe, baked)
		_check_corruptions(rig, recipe, baked)
	_free(rig)
	_check_own_poses(recipe)
	_check_worst_pair(recipe)
	_check_files(recipe)
	print("CROWD TESTS: %d failed" % failures)
	if failures > 0:
		fail("%d checks failed" % failures)


func _saved_material(material_name: String, color: Color) -> Material:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	var path := DIR + material_name + ".tres"
	ResourceSaver.save(material, path)
	return load(path)


## The character, saved as DIR/rig.tscn: a Node3D (placed and turned in the world, so the bake must work in its
## space), its Skeleton3D a little above it holding three bones (root, arm, hand, a metre apart up the y axis); the
## body a 2 m column (eight weight slots, the two that weigh last) and a band round the arm (masked by `team`, six
## weights a vertex); a dense head on the hand; a masked eye; a hidden box; a turned prop held by a BoneAttachment3D;
## and the AnimationPlayer: LOOP (1 s, looping in its Animation), ONCE (0.5 s), SNAP (1 s, still but for a 170°
## turn between 0.4 and 0.5 s) and WAVE (30 frames at ODD_RATE, keying the hand alone).
func _save_rig() -> void:
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
	var skin := _skin(skeleton)
	var body := _skinned("Body", _body(), skin)
	_own(rig, skeleton, body)
	var head := SphereMesh.new()
	head.radius = 0.25
	head.height = 0.5
	head.radial_segments = 48
	head.rings = 24
	_own(rig, skeleton, _skinned("Head", _bound(head, Vector3(0, 2.3, 0), 2, null), skin))
	var eye := SphereMesh.new()
	eye.radius = 0.05
	eye.height = 0.1
	_own(rig, skeleton, _skinned("Eye", _bound(eye, Vector3(0.12, 2.35, 0.2), 2, _glow), skin))
	var hidden := _skinned("Hidden", _bound(BoxMesh.new(), Vector3(0, 1, 0), 1, null), skin)
	hidden.visible = false
	_own(rig, skeleton, hidden)
	var hand := BoneAttachment3D.new()
	hand.name = "Hand"
	hand.bone_name = "hand"
	_own(rig, skeleton, hand)
	var prop := MeshInstance3D.new()
	prop.name = "Prop"
	var prop_mesh := BoxMesh.new()
	prop_mesh.size = Vector3(0.05, 0.6, 0.1)
	prop.mesh = prop_mesh
	prop.transform = Transform3D(Basis(PROP_TURN, deg_to_rad(90)), Vector3(0.2, 0.3, 0))
	_own(rig, hand, prop)
	var player := AnimationPlayer.new()
	player.name = "Player"
	var library := AnimationLibrary.new()
	library.add_animation(&"Loop", _clip(1.0, Animation.LOOP_LINEAR,
		[[0.0, 0.0, 0.0], [0.25, 60.0, -45.0], [1.0, 0.0, 0.0]]))
	library.add_animation(&"Once", _clip(0.5, Animation.LOOP_NONE,
		[[0.0, 0.0, 0.0], [0.1, 70.0, 20.0], [0.5, 90.0, 30.0]]))
	library.add_animation(&"Snap", _clip(1.0, Animation.LOOP_NONE,
		[[0.0, 0.0, 0.0], [0.4, 0.0, 0.0], [0.5, 170.0, 0.0], [1.0, 170.0, 0.0]]))
	var wave_length := 30.0 / ODD_RATE
	library.add_animation(&"Wave", _clip(wave_length, Animation.LOOP_NONE,
		[[0.0, 0.0, 0.0], [0.5, 0.0, 80.0], [wave_length, 0.0, 40.0]], false))
	player.add_animation_library(&"Test", library)
	_own(rig, rig, player)
	var packed := PackedScene.new()
	packed.pack(rig)
	rig.free()
	ResourceSaver.save(packed, DIR + "rig.tscn")


func _own(rig: Node, parent: Node, child: Node) -> void:
	parent.add_child(child)
	child.owner = rig


func _skin(skeleton: Skeleton3D) -> Skin:
	var skin := Skin.new()
	for bone in skeleton.get_bone_count():
		skin.add_named_bind(skeleton.get_bone_name(bone), skeleton.get_bone_global_rest(bone).affine_inverse())
	return skin


func _skinned(node_name: String, mesh: Mesh, skin: Skin) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.skin = skin
	node.skeleton = NodePath("..")
	return node


## A clip turning the arm about z (unless `keys_arm` is false: it leaves the arm alone) and the hand about x: keys of
## [seconds, arm degrees, hand degrees].
func _clip(clip_length: float, loop: Animation.LoopMode, keys: Array[Array], keys_arm := true) -> Animation:
	var clip := Animation.new()
	clip.length = clip_length
	clip.loop_mode = loop
	var arm := -1
	if keys_arm:
		arm = clip.add_track(Animation.TYPE_ROTATION_3D)
		clip.track_set_path(arm, NodePath("Skeleton:arm"))
	var hand := clip.add_track(Animation.TYPE_ROTATION_3D)
	clip.track_set_path(hand, NodePath("Skeleton:hand"))
	for key: Array in keys:
		var seconds: float = key[0]
		var arm_degrees: float = key[1]
		var hand_degrees: float = key[2]
		if keys_arm:
			clip.rotation_track_insert_key(arm, seconds, Quaternion(Vector3.BACK, deg_to_rad(arm_degrees)))
		clip.rotation_track_insert_key(hand, seconds, Quaternion(Vector3.RIGHT, deg_to_rad(hand_degrees)))
	return clip


## The body: a 0.2 m by 2 m column from the skeleton up, its rings weighted between the bones around them (eight slots,
## the two that weigh last: the bake keeps a vertex's four strongest, wherever they are); and a band round the arm,
## drawn with `team`, six weights a vertex (the bake keeps four and makes them sum to 1).
func _body() -> ArrayMesh:
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
		bones.append_array(PackedInt32Array([0, 0, 0, 0, 0, 0, low, low + 1]))
		weights.append_array(PackedFloat32Array([0, 0, 0, 0, 0, 0, 1.0 - share, share]))
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
	var band := BoxMesh.new()
	band.size = Vector3(0.3, 0.2, 0.3)
	var band_arrays := band.get_mesh_arrays()
	var band_positions: PackedVector3Array = band_arrays[Mesh.ARRAY_VERTEX]
	var band_bones := PackedInt32Array()
	var band_weights := PackedFloat32Array()
	for vertex in band_positions.size():
		band_positions[vertex].y += 1.2
		band_bones.append_array(PackedInt32Array([1, 2, 0, 1, 2, 0, 0, 0]))
		band_weights.append_array(PackedFloat32Array(BAND_WEIGHTS))
	band_arrays[Mesh.ARRAY_VERTEX] = band_positions
	band_arrays[Mesh.ARRAY_BONES] = band_bones
	band_arrays[Mesh.ARRAY_WEIGHTS] = band_weights
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, band_arrays, [], {}, Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
	mesh.surface_set_material(1, _team)
	return mesh


## `source`'s first surface at `at`, bound to `bone` alone, drawn with `material`.
func _bound(source: PrimitiveMesh, at: Vector3, bone: int, material: Material) -> ArrayMesh:
	var arrays := source.get_mesh_arrays()
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


func _recipe() -> UnifiedCrowdRecipe:
	var recipe := UnifiedCrowdRecipe.new()
	recipe.scene = DIR + "rig.tscn"
	recipe.clips = [UnifiedCrowdClip.new(LOOP, 30.0), UnifiedCrowdClip.new(ONCE, 60.0, UnifiedCrowdClip.Loop.HOLDS)]
	recipe.masked = [_glow, _team]
	recipe.mesh_path = DIR + "mesh.res"
	recipe.bones_path = DIR + "bones.res"
	recipe.clips_path = DIR + "clips.tres"
	return recipe


func _instance(recipe: UnifiedCrowdRecipe) -> Node3D:
	var rig := (load(recipe.scene) as PackedScene).instantiate() as Node3D
	root.add_child(rig)
	return rig


func _free(rig: Node3D) -> void:
	root.remove_child(rig)
	rig.free()


## The include compiles in a spatial shader (Godot's headless renderer parses it: an error is an ERROR line, which
## fails the suite) and declares the uniform UnifiedCrowdClips.apply sets; apply makes the texture once.
func _check_shader() -> void:
	var shader := Shader.new()
	shader.code = ("shader_type spatial;\n#include \"%s\"\nvoid vertex() {\n" % INCLUDE
		+ "\tmat4 skin = unified_crowd_skinning(1, 0.25, CUSTOM0, CUSTOM1);\n"
		+ "\tVERTEX = (skin * vec4(VERTEX, 1.0)).xyz;\n\tNORMAL = normalize(mat3(skin) * NORMAL);\n"
		+ "\tfloat seconds = unified_crowd_clip_length(0) + float(unified_crowd_clip_count());\n}\n")
	var uniforms := shader.get_shader_uniform_list()
	var declared := uniforms.any(func(uniform: Dictionary) -> bool:
		return uniform["name"] == String(UnifiedCrowdClips.BONES_PARAMETER) and uniform["type"] == TYPE_OBJECT)
	check("a spatial shader with the include compiles, its one uniform the bone texture", uniforms.size() == 1
		and declared, uniforms)
	check("the include declares `uniform sampler2D <BONES_PARAMETER>`", FileAccess.get_file_as_string(INCLUDE).contains(
		"uniform sampler2D %s " % UnifiedCrowdClips.BONES_PARAMETER))


## A recipe the character can't follow is refused, saying why; nothing of a refused bake is saved.
func _refusals(recipe: UnifiedCrowdRecipe) -> void:
	var cases: Array[Array] = []  # [what, recipe, words the error has]
	var odd := _copy_recipe(recipe)
	odd.clips[1].rate = 25.0
	cases.append(["a clip that is no whole number of frames at its rate", odd, "not a whole number"])
	var missing := _copy_recipe(recipe)
	missing.clips[1] = UnifiedCrowdClip.new(&"Test/Gone")
	cases.append(["a clip the AnimationPlayer lacks (a name's typo)", missing, "no clip Test/Gone"])
	var still := _copy_recipe(recipe)
	still.clips[0].rate = 0.0
	cases.append(["a rate of 0", still, "less than a frame"])
	var slow := _copy_recipe(recipe)
	slow.clips[1].rate = 0.5
	cases.append(["a clip shorter than half a frame", slow, "less than a frame"])
	var held := _copy_recipe(recipe)
	held.clips[0].loop = UnifiedCrowdClip.Loop.HOLDS
	cases.append(["a recipe holding a clip its Animation loops", held, "its Animation that it loops"])
	var twice := _copy_recipe(recipe)
	twice.clips.append(UnifiedCrowdClip.new(LOOP))
	cases.append(["a clip twice", twice, "twice"])
	var nowhere := _copy_recipe(recipe)
	nowhere.bones_path = ""
	cases.append(["no path for the bake", nowhere, "not where to keep"])
	var unused := _copy_recipe(recipe)
	unused.masked = [_glow, _team, StandardMaterial3D.new()]
	cases.append(["a masked material no part is drawn with", unused, "draws no part"])
	var tall := _copy_recipe(recipe)
	tall.clips[0].rate = 20000.0
	cases.append(["a texture over 16384 rows", tall, "over 16384"])
	for case in cases:
		var what: String = case[0]
		var refused: UnifiedCrowdRecipe = case[1]
		var words: String = case[2]
		var baked := UnifiedCrowdBake.bake(refused, root)
		check("refused: " + what, baked.mesh == null and "\n".join(baked.errors).contains(words), baked.errors)
	var failed := UnifiedCrowdBake.bake(odd, root)
	check("a refused bake saves nothing", failed.save() == ERR_INVALID_DATA)
	# a character's own faults, each added to an instance of the good one
	var faults: Array[Array] = [
		["a vertex no weight moves", "has no weight"],
		["a surface without normals", "no normals"],
		["two skins binding a bone apart", "two skins bind arm apart"],
	]
	for index in faults.size():
		var rig := _instance(recipe)
		var skeleton := rig.get_node("Skeleton") as Skeleton3D
		var mesh := _bound(BoxMesh.new(), Vector3.ZERO, 1, null)
		var skin := _skin(skeleton)
		if index == 0:
			var arrays := mesh.surface_get_arrays(0)
			var weights := PackedFloat32Array()
			weights.resize((arrays[Mesh.ARRAY_WEIGHTS] as PackedFloat32Array).size())
			arrays[Mesh.ARRAY_WEIGHTS] = weights
			mesh = ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		elif index == 1:
			var arrays := mesh.surface_get_arrays(0)
			arrays[Mesh.ARRAY_NORMAL] = null
			arrays[Mesh.ARRAY_TANGENT] = null
			mesh = ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		else:
			skin.set_bind_pose(1, Transform3D(Basis.IDENTITY, Vector3(0, -2, 0)))
		skeleton.add_child(_skinned("Fault", mesh, skin))
		var errors := UnifiedCrowdBake.validate(rig, recipe)
		check("refused: " + (faults[index][0] as String), "\n".join(errors).contains(faults[index][1] as String), errors)
		_free(rig)
	_check_wide_refused()


## A skeleton of more bones than a texture row holds (three texels each) is refused.
func _check_wide_refused() -> void:
	var rig := Node3D.new()
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton"
	rig.add_child(skeleton)
	for bone in int(UnifiedCrowdClips.MAX_SIDE / float(UnifiedCrowdClips.TEXELS_PER_BONE)) + 1:
		skeleton.add_bone("b%d" % bone)
	skeleton.add_child(_skinned("Body", _bound(BoxMesh.new(), Vector3.ZERO, 0, null), _skin(skeleton)))
	var player := AnimationPlayer.new()
	var library := AnimationLibrary.new()
	var clip := Animation.new()
	clip.length = 1.0
	library.add_animation(&"Still", clip)
	player.add_animation_library(&"Test", library)
	rig.add_child(player)
	root.add_child(rig)
	var recipe := _recipe()
	recipe.masked = []
	recipe.clips = [UnifiedCrowdClip.new(&"Test/Still")]
	var errors := UnifiedCrowdBake.validate(rig, recipe)
	check("refused: a texture over 16384 texels wide", "\n".join(errors).contains("over 16384"), errors)
	_free(rig)


func _copy_recipe(recipe: UnifiedCrowdRecipe) -> UnifiedCrowdRecipe:
	var copy := recipe.duplicate() as UnifiedCrowdRecipe
	copy.clips = []
	for clip in recipe.clips:
		copy.clips.append(UnifiedCrowdClip.new(clip.animation, clip.rate, clip.loop))
	copy.masked = recipe.masked.duplicate()
	return copy


## The header is the clip table: the clips and bones, then each clip's first row, frames, rate and looping (the loop's
## from its Animation, the one-shot's said).
func _check_table(clips: UnifiedCrowdClips) -> void:
	check("the table names the clips in the recipe's order", clips.clips == [LOOP, ONCE], clips.clips)
	check("the header counts the clips and the skeleton's bones",
		clips.bones.get_pixel(0, 0) == Color(2, 3, 0, 0), clips.bones.get_pixel(0, 0))
	check("the loop: rows from the header's end, 31 frames at 30, looping as its Animation does", clips.first_row(0) == 1
		and clips.frame_count(0) == 31 and clips.rate(0) == 30.0 and clips.loops(0), clips.bones.get_pixel(1, 0))
	check("the one-shot: its rows after the loop's, 31 frames at 60, holding", clips.first_row(1) == 32
		and clips.frame_count(1) == 31 and clips.rate(1) == 60.0 and not clips.loops(1), clips.bones.get_pixel(2, 0))
	check("the texture: three texels a bone, a row a frame after the header",
		clips.bones.get_width() == 9 and clips.bones.get_height() == 63, clips.bones.get_size())
	check("lengths as baked", is_equal_approx(clips.length(0), 1.0) and is_equal_approx(clips.length(1), 0.5))
	check("a clip's index by name", clips.index(ONCE) == 1 and clips.index(&"Test/Gone") == -1)
	var first := ShaderMaterial.new()
	var second := ShaderMaterial.new()
	clips.apply(first)
	clips.apply(second)
	var texture: Variant = first.get_shader_parameter(UnifiedCrowdClips.BONES_PARAMETER)
	check("apply sets one texture, made once", texture is ImageTexture
		and texture == second.get_shader_parameter(UnifiedCrowdClips.BONES_PARAMETER))


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


## The mesh: one surface in the crowd format, every visible surface merged (the hidden mesh not), each masked by its
## material's index plus one, weights summing to 1 (the band's six made four), the prop bound to the hand with its
## normals turned as it is, the bounds every pose's and each clip's last pose's.
func _check_mesh(rig: Node3D, baked: UnifiedCrowdBake.Baked) -> void:
	var mesh := baked.mesh
	var arrays := mesh.surface_get_arrays(0)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var masks: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var bones: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM1]
	var counts: Dictionary[String, int] = {}  # per visible part, its vertices
	var order: Array[String] = []
	for mesh_node: Node in rig.find_children("*", "MeshInstance3D", true, false):
		var shown := mesh_node as MeshInstance3D
		if not shown.is_visible_in_tree():
			continue
		for surface in shown.mesh.get_surface_count():
			var part := "%s/%d" % [shown.name, surface]
			counts[part] = (shown.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			order.append(part)
	var total := 0
	for part in order:
		total += counts[part]
	check("one surface, bones and weights in CUSTOM0 and CUSTOM1", mesh.get_surface_count() == 1
		and mesh.surface_get_format(0) & Mesh.ARRAY_FORMAT_CUSTOM0 != 0
		and mesh.surface_get_format(0) & Mesh.ARRAY_FORMAT_CUSTOM1 != 0)
	check("every visible surface merged, the hidden mesh left out", positions.size() == total and order == [
		"Body/0", "Body/1", "Head/0", "Eye/0", "Prop/0"], [positions.size(), total, order])
	var expected_masks: Dictionary[String, float] = {"Body/0": 0, "Body/1": 2, "Head/0": 0, "Eye/0": 1, "Prop/0": 0}
	var base := 0
	var masked_right := true
	for part in order:
		for vertex in range(base, base + counts[part]):
			masked_right = masked_right and masks[vertex].x == expected_masks[part]
		base += counts[part]
	check("each part masked by its material's index plus one (the eye 1, the band 2, the rest 0)", masked_right)
	var whole := true
	for vertex in positions.size():
		var sum := 0.0
		for k in UnifiedCrowdBake.WEIGHTS:
			sum += weights[vertex * UnifiedCrowdBake.WEIGHTS + k]
		whole = whole and absf(sum - 1.0) < 0.0001
	check("every vertex's weights sum to 1 (the band's strongest four of six)", whole)
	var band := counts["Body/0"]
	check("the band keeps its strongest four, made to sum to 1", is_equal_approx(weights[band * 4], 0.5 / 0.998)
		and bones[band * 4] == 1.0, weights.slice(band * 4, band * 4 + 4))
	var prop := positions.size() - counts["Prop/0"]
	check("the prop is bound to the hand alone",
		bones[prop * UnifiedCrowdBake.WEIGHTS] == 2.0 and weights[prop * UnifiedCrowdBake.WEIGHTS] == 1.0)
	var skeleton := rig.get_node("Skeleton") as Skeleton3D
	var prop_node := rig.get_node("Skeleton/Hand/Prop") as MeshInstance3D
	var at_rest := skeleton.get_bone_global_rest(skeleton.find_bone("hand")) * prop_node.transform
	var prop_normals: PackedVector3Array = prop_node.mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	var shaped := UnifiedCrowdBake.shape(rig, baked.recipe)  # the merged vertex each baked one is (first-use order)
	var prop_base := shaped.parts[shaped.parts.size() - 1].base
	var turned := true
	for vertex in range(prop, positions.size()):
		var expected := (at_rest.basis * prop_normals[shaped.source[vertex] - prop_base]).normalized()
		turned = turned and normals[vertex].distance_to(expected) <= NORMALS
	check("the prop's normals turn as it is turned", turned)
	check("the mesh's bounds are the clips' (culling)", mesh.custom_aabb == baked.clips.bounds)
	var bounds := baked.clips.bounds.grow(NEAR)
	var outside := ""
	var top := -INF
	var last_right := true
	for clip in baked.clips.clips.size():
		for frame in baked.clips.frame_count(clip):
			var matrices := baked.clips.matrices(clip, frame / baked.clips.rate(clip))
			var pose_box := AABB()
			for vertex in positions.size():
				var at := UnifiedCrowdBake.skin_vertex(arrays, vertex, matrices)
				pose_box = AABB(at, Vector3.ZERO) if vertex == 0 else pose_box.expand(at)
				top = maxf(top, at.y)
				if outside == "" and not bounds.has_point(at):
					outside = "%s frame %d vertex %d at %s" % [baked.clips.clips[clip], frame, vertex, at]
			if frame == baked.clips.frame_count(clip) - 1:
				var last := baked.clips.last_bounds[clip]
				last_right = last_right and last.position.distance_to(pose_box.position) <= NEAR and last.end.distance_to(
					pose_box.end) <= NEAR
	check("every vertex in every baked pose is within the bounds", outside == "", outside)
	check("the bounds reach about as high as the highest pose", absf(baked.clips.bounds.end.y - top) <= LOOSE,
		[baked.clips.bounds.end.y, top])
	check("each clip's last bounds are its last pose's, every vertex", last_right, baked.clips.last_bounds)


## Lightened (a max_error over 0): the dense head loses triangles, the masked eye and band keep every one, and the
## lighter bake still passes the check.
func _check_lightening(rig: Node3D, recipe: UnifiedCrowdRecipe, baked: UnifiedCrowdBake.Baked) -> void:
	var light := _copy_recipe(recipe)
	light.max_error = 0.3
	var lighter := UnifiedCrowdBake.bake_rig(rig, light)
	var whole := _triangles_by_mask(baked.mesh)
	var lightened := _triangles_by_mask(lighter.mesh)
	check("lightened: the unmasked parts lose triangles", lightened[0] < whole[0] * 0.6, [whole, lightened])
	check("lightened: the masked parts keep every triangle", lightened[1] == whole[1] and lightened[2] == whole[2],
		[whole, lightened])
	var lighter_check := UnifiedCrowdCheck.new(light)
	check("the check passes the lightened bake", lighter_check.check_bake(rig, lighter.mesh, lighter.clips),
		_messages(lighter_check))


## Per mask (0, 1, 2), the triangles of `mesh` whose first vertex has it.
func _triangles_by_mask(mesh: ArrayMesh) -> Array[int]:
	var arrays := mesh.surface_get_arrays(0)
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var masks: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var out: Array[int] = [0, 0, 0]
	for triangle in range(0, indices.size(), 3):
		out[int(masks[indices[triangle]].x)] += 1
	return out


## Parity passes the bake, and fails each wrong one: every frame a row late (off by one), the loop's rows reversed (a
## wrong row order), the loop's header saying one-shot (a loop that holds instead of wrapping).
func _check_parity(rig: Node3D, recipe: UnifiedCrowdRecipe, baked: UnifiedCrowdBake.Baked) -> void:
	var good := UnifiedCrowdCheck.new(recipe)
	check("the checks pass the bake", good.check_bake(rig, baked.mesh, baked.clips), _messages(good))
	check("parity: the baked crowd stands where the skeleton puts it", good.worst <= UnifiedCrowdCheck.PARITY,
		"%f at %s" % [good.worst, good.worst_at])
	var shaped := UnifiedCrowdBake.shape(rig, recipe)
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
	var first_row := reversed.first_row(0)
	for frame in frames:
		_copy_row(baked.clips.bones, first_row + frame, reversed.bones, first_row + frames - 1 - frame)
	wrongs["a clip's rows reversed"] = reversed
	var held := _copy(baked.clips)
	var header := held.bones.get_pixel(1, 0)
	held.bones.set_pixel(1, 0, Color(header.r, header.g, header.b, 0.0))
	wrongs["a loop baked as a one-shot"] = held
	for what in wrongs:
		var wrong := UnifiedCrowdCheck.new(recipe)
		var apart := wrong.parity(rig, shaped, arrays, wrongs[what])
		check("parity fails a wrong bake: " + what, apart > UnifiedCrowdCheck.PARITY and wrong.problems.size() == 1,
			"%f at %s" % [apart, wrong.worst_at])


## Each of the check's parts catches what only it sees: a matrix off by less than parity notices (fresh), a UV moved
## (the mesh against a bake now), a vertex masked as no part is (the masks against the scene's materials), a position
## moved past float noise (one within it passes), a mesh over the recipe's triangles (its rules).
func _check_corruptions(rig: Node3D, recipe: UnifiedCrowdRecipe, baked: UnifiedCrowdBake.Baked) -> void:
	var nudged := _copy(baked.clips)
	var texel := nudged.bones.get_pixel(3, 5)
	nudged.bones.set_pixel(3, 5, Color(texel.r, texel.g, texel.b, texel.a + 0.0005))
	_expect_problem("a matrix nudged half a millimetre", recipe, rig, baked.mesh, nudged, "a bake now differs")
	var arrays := baked.mesh.surface_get_arrays(0)
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	uvs[0] += Vector2(0.01, 0)
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	_expect_problem("a UV moved", recipe, rig, _mesh_of(arrays, baked.mesh), baked.clips, "UVs are not a bake's now")
	arrays = baked.mesh.surface_get_arrays(0)
	var masks: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var eye := masks.find(Vector2(1, 0))
	masks[eye] = Vector2.ZERO
	arrays[Mesh.ARRAY_TEX_UV2] = masks
	_expect_problem("an eye vertex unmasked", recipe, rig, _mesh_of(arrays, baked.mesh), baked.clips,
		"crowd vertex %d is masked 0, its scene part (Eye, surface 0) 1" % eye)
	arrays = baked.mesh.surface_get_arrays(0)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	positions[0] += Vector3(0.000002, 0, 0)
	arrays[Mesh.ARRAY_VERTEX] = positions
	var noisy := UnifiedCrowdCheck.new(recipe)
	check("the check passes a position a bake's within float noise", noisy.check_bake(rig, _mesh_of(arrays, baked.mesh),
		baked.clips), _messages(noisy))
	positions[0] += Vector3(0.001, 0, 0)
	arrays[Mesh.ARRAY_VERTEX] = positions
	_expect_problem("a position moved a millimetre", recipe, rig, _mesh_of(arrays, baked.mesh), baked.clips,
		"positions are not a bake's now")
	var capped := _copy_recipe(recipe)
	capped.max_triangles = 10
	_expect_problem("a mesh over the recipe's triangles", capped, rig, baked.mesh, baked.clips, "over 10")


func _expect_problem(what: String, recipe: UnifiedCrowdRecipe, rig: Node3D, mesh: ArrayMesh, clips: UnifiedCrowdClips,
		words: String) -> void:
	var crowd_check := UnifiedCrowdCheck.new(recipe)
	crowd_check.check_bake(rig, mesh, clips)
	var messages := _messages(crowd_check)
	check("the check fails " + what, messages.any(func(message: String) -> bool: return message.contains(words)),
		messages)


func _mesh_of(arrays: Array, like: ArrayMesh) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var custom := ((Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT))
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, custom)
	mesh.custom_aabb = like.custom_aabb
	return mesh


## Each clip's frames are its own pose, whatever the bake posed before it, though the AnimationPlayer blends from one
## clip to the next: ONCE ends with the arm turned, WAVE keys only the hand (its arm stands at rest, not where ONCE left
## it), and each clip's first frame is its own, not the last clip's last. Each is compared with an instance that played
## that clip alone. WAVE's rate, 29.97, isn't exact in 32 bits: the check passes the bake still.
func _check_own_poses(recipe: UnifiedCrowdRecipe) -> void:
	var blended := _copy_recipe(recipe)
	blended.clips = [UnifiedCrowdClip.new(ONCE, 60.0, UnifiedCrowdClip.Loop.HOLDS), UnifiedCrowdClip.new(WAVE, ODD_RATE),
		UnifiedCrowdClip.new(LOOP, 30.0)]
	var rig := _instance(blended)
	(rig.get_node("Player") as AnimationPlayer).playback_default_blend_time = 0.3
	var baked := UnifiedCrowdBake.bake_rig(rig, blended)
	check("the character bakes with a blend time", baked.errors.is_empty(), baked.errors)
	if not baked.errors.is_empty():
		_free(rig)
		return
	var clips := baked.clips
	var first_worst := 0.0
	var worst := 0.0
	var worst_at := ""
	for clip in clips.clips.size():
		var alone := _instance(blended)
		var player := alone.get_node("Player") as AnimationPlayer
		var skeleton := alone.get_node("Skeleton") as Skeleton3D
		player.play(clips.clips[clip])
		for frame in clips.frame_count(clip):
			player.seek(minf(frame / clips.rate(clip), clips.length(clip)), true)
			var expected := _skeleton_matrices(alone, skeleton)
			for bone in skeleton.get_bone_count():
				var apart := _apart(clips.frame_matrix(clips.first_row(clip) + frame, bone), expected[bone])
				if frame == 0:
					first_worst = maxf(first_worst, apart)
				if apart > worst:
					worst = apart
					worst_at = "%s frame %d bone %d" % [clips.clips[clip], frame, bone]
		_free(alone)
	check("with a blend time, each clip's first frame is its own pose", first_worst <= NEAR, first_worst)
	check("with a blend time, every frame is its clip's own pose (a bone it doesn't key at rest)", worst <= NEAR,
		"%f at %s" % [worst, worst_at])
	check("29.97 is no 32-bit float: the table's rate is near it, not it", clips.rate(1) != ODD_RATE
		and absf(clips.rate(1) - ODD_RATE) < 0.00001, clips.rate(1))
	var crowd_check := UnifiedCrowdCheck.new(blended)
	check("the check passes the bake, its 29.97 rate the recipe's", crowd_check.check_bake(rig, baked.mesh, clips),
		_messages(crowd_check))
	_free(rig)


## The pair of frames a bone turns fastest between is where parity looks: SNAP at 10 frames a second stands still but
## for a 170° turn between two frames, which no other time parity poses shows.
func _check_worst_pair(recipe: UnifiedCrowdRecipe) -> void:
	var snap := _copy_recipe(recipe)
	snap.clips = [UnifiedCrowdClip.new(SNAP, 10.0)]
	var rig := _instance(snap)
	var baked := UnifiedCrowdBake.bake_rig(rig, snap)
	var crowd_check := UnifiedCrowdCheck.new(snap)
	var shaped := UnifiedCrowdBake.shape(rig, snap)
	var apart := crowd_check.parity(rig, shaped, baked.mesh.surface_get_arrays(0), baked.clips)
	check("parity finds the snap between two frames", apart > UnifiedCrowdCheck.PARITY
		and crowd_check.worst_at.contains("Test/Snap at 0.4"), "%f at %s" % [apart, crowd_check.worst_at])
	_free(rig)


## From files: a bake saved where the recipe says passes the full check. Its inputs are the bake's version, Godot's,
## the recipe and the character's files; a changed recipe or a scene edited on disk makes the bake stale, a material's
## colour or a texture does not.
func _check_files(recipe: UnifiedCrowdRecipe) -> void:
	var baked := UnifiedCrowdBake.bake(recipe, root)
	check("the bake from the scene file is stamped with its inputs' hash",
		baked.errors.is_empty() and baked.clips.sources == UnifiedCrowdBake.inputs_hash(recipe))
	check("it saves where the recipe says", baked.save() == OK)
	var saved := load(recipe.clips_path) as UnifiedCrowdClips
	check("the saved table refers to the saved bones", saved != null and saved.bones.resource_path == recipe.bones_path)
	var fresh := UnifiedCrowdCheck.new(recipe)
	check("the full check passes the saved bake", fresh.check(root), _messages(fresh))
	var inputs := UnifiedCrowdBake.inputs(recipe)
	var files: Dictionary = inputs["files"]
	check("the inputs: the bake's version, Godot's, the recipe", inputs["bake"] == UnifiedCrowdBake.BAKE_VERSION
		and inputs["godot"] == Engine.get_version_info()["string"] and inputs["recipe"] == recipe.describe(), inputs)
	check("the inputs: the scene's bytes, not its materials'", files.has(recipe.scene)
		and files[recipe.scene] == FileAccess.get_sha256(recipe.scene) and not files.has(DIR + "glow.tres"), files)
	var changed := _copy_recipe(recipe)
	changed.max_error = 0.1
	_expect_stale("a changed recipe makes the bake stale", changed, true)
	var before := UnifiedCrowdBake.inputs_hash(recipe)
	(_glow as StandardMaterial3D).albedo_color = Color(0, 1, 0)
	ResourceSaver.save(_glow, _glow.resource_path)
	check("a material's colour leaves the bake fresh", UnifiedCrowdBake.inputs_hash(recipe) == before)
	var scene_text := FileAccess.get_file_as_string(recipe.scene)
	_write(recipe.scene, scene_text + "; edited\n")
	_expect_stale("the scene edited on disk makes the bake stale", recipe, true)
	_write(recipe.scene, scene_text)
	_expect_stale("the scene as it was is fresh again", recipe, false)


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _expect_stale(what: String, recipe: UnifiedCrowdRecipe, stale: bool) -> void:
	var crowd_check := UnifiedCrowdCheck.new(recipe)
	crowd_check.check(root)
	var said := _messages(crowd_check).any(func(message: String) -> bool: return message.contains("stale"))
	check(what, said == stale, _messages(crowd_check))


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
