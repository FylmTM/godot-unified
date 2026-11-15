extends MultiMeshInstance2D
## Rocks of one shape variant (the MultiMesh views rock_0..rock_3, their markers' kind set in the arena scene). The mesh is
## the sim's own shape (Unified.constants.rock_shapes[variant], the 8 corners at radius 1) as its convex hull, the same
## hull the sim's bodies have; the host scales it by each rock's radius in pixels (squashed for a moment on a
## hit). The shader shades by size (custom.x) and flashes on a hit (custom.y).

## Loaded in _ready, not preloaded: the play scene loads on a thread (games/shared/SPEC.md, Play scene).
const SHADER := "res://game/shaders/rock.gdshader"


func _ready() -> void:
	var variant := int(($UnifiedMultiView as UnifiedMultiView).kind.trim_prefix("rock_"))
	var shapes: Array = Unified.constants.rock_shapes
	var pts := PackedVector2Array()
	for p: Vector2 in shapes[variant]:
		pts.append(p)
	multimesh = BulkMesh.multimesh(BulkMesh.fan(pts))
	material = BulkMesh.material(load(SHADER) as Shader)
