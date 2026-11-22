extends Node2D
## A bomb in the air (View_Bomb, pooled: bombs come and go every few seconds per hero): its shadow on the ground and
## the bomb up its arc, its fuse flickering. The host poses it along the flight; the arc's height is the view's.

const ARC_HEIGHT := 60.0  # px at the top of the flight
const FUSE_HZ := 12.0

## Null while the view waits in its kind's pool.
var data: ViewBomb:
	set(value):
		data = value
		queue_redraw()

var _fuse_age := 0.0


func _process(delta: float) -> void:
	_fuse_age += delta
	queue_redraw()


## Taken from the pool for a new bomb: its fuse starts over.
func _sim_reused() -> void:
	_fuse_age = 0.0


func _draw() -> void:
	if data == null:
		return
	var lift := sin(data.progress * PI) * ARC_HEIGHT
	draw_circle(Vector2.ZERO, 6.0 * (1.0 - data.progress * 0.3), Color(0, 0, 0, 0.35))
	draw_circle(Vector2(0, -lift), 7.0, Color(0.2, 0.2, 0.22))
	var fuse := Palette.BLAST if int(_fuse_age * FUSE_HZ * 2.0) % 2 == 0 else UiTheme.player_color(data.slot)
	draw_circle(Vector2(-2, -lift - 2), 2.5, fuse)
