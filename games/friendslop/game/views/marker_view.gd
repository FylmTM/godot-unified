extends Node3D
## A sim object the level placed (item, platform, bell, plate, switch): the view takes over its level marker's
## visuals (key = marker index, entity = marker index + 1, LevelMarkers order), so the level scene is the only place
## they are authored. The sim moves the view; bells and plates also react to their events.

var _visuals: Array[Node3D] = []
var _scales: Array[Vector3] = []
var _pulse := 0.0

@onready var _view_marker: UnifiedView = %UnifiedView


func _ready() -> void:
	var entity := _view_marker.entity
	var arena := get_tree().current_scene as Arena
	var m: Node3D = arena.marker(entity) if arena != null else null
	if m == null:
		push_warning("marker view: no level marker for entity %d" % entity)
		return
	for c in m.get_children():
		var visual := c as Node3D
		if visual != null and not (visual is Path3D):
			visual.reparent(self, false)
			_visuals.append(visual)
			_scales.append(visual.scale)


func _process(delta: float) -> void:
	_pulse = move_toward(_pulse, 0.0, delta * 3.0)
	var s := 1.0 + _pulse * 0.2
	for i in _visuals.size():
		_visuals[i].scale = _scales[i] * s


## Effects play once, when the event is emitted (whether a prediction or the verified tick produced it).
func _sim_event(event: UnifiedEvent, state: int) -> void:
	if state != UnifiedSession.EVENT_EMITTED:
		return
	match event.kind:
		"bell_rung", "launched", "plate_on", "switch_on":
			_pulse = 1.0
		"thrown":
			Sfx.play(&"pop", -3.0, 1.1)
