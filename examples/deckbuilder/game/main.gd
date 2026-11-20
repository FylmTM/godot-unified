extends Control
## The table: the session, the board (the session's view_root: the enemies' row, the heroes' panels and hands, the
## local hand), the phase's panel (camp, map, reward, rest, the run's end) and the play itself. A card is played by
## clicking it, then its target (an enemy, or a hero's panel for an ally card; Hand Off: the card to hand, then the
## ally); a card with no target plays at once. What the player holds up and at whom is their aim (Unified.input), which
## every ally sees. The save follows the session's save_changed into user://.

const SAVE_PATH := "user://deckbuilder_save.json"
const LAN_PORT := 7400
const LOG_LINES := 2

var _selected: DeckCard
var _extra: DeckCard  # Hand Off: the card it hands
var _log: Array[String] = []
var _panel_shown := ""  # what the phase's panel shows now: it is rebuilt only when that changes

@onready var session: UnifiedSession = %UnifiedSession
@onready var _status: Label = %Status
@onready var _hint: Label = %Hint
@onready var _end_turn: Button = %EndTurn
@onready var _overlay: Control = %Overlay
@onready var _title: Label = %Title
@onready var _body: VBoxContainer = %Body
@onready var _log_label: Label = %Log


func _ready() -> void:
	add_to_group(&"table")
	(%LocalHand as Node).add_to_group(&"hand_local")
	session.view_root = %Board
	session.sim_event.connect(_on_sim_event)
	session.save_changed.connect(_on_save_changed)
	session.roster_changed.connect(_refresh)
	Unified.data.run.changed.connect(_refresh)
	Unified.data.heroes.changed.connect(_refresh)
	_end_turn.pressed.connect(_on_end_turn)
	if not session.running:
		session.start_single()
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	var press := event as InputEventMouseButton
	if event.is_action_pressed(&"ui_cancel") or (press != null and press.pressed and press.button_index == MOUSE_BUTTON_RIGHT):
		_select(null)


# --- playing cards (the views call these through the "table" group)


func card_clicked(card: DeckCard) -> void:
	if not card.is_local():
		return
	if _selected != null and _selected.id == EnumCardId.HAND_OFF and card != _selected:
		_extra = card
		_hint.text = "Hand Off: now click the ally to give %s to" % _card_name(card.id)
		return
	if not card.playable:
		_hint.text = "Not now: not your turn, ended, or not enough energy"
		return
	match card.target:
		EnumTargetKind.SELF, EnumTargetKind.ALL_ENEMIES:
			_play(card, 0, 0)
		_:
			_select(card)


func enemy_clicked(enemy: DeckEnemy) -> void:
	if _selected != null and _selected.target == EnumTargetKind.ENEMY:
		_play(_selected, enemy.marker.key, 0)


func enemy_hovered(enemy: DeckEnemy) -> void:
	if _selected != null and _selected.target == EnumTargetKind.ENEMY:
		Unified.input.enemy = enemy.index + 1


func hero_clicked(index: int) -> void:
	if _selected == null or _selected.target != EnumTargetKind.ALLY:
		return
	if _selected.id == EnumCardId.HAND_OFF and _extra == null:
		_hint.text = "Hand Off: first click the card to hand over"
		return
	_play(_selected, 0, index + 1)


func hero_hovered(index: int) -> void:
	if _selected != null and _selected.target == EnumTargetKind.ALLY:
		Unified.input.hero = index + 1


## Holds a card up (its aim reaches every ally), or puts it down (null).
func _select(card: DeckCard) -> void:
	if _selected != null and is_instance_valid(_selected):
		_selected.selected = false
	_selected = card
	_extra = null
	Unified.input.card = card.slot + 1 if card != null else 0
	Unified.input.enemy = 0
	Unified.input.hero = 0
	if card != null:
		card.selected = true
		_hint.text = "%s: click %s (right click: put it down)" % [_card_name(card.id),
			"an enemy" if card.target == EnumTargetKind.ENEMY else "a hero"]
	else:
		_hint.text = ""


func _play(card: DeckCard, enemy: int, ally: int) -> void:
	var play := CommandPlayCard.new()
	play.card = card.key()
	play.enemy = enemy
	play.ally = ally
	play.extra = _extra.key() if _extra != null and is_instance_valid(_extra) else 0
	session.send_command(play)
	_select(null)


func _on_end_turn() -> void:
	var local := Unified.data.run.local_hero
	if local < 0:
		return
	var end := CommandEndTurn.new()
	end.ready = not (Unified.data.heroes.heroes[local] as DataHeroRow).ready  # a value, not a toggle
	session.send_command(end)


# --- what the table shows


