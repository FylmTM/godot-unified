extends CanvasLayer
## The in-game HUD, driven by `Unified.hud` (the session data, simulation/extension/hud.odin) every frame: the local
## player card (HP, XP, level), wave, time and enemies, the shared session panel and controls list, the start hint,
## banners, the level-up choice and the match-over panel.
## In-game buttons never take focus: Space and pad A are the dash, not "press the focused button".

## Upgrade names, details and ids come from the sim (`Unified.constants.upgrades`), as does the "over" hold time.
const KEYS := ["1", "2", "3"]
const PAD_KEYS := ["X", "Y", "B"]

var _last_wave := 0
var _last_phase := EnumPhase.LOBBY
var _t := 0.0
var _last_hp := -1.0
var _last_xp := -1
## The red edge flash after taking damage, 0..1, decaying.
var _hurt := 0.0
## Keeps the panel up briefly after a choice, so the picked card can be seen.
var _levelup_hold := 0.0
var _over_since := 0.0
var _new_best := false
var _session: SessionPanel
var _controls: ControlsPanel

@onready var _root: Control = $Root
@onready var _card_name: Label = $Root/PlayerCard/VBox/Top/Name
@onready var _card_level: Label = $Root/PlayerCard/VBox/Top/Level
@onready var _hp: ProgressBar = $Root/PlayerCard/VBox/HP
@onready var _hp_text: Label = $Root/PlayerCard/VBox/HP/Text
@onready var _xp: ProgressBar = $Root/PlayerCard/VBox/XP
@onready var _xp_text: Label = $Root/PlayerCard/VBox/XPText
@onready var _top: Control = $Root/Top
@onready var _wave: Label = $Root/Top/Wave
@onready var _time: Label = $Root/Top/Time
@onready var _enemies: Label = $Root/Top/Enemies
@onready var _hint: Control = $Root/Hint
@onready var _respawn: Label = $Root/Respawn
@onready var _banner: Label = $Root/Banner
@onready var _levelup: PanelContainer = $Root/LevelUp
@onready var _pending: Label = $Root/LevelUp/VBox/Pending
@onready var _over: Control = $Root/GameOver
@onready var _over_panel: Control = $Root/GameOver/Center/Panel
@onready var _over_title: Label = $Root/GameOver/Center/Panel/VBox/Title
@onready var _over_survived: Label = $Root/GameOver/Center/Panel/VBox/Survived
@onready var _over_stats: Label = $Root/GameOver/Center/Panel/VBox/Stats
@onready var _over_best: Label = $Root/GameOver/Center/Panel/VBox/Best
@onready var _over_back: Label = $Root/GameOver/Center/Panel/VBox/Back
@onready var _over_leave: Button = $Root/GameOver/Center/Panel/VBox/Leave
@onready var _over_menu_hint: Label = $Root/GameOver/Center/Panel/VBox/MenuHint
@onready var _hp_fill: StyleBoxFlat = _hp.get_theme_stylebox(&"fill") as StyleBoxFlat
@onready var _vignette: ShaderMaterial = ($Root/Vignette as ColorRect).material as ShaderMaterial
@onready var _flash: ColorRect = $Root/Flash
@onready var _hint_main: Label = $Root/Hint/Main
@onready var _options: HBoxContainer = $Root/LevelUp/VBox/Options


func _ready() -> void:
	for i in 3:
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(200, 112)
		b.add_theme_font_size_override(&"font_size", 18)
		b.pressed.connect(_choose.bind(i + 1))
		_options.add_child(b)
	Game.input_device_changed.connect(func(_pad: bool) -> void: _label_keys())
	_label_keys()
	_session = SessionPanel.new()
	_root.add_child(_session)
	_controls = ControlsPanel.new()
	_root.add_child(_controls)
	_over_leave.pressed.connect(func() -> void:
		Sfx.play(&"click")
		Game.leave_to_menu())
	Game.session.sim_event.connect(_on_sim_event)
	_refresh(0.0)


