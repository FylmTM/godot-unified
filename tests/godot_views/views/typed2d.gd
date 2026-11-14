extends Node2D

@onready var marker: UnifiedView = %UnifiedView
var updates := 0
var last_position := Vector2.INF
var last_rotation := 0.0
var events: Array[Array] = []  # [event, state]
var despawns := 0

# Typed2D_Data (ext/ext.odin), set by the host on spawn and when a field's bytes change.
var shown := false
var mode := &""
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


func _ready() -> void:
	marker.despawned.connect(func() -> void: despawns += 1)


func _sim_update(position: Vector2, rotation_now: float, _alpha: float) -> void:
	updates += 1
	last_position = position
	last_rotation = rotation_now


func _sim_event(event: UnifiedEvent, state: int) -> void:
	events.append([event, state])
