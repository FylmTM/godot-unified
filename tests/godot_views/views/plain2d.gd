extends Node2D

@onready var marker: UnifiedView = $UnifiedView
var updates := 0
var last_position := Vector2.INF


func _sim_update(position: Vector2, _rotation: float, _alpha: float) -> void:
	updates += 1
	last_position = position
