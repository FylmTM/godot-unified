extends Node2D

var kind := &""
var entity := 0
var player := -1
var updates := 0
var last_position = null

func _sim_update(position: Vector2, rotation: float, alpha: float) -> void:
	updates += 1
	last_position = position
