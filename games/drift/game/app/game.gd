extends Node
## The app's flow (the `Game` autoload): owns the session for the app's lifetime and switches scenes on its status,
## whoever started it (the menus, the command line's session flags, a tool).
##
##   MENU --start/host/join--> CONNECTING --CONNECTED--> PLAYING --leave--> MENU
##                                  \--FAILED--> MENU (error shown)      \--FAILED/DISCONNECTED--> MENU
##
## The session is the native `UnifiedSession` from the game library (without the library the LibraryCheck autoload
## shows a fatal screen instead). Who plays (players, slots, names, the local player) comes from it
## (`Unified.session`); the sim's game-wide values are the game's session data, `Unified.data.hud`, and its fixed
## numbers `Unified.constants`.
## drift's views draw sim sizes (metres, from `Unified.constants`) at `Unified.view_scale` pixels per metre.

signal flow_changed(flow: Flow)
signal status_changed(status: UnifiedSession.Status, detail: String)
signal lobby_code_changed(code: String)
## The last input came from a gamepad (true) or keyboard and mouse (false): hints and key labels follow it.
signal input_device_changed(pad: bool)

enum Flow { MENU, CONNECTING, PLAYING }
enum Mode { SINGLE, HOST, HOST_LAN, JOIN }

const LAN_PORT := 7777
## The scenes the flow switches between: every game keeps its menu and play scene at these paths.
const MENU_SCENE := "res://game/ui/main_menu.tscn"
const PLAY_SCENE := "res://game/arena/arena.tscn"
const CONNECT_OVERLAY := preload("res://game/ui/connect_overlay.tscn")

var session: UnifiedSession
var flow := Flow.MENU
var mode := Mode.SINGLE
var status := UnifiedSession.STATUS_IDLE
var status_detail := ""
var lobby_code := ""
## The port Host on LAN listens on (a tool may pick another, so parallel runs don't collide).
var lan_port := LAN_PORT
## When hosting on LAN: the address friends join (host:port, first private IPv4), shown where the code would be.
var lan_address := ""
## Shown by the main menu once after a failure, then cleared.
var last_error := ""
## True while the player is using a gamepad (the last input event came from one).
var using_pad := false

var _quitting := false
var _overlay_layer: CanvasLayer
var _connect_overlay: Control
var _fps_label: Label
var _frame_ms := 16.7


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	UiTheme.install()
	if not InputMap.has_action(&"menu"):  # Esc and a pad's Start open the pause menu
		InputMap.add_action(&"menu")
		var esc := InputEventKey.new()
		esc.physical_keycode = KEY_ESCAPE
		InputMap.action_add_event(&"menu", esc)
		var start := InputEventJoypadButton.new()
		start.button_index = JOY_BUTTON_START
		InputMap.action_add_event(&"menu", start)
	get_tree().auto_accept_quit = false  # the window's close button goes through quit_app too
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.layer = 50
	add_child(_overlay_layer)
	var fps_layer := CanvasLayer.new()
	fps_layer.layer = 100
	add_child(fps_layer)
	_fps_label = Label.new()
	_fps_label.theme_type_variation = &"Dim"
	_fps_label.position = Vector2(10, 6)
	_fps_label.visible = Settings.show_fps
	fps_layer.add_child(_fps_label)
	Settings.changed.connect(_on_setting_changed)
	_fit_window.call_deferred()
	session = UnifiedSession.new()
	session.name = &"UnifiedSession"
	# before it enters the tree, where the command line's session flags start it: the flow follows from there
	session.local_name = Settings.player_name
	session.status_changed.connect(_on_status_changed)
	session.lobby_code.connect(_on_lobby_code)
	add_child(session)
	# Release smoke test (`uni release` runs the export headless with `-- --smoke-test`): exercise the sim too.
	if _smoke_test():
		print("%s: smoke test, starting single player" % _game_name())
		play_single.call_deferred()


