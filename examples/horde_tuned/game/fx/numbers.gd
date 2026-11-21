class_name Numbers
extends MultiMeshInstance2D
## Damage numbers, the tuned way: a ring buffer of MultiMesh digits (seven-segment, drawn by the shader) that float up
## and fade on the shader's clock, so GDScript writes a number's digits once, when it is hit, and never per frame.

const MAX := 4096
const DIGIT := Vector2(5, 8)  # half size in px

var _next := 0
var _now := 0.0


func _ready() -> void:
	multimesh = Quads.multimesh(Quads.quad(DIGIT))
	multimesh.instance_count = MAX
	for i in MAX:
		multimesh.set_instance_custom_data(i, Color(0, -100.0, 0, 0))
	var shader_material := ShaderMaterial.new()
	shader_material.shader = load("res://game/fx/numbers.gdshader") as Shader
	material = shader_material


func _process(delta: float) -> void:
	_now += delta
	(material as ShaderMaterial).set_shader_parameter(&"now", _now)


## The number `value` at `at` (px) in `color`.
func show_number(at: Vector2, value: int, color: Color) -> void:
	var text := str(value)
	var drift := randf_range(-20.0, 20.0)
	var left := at.x - (text.length() - 1) * DIGIT.x * 1.2
	for i in text.length():
		var digit := text.unicode_at(i) - 48
		multimesh.set_instance_transform_2d(_next, Transform2D(0.0, Vector2(left + i * DIGIT.x * 2.4, at.y - 24.0)))
		multimesh.set_instance_color(_next, color)
		multimesh.set_instance_custom_data(_next, Color(digit, _now, drift, 0))
		_next = (_next + 1) % MAX