func _refresh() -> void:
	var run := Unified.data.run
	_status.text = _status_text(run)
	var local := run.local_hero
	var fighting := run.phase == EnumPhase.HEROES or run.phase == EnumPhase.ENEMIES
	_end_turn.visible = fighting and local >= 0
	if local >= 0:
		var done := (Unified.data.heroes.heroes[local] as DataHeroRow).ready
		_end_turn.text = "Play on" if done else "End turn"
		_end_turn.disabled = run.phase != EnumPhase.HEROES
	if not fighting and _selected != null:
		_select(null)
	_show_panel(run)


func _status_text(run: DataRun) -> String:
	match run.phase:
		EnumPhase.CAMP:
			return "Camp"
		EnumPhase.OVER:
			return "The run is over"
	var where := "Floor %d of %d" % [run.floor + 1, Unified.constants.floors] if run.floor != 255 else "The act"
	match run.phase:
		EnumPhase.HEROES:
			return "%s - %s, round %d - your turn" % [where, EnumNodeKind.name(run.node).capitalize(), run.round]
		EnumPhase.ENEMIES:
			return "%s - %s, round %d - the enemies act" % [where, EnumNodeKind.name(run.node).capitalize(), run.round]
		EnumPhase.MAP:
			return "%s - vote for the next node" % where
		EnumPhase.REWARD:
			return "%s - rewards" % where
		EnumPhase.REST:
			return "%s - rest" % where
	return where


## The phase's panel, rebuilt only when what it shows changes: a rebuild between a press and its release loses the
## click.
func _show_panel(run: DataRun) -> void:
	var key := _panel_key(run)
	if key == _panel_shown:
		return
	_panel_shown = key
	for child in _body.get_children():
		child.queue_free()
	_overlay.visible = true
	match run.phase:
		EnumPhase.CAMP:
			_camp_panel()
		EnumPhase.MAP:
			_map_panel(run)
		EnumPhase.REWARD:
			_reward_panel(run)
		EnumPhase.REST:
			_rest_panel(run)
		EnumPhase.OVER:
			_title.text = "Victory!" if run.won else "The party fell"
			_label("Back to the camp in a moment.")
		_:
			_overlay.visible = false


## What the phase's panel shows (the camp's buttons depend on nothing the session sends).
func _panel_key(run: DataRun) -> String:
	match run.phase:
		EnumPhase.CAMP:
			return "camp"
		EnumPhase.MAP:
			return "map|%d|%d|%s|%s" % [run.floor, run.lane, run.votes, run.can_go]
		EnumPhase.REWARD:
			return "reward|%d|%s|%s" % [run.floor, run.picked, run.offers]
		EnumPhase.REST:
			return "rest|%d|%s|%d" % [run.floor, run.picked, run.deck_count]
		EnumPhase.OVER:
			return "over|%s" % run.won
	return ""


func _camp_panel() -> void:
	_title.text = "The camp"
	_label("Start a run with everyone here (others join with uni coop, or on the LAN).")
	_button("Start a run", func() -> void: session.send_command(CommandStartRun.new()))
	var saved := _saved_run()
	if saved != "":
		var problem := UnifiedSetup.json_problem(saved)
		if problem == "":
			var setup := UnifiedSetup.from_json(saved)
			_button("Continue the saved run (floor %d)" % (setup.floor + 1), func() -> void: _continue(saved))
		else:
			_label("The saved run does not read on this build: %s" % problem)
	var row := HBoxContainer.new()
	_body.add_child(row)
	for hero_class: int in [EnumHeroClass.VANGUARD, EnumHeroClass.ARCANIST]:
		var pick := Button.new()
		pick.text = EnumHeroClass.name(hero_class).capitalize()
		pick.toggle_mode = true
		pick.button_pressed = Unified.profile.hero_class == hero_class
		pick.focus_mode = Control.FOCUS_NONE
		pick.pressed.connect(_choose_class.bind(hero_class))
		row.add_child(pick)
	if session.mode == UnifiedSession.MODE_SINGLE:
		_button("Open to the LAN (port %d)" % LAN_PORT, func() -> void: session.open_direct(LAN_PORT))


func _map_panel(run: DataRun) -> void:
	_title.text = "Where next?"
	var grid := GridContainer.new()
	grid.columns = 3
	_body.add_child(grid)
	var lanes := Unified.constants.lanes
	for row in range(Unified.constants.floors - 1, -1, -1):
		for lane in lanes:
			var node: int = run.map_nodes[row * lanes + lane]
			var cell := Button.new()
			cell.custom_minimum_size = Vector2(130, 30)
			cell.focus_mode = Control.FOCUS_NONE
			cell.text = EnumNodeKind.name(node).capitalize() if node != EnumNodeKind.NONE else ""
			var next := 0 if run.floor == 255 else run.floor + 1
			var here := row == run.floor and lane == run.lane
			cell.disabled = not (row == next and run.can_go[lane])
			if row == next and run.votes[lane] > 0:
				cell.text += " (%d)" % run.votes[lane]
			if here:
				cell.text = "> " + cell.text + " <"
			cell.pressed.connect(_vote.bind(lane))
			grid.add_child(cell)


