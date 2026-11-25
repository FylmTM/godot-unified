class_name Hud
extends CanvasLayer
## The in-game HUD (hud.tscn): the scene and its counts, a crosshair (gold while holding something, hidden while
## driving), the session panel, the controls list (the spawn tool's next shape in its Spawn row) and a banner with the
## scene's name when everyone enters one. From the session's data (Unified.data.hud), the newest prediction: nothing
## here must be final. Redrawn when that data, the roster, the join code, the input device or the mouse mode changes.

## The controls list (action, what it does; see ControlsPanel.refresh), assembled per state in `_controls_rows`.
const MOVE: Array[StringName] = [&"move_forward", &"move_left", &"move_back", &"move_right"]
const LOOK: Array[StringName] = [&"look_up", &"look_left", &"look_down", &"look_right"]
const SCENE: Array[StringName] = [&"previous_scene", &"next_scene"]

## The spawn tool's next shape (an EnumShape value).
var _shape := 0
## What the controls list was last built for (its rows change only with these).
var _controls_key := []
## The mouse mode the session panel was last drawn for (its Copy shows only while the mouse is free).
var _mouse_mode := Input.MOUSE_MODE_VISIBLE

@onready var _phase: Label = %Phase
@onready var _scene: Label = %Scene
@onready var _counts: Label = %Counts
@onready var _crosshair: Label = %Crosshair
@onready var _state: Label = %State
@onready var _banner: Banner = %Banner
@onready var _session: SessionPanel = %Session
@onready var _controls: ControlsPanel = %Controls


func _ready() -> void:
	Unified.data.hud.changed.connect(_on_hud_changed)
	Unified.session.roster_changed.connect(_on_hud_changed)
	Unified.session.sim_event.connect(_on_sim_event)
	Unified.session.join_code_changed.connect(_on_hud_changed.unbind(1))
	Game.input_device_changed.connect(_on_hud_changed.unbind(1))
	_on_hud_changed()


func _process(_delta: float) -> void:
	if Input.mouse_mode != _mouse_mode:
		_on_hud_changed()


## The spawn tool's next shape, shown in the controls list's Spawn row.
func show_shape(shape: int) -> void:
	_shape = shape
	_on_hud_changed()


func _on_hud_changed() -> void:
	_mouse_mode = Input.mouse_mode
	var h := Unified.data.hud
	_phase.text = "SCENE %d / %d" % [h.scene + 1, EnumLevel.names().size()]
	_scene.text = _scene_name(h.scene)
	_counts.text = "%d %s  ·  %d bodies  ·  %d awake" % [h.players, "player" if h.players == 1 else "players", h.bodies,
		h.awake]
	_crosshair.modulate = UiTheme.GOLD if h.holding else Color(1, 1, 1, 0.8)
	_crosshair.visible = not h.driving
	_state.text = "Driving" if h.driving else ""
	# a hosted session alone is its lobby: the code to share, large, with Copy (under the pause menu: the mouse is free)
	var rows := _session_rows()
	_session.refresh(rows, rows.size() < 2, "")
	var key := [h.driving, h.holding, h.scene == EnumLevel.DRIVING, _shape, Game.using_pad]
	if key != _controls_key:
		_controls_key = key
		_controls.refresh(_controls_rows(h))


## The controls list for what the local player is doing: driving, holding something, or flying (Drive only in the
## Driving scene, Closer / Farther only while holding).
func _controls_rows(h: DataHud) -> Array:
	var rows: Array = []
	if h.driving:
		rows.append_array([[MOVE, "Drive and steer"], [&"drive", "Get out"]])
	else:
		rows.append_array([[MOVE, "Fly"], [&"move_up", "Up"], [&"move_down", "Down"], [LOOK, "Look", "Mouse"]])
		if h.holding:
			rows.append_array([[&"grab", "Release to fling"], [&"closer", "Pull closer"], [&"farther", "Push away"]])
		else:
			rows.append([&"grab", "Hold to grab"])
		rows.append_array([[&"shoot", "Shoot"], [&"spawn", "Spawn: %s" % String(EnumShape.name(_shape)).capitalize()],
			[&"next_shape", "Next shape"], [&"explode", "Explode"]])
		if h.scene == EnumLevel.DRIVING:
			rows.append([&"drive", "Get in a car"])
	rows.append_array([[SCENE, "Previous / next scene"], [&"reset_scene", "Reset the scene"], [&"menu", "Menu"]])
	return rows


func _session_rows() -> Array[SessionPanel.Row]:
	var rows: Array[SessionPanel.Row] = []
	for player: int in Unified.session.players:
		rows.append(SessionPanel.Row.new(player, Unified.session.get_player_name(player)))
	return rows


## Verified events only: a banner names the scene everyone entered (the session's first included).
func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state == UnifiedSession.EVENT_CONFIRMED and event is EventSceneEntered:
		_banner.show_message(_scene_name((event as EventSceneEntered).scene), UiTheme.TEXT, 1.2)


static func _scene_name(scene: int) -> String:
	return String(EnumLevel.name(scene)).capitalize()
