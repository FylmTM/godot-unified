extends CanvasLayer
## The in-game HUD: the local hero's card (HP, XP, level), the wave, time, enemies and kills, the session panel and
## controls list, banners, the level-up choice and the overrun panel. It follows the session data (`Unified.data.hud`,
## simulation/extension/hud.odin) when it changes, the roster for names and the input device for key labels;
## `_process` only animates. In-game buttons never take focus: the level-up keys and pad buttons pick.

## The level-up picks by card: the oldest pending level-up's three offers, in their order.
const PICKS: Array[StringName] = [&"levelup_1", &"levelup_2", &"levelup_3"]
## A stick's directions, one control in the controls list (ControlsPanel.refresh).
const MOVE: Array[StringName] = [&"move_forward", &"move_left", &"move_back", &"move_right"]
## The level-up panel stays up this long after a pick, so the picked card can be seen.
const PICK_HOLD_S := 0.35
## How long a sent pick may take to show in the HUD data before another is taken (one the sim refused never shows).
const PICK_WAIT_S := 1.0
## Below this share of HP the screen's edges pulse red.
const LOW_HP_SHARE := 0.3

var _time_s := 0.0
var _last_phase := EnumPhase.MATCH
var _last_wave := 0
var _last_hp := -1
var _last_xp := -1
var _named_slot := -1
## The red edges: the hurt flash (0..0.6, decaying) and the low-HP pulse's strength (0: none).
var _hurt := 0.0
var _low_hp := 0.0
var _choosing := false
var _hold_until := 0.0
## The pending level-ups when the last pick was sent (-1: none waits): no other pick until the HUD data shows fewer,
## so a double press can't spend the next level-up, and a press within the hold can't pick from the next level's cards.
var _picked_at_pending := -1
var _pick_wait_until := 0.0
## The upgrades the cards show (EnumUpgrade values, by card), while choosing.
var _offers: Array[int] = []

@onready var _root: Control = $Root
@onready var _vignette: ShaderMaterial = (%Vignette as ColorRect).material as ShaderMaterial
@onready var _player_name: Label = %PlayerName
@onready var _level: Label = %Level
@onready var _hp: ProgressBar = %HP
@onready var _hp_fill: StyleBoxFlat = _hp.get_theme_stylebox(&"fill") as StyleBoxFlat
@onready var _hp_text: Label = %HPText
@onready var _xp: ProgressBar = %XP
@onready var _xp_text: Label = %XPText
@onready var _wave: Label = %Wave
@onready var _time: Label = %Time
@onready var _enemies: Label = %Enemies
@onready var _respawn: Label = %Respawn
@onready var _banner: Banner = %Banner
@onready var _notice: Banner = %Notice
@onready var _levelup: Control = %LevelUp
@onready var _pending: Label = %Pending
@onready var _options: Control = %Options
@onready var _over: Control = %GameOver
@onready var _over_panel: Control = %OverPanel
@onready var _survived: Label = %Survived
@onready var _stats: Label = %Stats
@onready var _best: Label = %Best
@onready var _back: Label = %Back
@onready var _menu_hint: Label = %MenuHint
@onready var _session: SessionPanel = %Session
@onready var _controls: ControlsPanel = %Controls


func _ready() -> void:
	for i in _options.get_child_count():
		(_options.get_child(i) as Button).pressed.connect(_choose.bind(i))
	(%Leave as Button).pressed.connect(func() -> void:
		Sfx.play(&"click")
		Game.leave_to_menu())
	Unified.data.hud.changed.connect(_on_hud_changed)
	Unified.session.roster_changed.connect(_on_roster_changed)
	Unified.session.sim_event.connect(_on_sim_event)
	Game.input_device_changed.connect(func(_pad: bool) -> void: _label_keys())
	Unified.session.join_code_changed.connect(func(_code: String) -> void: _show_session())
	_root.resized.connect(_show_controls)  # the controls list places itself in the window's corner
	_best.text = ""
	_label_keys()
	_on_hud_changed()


func _process(delta: float) -> void:
	_time_s += delta
	_hurt = maxf(_hurt - delta * 2.5, 0.0)
	var low := (0.25 + 0.15 * sin(_time_s * 6.0)) * _low_hp
	_vignette.set_shader_parameter(&"intensity", clampf(maxf(_hurt, low), 0.0, 0.6))
	_levelup.visible = _choosing or _time_s < _hold_until
	if _over.visible:
		var left := ceilf(Unified.data.hud.reset_in_s)
		_back.text = "The arena resets in %d" % int(left) if left >= 1.0 else "The arena resets"
		_back.modulate.a = 0.6 + 0.4 * sin(_time_s * 4.0)


## The level-up keys and pad buttons pick while choosing, not while game input is off (the pause menu, the dev UI).
func _unhandled_input(event: InputEvent) -> void:
	if not _choosing or not Unified.session.game_input:
		return
	for i in PICKS.size():
		if event.is_action_pressed(PICKS[i]):
			get_viewport().set_input_as_handled()
			_choose(i)
			return


