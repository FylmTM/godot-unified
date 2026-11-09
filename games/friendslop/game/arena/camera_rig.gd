extends Node3D
## Third-person orbit camera behind the local player: mouse (captured while playing) or the right stick turn it,
## it pulls in when the level is in the way, and every frame it tells the session where it looks
## (UnifiedSession.set_input_vector: 0 = look direction, 1 = flat right), which the input sampler turns into
## camera-relative movement and the aim.

const DISTANCE := 6.0
const HEIGHT := 1.2  ## the orbit's pivot above the player's centre
const PITCH_MIN := -1.2
const PITCH_MAX := 0.6

@onready var camera: Camera3D = $Camera3D
var yaw := PI  ## looking towards -z
var pitch := -0.3
var _pivot := Vector3(0, 2, 6)
var _shake := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 7


func shake(amount: float) -> void:
	_shake = maxf(_shake, amount)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var s: float = Settings.get_value(&"mouse_sensitivity")
		yaw -= event.relative.x * 0.004 * s
		var inv := -1.0 if Settings.get_value(&"invert_y") else 1.0
		pitch = clampf(pitch - event.relative.y * 0.004 * s * inv, PITCH_MIN, PITCH_MAX)


func _process(delta: float) -> void:
	var paused: bool = get_tree().current_scene.has_node(^"PauseMenu") and get_tree().current_scene.get_node(^"PauseMenu").visible
	var want := Input.MOUSE_MODE_VISIBLE if paused or DisplayServer.get_name() == "headless" else Input.MOUSE_MODE_CAPTURED
	if Input.mouse_mode != want and Game.flow == Game.Flow.PLAYING:
		Input.mouse_mode = want
	var stick := Input.get_vector(&"look_left", &"look_right", &"look_up", &"look_down")
	yaw -= stick.x * 2.6 * delta
	pitch = clampf(pitch - stick.y * 1.8 * delta, PITCH_MIN, PITCH_MAX)
	var arena := get_parent()
	var me: Node3D = arena.local_player_view() if arena.has_method(&"local_player_view") else null
	if me != null:
		_pivot = _pivot.lerp(me.global_position + Vector3(0, HEIGHT, 0), 1.0 - exp(-delta * 12.0))
	var dir := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))  # from the pivot to the target
	var back := -dir
	var dist := DISTANCE
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(_pivot, _pivot + back * DISTANCE)
	var hit := space.intersect_ray(q)
	if not hit.is_empty():
		dist = maxf(_pivot.distance_to(hit.position) - 0.3, 1.0)
	global_position = _pivot + back * dist
	_shake = move_toward(_shake, 0.0, delta * 0.8)
	var jitter := Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), 0) * _shake * 0.3
	camera.global_position = global_position + global_transform.basis * jitter
	camera.look_at(_pivot + dir * 2.0, Vector3.UP)
	Game.session.set_input_vector(0, dir)
	Game.session.set_input_vector(1, Vector3(-cos(yaw), 0, sin(yaw)))  # flat right of `dir`
