class_name DriftArena
extends Node2D
## The play scene: the level (its art is the arena's visuals; the sim loads its exported .level), the views root
## handed to the session (ships, the station, gates), the multi views (rocks, bullets, gems), the camera following the
## local ships, effects and the HUD. Couch co-op: Start on a pad nobody plays on joins as another local player (the
## first player keeps the keyboard and mouse, or the pad they were using); Start on a playing pad opens the pause menu.
## Turns the mouse or the first player's right stick into their aim for every input sample (a joined pad aims with its
## own stick, in the extension), and routes the sim's events (sim_event) to effects, sounds and camera shake: rock
## effects as soon as an event is first shown (predicted), the rest once its tick is confirmed.

## `_last_input` besides a pad's id: nothing seen yet in the play scene, and a key or mouse button.
const UNSEEN := -2
const KBM := -1

## The arena's extent in pixels (the level's art), the camera's limits.
var bounds := Rect2()
## Off: only the right stick aims (game/tools/tour.gd, so a real mouse over the window can't steer the ship).
var mouse_aim_enabled := true
## The mouse aims (relative to the local ship) once it moves, until the right stick is used.
var _mouse_aim := false
## What the last input in the play scene came from: a pad's id, KBM (keyboard or a mouse button) or UNSEEN (nothing
## yet: Game.using_pad says which). While the first player plays on every device, a pad that did is theirs.
var _last_input := UNSEEN

@onready var camera: DriftCamera = $Camera
@onready var effects: DriftEffects = $Effects
@onready var _views: Node2D = $Views
@onready var _level: Node2D = $Level


func _ready() -> void:
	bounds = level_bounds(_level)
	camera.set_bounds(bounds)
	Unified.session.view_root = _views
	Unified.session.sim_event.connect(_on_sim_event)
	Unified.session.input_wanted.connect(_set_aim)  # this frame's sample takes the aim: never a frame late
	Input.set_default_cursor_shape(Input.CURSOR_CROSS)


func _exit_tree() -> void:
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)


## Runs before the pause menu sees the event: a pad's Start joins here when that pad is nobody's, and is handled; any
## other Start goes on to the pause menu (the `menu` action).
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and mouse_aim_enabled:
		_mouse_aim = true
	var button := event as InputEventJoypadButton
	if button != null and button.pressed and button.button_index == JOY_BUTTON_START and _joins(button.device):
		var session := Unified.session
		if session.local_indices.size() == 1 and session.get_local_device(0) == UnifiedSession.DEVICE_ANY:
			# the first player keeps what they were playing with: the pad they last used, else keyboard and mouse
			session.set_local_device(0, _last_input if _last_input >= 0 else UnifiedSession.DEVICE_KEYBOARD)
		if session.add_local_player(button.device, "Pad %d" % (button.device + 1)) >= 0:
			get_viewport().set_input_as_handled()
	if button != null or (event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) > 0.5):
		_last_input = event.device
	elif event is InputEventKey or event is InputEventMouseButton:
		_last_input = KBM


## Whether Start on pad `device` joins a new local player: no local player plays on it, and it isn't the pad the first
## player is using while they play on every device (their Start opens the pause menu).
func _joins(device: int) -> bool:
	var session := Unified.session
	for local: int in session.local_indices:
		if session.get_local_device(local) == device:
			return false
	if session.get_local_device(0) != UnifiedSession.DEVICE_ANY:
		return true
	return not (device == _last_input or (_last_input == UNSEEN and Game.using_pad))


## Before the sample: the first player's aim. The mouse (relative to their ship) once it moves; else the right stick of
## the device they play on: every pad while they play on every device, theirs when they have one (the extension reads
## it), none on the keyboard. Under the pause menu (game input off) zero: the heading stays.
func _set_aim() -> void:
	var session := Unified.session
	if not session.game_input:
		Unified.input.aim = Vector2.ZERO
		return
	var stick := Vector2.ZERO
	if session.get_local_device(0) == UnifiedSession.DEVICE_ANY:
		stick = Input.get_vector(&"aim_left", &"aim_right", &"aim_up", &"aim_down")
	if stick.length() > 0.3:
		_mouse_aim = false
	var dir := Vector2.ZERO
	var me := local_ship_view()
	if _mouse_aim and me != null:
		dir = get_global_mouse_position() - me.global_position
	elif stick != Vector2.ZERO:
		dir = stick
	Unified.input.aim = dir  # world space (x right, y down); zero keeps the heading


