extends Node2D
## The arena's floor: the ground, a grid every GRID_UNITS sim units and the walls, drawn once at the sim's size
## (Unified.constants.arena_half). The play scene and the menu's backdrop both show it.

const GRID_UNITS := 2.0
const WALL_WIDTH := 4.0


func _draw() -> void:
	var half := Unified.constants.arena_half * Unified.view_scale
	var arena := Rect2(-half, -half, half * 2.0, half * 2.0)
	draw_rect(arena, Palette.FLOOR)
	var step := Unified.view_scale * GRID_UNITS
	var line := -half
	while line <= half:
		draw_line(Vector2(line, -half), Vector2(line, half), Palette.GRID, 1.0)
		draw_line(Vector2(-half, line), Vector2(half, line), Palette.GRID, 1.0)
		line += step
	draw_rect(arena, Palette.WALL, false, WALL_WIDTH)
