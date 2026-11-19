class_name DriftEffects
extends Node2D
## Short-lived world effects in one node (one draw call list, no per-effect nodes): debris and sparks flying out
## and fading, rings expanding. View-only; fed by the arena from the sim's events.

var _bits: Array[Dictionary] = []  ## {pos, vel, life, max, color, size}
var _rings: Array[Dictionary] = []  ## {pos, r0, r1, life, max, color, width}
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	z_index = 5
	_rng.randomize()


## `n` fragments from `at`, flying out at up to `speed` px/s, squares of `size` px.
func debris(at: Vector2, n: int, color: Color, speed: float, size: float) -> void:
	for _i in n:
		var life := _rng.randf_range(0.35, 0.8)
		_bits.append({"pos": at, "vel": Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(0.3, 1.0) * speed,
			"life": life, "max": life, "color": color, "size": size * _rng.randf_range(0.6, 1.3)})


func sparks(at: Vector2, n: int, color: Color) -> void:
	for _i in n:
		var life := _rng.randf_range(0.1, 0.25)
		_bits.append({"pos": at, "vel": Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(80.0, 220.0),
			"life": life, "max": life, "color": color, "size": 2.0})


func ring(at: Vector2, r0: float, r1: float, seconds: float, color: Color, width: float) -> void:
	_rings.append({"pos": at, "r0": r0, "r1": r1, "life": seconds, "max": seconds, "color": color, "width": width})


## Live effects (for the tour's checks).
func count() -> int:
	return _bits.size() + _rings.size()


func _process(delta: float) -> void:
	if _bits.is_empty() and _rings.is_empty():
		return
	var drag := exp(-delta * 3.0)
	for i in range(_bits.size() - 1, -1, -1):
		var b := _bits[i]
		b.life -= delta
		if b.life <= 0.0:
			_bits.remove_at(i)
			continue
		b.pos += b.vel * delta
		b.vel *= drag
	for i in range(_rings.size() - 1, -1, -1):
		_rings[i].life -= delta
		if _rings[i].life <= 0.0:
			_rings.remove_at(i)
	queue_redraw()


func _draw() -> void:
	for b in _bits:
		var k: float = b.life / b.max
		var s: float = b.size * (0.4 + 0.6 * k)
		var bit_pos: Vector2 = b.pos
		var bit_color: Color = b.color
		draw_rect(Rect2(bit_pos - Vector2(s, s) * 0.5, Vector2(s, s)), Color(bit_color, k))
	for r in _rings:
		var k: float = r.life / r.max
		var t := 1.0 - k
		var r0: float = r.r0
		var r1: float = r.r1
		var ring_pos: Vector2 = r.pos
		var ring_color: Color = r.color
		var width: float = r.width
		var radius := lerpf(r0, r1, 1.0 - (1.0 - t) * (1.0 - t))
		draw_arc(ring_pos, radius, 0.0, TAU, 48, Color(ring_color, ring_color.a * k), width, true)
