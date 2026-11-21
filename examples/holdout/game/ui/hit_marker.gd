class_name HitMarker
extends Control
## The hit marker around the crosshair (a zero-size Control at the screen's centre, drawn in code): a small white X
## that flashes when the local player's shot hits, a bigger red one that pops on a headshot, and a gold ring around it
## on a kill. Each fades on its own; a new hit restarts the X. The HUD says when (`hit`, `kill`).

const HIT_S := 0.18
const HEADSHOT_S := 0.35
const KILL_S := 0.45
const HIT_COLOR := Color(1, 1, 1)

var _x_left := 0.0  # seconds of the X still to show
var _x_total := HIT_S
var _headshot := false
var _ring_left := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	if _x_left <= 0.0 and _ring_left <= 0.0:
		return
	_x_left = maxf(_x_left - delta, 0.0)
	_ring_left = maxf(_ring_left - delta, 0.0)
	queue_redraw()


## A shot of the local player's hit an enemy, on its head when `headshot`.
func hit(headshot: bool) -> void:
	_headshot = headshot or (_headshot and _x_left > 0.0)  # a body hit right after a headshot keeps its red X
	_x_total = HEADSHOT_S if _headshot else HIT_S
	_x_left = _x_total
	queue_redraw()


## The local player killed an enemy.
func kill() -> void:
	_ring_left = KILL_S
	queue_redraw()


func _draw() -> void:
	if _x_left > 0.0:
		var t := _x_left / _x_total  # 1 at the hit, 0 when gone
		var color := UiTheme.BAD if _headshot else HIT_COLOR
		color.a = clampf(t * 1.5, 0.0, 1.0)
		var pop := 1.0 + (0.6 * t * t if _headshot else 0.0)  # a headshot's X starts big and settles
		var gap := (9.0 if _headshot else 7.0) * pop
		var arm := (12.0 if _headshot else 9.0) * pop
		var width := 3.5 if _headshot else 2.0
		for corner: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			var dir := corner.normalized()
			draw_line(dir * gap, dir * (gap + arm), Color(0, 0, 0, color.a * 0.6), width + 2.0, true)
			draw_line(dir * gap, dir * (gap + arm), color, width, true)
	if _ring_left > 0.0:
		var t := _ring_left / KILL_S
		var ring := UiTheme.GOLD
		ring.a = clampf(t * 1.5, 0.0, 1.0)
		var radius := 34.0 - 4.0 * t  # outside the X; widens a little as it fades
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 40, Color(0, 0, 0, ring.a * 0.5), 5.0, true)
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 40, ring, 3.0, true)
