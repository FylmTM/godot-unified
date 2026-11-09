extends CanvasLayer
## In-game HUD, built in code: the run timer and best time, the checkpoint, a crosshair, the local player's state
## (holding, charge, held, stunned, fallen), the session panel (code + players) and the controls list (both shared
## with the other games), and banners for run events.

var _timer: Label
var _best: Label
var _phase: Label
var _state: Label
var _banner: Label
var _charge: ProgressBar
var _cross: Label
var _banner_t := 0.0
var _session: SessionPanel
var _controls: ControlsPanel


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	var top := VBoxContainer.new()
	top.set_anchors_preset(Control.PRESET_CENTER_TOP)
	top.position = Vector2(-200, 14)
	top.custom_minimum_size = Vector2(400, 0)
	top.alignment = BoxContainer.ALIGNMENT_BEGIN
	root.add_child(top)
	_phase = _label(top, "Dim", HORIZONTAL_ALIGNMENT_CENTER)
	_timer = _label(top, "Heading", HORIZONTAL_ALIGNMENT_CENTER)
	_best = _label(top, "Dim", HORIZONTAL_ALIGNMENT_CENTER)
	_cross = _label(root, "", HORIZONTAL_ALIGNMENT_CENTER)
	_cross.text = "·"
	_cross.set_anchors_preset(Control.PRESET_CENTER)
	_cross.add_theme_font_size_override(&"font_size", 28)
	_state = _label(root, "", HORIZONTAL_ALIGNMENT_CENTER)
	_state.set_anchors_preset(Control.PRESET_CENTER)
	_state.position.y += 40
	_charge = ProgressBar.new()
	_charge.set_anchors_preset(Control.PRESET_CENTER)
	_charge.custom_minimum_size = Vector2(160, 10)
	_charge.position += Vector2(-80, 24)
	_charge.show_percentage = false
	_charge.max_value = 1.0
	root.add_child(_charge)
	_banner = _label(root, "Heading", HORIZONTAL_ALIGNMENT_CENTER)
	_banner.set_anchors_preset(Control.PRESET_CENTER)
	_banner.position = Vector2(-300, -140)
	_banner.custom_minimum_size = Vector2(600, 0)
	_banner.add_theme_font_size_override(&"font_size", 48)
	_banner.visible = false
	_session = SessionPanel.new()
	root.add_child(_session)
	_controls = ControlsPanel.new()
	root.add_child(_controls)
	Game.session.sim_event.connect(_on_sim_event)


func _label(parent: Control, variation: String, align: HorizontalAlignment) -> Label:
	var l := Label.new()
	if variation != "":
		l.theme_type_variation = StringName(variation)
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


static func _time(s: float) -> String:
	return "%d:%04.1f" % [floori(s / 60.0), fmod(s, 60.0)]


func _process(delta: float) -> void:
	var h := Game.hud
	var phase: String = h.get("phase", "hub")
	var best: float = h.get("best_s", 0.0)
	match phase:
		"run":
			_phase.text = "RUN  ·  checkpoint %d" % maxi(int(h.get("checkpoint", -1)), 0)
			_timer.text = _time(h.get("run_s", 0.0))
		"finished":
			_phase.text = "FINISHED  ·  back to the hub in %d" % ceili(h.get("reset_in_s", 0.0))
			_timer.text = _time(h.get("run_s", 0.0))
		_:
			_phase.text = "HUB"
			_timer.text = ""
	_best.text = "best %s" % _time(best) if best > 0.0 else ""
	var rows := []
	for p: Dictionary in h.get("players", []):
		if not p.get("present", false):
			continue
		var tags: Array[String] = []
		if p.get("held", false):
			tags.append("held")
		if p.get("stunned", false):
			tags.append("dazed")
		if p.get("fallen", false):
			tags.append("fell")
		rows.append({"slot": p.slot, "name": Game.player_name(p), "status": ", ".join(tags)})
	_session.refresh(rows, phase == "hub", "Walk through the start gate to start the run.")
	var me := Game.local_player()
	var holding: int = me.get("holding", 0)
	_charge.value = me.get("charge", 0.0)
	_charge.visible = holding != 0 and _charge.value > 0.0
	if me.get("held", false):
		_state.text = Game.hint("Mash Space to break free!", "Mash A to break free!")
	elif me.get("fallen", false):
		_state.text = "Oops!"
	elif me.get("stunned", false):
		_state.text = "Dazed"
	else:
		_state.text = ""
	if me.get("held", false):
		_controls.refresh([["Space (mash)", "Break free"], ["Esc", "Menu"]], [["A (mash)", "Break free"], ["Start", "Menu"]])
	elif holding != 0:
		_controls.refresh(
			[["WASD", "Move"], ["Mouse", "Look"], ["Space", "Jump"], ["LMB / E", "Drop"],
				["Hold RMB / Q", "Charge, release to throw"], ["Esc", "Menu"]],
			[["Left stick", "Move"], ["Right stick", "Look"], ["A", "Jump"], ["RT", "Drop"],
				["Hold LT", "Charge, release to throw"], ["Start", "Menu"]])
	else:
		_controls.refresh(
			[["WASD", "Move"], ["Mouse", "Look"], ["Space", "Jump"], ["LMB / E", "Grab"], ["Esc", "Menu"]],
			[["Left stick", "Move"], ["Right stick", "Look"], ["A", "Jump"], ["RT", "Grab"], ["Start", "Menu"]])
	_banner_t = maxf(_banner_t - delta, 0.0)
	_banner.visible = _banner_t > 0.0
	_banner.modulate.a = clampf(_banner_t, 0.0, 1.0)


func _show_banner(text: String, seconds := 2.0) -> void:
	_banner.text = text
	_banner_t = seconds


func _on_sim_event(kind: StringName, _tick: int, _entity: int, _pos: Vector3, value: float) -> void:
	match kind:
		&"run_started":
			_show_banner("GO!", 1.5)
		&"checkpoint":
			_show_banner("Checkpoint %d" % int(value), 1.5)
		&"run_finished":
			_show_banner("Finished in %s" % _time(value), 4.0)
			var best: float = Settings.get_value(&"best_time")
			if best <= 0.0 or value < best:
				Settings.set_value(&"best_time", value)
