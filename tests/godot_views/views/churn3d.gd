extends Node3D
## The view bench's churn (ext/ext.odin's bench_frame): a view that comes and goes with a toy thing, its data shown on
## its body as a projectile's would be.

var data: ViewChurn3d:
	set(value):
		data = value
		if value != null and is_node_ready():
			_show()

@onready var body: MeshInstance3D = $Body


func _ready() -> void:
	_show()


func _show() -> void:
	body.rotation.y = data.serial * 0.1
