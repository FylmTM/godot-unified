extends CanvasLayer
## The in-game HUD, driven by `Game.hud` every frame: the local player card (HP, XP, level), wave, time and
## enemies, the shared session panel and controls list, the start hint, banners, the level-up choice and the
## match-over panel.
## In-game buttons never take focus: Space and pad A are the dash, not "press the focused button".

## Upgrade names and details come from the sim (`Game.constants.upgrades`), as does the "over" hold time.
const KEYS := ["1", "2", "3"]
const PAD_KEYS := ["X", "Y", "B"]

var _last_wave := 0
var _last_phase := ""
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
@onready var _hp_fill: StyleBoxFlat = _hp.get_theme_stylebox(&"fill") as StyleBoxFlat
@onready var _vignette: ShaderMaterial = $Root/Vignette.material
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
	$Root.add_child(_session)
	_controls = ControlsPanel.new()
	$Root.add_child(_controls)
	$Root/GameOver/Center/Panel/VBox/Leave.pressed.connect(func() -> void:
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
	var h := Game.hud
	var phase: String = h.get("phase", "lobby")
	var me := Game.local_player_info()
	var lobby := phase == "lobby"

	# Local player card.
	if not me.is_empty():
		_card_name.text = Game.player_name(me)
		_card_name.add_theme_color_override(&"font_color", UiTheme.player_color(me.player))
		_card_level.text = "LV %d" % me.level
		_hp.max_value = me.hp_max
		_hp.value = me.hp
		_hp_text.text = "%d / %d" % [ceili(me.hp), roundi(me.hp_max)]
		var r: float = me.hp / maxf(me.hp_max, 1.0)
		_hp_fill.bg_color = UiTheme.GOOD if r > 0.5 else (UiTheme.GOLD if r > 0.25 else UiTheme.BAD)
		_xp.max_value = maxi(me.xp_next, 1)
		_xp.value = me.xp
		_xp_text.text = "XP %d / %d" % [me.xp, me.xp_next]
		# Feedback: red edges and a rumble when hurt; the XP bar flashes on a gem.
		if _last_hp >= 0.0 and me.hp < _last_hp - 0.01 and me.alive:
			_hurt = minf(_hurt + 0.25 + (_last_hp - me.hp) / maxf(me.hp_max, 1.0) * 1.5, 0.6)
			Game.rumble(0.25, 0.35, 0.12)
		_last_hp = me.hp
		if _last_xp >= 0 and int(me.xp) > _last_xp:
			_xp.modulate = Color(2.2, 2.2, 2.2)
			_xp.create_tween().tween_property(_xp, "modulate", Color.WHITE, 0.3)
		_last_xp = me.xp
	var hp_ratio: float = float(me.get("hp", 1)) / maxf(float(me.get("hp_max", 1)), 1.0)
	var pulse_low: bool = hp_ratio < 0.3 and me.get("alive", false) and phase == "match"
	var low := (0.25 + 0.15 * sin(_t * 6.0)) * (1.0 - hp_ratio / 0.3) if pulse_low else 0.0
	_hurt = maxf(_hurt - delta * 2.5, 0.0) if me.get("alive", false) else 0.0
	_vignette.set_shader_parameter(&"intensity", clampf(maxf(_hurt, low), 0.0, 0.6))

	# Wave, time, enemies.
	_top.visible = not lobby
	_wave.text = "WAVE %d" % h.get("wave", 0)
	_time.text = _clock(h.get("time_s", 0.0))
	var n: int = h.get("enemies_alive", 0)
	_enemies.text = "%d %s" % [n, "enemy" if n == 1 else "enemies"]

	# Start hint: warms up as a player nears the circle's edge.
	_hint.visible = lobby
	if lobby:
		var urgency: float = get_parent().get(&"start_urgency") if get_parent().get(&"start_urgency") != null else 0.0
		_hint_main.text = "Step out to start the match!" if urgency > 0.5 else "Walk out of the circle to start"
		_hint_main.add_theme_color_override(&"font_color", UiTheme.CYAN.lerp(UiTheme.ACCENT, urgency))
		_hint.modulate.a = lerpf(0.65 + 0.35 * sin(_t * 3.0), 1.0, urgency)

	_session.refresh(_session_rows(lobby), lobby, "Anyone walking out of the circle starts the match.")

	# Respawn countdown.
	var dead_in_match: bool = phase == "match" and not me.is_empty() and not me.alive
	_respawn.visible = dead_in_match
	if dead_in_match:
		_respawn.text = "Respawning in %.1f s" % me.respawn_s

	# Level-up choice.
	var pending: int = me.get("pending_levelups", 0)
	var show_levelup: bool = pending > 0 and phase == "match" and me.get("alive", false)
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
	if phase == "over" and _last_phase != "over":
		_on_match_over(h, me)
	_over.visible = phase == "over"
	_banner.visible = phase != "over"
	if phase == "over":
		var left := ceilf(float(Game.constants.over_hold_s) - (_t - _over_since))
		var back: Label = $Root/GameOver/Center/Panel/VBox/Back
		back.text = "Back to the lobby in %d" % int(left) if left >= 1.0 else "Back to the lobby"
		back.modulate.a = 0.6 + 0.4 * sin(_t * 4.0)
		$Root/GameOver/Center/Panel/VBox/MenuHint.text = Game.hint("Esc: menu", "Start: menu")

	if phase == "match" and int(h.get("wave", 0)) > _last_wave and _last_wave > 0:
		_show_banner("WAVE %d" % h.wave, UiTheme.CYAN)
	_last_wave = h.get("wave", 0) if phase == "match" else 0
	_last_phase = phase


func _on_match_over(h: Dictionary, me: Dictionary) -> void:
	_over_since = _t
	var time_s: float = h.get("time_s", 0.0)
	var vbox := $Root/GameOver/Center/Panel/VBox
	vbox.get_node(^"Title").text = "GAME OVER"
	vbox.get_node(^"Survived").text = "You survived %s" % _clock(time_s)
	vbox.get_node(^"Stats").text = "Wave %d  ·  level %d  ·  %d enemies left" % [h.get("wave", 0), me.get("level", 0),
		h.get("enemies_alive", 0)]
	var best: float = Settings.get_value(&"best_time")
	_new_best = time_s > best + 0.01
	if _new_best:
		Settings.set_value(&"best_time", time_s)
	var best_label: Label = vbox.get_node(^"Best")
	best_label.text = "New best!" if _new_best else "Best: %s" % _clock(best)
	best_label.add_theme_color_override(&"font_color", UiTheme.GOLD if _new_best else UiTheme.TEXT_DIM)
	var panel: Control = $Root/GameOver/Center/Panel
	panel.pivot_offset = panel.size / 2.0
	panel.scale = Vector2(0.85, 0.85)
	panel.modulate.a = 0.0
	var tw := panel.create_tween().set_parallel()
	tw.tween_property(panel, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(panel, "modulate:a", 1.0, 0.25)


func _label_keys() -> void:
	var keys: Array = PAD_KEYS if Game.using_pad else KEYS
	var upgrades: Array = Game.constants.upgrades
	for i in _options.get_child_count():
		var u: Dictionary = upgrades[i]
		(_options.get_child(i) as Button).text = "%s\n%s\n[%s]" % [u.name, u.detail, keys[i]]


## Visual feedback for a level-up pick (key, pad button or click): pop the card, hold the panel a moment.
func _picked(i: int) -> void:
	var b: Button = _options.get_child(i)
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
			status = "down %.0fs" % ceilf(p.respawn_s) if not p.alive else "LV %d" % p.level
		var bar: float = -1.0 if lobby else p.hp / maxf(p.hp_max, 1.0)
		rows.append({"player": p.player, "name": Game.player_name(p), "status": status, "bar": bar})
	return rows


## Banners show when an event is confirmed (its tick verified), never on a prediction.
func _on_sim_event(event: StringName, state: int, data: Dictionary) -> void:
	if state != SimEvent.CONFIRMED:
		return
	var local := Game.local_player()
	match event:
		&"match_started":
			_show_banner("SURVIVE!", UiTheme.ACCENT)
			_flash.color.a = 0.12
			_flash.create_tween().tween_property(_flash, "color:a", 0.0, 0.4)
		&"level_up":
			if int(data.player) == local:
				_show_banner("LEVEL %d" % int(data.level), UiTheme.GOLD)
		&"player_joined":
			# Your own join is not news; nor is a join before the session knows your player (yours, or one before you).
			if local >= 0 and int(data.player) != local:
				_show_banner("%s JOINED" % _name_of(int(data.player)).to_upper(), UiTheme.GOOD, 32)
		&"player_left":
			if local >= 0 and int(data.player) != local:
				_show_banner("%s LEFT" % _name_of(int(data.player)).to_upper(), UiTheme.TEXT_DIM, 32)


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


## A level-up pick (key, pad button or click): the `pick` command, upgrade i in constants().upgrades order.
func _choose(option: int) -> void:
	_picked(option - 1)
	Game.session.send_command(&"pick", {"upgrade": option - 1})


func _name_of(player: int) -> String:
	var info := Game.player_info(player)
	return Game.player_name(info) if not info.is_empty() else "P%d" % (player + 1)


static func _clock(seconds: float) -> String:
	var s := int(seconds)
	return "%02d:%02d" % [floori(s / 60.0), s % 60]
