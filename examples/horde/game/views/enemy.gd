extends Node2D
## View_Enemy, the naive way (the experiment's baseline): three Node2D layers (shadow, body, HP bar) drawn in GDScript
## every frame, a wobble and a pop-in computed per enemy per frame, and a string key per frame to decide the redraws.

var data: ViewEnemy

var _age := 0.0
var _phase := 0.0
var _last_pos := Vector2.INF
var _vel := Vector2.ZERO
var _key := ""

@onready var _shadow: Node2D = $Shadow
@onready var _body: Node2D = $Body
@onready var _bar: Node2D = $Bar


func _ready() -> void:
	_phase = randf() * TAU
	_shadow.draw.connect(_draw_shadow)
	_body.draw.connect(_draw_body)
	_bar.draw.connect(_draw_bar)


func _process(delta: float) -> void:
	_age += delta
	if _last_pos != Vector2.INF and delta > 0.0:
		_vel = _vel.lerp((position - _last_pos) / delta, clampf(delta * 10.0, 0.0, 1.0))
	_last_pos = position
	var wobble := sin(_age * 9.0 + _phase)
	var pop := clampf(_age / 0.25, 0.0, 1.0)
	_body.scale = Vector2(1.0 + 0.08 * wobble, 1.0 - 0.08 * wobble) * pop
	var key := "%d|%s|%.2f|%d|%d" % [data.kind, data.flash, data.hp_k, int(_vel.x), int(_vel.y)]
	if key != _key:
		_key = key
		_body.queue_redraw()
		_bar.queue_redraw()
	_shadow.queue_redraw()


func _draw_shadow() -> void:
	var r := Palette.ENEMY_RADIUS[data.kind] * Unified.view_scale
	var points := PackedVector2Array()
	for i in 16:
		var angle := TAU * i / 16.0
		points.append(Vector2(cos(angle) * r, r * 0.55 + sin(angle) * r * 0.3))
	_shadow.draw_colored_polygon(points, Color(0, 0, 0, 0.35))


func _draw_body() -> void:
	var r := Palette.ENEMY_RADIUS[data.kind] * Unified.view_scale
	var color := Color.WHITE if data.flash else Palette.ENEMY_COLORS[data.kind]
	_body.draw_circle(Vector2.ZERO, r, color.darkened(0.45))
	_body.draw_circle(Vector2.ZERO, r * 0.82, color)
	var look := _vel.normalized() if _vel.length() > 1.0 else Vector2.DOWN
	var side := look.orthogonal() * r * 0.32
	for eye: Vector2 in [look * r * 0.35 + side, look * r * 0.35 - side]:
		_body.draw_circle(eye, r * 0.2, Color(1, 1, 1))
		_body.draw_circle(eye + look * r * 0.07, r * 0.1, Color(0.05, 0.05, 0.08))


func _draw_bar() -> void:
	if data.hp_k >= 1.0:
		return
	var r := Palette.ENEMY_RADIUS[data.kind] * Unified.view_scale
	var width := r * 2.0
	var top := Vector2(-r, -r - 7.0)
	_bar.draw_rect(Rect2(top, Vector2(width, 4.0)), Color(0, 0, 0, 0.6))
	_bar.draw_rect(Rect2(top, Vector2(width * data.hp_k, 4.0)), Color(0.9, 0.2, 0.2))
