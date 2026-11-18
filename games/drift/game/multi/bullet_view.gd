extends MultiMeshInstance2D
## Bullets (the `bullet` MultiMesh view). A small quad the host stretches along
## the bullet's velocity (scale per axis); the shader tints it with the owner's slot colour (custom.x = the owner's
## slot, -1 once they have left).

## Loaded in _ready, not preloaded: the play scene loads on a thread (game/ui/menu.gd).
const SHADER := "res://game/shaders/bullet.gdshader"


func _ready() -> void:
	multimesh = ViewMeshes.multimesh(ViewMeshes.quad(Vector2(6, 6)))
	var m := ViewMeshes.material(load(SHADER) as Shader)
	m.set_shader_parameter(&"palette", PackedColorArray(UiTheme.PLAYER_COLORS))
	material = m
