extends SimView2D

var updates := 0
var last_position = null
var last_rotation := 0.0
var events := []

func _sim_update(position: Vector2, rotation: float, alpha: float) -> void:
	updates += 1
	last_position = position
	last_rotation = rotation

func _sim_event(kind: StringName, data: Dictionary) -> void:
	events.append([kind, data])
