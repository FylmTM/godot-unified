class_name SurvivorPlayerView
extends Node3D
## A player: a capsule in the player's colour with a visor, a floor ring (bright for the local player), a name tag, lean and
## bob while moving, a hit flash when HP drops and an after-image trail while dashing. `player` (its UnifiedView
## marker's) is the player it shows (their key); the view lives while the player is in the session (dead too). The
## colour is their slot's, so it follows them when they come back in another slot.

const GHOST_EVERY := 0.025

@onready var _marker: UnifiedView = %UnifiedView
@onready var _body: Node3D = $Body
@onready var _mesh: MeshInstance3D = $Body/Mesh
@onready var _ring: MeshInstance3D = $Ring
@onready var _label: Label3D = $Name
var _mat: StandardMaterial3D
var _ring_mat: StandardMaterial3D
var _slot := -1
var _last_pos := Vector3.ZERO
var _vel := Vector3.ZERO
## The key of the player it shows (the marker's, set by the host before the view enters the tree).
var player: int:
	get:
		return _marker.player
## Smoothed velocity (m/s) from the interpolated positions; the camera leads with it.
var velocity: Vector3:
	get:
		return _vel
## View_Player (simulation/extension): set by the host before _ready, and anew each time it changes. An HP drop
## flashes; `dashing` leaves an after-image trail while it lasts.
var data: ViewPlayer:
	set(value):
		if data != null and value.hp < data.hp:
			_flash = 1.0
			if _is_local():
				Sfx.play(&"hit", -4.0)
		data = value
var _yaw := 0.0
var _flash := 0.0
var _ghost_t := 0.0
var _bob := 0.0
var _has_pos := false
var _leaving := false
var _exit: Tween


func _ready() -> void:
	_mat = _mesh.get_surface_override_material(0).duplicate() as StandardMaterial3D
	_mesh.set_surface_override_material(0, _mat)
	_ring_mat = _ring.get_surface_override_material(0).duplicate() as StandardMaterial3D
	_ring.set_surface_override_material(0, _ring_mat)
	_color_slot(maxi(Unified.session.get_player_slot(player), 0))


## Colours the player as `slot`'s.
func _color_slot(slot: int) -> void:
	_slot = slot
	var color := UiTheme.player_color(slot)
	_mat.albedo_color = color
	_ring_mat.albedo_color = Color(color * (2.2 if _is_local() else 0.8), 1.0)
	_label.modulate = color.lightened(0.35)


## The host has posed the root (the interpolated position) before this runs.
func _process(dt: float) -> void:
	quaternion = Quaternion.IDENTITY  # the host sets the root's rotation; the body turns by its motion below
	if _has_pos and dt > 0.0:
		_vel = _vel.lerp((position - _last_pos) / dt, 1.0 - exp(-dt * 20.0))
	_has_pos = true
	_last_pos = position
	var flat := Vector3(_vel.x, 0, _vel.z)
	var speed := flat.length()
	if speed > 0.5:  # the sim keeps no facing: turn toward the motion, keep the last yaw while standing
		_yaw = lerp_angle(_yaw, atan2(flat.x, flat.z), 1.0 - exp(-dt * 18.0))
	# Face the motion, lean into it (tilt about the axis perpendicular to it) and bob while walking.
	_body.basis = Basis.from_euler(Vector3(0, _yaw, 0))
	var lean := flat.limit_length(8.0) * 0.035
	if lean.length() > 0.001:
		_body.basis = Basis(Vector3(lean.z, 0, -lean.x).normalized(), lean.length()) * _body.basis
	_bob += dt * speed * 2.2
	_body.position.y = absf(sin(_bob)) * 0.08 * minf(speed / 6.0, 1.0)
	_update_hud_state(dt)
	if data.dashing:
		_ghost_t -= dt
		if _ghost_t <= 0.0:
			_ghost_t = GHOST_EVERY
			_spawn_ghost()


## Left the session: shrink away during the host's linger time (the host no longer moves it meanwhile).
func _sim_despawned() -> void:
	_leaving = true
	_exit = create_tween()
	_exit.tween_property(self, "scale", Vector3.ONE * 0.01, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)


## A rollback brought it back within the linger time.
func _sim_revived() -> void:
	if not _leaving:
		return
	_leaving = false
	if _exit != null:
		_exit.kill()
	scale = Vector3.ONE


func _update_hud_state(dt: float) -> void:
	var slot := Unified.session.get_player_slot(player)
	if slot >= 0:
		_label.text = Unified.session.get_player_name(player)
		if slot != _slot:
			_color_slot(slot)
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


func _is_local() -> bool:
	return player == Unified.session.local_player
