extends Node3D

@onready var marker: UnifiedView = $UnifiedView
var updates := 0
var last_position := Vector3.INF
var last_yaw := 0.0
var data: ViewPlain3d  # View_Plain3D (ext/ext.odin): set before _ready, and anew each time it changes


# The host posed it before any other node's _process (its own runs at priority -1000).
func _process(_delta: float) -> void:
	updates += 1
	last_position = position
	last_yaw = rotation.y