func _process(delta: float) -> void:
	_t += delta
	for i in 3:
		if Input.is_action_just_pressed(StringName("levelup_%d" % (i + 1))) and _levelup.visible:
			_choose(i + 1)
	_refresh(delta)


func _refresh(delta: float) -> void:
	var hud := Unified.hud
	var phase := hud.phase
	var me := Game.local_player_info()
	var lobby := phase == EnumPhase.LOBBY
	var wave := hud.wave
	var alive: bool = me.get("alive", false)
	var hp: float = me.get("hp", 1)
	var hp_full: float = me.get("hp_max", 1)
	var hp_max := maxf(hp_full, 1.0)
	var xp: int = me.get("xp", 0)
	var xp_next: int = me.get("xp_next", 1)
	var level: int = me.get("level", 0)

	# Local player card.
	if not me.is_empty():
		var player: int = me.get("player", 0)
		_card_name.text = Game.player_name(me)
		_card_name.add_theme_color_override(&"font_color", UiTheme.player_color(Game.player_slot(player)))
		_card_level.text = "LV %d" % level
		_hp.max_value = hp_max
		_hp.value = hp
		_hp_text.text = "%d / %d" % [ceili(hp), roundi(hp_max)]
		var r := hp / hp_max
		_hp_fill.bg_color = UiTheme.GOOD if r > 0.5 else (UiTheme.GOLD if r > 0.25 else UiTheme.BAD)
		_xp.max_value = maxi(xp_next, 1)
		_xp.value = xp
		_xp_text.text = "XP %d / %d" % [xp, xp_next]
		# Feedback: red edges and a rumble when hurt; the XP bar flashes on a gem.
		if _last_hp >= 0.0 and hp < _last_hp - 0.01 and alive:
			_hurt = minf(_hurt + 0.25 + (_last_hp - hp) / hp_max * 1.5, 0.6)
			Game.rumble(0.25, 0.35, 0.12)
		_last_hp = hp
		if _last_xp >= 0 and xp > _last_xp:
			_xp.modulate = Color(2.2, 2.2, 2.2)
			_xp.create_tween().tween_property(_xp, "modulate", Color.WHITE, 0.3)
		_last_xp = xp
	var hp_ratio := hp / hp_max
	var pulse_low := hp_ratio < 0.3 and alive and phase == EnumPhase.MATCH
	var low := (0.25 + 0.15 * sin(_t * 6.0)) * (1.0 - hp_ratio / 0.3) if pulse_low else 0.0
	_hurt = maxf(_hurt - delta * 2.5, 0.0) if alive else 0.0
	_vignette.set_shader_parameter(&"intensity", clampf(maxf(_hurt, low), 0.0, 0.6))

	# Wave, time, enemies.
	_top.visible = not lobby
	_wave.text = "WAVE %d" % wave
	var time_s := hud.time_s
	_time.text = _clock(time_s)
	var n := hud.enemies_alive
	_enemies.text = "%d %s" % [n, "enemy" if n == 1 else "enemies"]

	# Start hint: warms up as a player nears the circle's edge.
	_hint.visible = lobby
	if lobby:
		var arena := get_parent() as SurvivorArena
		var urgency := arena.start_urgency if arena != null else 0.0
		_hint_main.text = "Step out to start the match!" if urgency > 0.5 else "Walk out of the circle to start"
		_hint_main.add_theme_color_override(&"font_color", UiTheme.CYAN.lerp(UiTheme.ACCENT, urgency))
		_hint.modulate.a = lerpf(0.65 + 0.35 * sin(_t * 3.0), 1.0, urgency)

	_session.refresh(_session_rows(lobby), lobby, "Anyone walking out of the circle starts the match.")

	# Respawn countdown.
	var dead_in_match := phase == EnumPhase.MATCH and not me.is_empty() and not alive
	_respawn.visible = dead_in_match
	if dead_in_match:
		var respawn_s: float = me.get("respawn_s", 0.0)
		_respawn.text = "Respawning in %.1f s" % respawn_s

	# Level-up choice.
	var pending: int = me.get("pending_levelups", 0)
	var show_levelup := pending > 0 and phase == EnumPhase.MATCH and alive
	_levelup_hold = maxf(_levelup_hold - delta, 0.0)
	if show_levelup and not _levelup.visible:
		for b: Button in _options.get_children():
			b.modulate = Color.WHITE
			b.scale = Vector2.ONE
		_levelup.scale = Vector2(0.9, 0.9)
		_levelup.pivot_offset = _levelup.size / 2.0
		_levelup.create_tween().tween_property(_levelup, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK)
	_levelup.visible = show_levelup or _levelup_hold > 0.0
	_update_controls(show_levelup)
	_pending.text = "Choose an upgrade" + ("  ·  %d pending" % pending if pending > 1 else "")

	# Match over.
	var over := phase == EnumPhase.OVER
	if over and _last_phase != EnumPhase.OVER:
		_on_match_over(time_s, wave, level, n)
	_over.visible = over
	_banner.visible = not over
	if over:
		var hold_s := Unified.constants.over_hold_s
		var left := ceilf(hold_s - (_t - _over_since))
		_over_back.text = "Back to the lobby in %d" % int(left) if left >= 1.0 else "Back to the lobby"
		_over_back.modulate.a = 0.6 + 0.4 * sin(_t * 4.0)
		_over_menu_hint.text = Game.hint("Esc: menu", "Start: menu")

	if phase == EnumPhase.MATCH and wave > _last_wave and _last_wave > 0:
		_show_banner("WAVE %d" % wave, UiTheme.CYAN)
	_last_wave = wave if phase == EnumPhase.MATCH else 0
	_last_phase = phase


