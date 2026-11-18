class_name CameraRig
extends Node3D
## The third-person orbit camera behind the local player: the mouse (captured while playing) or the right stick turn
## it, it pulls in when the level is in the way, and every frame it tells the session where it looks
## (Unified.input: `look` = the look direction, `right` = flat right), which the input sampler turns into
## camera-relative movement and the aim.

const DISTANCE := 6.0
## The orbit's pivot above the player's centre.
const HEIGHT := 1.2
const PITCH_MIN := -1.2
const PITCH_MAX := 0.6

## Looking towards -z.
var yaw := PI
var pitch := -0.3
var _pivot := Vector3(0, 2, 6)
var _shake := 0.0
var _rng := RandomNumberGenerator.new()

@onready var _camera: Camera3D = $Camera3D
@onready var _arena: Arena = get_parent()
@onready var _pause_menu: CanvasLayer = _arena.get_node(^"PauseMenu")


func _ready() -> void:
	_rng.seed = 7


func _process(delta: float) -> void:
	_capture_mouse()
	var stick := Input.get_vector(&"look_left", &"look_right", &"look_up", &"look_down")
	yaw -= stick.x * 2.6 * delta
	pitch = clampf(pitch - stick.y * 1.8 * delta, PITCH_MIN, PITCH_MAX)
	var me := Game.session.get_player_view(EnumView.PLAYER, Game.local_player()) as Node3D
	if me != null:
		_pivot = _pivot.lerp(me.global_position + Vector3(0, HEIGHT, 0), 1.0 - exp(-delta * 12.0))
	var dir := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))  # from the pivot to the target
	var dist := DISTANCE
	var hit := get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(_pivot, _pivot - dir * DISTANCE))
	if not hit.is_empty():
		var hit_at: Vector3 = hit.position
		dist = maxf(_pivot.distance_to(hit_at) - 0.3, 1.0)
	global_position = _pivot - dir * dist
	_shake = move_toward(_shake, 0.0, delta * 0.8)
	var jitter := Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), 0) * _shake * 0.3
	_camera.global_position = global_position + global_transform.basis * jitter
	_camera.look_at(_pivot + dir * 2.0, Vector3.UP)
	Unified.input.look = dir
	Unified.input.right = Vector3(-cos(yaw), 0, sin(yaw))  # flat right of `dir`


func _unhandled_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var s: float = Settings.get_value(&"mouse_sensitivity")
		var invert := -1.0 if Settings.get_value(&"invert_y") else 1.0
		yaw -= motion.relative.x * 0.004 * s
		pitch = clampf(pitch - motion.relative.y * 0.004 * s * invert, PITCH_MIN, PITCH_MAX)


func shake(amount: float) -> void:
	_shake = maxf(_shake, amount)


## The mouse is captured while playing, free under the Esc menu (and never captured headless).
func _capture_mouse() -> void:
	var free := _pause_menu.visible or DisplayServer.get_name() == "headless"
	var want := Input.MOUSE_MODE_VISIBLE if free else Input.MOUSE_MODE_CAPTURED
	if Input.mouse_mode != want and Game.flow == UnifiedGame.Flow.PLAYING:
		Input.mouse_mode = want
