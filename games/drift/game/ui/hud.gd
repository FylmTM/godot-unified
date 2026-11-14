extends CanvasLayer
## In-game HUD, built in code: the phase and wave, the match time, the station's HP bar, the score; the lobby's
## start prompt (Enter or the Start button: the `start` command) and the restart prompt when the match is over
## (`restart`); banners for waves and the match's start and end; the session panel (code + players) and the
## controls list (games/shared).

## The prompt's button (Start in the lobby, Restart when over); the tour clicks it.
var start_button: Button
var _phase: Label
var _time: Label
var _hp: ProgressBar
var _hp_label: Label
var _score: Label
var _prompt: PanelContainer
var _prompt_text: Label
var _prompt_sub: Label
var _banner: Label
var _banner_t := 0.0
var _hp_shown := 1.0
var _session: SessionPanel
var _controls: ControlsPanel


func _ready() -> void:
	var root := Control.new()
	root.name = &"Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	var top := VBoxContainer.new()
	top.set_anchors_preset(Control.PRESET_CENTER_TOP)
	top.position = Vector2(-210, 12)
	top.custom_minimum_size = Vector2(420, 0)
	top.add_theme_constant_override(&"separation", 4)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(top)
	_phase = _label(top, &"Dim", HORIZONTAL_ALIGNMENT_CENTER)
	_time = _label(top, &"Heading", HORIZONTAL_ALIGNMENT_CENTER)
	_hp = ProgressBar.new()
	_hp.custom_minimum_size = Vector2(420, 16)
	_hp.show_percentage = false
	_hp.max_value = 1.0
	_hp.value = 1.0
	_hp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(_hp)
	_hp_label = _label(_hp, &"", HORIZONTAL_ALIGNMENT_CENTER)
	_hp_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)  # added already: offsets too
	_hp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hp_label.add_theme_font_size_override(&"font_size", 12)
	_score = _label(top, &"Dim", HORIZONTAL_ALIGNMENT_CENTER)

	var bottom := CenterContainer.new()  # centres the prompt at whatever size its text gives it
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_top = -200.0
	bottom.offset_bottom = -40.0
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bottom)
	_prompt = PanelContainer.new()
	_prompt.name = &"Prompt"
	bottom.add_child(_prompt)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override(&"separation", 8)
	_prompt.add_child(pv)
	_prompt_text = _label(pv, &"Heading", HORIZONTAL_ALIGNMENT_CENTER)
	_prompt_text.add_theme_font_size_override(&"font_size", 22)
	_prompt_sub = _label(pv, &"Dim", HORIZONTAL_ALIGNMENT_CENTER)
	start_button = Button.new()
	start_button.name = &"Start"
	start_button.theme_type_variation = &"PrimaryButton"
	start_button.focus_mode = Control.FOCUS_NONE  # Space fires: never "press the focused button"
	start_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	start_button.custom_minimum_size = Vector2(180, 0)
	start_button.pressed.connect(_start_or_restart)
	pv.add_child(start_button)

	_banner = _label(root, &"Heading", HORIZONTAL_ALIGNMENT_CENTER)
	_banner.add_theme_font_size_override(&"font_size", 44)
	_banner.visible = false
	# 600 px wide, 170 px above the centre (anchors first, then the offsets: `position` would put it off screen)
	_banner.set_anchors_preset(Control.PRESET_CENTER)
	_banner.offset_left = -300.0
	_banner.offset_right = 300.0
	_banner.offset_top = -170.0
	_banner.offset_bottom = -110.0
	_session = SessionPanel.new()
	root.add_child(_session)
	_controls = ControlsPanel.new()
	root.add_child(_controls)
	Game.session.sim_event_2d.connect(_on_sim_event)


