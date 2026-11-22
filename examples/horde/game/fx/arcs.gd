class_name Arcs
extends Node2D
## Lightning arcs: one node draws every live arc, a jagged polyline made again each frame from packed arrays, so an
## arc is three appends and no node.

const LIFE := 0.22  # s
const SEGMENTS := 9
const JITTER := 9.0  # px across the arc, at most
const WIDTH := 3.0

var _from := PackedVector2Array()
var _to := PackedVector2Array()
var _age := PackedFloat32Array()
var _points := PackedVector2Array()


func _ready() -> void:
	_points.resize(SEGMENTS + 1)


func _process(delta: float) -> void:
	if _age.is_empty():
		return
	var kept := 0
	for i in _age.size():
		var age := _age[i] + delta
		if age >= LIFE:
			continue
		_from[kept] = _from[i]
		_to[kept] = _to[i]
		_age[kept] = age
		kept += 1
	_from.resize(kept)
	_to.resize(kept)
	_age.resize(kept)
	queue_redraw()


func _draw() -> void:
	for i in _age.size():
		var from := _from[i]
		var to := _to[i]
		var side := (to - from).orthogonal().normalized()
		for k in SEGMENTS + 1:
			var offset := 0.0 if k == 0 or k == SEGMENTS else randf_range(-JITTER, JITTER)
			_points[k] = from.lerp(to, float(k) / SEGMENTS) + side * offset
		draw_polyline(_points, Color(Palette.ARC, 1.0 - _age[i] / LIFE), WIDTH)


## An arc from `from` to `to` (px).
func add(from: Vector2, to: Vector2) -> void:
	_from.append(from)
	_to.append(to)
	_age.append(0.0)
