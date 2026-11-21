extends Node3D
## One-shot effects from the session's events, at once (EMITTED: short enough that a cancelled one isn't undone): a
## blast's fireball and flash, an enemy hit's spark (brighter on the head), an enemy's death puff, a bolt hitting
## home. View-only: nothing here reads back into the sim.


func _ready() -> void:
	Unified.session.sim_event.connect(_on_sim_event)


func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state != UnifiedSession.EVENT_EMITTED:
		return
	if event is EventExplosion:
		var at := (event as EventExplosion).at
		var radius: float = Unified.constants.blast_radius
		_puff(at, Color(1, 0.55, 0.15), radius * 0.2, radius * 0.9, 0.45)
		_flash(at, Color(1, 0.6, 0.25), 8.0, radius * 3.0, 0.35)
	elif event is EventEnemyHit:
		var hit := event as EventEnemyHit
		_puff(hit.at, Color(1, 1, 0.5) if hit.headshot else Color(1, 0.75, 0.4), 0.05, 0.25 if hit.headshot else 0.15, 0.15)
	elif event is EventEnemyDied:
		_puff((event as EventEnemyDied).at + Vector3(0, 0.9, 0), Color(0.35, 0.33, 0.3), 0.3, 1.4, 0.7)
	elif event is EventPlayerDowned:
		_puff((event as EventPlayerDowned).at, Color(0.9, 0.2, 0.2), 0.2, 0.9, 0.5)


## A sphere at `at` that grows from `from` to `to` metres in radius and fades over `seconds`.
func _puff(at: Vector3, color: Color, from: float, to: float, seconds: float) -> void:
	var puff := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	sphere.material = material
	puff.mesh = sphere
	puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	puff.scale = Vector3.ONE * from
	add_child(puff)
	puff.global_position = at
	var tween := puff.create_tween().set_parallel()
	tween.tween_property(puff, "scale", Vector3.ONE * to, seconds).set_ease(Tween.EASE_OUT)
	tween.tween_property(material, "albedo_color:a", 0.0, seconds)
	tween.chain().tween_callback(puff.queue_free)


## A light at `at` fading from `energy` to nothing over `seconds`.
func _flash(at: Vector3, color: Color, energy: float, reach: float, seconds: float) -> void:
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = energy
	light.omni_range = reach
	add_child(light)
	light.global_position = at
	var tween := light.create_tween()
	tween.tween_property(light, "light_energy", 0.0, seconds)
	tween.tween_callback(light.queue_free)
