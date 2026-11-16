extends Node2D
## The station: a Node2D view with a UnifiedView marker. The host sets its
## position and rotation (it turns slowly), and `hp_frac` from Station_View; it flashes when that drops. Drawn in
## code: the hexagon the sim simulates (corners at k × 60°, radius `station_radius`), and an HP ring that stays
## upright. Also the menu's backdrop decoration (no session there).

## Station_View (simulation/extension), set by the host when it changes: 0..1.
var hp_frac := 1.0:
	set(v):
		if v < hp_frac - 0.001:
			_flash = 1.0
		hp_frac = v
		queue_redraw()

var _r := 80.0  ## the hexagon's corner radius, in pixels
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
	for k in 6:
		var a := k * TAU / 6.0
		hex.append(Vector2(cos(a), sin(a)) * _r)
		inner.append(Vector2(cos(a), sin(a)) * _r * 0.55)
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
	for k in 6:
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


func _sim_event(event: UnifiedEvent, state: int) -> void:
	if event is EventStationHit and state == UnifiedSession.EVENT_EMITTED:
		_flash = 1.0
