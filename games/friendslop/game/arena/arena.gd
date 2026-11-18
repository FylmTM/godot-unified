class_name Arena
extends Node3D
## The play scene: the level (its meshes are the visuals; markers lend theirs to the sim's views), the views root
## handed to the session, the third-person camera and the HUD. Routes sim events to sounds and camera shake.

## The level's markers in file order (LevelMarkers): marker views look themselves up here.
var markers: Array[Node] = []

@onready var camera_rig: CameraRig = $CameraRig
@onready var _views: Node3D = $Views
@onready var _level: Node3D = $Level


func _ready() -> void:
	markers = LevelMarkers.collect(_level)
	Game.session.view_root = _views
	Game.session.sim_event.connect(_on_sim_event)


## The marker node for a sim view's entity (marker index + 1), or null.
func marker(entity: int) -> Node3D:
	var i := entity - 1
	return markers[i] as Node3D if i >= 0 and i < markers.size() else null


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
			camera_rig.shake(0.25 if hit.speed > 7.0 else 0.15)
