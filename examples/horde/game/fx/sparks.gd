class_name Sparks
extends Node2D
## Particles, the naive way: parallel packed arrays updated in a GDScript loop and drawn with one draw_circle per
## particle every frame. Cosmetic only: a cancelled event leaves its sparks flying.

const MAX := 6000
const GRAVITY := 260.0
const DRAG := 2.5

var _pos := PackedVector2Array()
var _vel := PackedVector2Array()
var _age := PackedFloat32Array()
var _life := PackedFloat32Array()
var _size := PackedFloat32Array()
var _color := PackedColorArray()


## `count` sparks from `at` (px) in `color`, up to `speed` px/s each way.
func burst(at: Vector2, count: int, color: Color, speed: float, size: float, life: float) -> void:
	for i in count:
		if _pos.size() >= MAX:
			_drop_oldest()
		var angle := randf() * TAU
		_pos.append(at)
		_vel.append(Vector2.from_angle(angle) * speed * (0.3 + 0.7 * randf()) + Vector2(0, -speed * 0.3))
		_age.append(0.0)
		_life.append(life * (0.6 + 0.4 * randf()))
		_size.append(size * (0.6 + 0.4 * randf()))
		_color.append(color)


## How many sparks fly.
func count() -> int:
	return _pos.size()


func _process(delta: float) -> void:
	var keep := 0
	var drag := exp(-DRAG * delta)
	for i in _pos.size():
		var age := _age[i] + delta
		if age >= _life[i]:
			continue
		var vel := _vel[i] * drag + Vector2(0, GRAVITY * delta)
		_vel[keep] = vel
		_pos[keep] = _pos[i] + vel * delta
		_age[keep] = age
		_life[keep] = _life[i]
		_size[keep] = _size[i]
		_color[keep] = _color[i]
		keep += 1
	_pos.resize(keep)
	_vel.resize(keep)
	_age.resize(keep)
	_life.resize(keep)
	_size.resize(keep)
	_color.resize(keep)
	queue_redraw()


func _draw() -> void:
	for i in _pos.size():
		var k := _age[i] / _life[i]
		var c := _color[i]
		draw_circle(_pos[i], _size[i] * (1.0 - 0.6 * k), Color(c.r, c.g, c.b, c.a * (1.0 - k * k)))


func _drop_oldest() -> void:
	_pos.remove_at(0)
	_vel.remove_at(0)
	_age.remove_at(0)
	_life.remove_at(0)
	_size.remove_at(0)
	_color.remove_at(0)
