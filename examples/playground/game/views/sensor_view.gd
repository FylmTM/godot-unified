extends Node3D
## A sensor volume of the Sensors scene: a translucent box of its size, brighter while bodies are in it, and how many
## are in it and have entered it so far.

@onready var _volume: MeshInstance3D = %Volume
@onready var _count: Label3D = %Count

var half := Vector3.ONE:
	set(value):
		half = value
		_volume.scale = value * 2
var inside := 0:
	set(value):
		inside = value
		var material := _volume.material_override as StandardMaterial3D
		material.albedo_color.a = 0.35 if value > 0 else 0.18
		_show_count()
var visits := 0:
	set(value):
		visits = value
		_show_count()


func _show_count() -> void:
	_count.text = "%d in   %d entered" % [inside, visits]