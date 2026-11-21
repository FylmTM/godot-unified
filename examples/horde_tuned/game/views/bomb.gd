extends Node2D
## View_Bomb, the naive way: a shadow on the ground and the bomb up its arc, drawn in GDScript every frame.

const ARC_HEIGHT := 60.0

var data: ViewBomb:
	set(value):
		data = value
		queue_redraw()


func _draw() -> void:
	var lift := sin(data.progress * PI) * ARC_HEIGHT
	draw_circle(Vector2.ZERO, 6.0 * (1.0 - data.progress * 0.3), Color(0, 0, 0, 0.35))
	draw_circle(Vector2(0, -lift), 7.0, Color(0.2, 0.2, 0.22))
	draw_circle(Vector2(-2, -lift - 2), 2.5, Color(1.0, 0.6, 0.25))
