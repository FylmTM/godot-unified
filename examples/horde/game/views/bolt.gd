extends Node2D
## View_Bolt, the naive way: a glowing head drawn in GDScript and a trail Line2D that takes a point every frame.

const TRAIL_POINTS := 10

var data: ViewBolt

@onready var _trail: Line2D = $Trail


func _ready() -> void:
	var color := Palette.SLOT_COLORS[data.slot % Palette.SLOT_COLORS.size()]
	_trail.default_color = Color(color, 0.6)
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0))
	fade.set_color(1, Color(1, 1, 1, 1))
	_trail.gradient = fade


func _process(_delta: float) -> void:
	_trail.add_point(global_position)
	while _trail.get_point_count() > TRAIL_POINTS:
		_trail.remove_point(0)
	queue_redraw()


func _draw() -> void:
	var color := Palette.SLOT_COLORS[data.slot % Palette.SLOT_COLORS.size()]
	draw_circle(Vector2.ZERO, 7.0, Color(color, 0.3))
	draw_circle(Vector2.ZERO, 4.0, color.lightened(0.5))
	draw_line(Vector2(-6.0, 0.0), Vector2(6.0, 0.0), Color(1, 1, 1), 2.0)
