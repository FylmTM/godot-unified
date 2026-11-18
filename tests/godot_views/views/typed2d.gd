extends Node2D

@onready var marker: UnifiedView = %UnifiedView
var updates := 0
var last_position := Vector2.INF
var last_rotation := 0.0
var events: Array[Array] = []  # [event, state]

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


# The host posed it before any other node's _process (its own runs at priority -1000).
func _process(_delta: float) -> void:
	updates += 1
	last_position = position
	last_rotation = rotation


func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	events.append([event, state])
