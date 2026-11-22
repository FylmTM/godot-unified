class_name Numbers
extends MultiMeshInstance2D
## Damage numbers: a ring buffer of MultiMesh digits (seven-segment, drawn by numbers.gdshader) that rise and fade on
## the shader's clock, so a number costs GDScript one write per digit when its hit happens and nothing per frame. A
## number past the buffer's size overwrites the oldest digits.

const CAPACITY := 4096
const DIGIT_HALF := Vector2(5, 8)  # px
const RISE_START := 24.0  # px above the hit
const DRIFT := 20.0  # px/s sideways, at most

## numbers.gdshader.
@export var shader: Shader

var _next := 0
var _now := 0.0


func _ready() -> void:
	multimesh = Quads.multimesh(Quads.quad(DIGIT_HALF))
	multimesh.instance_count = CAPACITY
	for i in CAPACITY:  # never born: the shader collapses them
		multimesh.set_instance_custom_data(i, Color(0, -100.0, 0, 0))
	var shader_material := ShaderMaterial.new()
	shader_material.shader = shader
	material = shader_material


func _process(delta: float) -> void:
	_now += delta
	(material as ShaderMaterial).set_shader_parameter(&"now", _now)


## The number `value` centred over `at` (px) in `color`.
func show_number(at: Vector2, value: int, color: Color) -> void:
	var text := str(value)
	var drift := randf_range(-DRIFT, DRIFT)
	var left := at.x - (text.length() - 1) * DIGIT_HALF.x * 1.2
	for i in text.length():
		var digit := text.unicode_at(i) - 48  # "0"
		var place := Vector2(left + i * DIGIT_HALF.x * 2.4, at.y - RISE_START)
		multimesh.set_instance_transform_2d(_next, Transform2D(0.0, place))
		multimesh.set_instance_color(_next, color)
		multimesh.set_instance_custom_data(_next, Color(digit, _now, drift, 0))
		_next = (_next + 1) % CAPACITY
