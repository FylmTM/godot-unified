extends Node3D
## The main menu's backdrop (no sim): the Pyramid scene as it starts, its box pyramid laid out the way the sim builds
## it (build_pyramid in simulation/playground/scenes.odin), with a few players' spawns lying around it. Built once in
## code from those numbers; drawn in the play scene's colours (a scene body's, the players').

const ROWS := 13
const HALF := 0.4
const GAP := 0.02
const SCENE_COLOR := Color(0.86, 0.66, 0.42)
## The spawns around the pyramid: shape, where (x, z), the player's slot.
const SPAWNS := [["sphere", Vector2(-7.5, 3.0), 0], ["box", Vector2(6.5, 4.0), 1], ["cylinder", Vector2(-5.0, -6.0), 2],
	["sphere", Vector2(8.0, -3.5), 3], ["box", Vector2(-9.0, -1.5), 1], ["cylinder", Vector2(3.5, 7.0), 0],
	["sphere", Vector2(1.5, -8.5), 1], ["box", Vector2(-3.0, 8.0), 3]]


func _ready() -> void:
	_build_pyramid()
	for spawn: Array in SPAWNS:
		var shape: String = spawn[0]
		var at: Vector2 = spawn[1]
		var slot: int = spawn[2]
		_add_spawn(shape, at, UiTheme.player_color(slot))


func _build_pyramid() -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * 2.0 * HALF
	mesh.material = _material(SCENE_COLOR)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	@warning_ignore("integer_division")
	multimesh.instance_count = ROWS * (ROWS + 1) / 2
	var step := 2.0 * HALF + GAP
	var i := 0
	for row in ROWS:
		var count := ROWS - row
		for column in count:
			var x := (column - (count - 1) * 0.5) * step
			multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(x, HALF + row * 2.0 * HALF, 0)))
			i += 1
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	add_child(instance)


func _add_spawn(shape: String, at: Vector2, color: Color) -> void:
	var body := MeshInstance3D.new()
	match shape:
		"sphere":
			var sphere := SphereMesh.new()
			sphere.radius = 0.5
			sphere.height = 1.0
			body.mesh = sphere
		"cylinder":
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = 0.4
			cylinder.bottom_radius = 0.4
			cylinder.height = 1.2
			body.mesh = cylinder
			body.rotation = Vector3(PI / 2.0, at.angle(), 0)  # lying on its side
		_:
			var box := BoxMesh.new()
			box.size = Vector3(0.9, 0.9, 0.9)
			body.mesh = box
			body.rotation.y = at.x
	body.material_override = _material(color)
	body.position = Vector3(at.x, 0.4 if shape == "cylinder" else 0.45 if shape == "box" else 0.5, at.y)
	add_child(body)


static func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.8
	return material
