extends CanvasLayer
## The in-game HUD, built in code: the run timer and the best time, the checkpoint, a crosshair, the local player's
## state (holding, charge, held, stunned, fallen), the shared session panel and controls list, and banners for
## run events.

const KEYS_HELD := [["Space (mash)", "Break free"], ["Esc", "Menu"]]
const PAD_HELD := [["A (mash)", "Break free"], ["Start", "Menu"]]
const KEYS_HOLDING := [["WASD", "Move"], ["Mouse", "Look"], ["Space", "Jump"], ["LMB / E", "Drop"],
	["Hold RMB / Q", "Charge, release to throw"], ["Esc", "Menu"]]
const PAD_HOLDING := [["Left stick", "Move"], ["Right stick", "Look"], ["A", "Jump"], ["RT", "Drop"],
	["Hold LT", "Charge, release to throw"], ["Start", "Menu"]]
const KEYS := [["WASD", "Move"], ["Mouse", "Look"], ["Space", "Jump"], ["LMB / E", "Grab"], ["Esc", "Menu"]]
const PAD := [["Left stick", "Move"], ["Right stick", "Look"], ["A", "Jump"], ["RT", "Grab"], ["Start", "Menu"]]

var _phase: Label
var _timer: Label
var _best: Label
var _state: Label
var _banner: Label
var _charge: ProgressBar
var _session: SessionPanel
var _controls: ControlsPanel
var _banner_t := 0.0


func _ready() -> void:
	var root := Control.new()
	root.name = &"Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	var top := VBoxContainer.new()
	top.set_anchors_preset(Control.PRESET_CENTER_TOP)
	top.position = Vector2(-200, 14)
	top.custom_minimum_size = Vector2(400, 0)
	root.add_child(top)
	_phase = _label(top, &"Dim")
	_timer = _label(top, &"Heading")
	_best = _label(top, &"Dim")
	var cross := _label(root, &"")
	cross.text = "·"
	cross.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cross.add_theme_font_size_override(&"font_size", 28)
	_centre(cross, Rect2(-20, -20, 40, 40))
	_state = _label(root, &"")
	_centre(_state, Rect2(-200, 40, 400, 30))
	_charge = ProgressBar.new()
	_charge.show_percentage = false
	_charge.max_value = 1.0
	root.add_child(_charge)
	_centre(_charge, Rect2(-80, 24, 160, 10))
	_banner = _label(root, &"Heading")
	_banner.add_theme_font_size_override(&"font_size", 48)
	_banner.visible = false
	_centre(_banner, Rect2(-300, -140, 600, 60))
	_session = SessionPanel.new()
	root.add_child(_session)
	_controls = ControlsPanel.new()
	root.add_child(_controls)
	Game.session.sim_event.connect(_on_sim_event)


func _process(delta: float) -> void:
	var h := Game.hud
	var phase: String = h.get("phase", "hub")
	var checkpoint: int = h.get("checkpoint", -1)
	var run_s: float = h.get("run_s", 0.0)
	var reset_in_s: float = h.get("reset_in_s", 0.0)
	var best_s: float = h.get("best_s", 0.0)
	match phase:
		"run":
			_phase.text = "RUN  ·  checkpoint %d" % maxi(checkpoint, 0)
			_timer.text = _time(run_s)
		"finished":
			_phase.text = "FINISHED  ·  back to the hub in %d" % ceili(reset_in_s)
			_timer.text = _time(run_s)
		_:
			_phase.text = "HUB"
			_timer.text = ""
	var best := _best_time(best_s)
	_best.text = "best %s" % _time(best) if best > 0.0 else ""
	_session.refresh(_session_rows(), phase == "hub", "Walk through the start gate to start the run.")

	var me := Game.local_player_info()
	var holding: bool = me.get("holding", &"none") != &"none"
	var held: bool = me.get("held", false)
	_charge.value = me.get("charge", 0.0)
	_charge.visible = holding and _charge.value > 0.0
	if held:
		_state.text = Game.hint("Mash Space to break free!", "Mash A to break free!")
	elif me.get("fallen", false):
		_state.text = "Oops!"
	elif me.get("stunned", false):
		_state.text = "Dazed"
	else:
		_state.text = ""
	if held:
		_controls.refresh(KEYS_HELD, PAD_HELD)
	elif holding:
		_controls.refresh(KEYS_HOLDING, PAD_HOLDING)
	else:
		_controls.refresh(KEYS, PAD)

	_banner_t = maxf(_banner_t - delta, 0.0)
	_banner.visible = _banner_t > 0.0
	_banner.modulate.a = clampf(_banner_t, 0.0, 1.0)


func _session_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for p in Game.present_players():
		var tags: Array[String] = []
		if p.get("held", false):
			tags.append("held")
		if p.get("stunned", false):
			tags.append("dazed")
		if p.get("fallen", false):
			tags.append("fell")
		rows.append({"player": p.player, "name": Game.player_name(p), "status": ", ".join(tags)})
	return rows


## The better of this session's best (the sim's) and the personal best kept in the settings; 0 when neither.
static func _best_time(session_best: float) -> float:
	var saved: float = Settings.get_value(&"best_time")
	if saved <= 0.0 or (session_best > 0.0 and session_best < saved):
		return session_best
	return saved


func _show_banner(text: String, seconds := 2.0) -> void:
	_banner.text = text
	_banner_t = seconds


## Verified events only (as the banners always were).
func _on_sim_event(event: UnifiedEvent, state: int) -> void:
	if state != UnifiedSession.EVENT_CONFIRMED:
		return
	if event is EventRunStarted:
		_show_banner("GO!", 1.5)
	elif event is EventCheckpoint:
		_show_banner("Checkpoint %d" % (event as EventCheckpoint).index, 1.5)
	elif event is EventRunFinished:
		var seconds := (event as EventRunFinished).seconds
		_show_banner("Finished in %s" % _time(seconds), 4.0)
		var saved: float = Settings.get_value(&"best_time")
		if saved <= 0.0 or seconds < saved:
			Settings.set_value(&"best_time", seconds)


## Places a control at `rect` relative to the screen centre.
static func _centre(c: Control, rect: Rect2) -> void:
	c.set_anchors_preset(Control.PRESET_CENTER)
	c.offset_left = rect.position.x
	c.offset_top = rect.position.y
	c.offset_right = rect.end.x
	c.offset_bottom = rect.end.y


static func _label(parent: Control, variation: StringName) -> Label:
	var l := Label.new()
	l.theme_type_variation = variation
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


static func _time(s: float) -> String:
	return "%d:%04.1f" % [floori(s / 60.0), fmod(s, 60.0)]
