class_name GameView
extends Node3D
## Base for scene views (`res://game/views/<kind>.tscn`). The session (native `UnifiedSession` or the mock)
## instantiates the scene under its `view_root`, sets `kind`, `entity` and `slot` before adding it, then every
## frame sets `position` (and the root's rotation) and calls `_sim_update`; events for this entity arrive through
## `_sim_event`, including `despawned` (the view then lingers ~0.25 s for an exit animation before it is freed).
## Plain Node3D on purpose: the scenes load without the game library (see spec/survivor-client.md).

@export var kind: StringName
@export var entity := -1
## Player slot 0..3; -1 for non-player entities.
@export var slot := -1


## Called every rendered frame with the interpolated sim position, facing and interpolation alpha.
func _sim_update(_position: Vector3, _yaw: float, _alpha: float) -> void:
	pass


## A sim event for this entity (kind as in the session's `sim_event`; data: tick, entity, slot, position, value,
## predicted, cancelled), or `despawned` (empty data).
func _sim_event(_kind: StringName, _data: Dictionary) -> void:
	pass
