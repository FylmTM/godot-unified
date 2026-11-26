extends Node3D

@onready var marker: UnifiedView = $UnifiedView
# View_Predicted3D (ext/ext.odin): set by the host before _ready, and anew each time it changes.
var data: ViewPredicted3d:
	set(value):
		data = value
		if int(value.trail[0]) != value.tick or int(value.trail[-1]) != value.tick + value.trail.size() - 1:
			torn += 1
var torn := 0  # data set whose trail isn't its tick's: not one sample's whole data
var frames: Array[Array] = []  # [data tick, the session's verified tick] each frame it shows with data


func _process(_delta: float) -> void:
	if visible and data != null:
		frames.append([data.tick, Unified.session.verified_tick])
