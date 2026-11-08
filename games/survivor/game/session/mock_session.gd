class_name MockSession
extends Node
## A GDScript stand-in for the native `UnifiedSession`, with the same API, signals and view driving, backed by a
## tiny fake sim. It lets every flow (menu, connecting, lobby, match, level-up, game over) run without the game
## library: headless UI tests, screenshots, fresh checkouts. It is NOT the game: no determinism, no netcode, rough
## numbers. "Online" is faked: hosting gets a code and a bot friend joins after a few seconds.
##
## Test hooks for the mock only: join code "ZZZZZZ" fails ("lobby not found"), `debug_*` methods jump phases.

signal status_changed(status: String, detail: String)
signal lobby_code(code: String)
signal sim_event(kind: StringName, tick: int, entity: int, position: Vector3, value: float)

const TICK_HZ := 64
const DT := 1.0 / TICK_HZ
const MAX_STEPS_PER_FRAME := 8
const ARENA_HALF := 30.0
const CIRCLE_RADIUS := 6.0
const PLAYER_RADIUS := 0.45
const PLAYER_SPEED := 6.0
const HP_MAX := 100.0
const DASH_TIME := 0.125
const DASH_COOLDOWN := 1.4
const RESPAWN_TIME := 3.0
const FIRE_RANGE := 14.0
const PROJECTILE_SPEED := 16.0
const PROJECTILE_LIFE := 1.0

const MAX_ENEMIES := 400
const LINGER := 0.25  # seconds a despawned scene view stays (the native host's LINGER_S)
const ENEMY_CAPACITY := 512  # per bulk kind; matches the MultiMesh instance_count in arena.tscn
const PILLAR_RING := 14.0
const START := [Vector3(2, 0, 2), Vector3(-2, 0, 2), Vector3(2, 0, -2), Vector3(-2, 0, -2)]
const BOT_NAMES := ["Host (bot)", "Friend (bot)", "Bot 3", "Bot 4"]
## kind: [hp, speed, radius, damage, xp]
const ENEMY_KINDS := {
	&"grunt": [10.0, 2.0, 0.4, 5.0, 1],
	&"runner": [6.0, 3.2, 0.35, 3.0, 1],
	&"brute": [40.0, 1.2, 0.7, 12.0, 5],
}
const BULK_KINDS: Array[StringName] = [&"grunt", &"runner", &"brute", &"projectile", &"gem"]

## Seconds the "over" phase lasts before the fake sim returns to the lobby (the UI walk shortens it).
var over_seconds := 6.0
## Seconds after hosting until the bot friend joins.
var bot_join_seconds := 3.0
## Parent for spawned views; set by the arena on load, null when leaving (contract extension, see the spec).
## Microseconds the last _process took (fake sim ticks + view/bulk updates), for measurements.
var cost_us := 0
var view_root: Node3D:
	set = _set_view_root


class Player:
	var slot := 0
	var present := false
	var bot := false
	var name := ""
	var alive := true
	var pos := Vector3.ZERO
	var prev := Vector3.ZERO
	var yaw := 0.0
	var hp := HP_MAX
	var xp := 0
	var level := 1
	var pending := 0
	var respawn := 0.0
	var dash_t := 0.0
	var dash_cd := 0.0
	var fire_cd := 0.0
	var fire_interval := 0.33
	var damage_bonus := 0.0
	var speed_bonus := 0.0
	var wander := Vector3.ZERO
	var wander_t := 0.0


class Enemy:
	var kind: StringName
	var pos := Vector3.ZERO
	var prev := Vector3.ZERO
	var vel := Vector3.ZERO
	var hp := 0.0
	var speed := 0.0
	var radius := 0.0
	var damage := 0.0
	var xp := 1
	var cooldown := 0.0
	var flash := 0.0
	var age := DT  # > 0: the bulk shaders read age 0 as "no custom data"


class Shot:
	var pos := Vector3.ZERO
	var prev := Vector3.ZERO
	var vel := Vector3.ZERO
	var life := PROJECTILE_LIFE
	var damage := 5.0


