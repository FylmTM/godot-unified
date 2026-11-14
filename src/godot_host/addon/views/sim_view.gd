class_name GameView
extends Node3D
## A base for 3D scene views in GDScript (`res://game/views/<kind>.tscn`). The session instantiates the scene under
## its `view_root`, sets `kind`, `entity` and `slot` before adding it, then every frame sets `position` (and the
## root's rotation) and calls `_sim_update`; events for this entity arrive through `_sim_event`, including
## `despawned` (the view then lingers ~0.25 s for an exit animation before it is freed). A plain Node3D with the
## properties of the native `SimView` (src/godot_host/SPEC.md), so the scenes also load without the game library.

@export var kind: StringName
@export var entity := -1
## The player slot 0..3; -1 for an entity that isn't a player.
@export var slot := -1


## Called every rendered frame with the interpolated sim position, facing and interpolation alpha.
func _sim_update(_position: Vector3, _yaw: float, _alpha: float) -> void:
	pass


## A sim event for this entity (kind as in the session's `sim_event`; data: tick, entity, slot, position, value,
## predicted, cancelled), or `despawned` (empty data).
func _sim_event(_kind: StringName, _data: Dictionary) -> void:
	pass
