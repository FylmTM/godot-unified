class_name SurvivorFx
extends Node3D
## One-shot effects driven by sim events: death puffs, barrel explosions (light, fire, smoke, shock ring, screen
## shake), gem sparkles, level-up bursts, player death/respawn. No assets: the cube sprays are one Cubes node per
## kind (a ring buffer the shader flies, so a burst makes no node), the rings code-made meshes.

## The cube sprays, one Cubes node each: what falls alike and lives alike.
enum Spray { DEATH, GEM, LEVEL_UP, PLAYER, RESPAWN, FIRE, FLASH, SMOKE }

## The enemies' colours by EnumEnemyKind value (grunt, runner, brute).
const ENEMY_COLORS: Array[Color] = [Color("4a80c7"), Color("2ec7cc"), Color("7347b8")]
const GEM_COLOR := Color("5dffb1")
const FIRE := Color("ffb347")
const GOLD := Color("ffd23f")

var camera: SurvivorCamera
var _ring_mesh: TorusMesh
## By Spray value.
var _sprays: Array[Cubes] = []
## The cubes' material (cubes.gdshader), shared by every spray; its clock is `_now`.
var _cubes: ShaderMaterial
var _now := 0.0


func _ready() -> void:
	_ring_mesh = TorusMesh.new()
	_ring_mesh.inner_radius = 0.92
	_ring_mesh.outer_radius = 1.0
	_ring_mesh.rings = 48
	_ring_mesh.ring_segments = 4
	_cubes = ShaderMaterial.new()
	_cubes.shader = load("res://game/fx/cubes.gdshader")
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE * 0.18
	# Per spray (Spray order): the cubes it may have at once, its gravity (m/s², up positive) and its cubes' life (s).
	for spray: Array in [[4096, -9.0, 0.45], [1024, -2.0, 0.3], [512, -4.0, 0.8], [256, -9.0, 0.9], [256, -3.0, 0.6],
			[1024, 2.0, 0.55], [512, -9.0, 0.25], [1024, 1.5, 1.4]]:
		var cubes := Cubes.new()
		var capacity: int = spray[0]
		var gravity: float = spray[1]
		var life: float = spray[2]
		cubes.setup(capacity, cube, _cubes, gravity, life)
		add_child(cubes)
		_sprays.append(cubes)
	_warm_up()


func _process(delta: float) -> void:
	_now += delta
	_cubes.set_shader_parameter(&"now", _now)


## Draws each effect material once, under the floor, while the arena loads. A new material's shader compiles the
## first time it's drawn, which otherwise hitches the frame of the first kill or ring (on an exported game's first
## launch 0.4-0.7 s; 30 ms in dev runs). Lights need no warm-up (they don't change a material's shader). A new effect
## material needs a line here; `uni tool survivor tour --window --cold -- --frames` measures every first use.
func _warm_up() -> void:
	var at := Vector3(0, -4, 0)
	_burst(Spray.FLASH, at, Color.WHITE, 1, 0.0, 0.1)  # the cubes (every spray shares their material)
	_ring(at, Color.WHITE, 0.5, 0.1)  # unshaded transparent: rings, the start shockwave, dash after-images


## Plays the effect of a sim event (the session's `sim_event`, an object of the event's class). Sounds and rumble
## for the local player's own pickups, level-ups and death.
func play(event: UnifiedEvent) -> void:
	if event is EventEnemyDied:
		var died := event as EventEnemyDied
		var color := ENEMY_COLORS[clampi(died.enemy_kind, 0, ENEMY_COLORS.size() - 1)]
		_burst(Spray.DEATH, died.position + Vector3(0, 0.5, 0), color, 22 if died.enemy_kind == EnumEnemyKind.BRUTE else 10,
			4.0, 0.8)
		Sfx.play(&"pop", -8.0, randf_range(0.9, 1.2))
	elif event is EventBarrelExploded:
		explosion((event as EventBarrelExploded).position, Unified.constants.blast_radius)
	elif event is EventGemCollected:
		var gem := event as EventGemCollected
		_burst(Spray.GEM, gem.position + Vector3(0, 0.5, 0), GEM_COLOR, 6, 2.5, 0.5)
		if _is_local(gem.player):
			Sfx.play(&"gem", -6.0, randf_range(0.95, 1.15))
	elif event is EventLevelUp:
		var level_up := event as EventLevelUp
		_ring(level_up.position + Vector3(0, 0.1, 0), GOLD, 3.5, 0.6)
		_burst(Spray.LEVEL_UP, level_up.position + Vector3(0, 0.8, 0), GOLD, 26, 6.0, 1.0)
		if _is_local(level_up.player):
			Sfx.play(&"level")
	elif event is EventPlayerDied:
		var dead := event as EventPlayerDied
		var local := _is_local(dead.player)
		var c := UiTheme.player_color(Unified.session.get_player_slot(dead.player))
		_burst(Spray.PLAYER, dead.position + Vector3(0, 0.9, 0), c, 40, 7.0, 1.2)
		_ring(dead.position + Vector3(0, 0.1, 0), c, 4.0, 0.5)
		_shake(0.45 if local else 0.2)
		Sfx.play(&"die")
		if local:
			Game.rumble(0.6, 1.0, 0.5)
	elif event is EventPlayerRespawned:
		var respawned := event as EventPlayerRespawned
		_ring(respawned.position + Vector3(0, 0.1, 0), UiTheme.CYAN, 2.5, 0.5)
		_burst(Spray.RESPAWN, respawned.position + Vector3(0, 0.9, 0), UiTheme.CYAN, 18, 3.0, 0.6)
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
	_burst(Spray.FIRE, at, FIRE, 46, radius * 2.2, 1.6)
	_burst(Spray.FLASH, at, Color(1, 0.95, 0.75), 16, radius * 3.0, 0.9)
	_burst(Spray.SMOKE, at, Color(0.3, 0.32, 0.38, 0.8), 24, 2.5, 2.2)
	_ring(pos + Vector3(0, 0.15, 0), FIRE, radius, 0.4)
	_shake(0.55)
	Sfx.play(&"boom")
	Game.rumble(0.4, 0.8, 0.3)


## A one-shot spray of `amount` cubes from `pos`, flying every way at up to `speed` m/s, `size` × a cube across.
func _burst(spray: Spray, pos: Vector3, color: Color, amount: int, speed: float, size: float) -> void:
	_sprays[spray].burst(pos, color, amount, speed, size, _now)


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
