extends GameView
## A player: slot-coloured capsule with a visor, a floor ring (bright for the local player), a name tag, lean and
## bob while moving, a hit flash when HP drops and an after-image trail while dashing.

const DASH_SPEED := 9.0  # m/s; faster than the 6 m/s walk + upgrades means a dash
const GHOST_EVERY := 0.025

@onready var _body: Node3D = $Body
@onready var _mesh: MeshInstance3D = $Body/Mesh
@onready var _ring: MeshInstance3D = $Ring
@onready var _label: Label3D = $Name
var _mat: StandardMaterial3D
var _last_pos := Vector3.ZERO
var _vel := Vector3.ZERO
## Smoothed velocity (m/s) from the interpolated positions; the camera leads with it.
var velocity: Vector3:
	get:
		return _vel
var _yaw := 0.0
var _flash := 0.0
var _last_hp := -1.0
var _ghost_t := 0.0
var _bob := 0.0
var _has_pos := false
var _leaving := false
var _exit: Tween


func _ready() -> void:
	var color := UiTheme.slot_color(slot)
	_mat = (_mesh.get_surface_override_material(0) as StandardMaterial3D).duplicate()
	_mat.albedo_color = color
	_mesh.set_surface_override_material(0, _mat)
	var ring_mat := (_ring.get_surface_override_material(0) as StandardMaterial3D).duplicate()
	ring_mat.albedo_color = Color(color * (2.2 if _is_local() else 0.8), 1.0)
	_ring.set_surface_override_material(0, ring_mat)
	_label.modulate = color.lightened(0.35)


func _sim_update(pos: Vector3, yaw: float, _alpha: float) -> void:
	if _leaving:
		return
	quaternion = Quaternion.IDENTITY  # the host may set the root's rotation; the body turns by yaw below
	var dt := get_process_delta_time()
	if _has_pos and dt > 0.0:
		_vel = _vel.lerp((pos - _last_pos) / dt, 1.0 - exp(-dt * 20.0))
	_has_pos = true
	_last_pos = pos
	_yaw = lerp_angle(_yaw, yaw, 1.0 - exp(-dt * 18.0))
	var flat := Vector3(_vel.x, 0, _vel.z)
	var speed := flat.length()
	# Face the sim's yaw, lean into the motion (tilt about the axis perpendicular to it) and bob while walking.
	_body.basis = Basis.from_euler(Vector3(0, _yaw, 0))
	var lean := flat.limit_length(8.0) * 0.035
	if lean.length() > 0.001:
		_body.basis = Basis(Vector3(lean.z, 0, -lean.x).normalized(), lean.length()) * _body.basis
	_bob += dt * speed * 2.2
	_body.position.y = absf(sin(_bob)) * 0.08 * minf(speed / 6.0, 1.0)
	_update_hud_state(dt)
	if speed > DASH_SPEED:
		_ghost_t -= dt
		if _ghost_t <= 0.0:
			_ghost_t = GHOST_EVERY
			_spawn_ghost()


func _sim_event(event: StringName, _data: Dictionary) -> void:
	if event == &"despawned":  # died or left: shrink away during the host's linger time
		_leaving = true
		_exit = create_tween()
		_exit.tween_property(self, "scale", Vector3.ONE * 0.01, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	elif event == &"revived" and _leaving:  # a rollback brought it back within the linger time
		_leaving = false
		if _exit != null:
			_exit.kill()
		scale = Vector3.ONE


func _update_hud_state(dt: float) -> void:
	var p := _hud_player()
	if not p.is_empty():
		_label.text = Game.player_name(p)
		var hp: float = p.get("hp", 0.0)
		if _last_hp >= 0.0 and hp < _last_hp - 0.01:
			_flash = 1.0
			if _is_local():
				Sfx.play(&"hit", -4.0)
		_last_hp = hp
	if _flash > 0.0:
		# Emission stays enabled in the scene's material and only its colour changes: toggling
		# `emission_enabled` switches the shader variant and compiled a new shader on the first hit.
		_flash = maxf(_flash - dt * 6.0, 0.0)
		_mat.emission = Color(1, 0.3, 0.3) * _flash * 1.5
	_mesh.scale = Vector3.ONE * (1.0 + _flash * 0.15)


func _spawn_ghost() -> void:
	var g := MeshInstance3D.new()
	g.mesh = _mesh.mesh
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(_mat.albedo_color, 0.45)
	g.material_override = m
	g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_parent().add_child(g)
	g.global_transform = _mesh.global_transform
	var tw := g.create_tween().set_parallel()
	tw.tween_property(m, "albedo_color:a", 0.0, 0.25)
	tw.tween_property(g, "scale", Vector3.ONE * 0.7, 0.25)
	tw.chain().tween_callback(g.queue_free)


func _hud_player() -> Dictionary:
	for p: Dictionary in Game.hud.get("players", []):
		if p.get("slot", -1) == slot:
			return p
	return {}


func _is_local() -> bool:
	return slot == int(Game.hud.get("local_slot", 0))
