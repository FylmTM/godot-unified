extends Node3D
## A player: a wobbly capsule with googly eyes (player.tscn, greybox), sized to the sim's capsule and coloured as their
## slot. The sim gives the capsule's centre and the facing (the root's rotation); everything else here is view-only:
## lean into motion, squash on jumps and landings, tip over while stunned or held, arms out while holding, a name tag
## and a throw-charge ring.

## View_Player (simulation/extension): set by the host before _ready, and anew each time it changes. Stunned or held
## (`limp`): the body tips over; `charge`: the throw charge, 0..1.
var data: ViewPlayer

var _last_pos := Vector3.ZERO
var _vel := Vector3.ZERO
var _tip := 0.0
var _squash := 0.0
var _t := 0.0

## The view's marker: `player` is the key of the player it shows.
@onready var _view_marker: UnifiedView = %UnifiedView
## Everything that leans and squashes.
@onready var _body: Node3D = %Body
@onready var _capsule: MeshInstance3D = %Capsule
@onready var _feet: Node3D = %Feet
@onready var _eyes: Node3D = %Eyes
@onready var _arms: Node3D = %Arms
@onready var _tag: Label3D = %Tag
@onready var _ring: MeshInstance3D = %ChargeRing


func _ready() -> void:
	var radius := Unified.constants.player_radius
	var half := Unified.constants.player_half_height
	var feet := Unified.constants.feet
	var capsule := _capsule.mesh as CapsuleMesh
	capsule.radius = radius
	capsule.height = (half + radius) * 2.0
	_feet.position.y = -feet
	_eyes.position.z = radius
	_ring.position.y = 0.05 - feet
	_tag.position.y = half + radius + 0.45
	var c := UiTheme.player_color(Unified.session.get_player_slot(_view_marker.player))  # as in the session panel
	_capsule.material_override = Greybox.material(c)
	_paint(_feet, c.darkened(0.35))
	_paint(_arms, c.darkened(0.15))
	_tag.modulate = c.lightened(0.3)
	_last_pos = position


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	_t += delta
	_vel = _vel.lerp((position - _last_pos) / delta, 1.0 - exp(-delta * 10.0))
	_last_pos = position
	_tip = move_toward(_tip, 1.0 if data.limp else 0.0, delta * (6.0 if data.limp else 3.0))
	_squash = move_toward(_squash, 0.0, delta * 4.0)
	# Lean into the horizontal motion (in the root's frame, which turns with the facing).
	var local_v := global_transform.basis.inverse() * Vector3(_vel.x, 0, _vel.z)
	var lean := Vector3(clampf(local_v.z * 0.04, -0.3, 0.3), 0, clampf(-local_v.x * 0.04, -0.3, 0.3))
	_body.rotation = Vector3(lean.x + _tip * 1.35, 0, lean.z + sin(_t * 9.0) * 0.05 * _tip)
	var s := 1.0 + _squash * 0.25
	_body.scale = Vector3(s, 1.0 / s, s)
	_arms.visible = data.holding
	_ring.visible = data.charge > 0.01
	_ring.scale = Vector3.ONE * (0.6 + data.charge * 0.8)
	var player := _view_marker.player
	var player_name := Unified.session.get_player_name(player)
	if _tag.text != player_name:
		_tag.text = player_name
	_tag.visible = player != Unified.session.local_player


## Effects play once, when the event is first shown (predicted, or confirmed when nothing predicted it).
func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state != UnifiedSession.EVENT_EMITTED:
		return
	if event is EventJumped:
		_squash = -0.6
		Sfx.play(&"pop", -6.0, 1.4)
	elif event is EventLaunched:
		_squash = -1.0
		Sfx.play(&"start", -2.0, 1.6)
	elif event is EventGrabbed:
		Sfx.play(&"click", -2.0, 1.3)
	elif event is EventDropped:
		Sfx.play(&"click", -4.0, 0.8)
	elif event is EventThrown:
		Sfx.play(&"pop", 0.0, 0.8)
	elif event is EventHit:
		_squash = 0.8
		Sfx.play(&"hit")
		if _view_marker.player == Unified.session.local_player:
			Game.rumble(0.4, 0.6, 0.25)
	elif event is EventBrokeFree:
		Sfx.play(&"pop", 0.0, 1.8)
	elif event is EventFell:
		Sfx.play(&"die", -3.0)
	elif event is EventRespawned:
		_squash = 0.5
		Sfx.play(&"respawn", -4.0)


## Colours every mesh under `group` alike.
static func _paint(group: Node, color: Color) -> void:
	var material := Greybox.material(color)
	for part: MeshInstance3D in group.get_children():
		part.material_override = material
