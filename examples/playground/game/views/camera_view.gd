extends Node3D
## A player's flying camera (posed by the host: its position and look): a box with a lens in the player's colour, and
## the point their grab pulls to while they hold something. The local player's own is hidden (it is the viewpoint).

## View_Camera (simulation/extension): set by the host before _ready, and anew each time it changes.
var data: ViewCamera:
	set(value):
		data = value
		if is_node_ready():
			_show()

@onready var _body: MeshInstance3D = %Body
@onready var _grab_point: MeshInstance3D = %GrabPoint


func _ready() -> void:
	_show()


func _show() -> void:
	(_body.material_override as StandardMaterial3D).albedo_color = data.color
	_body.visible = not data.local
	_grab_point.visible = data.holding
	_grab_point.global_position = data.grab_at
