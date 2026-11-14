extends Node3D

var kind := &""
var entity := 0
var player := -1
var updates := 0
var last_position = null
var last_yaw := 0.0

func _sim_update(position: Vector3, yaw: float, alpha: float) -> void:
	updates += 1
	last_position = position
	last_yaw = yaw
