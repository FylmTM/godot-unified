extends Camera3D
## Slow orbit around the arena for the menu backdrop.

@export var radius := 30.0
@export var height := 17.0
@export var speed := 0.05

var _angle := 0.6


func _process(delta: float) -> void:
	_angle += delta * speed
	position = Vector3(cos(_angle) * radius, height, sin(_angle) * radius)
	look_at(Vector3(0, 0, 0), Vector3.UP)
