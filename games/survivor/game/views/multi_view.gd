extends MultiMeshInstance3D
## A MultiMesh view (enemies by kind, projectiles, gems: its UnifiedMultiView marker's `kind`, set in the arena
## scene). The host writes the instance buffer natively: 3D transform + custom data (r = hit flash, g = age s).


func _ready() -> void:
	# The arena bounds: skip per-frame AABB work and never cull a populated MultiMesh by accident.
	var h := Unified.constants.arena_half
	custom_aabb = AABB(Vector3(-h, -1, -h), Vector3(2 * h, 6, 2 * h))
