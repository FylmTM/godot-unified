class_name SurvivorArena
extends Node3D
## The match scene: hands its `Views` node to the session (scene views spawn there; the MultiMesh views are under
## `Bulk`), drives the start circle and routes sim events to effects and camera shake.

@onready var _views: Node3D = $Views
@onready var _circle: MeshInstance3D = $StartCircle
@onready var _camera: SurvivorCamera = $Camera
@onready var _fx: SurvivorFx = $Fx
var _circle_fade := 1.0
var _radius := 0.0
## 0..1: how close the furthest player is to the start circle's edge (drives the ring and the HUD hint).
var start_urgency := 0.0


func _ready() -> void:
	_radius = Unified.constants.start_radius
	Game.session.view_root = _views
	Game.session.sim_event.connect(_on_sim_event)
	_fx.camera = _camera


func _exit_tree() -> void:
	if Game.session.view_root == _views:
		Game.session.view_root = null


func _process(delta: float) -> void:
	var lobby := Unified.hud.phase == EnumPhase.LOBBY
	_circle_fade = move_toward(_circle_fade, 1.0 if lobby else 0.0, delta * 2.0)
	_circle.visible = _circle_fade > 0.001
	var r := Unified.hud.circle_radius
	if r > 0.0:
		_radius = r  # the sim reports 0 outside the lobby; keep the ring's size while it fades
	var furthest := 0.0
	if lobby:
		for v in player_views():
			furthest = maxf(furthest, Vector2(v.position.x, v.position.z).length() / _radius)
	start_urgency = move_toward(start_urgency, smoothstep(0.55, 1.0, furthest) if lobby else 0.0, delta * 4.0)
	var mat := _circle.mesh.surface_get_material(0) as ShaderMaterial
	mat.set_shader_parameter(&"fade", _circle_fade)
	mat.set_shader_parameter(&"radius", _radius)
	mat.set_shader_parameter(&"urgency", start_urgency)


## The players' views under the views root.
func player_views() -> Array[SurvivorPlayerView]:
	var out: Array[SurvivorPlayerView] = []
	for v in _views.get_children():
		var player_view := v as SurvivorPlayerView
		if player_view != null:
			out.append(player_view)
	return out


func local_player_view() -> SurvivorPlayerView:
	var player := Game.local_player()
	for v in player_views():
		if v.player == player:
			return v
	return null


func any_player_view() -> SurvivorPlayerView:
	var views := player_views()
	return views[0] if not views.is_empty() else null


## Effects play when an event is confirmed (its tick verified), never on a prediction.
func _on_sim_event(event: UnifiedEvent, state: int) -> void:
	if state != UnifiedSession.EVENT_CONFIRMED:
		return
	if event is EventMatchStarted:
		_fx.shockwave(_radius)
	_fx.play(event)