func _reward_panel(run: DataRun) -> void:
	_title.text = "Choose a card"
	if run.picked:
		_label("Waiting for the others to choose.")
		return
	for offer in run.offer_count:
		var id: int = run.offers[offer]
		_button("%s: %s" % [_card_name(id), (Unified.constants.cards[id] as DataCardText).text], _pick.bind(offer))
	_button("Skip", _pick.bind(255))


func _rest_panel(run: DataRun) -> void:
	_title.text = "Rest"
	if run.picked:
		_label("Waiting for the others to rest.")
		return
	_button("Heal", _rest.bind(EnumRestChoice.HEAL, 0))
	_label("or upgrade a card:")
	var flow := HFlowContainer.new()
	flow.custom_minimum_size = Vector2(560, 0)
	_body.add_child(flow)
	for k in run.deck_count:
		var card: DataDeckCard = run.deck[k]
		if card.upgraded:
			continue
		var upgrade := Button.new()
		upgrade.text = _card_name(card.id)
		upgrade.tooltip_text = (Unified.constants.cards[card.id] as DataCardText).upgraded
		upgrade.focus_mode = Control.FOCUS_NONE
		upgrade.pressed.connect(_rest.bind(EnumRestChoice.UPGRADE, card.card))
		flow.add_child(upgrade)


func _label(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(400, 0)
	_body.add_child(label)


func _button(text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	_body.add_child(button)


func _vote(lane: int) -> void:
	var vote := CommandVote.new()
	vote.lane = lane
	session.send_command(vote)


func _pick(offer: int) -> void:
	var pick := CommandPickReward.new()
	pick.offer = offer
	session.send_command(pick)


func _rest(choice: int, card: int) -> void:
	var rest := CommandRest.new()
	rest.choice = choice
	rest.card = card
	session.send_command(rest)


func _choose_class(hero_class: int) -> void:
	Unified.profile.hero_class = hero_class
	_panel_shown = ""
	if session.mode == UnifiedSession.MODE_SINGLE:  # nobody else here: the session starts again with the new class
		session.start_single()
	else:
		_refresh()


func _card_name(id: int) -> String:
	return EnumCardId.name(id).capitalize()


# --- the save


func _saved_run() -> String:
	if not FileAccess.file_exists(SAVE_PATH):
		return ""
	return FileAccess.get_file_as_string(SAVE_PATH)


func _continue(saved: String) -> void:
	session.start_single(UnifiedSetup.from_json(saved))  # the camp's session ends first


## Every player keeps the save (any of them can host the run's continuation); the run's end clears it.
func _on_save_changed(setup: UnifiedSetup) -> void:
	if setup.version == 0:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
		return
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(setup.to_json())


# --- the log and the heroes' flashes


func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state == UnifiedSession.EVENT_EMITTED:
		_flash_hero(event)
	if state != UnifiedSession.EVENT_CONFIRMED:
		return
	if event is EventPlayRefused:
		var refused := event as EventPlayRefused
		if refused.hero == Unified.data.run.local_hero:
			_say("Refused: %s" % ["not now", "not in your hand", "not enough energy", "the target is gone",
				"their hand is full"][refused.reason])
	elif event is EventCardPlayed:
		var played := event as EventCardPlayed
		if played.hero != Unified.data.run.local_hero:
			_say("%s plays %s" % [_hero_name(played.hero), _card_name(played.played)])
	elif event is EventNodeEntered:
		var entered := event as EventNodeEntered
		_say("Floor %d: %s" % [entered.floor + 1, EnumNodeKind.name(entered.node).capitalize()])
	elif event is EventRelicGained:
		var relic := event as EventRelicGained
		_say("%s finds the %s: %s" % [_hero_name(relic.hero), EnumRelic.name(relic.relic).capitalize(),
			Unified.constants.relics[relic.relic]])
	elif event is EventHeroDown:
		_say("%s is down" % _hero_name((event as EventHeroDown).hero))


func _flash_hero(event: UnifiedEvent) -> void:
	var hero := -1
	var color := Color.WHITE
	if event is EventHeroHit:
		hero = (event as EventHeroHit).hero
		color = Color(1.6, 0.6, 0.6)
	elif event is EventHeroBlocked:
		hero = (event as EventHeroBlocked).hero
		color = Color(0.7, 0.9, 1.6)
	elif event is EventHeroHealed:
		hero = (event as EventHeroHealed).hero
		color = Color(0.7, 1.6, 0.7)
	if hero >= 0:
		(get_node("%%Board/Heroes/Hero%d" % hero) as HeroPanel).flash(color)


func _hero_name(hero: int) -> String:
	var row: DataHeroRow = Unified.data.heroes.heroes[hero]
	var player_name := session.get_player_name(row.player)
	return player_name if player_name != "" else "Hero %d" % (hero + 1)


func _say(line: String) -> void:
	_log.append(line)
	if _log.size() > LOG_LINES:
		_log.pop_front()
	_log_label.text = "\n".join(_log)
