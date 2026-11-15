class_name DriftCamera
extends Camera2D
## Follows the local ship (position smoothing, within the arena's limits) and shakes on station hits. A warp moves
## the ship across the arena in one frame: the camera cuts instead of panning there.

const CUT_DIST := 256.0  ## pixels in one frame: a warp or a respawn, not flight

var _shake := 0.0
var _last := Vector2.INF
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 11


func set_bounds(r: Rect2) -> void:
	limit_left = floori(r.position.x)
	limit_top = floori(r.position.y)
	limit_right = ceili(r.end.x)
	limit_bottom = ceili(r.end.y)


func shake(amount: float) -> void:
	_shake = maxf(_shake, amount)


func _process(delta: float) -> void:
	var arena := get_parent() as DriftArena
	var me: Node2D = arena.local_ship_view() if arena != null else null
	if me != null:
		var p := me.global_position
		position = p
		if _last != Vector2.INF and p.distance_to(_last) > CUT_DIST:
			reset_smoothing()
		_last = p
	_shake = move_toward(_shake, 0.0, delta * 1.5)
	offset = Vector2(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * _shake * 10.0
