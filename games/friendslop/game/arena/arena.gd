class_name Arena
extends Node3D
## The play scene: the level (its meshes are the visuals; markers lend theirs to the sim's views), the views root
## handed to the session, the third-person camera and the HUD. Routes sim events to sounds and camera shake.

## The level's markers in the level file's order (Unified.level_markers): marker views look themselves up here.
var markers: Array[Node] = []

@onready var camera_rig: CameraRig = $CameraRig
@onready var _views: Node3D = $Views
@onready var _level: Node3D = $Level


func _ready() -> void:
	markers = Unified.level_markers(_level)
	Unified.session.view_root = _views
	Unified.session.sim_event.connect(_on_sim_event)


## The marker node for a marker view's key (its marker index), or null.
func marker(index: int) -> Node3D:
	return markers[index] as Node3D if index >= 0 and index < markers.size() else null


## Verified events only (predictions are the views' business).
func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state != UnifiedSession.EVENT_CONFIRMED:
		return
	if event is EventRunStarted:
		Sfx.play(&"start")
	elif event is EventRunFinished:
		Sfx.play(&"level")
	elif event is EventCheckpoint:
		Sfx.play(&"respawn")
	elif event is EventBellRung:
		Sfx.play(&"gem", 2.0, 0.6)
	elif event is EventPlateOn or event is EventSwitchOn:
		Sfx.play(&"click", 0.0, 0.7)
	elif event is EventPlateOff:
		Sfx.play(&"click", -4.0, 0.5)
	elif event is EventHit:
		var hit := event as EventHit
		if hit.position.distance_to(camera_rig.global_position) < 18.0:
			camera_rig.shake(0.25 if hit.bumper else 0.15)
