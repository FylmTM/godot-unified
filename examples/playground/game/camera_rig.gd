extends Node3D
## The local player's flying camera: where the sim says their camera is (their Camera view, interpolated), looking
## where the mouse turns it (captured on a click, released with Esc). Every frame, just before the session samples the
## input (input_wanted), it tells the session its yaw and pitch (Unified.input), which the input sampler makes the
## Input's aim. On entering a scene it looks at the scene's middle.

const MOUSE_TURN := 0.0025  # radians per pixel
## Short of straight up or down, as dmath.AIM_PITCH_LIMIT holds the aim.
const PITCH_LIMIT := 1.5
const SCENE_MIDDLE := Vector3(0, 1, 0)

var yaw := 0.0
var pitch := -0.3
## Seconds left in which the camera turns to the scene's middle (a scene was entered: its view may still be moving).
var _look_at_scene := 0.3


func _ready() -> void:
	Unified.session.input_wanted.connect(_tell_session)
	Unified.session.sim_event.connect(_on_sim_event)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed(&"ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		yaw -= motion.relative.x * MOUSE_TURN
		pitch = clampf(pitch - motion.relative.y * MOUSE_TURN, -PITCH_LIMIT, PITCH_LIMIT)


func _process(delta: float) -> void:
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


## Before the session samples this frame's input: where the camera looks, in turns.
func _tell_session() -> void:
	Unified.input.yaw_turns = yaw / TAU
	Unified.input.pitch_turns = pitch / TAU


func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if event is EventSceneEntered and state == UnifiedSession.EVENT_EMITTED:
		_look_at_scene = 0.3
