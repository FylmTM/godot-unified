extends UnifiedTool
## A scripted walk through deckbuilder's table with real clicks, the godot suite's `walk` step:
##   godot --headless --path examples/deckbuilder -s res://game/tools/ui_walk.gd -- [--shots=<dir>]
## the camp (it offers hosting and joining; pick the Arcanist: the session starts again with the new class) -> start a run -> vote on the map ->
## the first fight: hold a card up (the aim), put it down (right click), play it on an enemy -> end the turn (the
## enemies act, the next round deals) -> win the fight (the dev command) -> take a reward card -> vote again (the save
## point) -> the table again from the start: the camp offers the saved run -> continue it (the floor and the deck as
## saved). With `--shots=<dir>` (a window) it saves PNGs at the key moments.

const SAVE_PATH := "user://deckbuilder_save.json"

## The local hero's cards played, from sim_event (confirmed).
var _played := 0


func _run() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))  # a walk starts with no saved run
	await load_session()
	await wait_for_scene("Main", 5.0)
	session.sim_event.connect(_on_sim_event)
	await _camp()
	expect(Table.button(current_scene, "Continue") == null, "no saved run: the camp offers no Continue")
	for offer: String in ["Host online", "Host on the LAN", "Join by code", "Join on the LAN"]:
		expect(Table.button(current_scene, offer) != null, "the camp offers %s" % offer)
	await shot("01_camp")
	step("the camp")
	if failed():
		return

	await click(Table.button(current_scene, "Arcanist"))
	await wait_for(func() -> bool: return Unified.profile.hero_class == EnumHeroClass.ARCANIST, 3.0,
		"the Arcanist chosen")
	await _camp()
	expect(Table.button(current_scene, "Arcanist") != null and Table.button(current_scene, "Arcanist").button_pressed, "the camp shows the Arcanist picked")
	step("picked the Arcanist")
	if failed():
		return

	await click(Table.button(current_scene, "Start a run"))
	await wait_for(func() -> bool: return Unified.data.run.phase == EnumPhase.MAP and Table.title(current_scene) == "Where next?", 3.0,
		"the map after starting the run")
	var hero := Table.local_row()
	expect(hero != null and hero.in_run and hero.hero_class == EnumHeroClass.ARCANIST,
		"the local hero is an Arcanist in the run")
	await frames(3)
	await shot("02_map")
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
	await click(card)
	await wait_for(func() -> bool: return Unified.input.card == card.data.slot + 1, 2.0, "the card held up (the aim)")
	await wait_for(func() -> bool: return Table.local_row().aim_card == card.data.slot + 1, 3.0,
		"the aim reaches the hero's row (the Input)")
	await click_at(Vector2(4, 4), MOUSE_BUTTON_RIGHT)  # the empty table
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
	await shot("03_played")
	step("played a card on an enemy")
	if failed():
		return

	var round: int = Unified.data.run.round
	await click(find(current_scene, ^"%EndTurn") as Control)
	await wait_for(func() -> bool: return Unified.data.run.round > round and Unified.data.run.phase == EnumPhase.HEROES,
		10.0, "the enemies act, the next round")
	step("ended the turn: round %d" % Unified.data.run.round)
	if failed():
		return

	session.send_command(CommandDevWinFight.new())
	await wait_for(func() -> bool: return Unified.data.run.phase == EnumPhase.REWARD and Table.title(current_scene) == "Choose a card",
		3.0, "the reward after the fight")
	await frames(3)
	await shot("04_reward")
	var deck: int = Unified.data.run.deck_count
	await click(find(current_scene, ^"%Body").get_child(0) as Control)
	await wait_for(func() -> bool: return Unified.data.run.phase == EnumPhase.MAP, 3.0, "the map after the reward")
	expect(Unified.data.run.deck_count == deck + 1, "the reward card joined the deck")
	step("took a reward card: %d in the deck" % Unified.data.run.deck_count)
	if failed():
		return

	await _vote()
	await wait_for(func() -> bool: return Unified.data.run.floor == 1, 3.0, "the party enters the second floor")
	await wait_for(func() -> bool: return FileAccess.file_exists(SAVE_PATH), 3.0, "the save point written")
	step("entered floor 2: the run saved")
	if failed():
		return

	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	await frames(3)
	await _camp()
	expect(Table.button(current_scene, "Continue") != null, "the camp offers the saved run")
	await shot("05_continue")
	await click(Table.button(current_scene, "Continue"))
	await wait_for(func() -> bool: return Unified.data.run.floor == 1 and Unified.data.run.local_hero >= 0, 5.0,
		"the saved run continues on its floor")
	expect(Unified.data.run.deck_count == deck + 1, "the continued run keeps the deck as saved")
	expect(Table.local_row().hero_class == EnumHeroClass.ARCANIST, "the continued run keeps the hero's class")
	step("continued the saved run")
	if failed():
		return


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

