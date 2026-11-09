extends Node3D
## The match scene: hands its `Views` node to the session (views spawn there), drives the start circle and
## routes sim events to effects and camera shake.

@onready var _views: Node3D = $Views
@onready var _circle: MeshInstance3D = $StartCircle
@onready var _camera: Camera3D = $Camera
var _circle_fade := 1.0
var _radius := 0.0
## 0..1: how close the furthest player is to the start circle's edge (drives the ring and the HUD hint).
var start_urgency := 0.0


func _ready() -> void:
	_radius = float(Game.constants.start_radius)
	if &"view_root" in Game.session:
		Game.session.view_root = _views
	else:
		push_warning("arena: the session has no view_root property; views won't spawn (see games/survivor/SPEC.md)")
	Game.session.sim_event.connect(_on_sim_event)
	$Fx.camera = _camera


func _exit_tree() -> void:
	if &"view_root" in Game.session and Game.session.view_root == _views:
		Game.session.view_root = null


func _process(delta: float) -> void:
	var lobby: bool = Game.hud.get("phase", "lobby") == "lobby"
	_circle_fade = move_toward(_circle_fade, 1.0 if lobby else 0.0, delta * 2.0)
	_circle.visible = _circle_fade > 0.001
	var r := float(Game.hud.get("circle_radius", 0.0))
	if r > 0.0:
		_radius = r  # the sim reports 0 outside the lobby; keep the ring's size while it fades
	var furthest := 0.0
	if lobby:
		for v in _views.get_children():
			if v is GameView and v.kind == &"player":
				furthest = maxf(furthest, Vector2(v.position.x, v.position.z).length() / _radius)
	start_urgency = move_toward(start_urgency, smoothstep(0.55, 1.0, furthest) if lobby else 0.0, delta * 4.0)
	var mat := _circle.mesh.surface_get_material(0) as ShaderMaterial
	mat.set_shader_parameter(&"fade", _circle_fade)
	mat.set_shader_parameter(&"radius", _radius)
	mat.set_shader_parameter(&"urgency", start_urgency)


func local_player_view() -> Node3D:
	var slot: int = Game.hud.get("local_slot", 0)
	for v in _views.get_children():
		if v is GameView and v.kind == &"player" and v.slot == slot:
			return v
	return null


func any_player_view() -> Node3D:
	for v in _views.get_children():
		if v is GameView and v.kind == &"player":
			return v
	return null


func _on_sim_event(kind: StringName, _tick: int, entity: int, pos: Vector3, value: float) -> void:
	var local := entity == int(Game.hud.get("local_slot", 0))
	if kind == &"match_started":
		$Fx.shockwave(_radius)
	$Fx.play(kind, entity, pos, value, local)
