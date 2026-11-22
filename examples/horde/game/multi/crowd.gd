extends MultiMeshInstance2D
## A crowd: a MultiMesh view (its UnifiedMultiView child names the kind) of quads `half` pixels each way, drawn by
## `shader`. The host writes every instance's 2D transform, colour and custom data in one buffer per frame; what the
## custom data means is the shader's (simulation/extension/frame.odin, MultiView). The shaders' colour tables come
## from the heroes' colours and the arena's palette, so they have one home.

@export var shader: Shader
@export var half := Vector2(16, 16)


func _ready() -> void:
	multimesh = Quads.multimesh(Quads.quad(half))
	var shader_material := ShaderMaterial.new()
	shader_material.shader = shader
	shader_material.set_shader_parameter(&"slot_colors", PackedColorArray(UiTheme.PLAYER_COLORS))
	shader_material.set_shader_parameter(&"kind_colors", PackedColorArray(Palette.ENEMY_COLORS))
	material = shader_material
