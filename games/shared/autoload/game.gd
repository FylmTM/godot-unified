class_name UnifiedGame
extends Node
## The app's flow, the base of a game's `Game` autoload: owns the session for the app's lifetime and switches scenes
## on its status.
##
##   MENU --start/host/join--> CONNECTING --"connected"--> PLAYING --leave--> MENU
##                                  \--"failed"--> MENU (error shown)      \--"failed"/"disconnected"--> MENU
##
## The session is the native `UnifiedSession` from the game library (`_create_session()`; a game may offer a GDScript
## stand-in for development, `is_mock`). Without one the app shows a fatal screen. Everything reads the sim through
## `Game.hud` (current from the session's first event of a frame on) and its fixed numbers through `Game.constants`
## (the session's `constants()`, read once).

signal flow_changed(flow: Flow)
signal status_changed(status: String, detail: String)
signal lobby_code_changed(code: String)
## The last input came from a gamepad (true) or keyboard and mouse (false): hints and key labels follow it.
signal input_device_changed(pad: bool)

enum Flow { MENU, CONNECTING, PLAYING }
enum Mode { SINGLE, HOST, HOST_LAN, JOIN }

const LAN_PORT := 7777
## The scenes the flow switches between: every game keeps its menu and play scene at these paths.
const MENU_SCENE := "res://game/ui/main_menu.tscn"
const PLAY_SCENE := "res://game/arena/arena.tscn"
const CONNECT_OVERLAY := preload("res://addons/shared/ui/connect_overlay.tscn")

var session: Node
## The session is the game's GDScript stand-in, not the game library.
var is_mock := false
var flow := Flow.MENU
var mode := Mode.SINGLE
var status := "idle"
var status_detail := ""
var lobby_code := ""
## The port Host on LAN listens on (a tool may pick another, so parallel runs don't collide).
var lan_port := LAN_PORT
## When hosting on LAN: the address friends join (host:port, first private IPv4), shown where the code would be.
var lan_address := ""
## Shown by the main menu once after a failure, then cleared.
var last_error := ""
## The sim's HUD dictionary (the game's contract plus `local_slot`, -1 until the session assigns one).
var hud: Dictionary = {}
## The sim's fixed numbers (the game's contract plus `tick_hz`).
var constants: Dictionary = {}
## True while the player is using a gamepad (the last input event came from one).
var using_pad := false

var _hud_frame := -1
var _quitting := false
var _overlay_layer: CanvasLayer
var _connect_overlay: Control
var _fps_label: Label
var _frame_ms := 16.7


func _ready() -> void:
	process_priority = -100  # refresh `hud` before any other node reads it
	process_mode = Node.PROCESS_MODE_ALWAYS
	UiTheme.install()
	get_tree().auto_accept_quit = false  # the window's close button goes through quit_app too
	session = _create_session()
	if session == null:
		_fatal()
		return
	session.name = &"Session"
	add_child(session)
	# Connected before any view or HUD: a handler of the frame's first event reads this frame's hud.
	session.sim_event.connect(func(_k: StringName, _t: int, _e: int, _p: Vector3, _v: float) -> void: _refresh_hud())
	if session.has_signal(&"sim_event_2d"):
		session.sim_event_2d.connect(func(_k: StringName, _t: int, _e: int, _p: Vector2, _v: float) -> void:
			_refresh_hud())
	session.status_changed.connect(_on_status_changed)
	session.lobby_code.connect(_on_lobby_code)
	hud = session.hud()
	constants = session.constants()

	_overlay_layer = CanvasLayer.new()
	_overlay_layer.layer = 50
	add_child(_overlay_layer)
	var fps_layer := CanvasLayer.new()
	fps_layer.layer = 100
	add_child(fps_layer)
	_fps_label = Label.new()
	_fps_label.theme_type_variation = &"Dim"
	_fps_label.position = Vector2(10, 6)
	_fps_label.visible = Settings.get_value(&"show_fps")
	fps_layer.add_child(_fps_label)
	Settings.changed.connect(_on_setting_changed)
	_fit_window.call_deferred()
	# Release smoke test (`uni release` runs the export headless with `-- --smoke-test`): exercise the sim too.
	if _smoke_test():
		print("%s: smoke test, %s session, starting single player" % [_game_name(), "mock" if is_mock else "native"])
		play_single.call_deferred()


func _process(delta: float) -> void:
	_refresh_hud()
	_frame_ms = lerpf(_frame_ms, delta * 1000.0 / maxf(Engine.time_scale, 0.001), 0.05)
	if _fps_label.visible:
		_fps_label.text = "%d FPS  ·  %.1f ms" % [roundi(1000.0 / maxf(_frame_ms, 0.01)), _frame_ms]


func _input(event: InputEvent) -> void:
	var pad := event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > 0.5)
	var kbm := event is InputEventKey or event is InputEventMouseButton
	if (pad and not using_pad) or (kbm and using_pad):
		using_pad = pad
		input_device_changed.emit(pad)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit_app()


## The session: the native `UnifiedSession` when the game library is loaded, else null. A game with a GDScript
## stand-in returns it here (and sets `is_mock`); exports never ship one.
func _create_session() -> Node:
	if ClassDB.class_exists(&"UnifiedSession"):
		return ClassDB.instantiate(&"UnifiedSession")
	return null


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
	if status != "idle":
		session.leave()
	lobby_code = ""
	lan_address = ""
	_hide_connect_overlay()
	if flow != Flow.MENU:
		_set_flow(Flow.MENU)
		get_tree().change_scene_to_file(MENU_SCENE)


