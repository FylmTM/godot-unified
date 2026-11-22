extends Node3D
## The view bench's pooled churn: churn3d.gd's view, its kind pooled (its data null while in the pool, _sim_reused
## when taken again).

var data: ViewChurnPool3d:
	set(value):
		data = value
		if value != null and is_node_ready():
			_show()

@onready var body: MeshInstance3D = $Body


func _ready() -> void:
	_show()


func _sim_reused() -> void:
	body.visible = true


func _show() -> void:
	body.rotation.y = data.serial * 0.1
