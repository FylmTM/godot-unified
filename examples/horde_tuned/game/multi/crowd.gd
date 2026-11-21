extends MultiMeshInstance2D
## A MultiMesh view (an UnifiedMultiView child names its kind): a quad of `half` pixels each way drawn by `shader_path`.
## The host writes every instance's TRANSFORM_2D, colour and custom data in one buffer per frame.

@export var shader_path := ""
@export var half := Vector2(16, 16)


func _ready() -> void:
	multimesh = Quads.multimesh(Quads.quad(half))
	var shader_material := ShaderMaterial.new()
	shader_material.shader = load(shader_path) as Shader
	shader_material.set_shader_parameter(&"palette", PackedColorArray(Palette.SLOT_COLORS))
	shader_material.set_shader_parameter(&"kinds", PackedColorArray(Palette.ENEMY_COLORS))
	material = shader_material
