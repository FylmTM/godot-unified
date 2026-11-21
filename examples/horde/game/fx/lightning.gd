extends Line2D
## A lightning arc, the naive way: a Line2D node made per arc whose jagged points are made again every frame until it
## fades and frees itself.

const LIFE := 0.22
const SEGMENTS := 9
const JITTER := 9.0

var from := Vector2.ZERO
var to := Vector2.ZERO

var _age := 0.0


func _ready() -> void:
	width = 3.0
	default_color = Color(0.7, 0.9, 1.0)
	_jag()


func _process(delta: float) -> void:
	_age += delta
	if _age >= LIFE:
		queue_free()
		return
	modulate.a = 1.0 - _age / LIFE
	_jag()


func _jag() -> void:
	clear_points()
	var side := (to - from).orthogonal().normalized()
	for i in SEGMENTS + 1:
		var k := float(i) / SEGMENTS
		var offset := 0.0 if i == 0 or i == SEGMENTS else randf_range(-JITTER, JITTER)
		add_point(from.lerp(to, k) + side * offset)
