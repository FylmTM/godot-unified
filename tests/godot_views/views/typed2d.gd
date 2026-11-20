extends Node2D

@onready var marker: UnifiedView = %UnifiedView
var updates := 0
var last_position := Vector2.INF
var last_rotation := 0.0
var events: Array[Array] = []  # [event, state]

# View_Typed2D (ext/ext.odin): set by the host before _ready, and anew each time its bytes change.
var data: ViewTyped2d:
	set(value):
		if data == null or value.hp != data.hp:
			hp_sets += 1
		if data == null or value.ticks != data.ticks:
			ticks_sets += 1
		data = value
		data_sets += 1
var data_sets := 0
var hp_sets := 0
var ticks_sets := 0
var data_at_ready: ViewTyped2d  # what _ready found: the host sets the data before it


func _ready() -> void:
	data_at_ready = data


# The host posed it before any other node's _process (its own runs at priority -1000).
func _process(_delta: float) -> void:
	updates += 1
	last_position = position
	last_rotation = rotation


func _sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	events.append([event, state])
