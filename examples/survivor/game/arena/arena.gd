class_name SurvivorArena
extends Node3D
## The match scene: hands its `Views` node to the session (scene views spawn there; the MultiMesh views are under
## `MultiViews`), drives the start circle and routes sim events to effects and camera shake. The level's crates and
## barrels are its item markers: they go, the sim's item views draw the items.

@onready var _level: Node3D = $Level
@onready var _views: Node3D = $Views
@onready var _circle: MeshInstance3D = $StartCircle
@onready var _camera: SurvivorCamera = $Camera
@onready var _fx: SurvivorFx = $Fx
var _circle_fade := 1.0
var _radius := 0.0  # the start circle's (the sim's START_RADIUS)
## 0..1: how close the furthest player is to the start circle's edge (drives the ring and the HUD hint).
var start_urgency := 0.0


func _ready() -> void:
	for marker: Node in Unified.level_markers(_level):
		if marker is SurvivorPropView:
			marker.queue_free()
	_radius = Unified.constants.start_radius
	Unified.session.view_root = _views
	Unified.session.sim_event.connect(_on_sim_event)
	_fx.camera = _camera


func _process(delta: float) -> void:
	var lobby := Unified.data.hud.phase == EnumPhase.LOBBY
	_circle_fade = move_toward(_circle_fade, 1.0 if lobby else 0.0, delta * 2.0)
	_circle.visible = _circle_fade > 0.001
	var furthest := 0.0
	if lobby:
		for v: Node3D in Unified.session.get_views(EnumView.PLAYER):
			furthest = maxf(furthest, Vector2(v.position.x, v.position.z).length() / _radius)
	start_urgency = move_toward(start_urgency, smoothstep(0.55, 1.0, furthest) if lobby else 0.0, delta * 4.0)
	var mat := _circle.mesh.surface_get_material(0) as ShaderMaterial
	mat.set_shader_parameter(&"fade", _circle_fade)
	mat.set_shader_parameter(&"radius", _radius)
	mat.set_shader_parameter(&"urgency", start_urgency)


## Effects, sounds, shake and rumble play when an event is emitted, a prediction too, so the horde answers at once;
## one a rollback cancels is left as it played. Banners and the record wait for the confirmation (hud.gd).
func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state != UnifiedSession.EVENT_EMITTED:
		return
	if event is EventMatchStarted:
		_fx.shockwave(_radius)
	_fx.play(event)
