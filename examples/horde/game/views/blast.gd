extends Node2D
## View_Blast, the naive way: a flash and an expanding shockwave ring drawn in GDScript.

var data: ViewBlast:
	set(value):
		data = value
		queue_redraw()


func _draw() -> void:
	var t := data.progress
	var color := Color(1.0, 0.65, 0.3)
	draw_circle(Vector2.ZERO, data.radius * (0.4 + 0.6 * t), Color(color, 0.35 * (1.0 - t)))
	draw_arc(Vector2.ZERO, data.radius * (0.5 + 0.6 * t), 0.0, TAU, 48, Color(1, 0.9, 0.7, 1.0 - t), 6.0 * (1.0 - t) + 1.0)
