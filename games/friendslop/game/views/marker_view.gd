extends GameView
## A sim object the level placed (item, platform, bell, plate, switch): the view takes over its level marker's
## visuals (entity = marker index + 1, LevelMarkers order), so the level scene is the only place they are authored.
## The sim moves the view; bells and plates also react to their events.

var _visuals: Array[Node3D] = []
var _scales: Array[Vector3] = []
var _pulse := 0.0


func _ready() -> void:
	var arena := get_tree().current_scene
	var m: Node3D = arena.marker(entity) if arena != null and arena.has_method(&"marker") else null
	if m == null:
		push_warning("marker view: no level marker for entity %d" % entity)
		return
	for c in m.get_children():
		if c is Node3D and not (c is Path3D):
			c.reparent(self, false)
			_visuals.append(c)
			_scales.append(c.scale)


func _process(delta: float) -> void:
	_pulse = move_toward(_pulse, 0.0, delta * 3.0)
	var s := 1.0 + _pulse * 0.2
	for i in _visuals.size():
		_visuals[i].scale = _scales[i] * s


func _sim_event(event: StringName, data: Dictionary) -> void:
	if data.get("cancelled", false):
		return
	match event:
		&"bell_rung", &"launched", &"plate_on", &"switch_on":
			_pulse = 1.0
		&"thrown":
			Sfx.play(&"pop", -3.0, 1.1)