## Quits the app (menus, the window's close button, tools). The session ends and every playing sound stops first,
## and the quit waits (at most 1 s) until the AudioServer has freed their playbacks: one it still holds at exit is
## reported as leaked.
func quit_app(exit_code := 0) -> void:
	if _quitting:
		return
	_quitting = true
	if session != null and status != "idle":
		session.leave()
	var playbacks: Array[WeakRef] = []
	for type: String in ["AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D"]:
		for p: Node in get_tree().root.find_children("*", type, true, false):
			if p.has_stream_playback():
				playbacks.append(weakref(p.get_stream_playback()))
			p.stop()
	var deadline := Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < deadline and playbacks.any(func(w: WeakRef) -> bool: return w.get_ref() != null):
		await get_tree().process_frame
	get_tree().quit(exit_code)


## Sends one of the game's commands, delivered to the sim exactly once (src/godot_host/SPEC.md). False when the
## session refused it (it prints why).
func send_command(command: StringName, args := {}) -> bool:
	return session.send_command(command, args)


func is_online() -> bool:
	return mode != Mode.SINGLE


## The local player's slot, -1 until the session assigns one.
func local_slot() -> int:
	return int(hud.get("local_slot", -1))


## A slot's entry in the HUD's `players` ({} when there is none).
func player(slot: int) -> Dictionary:
	for p: Dictionary in hud.get("players", []):
		if int(p.get("slot", -1)) == slot:
			return p
	return {}


func local_player() -> Dictionary:
	return player(local_slot())


## The HUD's players that are present, in slot order.
func present_players() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p: Dictionary in hud.get("players", []):
		if p.get("present", false):
			out.append(p)
	return out


## A HUD player's display name: the synced name when the session has one, else "P<n>".
func player_name(p: Dictionary) -> String:
	var n := String(p.get("name", ""))
	return n if n != "" else "P%d" % (int(p.get("slot", 0)) + 1)


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


## Once per frame, from the session's first event or this node's _process, whichever comes first.
func _refresh_hud() -> void:
	var frame := Engine.get_process_frames()
	if frame != _hud_frame:
		_hud_frame = frame
		hud = session.hud()


func _begin(m: Mode) -> void:
	mode = m
	last_error = ""
	lobby_code = ""
	lan_address = ""
	session.set_player_name(Settings.get_value(&"player_name"))
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


func _on_status_changed(new_status: String, detail: String) -> void:
	status = new_status
	status_detail = detail
	status_changed.emit(new_status, detail)
	match new_status:
		"connected":
			if flow == Flow.CONNECTING:
				_hide_connect_overlay()
				_set_flow(Flow.PLAYING)
				get_tree().change_scene_to_file(PLAY_SCENE)
		"failed":
			if _smoke_test():
				push_error("%s: smoke test: the session failed: %s" % [_game_name(), detail])  # uni release fails on it
				quit_app.call_deferred(1)
				return
			leave_to_menu(detail if detail != "" else "Connection failed.")
		"disconnected":
			if flow != Flow.MENU:
				leave_to_menu("Disconnected" + (": " + detail if detail != "" else "."))


func _on_lobby_code(code: String) -> void:
	if mode == Mode.HOST_LAN:
		return  # the native LAN host reports its port here; friends need the address (lan_address)
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


func _on_setting_changed(key: StringName, value: Variant) -> void:
	if key == &"show_fps":
		_fps_label.visible = value
	elif key == &"player_name":
		session.set_player_name(value)  # takes effect when the next session starts


## macOS Retina: the project size is in pixels, so a 1280x720 window opens at half size. Scales it once at boot.
func _fit_window() -> void:
	if DisplayServer.get_name() == "headless" or "--no-settings" in OS.get_cmdline_user_args():
		return
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	var scale := DisplayServer.screen_get_scale()
	if scale <= 1.0:
		return
	var base := Vector2(
		ProjectSettings.get_setting("display/window/size/viewport_width"),
		ProjectSettings.get_setting("display/window/size/viewport_height"))
	var usable := DisplayServer.screen_get_usable_rect()
	var size := Vector2i((base * scale).min(Vector2(usable.size) * 0.9))
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(usable.position + Vector2i(Vector2(usable.size - size) * 0.5))


static func _smoke_test() -> bool:
	return "--smoke-test" in OS.get_cmdline_user_args()


static func _game_name() -> String:
	return ProjectSettings.get_setting("application/config/name")


## Without a session nothing can run: says so and offers Quit.
func _fatal() -> void:
	var exported := OS.has_feature("template")
	push_error("%s: the game library failed to load (UnifiedSession missing): %s" % [_game_name(),
		"the export is broken" if exported else "build it with ./uni build"])
	set_process(false)
	get_tree().unload_current_scene.call_deferred()
	var layer := CanvasLayer.new()
	layer.layer = 200
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = UiTheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(box)
	var title := Label.new()
	title.theme_type_variation = &"Heading"
	title.text = "The game library failed to load"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var detail := Label.new()
	detail.theme_type_variation = &"Dim"
	detail.text = ("This copy of the game is incomplete or damaged. Download it again." if exported
		else "Build it first: ./uni build")
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(detail)
	var quit := Button.new()
	quit.theme_type_variation = &"PrimaryButton"
	quit.text = "Quit"
	quit.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	quit.pressed.connect(quit_app)
	box.add_child(quit)
	quit.grab_focus.call_deferred()
	_fit_window.call_deferred()
	if _smoke_test():
		quit_app.call_deferred(1)
