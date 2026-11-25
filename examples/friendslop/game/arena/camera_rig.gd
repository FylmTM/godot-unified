class_name CameraRig
extends Node3D
## The third-person orbit camera behind the local player: the mouse (captured while playing) or the right stick turn
## it (at the settings' sensitivity and invert look; the stick not under the pause menu), it pulls in when the level is
## in the way, and every frame, just before the session samples the input
## (input_wanted), it tells the session where it looks (Unified.input: `look` = the look direction, `right` = flat
## right), which the input sampler turns into camera-relative movement and the aim.

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
	Unified.session.input_wanted.connect(_turn)


func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE  # however the play scene ends, the menu gets a free mouse


## Before the session samples this frame's input: the stick turns the camera, and the session learns where it looks.
func _turn() -> void:
	var delta := get_process_delta_time()
	var stick := Vector2.ZERO
	if Unified.session.game_input:  # not under the pause menu
		stick = Input.get_vector(&"look_left", &"look_right", &"look_up", &"look_down")
	var invert := -1.0 if Settings.invert_y else 1.0
	yaw -= stick.x * 2.6 * delta
	pitch = clampf(pitch - stick.y * 1.8 * invert * delta, PITCH_MIN, PITCH_MAX)
	Unified.input.look = _look()
	Unified.input.right = Vector3(-cos(yaw), 0, sin(yaw))  # flat right of the look


## The look direction: from the pivot to the target.
func _look() -> Vector3:
	return Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))


func _process(delta: float) -> void:
	_capture_mouse()
	var me := Unified.session.get_player_view(EnumView.PLAYER, Unified.session.local_player) as Node3D
	if me != null:
		_pivot = _pivot.lerp(me.global_position + Vector3(0, HEIGHT, 0), 1.0 - exp(-delta * 12.0))
	var dir := _look()
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


func _unhandled_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var s := Settings.mouse_sensitivity
		var invert := -1.0 if Settings.invert_y else 1.0
		yaw -= motion.relative.x * 0.004 * s
		pitch = clampf(pitch - motion.relative.y * 0.004 * s * invert, PITCH_MIN, PITCH_MAX)


func shake(amount: float) -> void:
	_shake = maxf(_shake, amount)


## The mouse is captured while playing, free under the Esc menu and the connect overlay (reconnecting: its Cancel is
## clicked), and never captured headless.
func _capture_mouse() -> void:
	var free := _pause_menu.visible or Game.status != UnifiedSession.STATUS_CONNECTED or DisplayServer.get_name() == "headless"
	var want := Input.MOUSE_MODE_VISIBLE if free else Input.MOUSE_MODE_CAPTURED
	if Input.mouse_mode != want and Game.flow == Game.Flow.PLAYING:
		Input.mouse_mode = want
