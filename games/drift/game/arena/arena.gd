extends Node2D
## The play scene: the level (its art is the arena's visuals; the sim loads its exported .level), the views root
## handed to the session (ships, the station, gates), the bulk views (rocks, bullets, gems), the camera following the
## local ship, effects and the HUD. Turns the mouse or the right stick into the aim every frame, and routes the
## sim's verified events (sim_event_2d) to effects, sounds and camera shake.

@onready var _views: Node2D = $Views
@onready var _level: Node2D = $Level
@onready var camera: Camera2D = $Camera
@onready var effects: Node2D = $Effects
## The arena's extent in pixels (the level's art), the camera's limits.
var bounds := Rect2()
## The mouse aims (relative to the local ship) once it moves, until the right stick is used.
var _mouse_aim := false


func _ready() -> void:
	process_priority = -1001  # the aim is set before UnifiedSession (-1000) samples the input: never a frame late
	Game.px_per_m = float(_level.get_meta(&"unified_px_per_m", 32.0))
	bounds = level_bounds(_level)
	camera.set_bounds(bounds)
	Game.session.view_root = _views
	Game.session.sim_event_2d.connect(_on_sim_event)
	Input.set_default_cursor_shape(Input.CURSOR_CROSS)


func _exit_tree() -> void:
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	if Game.session != null and Game.session.view_root == _views:
		Game.session.view_root = null


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
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
	Game.session.set_input_vector_2d(0, dir)  # world space (x right, y down); zero keeps the heading


## The scene views of one kind (ship, station, gate) under the views root.
func views_of(kind: String) -> Array[Node2D]:
	var out: Array[Node2D] = []
	for v in _views.get_children():
		if v is Node2D and String(v.get(&"kind")) == kind:
			out.append(v)
	return out


func ship_view(slot: int) -> Node2D:
	for v in views_of("ship"):
		if int(v.get(&"slot")) == slot:
			return v
	return null


func local_ship_view() -> Node2D:
	return ship_view(Game.local_slot())


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


func _on_sim_event(kind: StringName, _tick: int, _entity: int, position_m: Vector2, value: float) -> void:
	var at := position_m * Game.px_per_m  # sim events carry metres; views are in pixels
	var near := at.distance_to(camera.get_screen_center_position()) < 900.0
	match kind:
		&"rock_hit":
			effects.sparks(at, 4, Color(1, 0.9, 0.7))
			if near:
				Sfx.play(&"hit", -14.0, randf_range(1.2, 1.5))
		&"rock_split":
			effects.debris(at, 8, Color(0.62, 0.56, 0.5), 140.0, 4.0)
			Sfx.play(&"pop", -6.0, 0.7 if value >= 2.0 else 0.9)
		&"rock_destroyed":
			effects.debris(at, 10, Color(0.75, 0.68, 0.6), 170.0, 3.0)
			effects.ring(at, 6.0, 34.0, 0.35, Color(1, 0.9, 0.7, 0.8), 2.0)
			Sfx.play(&"boom", -12.0, 1.6)
		&"station_hit":
			effects.debris(at, 14, UiTheme.BAD, 200.0, 4.0)
			effects.ring(at, 10.0, 60.0, 0.5, UiTheme.BAD, 3.0)
			camera.shake(0.5 if value >= 10.0 else 0.3)
			Sfx.play(&"boom", -4.0)
			Game.rumble(0.5, 0.7, 0.3)
		&"gem_picked":
			effects.ring(at, 4.0, 28.0, 0.3, UiTheme.GOLD, 2.0)
			Sfx.play(&"gem", -2.0)
		&"warped":
			effects.ring(at, 8.0, 70.0, 0.45, UiTheme.CYAN, 3.0)
		&"joined":
			effects.ring(at, 8.0, 50.0, 0.5, Color.WHITE, 2.0)
			Sfx.play(&"join", -6.0)
		&"wave":
			Sfx.play(&"wave")
		&"match_started":
			Sfx.play(&"start")
		&"match_over":
			var station := views_of("station")
			var c := station[0].global_position if not station.is_empty() else Vector2.ZERO
			effects.debris(c, 40, UiTheme.BAD, 320.0, 5.0)
			effects.ring(c, 20.0, 260.0, 1.0, UiTheme.BAD, 5.0)
			camera.shake(1.0)
			Sfx.play(&"over")
			Sfx.play(&"boom")
