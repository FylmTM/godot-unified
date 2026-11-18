class_name DriftArena
extends Node2D
## The play scene: the level (its art is the arena's visuals; the sim loads its exported .level), the views root
## handed to the session (ships, the station, gates), the multi views (rocks, bullets, gems), the camera following the
## local ship, effects and the HUD. Turns the mouse or the right stick into the aim every frame, and routes the
## sim's events (sim_event) to effects, sounds and camera shake: rock effects as soon as an event is first shown
## (predicted), the rest once its tick is confirmed.

## The arena's extent in pixels (the level's art), the camera's limits.
var bounds := Rect2()
## Off: only the right stick aims (game/tools/tour.gd, so a real mouse over the window can't steer the ship).
var mouse_aim_enabled := true
## The mouse aims (relative to the local ship) once it moves, until the right stick is used.
var _mouse_aim := false

@onready var camera: DriftCamera = $Camera
@onready var effects: DriftEffects = $Effects
@onready var _views: Node2D = $Views
@onready var _level: Node2D = $Level


func _ready() -> void:
	process_priority = -1001  # the aim is set before UnifiedSession (-1000) samples the input: never a frame late
	bounds = level_bounds(_level)
	camera.set_bounds(bounds)
	Game.session.view_root = _views
	Game.session.sim_event.connect(_on_sim_event)
	Input.set_default_cursor_shape(Input.CURSOR_CROSS)


func _exit_tree() -> void:
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and mouse_aim_enabled:
		_mouse_aim = true


func _process(_delta: float) -> void:
	var stick := Input.get_vector(&"aim_left", &"aim_right", &"aim_up", &"aim_down")
	if stick.length() > 0.3:
		_mouse_aim = false
	var dir := Vector2.ZERO
	var me := local_ship_view()
	if _mouse_aim and me != null:
		dir = get_global_mouse_position() - me.global_position
	elif stick != Vector2.ZERO:
		dir = stick
	Unified.input.aim = dir  # world space (x right, y down); zero keeps the heading


## The local player's ship view (null until they have one).
func local_ship_view() -> Node2D:
	return Game.session.get_player_view(EnumView.SHIP, Unified.session.local_player) as Node2D


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
		camera.shake(0.5 if station_hit.damage >= 10 else 0.3)
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
		var station := Game.session.get_view(EnumView.STATION, 0) as Node2D
		var c := station.global_position if station != null else Vector2.ZERO
		effects.debris(c, 40, UiTheme.BAD, 320.0, 5.0)
		effects.ring(c, 20.0, 260.0, 1.0, UiTheme.BAD, 5.0)
		camera.shake(1.0)
		Sfx.play(&"over")
		Sfx.play(&"boom")
