extends Control
## The play scene (Game.PLAY_SCENE): the table on its felt. The board is the session's view_root: the enemies' row, the
## heroes' panels with their open hands, and the local hero's fanned hand, with their energy and End turn beside it.
## Over it, the phase's panel: the camp (pick a class, start or continue a run, invite friends), the map, the reward,
## the rest and the run's end. The session is the Game autoload's; the menus start and end it, and the pause menu
## (Esc) leaves, invites friends and opens the settings; the session panel top-right shows who is here and the code.
##
## A card is played by clicking it, then its target (an enemy, or a hero's panel for an ally card; Hand Off: the card to
## hand, then the ally); a card with no target plays at once. What the player holds up and at whom is their aim
## (Unified.input), which every ally sees; the targets it can go to light up. Right click or Esc puts it down.

const LOG_LINES := 3

var _selected: DeckCard
var _extra: DeckCard  # Hand Off: the card it hands
var _log: Array[String] = []
var _panel_shown := ""  # what the phase's panel shows now: it is rebuilt only when that changes
var _phase := -1  # the phase the banners last announced
var _session_panel: SessionPanel

@onready var _status: Label = %Status
@onready var _hint: Label = %Hint
@onready var _end_turn: Button = %EndTurn
@onready var _energy: EnergyOrb = %Energy
@onready var _overlay: Control = %Overlay
@onready var _title: Label = %Title
@onready var _body: VBoxContainer = %Body
@onready var _log_label: Label = %Log
@onready var _banner: Banner = %Banner


func _ready() -> void:
	add_to_group(&"table")
	(%LocalHand as Node).add_to_group(&"hand_local")
	_session_panel = SessionPanel.new()
	add_child(_session_panel)
	move_child(_session_panel, ($PauseMenu as Node).get_index())
	var session := Unified.session
	session.view_root = %Board
	session.sim_event.connect(_on_sim_event)
	session.roster_changed.connect(_refresh)
	session.join_code_changed.connect(_refresh.unbind(1))
	session.mode_changed.connect(_refresh.unbind(2))
	Unified.data.run.changed.connect(_refresh)
	Unified.data.heroes.changed.connect(_refresh)
	_end_turn.pressed.connect(_on_end_turn)
	_refresh()


## Esc puts a held card down before the pause menu sees it.
func _input(event: InputEvent) -> void:
	if _selected != null and event.is_action_pressed(&"ui_cancel"):
		_select(null)
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	var press := event as InputEventMouseButton
	if press != null and press.pressed and press.button_index == MOUSE_BUTTON_RIGHT:
		_select(null)


# --- playing cards (the views call these through the "table" group)


func card_clicked(card: DeckCard) -> void:
	if not card.is_local():
		return
	if _selected != null and _selected.data.id == EnumCardId.HAND_OFF and card != _selected:
		_extra = card
		_hint.text = "Hand Off: now click the ally to give %s to" % _card_name(card.data.id)
		return
	if card == _selected:
		_select(null)
		return
	if not card.data.playable:
		_hint.text = "Not now: not your turn, ended, or not enough energy"
		Sfx.play(&"refused")
		return
	match card.data.target:
		EnumTargetKind.SELF, EnumTargetKind.ALL_ENEMIES:
			_play(card, 0, 0)
		_:
			_select(card)


## A whisper of the card under the mouse, when the local hero could play it.
func card_hovered(card: DeckCard) -> void:
	if card.is_local() and card.data.playable:
		Sfx.play(&"draw", -10.0, 1.4)


func enemy_clicked(enemy: DeckEnemy) -> void:
	if _selected != null and _selected.data.target == EnumTargetKind.ENEMY:
		_play(_selected, enemy.marker.key, 0)


func enemy_hovered(enemy: DeckEnemy) -> void:
	if _selected != null and _selected.data.target == EnumTargetKind.ENEMY:
		Unified.input.enemy = enemy.data.index + 1


func hero_clicked(index: int) -> void:
	if _selected == null or _selected.data.target != EnumTargetKind.ALLY:
		return
	if _selected.data.id == EnumCardId.HAND_OFF and _extra == null:
		_hint.text = "Hand Off: first click the card to hand over"
		return
	_play(_selected, 0, index + 1)


func hero_hovered(index: int) -> void:
	if _selected != null and _selected.data.target == EnumTargetKind.ALLY:
		Unified.input.hero = index + 1


