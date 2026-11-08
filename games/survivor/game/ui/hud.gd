extends CanvasLayer
## In-game HUD, driven by `Game.hud` every frame: local player card (HP, XP, level), wave/time/enemies, the
## lobby/squad panel (code + players), the start hint, banners, the level-up choice and the match-over panel.
## In-game buttons never take focus: Space and pad A are the dash, not "press the focused button".

const UPGRADES := [
	["Fire rate", "Shoot more often"],
	["Damage", "+3 damage per shot"],
	["Move speed", "+0.5 m/s"],
]
const KEY_HINTS := ["1 / X", "2 / Y", "3 / B"]

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
@onready var _side: PanelContainer = $Root/Side
@onready var _side_heading: Label = $Root/Side/VBox/Heading
@onready var _code_row: Control = $Root/Side/VBox/CodeRow
@onready var _code_label: Label = $Root/Side/VBox/CodeRow/Label
@onready var _code: Label = $Root/Side/VBox/CodeRow/Code
@onready var _copy: Button = $Root/Side/VBox/CodeRow/Copy
@onready var _list: VBoxContainer = $Root/Side/VBox/List
@onready var _side_hint: Label = $Root/Side/VBox/Hint
@onready var _hint: Control = $Root/Hint
@onready var _respawn: Label = $Root/Respawn
@onready var _banner: Label = $Root/Banner
@onready var _levelup: PanelContainer = $Root/LevelUp
@onready var _pending: Label = $Root/LevelUp/VBox/Pending
@onready var _over: Control = $Root/GameOver
@onready var _hp_fill: StyleBoxFlat = _hp.get_theme_stylebox(&"fill") as StyleBoxFlat

var _rows: Array[Dictionary] = []
var _last_wave := 0
var _last_phase := ""
var _t := 0.0


func _ready() -> void:
	for i in 3:
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(200, 112)
		b.text = "%s\n%s\n[%s]" % [UPGRADES[i][0], UPGRADES[i][1], KEY_HINTS[i]]
		b.add_theme_font_size_override(&"font_size", 18)
		b.pressed.connect(_choose.bind(i + 1))
		$Root/LevelUp/VBox/Options.add_child(b)
	for i in 4:
		_rows.append(_make_row())
	_copy.pressed.connect(_copy_code)
	$Root/GameOver/Center/Panel/VBox/Leave.pressed.connect(func() -> void:
		Sfx.play(&"click")
		Game.leave_to_menu())
	Game.session.sim_event.connect(_on_sim_event)
	_refresh(0.0)


func _process(delta: float) -> void:
	_t += delta
	_refresh(delta)


func _refresh(_delta: float) -> void:
	var h := Game.hud
	var phase: String = h.get("phase", "lobby")
	var me := Game.local_player()
	var lobby := phase == "lobby"

	# Local player card.
	if not me.is_empty():
		_card_name.text = Game.player_name(me)
		_card_name.add_theme_color_override(&"font_color", UiTheme.slot_color(me.slot))
		_card_level.text = "LV %d" % me.level
		_hp.max_value = me.hp_max
		_hp.value = me.hp
		_hp_text.text = "%d / %d" % [ceili(me.hp), roundi(me.hp_max)]
		var r: float = me.hp / maxf(me.hp_max, 1.0)
		_hp_fill.bg_color = UiTheme.GOOD if r > 0.5 else (Color("ffd23f") if r > 0.25 else UiTheme.BAD)
		_xp.max_value = maxi(me.xp_next, 1)
		_xp.value = me.xp
		_xp_text.text = "XP %d / %d" % [me.xp, me.xp_next]

	# Wave, time, enemies.
	_top.visible = not lobby
	_wave.text = "WAVE %d" % h.get("wave", 0)
	_time.text = _clock(h.get("time_s", 0.0))
	var n: int = h.get("enemies_alive", 0)
	_enemies.text = "%d %s" % [n, "enemy" if n == 1 else "enemies"]

	# Start hint.
	_hint.visible = lobby
	if lobby:
		_hint.modulate.a = 0.65 + 0.35 * sin(_t * 3.0)

	_update_side(lobby)

	# Respawn countdown.
	var dead_in_match: bool = phase == "match" and not me.is_empty() and not me.alive
	_respawn.visible = dead_in_match
	if dead_in_match:
		_respawn.text = "Respawning in %.1f s" % me.respawn_s

	# Level-up choice.
	var pending: int = me.get("pending_levelups", 0)
	var show_levelup: bool = pending > 0 and phase == "match" and me.get("alive", false)
	if show_levelup and not _levelup.visible:
		_levelup.scale = Vector2(0.9, 0.9)
		_levelup.pivot_offset = _levelup.size / 2.0
		_levelup.create_tween().tween_property(_levelup, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK)
	_levelup.visible = show_levelup
	_pending.text = "Choose an upgrade" + ("  ·  %d pending" % pending if pending > 1 else "")

	# Match over.
	if phase == "over" and _last_phase != "over":
		$Root/GameOver/Center/Panel/VBox/Survived.text = "You survived %s" % _clock(h.get("time_s", 0.0))
		$Root/GameOver/Center/Panel/VBox/Stats.text = "Reached wave %d  ·  level %d" % [h.get("wave", 0), me.get("level", 1)]
	_over.visible = phase == "over"
	_banner.visible = phase != "over"
	if phase == "over":
		$Root/GameOver/Center/Panel/VBox/Back.modulate.a = 0.6 + 0.4 * sin(_t * 4.0)

	if phase == "match" and int(h.get("wave", 0)) > _last_wave and _last_wave > 0:
		_show_banner("WAVE %d" % h.wave, UiTheme.CYAN)
	_last_wave = h.get("wave", 0) if phase == "match" else 0
	_last_phase = phase


