extends Node3D
## A sensor volume of the Sensors scene: a translucent box of its size, brighter while bodies are in it, and how many
## are in it and have entered it so far.

## View_Sensor (simulation/extension): set by the host before _ready, and anew each time it changes.
var data: ViewSensor:
	set(value):
		data = value
		if is_node_ready():
			_show()

@onready var _volume: MeshInstance3D = %Volume
@onready var _count: Label3D = %Count


func _ready() -> void:
	_show()


func _show() -> void:
	_volume.scale = data.half * 2
	var material := _volume.material_override as StandardMaterial3D
	material.albedo_color.a = 0.35 if data.inside > 0 else 0.18
	_count.text = "%d in   %d entered" % [data.inside, data.visits]
