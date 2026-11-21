class_name Sparks
extends MultiMeshInstance2D
## Particles, the tuned way: a ring buffer of MultiMesh instances whose flight the shader computes from their spawn
## (origin, velocity, birth time, life), so GDScript touches a particle once, when it is born, and never per frame.

const MAX := 8192

var _next := 0
var _now := 0.0


func _ready() -> void:
	multimesh = Quads.multimesh(Quads.quad(Vector2(1, 1)))
	multimesh.instance_count = MAX
	var collapsed := Transform2D(0.0, Vector2.ZERO, 0.0, Vector2(1e9, 1e9))
	for i in MAX:
		multimesh.set_instance_transform_2d(i, collapsed)
		multimesh.set_instance_custom_data(i, Color(0, 0, -100.0, 0.001))
	var shader_material := ShaderMaterial.new()
	shader_material.shader = load("res://game/fx/sparks.gdshader") as Shader
	material = shader_material


func _process(delta: float) -> void:
	_now += delta
	(material as ShaderMaterial).set_shader_parameter(&"now", _now)


## `count` sparks from `at` (px) in `color`, up to `speed` px/s each way.
func burst(at: Vector2, count: int, color: Color, speed: float, size: float, life: float) -> void:
	for i in count:
		var angle := randf() * TAU
		var vel := Vector2.from_angle(angle) * speed * (0.3 + 0.7 * randf()) + Vector2(0, -speed * 0.3)
		var radius := size * (0.6 + 0.4 * randf())
		multimesh.set_instance_transform_2d(_next, Transform2D(0.0, Vector2(radius, radius), 0.0, at))
		multimesh.set_instance_color(_next, color)
		multimesh.set_instance_custom_data(_next, Color(vel.x, vel.y, _now, life * (0.6 + 0.4 * randf())))
		_next = (_next + 1) % MAX
