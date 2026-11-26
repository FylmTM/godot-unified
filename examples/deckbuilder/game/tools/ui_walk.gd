extends MenuTool
## A scripted walk through deckbuilder's UI with real input events (clicks, pad buttons, keys, actions), the godot
## suite's `walk` step:
##   godot --headless --path examples/deckbuilder -s res://game/tools/ui_walk.gd -- --no-settings [--shots=<dir>]
## the menu -> settings (Show FPS toggles) -> pad navigation -> Single player -> the table's camp (pick the Arcanist:
## the session starts again with the new class) -> start a run -> vote on the map -> the first fight: hold a card up
## (the aim, its targets lit), put it down (right click), play it on an enemy -> end the turn (the enemies act, the next
## round deals) -> win the fight (the dev command) -> take a reward card -> vote again (the save point) -> the Esc menu
## pauses -> leave to the menu -> Single player again: the camp offers the saved run -> continue it (the floor and the
## deck as saved) -> leave -> host on LAN (the session panel shows the address) -> a bad code's error on the menu. With
## `--shots=<dir>` (a window) it saves PNGs at the key moments.

## The local hero's cards played, from sim_event (confirmed).
var _played := 0


func _run() -> void:
	game.lan_port = 20000 + randi() % 20000  # parallel walks (one per game) must not share a port
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	await wait_for_scene("MainMenu", 5.0)
	await frames(5)
	await shot("01_menu")
	step("main menu")

	await _walk_settings()
	await _walk_pad()

	await click_menu("Single")
	await wait_for_scene("Table", 5.0)
	session.sim_event.connect(_on_sim_event)
	await _camp()
	expect(Table.button(current_scene, "Continue") == null, "no saved run: the camp offers no Continue")
	expect(Table.button(current_scene, "Invite friends") != null, "the camp offers to invite friends")
	expect(not (find(current_scene, ^"Session") as Control).visible, "no session panel alone")
	await shot("02_camp")
	step("the camp")
	if failed():
		return

	await click(Table.button(current_scene, "Arcanist"))
	await wait_for(func() -> bool: return Unified.profile.hero_class == EnumHeroClass.ARCANIST, 3.0,
		"the Arcanist chosen")
	expect(setting(&"hero_class") == EnumHeroClass.ARCANIST, "the class is the player's setting")
	await _camp()
	expect(Table.button(current_scene, "Arcanist") != null and Table.button(current_scene, "Arcanist").button_pressed,
		"the camp shows the Arcanist picked")
	step("picked the Arcanist")
	if failed():
		return

	await click(Table.button(current_scene, "Start a run"))
	# a run's start is a session's start and the table's load: 10 s, as a wait for a step (not a timing claim), so a
	# loaded machine (every suite in parallel under verify) doesn't fail it
	await wait_for(func() -> bool: return Unified.data.run.phase == EnumPhase.MAP and Table.title(current_scene) == "Where next?", 10.0,
		"the map after starting the run")
	var hero := Table.local_row()
	expect(hero != null and hero.in_run and hero.hero_class == EnumHeroClass.ARCANIST,
		"the local hero is an Arcanist in the run")
	await frames(3)
	await shot("03_map")
	step("the run starts on the map")
	if failed():
		return

	await _vote()
	await wait_for(func() -> bool: return Unified.data.run.phase == EnumPhase.HEROES and Table.hand(current_scene).size() > 0, 5.0,
		"the first fight, the hand dealt")
	await wait_for(func() -> bool: return views(EnumView.ENEMY).size() > 0, 3.0, "the enemies in their row")
	expect(Table.title(current_scene) == "", "no panel over the fight")
	step("the first fight: %d cards in hand, %d enemies" % [Table.hand(current_scene).size(), views(EnumView.ENEMY).size()])
	if failed():
		return

	var card := Table.playable(current_scene, EnumTargetKind.ENEMY)
	if card == null:
		fail("no playable card that targets an enemy in the opening hand")
		return
	await seconds(0.4)  # the hand dealt and fanned
	await click(card)
	await wait_for(func() -> bool: return Unified.input.card == card.data.slot + 1, 2.0, "the card held up (the aim)")
	await wait_for(func() -> bool: return Table.local_row().aim_card == card.data.slot + 1, 3.0,
		"the aim reaches the hero's row (the Input)")
	expect((views(EnumView.ENEMY)[0] as DeckEnemy).targetable, "the enemies light up as its targets")
	await shot("04_held")
	await click_at(Vector2(640, 300), MOUSE_BUTTON_RIGHT)  # the empty table
	expect(Unified.input.card == 0, "a right click puts the card down")
	step("held a card up and put it down")
	if failed():
		return

	var energy := Table.local_row().energy
	await click(card)
	var enemy := views(EnumView.ENEMY)[0] as Control
	await click(enemy)
	await wait_for(func() -> bool: return _played == 1, 3.0, "the card played on the enemy")
	expect(Table.local_row().energy < energy, "the play spent energy")
	await seconds(0.3)
	await shot("05_played")
	step("played a card on an enemy")
	if failed():
		return

	var held := Table.playable(current_scene, EnumTargetKind.ENEMY)
	if held != null:
		await click(held)
		await wait_for(func() -> bool: return Unified.input.card == held.data.slot + 1, 2.0, "a card held up again")
	var round: int = Unified.data.run.round
	await click(find(current_scene, ^"%EndTurn") as Control)
	expect(Unified.input.card == 0, "ending the turn puts the held card down")
	await wait_for(func() -> bool: return Unified.data.run.round > round and Unified.data.run.phase == EnumPhase.HEROES,
		10.0, "the enemies act, the next round")
	expect(Unified.input.card == 0, "the next round holds no card up")
	step("ended the turn: round %d" % Unified.data.run.round)
	if failed():
		return

	session.send_command(CommandDevWinFight.new())
	await wait_for(func() -> bool: return Unified.data.run.phase == EnumPhase.REWARD and Table.first_offer(current_scene) != null,
		3.0, "the reward after the fight")
	await frames(3)
	await shot("06_reward")
	var deck: int = Unified.data.run.deck_count
	await click(Table.first_offer(current_scene))
	await wait_for(func() -> bool: return Unified.data.run.phase == EnumPhase.MAP, 3.0, "the map after the reward")
	expect(Unified.data.run.deck_count == deck + 1, "the reward card joined the deck")
	step("took a reward card: %d in the deck" % Unified.data.run.deck_count)
	if failed():
		return

	await _vote()
	await wait_for(func() -> bool: return Unified.data.run.floor == 1, 3.0, "the party enters the second floor")
	await wait_for(func() -> bool: return game.saved_run() != "", 3.0, "the save point kept (in memory: --no-settings)")
	step("entered floor 2: the run saved")
	if failed():
		return

	await _walk_pause_menu()
	await click(find(find(current_scene, ^"PauseMenu"), ^"%Leave") as Control)
	await wait_for_scene("MainMenu", 5.0)
	await wait_for(func() -> bool: return game.flow == game.Flow.MENU and game.status in [UnifiedSession.STATUS_IDLE, UnifiedSession.STATUS_LEFT], 3.0,
		"the flow back to MENU, the session ended")
	step("left to the menu")

	await frames(3)
	await click_menu("Single")
	await wait_for_scene("Table", 5.0)
	await _camp()
	expect(Table.button(current_scene, "Continue") != null, "the camp offers the saved run")
	await shot("07_continue")
	await click(Table.button(current_scene, "Continue"))
	await wait_for(func() -> bool: return Unified.data.run.floor == 1 and Unified.data.run.local_hero >= 0, 5.0,
		"the saved run continues on its floor")
	expect(Unified.data.run.deck_count == deck + 1, "the continued run keeps the deck as saved")
	expect(Table.local_row().hero_class == EnumHeroClass.ARCANIST, "the continued run keeps the hero's class")
	step("continued the saved run")
	if failed():
		return
	game.leave_to_menu()
	await wait_for_scene("MainMenu", 5.0)

	await frames(3)
	await click_menu("JoinAddress")
	await click_menu("HostLan")
	await wait_for_scene("Table", 5.0)
	await _camp()
	var code := find(current_scene, ^"Session/VBox/CodeRow/Code") as Label
	expect(code != null and code.text.ends_with(":%d" % game.lan_port), "the session panel shows host:port")
	await shot("08_lan_host")
	step("hosted on LAN: %s" % game.session.join_code)
	game.leave_to_menu()
	await wait_for_scene("MainMenu", 5.0)

	await frames(3)
	await click_menu("Join")
	var edit := find(menu(), ^"%CodeEdit") as LineEdit
	if failed():
		return
	edit.clear()  # a windowed run may have prefilled it from the real clipboard
	await type_text("ab0o1l")  # 0, O, 1 and L look like other characters: the code alphabet has none of them
	await frames(2)
	expect(edit.text == "AB", "the code field keeps only the code's characters (got '%s')" % edit.text)
	edit.clear()
	await type_text("zz-zz zz")  # messy input: cleaned to ZZZZZZ
	await frames(2)  # LineEdit emits text_changed deferred
	expect(edit.text == "ZZZZZZ", "the code field cleans and uppercases its input (got '%s')" % edit.text)
	await click_menu("CodeJoin")
	await wait_for(func() -> bool: return menu() != null and menu().visible_panel() == find(menu(), ^"%ErrorPanel"),
		20.0, "a failed join shows the error on the menu")
	await frames(3)
	await shot("09_join_error")
	step("bad code -> the error on the menu")


