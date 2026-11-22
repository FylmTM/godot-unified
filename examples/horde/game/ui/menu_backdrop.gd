extends Node2D
## The main menu's backdrop: the arena's floor (a Floor child) with a ring of enemies closing in and falling back
## around its centre, drawn by the match's enemy shader at the sim's sizes (Unified.constants), and a camera drifting
## slowly with the arena right of the menu. No session runs here: the crowd is this script's own MultiMesh.

const ENEMIES := 360
const RING_UNITS := 9.0  # the ring's mean radius, in sim units
const BREATHE_UNITS := 3.0  # how far the ring closes in and falls back
const BREATHE_HZ := 0.08
const CAMERA_CENTRE := Vector2(-330, 20)  # px: the arena's centre right of the menu
const CAMERA_DRIFT := 40.0  # px
const CAMERA_HZ := 0.02
const SPIN := 0.03  # rad/s: the ring turns slowly

## Each enemy's kind, its place on the ring and how far off the ring it keeps, made once.
var _kinds := PackedInt32Array()
var _angles := PackedFloat32Array()
var _offsets := PackedFloat32Array()
var _time_s := 0.0

@onready var _crowd: MultiMeshInstance2D = $Crowd
@onready var _camera: Camera2D = $Camera


func _ready() -> void:
	var instances := Quads.multimesh(Quads.quad(Vector2.ONE))
	instances.instance_count = ENEMIES
	_crowd.multimesh = instances
	var shader_material := ShaderMaterial.new()
	shader_material.shader = load("res://game/multi/enemy.gdshader") as Shader
	shader_material.set_shader_parameter(&"kind_colors", PackedColorArray(Palette.ENEMY_COLORS))
	_crowd.material = shader_material
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in ENEMIES:
		var kind := 2 if i % 9 == 0 else (1 if i % 3 == 0 else 0)
		_kinds.append(kind)
		_angles.append(rng.randf() * TAU)
		_offsets.append(rng.randf_range(-2.5, 2.5))


func _process(delta: float) -> void:
	_time_s += delta
	var scale_px := Unified.view_scale
	var radii := Unified.constants.enemy_radii
	var quad_radii := Unified.constants.enemy_quad_radii
	var breathe := sin(_time_s * TAU * BREATHE_HZ) * BREATHE_UNITS
	for i in ENEMIES:
		var direction := Vector2.from_angle(_angles[i] + _time_s * SPIN)
		var distance := (RING_UNITS + _offsets[i] + breathe) * scale_px
		var radius_px: float = radii[_kinds[i]] * scale_px
		var size := radius_px * quad_radii
		var place := Transform2D((-direction).angle(), Vector2(size, size), 0.0, direction * distance)  # facing in
		_crowd.multimesh.set_instance_transform_2d(i, place)
		_crowd.multimesh.set_instance_custom_data(i, Color(_kinds[i], 0.0, 1.0, radius_px))
	var drift := _time_s * TAU * CAMERA_HZ
	_camera.position = CAMERA_CENTRE + Vector2(cos(drift), sin(drift) * 0.6) * CAMERA_DRIFT
