class_name Bars
## The HP bars' look: a flat, rounded box of one colour (a ProgressBar's fill or background).


static func fill(color: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(3)
	return box