func _process(delta: float) -> void:
	var h := Game.hud
	var phase: String = h.get("phase", "lobby")
	var wave: int = h.get("wave", 0)
	match phase:
		"match":
			_phase.text = "WAVE %d  ·  next wave in %d s" % [wave, ceili(h.get("next_wave_s", 0.0))]
			_time.text = _time_text(h.get("time_s", 0.0))
		"over":
			_phase.text = "STATION LOST  ·  wave %d" % wave
			_time.text = _time_text(h.get("time_s", 0.0))
		_:
			_phase.text = "LOBBY"
			_time.text = ""
	var hp: int = h.get("station_hp", 100)
	var hp_max: int = maxi(int(h.get("station_max", 100)), 1)
	var frac := clampf(float(hp) / hp_max, 0.0, 1.0)
	_hp_shown = lerpf(_hp_shown, frac, 1.0 - exp(-delta * 10.0))
	_hp.value = _hp_shown
	_hp_label.text = "STATION  %d / %d" % [maxi(hp, 0), hp_max]
	var fill := UiTheme.GOOD if frac > 0.5 else (UiTheme.GOLD if frac > 0.25 else UiTheme.BAD)
	var sb := _hp.get_theme_stylebox(&"fill") as StyleBoxFlat
	if sb != null and sb.bg_color != fill:
		_hp.add_theme_stylebox_override(&"fill", UiTheme.box(fill, 6, 0))
	var best: float = Settings.get_value(&"best_time")
	_score.text = "score %d  ·  rocks %d%s" % [int(h.get("score", 0)), int(h.get("rocks", 0)),
		("  ·  best %s" % _time_text(best)) if best > 0.0 else ""]

	_prompt.visible = phase == "lobby" or phase == "over"
	var keys := Game.hint("Enter", "X")
	if phase == "lobby":
		_prompt_text.text = "Press %s or click Start to start" % keys
		_prompt_sub.text = "Rocks drift in from the edges in waves. Keep them off the station."
		start_button.text = "Start"
	elif phase == "over":
		_prompt_text.text = "The station is lost: you held out %s" % _time_text(h.get("time_s", 0.0))
		_prompt_sub.text = "Back to the lobby in %d s" % ceili(h.get("reset_in_s", 0.0))
		start_button.text = "Restart"

	var rows: Array[Dictionary] = []
	for p in Game.present_players():
		rows.append({"slot": p.slot, "name": Game.player_name(p), "status": "%d gems" % int(p.get("gems", 0))})
	_session.refresh(rows, phase == "lobby", "Press %s or click Start when everyone is in." % keys)
	var kb := [["WASD", "Move"], ["Mouse", "Aim"], ["LMB / Space", "Fire"], ["RMB / Shift", "Boost"]]
	var pad := [["Left stick", "Move"], ["Right stick", "Aim"], ["RT", "Fire"], ["LT / A", "Boost"]]
	if phase == "lobby":
		kb.append(["Enter", "Start"])
		pad.append(["X", "Start"])
	elif phase == "over":
		kb.append(["Enter", "Restart"])
		pad.append(["X", "Restart"])
	kb.append(["Esc", "Menu"])
	pad.append(["Start", "Menu"])
	_controls.refresh(kb, pad)
	_banner_t = maxf(_banner_t - delta, 0.0)
	_banner.visible = _banner_t > 0.0
	_banner.modulate.a = clampf(_banner_t, 0.0, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"start"):
		get_viewport().set_input_as_handled()
		_start_or_restart()


## The lobby's `start` or the over screen's `restart` command (anyone may send either).
func _start_or_restart() -> void:
	match String(Game.hud.get("phase", "")):
		"lobby":
			Sfx.play(&"click")
			Game.send_command(&"start")
		"over":
			Sfx.play(&"click")
			Game.send_command(&"restart")


func _show_banner(text: String, seconds := 2.0) -> void:
	_banner.text = text
	_banner_t = seconds


func _on_sim_event(kind: StringName, _tick: int, _entity: int, _pos: Vector2, value: float) -> void:
	match kind:
		&"match_started":
			_show_banner("Defend the station!", 2.0)
		&"wave":
			if int(value) > 1:
				_show_banner("Wave %d" % int(value), 2.0)
		&"match_over":
			_show_banner("Station lost", 3.0)
			var best: float = Settings.get_value(&"best_time")
			if value > best:
				Settings.set_value(&"best_time", value)


static func _label(parent: Control, variation: StringName, align: HorizontalAlignment) -> Label:
	var l := Label.new()
	l.theme_type_variation = variation
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


static func _time_text(s: float) -> String:
	return "%d:%04.1f" % [floori(s / 60.0), fmod(s, 60.0)]
