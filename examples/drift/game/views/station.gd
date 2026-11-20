extends Node2D
## The station: a Node2D view with a UnifiedView marker. The host sets its
## position and rotation (it turns slowly), and its View_Station `data`; it flashes when its HP drops. Drawn in
## code: the hexagon the sim simulates (Unified.constants.station_shape at radius `station_radius`), and an HP ring
## that stays upright. Also the menu's backdrop decoration (no session there).

## View_Station (simulation/extension): set by the host before _ready, and anew each time it changes. Null on the
## menu's backdrop (no session): full HP.
var data: ViewStation:
	set(value):
		if data != null and value.hp_frac < data.hp_frac - 0.001:
			_flash = 1.0
		data = value
		queue_redraw()

var _r: float  ## the hexagon's corner radius (the sim's station_radius), in pixels
var _flash := 0.0
var _t := 0.0


func _ready() -> void:
	_r = Unified.constants.station_radius * Unified.view_scale


func _process(delta: float) -> void:
	_t += delta
	_flash = maxf(_flash - delta * 3.0, 0.0)
	queue_redraw()


func _draw() -> void:
	var hex := PackedVector2Array()
	var inner := PackedVector2Array()
	for corner: Vector2 in Unified.constants.station_shape:
		hex.append(corner * _r)
		inner.append(corner * _r * 0.55)
	var hp_frac := data.hp_frac if data != null else 1.0
	var hurt := 1.0 - hp_frac
	var fill := Color("1f2a3a").lerp(Color("3a1f26"), hurt * 0.8)
	draw_colored_polygon(hex, fill.lerp(Color.WHITE, _flash * 0.6))
	var edge := UiTheme.CYAN.lerp(UiTheme.BAD, hurt)
	var loop := hex.duplicate()
	loop.append(hex[0])
	draw_polyline(loop, edge.lerp(Color.WHITE, _flash), 3.0, true)
	var inner_loop := inner.duplicate()
	inner_loop.append(inner[0])
	draw_polyline(inner_loop, Color(edge, 0.5), 2.0, true)
	for k in hex.size():
		draw_line(inner[k], hex[k], Color(edge, 0.35), 1.5, true)
	# the core pulses faster as the station weakens
	var pulse := 0.5 + 0.5 * sin(_t * (2.0 + 6.0 * hurt))
	draw_circle(Vector2.ZERO, _r * 0.22, Color(edge, 0.5 + 0.4 * pulse))
	# HP ring, upright (undo the root's rotation)
	draw_set_transform(Vector2.ZERO, -rotation, Vector2.ONE)
	var ring := _r * 1.18
	draw_arc(Vector2.ZERO, ring, 0.0, TAU, 64, Color(0, 0, 0, 0.35), 5.0, true)
	if hp_frac > 0.0:
		var hp_col := UiTheme.GOOD.lerp(UiTheme.GOLD, clampf(hurt * 2.0, 0.0, 1.0)).lerp(UiTheme.BAD,
			clampf(hurt * 2.0 - 1.0, 0.0, 1.0))
		draw_arc(Vector2.ZERO, ring, -PI / 2.0, -PI / 2.0 + TAU * hp_frac, 64, hp_col, 4.0, true)


func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if event is EventStationHit and state == UnifiedSession.EVENT_EMITTED:
		_flash = 1.0
