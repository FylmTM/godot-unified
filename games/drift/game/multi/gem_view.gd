extends MultiMeshInstance2D
## Gems (the `gem` MultiMesh view). A diamond in pixels; the host spins it and squashes and stretches it in
## a pulse, and its colour (from extract) fades it out before it expires. The shader adds a glint (custom.x = age).

## Loaded in _ready, not preloaded: the play scene loads on a thread (game/ui/menu.gd).
const SHADER := "res://game/shaders/gem.gdshader"
const SIZE := Vector2(7, 10)  ## half width and half height, pixels


func _ready() -> void:
	var pts := PackedVector2Array([Vector2(SIZE.x, 0), Vector2(0, SIZE.y), Vector2(-SIZE.x, 0), Vector2(0, -SIZE.y)])
	multimesh = ViewMeshes.multimesh(ViewMeshes.fan(pts))
	material = ViewMeshes.material(load(SHADER) as Shader)
