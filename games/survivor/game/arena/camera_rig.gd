class_name SurvivorCamera
extends Camera3D
## Top-down follow camera: tracks the local player (a teammate while dead) with exponential smoothing and a
## look-ahead in the direction of travel (more of the arena ahead, where enemies come from), pulls in a little in
## the lobby, and shakes from `add_trauma` (amount 0..1, decays; offset ~ trauma²).

@export var pitch_deg := 62.0
@export var distance_match := 25.0
@export var distance_lobby := 18.0
@export var follow_rate := 6.0
## Metres of look-ahead per m/s of player speed, capped by `max_lead`.
@export var lead := 0.45
@export var max_lead := 3.5
@export var max_shake := 0.6

var _lead := Vector3.ZERO

var _target := Vector3.ZERO
var _distance := 22.0
var _trauma := 0.0
var _t := 0.0


func add_trauma(amount: float) -> void:
	_trauma = minf(_trauma + amount, 1.0)


func _process(delta: float) -> void:
	var arena := get_parent() as SurvivorArena
	var v: SurvivorPlayerView = arena.local_player_view() if arena != null else null
	if v == null and arena != null:
		v = arena.any_player_view()
	var goal := Vector3(v.position.x, 0, v.position.z) if v != null else _target
	var vel := v.velocity if v != null else Vector3.ZERO
	var lobby := Unified.data.hud.phase == EnumPhase.LOBBY
	var want_lead := Vector3(vel.x, 0, vel.z) * lead if not lobby else Vector3.ZERO
	_lead = _lead.lerp(want_lead.limit_length(max_lead), 1.0 - exp(-delta * 1.5))
	goal += _lead
	var k := 1.0 - exp(-delta * follow_rate)
	_target = _target.lerp(goal, k)
	_distance = lerpf(_distance, distance_lobby if lobby else distance_match, 1.0 - exp(-delta * 2.0))
	var pitch := deg_to_rad(pitch_deg)
	var offset := Vector3(0, sin(pitch), cos(pitch)) * _distance
	_t += delta
	_trauma = maxf(_trauma - delta * 1.6, 0.0)
	var s := _trauma * _trauma * max_shake
	var shake := Vector3(sin(_t * 47.0), sin(_t * 39.0 + 1.3), sin(_t * 53.0 + 2.1)) * s
	position = _target + offset + shake
	look_at(_target + shake * 0.5, Vector3.UP)
