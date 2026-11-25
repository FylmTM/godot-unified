extends Node3D
## The first-person camera: the mouse or the right stick (not under the pause menu) turn it, at the settings'
## sensitivity (the mouse's) and invert look, and every frame, just before the session samples the input
## (input_wanted), it tells the session where it looks (Unified.input.yaw and .pitch, in turns: the sim's dmath.Aim).
## The look is the rig's own, at render rate, so a rollback never moves it; a look `uni drive values` holds turns it
## too. The mouse is captured while playing and free under the pause menu and the connect overlay; a window that loses
## focus lets it go, and a click takes it back. The position is the local
## player's view (predicted and smoothed) at eye height. Before the local player has a body, it looks over the yard
## from above. The `camera` action (Tab, pad LB) cycles through a few fixed views of the yard and back. The viewmodel
## kicks and flashes on a shot the sim will fire (Unified.data.hud.fire_ready): view-only, at once.

const MOUSE_TURNS := 0.00012  # turns per mouse count at sensitivity 1 (Settings.mouse_sensitivity)
const STICK_TURNS := 0.45  # turns per second at full tilt
const OVERVIEW := Vector3(0, 38, 34)
const OVERVIEW_PITCH := -0.12
## Views of the yard the `camera` action cycles through (from, looking at): the whole yard, the deck the east gate
## opens onto, the bridge over the trench, the north gate.
const WATCH: Array[Array] = [
	[Vector3(-30, 30, 40), Vector3(0, 0, -5)],
	[Vector3(4, 10, 32), Vector3(26, 2, 14)],
	[Vector3(-6, 9, -10), Vector3(-18, -1, -21)],
	[Vector3(0, 7, -12), Vector3(0, 0, -34)],
]

## Where the rig looks, in turns (doubles: a long turn never drifts). Zero looks along -Z, as the sim's Aim.
var yaw := 0.0
var pitch := 0.0
## Which of WATCH the camera looks from (-1: the player's eye); the `camera` action steps through them.
var watch := -1
var _kick := 0.0
var _written := Vector2.ZERO  # the yaw and pitch it last handed the session
var _fire_cooldown := 0.0
var _mouse_was_free := true  # the mouse was meant to be free last frame (the menu, or not playing yet)

@onready var camera: Camera3D = $Camera3D
@onready var muzzle: Node3D = $Camera3D/Viewmodel/Muzzle
@onready var _viewmodel: Node3D = $Camera3D/Viewmodel
@onready var _flash: OmniLight3D = $Camera3D/Viewmodel/Muzzle/Flash
@onready var _pause_menu: CanvasLayer = get_parent().get_node(^"PauseMenu")


func _ready() -> void:
	Unified.session.input_wanted.connect(_on_input_wanted)
	add_to_group(&"rig")


func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE  # however the play scene ends, the menu gets a free mouse


## Before the session samples this frame's input: the stick turns the rig, and the session learns where it looks.
func _on_input_wanted() -> void:
	var delta := get_process_delta_time()
	var stick := Vector2.ZERO
	if Unified.session.game_input:  # not under the pause menu
		stick = Input.get_vector(&"look_left", &"look_right", &"look_up", &"look_down")
	yaw -= stick.x * STICK_TURNS * delta
	pitch -= stick.y * STICK_TURNS * 0.6 * delta * (-1.0 if Settings.invert_y else 1.0)
	_clamp_look()
	_written = Vector2(fposmod(yaw, 1.0), pitch)
	Unified.input.yaw = _written.x
	Unified.input.pitch = _written.y


func _process(delta: float) -> void:
	_capture_mouse()
	_follow_held_look()
	if Input.is_action_just_pressed(&"camera") and Unified.session.game_input:
		watch = (watch + 2) % (WATCH.size() + 1) - 1
	if watch >= 0:
		var from: Vector3 = WATCH[watch][0]
		var target: Vector3 = WATCH[watch][1]
		global_position = from
		camera.rotation = Vector3.ZERO
		camera.look_at(target)
		_viewmodel.visible = false
		return
	var me := _my_view()
	if me == null:
		global_position = OVERVIEW
		camera.rotation = Vector3(OVERVIEW_PITCH * TAU, 0, 0)
		_viewmodel.visible = false
		return
	var constants := Unified.constants
	var my_data: ViewPlayer = me.get(&"data")
	var downed := my_data.downed
	# the view stands at the feet of the upright capsule: lying, the eye is about where its centre was
	var centre: float = constants.player_radius + constants.player_half_height
	var eye := centre if downed else centre + constants.eye_height
	global_position = me.global_position + Vector3(0, eye, 0)
	camera.rotation = Vector3(pitch * TAU, yaw * TAU, 0)
	_viewmodel.visible = not downed
	_shoot_feedback(delta)


func _unhandled_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var turns := MOUSE_TURNS * Settings.mouse_sensitivity
		yaw -= motion.relative.x * turns
		pitch -= motion.relative.y * turns * (-1.0 if Settings.invert_y else 1.0)
		_clamp_look()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed and _can_capture():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## The local player's view (null: no body yet).
func _my_view() -> Node3D:
	return Unified.session.get_player_view(EnumView.PLAYER, Unified.session.local_player) as Node3D


## The viewmodel kicks back and the muzzle flashes each time the rifle would fire while Fire is held.
func _shoot_feedback(delta: float) -> void:
	_fire_cooldown -= delta
	var ticks: float = Unified.constants.fire_interval_ticks
	var firing := Input.is_action_pressed(&"fire") and Unified.session.game_input  # not under the pause menu
	if firing and Unified.data.hud.fire_ready and _fire_cooldown <= 0.0:
		_fire_cooldown = ticks / Unified.tick_hz * 0.9
		_kick = 1.0
	_kick = move_toward(_kick, 0.0, delta * 10.0)
	_viewmodel.position = Vector3(0.2, -0.17, -0.52 + _kick * 0.05)
	_viewmodel.rotation.x = _kick * 0.08
	_flash.visible = _kick > 0.6


## A look someone else holds over the rig's (`uni drive values yaw=.. pitch=..`, after input_wanted): the camera turns
## to it, so a driven check sees what it aims at.
func _follow_held_look() -> void:
	var held := Vector2(Unified.input.yaw, Unified.input.pitch)
	if not held.is_equal_approx(_written):
		yaw = held.x
		pitch = held.y
		_written = held


func _clamp_look() -> void:
	var limit: float = Unified.constants.pitch_limit
	pitch = clampf(pitch, -limit, limit)


## The mouse is free under the pause menu, before play (the flow not PLAYING yet), under the connect overlay
## (reconnecting: its Cancel is clicked), and always headless.
func _mouse_free() -> bool:
	return (_pause_menu.visible or Game.flow != Game.Flow.PLAYING or Game.status != UnifiedSession.STATUS_CONNECTED
		or DisplayServer.get_name() == "headless")


## Whether a click may take the mouse: playing, in a window that has the focus.
func _can_capture() -> bool:
	return not _mouse_free() and DisplayServer.window_is_focused()


## Captured as play starts and as the pause menu closes (in a focused window), free under the menu; a window that
## lost focus lets it go, and a click takes it back (_unhandled_input).
func _capture_mouse() -> void:
	var free := _mouse_free()
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if free or (captured and not DisplayServer.window_is_focused()):
		if captured:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif _mouse_was_free and _can_capture():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_mouse_was_free = free
