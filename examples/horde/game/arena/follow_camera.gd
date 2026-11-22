class_name HordeCamera
extends Camera2D
## Follows the local hero (a smoothed chase, a cut on its first frame) within the arena and a margin, and shakes when
## told (bombs landing, the hero going down).

const CHASE_RATE := 8.0  # 1/s: how fast the camera closes on the hero
const MARGIN := 96.0  # px past the walls the camera may show
const SHAKE_DECAY := 30.0  # px/s
const SHAKE_MAX := 12.0  # px

var _shake := 0.0
var _found := false


func _ready() -> void:
	var half := ceili(Unified.constants.arena_half * Unified.view_scale + MARGIN)
	limit_left = -half
	limit_top = -half
	limit_right = half
	limit_bottom = half


func _process(delta: float) -> void:
	var hero := Unified.session.get_player_view(EnumView.HERO, Unified.session.local_player) as Node2D
	if hero != null:
		position = position.lerp(hero.position, 1.0 - exp(-CHASE_RATE * delta)) if _found else hero.position
		_found = true
	_shake = maxf(_shake - delta * SHAKE_DECAY, 0.0)
	offset = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * _shake


## Adds `amount` px of shake (up to SHAKE_MAX), decaying at SHAKE_DECAY.
func shake(amount: float) -> void:
	_shake = minf(_shake + amount, SHAKE_MAX)