## Holds a card up (its aim reaches every ally), or puts it down (null); its targets light up.
func _select(card: DeckCard) -> void:
	if _selected != null and is_instance_valid(_selected):
		_selected.selected = false
	_selected = card
	_extra = null
	Unified.input.card = card.data.slot + 1 if card != null else 0
	Unified.input.enemy = 0
	Unified.input.hero = 0
	var target: int = card.data.target if card != null else -1
	for node in get_tree().get_nodes_in_group(&"enemies"):
		(node as DeckEnemy).targetable = target == EnumTargetKind.ENEMY
	for hero in 4:
		_hero_panel(hero).targetable = target == EnumTargetKind.ALLY
	if card != null:
		card.selected = true
		Sfx.play(&"pick")
		_hint.text = "%s: click %s  (right click: put it down)" % [_card_name(card.data.id),
			"an enemy" if target == EnumTargetKind.ENEMY else "a hero"]
	else:
		_hint.text = ""


func _play(card: DeckCard, enemy: int, ally: int) -> void:
	var play := CommandPlayCard.new()
	play.card = card.key()
	play.enemy = enemy
	play.ally = ally
	play.extra = _extra.key() if _extra != null and is_instance_valid(_extra) else 0
	Unified.session.send_command(play)
	Sfx.play(&"play")
	_select(null)


func _on_end_turn() -> void:
	var local := Unified.data.run.local_hero
	if local < 0:
		return
	Sfx.play(&"click")
	var end := CommandEndTurn.new()
	end.ready = not (Unified.data.heroes.heroes[local] as DataHeroRow).ready  # a value, not a toggle
	Unified.session.send_command(end)


# --- what the table shows


func _refresh() -> void:
	var run := Unified.data.run
	_status.text = _status_text(run)
	var local := run.local_hero
	var fighting := run.phase == EnumPhase.HEROES or run.phase == EnumPhase.ENEMIES
	_end_turn.visible = fighting and local >= 0
	_energy.visible = fighting and local >= 0
	if local >= 0:
		var hero: DataHeroRow = Unified.data.heroes.heroes[local]
		_end_turn.text = "Play on" if hero.ready else "End turn"
		_end_turn.disabled = run.phase != EnumPhase.HEROES
		_energy.show_hero(hero)
	if not fighting and _selected != null:
		_select(null)
	_announce(run)
	_show_panel(run)
	_session_panel.refresh(_session_rows(), run.phase == EnumPhase.CAMP, "Anyone here can start the run.")


func _status_text(run: DataRun) -> String:
	match run.phase:
		EnumPhase.CAMP:
			return "The camp"
		EnumPhase.OVER:
			return "The run is over"
	var where := "Floor %d of %d" % [run.floor + 1, Unified.constants.floors] if run.floor != 255 else "The act"
	match run.phase:
		EnumPhase.HEROES, EnumPhase.ENEMIES:
			return "%s  ·  %s  ·  round %d" % [where, EnumNodeKind.name(run.node).capitalize(), run.round]
		EnumPhase.MAP:
			return "%s  ·  the map" % where
		EnumPhase.REWARD:
			return "%s  ·  spoils" % where
		EnumPhase.REST:
			return "%s  ·  the campfire" % where
	return where


## A banner (and its sound) as the fight's turns change hands: the heroes' turn, the enemies'.
func _announce(run: DataRun) -> void:
	if run.phase == _phase:
		return
	var before := _phase
	_phase = run.phase
	if before < 0:
		return
	match run.phase:
		EnumPhase.HEROES:
			_banner.show_message("Your turn", UiTheme.GOLD, 0.8)
			Sfx.play(&"turn")
		EnumPhase.ENEMIES:
			_banner.show_message("The enemies act", UiTheme.BAD, 0.8)


## The phase's panel, rebuilt only when what it shows changes: a rebuild between a press and its release loses the
## click.
func _show_panel(run: DataRun) -> void:
	var key := _panel_key(run)
	if key == _panel_shown:
		return
	_panel_shown = key
	for child in _body.get_children():
		_body.remove_child(child)
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
			_label("Back to the camp in a moment.", true)
		_:
			_overlay.visible = false