class Gem:
	var pos := Vector3.ZERO
	var xp := 1
	var age := DT


class Item:
	var entity := 0
	var kind: StringName
	var home := Vector3.ZERO
	var pos := Vector3.ZERO
	var prev := Vector3.ZERO
	var vel := Vector3.ZERO
	var hp := 30.0
	var alive := true
	var respawn := 0.0

var _status := "idle"
var _running := false
var _tick := 0
var _acc := 0.0
var _phase := "lobby"
var _match_start_tick := 0
var _over_t := 0.0
var _over_time_s := 0.0
var _spawn_t := 0.0
var _code := ""
var _local_slot := 0
var _local_name := "Player"
var _players: Array[Player] = []
var _enemies: Array[Enemy] = []
var _shots: Array[Shot] = []
var _gems: Array[Gem] = []
var _items: Array[Item] = []
var _pillars: Array[Vector3] = []
var _rng := RandomNumberGenerator.new()
var _latched_dash := false  # input edges latched per frame, consumed by the next tick
var _latched_choice := 0
var _timers: Array = []  # [seconds_left, Callable]: fake network delays
var _views := {}  # entity -> Node3D
var _view_scenes := {}  # kind -> PackedScene
var _bulk := {}  # kind -> MultiMeshInstance3D
var _bulk_buf := {}  # kind -> PackedFloat32Array


func _init() -> void:
	for i in 4:
		var p := Player.new()
		p.slot = i
		_players.append(p)
	for k in 8:
		var a := k * PI / 4.0
		_pillars.append(Vector3(PILLAR_RING * cos(a), 0, PILLAR_RING * sin(a)))
	for kind in BULK_KINDS:
		var buf := PackedFloat32Array()
		buf.resize(_capacity(kind) * 16)
		_bulk_buf[kind] = buf


# --- Contract API -------------------------------------------------------------------------------


func start_single() -> void:
	_reset_world(0)
	_set_status("connecting", "Starting")
	_set_status("connected", "Single player")
	_running = true


func host_online() -> void:
	_reset_world(0)
	_set_status("connecting", "Creating lobby")
	_after(0.5, func() -> void:
		_code = _make_code()
		lobby_code.emit(_code)
		_set_status("connected", "Hosting lobby " + _code)
		_running = true
		_after(bot_join_seconds, _bot_join.bind(1)))


func join_online(code: String) -> void:
	var c := code.strip_edges().to_upper()
	_set_status("connecting", "Joining lobby " + c)
	if c.length() != 6 or not _is_alnum(c):
		_after(0.3, _fail.bind("Lobby codes are 6 letters or digits."))
	elif c == "ZZZZZZ":
		_after(0.8, _fail.bind("Lobby %s was not found. Check the code and try again." % c))
	else:
		_after(0.8, _join_as_guest.bind(c))


func join_direct(address: String) -> void:
	var a := address.strip_edges()
	_set_status("connecting", "Connecting to " + a)
	var colon := a.rfind(":")
	if colon <= 0 or not a.substr(colon + 1).is_valid_int():
		_after(0.3, _fail.bind("Expected host:port, for example 192.168.1.20:7777."))
	else:
		_after(0.5, _join_as_guest.bind(""))


func leave() -> void:
	_running = false
	_timers.clear()
	_clear_views()
	_reset_world(0)
	_set_status("idle", "")


func choose_levelup(option: int) -> void:
	_apply_levelup(_players[_local_slot], option)


func set_player_name(player_name: String) -> void:
	_local_name = player_name


func hud() -> Dictionary:
	var players := []
	for p in _players:
		players.append(
			{
				"slot": p.slot,
				"present": p.present,
				"alive": p.alive,
				"hp": p.hp,
				"hp_max": HP_MAX,
				"xp": p.xp,
				"xp_next": _xp_next(p.level),
				"level": p.level,
				"pending_levelups": p.pending,
				"respawn_s": p.respawn,
				"name": p.name,
			}
		)
	var time_s := 0.0
	if _phase != "lobby":
		time_s = (_tick - _match_start_tick) * DT if _phase == "match" else _over_time_s
	return {
		"phase": _phase,
		"tick": _tick,
		"time_s": time_s,
		"wave": _wave(),
		"enemies_alive": _enemies.size(),
		"circle_radius": CIRCLE_RADIUS,
		"local_slot": _local_slot,
		"players": players,
	}


