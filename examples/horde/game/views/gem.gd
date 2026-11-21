extends Node2D
## View_Gem, the naive way: a diamond drawn in GDScript, bobbing every frame.

var data: ViewGem

var _age := 0.0


func _ready() -> void:
	_age = randf() * TAU


func _process(delta: float) -> void:
	_age += delta
	queue_redraw()


func _draw() -> void:
	var size := 5.0 + 2.0 * float(data.value)
	var lift := sin(_age * 5.0) * 2.0
	var points := PackedVector2Array([
		Vector2(0, -size + lift), Vector2(size * 0.7, lift), Vector2(0, size + lift), Vector2(-size * 0.7, lift)
	])
	draw_colored_polygon(points, Color(0.3, 0.9, 1.0))
	draw_polyline(points + PackedVector2Array([points[0]]), Color(0.8, 1, 1), 1.5)
