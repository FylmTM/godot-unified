extends "res://game/tools/ui_walk.gd"
## A tour of the real game with the native session, driven by input actions: the walk's start of a match (ui_walk.gd:
## the lobby, walking out, the auto-attack, a Pick), then the rest of a whole match: kite in circles -> level-up ->
## stand still until the match is lost -> over -> back to the lobby -> leave.
##   godot --path examples/survivor -s res://game/tools/tour.gd -- --no-settings [--shots=<dir>] [--frames]
## By hand (`uni tool survivor tour`). With `--frames` it also tags the first show of each HUD panel and banner size,
## the first hit on the player and a barrel explosion, for the first-use hitches.

const HUD_PANELS: Array[NodePath] = [^"LevelUp", ^"GameOver", ^"Respawn"]
## The level-up keys by card (the HUD's PICKS).
const LEVELUP_KEYS: Array[StringName] = [&"levelup_1", &"levelup_2", &"levelup_3"]
const MOVES: Array[StringName] = [&"move_left", &"move_right", &"move_forward", &"move_back"]
## Kiting in a big circle, so the auto-attack works and gems get collected.
const KITE: Array[Array] = [[&"move_right"], [&"move_right", &"move_back"], [&"move_back"],
	[&"move_left", &"move_back"], [&"move_left"], [&"move_left", &"move_forward"], [&"move_forward"],
	[&"move_right", &"move_forward"]]

var _last_hp := -1.0


func _process(delta: float) -> bool:
	if frame_log != null:
		_watch_hud()
	return super(delta)


func _run() -> void:
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	await wait_for_scene("MainMenu", 5.0)
	await seconds(3.0 if frame_log != null else 0.5)  # --frames: a player's time in the menu, for what loads meanwhile
	await shot("r01_menu")
	step("menu (native session)")

	await click_menu("Single")
	await wait_for_scene("Arena", 5.0)
	if failed():
		return
	await _walk_play()
	if failed():
		return

	var leveled := false
	var shot_fight := false
	var shot_dead := false
	for i in 700:  # up to ~70 s: until a level-up (the first comes after about 30 s of kiting)
		_release_all()
		for a: StringName in KITE[floori(i / 4.0) % KITE.size()]:
			Input.action_press(a)
		if i % 25 == 0:
			frame_tag("dash")
			_tap(&"dash")
		if frame_log != null and i == 60:
			_probe_explosion()
		await seconds(0.1)
		if not shot_fight and Unified.data.hud.enemies_alive > 25:
			shot_fight = true
			await shot("r04_fight")
		if _me() != null and _me().pending_levelups > 0 and not leveled:
			leveled = true
			await seconds(0.3)
			await shot("r05_levelup")
			var pending := _me().pending_levelups
			var key := _offered_key(_me().offer_a)
			await press_action(key)  # an input event: the HUD picks in _unhandled_input
			await wait_for(func() -> bool: return _me() == null or _me().pending_levelups < pending, 2.0,
				"the first offer's key picks an upgrade")
			step("level-up offered and chosen (%s)" % key)
		if (leveled and shot_fight and i > 150) or Unified.data.hud.phase != EnumPhase.MATCH or failed():
			break
		if _me() != null and not _me().alive and not shot_dead:
			shot_dead = true
			await seconds(0.25)
			await shot("r05b_down")
	_release_all()
	expect(leveled, "kiting reaches a level-up")
	await shot("r06_fight_later")
	step("fight: wave %d, %d enemies, level %d" % [Unified.data.hud.wave, Unified.data.hud.enemies_alive,
		_me().level if _me() != null else 0])

	# Stand still until the horde wins.
	await wait_for(func() -> bool: return Unified.data.hud.phase == EnumPhase.OVER, 90.0, "the match is lost")
	await seconds(0.8)
	await shot("r07_over")
	step("match over after %.0f s" % Unified.data.hud.time_s)
	await wait_for(func() -> bool: return Unified.data.hud.phase == EnumPhase.LOBBY, 10.0, "back to the lobby")
	await seconds(0.8)
	await shot("r08_back_in_lobby")
	step("back in the lobby")
	game.leave_to_menu()
	await wait_for_scene("MainMenu", 5.0)
	step("left to the menu")


## The local player's HUD row (null until the session assigns one).
func _me() -> DataHudPlayer:
	return local_row()


## The level-up key of the card for `upgrade` (an EnumUpgrade value; the cards are in Unified.constants.upgrades order).
func _offered_key(upgrade: int) -> StringName:
	var cards := Unified.constants.upgrades
	for i in cards.size():
		if (cards[i] as DataUpgradeCard).upgrade == upgrade:
			return LEVELUP_KEYS[i]
	return &"levelup_1"


func _release_all() -> void:
	for a: StringName in MOVES + [&"dash"]:
		Input.action_release(a)


## Presses an action for two frames (Input's state, what the session samples), without waiting for it.
func _tap(action: StringName) -> void:
	Input.action_press(action)
	await process_frame
	await process_frame
	Input.action_release(action)


## Barrels only explode from stray shots, so a run rarely sees one: plays the effect (client-only, no sim change)
## near the player to measure its first use.
func _probe_explosion() -> void:
	var players := views(EnumView.PLAYER)
	if players.is_empty():
		return
	frame_tag("probe: barrel_exploded")
	var at: Vector3 = (players[0] as Node3D).global_position + Vector3(3, 0, 0)
	current_scene.get_node(^"Fx").call(&"explosion", at, 4.0)


## Tags the first frame each HUD panel and banner size is shown (a first draw can rasterize glyphs or compile).
func _watch_hud() -> void:
	var hud := current_scene.get_node_or_null(^"HUD/Root") if current_scene != null else null
	if hud == null:
		return
	for p in HUD_PANELS:
		if (hud.get_node(p) as CanvasItem).is_visible_in_tree() and not frame_log.seen("show " + str(p)):
			frame_tag("show " + str(p))
	for banner: Label in [hud.get_node(^"Banner"), hud.get_node(^"Notice")]:
		if banner.is_visible_in_tree() and banner.modulate.a > 0.0:
			frame_tag("banner %dpx" % banner.get_theme_font_size(&"font_size"))
	var hp := float(_me().hp) if _me() != null else -1.0
	if _last_hp >= 0.0 and hp < _last_hp - 0.01:
		frame_tag("player hit")  # the hit flash
	_last_hp = hp