func _walk_settings() -> void:
	await click_menu("Settings")
	var panel: Control = menu().visible_panel() if menu() != null else null
	expect(panel != null and panel.name == "SettingsPanel", "Settings opens the settings panel")
	if failed():
		return
	var fps: CheckButton = panel.control("Show FPS")
	await click(fps)
	expect(setting(&"show_fps") == true, "Show FPS turns the setting on")
	await frames(3)
	await shot("01b_settings")
	await click(fps)
	expect(setting(&"show_fps") == false, "Show FPS turns it off again")
	await click(find(panel, ^"%Back") as Control)
	expect(not panel.visible, "Done closes the settings")
	step("settings panel")


## A pad drives the menu: the d-pad moves focus, A presses, B goes back; a key switches the hints back.
func _walk_pad() -> void:
	(find(menu(), ^"%Single") as Control).grab_focus()
	for i in 4:
		await pad_button(JOY_BUTTON_DPAD_DOWN)
	expect(root.gui_get_focus_owner() == find(menu(), ^"%Settings"), "the d-pad moves focus to Settings")
	await pad_button(JOY_BUTTON_A)
	expect(menu().visible_panel() != null, "pad A opens the focused Settings")
	await pad_button(JOY_BUTTON_B)
	expect(menu().visible_panel() == null, "pad B closes the panel")
	expect(game.using_pad, "the game switched to pad hints")
	await type_text("q")  # any key switches back (not Space: it presses the focused button)
	expect(not game.using_pad, "a key switches back to keyboard hints")
	step("pad menu navigation")


