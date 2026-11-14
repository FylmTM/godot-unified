class_name GameView
extends Node3D
## A base for 3D scene views in GDScript (`res://game/views/<kind>.tscn`). The session instantiates the scene under
## its `view_root`, sets `kind`, `entity` and `player` before adding it, then every frame sets `position` (and the
## root's rotation) and calls `_sim_update`; events for this entity arrive through `_sim_event`, including
## `despawned` (the view then lingers ~0.25 s for an exit animation before it is freed). A plain Node3D with the
## properties of the native `SimView` (src/godot_host/SPEC.md), so the scenes also load without the game library.

@export var kind: StringName
@export var entity := -1
## The player it shows (0..); -1 for an entity that isn't a player.
@export var player := -1


## Called every rendered frame with the interpolated sim position, facing and interpolation alpha.
func _sim_update(_position: Vector3, _yaw: float, _alpha: float) -> void:
	pass


## A sim event for this entity, in any state (as the session's `sim_event`: data has the event's fields plus
## `tick`, `state` ("predicted", "confirmed", "cancelled") and `first`), or `revived` / `despawned` (empty data).
func _sim_event(_event: StringName, _data: Dictionary) -> void:
	pass
