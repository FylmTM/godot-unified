class_name OrbitCamera
extends Camera3D
## A slow orbit around the origin, for a 3D menu backdrop.

@export var radius := 30.0
@export var height := 17.0
@export var speed := 0.05

var _angle := 0.6


func _process(delta: float) -> void:
	_angle += delta * speed
	position = Vector3(cos(_angle) * radius, height, sin(_angle) * radius)
	look_at(Vector3.ZERO, Vector3.UP)
