class_name Felt
extends Control
## The tabletop under everything, drawn in code: green baize lit from above (a radial wash, darkest at the corners), a
## faint weave, and a walnut rim with a brass inlay around the window's edge. The table and the main menu stand on it.

const BAIZE := Color("2f5d40")
const BAIZE_EDGE := Color("0d1f15")
const WOOD := Color("3b2414")
const BRASS := Color("9a7432")
const RIM := 14.0

var _wash: GradientTexture2D


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	gradient.colors = PackedColorArray([BAIZE, BAIZE.lerp(BAIZE_EDGE, 0.45), BAIZE_EDGE])
	_wash = GradientTexture2D.new()
	_wash.gradient = gradient
	_wash.fill = GradientTexture2D.FILL_RADIAL
	_wash.fill_from = Vector2(0.5, 0.38)
	_wash.fill_to = Vector2(1.05, 1.05)
	_wash.width = 256
	_wash.height = 256
	resized.connect(queue_redraw)


func _draw() -> void:
	var area := Rect2(Vector2.ZERO, size)
	draw_texture_rect(_wash, area, false)
	# the weave: faint diagonal threads
	var thread := Color(0, 0, 0, 0.05)
	var step := 9.0
	var x := -size.y
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x + size.y, size.y), thread, 1.0)
		x += step
	# the rim and its inlay
	var rim := StyleBoxFlat.new()
	rim.draw_center = false
	rim.border_color = WOOD
	rim.set_border_width_all(int(RIM))
	rim.shadow_color = Color(0, 0, 0, 0.0)
	draw_style_box(rim, area)
	draw_rect(area.grow(-RIM), BRASS, false, 2.0)
	draw_rect(area.grow(-RIM - 2.0), Color(0, 0, 0, 0.35), false, 4.0)
