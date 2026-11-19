class_name SurvivorFx
extends Node3D
## One-shot effects driven by sim events: death puffs, barrel explosions (light, fire, smoke, shock ring, screen
## shake), gem sparkles, level-up bursts, player death/respawn. Built from code-made CPUParticles3D, no assets.

## The enemies' colours by EnumEnemyKind value (grunt, runner, brute).
const ENEMY_COLORS: Array[Color] = [Color("4a80c7"), Color("2ec7cc"), Color("7347b8")]
const GEM_COLOR := Color("5dffb1")
const FIRE := Color("ffb347")
const GOLD := Color("ffd23f")

var camera: SurvivorCamera
var _cube: BoxMesh
var _ring_mesh: TorusMesh
var _shrink: Curve


func _ready() -> void:
	_cube = BoxMesh.new()
	_cube.size = Vector3.ONE * 0.18
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_cube.material = m
	_ring_mesh = TorusMesh.new()
	_ring_mesh.inner_radius = 0.92
	_ring_mesh.outer_radius = 1.0
	_ring_mesh.rings = 48
	_ring_mesh.ring_segments = 4
	_shrink = Curve.new()
	_shrink.add_point(Vector2(0, 1))
	_shrink.add_point(Vector2(1, 0))
	_warm_up()


## Draws each effect material once, under the floor, while the arena loads. A new material's shader compiles the
## first time it's drawn, which otherwise hitches the frame of the first kill or ring (on an exported game's first
## launch 0.4-0.7 s; 30 ms in dev runs). Lights need no warm-up (they don't change a material's shader). A new effect
## material needs a line here; `uni tool survivor tour --window --cold -- --frames` measures every first use.
func _warm_up() -> void:
	var at := Vector3(0, -4, 0)
	_burst(at, Color.WHITE, 1, 0.0, 0.1, 0.1, 0.0)  # vertex-coloured cubes: kills, gems, level-ups, deaths
	_ring(at, Color.WHITE, 0.5, 0.1)  # unshaded transparent: rings, the start shockwave, dash after-images


## Plays the effect of a sim event (the session's `sim_event`, an object of the event's class). Sounds and rumble
## for the local player's own pickups, level-ups and death.
func play(event: UnifiedEvent) -> void:
	if event is EventEnemyDied:
		var died := event as EventEnemyDied
		var color := ENEMY_COLORS[clampi(died.enemy_kind, 0, ENEMY_COLORS.size() - 1)]
		_burst(died.position + Vector3(0, 0.5, 0), color, 22 if died.enemy_kind == EnumEnemyKind.BRUTE else 10, 4.0,
			0.45, 0.8)
		Sfx.play(&"pop", -8.0, randf_range(0.9, 1.2))
	elif event is EventBarrelExploded:
		explosion((event as EventBarrelExploded).position, Unified.constants.blast_radius)
	elif event is EventGemCollected:
		var gem := event as EventGemCollected
		_burst(gem.position + Vector3(0, 0.5, 0), GEM_COLOR, 6, 2.5, 0.3, 0.5, -2.0)
		if _is_local(gem.player):
			Sfx.play(&"gem", -6.0, randf_range(0.95, 1.15))
	elif event is EventLevelUp:
		var level_up := event as EventLevelUp
		_ring(level_up.position + Vector3(0, 0.1, 0), GOLD, 3.5, 0.6)
		_burst(level_up.position + Vector3(0, 0.8, 0), GOLD, 26, 6.0, 0.8, 1.0, -4.0)
		if _is_local(level_up.player):
			Sfx.play(&"level")
	elif event is EventPlayerDied:
		var dead := event as EventPlayerDied
		var local := _is_local(dead.player)
		var c := UiTheme.player_color(Unified.session.get_player_slot(dead.player))
		_burst(dead.position + Vector3(0, 0.9, 0), c, 40, 7.0, 0.9, 1.2)
		_ring(dead.position + Vector3(0, 0.1, 0), c, 4.0, 0.5)
		_shake(0.45 if local else 0.2)
		Sfx.play(&"die")
		if local:
			Game.rumble(0.6, 1.0, 0.5)
	elif event is EventPlayerRespawned:
		var respawned := event as EventPlayerRespawned
		_ring(respawned.position + Vector3(0, 0.1, 0), UiTheme.CYAN, 2.5, 0.5)
		_burst(respawned.position + Vector3(0, 0.9, 0), UiTheme.CYAN, 18, 3.0, 0.6, 0.6, -3.0)
		Sfx.play(&"respawn", -4.0)
	elif event is EventMatchStarted:
		Sfx.play(&"start")
		Game.rumble(0.3, 0.5, 0.25)
	elif event is EventMatchOver:
		Sfx.play(&"over")