func _on_match_over(time_s: float, wave: int, level: int, enemies: int) -> void:
	_over_since = _t
	_over_title.text = "GAME OVER"
	_over_survived.text = "You survived %s" % _clock(time_s)
	_over_stats.text = "Wave %d  ·  level %d  ·  %d enemies left" % [wave, level, enemies]
	var best: float = Settings.get_value(&"best_time")
	_new_best = time_s > best + 0.01
	if _new_best:
		Settings.set_value(&"best_time", time_s)
	_over_best.text = "New best!" if _new_best else "Best: %s" % _clock(best)
	_over_best.add_theme_color_override(&"font_color", UiTheme.GOLD if _new_best else UiTheme.TEXT_DIM)
	_over_panel.pivot_offset = _over_panel.size / 2.0
	_over_panel.scale = Vector2(0.85, 0.85)
	_over_panel.modulate.a = 0.0
	var tw := _over_panel.create_tween().set_parallel()
	tw.tween_property(_over_panel, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_over_panel, "modulate:a", 1.0, 0.25)


func _label_keys() -> void:
	var keys: Array = PAD_KEYS if Game.using_pad else KEYS
	var cards := Unified.constants.upgrades
	for i in mini(_options.get_child_count(), cards.size()):
		var card: Dictionary = cards[i]
		(_options.get_child(i) as Button).text = "%s\n%s\n[%s]" % [card.name, card.detail, keys[i]]


## Visual feedback for a level-up pick (key, pad button or click): pop the card, hold the panel a moment.
func _picked(i: int) -> void:
	var b := _options.get_child(i) as Button
	b.pivot_offset = b.size / 2.0
	b.modulate = Color(1.6, 1.4, 0.6)
	var tw := b.create_tween()
	tw.tween_property(b, "scale", Vector2(1.12, 1.12), 0.08)
	tw.tween_property(b, "scale", Vector2.ONE, 0.12)
	_levelup_hold = 0.35
	Sfx.play(&"click")