func _on_hud_changed() -> void:
	var hud := Unified.data.hud
	var me := _local_hero()
	var playing := hud.phase == EnumPhase.MATCH
	var alive := me != null and me.alive
	if me != null:
		_show_hero(me, playing)
	if not alive:
		_hurt = 0.0
		_low_hp = 0.0

	_wave.text = "WAVE %d" % hud.wave
	_time.text = UiTheme.clock(hud.time_s)
	_enemies.text = "%d %s  ·  %d kills" % [hud.enemies, "enemy" if hud.enemies == 1 else "enemies", hud.kills]
	_respawn.visible = playing and me != null and not alive
	if _respawn.visible:
		_respawn.text = "Back up in %.1f s" % me.respawn_s

	var pending := me.pending_levelups if me != null else 0
	var choosing := pending > 0 and playing and alive
	if not choosing or pending < _picked_at_pending:
		_picked_at_pending = -1  # the pick is in (or there is nothing to pick)
	if choosing:
		_show_offers(me)
	if choosing and not _levelup.visible:
		_pop_levelup()
	if choosing != _choosing:
		_choosing = choosing
		_show_controls()
	_pending.text = "Choose an upgrade" + ("  ·  %d pending" % pending if pending > 1 else "")

	var over := hud.phase == EnumPhase.OVER
	if over and _last_phase != EnumPhase.OVER:
		_on_match_over(hud, me)
	_over.visible = over
	_banner.visible = not over
	_notice.visible = not over
	if playing and hud.wave > _last_wave and _last_wave > 0:
		_banner.show_message("WAVE %d" % hud.wave, UiTheme.CYAN)
		Sfx.play(&"wave")
	_last_wave = hud.wave if playing else 0
	_last_phase = hud.phase
	_show_session()


func _on_roster_changed() -> void:
	_show_name()
	_show_session()


## Banners and the record follow an event once it is confirmed (its tick verified), never a prediction: they stay.
## Effects and sounds play on the prediction (arena.gd).
func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state != UnifiedSession.EVENT_CONFIRMED:
		return
	var local := Unified.session.local_player
	if event is EventMatchOver:
		_show_best(event as EventMatchOver)
	elif event is EventLevelUp:
		var level_up := event as EventLevelUp
		if level_up.player == local:
			_banner.show_message("LEVEL %d" % level_up.level, UiTheme.GOLD)
	elif event is EventHeroDown:
		var down := event as EventHeroDown
		if local != 0 and down.player != local:
			_notice.show_message("%s IS DOWN" % Unified.session.get_player_name(down.player).to_upper(), UiTheme.BAD)
	elif event is EventPlayerJoined:
		# Your own join is not news; nor is a join before the session knows your player (yours, or one before you).
		var joined := event as EventPlayerJoined
		if local != 0 and joined.player != local:
			var what := "IS BACK" if joined.returning else "JOINED"
			_notice.show_message("%s %s" % [_name_of(joined.player, joined.slot).to_upper(), what], UiTheme.GOOD)
	elif event is EventPlayerLeft:
		var left := event as EventPlayerLeft
		if local != 0 and left.player != local:
			_notice.show_message("%s LEFT" % _name_of(left.player, left.slot).to_upper(), UiTheme.TEXT_DIM)


## The local hero's card, with feedback on a change: red edges when hurt, a flash of the XP bar on a gem.
func _show_hero(me: DataHudHero, playing: bool) -> void:
	if Unified.session.get_player_slot(Unified.session.local_player) != _named_slot:
		_show_name()
	var hp_max := maxi(me.hp_max, 1)
	var share := float(me.hp) / hp_max
	_level.text = "LV %d" % me.level
	_hp.max_value = hp_max
	_hp.value = me.hp
	_hp_text.text = "%d / %d" % [me.hp, hp_max]
	_hp_fill.bg_color = UiTheme.health_color(share)
	_xp.max_value = maxi(me.xp_next, 1)
	_xp.value = me.xp
	_xp_text.text = "XP %d / %d" % [me.xp, me.xp_next]
	if _last_hp >= 0 and me.hp < _last_hp and me.alive:
		_hurt = minf(_hurt + 0.25 + float(_last_hp - me.hp) / hp_max * 1.5, 0.6)
	_last_hp = me.hp
	if _last_xp >= 0 and me.xp > _last_xp:
		_xp.modulate = Color(2.2, 2.2, 2.2)
		_xp.create_tween().tween_property(_xp, "modulate", Color.WHITE, 0.3)
	_last_xp = me.xp
	_low_hp = 1.0 - share / LOW_HP_SHARE if share < LOW_HP_SHARE and playing else 0.0


func _show_name() -> void:
	var player := Unified.session.local_player
	_named_slot = Unified.session.get_player_slot(player)
	_player_name.text = Unified.session.get_player_name(player)
	_player_name.add_theme_color_override(&"font_color", UiTheme.player_color(_named_slot))