func _process(delta: float) -> void:
	_frame_ms = lerpf(_frame_ms, delta * 1000.0 / maxf(Engine.time_scale, 0.001), 0.05)
	if _fps_label.visible:
		_fps_label.text = "%d FPS  ·  %.1f ms" % [roundi(1000.0 / maxf(_frame_ms, 0.01)), _frame_ms]


func _input(event: InputEvent) -> void:
	var pad := event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) > 0.5)
	var kbm := event is InputEventKey or event is InputEventMouseButton
	if (pad and not using_pad) or (kbm and using_pad):
		using_pad = pad
		input_device_changed.emit(pad)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit_app()


# --- The flow (menus and tools call these) -----------------------------------------------------------------------


func play_single() -> void:
	_begin(Mode.SINGLE)
	session.start_single()


func host_online() -> void:
	_begin(Mode.HOST)
	session.host_online()


func host_direct(port := lan_port) -> void:
	_begin(Mode.HOST_LAN)
	var ips := _lan_ips()
	lan_address = "%s:%d" % [ips[0] if not ips.is_empty() else "127.0.0.1", port]
	session.host_direct(port)


func join_online(code: String) -> void:
	_begin(Mode.JOIN)
	session.join_online(code)


func join_direct(address: String) -> void:
	_begin(Mode.JOIN)
	session.join_direct(address)


## Leaves the match (or cancels connecting) and returns to the main menu, showing `error` there when given.
func leave_to_menu(error := "") -> void:
	last_error = error
	if status != UnifiedSession.STATUS_IDLE:
		session.leave()
	lobby_code = ""
	lan_address = ""
	_hide_connect_overlay()
	if flow != Flow.MENU:
		_set_flow(Flow.MENU)
		get_tree().change_scene_to_file(MENU_SCENE)


## Quits the app (menus, the window's close button, tools). The session ends and every playing sound stops first
## (Sfx plays nothing more: the session's events keep arriving until the quit), and the quit waits (at most 1 s)
## until the AudioServer has freed their playbacks: one it still holds at exit is reported as leaked.
func quit_app(exit_code := 0) -> void:
	if _quitting:
		return
	_quitting = true
	if session != null and status != UnifiedSession.STATUS_IDLE:
		session.leave()
	Sfx.close()
	var playbacks: Array[WeakRef] = []
	for type: String in ["AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D"]:
		for player: Node in get_tree().root.find_children("*", type, true, false):
			if player.call(&"has_stream_playback"):
				playbacks.append(weakref(player.call(&"get_stream_playback")))
			player.call(&"stop")
	var deadline := Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < deadline and playbacks.any(func(w: WeakRef) -> bool: return w.get_ref() != null):
		await get_tree().process_frame
	get_tree().quit(exit_code)


func is_online() -> bool:
	return mode != Mode.SINGLE


## "keyboard text" or "pad text", whichever device the player uses.
func hint(keys: String, pad: String) -> String:
	return pad if using_pad else keys


## A short rumble on every connected gamepad (no-op without one).
func rumble(weak: float, strong: float, seconds: float) -> void:
	for d in Input.get_connected_joypads():
		Input.start_joy_vibration(d, weak, strong, seconds)


## The clipboard, empty where the display server has none (headless tools).
func clipboard_get() -> String:
	return DisplayServer.clipboard_get() if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD) else ""


func clipboard_set(text: String) -> void:
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		DisplayServer.clipboard_set(text)


## A Copy button's action: puts `text` on the clipboard and shows "Copied!" on the button for a moment.
func copy_with_feedback(button: Button, text: String) -> void:
	clipboard_set(text)
	Sfx.play(&"gem")
	button.text = "Copied!"
	get_tree().create_timer(1.2).timeout.connect(func() -> void:
		if is_instance_valid(button):
			button.text = "Copy")


# --- Internals ---------------------------------------------------------------------------------------------------


func _begin(m: Mode) -> void:
	mode = m
	last_error = ""
	lobby_code = ""
	lan_address = ""
	session.local_name = Settings.player_name
	_set_flow(Flow.CONNECTING)
	if m != Mode.SINGLE:
		_show_connect_overlay()


