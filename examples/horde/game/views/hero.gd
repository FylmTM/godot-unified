extends Node2D
## View_Hero, the naive way: drawn in GDScript every frame (a ring, a body, a facing nose, an HP bar).

var data: ViewHero

var _age := 0.0
var _last_pos := Vector2.INF
var _look := Vector2.DOWN


func _process(delta: float) -> void:
	_age += delta
	if _last_pos != Vector2.INF and delta > 0.0:
		var vel := (position - _last_pos) / delta
		if vel.length() > 10.0:
			_look = vel.normalized()
	_last_pos = position
	queue_redraw()


func _draw() -> void:
	var r := Palette.HERO_RADIUS * Unified.view_scale
	var color := Palette.SLOT_COLORS[data.slot % Palette.SLOT_COLORS.size()]
	if not data.alive:
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 24, color.darkened(0.5), 2.0)
		return
	var pulse := 0.5 + 0.5 * sin(_age * 4.0)
	draw_arc(Vector2.ZERO, r * (1.6 + 0.15 * pulse), 0.0, TAU, 32, Color(color, 0.35), 2.0)
	var body := Color.WHITE if data.hurt and int(_age * 20.0) % 2 == 0 else color
	draw_circle(Vector2.ZERO, r, body.darkened(0.4))
	draw_circle(Vector2.ZERO, r * 0.8, body)
	draw_circle(_look * r * 0.7, r * 0.25, Color(1, 1, 1))
	draw_rect(Rect2(Vector2(-r, r + 5.0), Vector2(r * 2.0, 4.0)), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(Vector2(-r, r + 5.0), Vector2(r * 2.0 * data.hp_k, 4.0)), Color(0.3, 0.95, 0.4))