# --- Mock-only test hooks -----------------------------------------------------------------------


func debug_start_match() -> void:
	if _running and _phase == "lobby":
		_start_match()


func debug_end_match() -> void:
	if _running and _phase == "match":
		_end_match()


func debug_grant_levelup() -> void:
	var p := _players[_local_slot]
	p.xp = _xp_next(p.level)
	_check_level(p)


## Blows up the barrel nearest to the local player (effects screenshots).
func debug_explode_nearest_barrel() -> void:
	var best: Item = null
	for it in _items:
		if it.alive and it.kind == &"barrel" and (best == null or it.pos.distance_to(_players[_local_slot].pos) < best.pos.distance_to(_players[_local_slot].pos)):
			best = it
	if best != null:
		_explode(best)


func debug_spawn(count: int, radius := 27.0) -> void:
	for i in count:
		_spawn_enemy(radius)


# --- Flow ---------------------------------------------------------------------------------------


func _set_status(status: String, detail: String) -> void:
	_status = status
	status_changed.emit(status, detail)


func _fail(reason: String) -> void:
	_running = false
	_set_status("failed", reason)


func _join_as_guest(code: String) -> void:
	_reset_world(1)
	_players[0].present = true
	_players[0].bot = true
	_players[0].name = BOT_NAMES[0]
	if code != "":
		_code = code
		lobby_code.emit(code)
	_set_status("connected", "Joined")
	_running = true


func _bot_join(slot: int) -> void:
	if not _running or _players[slot].present:
		return
	var p := _players[slot]
	_reset_player(p)
	p.present = true
	p.bot = true
	p.name = BOT_NAMES[slot]
	_emit(&"player_joined", slot, p.pos, 0.0)
	_spawn_view(&"player", slot, slot)


func _after(seconds: float, fn: Callable) -> void:
	_timers.append([seconds, fn])


func _reset_world(local_slot: int) -> void:
	_rng.seed = 12345
	_tick = 0
	_acc = 0.0
	_phase = "lobby"
	_code = ""
	_local_slot = local_slot
	_enemies.clear()
	_shots.clear()
	_gems.clear()
	for p in _players:
		_reset_player(p)
		p.present = p.slot == local_slot
		p.bot = false
		p.name = _local_name if p.present else ""
	_items.clear()
	for i in 40:
		var it := Item.new()
		it.entity = 100 + i
		it.kind = &"barrel" if i % 5 == 2 else &"crate"
		it.home = Vector3((i % 8) * 4 - 14, 0, (i / 8) * 4 - 8)
		# Keep the start circle clear: push the middle items outwards.
		if it.home.length() < CIRCLE_RADIUS + 1.5:
			it.home += it.home.normalized() * 3.0 if it.home.length() > 0.1 else Vector3(6, 0, 0)
		it.pos = it.home
		it.prev = it.home
		_items.append(it)
	_respawn_all_views()


func _reset_player(p: Player) -> void:
	p.alive = true
	p.pos = START[p.slot]
	p.prev = p.pos
	p.hp = HP_MAX
	p.xp = 0
	p.level = 1
	p.pending = 0
	p.respawn = 0.0
	p.dash_t = 0.0
	p.dash_cd = 0.0
	p.fire_cd = 0.0
	p.fire_interval = 0.33
	p.damage_bonus = 0.0
	p.speed_bonus = 0.0


func _start_match() -> void:
	_phase = "match"
	_match_start_tick = _tick
	_spawn_t = 0.0
	_emit(&"match_started", -1, Vector3.ZERO, 0.0)


func _end_match() -> void:
	_phase = "over"
	_over_t = over_seconds
	_over_time_s = (_tick - _match_start_tick) * DT
	_emit(&"match_over", -1, Vector3.ZERO, _over_time_s)


