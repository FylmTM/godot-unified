class_name Sparks
extends MultiMeshInstance2D
## Particles: a ring buffer of MultiMesh instances whose flight the shader computes from their birth (origin,
## velocity, birth time, life: sparks.gdshader), so a spark costs GDScript one write when an event makes it and nothing
## per frame. A burst past the buffer's size overwrites the oldest.

const CAPACITY := 8192

## sparks.gdshader.
@export var shader: Shader

var _next := 0
var _now := 0.0


func _ready() -> void:
	multimesh = Quads.multimesh(Quads.quad(Vector2(1, 1)))
	multimesh.instance_count = CAPACITY
	var collapsed := Transform2D(0.0, Vector2.ZERO, 0.0, Vector2(1e9, 1e9))
	for i in CAPACITY:  # never born: the shader collapses them
		multimesh.set_instance_transform_2d(i, collapsed)
		multimesh.set_instance_custom_data(i, Color(0, 0, -100.0, 0.001))
	var shader_material := ShaderMaterial.new()
	shader_material.shader = shader
	material = shader_material


func _process(delta: float) -> void:
	_now += delta
	(material as ShaderMaterial).set_shader_parameter(&"now", _now)


## `count` sparks from `at` (px) in `color`, flying out at up to `speed` px/s, `size` px across, living up to `life` s.
func burst(at: Vector2, count: int, color: Color, speed: float, size: float, life: float) -> void:
	for i in count:
		var vel := Vector2.from_angle(randf() * TAU) * speed * (0.3 + 0.7 * randf()) + Vector2(0, -speed * 0.3)
		var radius := size * (0.6 + 0.4 * randf())
		multimesh.set_instance_transform_2d(_next, Transform2D(0.0, Vector2(radius, radius), 0.0, at))
		multimesh.set_instance_color(_next, color)
		multimesh.set_instance_custom_data(_next, Color(vel.x, vel.y, _now, life * (0.6 + 0.4 * randf())))
		_next = (_next + 1) % CAPACITY