## The match starts: the start circle bursts outwards across the arena.
func shockwave(from_radius: float) -> void:
	var r := MeshInstance3D.new()
	r.mesh = _ring_mesh
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(UiTheme.CYAN * 1.3, 0.9)
	r.material_override = m
	r.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(r)
	r.position = Vector3(0, 0.08, 0)
	r.scale = Vector3(from_radius, 1.0, from_radius)
	var tw := r.create_tween().set_parallel()
	tw.tween_property(r, "scale", Vector3(34, 1, 34), 0.9).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUART)
	tw.tween_property(m, "albedo_color:a", 0.0, 0.9).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(r.queue_free)
	_shake(0.3)


## A barrel explosion at `pos` (also played by the tour to measure its first use).
func explosion(pos: Vector3, radius: float) -> void:
	var at := pos + Vector3(0, 0.6, 0)
	var light := OmniLight3D.new()
	light.light_color = Color(1, 0.6, 0.25)
	light.light_energy = 12.0
	light.omni_range = radius * 2.0
	add_child(light)
	light.position = at + Vector3(0, 1, 0)
	var tw := light.create_tween()
	tw.tween_property(light, "light_energy", 0.0, 0.45).set_ease(Tween.EASE_OUT)
	tw.tween_callback(light.queue_free)
	_burst(at, FIRE, 46, radius * 2.2, 0.55, 1.6, 2.0)
	_burst(at, Color(1, 0.95, 0.75), 16, radius * 3.0, 0.25, 0.9)
	_burst(at, Color(0.3, 0.32, 0.38, 0.8), 24, 2.5, 1.4, 2.2, 1.5)
	_ring(pos + Vector3(0, 0.15, 0), FIRE, radius, 0.4)
	_shake(0.55)
	Sfx.play(&"boom")
	Game.rumble(0.4, 0.8, 0.3)


## A one-shot cube spray; frees itself after its lifetime.
func _burst(pos: Vector3, color: Color, amount: int, speed: float, life: float, size: float, gravity_y := -9.0) -> void:
	var p := CPUParticles3D.new()
	p.mesh = _cube
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = amount
	p.lifetime = life
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = speed * 0.4
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, gravity_y, 0)
	p.damping_min = 1.0
	p.damping_max = 3.0
	p.scale_amount_min = size * 0.6
	p.scale_amount_max = size * 1.2
	p.scale_amount_curve = _shrink
	p.angular_velocity_min = -360.0
	p.angular_velocity_max = 360.0
	p.color = color
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.position = pos  # before entering the tree: a CPUParticles3D starts emitting where it enters
	add_child(p)
	p.emitting = true
	p.finished.connect(p.queue_free)


## An expanding, fading ring on the floor.
func _ring(pos: Vector3, color: Color, radius: float, time: float) -> void:
	var r := MeshInstance3D.new()
	r.mesh = _ring_mesh
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(color * 1.8, 1.0)
	r.material_override = m
	r.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(r)
	r.position = pos
	r.scale = Vector3(0.2, 0.2, 0.2)
	var tw := r.create_tween().set_parallel()
	tw.tween_property(r, "scale", Vector3(radius, 1.0, radius), time) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(m, "albedo_color:a", 0.0, time)
	tw.chain().tween_callback(r.queue_free)


## Whether `player` (a key, 0: none) is the local player.
func _is_local(player: int) -> bool:
	return player != 0 and player == Unified.session.local_player


func _shake(amount: float) -> void:
	if camera != null:
		camera.add_trauma(amount)