func _back_to_lobby() -> void:
	var local := _local_slot
	var present := []
	for p in _players:
		present.append([p.present, p.bot, p.name])
	_reset_world(local)
	for p in _players:
		p.present = present[p.slot][0]
		p.bot = present[p.slot][1]
		p.name = present[p.slot][2]
	_respawn_all_views()


func _wave() -> int:
	return 0 if _phase == "lobby" else int((_tick - _match_start_tick) * DT / 20.0) + 1


func _xp_next(level: int) -> int:
	return 10 + level * 5


# --- Tick ---------------------------------------------------------------------------------------


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_inner(delta)
	cost_us = Time.get_ticks_usec() - t0


func _process_inner(delta: float) -> void:
	for t in _timers.duplicate():
		t[0] -= delta
		if t[0] <= 0.0:
			_timers.erase(t)
			t[1].call()
	if not _running:
		return
	if Input.is_action_just_pressed(&"dash"):
		_latched_dash = true
	for i in 3:
		if Input.is_action_just_pressed(StringName("levelup_%d" % (i + 1))):
			_latched_choice = i + 1
	_acc += delta
	var steps := 0
	while _acc >= DT and steps < MAX_STEPS_PER_FRAME:
		_acc -= DT
		steps += 1
		_step()
	if steps == MAX_STEPS_PER_FRAME:
		_acc = 0.0
	_update_views(clampf(_acc / DT, 0.0, 1.0))


func _step() -> void:
	_tick += 1
	for p in _players:
		p.prev = p.pos
	for e in _enemies:
		e.prev = e.pos
	for s in _shots:
		s.prev = s.pos
	for it in _items:
		it.prev = it.pos
	_step_players()
	_step_items()
	match _phase:
		"lobby":
			for p in _players:
				if p.present and p.alive and Vector2(p.pos.x, p.pos.z).length() > CIRCLE_RADIUS:
					_start_match()
					break
		"match":
			_step_spawner()
			_step_enemies()
			_step_shots()
			_step_gems()
			var any_alive := false
			for p in _players:
				any_alive = any_alive or (p.present and p.alive)
			if not any_alive:
				_end_match()
		"over":
			_step_enemies()
			_over_t -= DT
			if _over_t <= 0.0:
				_back_to_lobby()


func _step_players() -> void:
	for p in _players:
		if not p.present:
			continue
		if not p.alive:
			if _phase == "match":
				p.respawn -= DT
				if p.respawn <= 0.0:
					p.alive = true
					p.hp = HP_MAX
					p.pos = START[p.slot]
					p.prev = p.pos
					_emit(&"player_respawned", p.slot, p.pos, 0.0)
					_spawn_view(&"player", p.slot, p.slot)
			continue
		var dir := Vector3.ZERO
		var dash := false
		var choice := 0
		if p.bot:
			dir = _bot_dir(p)
			dash = _rng.randf() < 0.004
			if p.pending > 0:
				choice = _rng.randi_range(1, 3)
		elif p.slot == _local_slot:
			var v := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
			dir = Vector3(v.x, 0, v.y)
			dash = _latched_dash
			choice = _latched_choice
			_latched_dash = false
			_latched_choice = 0
		if choice > 0:
			_apply_levelup(p, choice)
		p.dash_cd = maxf(p.dash_cd - DT, 0.0)
		p.dash_t = maxf(p.dash_t - DT, 0.0)
		if dash and p.dash_cd <= 0.0 and dir.length_squared() > 0.01:
			p.dash_t = DASH_TIME
			p.dash_cd = DASH_COOLDOWN
		var vel := dir.limit_length(1.0) * (PLAYER_SPEED + p.speed_bonus) * (3.0 if p.dash_t > 0.0 else 1.0)
		p.pos += vel * DT
		if vel.length_squared() > 0.01:
			p.yaw = atan2(vel.x, vel.z)
		p.pos = _push_out_static(p.pos, PLAYER_RADIUS)
		for it in _items:
			if it.alive:
				var d := Vector3(it.pos.x - p.pos.x, 0, it.pos.z - p.pos.z)
				var min_d := PLAYER_RADIUS + 0.55
				if d.length_squared() < min_d * min_d and d.length_squared() > 1e-6:
					it.pos += d.normalized() * (min_d - d.length())  # players shove crates and barrels
		if _phase == "match":
			p.fire_cd -= DT
			if p.fire_cd <= 0.0:
				var target := _nearest_enemy(p.pos, FIRE_RANGE)
				if target != null:
					p.fire_cd = p.fire_interval
					var s := Shot.new()
					s.pos = p.pos
					s.prev = s.pos
					s.vel = Vector3(target.pos.x - p.pos.x, 0, target.pos.z - p.pos.z).normalized() * PROJECTILE_SPEED
					s.damage = 5.0 + p.damage_bonus
					if _shots.size() < ENEMY_CAPACITY:
						_shots.append(s)


