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


func _exit_tree() -> void:
	if Game.session.view_root == _views:
		Game.session.view_root = null


## The marker node for a sim view's entity (marker index + 1), or null.
func marker(entity: int) -> Node3D:
	var i := entity - 1
	return markers[i] as Node3D if i >= 0 and i < markers.size() else null


func player_view(player: int) -> GameView:
	for v: GameView in _views.get_children():
		if v.kind == &"player" and v.player == player:
			return v
	return null


func local_player_view() -> GameView:
	return player_view(Game.local_player())


## Verified events only (predictions are the views' business).
func _on_sim_event(event: UnifiedEvent, state: int) -> void:
	if state != UnifiedSession.EVENT_CONFIRMED:
		return
	match event.kind:
		"run_started":
			Sfx.play(&"start")
		"run_finished":
			Sfx.play(&"level")
		"checkpoint":
			Sfx.play(&"respawn")
		"bell_rung":
			Sfx.play(&"gem", 2.0, 0.6)
		"plate_on", "switch_on":
			Sfx.play(&"click", 0.0, 0.7)
		"plate_off":
			Sfx.play(&"click", -4.0, 0.5)
		"hit":
			var hit := event as Hit
			if hit.position.distance_to(camera_rig.global_position) < 18.0:
				camera_rig.shake(0.25 if hit.speed > 7.0 else 0.15)
