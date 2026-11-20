extends Node3D
## A player's flying camera (posed by the host: its position and look): a box with a lens in the player's colour, and
## the point their grab pulls to while they hold something. The local player's own is hidden (it is the viewpoint).

@onready var _body: MeshInstance3D = %Body
@onready var _grab_point: MeshInstance3D = %GrabPoint

var color: Color:
	set(value):
		color = value
		(_body.material_override as StandardMaterial3D).albedo_color = value
var holding := false:
	set(value):
		holding = value
		_grab_point.visible = value
var driving := false
var local := false:
	set(value):
		local = value
		_body.visible = not value
var grab_at := Vector3.ZERO:
	set(value):
		grab_at = value
		_grab_point.global_position = value