func _bot_dir(p: Player) -> Vector3:
	p.wander_t -= DT
	if p.wander_t <= 0.0:
		p.wander_t = _rng.randf_range(0.6, 1.8)
		var r := CIRCLE_RADIUS - 1.0 if _phase == "lobby" else 18.0
		p.wander = Vector3(_rng.randf_range(-r, r), 0, _rng.randf_range(-r, r))
	var to := p.wander - p.pos
	to.y = 0
	var dir := to.normalized() if to.length() > 0.5 else Vector3.ZERO
	var threat := _nearest_enemy(p.pos, 3.0)
	if threat != null:
		dir = (p.pos - threat.pos).normalized()
	return dir * (0.6 if _phase == "lobby" else 1.0)


func _step_items() -> void:
	for it in _items:
		if not it.alive:
			it.respawn -= DT
			if it.respawn <= 0.0 and _phase != "lobby":
				it.alive = true
				it.hp = 30.0
				it.pos = it.home
				it.prev = it.home
				_spawn_view(it.kind, it.entity, -1)
			continue
		if it.vel.length_squared() > 1e-4:
			it.pos += it.vel * DT
			it.vel *= 0.9
		it.pos = _push_out_static(it.pos, 0.5)


func _step_spawner() -> void:
	_spawn_t -= DT
	if _spawn_t > 0.0:
		return
	_spawn_t = 1.0
	var n := mini(3 + _wave() * 2, 24)
	for i in n:
		if _enemies.size() >= MAX_ENEMIES:
			break
		_spawn_enemy()


func _spawn_enemy(radius := 27.0) -> void:
	var r := _rng.randi_range(0, 9)
	var kind: StringName = &"grunt" if r < 7 else (&"runner" if r < 9 else &"brute")
	var spec: Array = ENEMY_KINDS[kind]
	var e := Enemy.new()
	e.kind = kind
	var a := _rng.randf() * TAU
	e.pos = Vector3(radius * cos(a), 0, radius * sin(a))
	e.prev = e.pos
	e.hp = spec[0]
	e.speed = spec[1]
	e.radius = spec[2]
	e.damage = spec[3]
	e.xp = spec[4]
	_enemies.append(e)