## The Esc menu opens over the table and closes; in single player it pauses the session meanwhile. Left open: the
## walk leaves through it.
func _walk_pause_menu() -> void:
	var pause := find(current_scene, ^"PauseMenu") as CanvasLayer
	if failed():
		return
	await press_action(&"menu")
	expect(pause.visible, "Esc opens the menu")
	await seconds(0.1)
	expect(session.paused, "single player: the menu pauses the session")
	var held: int = session.tick
	await seconds(0.3)
	expect(session.tick == held, "no tick while paused")
	await shot("06b_pause_menu")
	await press_action(&"menu")
	expect(not pause.visible, "Esc closes the menu")
	await seconds(0.3)
	expect(not session.paused and session.tick > held, "the ticks go on once it closes")
	await pad_button(JOY_BUTTON_START, 1)
	expect(pause.visible, "a second pad's Start opens the menu (the menu action hears every pad)")
	await pad_button(JOY_BUTTON_START, 1)
	expect(not pause.visible, "and closes it")
	await press_action(&"menu")
	step("Esc menu")


## The camp, once the session runs: its panel is rebuilt when the session's first data comes, and a click before
## that lands on a button on its way out.
func _camp() -> void:
	await wait_for(func() -> bool: return _connected() and Table.title(current_scene) == "The camp", 5.0,
		"the camp, the session running")
	await frames(3)  # the panel's buttons laid out


func _connected() -> bool:
	return session != null and session.status == UnifiedSession.STATUS_CONNECTED


func _vote() -> void:
	await frames(3)
	if failed():
		return
	var lane := Table.open_lane(current_scene)
	if lane == null:
		fail("no lane to vote for")
		return
	await click(lane)


func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state == UnifiedSession.EVENT_CONFIRMED and event is EventCardPlayed:
		if (event as EventCardPlayed).hero == Unified.data.run.local_hero:
			_played += 1
