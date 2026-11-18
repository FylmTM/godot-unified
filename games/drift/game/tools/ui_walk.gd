extends UnifiedUiWalk
## The shared UI walk (UnifiedUiWalk) plus drift's own play scene, on the real session (single player), driven by
## input actions as a player would (the right stick aims): the lobby (the ship, the station and both gates) -> click
## Start (the `start` command) -> the match: aim with the stick (the ship turns to it), thrust (it moves, the camera
## follows), fire (bullets in the multi view) while the first wave's rocks drift in -> hunt rocks until a bullet hits
## one. Splitting and destroying rocks and warping through a gate: the full tour (`uni tool drift tour`).

const ROCK_KINDS: Array[StringName] = [&"rock_0", &"rock_1", &"rock_2", &"rock_3"]
const HUNT_S := 20
## How far the hunt shoots (pixels): well inside a bullet's reach (BULLET_SPEED × BULLET_LIFE_S ≈ 500 px), so a rock
## drifting while a bullet flies is still hit.
const HUNT_RANGE := 400.0

## Confirmed rock hits, from sim_event.
var _rock_hits := 0


func _walk_play() -> void:
	current_scene.mouse_aim_enabled = false  # the stick aims; a real mouse over a window must not
	var on_event := _on_sim_event
	session.sim_event.connect(on_event)
	await _lobby_and_start()
	await _aim_and_thrust()
	await _fire_and_hunt()
	Input.action_release(&"fire")
	_stick(Vector2.ZERO)
	_move(Vector2.ZERO)
	session.sim_event.disconnect(on_event)


func _lobby_and_start() -> void:
	await wait_for(func() -> bool: return _me() != null, 8.0, "the local ship's view")
	await wait_for(func() -> bool: return views(EnumView.STATION).size() == 1 and views(EnumView.GATE).size() == 2, 3.0,
		"the station and 2 gate views")
	await wait_for(func() -> bool: return Unified.data.hud.phase == EnumPhase.LOBBY, 3.0, "the lobby")
	if failed():
		return
	await shot("02_lobby")
	step("lobby: ship at %s" % _v(_me().global_position))

	var start: Button = current_scene.get_node(^"HUD").start_button
	expect(start.is_visible_in_tree(), "the Start button shows in the lobby")
	await click(start)
	await wait_for(func() -> bool: return Unified.data.hud.phase == EnumPhase.MATCH, 3.0,
		"the match after Start (the start command)")
	step("match started (wave %d)" % Unified.data.hud.wave)


## The stick turns the ship (its view's rotation, set by the host from the sim's heading); thrust moves it and the
## camera follows.
func _aim_and_thrust() -> void:
	for aim: Array in [[&"aim_right", 0.0], [&"aim_up", -PI / 2.0], [&"aim_left", PI]]:
		Input.action_press(aim[0], 1.0)
		await wait_for(func() -> bool: return absf(angle_difference(_me().rotation, aim[1])) <= 0.3, 1.5,
			"aiming %s turns the ship" % aim[0])
		Input.action_release(aim[0])
	step("aimed right, up and left: the ship turned")

	var cam: Camera2D = current_scene.get_node(^"Camera")
	var p0 := _me().global_position
	var c0 := cam.get_screen_center_position()
	Input.action_press(&"move_right")
	await wait_for(func() -> bool: return _me().global_position.x - p0.x >= 40.0, 2.0, "thrusting right moves the ship")
	await wait_for(func() -> bool: return cam.get_screen_center_position().x - c0.x >= 10.0, 2.0,
		"the camera follows the ship")
	Input.action_release(&"move_right")
	step("thrust right: ship %+.0f px, camera %+.0f px" % [_me().global_position.x - p0.x,
		cam.get_screen_center_position().x - c0.x])


## Fires while the first wave drifts in, then hunts until a bullet hits a rock. The ship holds still and aims at the
## nearest rock it can hit: in range, with nothing between (the level's walls, reefs and pillars, the station). The
## rocks drift at the station, so one comes into a clear line within seconds; until then the aim sweeps.
func _fire_and_hunt() -> void:
	Input.action_press(&"fire")
	Input.action_press(&"aim_up", 1.0)
	await wait_for(func() -> bool: return multi_count(&"bullet") > 0, 2.0, "bullets in the bullet multi view")
	await wait_for(func() -> bool: return _rocks_drawn() > 0, 6.0, "rocks in the rock multi views")
	Input.action_release(&"aim_up")
	await shot("03_match")
	step("match: %d bullets, %d rocks drawn" % [multi_count(&"bullet"), _rocks_drawn()])

	var start := Time.get_ticks_msec()
	await wait_for(func() -> bool: return _rock_hits > 0 or _hunt_steer(start), HUNT_S,
		"a bullet hits a rock (%d s of firing at them)" % HUNT_S)
	step("hunt: a rock hit after %.1f s" % ((Time.get_ticks_msec() - start) / 1000.0))


