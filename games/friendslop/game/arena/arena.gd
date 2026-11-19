class_name Arena
extends Node3D
## The play scene: the level root the session instances the active level under (the hub or the route; their meshes are
## the visuals, their markers lend theirs to the sim's views), the views root handed to the session, the third-person
## camera, the HUD and a loading view while a level's scene loads. Routes sim events to sounds and camera shake.

@onready var camera_rig: CameraRig = $CameraRig
@onready var _views: Node3D = $Views
@onready var _level: Node3D = $Level
@onready var _loading: CanvasLayer = $Loading


func _ready() -> void:
	Unified.session.view_root = _views
	Unified.session.level_root = _level
	Unified.session.level_changing.connect(func(_to: int) -> void: _loading.visible = true)
	Unified.session.level_changed.connect(func(_level_id: int) -> void: _loading.visible = false)
	Unified.session.sim_event.connect(_on_sim_event)


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
