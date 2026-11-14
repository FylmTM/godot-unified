extends MultiMeshInstance2D
## Bullets (`kind` bullet): a plain MultiMeshInstance2D (not SimBulkView2D), which declares `kind` and joins the
## `sim_bulk` group itself, so the host's plain-node path stays exercised. A small quad the host stretches along
## the bullet's velocity (scale per axis); the shader tints it with the owner's slot colour (custom.x = slot).

## Loaded in _ready, not preloaded: the play scene loads on a thread (src/godot_host/SPEC.md, Play scene).
const SHADER := "res://game/shaders/bullet.gdshader"

var kind := "bullet"  ## a String, as the host reads it from plain nodes


func _ready() -> void:
	add_to_group(&"sim_bulk")
	multimesh = BulkMesh.multimesh(BulkMesh.quad(Vector2(6, 6)))
	var m := BulkMesh.material(load(SHADER) as Shader)
	m.set_shader_parameter(&"palette", PackedColorArray(UiTheme.SLOT_COLORS))
	material = m
