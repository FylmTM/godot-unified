extends CanvasLayer
## The in-game HUD: the local player card (HP, XP, level), wave, time and enemies, the session panel and controls
## list, the start hint, banners, the level-up choice and the match-over panel. It follows the session data
## (`Unified.data.hud`, simulation/extension/hud.odin) when it changes, the roster for names and the input device for
## key labels; `_process` only animates. In-game buttons never take focus: Space and pad A are the dash.

## The level-up picks by card (Unified.constants.upgrades order).
const PICKS: Array[StringName] = [&"levelup_1", &"levelup_2", &"levelup_3"]
## A stick's directions, one control in the controls list (ControlsPanel.refresh).
const MOVE: Array[StringName] = [&"move_forward", &"move_left", &"move_back", &"move_right"]
## The level-up panel stays up this long after a pick, so the picked card can be seen.
const PICK_HOLD_S := 0.35
## How long a sent pick may take to show in the HUD data before another is taken (one the sim refused never shows).
const PICK_WAIT_S := 1.0

var _t := 0.0
var _last_phase := EnumPhase.LOBBY
var _last_wave := 0
## The record before the match that ended: Unified.data.hud.best_wave while no match is over (-1: not seen yet).
var _best_before := -1
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
var _arena: SurvivorArena

@onready var _root: Control = $Root
@onready var _vignette: ShaderMaterial = (%Vignette as ColorRect).material as ShaderMaterial
@onready var _flash: ColorRect = %Flash
@onready var _player_name: Label = %PlayerName
@onready var _level: Label = %Level
@onready var _hp: ProgressBar = %HP
@onready var _hp_fill: StyleBoxFlat = _hp.get_theme_stylebox(&"fill") as StyleBoxFlat
@onready var _hp_text: Label = %HPText
@onready var _xp: ProgressBar = %XP
@onready var _xp_text: Label = %XPText
@onready var _top: Control = %Top
@onready var _wave: Label = %Wave
@onready var _time: Label = %Time
@onready var _enemies: Label = %Enemies
@onready var _hint: Control = %Hint
@onready var _start_hint: Label = %StartHint
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
	_arena = get_parent() as SurvivorArena
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
	_label_keys()
	_on_hud_changed()


func _process(delta: float) -> void:
	_t += delta
	_hurt = maxf(_hurt - delta * 2.5, 0.0)
	var low := (0.25 + 0.15 * sin(_t * 6.0)) * _low_hp
	_vignette.set_shader_parameter(&"intensity", clampf(maxf(_hurt, low), 0.0, 0.6))
	_levelup.visible = _choosing or _t < _hold_until
	if _hint.visible:  # warms up as a player nears the circle's edge
		var urgency := _arena.start_urgency if _arena != null else 0.0
		_start_hint.text = "Step out to start the match!" if urgency > 0.5 else "Walk out of the circle to start"
		_start_hint.self_modulate = UiTheme.CYAN.lerp(UiTheme.ACCENT, urgency)
		_hint.modulate.a = lerpf(0.65 + 0.35 * sin(_t * 3.0), 1.0, urgency)
	if _over.visible:
		var left := ceilf(Unified.data.hud.reset_in_s)
		_back.text = "Back to the lobby in %d" % int(left) if left >= 1.0 else "Back to the lobby"
		_back.modulate.a = 0.6 + 0.4 * sin(_t * 4.0)


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
	var me := _local_row()
	var lobby := hud.phase == EnumPhase.LOBBY
	var playing := hud.phase == EnumPhase.MATCH
	var alive := me != null and me.alive
	if me != null:
		_show_player(me, playing)
	if not alive:
		_hurt = 0.0
		_low_hp = 0.0

	_top.visible = not lobby
	_wave.text = "WAVE %d" % hud.wave
	_time.text = UiTheme.clock(hud.time_s)
	_enemies.text = "%d %s" % [hud.enemies_alive, "enemy" if hud.enemies_alive == 1 else "enemies"]
	_hint.visible = lobby
	_respawn.visible = playing and me != null and not alive
	if _respawn.visible:
		_respawn.text = "Respawning in %.1f s" % me.respawn_s

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
	elif not over and _last_phase == EnumPhase.OVER:
		_best.text = ""  # the next match's record shows when its end is confirmed
	if not over:
		_best_before = hud.best_wave
	_over.visible = over
	_banner.visible = not over
	_notice.visible = not over
	if playing and hud.wave > _last_wave and _last_wave > 0:
		_banner.show_message("WAVE %d" % hud.wave, UiTheme.CYAN)
	_last_wave = hud.wave if playing else 0
	_last_phase = hud.phase
	_show_session()


