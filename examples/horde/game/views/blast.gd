extends Node2D
## A blast where a bomb landed (View_Blast, pooled: one per bomb): a flash and a shockwave ring growing to its radius
## and fading over its showing, the ring's dashes at a turn of their own so no two blasts look alike.

const DASHES := 12

## Null while the view waits in its kind's pool.
var data: ViewBlast:
	set(value):
		data = value
		queue_redraw()

var _turn := randf() * TAU


## Taken from the pool for a new blast: a new turn for its dashes.
func _sim_reused() -> void:
	_turn = randf() * TAU


func _draw() -> void:
	if data == null:
		return
	var progress := data.progress
	var fade := 1.0 - progress
	draw_circle(Vector2.ZERO, data.radius * (0.4 + 0.6 * progress), Color(Palette.BLAST, 0.35 * fade))
	var ring := data.radius * (0.5 + 0.6 * progress)
	var width := 6.0 * fade + 1.0
	var ring_color := Color(UiTheme.player_color(data.slot).lightened(0.5), fade)
	for i in DASHES:
		var start := _turn + TAU * i / DASHES
		draw_arc(Vector2.ZERO, ring, start, start + TAU / DASHES * 0.7, 8, ring_color, width)