## Private IPv4 addresses of this machine (what a LAN friend types), sorted.
static func _lan_ips() -> Array[String]:
	var out: Array[String] = []
	for ip: String in IP.get_local_addresses():
		var second := int(ip.get_slice(".", 1))
		if ip.begins_with("192.168.") or ip.begins_with("10.") or (ip.begins_with("172.") and second in range(16, 32)):
			out.append(ip)
	out.sort()
	return out


func _set_flow(f: Flow) -> void:
	flow = f
	flow_changed.emit(f)


func _on_status_changed(new_status: UnifiedSession.Status, detail: String) -> void:
	status = new_status
	status_detail = detail
	status_changed.emit(new_status, detail)
	match new_status:
		UnifiedSession.STATUS_CONNECTING:
			if flow == Flow.MENU:
				_adopt()
		UnifiedSession.STATUS_CONNECTED:
			if flow == Flow.MENU:
				_adopt()
			if flow == Flow.CONNECTING:
				_hide_connect_overlay()
				_set_flow(Flow.PLAYING)
				get_tree().change_scene_to_file(PLAY_SCENE)
		UnifiedSession.STATUS_FAILED:
			if _smoke_test():
				push_error("%s: smoke test: the session failed: %s" % [_game_name(), detail])  # uni release fails on it
				quit_app.call_deferred(1)
				return
			leave_to_menu(detail if detail != "" else "Connection failed.")
		UnifiedSession.STATUS_DISCONNECTED:
			if flow != Flow.MENU:
				# "left": this player left through the session (a tool, say), not through the menus
				leave_to_menu("" if detail == "left" else "Disconnected" + (": " + detail if detail != "" else "."))


## A session the menus didn't start (the command line's session flags, a tool) is the app's too: the flow follows it.
func _adopt() -> void:
	match session.mode:
		UnifiedSession.MODE_SINGLE:
			_begin(Mode.SINGLE)
		UnifiedSession.MODE_HOST_ONLINE:
			_begin(Mode.HOST)
		UnifiedSession.MODE_HOST_DIRECT:
			_begin(Mode.HOST_LAN)
		_:
			_begin(Mode.JOIN)


func _on_lobby_code(code: String) -> void:
	if mode == Mode.HOST_LAN:
		# the native LAN host reports its port here; friends need the address
		var ips := _lan_ips()
		lan_address = "%s:%s" % [ips[0] if not ips.is_empty() else "127.0.0.1", code]
		return
	lobby_code = code
	if mode == Mode.HOST and code != "":
		clipboard_set(code)  # the host's next move is pasting it to a friend
	lobby_code_changed.emit(code)


func _show_connect_overlay() -> void:
	if _connect_overlay == null:
		_connect_overlay = CONNECT_OVERLAY.instantiate()
		_overlay_layer.add_child(_connect_overlay)


func _hide_connect_overlay() -> void:
	if _connect_overlay != null:
		_connect_overlay.queue_free()
		_connect_overlay = null


func _on_setting_changed(setting: StringName) -> void:
	if setting == &"show_fps":
		_fps_label.visible = Settings.show_fps
	elif setting == &"player_name":
		session.local_name = Settings.player_name  # takes effect when the next session starts


## macOS Retina: the project size is in pixels, so a 1280x720 window opens at half size. Scales it once at boot.
func _fit_window() -> void:
	if DisplayServer.get_name() == "headless" or "--no-settings" in OS.get_cmdline_user_args():
		return
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	var scale := DisplayServer.screen_get_scale()
	if scale <= 1.0:
		return
	var width: float = ProjectSettings.get_setting("display/window/size/viewport_width")
	var height: float = ProjectSettings.get_setting("display/window/size/viewport_height")
	var base := Vector2(width, height)
	var usable := DisplayServer.screen_get_usable_rect()
	var size := Vector2i((base * scale).min(Vector2(usable.size) * 0.9))
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(usable.position + Vector2i(Vector2(usable.size - size) * 0.5))


static func _smoke_test() -> bool:
	return "--smoke-test" in OS.get_cmdline_user_args()


static func _game_name() -> String:
	return ProjectSettings.get_setting("application/config/name")
