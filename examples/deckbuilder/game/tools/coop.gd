extends UnifiedCoop
## deckbuilder's co-op play (the flow is the library's, UnifiedCoop): the host starts a run from the camp, both vote
## for the first floor, and in the fight each holds a card up (the other sees the aim on their hero's row) and plays it
## on an enemy, then both end the turn and see the enemies act.

## Cards the local hero played, from sim_event (confirmed).
var _played := 0
## Cards the friend's hero played, as this side saw them (confirmed).
var _friend_played := 0


func _host_play() -> void:
	session.sim_event.connect(_on_sim_event)
	await wait_for(func() -> bool: return Table.title(current_scene) == "The camp", 10.0, "the camp")
	await frames(3)
	await click(Table.button(current_scene, "Start a run"))
	await wait_for(func() -> bool: return Unified.data.run.phase == EnumPhase.MAP, 5.0, "the map after Start a run")
	expect(_heroes_in_run() == 2, "a hero each")
	step("run started: %d heroes" % _heroes_in_run())
	await _fight()


func _join_play() -> void:
	session.sim_event.connect(_on_sim_event)
	await wait_for(func() -> bool: return Unified.data.run.phase == EnumPhase.MAP, 40.0, "the host starts a run")
	step("run started (seen by the joiner)")
	await _fight()


func _playing() -> bool:
	return Unified.data.run.phase != EnumPhase.CAMP


## Both sides: the vote, a card held up and then played, the turn ended, the enemies' turn.
func _fight() -> void:
	await frames(3)
	await click(Table.open_lane(current_scene))
	await wait_for(func() -> bool: return Unified.data.run.phase == EnumPhase.HEROES, 10.0,
		"the party's vote enters the first fight")
	await wait_for(func() -> bool: return Table.playable(current_scene, EnumTargetKind.ENEMY) != null, 5.0,
		"a card to play at an enemy")
	if failed():
		return
	step("the fight")

	var card := Table.playable(current_scene, EnumTargetKind.ENEMY)
	await click(card)
	await wait_for(func() -> bool: return _friend_row() != null and _friend_row().aim_card != 0, 10.0,
		"the friend's aim shows on their hero's row")
	step("the friend holds up their card %d" % _friend_row().aim_card)
	await seconds(1.0)  # both see each other's aim before either plays
	await click(views(EnumView.ENEMY)[0] as Control)
	await wait_for(func() -> bool: return _played == 1 and _friend_played == 1, 10.0, "both cards played")
	await shot("c03_both_played")
	step("both played a card")

	var round: int = Unified.data.run.round
	await click(find(current_scene, ^"%EndTurn") as Control)
	await wait_for(func() -> bool: return Unified.data.run.round > round and Unified.data.run.phase == EnumPhase.HEROES,
		15.0, "the enemies act, the next round")
	step("round %d" % Unified.data.run.round)


func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state != UnifiedSession.EVENT_CONFIRMED or not event is EventCardPlayed:
		return
	if (event as EventCardPlayed).hero == Unified.data.run.local_hero:
		_played += 1
	else:
		_friend_played += 1


func _heroes_in_run() -> int:
	var count := 0
	for row: DataHeroRow in Unified.data.heroes.heroes:
		count += 1 if row.in_run else 0
	return count


## The other hero in the run (null: none).
func _friend_row() -> DataHeroRow:
	for row: DataHeroRow in Unified.data.heroes.heroes:
		if row.in_run and not row.local:
			return row
	return null
