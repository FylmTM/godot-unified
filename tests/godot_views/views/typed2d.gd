extends SimView2D

var updates := 0
var last_position = null
var last_rotation := 0.0
var events := []

# Typed2D_Data (ext/ext.odin), set by the host on spawn and when a field's bytes change.
var shown := false
var mode := 0
var hp := 0:
	set(v):
		hp = v
		hp_sets += 1
var hp_sets := 0
var ticks := 0:
	set(v):
		ticks = v
		ticks_sets += 1
var ticks_sets := 0
var charge := 0.0
var dir := Vector2.ZERO
var tint := Color.BLACK

func _sim_update(position: Vector2, rotation: float, alpha: float) -> void:
	updates += 1
	last_position = position
	last_rotation = rotation

func _sim_event(kind: StringName, data: Dictionary) -> void:
	events.append([kind, data])
