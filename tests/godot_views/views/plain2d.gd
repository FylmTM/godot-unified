extends Node2D

@onready var marker: UnifiedView = $UnifiedView
var updates := 0
var last_position := Vector2.INF
var despawns := 0
var revivals := 0
var events: Array[Array] = []


# The host posed it before any other node's _process (its own runs at priority -1000).
func _process(_delta: float) -> void:
	updates += 1
	last_position = position


# Gone: the host stops posing it while it lingers, so an exit animation may move it.
func _sim_despawned() -> void:
	despawns += 1
	position = Vector2(999, 999)


func _sim_revived() -> void:
	revivals += 1


func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	events.append([event, state])
