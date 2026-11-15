extends Node3D
## A player: a wobbly capsule with googly eyes, built in code (greybox). The sim gives the capsule's centre and the
## facing (the root's rotation); everything else here is view-only: lean into motion, squash on jumps and landings,
## tip over while stunned or held, arms out while holding, a name tag and a throw-charge ring.

const COLORS: Array[Color] = [Color(1.0, 0.55, 0.3), Color(0.4, 0.75, 1.0), Color(1.0, 0.5, 0.8), Color(0.6, 0.9, 0.4)]

## The sim's Player_View data (simulation/extension), set by the host when it changes.
## Stunned or held: the body tips over.
var limp := false
var holding := false
## The throw charge, 0..1.
var charge := 0.0

## Everything that leans and squashes.
var _body: Node3D
var _arms: Node3D
var _tag: Label3D
var _ring: MeshInstance3D
var _last_pos := Vector3.ZERO
var _vel := Vector3.ZERO
var _tip := 0.0
var _squash := 0.0
var _t := 0.0

## The view's marker: `player` is the key of the player it shows.
@onready var _view_marker: UnifiedView = %UnifiedView


func _ready() -> void:
	var player := _view_marker.player
	var c := COLORS[clampi(Game.player_slot(player), 0, COLORS.size() - 1)]
	_body = Node3D.new()
	add_child(_body)
	var radius := Unified.constants.player_radius
	var half := Unified.constants.player_half_height
	var cap := CapsuleMesh.new()
	cap.radius = radius
	cap.height = (half + radius) * 2.0
	Greybox.set_mesh(_body, cap, c)
	var feet := Unified.constants.feet
	for side: int in [-1, 1]:
		var foot := Greybox.set_mesh(_body, Greybox.sphere(0.13), c.darkened(0.35),
			Vector3(0.15 * side, -feet + 0.12, 0.05), 0.0, "Foot%d" % (side + 1))
		foot.scale = Vector3(1, 0.7, 1.4)
		var eye := Greybox.set_mesh(_body, Greybox.sphere(0.11), Color.WHITE,
			Vector3(0.13 * side, 0.45, radius - 0.03), 0.0,
			"Eye%d" % (side + 1))
		var pupil := Greybox.set_mesh(eye, Greybox.sphere(0.05), Color(0.05, 0.05, 0.08), Vector3(0, 0, 0.08), 0.0,
			"Pupil")
		pupil.set_meta(&"wobble", side)
	_arms = Node3D.new()
	_body.add_child(_arms)
	for side: int in [-1, 1]:
		var arm := CapsuleMesh.new()
		arm.radius = 0.08
		arm.height = 0.6
		var a := Greybox.set_mesh(_arms, arm, c.darkened(0.15), Vector3(0.3 * side, 0.15, 0.3), 0.0,
			"Arm%d" % (side + 1))
		a.rotation.x = PI / 2.0
	_arms.visible = false
	_tag = Label3D.new()
	_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_tag.position = Vector3(0, half + radius + 0.45, 0)
	_tag.font_size = 40
	_tag.outline_size = 10
	_tag.modulate = c.lightened(0.3)
	_tag.no_depth_test = true
	add_child(_tag)
	var torus := TorusMesh.new()
	torus.inner_radius = 0.45
	torus.outer_radius = 0.55
	_ring = Greybox.set_mesh(self, torus, Color(1, 0.9, 0.3), Vector3(0, -feet + 0.05, 0), 1.5, "ChargeRing")
	_ring.visible = false
	_last_pos = position


func _sim_update(pos: Vector3, _yaw: float, _alpha: float) -> void:
	var dt := get_process_delta_time()
	if dt <= 0.0:
		return
	_t += dt
	_vel = _vel.lerp((pos - _last_pos) / dt, 1.0 - exp(-dt * 10.0))
	_last_pos = pos
	_tip = move_toward(_tip, 1.0 if limp else 0.0, dt * (6.0 if limp else 3.0))
	_squash = move_toward(_squash, 0.0, dt * 4.0)
	# Lean into the horizontal motion (in the root's frame, which turns with the facing).
	var local_v := global_transform.basis.inverse() * Vector3(_vel.x, 0, _vel.z)
	var lean := Vector3(clampf(local_v.z * 0.04, -0.3, 0.3), 0, clampf(-local_v.x * 0.04, -0.3, 0.3))
	_body.rotation = Vector3(lean.x + _tip * 1.35, 0, lean.z + sin(_t * 9.0) * 0.05 * _tip)
	var s := 1.0 + _squash * 0.25
	_body.scale = Vector3(s, 1.0 / s, s)
	_arms.visible = holding
	_ring.visible = charge > 0.01
	_ring.scale = Vector3.ONE * (0.6 + charge * 0.8)
	var player := _view_marker.player
	var info := Game.player_info(player)
	var player_name := Game.player_name(info) if not info.is_empty() else "P%d" % (Game.player_slot(player) + 1)
	if _tag.text != player_name:
		_tag.text = player_name
	_tag.visible = player != Game.local_player()


## Effects play once, when the event is first shown (predicted, or confirmed when nothing predicted it).
func _sim_event(event: UnifiedEvent, state: int) -> void:
	if state != UnifiedSession.EVENT_EMITTED:
		return
	var local := _view_marker.player == Game.local_player()
	match event.kind:
		"jumped":
			_squash = -0.6
			Sfx.play(&"pop", -6.0, 1.4)
		"launched":
			_squash = -1.0
			Sfx.play(&"start", -2.0, 1.6)
		"grabbed":
			Sfx.play(&"click", -2.0, 1.3)
		"dropped":
			Sfx.play(&"click", -4.0, 0.8)
		"thrown":
			Sfx.play(&"pop", 0.0, 0.8)
		"hit":
			_squash = 0.8
			Sfx.play(&"hit")
			if local:
				Game.rumble(0.4, 0.6, 0.25)
		"broke_free":
			Sfx.play(&"pop", 0.0, 1.8)
		"fell":
			Sfx.play(&"die", -3.0)
		"respawned":
			_squash = 0.5
			Sfx.play(&"respawn", -4.0)