## The first local player's ship view (null until they have one).
func local_ship_view() -> Node2D:
	return Unified.session.get_player_view(EnumView.SHIP, Unified.session.local_player) as Node2D


## Where the camera looks: the middle of every local player's ship (null: none has one yet).
func local_ships_center() -> Variant:
	var sum := Vector2.ZERO
	var count := 0
	for player: int in Unified.session.local_players:
		var ship := Unified.session.get_player_view(EnumView.SHIP, player) as Node2D
		if ship != null:
			sum += ship.global_position
			count += 1
	if count == 0:
		return null
	return sum / count


## The union of the level's drawn rects and polygons, in global pixels.
static func level_bounds(level: Node) -> Rect2:
	var r := Rect2()
	var first := true
	var stack: Array[Node] = [level]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		var part := Rect2()
		if n is ColorRect:
			part = (n as ColorRect).get_global_rect()
		elif n is Polygon2D and (n as Polygon2D).polygon.size() > 0:
			var poly := n as Polygon2D
			var pts := poly.global_transform * poly.polygon
			part = Rect2(pts[0], Vector2.ZERO)
			for p in pts:
				part = part.expand(p)
		else:
			continue
		r = part if first else r.merge(part)
		first = false
	return r


func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	# rock effects play when the event is emitted (a cancelled one has already played: left as is); the rest wait
	# for the confirmed tick. Positions are in pixels, like the views (the host maps them: Glue.view_scale).
	var rock_effect := event is EventRockHit or event is EventRockSplit or event is EventRockDestroyed
	if state != (UnifiedSession.EVENT_EMITTED if rock_effect else UnifiedSession.EVENT_CONFIRMED):
		return
	if event is EventRockHit:
		var hit := event as EventRockHit
		effects.sparks(hit.position, 4, Color(1, 0.9, 0.7))
		if hit.position.distance_to(camera.get_screen_center_position()) < 900.0:
			Sfx.play(&"hit", -14.0, randf_range(1.2, 1.5))
	elif event is EventRockSplit:
		var split := event as EventRockSplit
		effects.debris(split.position, 8, Color(0.62, 0.56, 0.5), 140.0, 4.0)
		Sfx.play(&"pop", -6.0, 0.7 if split.size == EnumRockSize.LARGE else 0.9)
	elif event is EventRockDestroyed:
		var destroyed := event as EventRockDestroyed
		effects.debris(destroyed.position, 10, Color(0.75, 0.68, 0.6), 170.0, 3.0)
		effects.ring(destroyed.position, 6.0, 34.0, 0.35, Color(1, 0.9, 0.7, 0.8), 2.0)
		Sfx.play(&"boom", -12.0, 1.6)
	elif event is EventStationHit:
		var station_hit := event as EventStationHit
		effects.debris(station_hit.position, 14, UiTheme.BAD, 200.0, 4.0)
		effects.ring(station_hit.position, 10.0, 60.0, 0.5, UiTheme.BAD, 3.0)
		camera.shake(0.5 if station_hit.size == EnumRockSize.LARGE else 0.3)
		Sfx.play(&"boom", -4.0)
		Game.rumble(0.5, 0.7, 0.3)
	elif event is EventGemPicked:
		effects.ring((event as EventGemPicked).position, 4.0, 28.0, 0.3, UiTheme.GOLD, 2.0)
		Sfx.play(&"gem", -2.0)
	elif event is EventWarped:
		effects.ring((event as EventWarped).position, 8.0, 70.0, 0.45, UiTheme.CYAN, 3.0)
	elif event is EventSpawned:
		effects.ring((event as EventSpawned).position, 8.0, 50.0, 0.5, Color.WHITE, 2.0)
		Sfx.play(&"join", -6.0)
	elif event is EventWave:
		Sfx.play(&"wave")
	elif event is EventMatchStarted:
		Sfx.play(&"start")
	elif event is EventMatchOver:
		var station := Unified.session.get_view(EnumView.STATION, 0) as Node2D
		var c := station.global_position if station != null else Vector2.ZERO
		effects.debris(c, 40, UiTheme.BAD, 320.0, 5.0)
		effects.ring(c, 20.0, 260.0, 1.0, UiTheme.BAD, 5.0)
		camera.shake(1.0)
		Sfx.play(&"over")
		Sfx.play(&"boom")
