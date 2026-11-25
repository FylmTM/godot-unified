extends Node3D
## A player: posed at their feet, turned by their aim's yaw (a teammate's on the verified timeline: a few ticks late,
## never corrected); the head and the rifle tilt by the aim's pitch. Downed, the body lies on its side. The local
## player's own body only casts its shadow (the camera is inside it). A shot draws a tracer from the rifle's muzzle to
## where it struck: the local player's at once (EMITTED), a teammate's when their late body fires it (CONFIRMED).

const TRACER_S := 0.1
## The tracers' beam (a unit box, scaled along its length) and materials (one hit, one missed), shared by every player
## view: a shot makes a node, no mesh or material.
static var _beam: BoxMesh
static var _beam_hit: StandardMaterial3D
static var _beam_missed: StandardMaterial3D

## View_Player (simulation/extension): set by the host before _ready, and anew each time it changes.
var data: ViewPlayer:
	set(value):
		var recolored := data == null or value.color != data.color
		data = value
		if recolored and is_node_ready():
			_body_material.albedo_color = value.color

var _hurt := 0.0
## Whether the shadow-only body was set for the local player (-1: not set yet; else 0 or 1).
var _shadow_for_mine := -1

@onready var marker: UnifiedView = %UnifiedView
@onready var _body: Node3D = $Body
@onready var _head: Node3D = $Body/Head
@onready var _muzzle: Node3D = $Body/Head/Rifle/Muzzle
@onready var _revive_ring: MeshInstance3D = $ReviveRing
@onready var _body_material: StandardMaterial3D = ($Body/Torso as MeshInstance3D).material_override
@onready var _meshes: Array[MeshInstance3D] = [$Body/Torso, $Body/Head/Skull, $Body/Head/Visor, $Body/Head/Rifle/Barrel]


func _ready() -> void:
	_body_material.albedo_color = data.color


func _process(delta: float) -> void:
	var mine := marker.player == Unified.session.local_player
	if int(mine) != _shadow_for_mine:  # changes when the view's player becomes (or stops being) the local one
		_shadow_for_mine = int(mine)
		var shadow := GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if mine else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		for mesh: MeshInstance3D in _meshes:
			mesh.cast_shadow = shadow
	_head.rotation.x = -data.pitch * TAU  # the model faces +Z: a positive pitch looks up
	_body.rotation.z = lerpf(_body.rotation.z, PI / 2 if data.downed else 0.0, 1.0 - exp(-delta * 8.0))
	_body.position.y = lerpf(_body.position.y, 0.35 if data.downed else 0.0, 1.0 - exp(-delta * 8.0))
	_revive_ring.visible = data.downed and not mine
	_revive_ring.scale = Vector3.ONE * (0.4 + data.revive * 0.8)
	_hurt = move_toward(_hurt, 0.0, delta * 4.0)
	_body_material.emission_energy_multiplier = _hurt * 2.0


func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	var mine := marker.player == Unified.session.local_player
	if event is EventShot and (state == UnifiedSession.EVENT_EMITTED or (state == UnifiedSession.EVENT_CONFIRMED and not mine)):
		var shot := event as EventShot
		var from := _muzzle.global_position
		if mine:
			var rig := get_tree().get_first_node_in_group(&"rig")
			if rig != null:
				var rig_muzzle: Node3D = rig.get(&"muzzle")
				from = rig_muzzle.global_position
		_tracer(from, shot.to, shot.hit)
	elif event is EventPlayerHurt and state == (UnifiedSession.EVENT_EMITTED if mine else UnifiedSession.EVENT_CONFIRMED):
		_hurt = 1.0  # once: the local player's at once, a teammate's on their (verified) timeline


## A thin glowing beam from `from` to `to`, gone in TRACER_S.
func _tracer(from: Vector3, to: Vector3, hit: bool) -> void:
	var length := from.distance_to(to)
	if length < 0.05:
		return
	if _beam == null:
		_beam = BoxMesh.new()
		_beam.size = Vector3(0.04, 0.04, 1.0)
		_beam_hit = _beam_material(Color(1, 0.55, 0.35))
		_beam_missed = _beam_material(Color(1, 0.9, 0.6))
	var beam := MeshInstance3D.new()
	beam.mesh = _beam
	beam.material_override = _beam_hit if hit else _beam_missed
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(beam)
	beam.look_at_from_position((from + to) / 2, to, Vector3.UP if absf((to - from).normalized().y) < 0.99 else Vector3.RIGHT)
	beam.scale = Vector3(1, 1, length)
	var tween := beam.create_tween()
	tween.tween_property(beam, "transparency", 1.0, TRACER_S)
	tween.tween_callback(beam.queue_free)


static func _beam_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	return material
