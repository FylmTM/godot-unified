extends CanvasLayer
## In-game HUD, built in code: the run timer and best time, the checkpoint, a crosshair, the local player's state
## (holding, charge, held, stunned, fallen), the players list, control hints and banners for run events.

var _timer: Label
var _best: Label
var _phase: Label
var _state: Label
var _players: Label
var _hint: Label
var _banner: Label
var _charge: ProgressBar
var _cross: Label
var _banner_t := 0.0


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
	_players = _label(root, "Dim", HORIZONTAL_ALIGNMENT_LEFT)
	_players.position = Vector2(16, 14)
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
	_hint = _label(root, "Dim", HORIZONTAL_ALIGNMENT_CENTER)
	_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hint.position = Vector2(-450, -40)
	_hint.custom_minimum_size = Vector2(900, 0)
	_banner = _label(root, "Heading", HORIZONTAL_ALIGNMENT_CENTER)
	_banner.set_anchors_preset(Control.PRESET_CENTER)
	_banner.position = Vector2(-300, -140)
	_banner.custom_minimum_size = Vector2(600, 0)
	_banner.add_theme_font_size_override(&"font_size", 48)
	_banner.visible = false
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
	var lines: Array[String] = []
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
		lines.append("%s%s" % [Game.player_name(p), ("  (" + ", ".join(tags) + ")") if not tags.is_empty() else ""])
	_players.text = "\n".join(lines)
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
	if holding != 0:
		_hint.text = Game.hint("LMB / E drop  ·  hold RMB / Q to charge, release to throw  ·  Space jump",
			"RT drop  ·  hold LT to charge, release to throw  ·  A jump")
	else:
		_hint.text = Game.hint("WASD move  ·  mouse look  ·  Space jump  ·  LMB / E grab  ·  Esc menu",
			"Left stick move  ·  right stick look  ·  A jump  ·  RT grab  ·  Start menu")
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
