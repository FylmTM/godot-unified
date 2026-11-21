extends Node2D
## The arena's floor: a grid and the wall, drawn once.


func _draw() -> void:
	var half := Palette.ARENA_HALF * Unified.view_scale
	draw_rect(Rect2(-half, -half, half * 2.0, half * 2.0), Palette.FLOOR)
	var step := Unified.view_scale * 2.0
	var x := -half
	while x <= half:
		draw_line(Vector2(x, -half), Vector2(x, half), Palette.GRID, 1.0)
		draw_line(Vector2(-half, x), Vector2(half, x), Palette.GRID, 1.0)
		x += step
	draw_rect(Rect2(-half, -half, half * 2.0, half * 2.0), Color(0.4, 0.42, 0.5), false, 4.0)
