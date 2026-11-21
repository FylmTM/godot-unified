extends Label
## A damage number, the naive way: a Label node made per hit that floats up, fades and frees itself.

const LIFE := 0.7
const RISE := 40.0

var _age := 0.0
var _drift := 0.0


func _ready() -> void:
	_drift = randf_range(-20.0, 20.0)


func _process(delta: float) -> void:
	_age += delta
	if _age >= LIFE:
		queue_free()
		return
	position += Vector2(_drift, -RISE) * delta
	modulate.a = 1.0 - (_age / LIFE) * (_age / LIFE)
	scale = Vector2.ONE * (1.0 + 0.4 * maxf(0.0, 1.0 - _age * 8.0))