func _update_controls(choosing: bool) -> void:
	var keys := [["WASD / arrows", "Move"], ["Space", "Dash"]]
	var pad := [["Left stick", "Move"], ["A", "Dash"]]
	if choosing:
		keys.append(["1  2  3", "Pick an upgrade"])
		pad.append(["X  Y  B", "Pick an upgrade"])
	keys.append(["Esc", "Menu"])
	pad.append(["Start", "Menu"])
	_controls.refresh(keys, pad)


## The session panel's rows: everyone present, with their level and HP in a match.
func _session_rows(lobby: bool) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for p in Game.present_players():
		var status := "ready"
		if not lobby:
			var alive: bool = p.get("alive", false)
			var respawn_s: float = p.get("respawn_s", 0.0)
			var level: int = p.get("level", 0)
			status = "down %.0fs" % ceilf(respawn_s) if not alive else "LV %d" % level
		var hp: float = p.get("hp", 0)
		var hp_max: float = p.get("hp_max", 1)
		var bar := -1.0 if lobby else hp / maxf(hp_max, 1.0)
		rows.append({"player": p.get("player", 0), "name": Game.player_name(p), "status": status, "bar": bar})
	return rows


## Banners show when an event is confirmed (its tick verified), never on a prediction.
func _on_sim_event(event: UnifiedEvent, state: int) -> void:
	if state != UnifiedSession.EVENT_CONFIRMED:
		return
	var local := Game.local_player()
	if event is EventMatchStarted:
		_show_banner("SURVIVE!", UiTheme.ACCENT)
		_flash.color.a = 0.12
		_flash.create_tween().tween_property(_flash, "color:a", 0.0, 0.4)
	elif event is EventLevelUp:
		var level_up := event as EventLevelUp
		if level_up.player == local:
			_show_banner("LEVEL %d" % level_up.level, UiTheme.GOLD)
	elif event is EventPlayerJoined:
		# Your own join is not news; nor is a join before the session knows your player (yours, or one before you).
		var joined := event as EventPlayerJoined
		if local != 0 and joined.player != local:
			var what := "IS BACK" if joined.returning else "JOINED"
			_show_banner("%s %s" % [_name_of(joined.player, joined.slot).to_upper(), what], UiTheme.GOOD, 32)
	elif event is EventPlayerLeft:
		var left := event as EventPlayerLeft
		if local != 0 and left.player != local:
			_show_banner("%s LEFT" % _name_of(left.player, left.slot).to_upper(), UiTheme.TEXT_DIM, 32)


func _show_banner(text: String, color: Color, size := 60) -> void:
	_banner.text = text
	_banner.add_theme_color_override(&"font_color", color)
	_banner.add_theme_font_size_override(&"font_size", size)
	_banner.pivot_offset = _banner.size / 2.0
	var tw := _banner.create_tween()
	_banner.modulate.a = 0.0
	_banner.scale = Vector2(1.4, 1.4)
	tw.set_parallel()
	tw.tween_property(_banner, "modulate:a", 1.0, 0.15)
	tw.tween_property(_banner, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.chain().tween_interval(1.0)
	tw.chain().tween_property(_banner, "modulate:a", 0.0, 0.4)


## A level-up pick (key, pad button or click): the `pick` command with card i's upgrade (Unified.constants.upgrades).
func _choose(option: int) -> void:
	_picked(option - 1)
	var cards := Unified.constants.upgrades
	if option - 1 >= cards.size():
		return
	var card: Dictionary = cards[option - 1]
	var pick := CommandPick.new()
	pick.upgrade = card.upgrade
	Game.send_command(pick)


## A player's name for a banner: the session's (it still knows a player who left), else "P<slot + 1>".
func _name_of(player: int, slot: int) -> String:
	var synced := Game.session.get_player_name(player)
	return synced if synced != "" else "P%d" % (slot + 1)


static func _clock(seconds: float) -> String:
	var s := int(seconds)
	return "%02d:%02d" % [floori(s / 60.0), s % 60]
