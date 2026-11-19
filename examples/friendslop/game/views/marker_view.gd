extends Node3D
## A sim object the level placed (item, platform, bell, plate, switch): the view takes over its level marker's
## visuals (key = marker index, Unified.level_markers order), so the level scene is the only place
## they are authored. The sim moves the view (its pose handed over: GLUE.view_policy, .Marker is script-posed); an
## item the local player holds is drawn at their hand instead, every rendered frame, so it stays with them and the
## camera; bells and plates also react to their events.

## The sim's Marker_View data: the key of the player holding this one-handle item (0: nobody).
var held_by := 0

var _sim_position := Vector3.ZERO
var _sim_rotation := Quaternion.IDENTITY
## 0: at the sim's pose, 1: at the local player's hand (blends either way on a grab, a drop or a throw).
var _follow := 0.0
## The hand's pose last drawn (blended out from after a drop).
var _hand := Vector3.ZERO
var _hand_rotation := Quaternion.IDENTITY
var _visuals: Array[Node3D] = []
var _scales: Array[Vector3] = []
var _pulse := 0.0

@onready var _view_marker: UnifiedView = %UnifiedView


func _ready() -> void:
	_place(0.0)  # _sim_pose came before _ready
	var index := _view_marker.key
	var level_marker := Unified.session.level_marker(index) as Node3D
	if level_marker == null:
		push_warning("marker view: no level marker %d" % index)
		return
	for c in level_marker.get_children():
		var visual := c as Node3D
		if visual != null and not (visual is Path3D):
			visual.reparent(self, false)
			_visuals.append(visual)
			_scales.append(visual.scale)


## The host hands the pose over instead of setting it, whenever it changes (the first time before _ready).
func _sim_pose(sim_position: Vector3, sim_rotation: Quaternion) -> void:
	_sim_position = sim_position
	_sim_rotation = sim_rotation


func _process(delta: float) -> void:
	_place(delta)
	_pulse = move_toward(_pulse, 0.0, delta * 3.0)
	var s := 1.0 + _pulse * 0.2
	for i in _visuals.size():
		_visuals[i].scale = _scales[i] * s


## At the sim's pose, or at the local holder's hold point as the sim computes it (hands.odin, hold_frame) from their
## view and the camera's look.
func _place(delta: float) -> void:
	var holder: Node3D = null
	if held_by != 0 and held_by == Unified.session.local_player:
		holder = Unified.session.get_player_view(EnumView.PLAYER, held_by) as Node3D
	if holder != null:
		var look: Vector3 = Unified.input.look
		var facing := holder.quaternion * Vector3.BACK  # the sim's facing turns +z
		var up := Unified.constants.hold_up + look.y * Unified.constants.hold_pitch
		_hand = holder.position + facing * Unified.constants.hold_dist + Vector3.UP * up
		_hand_rotation = holder.quaternion
	_follow = move_toward(_follow, 1.0 if holder != null else 0.0, delta * 8.0)
	position = _sim_position.lerp(_hand, _follow)
	quaternion = _sim_rotation.slerp(_hand_rotation, _follow)


## Effects play once, when the event is emitted (whether a prediction or the verified tick produced it). A marker
## gets the events about it with no player (an event about a player goes to the player's view: event_key): a bell
## rung, a plate pressed or let go, an item a pad launched, a lock opened, the trophy at the pedestal.
func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state != UnifiedSession.EVENT_EMITTED:
		return
	if event is EventBellRung or event is EventLaunched or event is EventPlateOn or event is EventSwitchOn:
		_pulse = 1.0
