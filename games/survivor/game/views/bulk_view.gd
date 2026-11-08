class_name GameBulkView
extends MultiMeshInstance3D
## A MultiMesh bulk view (enemies by kind, projectiles, gems). The session finds it in group `sim_bulk` under its
## `view_root` and writes the instance buffer natively: 3D transform + custom data (r = hit flash, g = age s).

@export var kind: StringName


func _ready() -> void:
	add_to_group(&"sim_bulk")
	# The arena bounds: skip per-frame AABB work and never cull a populated MultiMesh by accident.
	custom_aabb = AABB(Vector3(-32, -1, -32), Vector3(64, 6, 64))
