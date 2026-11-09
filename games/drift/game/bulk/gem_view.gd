extends SimBulkView2D
## Gems (`kind` gem): a typed bulk view. A diamond in pixels; the host spins it and squashes and stretches it in
## a pulse, and its colour (from extract) fades it out before it expires. The shader adds a glint (custom.x = age).

## Loaded in _ready, not preloaded: a preloaded shader leaks at exit once the menu has loaded the arena on a thread.
const SHADER := "res://game/shaders/gem.gdshader"
const SIZE := Vector2(7, 10)  ## half width and half height, pixels


func _ready() -> void:
	var pts := PackedVector2Array([Vector2(SIZE.x, 0), Vector2(0, SIZE.y), Vector2(-SIZE.x, 0), Vector2(0, -SIZE.y)])
	multimesh = BulkMesh.multimesh(BulkMesh.fan(pts))
	material = BulkMesh.material(load(SHADER) as Shader)