func _step_enemies() -> void:
	# Cheap separation through a spatial hash (cell 2 m).
	var grid := {}
	for i in _enemies.size():
		var e := _enemies[i]
		var key := Vector2i(floori(e.pos.x / 2.0), floori(e.pos.z / 2.0))
		if grid.has(key):
			grid[key].append(i)
		else:
			grid[key] = [i]
	var chase := _phase == "match"
	for i in _enemies.size():
		var e := _enemies[i]
		e.age += DT
		e.flash = maxf(e.flash - DT * 6.0, 0.0)
		e.cooldown = maxf(e.cooldown - DT, 0.0)
		var desired := Vector3.ZERO
		var target := _nearest_player(e.pos) if chase else null
		if target != null:
			desired = Vector3(target.pos.x - e.pos.x, 0, target.pos.z - e.pos.z).normalized() * e.speed
		elif not chase:
			desired = Vector3(e.pos.x, 0, e.pos.z).normalized() * e.speed  # scatter outwards when it is over
		var key := Vector2i(floori(e.pos.x / 2.0), floori(e.pos.z / 2.0))
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var cell: Array = grid.get(key + Vector2i(dx, dz), [])
				for j: int in cell:
					if j == i:
						continue
					var o := _enemies[j]
					var d := e.pos - o.pos
					var rr := e.radius + o.radius
					var d2 := d.x * d.x + d.z * d.z
					if d2 < rr * rr and d2 > 1e-6:
						desired += Vector3(d.x, 0, d.z) * (0.5 / d2)
		e.vel = e.vel * 0.8 + desired * 0.2
		e.vel = e.vel.limit_length(e.speed * 1.5)
	for e in _enemies:
		e.pos += e.vel * DT
		e.pos = _push_out_static(e.pos, e.radius)
		if not chase:
			continue
		for p in _players:
			if p.present and p.alive and e.cooldown <= 0.0:
				var d := Vector2(p.pos.x - e.pos.x, p.pos.z - e.pos.z).length()
				if d < e.radius + PLAYER_RADIUS:
					e.cooldown = 0.5
					_damage_player(p, e.damage)


func _damage_player(p: Player, amount: float) -> void:
	if not p.alive:
		return
	p.hp -= amount
	if p.hp <= 0.0:
		p.hp = 0.0
		p.alive = false
		p.respawn = RESPAWN_TIME
		_emit(&"player_died", p.slot, p.pos, 0.0)
		_despawn_view(p.slot)


func _step_shots() -> void:
	var i := 0
	while i < _shots.size():
		var s := _shots[i]
		s.pos += s.vel * DT
		s.life -= DT
		var dead := s.life <= 0.0 or absf(s.pos.x) > ARENA_HALF or absf(s.pos.z) > ARENA_HALF
		if not dead:
			for e in _enemies:
				var r := e.radius + 0.15
				if Vector2(e.pos.x - s.pos.x, e.pos.z - s.pos.z).length_squared() < r * r:
					e.hp -= s.damage
					e.flash = 1.0
					e.vel += s.vel.normalized() * 1.5
					dead = true
					break
		if not dead:
			for it in _items:
				if it.alive and Vector2(it.pos.x - s.pos.x, it.pos.z - s.pos.z).length_squared() < 0.36:
					dead = true
					if it.kind == &"barrel":
						it.hp -= s.damage
					else:
						it.vel += s.vel.normalized() * 0.6
					break
		if not dead:
			for c in _pillars:
				if absf(s.pos.x - c.x) < 1.0 and absf(s.pos.z - c.z) < 1.0:
					dead = true
					break
		if dead:
			_shots.remove_at(i)
		else:
			i += 1
	for it in _items:
		if it.alive and it.kind == &"barrel" and it.hp <= 0.0:
			_explode(it)
	i = 0
	while i < _enemies.size():
		var e := _enemies[i]
		if e.hp <= 0.0:
			_emit(&"enemy_died", 1000 + i, e.pos, float(BULK_KINDS.find(e.kind)))
			var g := Gem.new()
			g.pos = e.pos
			g.xp = e.xp
			_gems.append(g)
			_enemies.remove_at(i)
		else:
			i += 1


func _explode(it: Item) -> void:
	it.alive = false
	it.respawn = 10.0
	_emit(&"barrel_exploded", it.entity, it.pos, 5.0)
	_despawn_view(it.entity)
	for e in _enemies:
		if e.pos.distance_to(it.pos) < 5.0:
			e.hp -= 25.0
			e.flash = 1.0
			e.vel += (e.pos - it.pos).normalized() * 6.0
	for o in _items:
		var d := o.pos.distance_to(it.pos)
		if o.alive and d < 5.0 and d > 0.01:
			o.vel += (o.pos - it.pos).normalized() * 12.0 * (1.0 - d / 5.0)
	for p in _players:
		if p.present and p.alive and p.pos.distance_to(it.pos) < 3.0:
			_damage_player(p, 15.0)


