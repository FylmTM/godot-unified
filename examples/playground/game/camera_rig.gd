class_name CameraRig
extends Node3D
## The local player's flying camera: where the sim says their camera is (their Camera view, interpolated), looking
## where the mouse (captured while playing, free under the pause menu) or the right stick turns it, with the settings'
## sensitivity and invert look. Every frame, just before the session samples the input (input_wanted), it tells the
## session its yaw and pitch (Unified.input), which the input sampler makes the Input's aim. On entering a scene it
## looks at the scene's middle. `shake` jolts the lens (an explosion nearby, a shot): the aim stays where it was.

const MOUSE_TURN := 0.0025  # radians per pixel at sensitivity 1
const STICK_YAW := 2.6  # radians per second, the stick held over
const STICK_PITCH := 1.8
## Short of straight up or down, as dmath.AIM_PITCH_LIMIT holds the aim.
const PITCH_LIMIT := 1.5
const SCENE_MIDDLE := Vector3(0, 1, 0)

var yaw := 0.0
var pitch := -0.3
## Seconds left in which the camera turns to the scene's middle (a scene was entered: its view may still be moving).
var _look_at_scene := 0.3
var _shake := 0.0
var _rng := RandomNumberGenerator.new()

@onready var _camera: Camera3D = $Camera3D
@onready var _pause_menu: CanvasLayer = get_parent().get_node(^"PauseMenu")


func _ready() -> void:
	_rng.seed = 7
	Unified.session.input_wanted.connect(_tell_session)
	Unified.session.sim_event.connect(_on_sim_event)


func _unhandled_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var turn := MOUSE_TURN * Settings.mouse_sensitivity
		var invert := -1.0 if Settings.invert_y else 1.0
		yaw -= motion.relative.x * turn
		pitch = clampf(pitch - motion.relative.y * turn * invert, -PITCH_LIMIT, PITCH_LIMIT)


func _process(delta: float) -> void:
	_capture_mouse()
	_shake = move_toward(_shake, 0.0, delta * 0.8)
	var jolt := Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), 0) * _shake
	_camera.position = jolt * 0.15
	_camera.rotation = Vector3(jolt.y, jolt.x, 0) * 0.03
	var me := Unified.session.get_player_view(EnumView.CAMERA, Unified.session.local_player) as Node3D
	if me == null:
		return
	global_position = me.global_position
	if _look_at_scene > 0.0:
		_look_at_scene -= delta
		var to := SCENE_MIDDLE - global_position
		yaw = atan2(-to.x, -to.z)
		pitch = clampf(atan2(to.y, Vector2(to.x, to.z).length()), -PITCH_LIMIT, PITCH_LIMIT)
	rotation = Vector3(pitch, yaw, 0)


## Jolts the lens by `amount` (0..1), fading over about a second; a bigger jolt replaces a smaller one.
func shake(amount: float) -> void:
	_shake = maxf(_shake, amount)


## Before the session samples this frame's input: the stick turns the camera, and the session learns where it looks,
## in turns.
func _tell_session() -> void:
	var delta := get_process_delta_time()
	var stick := Input.get_vector(&"look_left", &"look_right", &"look_up", &"look_down")
	var invert := -1.0 if Settings.invert_y else 1.0
	yaw -= stick.x * STICK_YAW * delta
	pitch = clampf(pitch - stick.y * STICK_PITCH * invert * delta, -PITCH_LIMIT, PITCH_LIMIT)
	Unified.input.yaw_turns = yaw / TAU
	Unified.input.pitch_turns = pitch / TAU


func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if event is EventSceneEntered and state == UnifiedSession.EVENT_EMITTED:
		_look_at_scene = 0.3


## The mouse is captured while playing, free under the pause menu (and never captured headless).
func _capture_mouse() -> void:
	var free := _pause_menu.visible or DisplayServer.get_name() == "headless"
	var want := Input.MOUSE_MODE_VISIBLE if free else Input.MOUSE_MODE_CAPTURED
	if Input.mouse_mode != want and Game.flow == Game.Flow.PLAYING:
		Input.mouse_mode = want
