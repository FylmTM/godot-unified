extends Node2D
## A hero (View_Hero, keyed by its player): a pulsing ring in its slot's colour, a body that flashes white while it
## was just hurt, a nose toward where it walks and an HP bar; a downed hero is a dim ring where it fell. Drawn every
## frame: only up to four exist.

const PULSE_HZ := 0.64
const FLASH_HZ := 10.0
const MIN_TURN_SPEED := 10.0  # px/s: slower moves keep the nose where it was

var data: ViewHero

var _age := 0.0
var _last_pos := Vector2.INF
var _look := Vector2.DOWN


func _process(delta: float) -> void:
	_age += delta
	if _last_pos != Vector2.INF and delta > 0.0:
		var vel := (position - _last_pos) / delta
		if vel.length() > MIN_TURN_SPEED:
			_look = vel.normalized()
	_last_pos = position
	queue_redraw()


func _draw() -> void:
	var radius := Unified.constants.hero_radius * Unified.view_scale
	var color := UiTheme.player_color(data.slot)
	if not data.alive:
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 24, color.darkened(0.5), 2.0)
		return
	var pulse := 0.5 + 0.5 * sin(_age * TAU * PULSE_HZ)
	draw_arc(Vector2.ZERO, radius * (1.6 + 0.15 * pulse), 0.0, TAU, 32, Color(color, 0.35), 2.0)
	var body := Color.WHITE if data.hurt and int(_age * FLASH_HZ * 2.0) % 2 == 0 else color
	draw_circle(Vector2.ZERO, radius, body.darkened(0.4))
	draw_circle(Vector2.ZERO, radius * 0.8, body)
	draw_circle(_look * radius * 0.7, radius * 0.25, Color.WHITE)
	var bar := Rect2(Vector2(-radius, radius + 5.0), Vector2(radius * 2.0, 4.0))
	draw_rect(bar, Color(0, 0, 0, 0.6))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * data.hp_share, bar.size.y)), UiTheme.GOOD)
