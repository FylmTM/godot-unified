extends Node
## The app's flow: owns the session for the app's lifetime and switches scenes on its status.
##
##   MENU --start/host/join--> CONNECTING --"connected"--> PLAYING --leave--> MENU
##                                  \--"failed"--> MENU (error shown)      \--"failed"/"disconnected"--> MENU
##
## The session is the native `UnifiedSession` when the game library is loaded, else the GDScript `MockSession`
## (same API). `-- --mock` forces the mock. Everything reads the sim through `Game.hud` (refreshed once per frame).

signal flow_changed(flow: Flow)
signal status_changed(status: String, detail: String)
signal lobby_code_changed(code: String)

enum Flow { MENU, CONNECTING, PLAYING }
enum Mode { SINGLE, HOST, JOIN }

const MENU_SCENE := "res://game/ui/main_menu.tscn"
const ARENA_SCENE := "res://game/arena/arena.tscn"
const CONNECT_OVERLAY := preload("res://game/ui/connect_overlay.tscn")

var session: Node
var is_mock := false
var flow := Flow.MENU
var mode := Mode.SINGLE
var status := "idle"
var status_detail := ""
var lobby_code := ""
## Shown by the main menu once after a failure, then cleared.
var last_error := ""
## The sim's HUD dictionary (contract: phase, tick, time_s, wave, ...), refreshed every frame.
var hud: Dictionary = {}

var _overlay_layer: CanvasLayer
var _connect_overlay: Control
var _fps_label: Label
var _debug_label: Label


func _ready() -> void:
	process_priority = -100  # refresh `hud` before any other node reads it
	process_mode = Node.PROCESS_MODE_ALWAYS
	UiTheme.install()
	var force_mock := "--mock" in OS.get_cmdline_user_args()
	if not force_mock and ClassDB.class_exists(&"UnifiedSession"):
		session = ClassDB.instantiate(&"UnifiedSession")
	else:
		session = MockSession.new()
		is_mock = true
	session.name = "Session"
	add_child(session)
	session.status_changed.connect(_on_status_changed)
	session.lobby_code.connect(_on_lobby_code)
	hud = session.hud()

	_overlay_layer = CanvasLayer.new()
	_overlay_layer.layer = 50
	add_child(_overlay_layer)
	_fps_label = Label.new()
	_fps_label.theme_type_variation = &"Dim"
	_fps_label.position = Vector2(10, 6)
	_fps_label.visible = Settings.get_value(&"show_fps")
	var fps_layer := CanvasLayer.new()
	fps_layer.layer = 100
	add_child(fps_layer)
	fps_layer.add_child(_fps_label)
	Settings.changed.connect(_on_setting_changed)
	_fit_window.call_deferred()
	# Release smoke test (tools/release.py runs the export headless with `-- --smoke-test`): exercise the sim too.
	if "--smoke-test" in OS.get_cmdline_user_args():
		print("survivor: smoke test, %s session, starting single player" % ("mock" if is_mock else "native"))
		play_single.call_deferred()


func _process(_delta: float) -> void:
	hud = session.hud()
	if _fps_label.visible:
		_fps_label.text = "%d FPS" % Engine.get_frames_per_second()
	if _debug_label != null and _debug_label.visible:
		_debug_label.text = _debug_text()


func _unhandled_input(event: InputEvent) -> void:
	# With the native session the dev UI owns F1; the mock gets a plain text dump instead.
	if is_mock and event.is_action_pressed(&"toggle_devui"):
		_toggle_debug()
		get_viewport().set_input_as_handled()


# --- Flow API (menus call these) ----------------------------------------------------------------


func play_single() -> void:
	_begin(Mode.SINGLE)
	session.start_single()


func host_online() -> void:
	_begin(Mode.HOST)
	session.host_online()


func join_online(code: String) -> void:
	_begin(Mode.JOIN)
	session.join_online(code)


func join_direct(address: String) -> void:
	_begin(Mode.JOIN)
	session.join_direct(address)


