extends CanvasLayer
## In-game HUD, built in code: the phase and wave, the match time, the station's HP bar, the score; the lobby's
## start prompt (Enter or the Start button: the `start` command) and the restart prompt when the match is over
## (`restart`); banners for waves and the match's start and end; the session panel (code + players) and the
## controls list.

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
	Game.session.sim_event.connect(_on_sim_event)


func _process(delta: float) -> void:
	var h: DataHud = Unified.data.hud
	var phase := h.phase
	var wave := h.wave
	match phase:
		EnumPhase.MATCH:
			_phase.text = "WAVE %d  ·  next wave in %d s" % [wave, ceili(h.next_wave_s)]
			_time.text = _time_text(h.time_s)
		EnumPhase.OVER:
			_phase.text = "STATION LOST  ·  wave %d" % wave
			_time.text = _time_text(h.time_s)
		_:
			_phase.text = "LOBBY"
			_time.text = ""
	var hp := h.station_hp
	var hp_max := maxi(h.station_max, 1)
	var frac := clampf(float(hp) / hp_max, 0.0, 1.0)
	_hp_shown = lerpf(_hp_shown, frac, 1.0 - exp(-delta * 10.0))
	_hp.value = _hp_shown
	_hp_label.text = "STATION  %d / %d" % [maxi(hp, 0), hp_max]
	var fill := UiTheme.GOOD if frac > 0.5 else (UiTheme.GOLD if frac > 0.25 else UiTheme.BAD)
	var sb := _hp.get_theme_stylebox(&"fill") as StyleBoxFlat
	if sb != null and sb.bg_color != fill:
		_hp.add_theme_stylebox_override(&"fill", UiTheme.box(fill, 6, 0))
	var best := Settings.best_time
	_score.text = "score %d  ·  rocks %d%s" % [h.score, h.rocks,
		("  ·  best %s" % _time_text(best)) if best > 0.0 else ""]

	_prompt.visible = phase == EnumPhase.LOBBY or phase == EnumPhase.OVER
	var keys := Game.hint("Enter", "X")
	if phase == EnumPhase.LOBBY:
		_prompt_text.text = "Press %s or click Start to start" % keys
		_prompt_sub.text = "Rocks drift in from the edges in waves. Keep them off the station."
		start_button.text = "Start"
	elif phase == EnumPhase.OVER:
		_prompt_text.text = "The station is lost: you held out %s" % _time_text(h.time_s)
		_prompt_sub.text = "Back to the lobby in %d s" % ceili(h.reset_in_s)
		start_button.text = "Restart"

	var rows: Array[Dictionary] = []
	for player in Unified.session.get_players():
		var info := Unified.data.hud.players[Unified.session.get_player_slot(player)] as DataHudPlayer
		rows.append({"player": player, "name": Unified.session.get_player_name(player), "status": "%d gems" % info.gems})
	_session.refresh(rows, phase == EnumPhase.LOBBY, "Press %s or click Start when everyone is in." % keys)
	var kb := [["WASD", "Move"], ["Mouse", "Aim"], ["LMB / Space", "Fire"], ["RMB / Shift", "Boost"]]
	var pad := [["Left stick", "Move"], ["Right stick", "Aim"], ["RT", "Fire"], ["LT / A", "Boost"]]
	if phase == EnumPhase.LOBBY:
		kb.append(["Enter", "Start"])
		pad.append(["X", "Start"])
	elif phase == EnumPhase.OVER:
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
	match Unified.data.hud.phase:
		EnumPhase.LOBBY:
			Sfx.play(&"click")
			Unified.session.send_command(CommandStart.new())
		EnumPhase.OVER:
			Sfx.play(&"click")
			Unified.session.send_command(CommandRestart.new())


func _show_banner(text: String, seconds := 2.0) -> void:
	_banner.text = text
	_banner_t = seconds


## Banners and the best time, once an event's tick is confirmed.
func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state != UnifiedSession.EVENT_CONFIRMED:
		return
	if event is EventMatchStarted:
		_show_banner("Defend the station!", 2.0)
	elif event is EventWave:
		var wave := (event as EventWave).wave
		if wave > 1:
			_show_banner("Wave %d" % wave, 2.0)
	elif event is EventMatchOver:
		_show_banner("Station lost", 3.0)
		var survived := (event as EventMatchOver).seconds_survived
		var best := Settings.best_time
		if survived > best:
			Settings.best_time = survived


static func _label(parent: Control, variation: StringName, align: HorizontalAlignment) -> Label:
	var l := Label.new()
	l.theme_type_variation = variation
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


static func _time_text(s: float) -> String:
	return "%d:%04.1f" % [floori(s / 60.0), fmod(s, 60.0)]
