extends Node2D
# A pooled kind that appears on verified (ext/ext.odin's GLUE.view_policy): what happens to each instance, as pool2d.gd.

## In order: {what (ready, reused, despawned, cancelled), id, key, serial}.
static var log: Array[Dictionary] = []

var data: ViewPoolLate2d

@onready var marker: UnifiedView = $UnifiedView


func _ready() -> void:
	_note("ready")


func _sim_reused() -> void:
	_note("reused")


func _sim_despawned() -> void:
	_note("despawned")


func _sim_cancelled() -> void:
	_note("cancelled")


func _note(what: String) -> void:
	log.append({what = what, id = get_instance_id(), key = marker.key, serial = data.serial if data else -1})