func _update_side(lobby: bool) -> void:
	var present := []
	for p: Dictionary in Game.hud.get("players", []):
		if p.get("present", false):
			present.append(p)
	# Solo: nothing to list in the match, and no code in the lobby.
	_side.visible = Game.is_online() or (lobby and present.size() > 1)
	if not _side.visible:
		return
	_side_heading.text = "Lobby" if lobby else "Squad"
	_code_row.visible = lobby and (Game.lobby_code != "" or Game.lan_address != "")
	_code_label.text = "Code" if Game.lobby_code != "" else "LAN"
	_code.text = Game.lobby_code if Game.lobby_code != "" else Game.lan_address
	_code.add_theme_font_size_override(&"font_size", 30 if Game.lobby_code != "" else 18)
	_side_hint.visible = lobby
	if present.size() < 2:
		match Game.mode:
			Game.Mode.HOST:
				_side_hint.text = "Waiting for a friend. Share the code; they join from the main menu."
			Game.Mode.HOST_LAN:
				_side_hint.text = "Waiting for a friend. They pick Join by address and type the address above."
			_:
				_side_hint.text = "Waiting for players."
	else:
		_side_hint.text = "Anyone walking out of the circle starts the match."
	var local_slot: int = Game.hud.get("local_slot", 0)
	for i in _rows.size():
		var row := _rows[i]
		var show := i < present.size()
		row.box.visible = show
		if not show:
			continue
		var p: Dictionary = present[i]
		row.dot.color = UiTheme.slot_color(p.slot)
		row.name.text = Game.player_name(p) + (" (you)" if p.slot == local_slot else "")
		row.bar.visible = not lobby
		if lobby:
			row.status.text = "ready"
		elif not p.alive:
			row.status.text = "down %.0fs" % ceilf(p.respawn_s)
		else:
			row.status.text = "LV %d" % p.level
		row.bar.max_value = p.hp_max
		row.bar.value = p.hp


func _make_row() -> Dictionary:
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 2)
	var line := HBoxContainer.new()
	line.add_theme_constant_override(&"separation", 8)
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(12, 12)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var name := Label.new()
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var status := Label.new()
	status.theme_type_variation = &"Dim"
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 6)
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(dot)
	line.add_child(name)
	line.add_child(status)
	box.add_child(line)
	box.add_child(bar)
	_list.add_child(box)
	return {"box": box, "dot": dot, "name": name, "status": status, "bar": bar}


func _on_sim_event(kind: StringName, _tick: int, entity: int, _pos: Vector3, value: float) -> void:
	match kind:
		&"match_started":
			_show_banner("SURVIVE!", UiTheme.ACCENT)
		&"level_up":
			if entity == int(Game.hud.get("local_slot", 0)):
				_show_banner("LEVEL %d" % int(value), Color("ffd23f"))
		&"player_joined":
			_show_banner("A PLAYER JOINED", UiTheme.GOOD, 32)
		&"player_left":
			_show_banner("A PLAYER LEFT", UiTheme.TEXT_DIM, 32)


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


func _choose(option: int) -> void:
	Sfx.play(&"click")
	Game.session.choose_levelup(option)


func _copy_code() -> void:
	DisplayServer.clipboard_set(Game.lobby_code if Game.lobby_code != "" else Game.lan_address.get_slice(",", 0))
	Sfx.play(&"gem")
	_copy.text = "Copied!"
	get_tree().create_timer(1.2).timeout.connect(func() -> void:
		if is_instance_valid(_copy):
			_copy.text = "Copy")


static func _clock(seconds: float) -> String:
	var s := int(seconds)
	return "%02d:%02d" % [s / 60, s % 60]
