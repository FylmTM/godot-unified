class_name Arcs
extends Node2D
## Lightning arcs, the tuned way: one node draws every live arc (a jagged polyline made again each frame) from pooled
## arrays: no node per arc.

const LIFE := 0.22
const SEGMENTS := 9
const JITTER := 9.0

var _from := PackedVector2Array()
var _to := PackedVector2Array()
var _age := PackedFloat32Array()
var _points := PackedVector2Array()


## An arc from `from` to `to` (px).
func add(from: Vector2, to: Vector2) -> void:
	_from.append(from)
	_to.append(to)
	_age.append(0.0)


func _ready() -> void:
	_points.resize(SEGMENTS + 1)


func _process(delta: float) -> void:
	var keep := 0
	for i in _age.size():
		var age := _age[i] + delta
		if age >= LIFE:
			continue
		_from[keep] = _from[i]
		_to[keep] = _to[i]
		_age[keep] = age
		keep += 1
	_from.resize(keep)
	_to.resize(keep)
	_age.resize(keep)
	queue_redraw()


func _draw() -> void:
	for i in _age.size():
		var from := _from[i]
		var to := _to[i]
		var side := (to - from).orthogonal().normalized()
		for k in SEGMENTS + 1:
			var offset := 0.0 if k == 0 or k == SEGMENTS else randf_range(-JITTER, JITTER)
			_points[k] = from.lerp(to, float(k) / SEGMENTS) + side * offset
		draw_polyline(_points, Color(0.7, 0.9, 1.0, 1.0 - _age[i] / LIFE), 3.0)