func _on_roster_changed() -> void:
	_show_name()
	_show_session()


## Banners and the record follow an event once it is confirmed (its tick verified), never a prediction: they
## stay. Effects and sounds play on the prediction (arena.gd).
func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state != UnifiedSession.EVENT_CONFIRMED:
		return
	var local := Unified.session.local_player
	if event is EventMatchOver:
		_show_best(event as EventMatchOver)
	elif event is EventMatchStarted:
		_banner.show_message("SURVIVE!", UiTheme.ACCENT)
		_flash.color.a = 0.12
		_flash.create_tween().tween_property(_flash, "color:a", 0.0, 0.4)
	elif event is EventLevelUp:
		var level_up := event as EventLevelUp
		if level_up.player == local:
			_banner.show_message("LEVEL %d" % level_up.level, UiTheme.GOLD)
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


## The local player's card, with feedback on a change: red edges and a rumble when hurt, a flash of the XP bar on a gem.
func _show_player(me: DataHudPlayer, playing: bool) -> void:
	if Unified.session.get_player_slot(Unified.session.local_player) != _named_slot:
		_show_name()
	var hp_max := maxi(me.hp_max, 1)
	var fraction := float(me.hp) / hp_max
	_level.text = "LV %d" % me.level
	_hp.max_value = hp_max
	_hp.value = me.hp
	_hp_text.text = "%d / %d" % [me.hp, hp_max]
	_hp_fill.bg_color = UiTheme.health_color(fraction)
	_xp.max_value = maxi(me.xp_next, 1)
	_xp.value = me.xp
	_xp_text.text = "XP %d / %d" % [me.xp, me.xp_next]
	if _last_hp >= 0 and me.hp < _last_hp and me.alive:
		_hurt = minf(_hurt + 0.25 + float(_last_hp - me.hp) / hp_max * 1.5, 0.6)
		Game.rumble(0.25, 0.35, 0.12)
	_last_hp = me.hp
	if _last_xp >= 0 and me.xp > _last_xp:
		_xp.modulate = Color(2.2, 2.2, 2.2)
		_xp.create_tween().tween_property(_xp, "modulate", Color.WHITE, 0.3)
	_last_xp = me.xp
	_low_hp = 1.0 - fraction / 0.3 if fraction < 0.3 and playing else 0.0


func _show_name() -> void:
	var player := Unified.session.local_player
	_named_slot = Unified.session.get_player_slot(player)
	_player_name.text = Unified.session.get_player_name(player)
	_player_name.add_theme_color_override(&"font_color", UiTheme.player_color(_named_slot))


## The session panel's rows: everyone present, with their level and HP in a match.
func _show_session() -> void:
	var lobby := Unified.data.hud.phase == EnumPhase.LOBBY
	var rows: Array[SessionPanel.Row] = []
	for player in Unified.session.players:
		var info := Unified.data.hud.players[Unified.session.get_player_slot(player)] as DataHudPlayer
		var status := "ready"
		if not lobby:
			status = "down %.0fs" % ceilf(info.respawn_s) if not info.alive else "LV %d" % info.level
		var bar := -1.0 if lobby else float(info.hp) / maxf(info.hp_max, 1.0)
		rows.append(SessionPanel.Row.new(player, Unified.session.get_player_name(player), status, bar))
	_session.refresh(rows, lobby, "Anyone walking out of the circle starts the match.")