## What the phase's panel shows (the camp's: how the session runs, and the class).
func _panel_key(run: DataRun) -> String:
	match run.phase:
		EnumPhase.CAMP:
			var session := Unified.session
			return "camp|%d|%d|%s|%d|%s" % [session.status, session.mode, session.join_code, Unified.profile.hero_class,
				Game.saved_run() != ""]
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
	var session := Unified.session
	_title.text = "The camp"
	_label("Choose your class, then set out together.", true)
	var classes := HBoxContainer.new()
	classes.alignment = BoxContainer.ALIGNMENT_CENTER
	_body.add_child(classes)
	for hero_class: int in [EnumHeroClass.VANGUARD, EnumHeroClass.ARCANIST]:
		var pick := Button.new()
		pick.name = EnumHeroClass.name(hero_class).capitalize()
		pick.text = pick.name
		pick.toggle_mode = true
		pick.custom_minimum_size = Vector2(190, 0)
		pick.button_pressed = Unified.profile.hero_class == hero_class
		pick.tooltip_text = ("Shields the party and hits hard." if hero_class == EnumHeroClass.VANGUARD
			else "Weakens the enemies and feeds the party energy.")
		pick.focus_mode = Control.FOCUS_NONE
		pick.pressed.connect(_choose_class.bind(hero_class))
		classes.add_child(pick)
	var start := _button("Start a run", func() -> void: Unified.session.send_command(CommandStartRun.new()))
	start.theme_type_variation = &"PrimaryButton"
	if session.mode == UnifiedSession.MODE_SINGLE:  # a host's restart would end it for the others
		var saved := Game.saved_run()
		if saved != "":
			var problem := UnifiedSetup.json_problem(saved)
			if problem == "":
				var setup := UnifiedSetup.from_json(saved)
				_button("Continue the saved run (floor %d)" % (setup.floor + 1), Game.continue_run)
			else:
				_label("The saved run does not read on this build: %s" % problem)
	match session.mode:
		UnifiedSession.MODE_SINGLE:
			_button("Invite friends", Game.invite_friends)
		UnifiedSession.MODE_HOST_ONLINE, UnifiedSession.MODE_HOST_DIRECT:
			_label("Friends join with the %s at the top right." % ("lobby code"
				if session.mode == UnifiedSession.MODE_HOST_ONLINE else "address") if session.join_code != ""
				else "Opening the camp to friends...", true)
		_:
			_label("You are in a friend's camp.", true)


func _map_panel(run: DataRun) -> void:
	_title.text = "Where next?"
	_label("Vote for the next node. The party goes where most of you do.", true)
	var map := MapView.new()
	map.name = &"Map"
	map.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	map.voted.connect(_vote)
	_body.add_child(map)
	map.show_run(run)


func _reward_panel(run: DataRun) -> void:
	_title.text = "Spoils of the fight"
	if run.picked:
		_label("Waiting for the others to choose.", true)
		return
	_label("Take a card into your deck.", true)
	var row := HBoxContainer.new()
	row.name = &"Offers"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override(&"separation", 18)
	_body.add_child(row)
	for offer in run.offer_count:
		var id: int = run.offers[offer]
		row.add_child(_card_button(id, false, _pick.bind(offer)))
	_button("Skip", _pick.bind(255))


func _rest_panel(run: DataRun) -> void:
	_title.text = "The campfire"
	if run.picked:
		_label("Waiting for the others to rest.", true)
		return
	var heal := _button("Rest and heal", _rest.bind(EnumRestChoice.HEAL, 0))
	heal.theme_type_variation = &"PrimaryButton"
	_label("or sharpen a card (shown upgraded):", true)
	var flow := HFlowContainer.new()
	flow.name = &"Upgrades"
	flow.custom_minimum_size = Vector2(720, 0)
	flow.alignment = FlowContainer.ALIGNMENT_CENTER
	flow.add_theme_constant_override(&"h_separation", 8)
	flow.add_theme_constant_override(&"v_separation", 8)
	_body.add_child(flow)
	for k in run.deck_count:
		var card: DataDeckCard = run.deck[k]
		if card.upgraded:
			continue
		flow.add_child(_card_button(card.id, true, _rest.bind(EnumRestChoice.UPGRADE, card.card), 0.62))


## A card to choose (a reward, an upgrade): its face, lifting under the mouse; a click chooses it.
func _card_button(id: int, upgraded: bool, action: Callable, scale_by := 1.0) -> Button:
	var button := Button.new()
	button.name = EnumCardId.name(id).capitalize().replace(" ", "")
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = DeckCard.BIG * scale_by
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.tooltip_text = (Unified.constants.cards[id] as DataCardText).upgraded if upgraded else ""
	for state: StringName in [&"normal", &"hover", &"pressed", &"hover_pressed", &"focus"]:
		button.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	var face := CardFace.new()
	face.size = button.custom_minimum_size
	face.pivot_offset = Vector2(face.size.x * 0.5, face.size.y)
	button.add_child(face)
	face.show_card(id, upgraded)
	button.mouse_entered.connect(func() -> void:
		face.highlighted = true
		face.create_tween().tween_property(face, ^"position:y", -10.0, 0.08))
	button.mouse_exited.connect(func() -> void:
		face.highlighted = false
		face.create_tween().tween_property(face, ^"position:y", 0.0, 0.08))
	button.pressed.connect(func() -> void:
		Sfx.play(&"click")
		action.call())
	return button


func _label(text: String, centred := false) -> void:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"Dim"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(420, 0)
	if centred:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_body.add_child(label)


func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(func() -> void:
		Sfx.play(&"click")
		action.call())
	_body.add_child(button)
	return button


func _vote(lane: int) -> void:
	Sfx.play(&"click")
	var vote := CommandVote.new()
	vote.lane = lane
	Unified.session.send_command(vote)


