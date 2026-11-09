extends Camera2D
## The menu backdrop: a slow drift with the station on the right (the menu is on the left), the station decoration
## turning as it does in a match.

@export var centre := Vector2(-330, 20)
@export var radius := 40.0
@export var speed := 0.12
@export var station_spin := 0.25  ## rad/s, the sim's

var _angle := 0.4


func _process(delta: float) -> void:
	_angle += delta * speed
	position = centre + Vector2(cos(_angle), sin(_angle) * 0.6) * radius
	var station := get_node_or_null(^"../Station") as Node2D
	if station != null:
		station.rotation += station_spin * delta