func _show_controls() -> void:
	var rows := [[MOVE, "Move"], [&"dash", "Dash"]]
	if _choosing:
		rows.append([PICKS, "Pick an upgrade"])
	rows.append([&"menu", "Menu"])
	_controls.refresh(rows)


## The key labels for the device in use: the level-up cards, the controls list, the match-over hint.
func _label_keys() -> void:
	var cards := Unified.constants.upgrades
	for i in mini(_options.get_child_count(), cards.size()):
		var card: DataUpgradeCard = cards[i]
		(_options.get_child(i) as Button).text = "%s\n%s\n[%s]" % [card.name, card.detail, Game.input_label(PICKS[i])]
	_menu_hint.text = "%s: menu" % Game.input_label(&"menu")
	_show_controls()


## Only the oldest pending level-up's two offers (the roll the sim makes for the pick, which the HUD data peeks) can
## be picked: the third card hides, and its key does nothing.
func _show_offers(me: DataHudPlayer) -> void:
	var cards := Unified.constants.upgrades
	for i in mini(_options.get_child_count(), cards.size()):
		var card: DataUpgradeCard = cards[i]
		(_options.get_child(i) as Button).visible = card.upgrade == me.offer_a or card.upgrade == me.offer_b


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
	if (_picked_at_pending >= 0 and _t < _pick_wait_until) or _t < _hold_until or not _choosing:
		return
	var me := _local_row()
	if me == null:
		return
	var button := _options.get_child(index) as Button
	if not button.visible:
		return  # not offered: the sim would ignore it
	button.pivot_offset = button.size / 2.0
	button.modulate = Color(1.6, 1.4, 0.6)
	var tween := button.create_tween()
	tween.tween_property(button, "scale", Vector2(1.12, 1.12), 0.08)
	tween.tween_property(button, "scale", Vector2.ONE, 0.12)
	_hold_until = _t + PICK_HOLD_S
	_pick_wait_until = _t + PICK_WAIT_S
	_picked_at_pending = me.pending_levelups
	Sfx.play(&"click")
	var card: DataUpgradeCard = Unified.constants.upgrades[index]
	var pick := CommandPick.new()
	pick.upgrade = card.upgrade
	pick.level = me.level - me.pending_levelups + 1  # the oldest pending level-up's: the offers shown are its
	Unified.session.send_command(pick)


func _on_match_over(hud: DataHud, me: DataHudPlayer) -> void:
	_survived.text = "You survived %s" % UiTheme.clock(hud.time_s)
	_stats.text = "Wave %d  ·  level %d  ·  %d enemies left" % [hud.wave, me.level if me != null else 0,
		hud.enemies_alive]
	_over_panel.pivot_offset = _over_panel.size / 2.0
	_over_panel.scale = Vector2(0.85, 0.85)
	_over_panel.modulate.a = 0.0
	var tween := _over_panel.create_tween().set_parallel()
	tween.tween_property(_over_panel, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(_over_panel, "modulate:a", 1.0, 0.25)


## The match's end is confirmed: the waves it reached against the session's record (the sim's, from the Setup: the
## host saves it, game.gd).
func _show_best(over: EventMatchOver) -> void:
	var new_best := _best_before >= 0 and over.waves > _best_before
	_best.text = "New best!" if new_best else "Best: wave %d" % over.best_wave
	_best.add_theme_color_override(&"font_color", UiTheme.GOLD if new_best else UiTheme.TEXT_DIM)

## A player's name for a banner: the session's (it still knows a player who left), else "P<slot + 1>".
func _name_of(player: int, slot: int) -> String:
	var synced := Unified.session.get_player_name(player)
	return synced if synced != "" else "P%d" % (slot + 1)


## The local player's row of the HUD data (null until they hold a slot).
func _local_row() -> DataHudPlayer:
	var slot := Unified.session.get_player_slot(Unified.session.local_player)
	return Unified.data.hud.players[slot] as DataHudPlayer if slot >= 0 else null