## Steers the hunt for this frame (never done: the hunt ends on a hit).
func _hunt_steer(start: int) -> bool:
	var at := _me().global_position
	var target := _clear_rock(at)
	if target != Vector2.INF:
		_stick((target - at).normalized())
	else:
		_stick(Vector2.from_angle((Time.get_ticks_msec() - start) * 0.002))  # 2 rad/s, slower than the ship turns
	_move(Vector2.ZERO)
	return false


func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if event is EventRockHit and state == UnifiedSession.EVENT_CONFIRMED:
		_rock_hits += 1


func _me() -> Node2D:
	return session.get_player_view(EnumView.SHIP, session.local_player) as Node2D


func _rocks_drawn() -> int:
	var n := 0
	for kind in ROCK_KINDS:
		n += multi_count(kind)
	return n


## The nearest rock within HUNT_RANGE of `from` that a bullet from there reaches, or Vector2.INF. The rocks are read
## back from the rock multi views' buffers (what the host wrote; the dummy renderer keeps them); the line of fire must
## miss the level's static bodies (the play scene holds them) and the station's circle.
func _clear_rock(from: Vector2) -> Vector2:
	var space := (current_scene as Node2D).get_world_2d().direct_space_state
	var station := session.get_view(EnumView.STATION, 0) as Node2D
	var station_reach := (Unified.constants.station_radius + Unified.constants.ship_radius) * Unified.view_scale
	var best := Vector2.INF
	for rock: Vector2 in _rock_positions():
		if from.distance_to(rock) > HUNT_RANGE or (best != Vector2.INF and from.distance_to(rock) >= from.distance_to(best)):
			continue
		if station != null and Geometry2D.get_closest_point_to_segment(station.global_position, from, rock) \
				.distance_to(station.global_position) < station_reach:
			continue
		if not space.intersect_ray(PhysicsRayQueryParameters2D.create(from, rock)).is_empty():
			continue
		best = rock
	return best


## Every drawn rock's position (global pixels).
func _rock_positions() -> Array[Vector2]:
	var out: Array[Vector2] = []
	for b in current_scene.get_node(^"MultiViews").get_children():
		var mmi := b as MultiMeshInstance2D
		var marker := b.get_node_or_null(^"UnifiedMultiView") as UnifiedMultiView
		if mmi == null or mmi.multimesh == null or marker == null or not (StringName(marker.kind) in ROCK_KINDS):
			continue
		var mm := mmi.multimesh
		var buffer := mm.buffer
		var stride := 8 + (4 if mm.use_colors else 0) + (4 if mm.use_custom_data else 0)  # a 2D transform: 2x4
		for i in mini(maxi(mm.visible_instance_count, 0), buffer.size() / stride):
			var at := i * stride
			out.append(mmi.global_transform * Vector2(buffer[at + 3], buffer[at + 7]))
	return out

## The right stick, as Input actions (what Input.get_vector reads).
func _stick(dir: Vector2) -> void:
	_press_vector(dir, [&"aim_right", &"aim_left", &"aim_down", &"aim_up"])


## The left stick (thrust).
func _move(dir: Vector2) -> void:
	_press_vector(dir, [&"move_right", &"move_left", &"move_down", &"move_up"])


## A direction as four actions (+x, -x, +y, -y) pressed with its components as strengths.
func _press_vector(dir: Vector2, actions: Array[StringName]) -> void:
	for pair: Array in [[actions[0], dir.x], [actions[1], -dir.x], [actions[2], dir.y], [actions[3], -dir.y]]:
		if pair[1] > 0.05:
			Input.action_press(pair[0], pair[1])
		else:
			Input.action_release(pair[0])


static func _v(p: Vector2) -> String:
	return "(%.0f, %.0f)" % [p.x, p.y]
