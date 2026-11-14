extends UnifiedGame
## survivor's flow (the shared one, UnifiedGame), with its GDScript stand-in for the game library: in a dev run
## without the library, or with `-- --mock`, the session is the mock (game/session/mock_session.gd, the same API, a
## fake sim). Exports never ship the mock (export_presets.cfg excludes game/session/). With the mock, F1 shows a
## plain text dump of the sim's state (the native session's dev UI owns F1 otherwise).

## Loaded by path, not class name: exports exclude game/session/.
const MOCK_SESSION := "res://game/session/mock_session.gd"

var _debug_label: Label


func _create_session() -> Node:
	var exported := OS.has_feature("template")
	var force_mock := not exported and "--mock" in OS.get_cmdline_user_args()
	if not force_mock and ClassDB.class_exists(&"UnifiedSession"):
		return ClassDB.instantiate(&"UnifiedSession")
	if exported:
		return null
	is_mock = true
	return (load(MOCK_SESSION) as GDScript).new()


func _process(delta: float) -> void:
	super(delta)
	if _debug_label != null and _debug_label.visible:
		_debug_label.text = _debug_text()


func _unhandled_input(event: InputEvent) -> void:
	if is_mock and event.is_action_pressed(&"toggle_devui"):
		_toggle_debug()
		get_viewport().set_input_as_handled()


func _toggle_debug() -> void:
	if _debug_label == null:
		_debug_label = Label.new()
		_debug_label.theme_type_variation = &"Dim"
		_debug_label.position = Vector2(12, 120)
		_debug_label.add_theme_color_override(&"font_color", UiTheme.CYAN)
		_debug_label.visible = false
		var layer := CanvasLayer.new()
		layer.layer = 50
		add_child(layer)
		layer.add_child(_debug_label)
	_debug_label.visible = not _debug_label.visible


func _debug_text() -> String:
	var lines: Array[String] = ["mock session (F1)  status=%s  flow=%s" % [status, Flow.keys()[flow]]]
	for key: String in ["phase", "tick", "time_s", "wave", "enemies_alive", "local_player"]:
		lines.append("%s: %s" % [key, str(hud.get(key))])
	for p in present_players():
		lines.append("  player %d %s hp %d lv %d xp %d/%d pending %d" % [p.player, player_name(p), p.hp, p.level, p.xp,
			p.xp_next, p.pending_levelups])
	return "\n".join(lines)