func _step_gems() -> void:
	var i := 0
	while i < _gems.size():
		var g := _gems[i]
		g.age += DT
		var taken := false
		for p in _players:
			if p.present and p.alive:
				var d := Vector2(p.pos.x - g.pos.x, p.pos.z - g.pos.z).length()
				if d < 1.5:
					p.xp += g.xp
					_emit(&"gem_collected", p.slot, g.pos, float(g.xp))
					_check_level(p)
					taken = true
					break
				if d < 3.0:
					g.pos = g.pos.move_toward(Vector3(p.pos.x, 0, p.pos.z), 8.0 * DT)  # a little magnet
		if taken:
			_gems.remove_at(i)
		else:
			i += 1


func _check_level(p: Player) -> void:
	while p.xp >= _xp_next(p.level):
		p.xp -= _xp_next(p.level)
		p.level += 1
		p.pending += 1
		_emit(&"level_up", p.slot, p.pos, float(p.level))


func _apply_levelup(p: Player, option: int) -> void:
	if p.pending <= 0 or option < 1 or option > 3:
		return
	match option:
		1:
			p.fire_interval = maxf(p.fire_interval - 0.04, 0.1)
		2:
			p.damage_bonus += 3.0
		3:
			p.speed_bonus += 0.5
	p.pending -= 1


# --- Helpers ------------------------------------------------------------------------------------


func _push_out_static(pos: Vector3, r: float) -> Vector3:
	for c in _pillars:
		var dx := pos.x - c.x
		var dz := pos.z - c.z
		var px := 1.0 + r - absf(dx)
		var pz := 1.0 + r - absf(dz)
		if px > 0.0 and pz > 0.0:
			if px < pz:
				pos.x += px * signf(dx)
			else:
				pos.z += pz * signf(dz)
	var lim := ARENA_HALF - r
	pos.x = clampf(pos.x, -lim, lim)
	pos.z = clampf(pos.z, -lim, lim)
	return pos


func _nearest_enemy(pos: Vector3, max_range: float) -> Enemy:
	var best: Enemy = null
	var best_d := max_range * max_range
	for e in _enemies:
		var d := Vector2(e.pos.x - pos.x, e.pos.z - pos.z).length_squared()
		if d < best_d:
			best_d = d
			best = e
	return best


func _nearest_player(pos: Vector3) -> Player:
	var best: Player = null
	var best_d := INF
	for p in _players:
		if p.present and p.alive:
			var d := pos.distance_squared_to(p.pos)
			if d < best_d:
				best_d = d
				best = p
	return best


func _emit(kind: StringName, entity: int, pos: Vector3, value: float) -> void:
	sim_event.emit(kind, _tick, entity, pos, value)
	var view: Node3D = _views.get(entity)
	if view != null and view.has_method(&"_sim_event"):
		var slot := entity if entity < 4 else -1
		view._sim_event(kind, {"tick": _tick, "entity": entity, "slot": slot, "position": pos, "value": value, "predicted": false, "cancelled": false})


func _make_code() -> String:
	const ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O, 1/I
	var s := ""
	for i in 6:
		s += ALPHABET[_rng.randi_range(0, ALPHABET.length() - 1)]
	return s


