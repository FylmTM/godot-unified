extends UnifiedTool
## Writes the enemy sprite sheet (`uni tool horde_odin game/tools/make_enemy_sheet.gd`): a row per kind (grunt, runner, brute), 8 frames
## right: walk 0-3, idle 4-5, hurt 6, spawn 7. Pixel art drawn with hard edges, shadow included.

const PATH := "res://game/art/enemies.png"
const FRAME := 48
const COLUMNS := 8
const RADII: Array[float] = [11.0, 9.0, 19.0]
const COLORS: Array[Color] = [Color(0.55, 0.8, 0.35), Color(0.95, 0.7, 0.25), Color(0.7, 0.35, 0.9)]

var image: Image


func _run() -> void:
	image = Image.create_empty(FRAME * COLUMNS, FRAME * RADII.size(), false, Image.FORMAT_RGBA8)
	for kind in RADII.size():
		for frame in COLUMNS:
			_draw_frame(kind, frame, Vector2(frame * FRAME, kind * FRAME))
	var path := ProjectSettings.globalize_path(PATH)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	expect(image.save_png(path) == OK, "saved " + PATH)


func _draw_frame(kind: int, frame: int, cell: Vector2) -> void:
	var r := RADII[kind]
	var color := COLORS[kind]
	var origin := cell + Vector2(FRAME / 2.0, FRAME / 2.0 + 3.0)
	var bob := 0.0
	var sx := 1.0
	var sy := 1.0
	var stride := 0.0
	var closed := false
	var size := 1.0
	if frame < 4:
		var steps: Array[float] = [1.0, 0.0, -1.0, 0.0]
		stride = steps[frame]
		bob = -2.0 if frame % 2 == 1 else 0.0
		sy = 1.0 + 0.05 * absf(stride)
		sx = 1.0 - 0.04 * absf(stride)
	elif frame == 5:
		sy = 0.94
		sx = 1.05
	elif frame == 6:
		sx = 1.25
		sy = 0.8
		closed = true
	elif frame == 7:
		size = 0.55
	r *= size
	# the shadow stays on the ground
	_ellipse(origin + Vector2(0, r * 0.95), Vector2(r * 1.05, r * 0.32), Color(0, 0, 0, 0.35))
	var body := origin + Vector2(0, bob)
	# feet, swinging along x as it walks right
	var foot := Vector2(r * 0.32, r * 0.2)
	_ellipse(origin + Vector2(-r * 0.4 + stride * r * 0.25, r * 0.82), foot, color.darkened(0.55))
	_ellipse(origin + Vector2(r * 0.4 - stride * r * 0.25, r * 0.82), foot, color.darkened(0.55))
	match kind:
		0:  # grunt: an antenna
			_line(body + Vector2(-r * 0.2, -r * sy), body + Vector2(-r * 0.45, -r * sy - r * 0.6), color.darkened(0.5))
			_ellipse(body + Vector2(-r * 0.45, -r * sy - r * 0.6), Vector2(2.2, 2.2), Color(1.0, 0.95, 0.4))
		1:  # runner: swept-back ears
			_triangle(body + Vector2(-r * 0.1, -r * 0.7 * sy), body + Vector2(-r * 0.6, -r * 0.6 * sy), body + Vector2(-r * 1.0, -r * 1.35 * sy), color.darkened(0.35))
		2:  # brute: two horns
			for side: float in [-1.0, 1.0]:
				var base := body + Vector2(side * r * 0.45, -r * 0.75 * sy)
				_triangle(base + Vector2(-r * 0.18, 0), base + Vector2(r * 0.18, 0), base + Vector2(side * r * 0.25, -r * 0.55), Color(0.95, 0.92, 0.85))
	_ellipse(body, Vector2(r * sx, r * sy), color.darkened(0.45))
	_ellipse(body, Vector2(r * 0.84 * sx, r * 0.84 * sy), color)
	_ellipse(body + Vector2(-r * 0.1, r * 0.3 * sy), Vector2(r * 0.55 * sx, r * 0.38 * sy), color.lightened(0.25))
	# eyes toward +x
	var eye_r := maxf(r * 0.22, 1.5)
	for offset: float in [-0.3, 0.3]:
		var eye := body + Vector2(r * 0.38 * sx, r * offset * sy - r * 0.15)
		if closed:
			_line(eye - Vector2(eye_r, 0), eye + Vector2(eye_r, 0), Color(0.05, 0.05, 0.08))
		else:
			_ellipse(eye, Vector2(eye_r, eye_r), Color(1, 1, 1))
			_ellipse(eye + Vector2(eye_r * 0.35, 0), Vector2(eye_r * 0.5, eye_r * 0.5), Color(0.05, 0.05, 0.08))
	if kind == 2 and not closed:  # the brute's teeth
		for i in 3:
			var tooth := body + Vector2(r * 0.25 + i * r * 0.18, r * 0.42 * sy)
			_triangle(tooth, tooth + Vector2(r * 0.14, 0), tooth + Vector2(r * 0.07, r * 0.14), Color(1, 1, 1))


func _ellipse(center: Vector2, radii: Vector2, color: Color) -> void:
	for y in range(floori(center.y - radii.y), ceili(center.y + radii.y) + 1):
		for x in range(floori(center.x - radii.x), ceili(center.x + radii.x) + 1):
			var d := Vector2((x + 0.5 - center.x) / radii.x, (y + 0.5 - center.y) / radii.y)
			if d.length_squared() <= 1.0:
				_blend(x, y, color)


func _triangle(a: Vector2, b: Vector2, c: Vector2, color: Color) -> void:
	var low := Vector2(minf(a.x, minf(b.x, c.x)), minf(a.y, minf(b.y, c.y)))
	var high := Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.y, maxf(b.y, c.y)))
	for y in range(floori(low.y), ceili(high.y) + 1):
		for x in range(floori(low.x), ceili(high.x) + 1):
			var p := Vector2(x + 0.5, y + 0.5)
			if Geometry2D.point_is_inside_triangle(p, a, b, c):
				_blend(x, y, color)


func _line(from: Vector2, to: Vector2, color: Color) -> void:
	var steps := ceili(from.distance_to(to) * 2.0)
	for i in steps + 1:
		var p := from.lerp(to, float(i) / maxf(steps, 1))
		_blend(floori(p.x), floori(p.y), color)
		_blend(floori(p.x) + 1, floori(p.y), color)


func _blend(x: int, y: int, color: Color) -> void:
	if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
		return
	image.set_pixel(x, y, image.get_pixel(x, y).blend(color))