func _pick(offer: int) -> void:
	var pick := CommandPickReward.new()
	pick.offer = offer
	Unified.session.send_command(pick)


func _rest(choice: int, card: int) -> void:
	var rest := CommandRest.new()
	rest.choice = choice
	rest.card = card
	Unified.session.send_command(rest)


func _choose_class(hero_class: int) -> void:
	_panel_shown = ""
	Game.choose_class(hero_class)
	_refresh()


func _card_name(id: int) -> String:
	return EnumCardId.name(id).capitalize()


func _hero_panel(hero: int) -> HeroPanel:
	return get_node("%%Board/Heroes/Hero%d" % hero) as HeroPanel


## The session panel's rows: who is here, and whether their hero ended their turn.
func _session_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for player: int in Unified.session.get_players():
		var status := ""
		for hero in 4:
			var row: DataHeroRow = Unified.data.heroes.heroes[hero]
			if row.in_run and row.player == player:
				status = EnumHeroClass.name(row.hero_class).capitalize() + (", ready" if row.ready else "")
		rows.append({"player": player, "name": Unified.session.get_player_name(player), "status": status})
	return rows


# --- the log, the sounds, the heroes' flashes


func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state == UnifiedSession.EVENT_EMITTED:
		_react(event)
	if state != UnifiedSession.EVENT_CONFIRMED:
		return
	if event is EventPlayRefused:
		var refused := event as EventPlayRefused
		if refused.hero == Unified.data.run.local_hero:
			Sfx.play(&"refused")
			_say("Refused: %s" % ["not now", "not in your hand", "not enough energy", "the target is gone",
				"their hand is full"][refused.reason])
	elif event is EventCardPlayed:
		var played := event as EventCardPlayed
		if played.hero != Unified.data.run.local_hero:
			_say("%s plays %s" % [_hero_name(played.hero), _card_name(played.played)])
	elif event is EventRunStarted:
		Sfx.play(&"start")
	elif event is EventNodeEntered:
		var entered := event as EventNodeEntered
		var kind := EnumNodeKind.name(entered.node).capitalize()
		_say("Floor %d: %s" % [entered.floor + 1, kind])
		if entered.node in [EnumNodeKind.ELITE, EnumNodeKind.BOSS]:  # a fight's own banner is its first turn
			_banner.show_message(kind, UiTheme.BAD, 0.9)
	elif event is EventFightWon:
		Sfx.play(&"reward")
	elif event is EventRelicGained:
		var relic := event as EventRelicGained
		Sfx.play(&"relic")
		_say("%s finds the %s: %s" % [_hero_name(relic.hero), EnumRelic.name(relic.relic).capitalize(),
			Unified.constants.relics[relic.relic]])
	elif event is EventHeroDown:
		_say("%s is down" % _hero_name((event as EventHeroDown).hero))
	elif event is EventRunOver:
		var won := (event as EventRunOver).won
		Sfx.play(&"won" if won else &"over")
		_banner.show_message("Victory!" if won else "The party fell", UiTheme.GOLD if won else UiTheme.BAD, 2.5)


## At once, as predicted: the sounds of the fight and the heroes' flashes (an event a rollback cancels has played).
func _react(event: UnifiedEvent) -> void:
	var hero := -1
	var color := Color.WHITE
	if event is EventHeroHit:
		var hit := event as EventHeroHit
		hero = hit.hero
		color = Color(1.7, 0.6, 0.55)
		Sfx.play(&"hurt" if hero == Unified.data.run.local_hero else &"hit")
	elif event is EventHeroBlocked:
		hero = (event as EventHeroBlocked).hero
		color = Color(0.7, 0.9, 1.7)
		Sfx.play(&"block")
	elif event is EventHeroHealed:
		hero = (event as EventHeroHealed).hero
		color = Color(0.7, 1.7, 0.7)
		Sfx.play(&"heal")
	elif event is EventEnemyHit:
		Sfx.play(&"hit" if (event as EventEnemyHit).amount > 0 else &"blocked")
	elif event is EventEnemyDied:
		Sfx.play(&"die")
	elif event is EventEnemyActed:
		Sfx.play(&"enemy")
	elif event is EventCardDrawn:
		Sfx.play(&"draw", -6.0)
	if hero >= 0:
		_hero_panel(hero).flash(color)


func _hero_name(hero: int) -> String:
	var row: DataHeroRow = Unified.data.heroes.heroes[hero]
	var player_name := Unified.session.get_player_name(row.player)
	return player_name if player_name != "" else "Hero %d" % (hero + 1)


func _say(line: String) -> void:
	_log.append(line)
	if _log.size() > LOG_LINES:
		_log.pop_front()
	_log_label.text = "\n".join(_log)