## The session panel's rows: everyone present, with their level and HP, or how long until a downed hero is back up.
func _show_session() -> void:
	var rows: Array[SessionPanel.Row] = []
	for player in Unified.session.players:
		var hero := Unified.data.hud.heroes[Unified.session.get_player_slot(player)] as DataHudHero
		var status := "LV %d" % hero.level if hero.alive else "down %.0fs" % ceilf(hero.respawn_s)
		var bar := float(hero.hp) / maxf(hero.hp_max, 1.0)
		rows.append(SessionPanel.Row.new(player, Unified.session.get_player_name(player), status, bar))
	_session.refresh(rows, false, "")


func _show_controls() -> void:
	var rows := [[MOVE, "Move"]]
	if _choosing:
		rows.append([PICKS, "Pick an upgrade"])
	rows.append([&"menu", "Menu"])
	_controls.refresh(rows)


## The key labels for the device in use: the level-up cards, the controls list, the overrun panel's hint.
func _label_keys() -> void:
	_show_cards()
	_menu_hint.text = "%s: menu" % Game.input_label(&"menu")
	_show_controls()


## The oldest pending level-up's three offers (the roll the sim makes for the pick, which the HUD data peeks), one
## per card. The data's `offers` is a read-only Array: copied, never changed in place.
func _show_offers(me: DataHudHero) -> void:
	var offers: Array[int] = []
	for offer: int in me.offers:
		offers.append(offer)
	if offers != _offers:
		_offers = offers
		_show_cards()


## Each card's upgrade, what it does and the key that picks it.
func _show_cards() -> void:
	var cards := Unified.constants.upgrades
	for i in _options.get_child_count():
		var button := _options.get_child(i) as Button
		button.visible = i < _offers.size()
		if button.visible:
			var card: DataUpgradeCard = cards[_offers[i]]
			button.text = "%s\n%s\n[%s]" % [card.name, card.detail, Game.input_label(PICKS[i])]


func _pop_levelup() -> void:
	for button: Button in _options.get_children():
		button.modulate = Color.WHITE
		button.scale = Vector2.ONE
	_levelup.visible = true
	_levelup.scale = Vector2(0.9, 0.9)
	_levelup.pivot_offset = _levelup.size / 2.0
	_levelup.create_tween().tween_property(_levelup, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK)


## A level-up pick (key, pad button or click): pops the card, holds the panel a moment and sends the `pick` command
## with card `index`'s upgrade. Nothing while the last pick waits (`_picked_at_pending`) or the panel holds it.
func _choose(index: int) -> void:
	if (_picked_at_pending >= 0 and _time_s < _pick_wait_until) or _time_s < _hold_until or not _choosing:
		return
	var me := _local_hero()
	if me == null:
		return
	if index >= _offers.size():
		return
	var button := _options.get_child(index) as Button
	button.pivot_offset = button.size / 2.0
	button.modulate = Color(1.6, 1.4, 0.6)
	var tween := button.create_tween()
	tween.tween_property(button, "scale", Vector2(1.12, 1.12), 0.08)
	tween.tween_property(button, "scale", Vector2.ONE, 0.12)
	_hold_until = _time_s + PICK_HOLD_S
	_pick_wait_until = _time_s + PICK_WAIT_S
	_picked_at_pending = me.pending_levelups
	Sfx.play(&"click")
	var pick := CommandPick.new()
	pick.upgrade = _offers[index]
	pick.level = me.offer_level  # the level the offers shown are for
	Unified.session.send_command(pick)


func _on_match_over(hud: DataHud, me: DataHudHero) -> void:
	_survived.text = "You held out %s" % UiTheme.clock(hud.time_s)
	_stats.text = "Wave %d  ·  %d kills  ·  level %d" % [hud.wave, hud.kills, me.level if me != null else 0]
	_best.text = ""  # the record shows when the match's end is confirmed
	_over_panel.pivot_offset = _over_panel.size / 2.0
	_over_panel.scale = Vector2(0.85, 0.85)
	_over_panel.modulate.a = 0.0
	var tween := _over_panel.create_tween().set_parallel()
	tween.tween_property(_over_panel, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(_over_panel, "modulate:a", 1.0, 0.25)


## The match's end is confirmed: the wave it reached (1-based) against this player's record, which it may raise (not a
## replay's match: maybe someone else's).
func _show_best(over: EventMatchOver) -> void:
	var reached := over.wave + 1
	var new_best := reached > Settings.best_wave and Unified.session.mode != UnifiedSession.MODE_REPLAY
	if new_best:
		Settings.best_wave = reached
	_best.text = "New best!" if new_best else "Best: wave %d" % Settings.best_wave
	_best.add_theme_color_override(&"font_color", UiTheme.GOLD if new_best else UiTheme.TEXT_DIM)


## A player's name for a banner: the session's (it still knows a player who left), else "P<slot + 1>".
func _name_of(player: int, slot: int) -> String:
	var synced := Unified.session.get_player_name(player)
	return synced if synced != "" else "P%d" % (slot + 1)


## The local player's hero in the HUD data (null until they hold a slot).
func _local_hero() -> DataHudHero:
	var slot := Unified.session.get_player_slot(Unified.session.local_player)
	return Unified.data.hud.heroes[slot] as DataHudHero if slot >= 0 else null
