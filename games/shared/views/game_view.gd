class_name GameView
extends Node3D
## A base for the demo games' 3D scene views: the root of a view scene whose UnifiedView marker is a direct child
## named UnifiedView (src/godot/SPEC.md). `kind`, `entity` and `player` read the marker, which the host fills before
## the view enters the tree. The host calls `_sim_update` every frame and `_sim_event` for this entity's events; the
## marker's `despawned` (the view lingers ~0.25 s for an exit animation, then is freed) and `revived` signals call
## `_despawned()` and `_revived()`.

## The view's marker (null in a scene that has none).
var marker: UnifiedView:
	get:
		return get_node_or_null(^"UnifiedView") as UnifiedView
## The view kind (the game's View member, lowercased).
var kind: String:
	get:
		return marker.kind if marker != null else ""
## The id this entity's events carry (0: none).
var entity: int:
	get:
		return marker.entity if marker != null else 0
## The key of the player it shows (the same while they are in the session); 0 for an entity that isn't a player.
var player: int:
	get:
		return marker.player if marker != null else 0


func _notification(what: int) -> void:
	if what == NOTIFICATION_READY and marker != null:
		marker.despawned.connect(_despawned)
		marker.revived.connect(_revived)


## Called every rendered frame with the interpolated sim position, facing and interpolation alpha.
func _sim_update(_position: Vector3, _yaw: float, _alpha: float) -> void:
	pass


## A sim event for this entity in one of its states (UnifiedSession.EVENT_EMITTED, then EVENT_CONFIRMED or
## EVENT_CANCELLED).
func _sim_event(_event: UnifiedEvent, _state: int) -> void:
	pass


## The entity is gone from the sim: an exit animation (the view lingers ~0.25 s).
func _despawned() -> void:
	pass


## A rollback brought the entity back while the view lingered: undo the exit animation.
func _revived() -> void:
	pass
