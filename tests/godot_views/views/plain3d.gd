extends Node3D

@onready var marker: UnifiedView = $UnifiedView
var updates := 0
var last_position := Vector3.INF
var last_yaw := 0.0


func _sim_update(position: Vector3, yaw: float, _alpha: float) -> void:
	updates += 1
	last_position = position
	last_yaw = yaw