## Leave the match (or cancel connecting) and return to the main menu.
func leave_to_menu(error := "") -> void:
	last_error = error
	if status != "idle":
		session.leave()
	lobby_code = ""
	_hide_connect_overlay()
	if flow != Flow.MENU:
		_set_flow(Flow.MENU)
		get_tree().change_scene_to_file(MENU_SCENE)


func is_online() -> bool:
	return mode != Mode.SINGLE


func local_player() -> Dictionary:
	var slot: int = hud.get("local_slot", 0)
	for p: Dictionary in hud.get("players", []):
		if p.get("slot", -1) == slot:
			return p
	return {}


## Display name for a HUD player entry: the synced name when the session has one, else "P<n>".
static func player_name(p: Dictionary) -> String:
	var n := String(p.get("name", ""))
	return n if n != "" else "P%d" % (int(p.get("slot", 0)) + 1)


# --- Internals ----------------------------------------------------------------------------------


func _begin(m: Mode) -> void:
	mode = m
	last_error = ""
	lobby_code = ""
	if session.has_method(&"set_player_name"):
		session.set_player_name(Settings.get_value(&"player_name"))
	_set_flow(Flow.CONNECTING)
	if m != Mode.SINGLE:
		_show_connect_overlay()


func _set_flow(f: Flow) -> void:
	flow = f
	flow_changed.emit(f)


func _on_status_changed(new_status: String, detail: String) -> void:
	status = new_status
	status_detail = detail
	status_changed.emit(new_status, detail)
	match new_status:
		"connected":
			if flow == Flow.CONNECTING:
				_hide_connect_overlay()
				_set_flow(Flow.PLAYING)
				get_tree().change_scene_to_file(ARENA_SCENE)
		"failed":
			leave_to_menu(detail if detail != "" else "Connection failed.")
		"disconnected":
			if flow != Flow.MENU:
				leave_to_menu("Disconnected" + (": " + detail if detail != "" else "."))


func _on_lobby_code(code: String) -> void:
	lobby_code = code
	lobby_code_changed.emit(code)


func _show_connect_overlay() -> void:
	if _connect_overlay == null:
		_connect_overlay = CONNECT_OVERLAY.instantiate()
		_overlay_layer.add_child(_connect_overlay)


func _hide_connect_overlay() -> void:
	if _connect_overlay != null:
		_connect_overlay.queue_free()
		_connect_overlay = null


func _on_setting_changed(key: StringName, value: Variant) -> void:
	if key == &"show_fps":
		_fps_label.visible = value


## macOS Retina: the project size is in pixels, so a 1280x720 window opens at half size. Scale it once at boot.
func _fit_window() -> void:
	if DisplayServer.get_name() == "headless" or "--no-settings" in OS.get_cmdline_user_args():
		return
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	var scale := DisplayServer.screen_get_scale()
	if scale <= 1.0:
		return
	var size := Vector2i(Vector2(1280, 720) * scale)
	var usable := DisplayServer.screen_get_usable_rect()
	size = size.min(usable.size * 9 / 10)
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(usable.position + (usable.size - size) / 2)


func _toggle_debug() -> void:
	if _debug_label == null:
		_debug_label = Label.new()
		_debug_label.theme_type_variation = &"Dim"
		_debug_label.position = Vector2(12, 120)
		_debug_label.add_theme_color_override(&"font_color", UiTheme.CYAN)
		_overlay_layer.add_child(_debug_label)
		_debug_label.visible = false
	_debug_label.visible = not _debug_label.visible


func _debug_text() -> String:
	var lines := ["mock session (F1)  status=%s  flow=%s" % [status, Flow.keys()[flow]]]
	for key: String in ["phase", "tick", "time_s", "wave", "enemies_alive", "local_slot"]:
		lines.append("%s: %s" % [key, str(hud.get(key))])
	for p: Dictionary in hud.get("players", []):
		if p.get("present", false):
			lines.append("  slot %d %s hp %d lv %d xp %d/%d pending %d" % [p.slot, player_name(p), p.hp, p.level, p.xp, p.xp_next, p.pending_levelups])
	return "\n".join(lines)