func _is_alnum(s: String) -> bool:
	for ch in s:
		if not ((ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9")):
			return false
	return true


func _capacity(kind: StringName) -> int:
	return 1024 if kind == &"gem" else ENEMY_CAPACITY


# --- Views (what godot_host does natively) ------------------------------------------------------


func _set_view_root(root: Node3D) -> void:
	_clear_views()
	view_root = root
	_bulk.clear()
	if root != null:
		for n in get_tree().get_nodes_in_group(&"sim_bulk"):
			if root.is_ancestor_of(n):
				_bulk[StringName(n.get(&"kind"))] = n
		_respawn_all_views()


func _respawn_all_views() -> void:
	_clear_views()
	if view_root == null:
		return
	for p in _players:
		if p.present and p.alive:
			_spawn_view(&"player", p.slot, p.slot)
	for it in _items:
		if it.alive:
			_spawn_view(it.kind, it.entity, -1)


func _spawn_view(kind: StringName, entity: int, slot: int) -> void:
	if view_root == null or _views.has(entity):
		return
	if not _view_scenes.has(kind):
		_view_scenes[kind] = load("res://game/views/%s.tscn" % kind)
	var node: Node3D = _view_scenes[kind].instantiate()
	node.set(&"kind", kind)
	node.set(&"entity", entity)
	node.set(&"slot", slot)
	node.position = _entity_pos(entity)
	view_root.add_child(node)
	_views[entity] = node


## Like the native host: tell the view (`despawned`), keep it LINGER seconds for an exit animation, then free it.
func _despawn_view(entity: int, linger := true) -> void:
	var node: Node3D = _views.get(entity)
	if node == null:
		return
	_views.erase(entity)
	if not linger or not node.is_inside_tree():
		node.queue_free()
		return
	if node.has_method(&"_sim_event"):
		node._sim_event(&"despawned", {})
	get_tree().create_timer(LINGER).timeout.connect(node.queue_free)


func _clear_views() -> void:
	for entity in _views.keys():
		_despawn_view(entity, false)


## Views get the body centre, like the native sim reports it (the fake sim works on the floor plane).
func _entity_pos(entity: int) -> Vector3:
	if entity < 4:
		return _players[entity].pos + Vector3(0, 0.9, 0)
	var it := _items[entity - 100]
	return it.pos + Vector3(0, 0.7 if it.kind == &"barrel" else 0.5, 0)


func _update_views(alpha: float) -> void:
	if view_root == null:
		return
	for entity: int in _views:
		var node: Node3D = _views[entity]
		var pos: Vector3
		var yaw := 0.0
		if entity < 4:
			var p := _players[entity]
			pos = p.prev.lerp(p.pos, alpha) + Vector3(0, 0.9, 0)
			yaw = p.yaw
		else:
			var it := _items[entity - 100]
			pos = it.prev.lerp(it.pos, alpha) + Vector3(0, 0.7 if it.kind == &"barrel" else 0.5, 0)
		node.position = pos
		node._sim_update(pos, yaw, alpha)
	for kind in BULK_KINDS:
		var node: MultiMeshInstance3D = _bulk.get(kind)
		if node == null or node.multimesh == null:
			continue
		var buf: PackedFloat32Array = _bulk_buf[kind]  # a reference: packed arrays are shared, not copied
		var cap := _capacity(kind)
		var n := 0
		if kind == &"projectile":
			for s in _shots:
				if n < cap:
					_write_instance(buf, n, s.prev.lerp(s.pos, alpha), atan2(s.vel.x, s.vel.z), 0.0, s.life)
					n += 1
		elif kind == &"gem":
			for g in _gems:
				if n < cap:
					_write_instance(buf, n, g.pos, 0.0, 0.0, g.age)
					n += 1
		else:
			for e in _enemies:
				if e.kind == kind and n < cap:
					_write_instance(buf, n, e.prev.lerp(e.pos, alpha), atan2(e.vel.x, e.vel.z), e.flash, e.age)
					n += 1
		var mm := node.multimesh
		if mm.instance_count != cap:
			mm.instance_count = cap
		RenderingServer.multimesh_set_buffer(mm.get_rid(), buf)
		mm.visible_instance_count = n


func _write_instance(buf: PackedFloat32Array, i: int, pos: Vector3, yaw: float, flash: float, age: float) -> void:
	var c := cos(yaw)
	var s := sin(yaw)
	var o := i * 16
	# Row-major 3x4 transform (basis rows + origin), then custom data (flash, age, 0, 0).
	buf[o + 0] = c
	buf[o + 1] = 0.0
	buf[o + 2] = s
	buf[o + 3] = pos.x
	buf[o + 4] = 0.0
	buf[o + 5] = 1.0
	buf[o + 6] = 0.0
	buf[o + 7] = pos.y
	buf[o + 8] = -s
	buf[o + 9] = 0.0
	buf[o + 10] = c
	buf[o + 11] = pos.z
	buf[o + 12] = flash
	buf[o + 13] = age
	buf[o + 14] = 0.0
	buf[o + 15] = 0.0
