extends Node
## The app's flow: owns the session for the app's lifetime and switches scenes on its status.
##
##   MENU --start/host/join--> CONNECTING --"connected"--> PLAYING --leave--> MENU
##                                  \--"failed"--> MENU (error shown)      \--"failed"/"disconnected"--> MENU
##
## The session is the native `UnifiedSession` from the game library (there is no GDScript mock: the library builds in
## about a second, `uni build friendslop`). Without it the app shows a fatal screen. Everything
## reads the sim through `Game.hud` (refreshed once per frame) and its fixed numbers through `Game.constants` (the
## session's `constants()`, read once).

signal flow_changed(flow: Flow)
signal status_changed(status: String, detail: String)
signal lobby_code_changed(code: String)
## The last input came from a gamepad (true) or keyboard/mouse (false): hints and key labels follow it.
signal input_device_changed(pad: bool)

enum Flow { MENU, CONNECTING, PLAYING }
enum Mode { SINGLE, HOST, HOST_LAN, JOIN }

const LAN_PORT := 7777

const MENU_SCENE := "res://game/ui/main_menu.tscn"
const ARENA_SCENE := "res://game/arena/arena.tscn"
const CONNECT_OVERLAY := preload("res://game/ui/connect_overlay.tscn")

var session: Node
var flow := Flow.MENU
var mode := Mode.SINGLE
var status := "idle"
var status_detail := ""
var lobby_code := ""
## When hosting on LAN: the address friends join (host:port, first private IPv4), shown where the code would be.
var lan_address := ""
## Shown by the main menu once after a failure, then cleared.
var last_error := ""
## The sim's HUD dictionary (phase, tick, run_s, best_s, checkpoint, players, ...), refreshed every frame.
var hud: Dictionary = {}
## The sim's fixed numbers (tick_hz, finish_hold_s, respawn_s, feet, item_sizes, ...).
var constants: Dictionary = {}
## True while the player is using a gamepad (last input event came from one).
var using_pad := false

var _overlay_layer: CanvasLayer
var _connect_overlay: Control
var _fps_label: Label
var _frame_ms := 16.7


func _ready() -> void:
	process_priority = -100  # refresh `hud` before any other node reads it
	process_mode = Node.PROCESS_MODE_ALWAYS
	UiTheme.install()
	get_tree().auto_accept_quit = false  # the window's close button goes through quit_app too
	if not ClassDB.class_exists(&"UnifiedSession"):
		_fatal()
		return
	session = ClassDB.instantiate(&"UnifiedSession")
	session.name = "Session"
	add_child(session)
	session.status_changed.connect(_on_status_changed)
	session.lobby_code.connect(_on_lobby_code)
	hud = session.hud()
	constants = session.constants()

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
	# Release smoke test (`uni release` runs the export headless with `-- --smoke-test`): exercise the sim too.
	if "--smoke-test" in OS.get_cmdline_user_args():
		print("friendslop: smoke test, starting single player")
		play_single.call_deferred()


func _process(delta: float) -> void:
	hud = session.hud()
	Sfx.music.set_intensity(1.0 if hud.get("phase", "") == "run" and flow == Flow.PLAYING else 0.0)
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


## Quits the app (menus, the window's close button, tools). Audio stops first and the quit waits (at most 1 s)
## until the AudioServer has freed its playbacks; quitting with a sound playing reports it as leaked at exit.
func quit_app(exit_code := 0) -> void:
	var playbacks := Sfx.shut_down()
	var deadline := Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < deadline and playbacks.any(func(w: WeakRef) -> bool: return w.get_ref() != null):
		await get_tree().process_frame
	get_tree().quit(exit_code)


## A short rumble on the gamepad in use (no-op without one).
func rumble(weak: float, strong: float, seconds: float) -> void:
	for d in Input.get_connected_joypads():
		Input.start_joy_vibration(d, weak, strong, seconds)


## Clipboard access that is a no-op where the display server has none (headless tools).
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


## "keyboard text" or "pad text", whichever device the player uses.
func hint(keys: String, pad: String) -> String:
	return pad if using_pad else keys


# --- Flow API (menus call these) ----------------------------------------------------------------


func play_single() -> void:
	_begin(Mode.SINGLE)
	session.start_single()


func host_online() -> void:
	_begin(Mode.HOST)
	session.host_online()


func host_direct(port := LAN_PORT) -> void:
	_begin(Mode.HOST_LAN)
	lan_address = ", ".join(_lan_ips().map(func(ip: String) -> String: return "%s:%d" % [ip, port]))
	if lan_address == "":
		lan_address = "127.0.0.1:%d" % port
	session.host_direct(port)


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
	lan_address = ""
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
func player_name(p: Dictionary) -> String:
	var n := String(p.get("name", ""))
	return n if n != "" else "P%d" % (int(p.get("slot", 0)) + 1)


# --- Internals ----------------------------------------------------------------------------------


func _begin(m: Mode) -> void:
	mode = m
	last_error = ""
	lobby_code = ""
	lan_address = ""
	if session.has_method(&"set_player_name"):
		session.set_player_name(Settings.get_value(&"player_name"))
	_set_flow(Flow.CONNECTING)
	if m != Mode.SINGLE:
		_show_connect_overlay()


## Private IPv4 addresses of this machine (what a LAN friend types).
static func _lan_ips() -> Array:
	var out := []
	for ip: String in IP.get_local_addresses():
		if ip.begins_with("192.168.") or ip.begins_with("10.") or (ip.begins_with("172.") and int(ip.split(".")[1]) >= 16 and int(ip.split(".")[1]) <= 31):
			out.append(ip)
	out.sort()
	return out.slice(0, 1)


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
			if "--smoke-test" in OS.get_cmdline_user_args():
				push_error("friendslop: smoke test: the session failed: %s" % detail)  # uni release fails on it
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
	elif key == &"player_name" and session.has_method(&"set_player_name"):
		session.set_player_name(value)  # takes effect when the next session starts


## macOS Retina: the project size is in pixels, so a 1280x720 window opens at half size. Scale it once at boot.
func _fit_window() -> void:
	if DisplayServer.get_name() == "headless" or "--no-settings" in OS.get_cmdline_user_args():
		return
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	var scale := DisplayServer.screen_get_scale()
	if scale <= 1.0:
		return
	var usable := DisplayServer.screen_get_usable_rect()
	var size := Vector2i((Vector2(1280, 720) * scale).min(Vector2(usable.size) * 0.9))
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(usable.position + Vector2i(Vector2(usable.size - size) * 0.5))


## Without the game library nothing can run: say so and offer Quit.
func _fatal() -> void:
	push_error("friendslop: the game library failed to load (UnifiedSession missing): in the repo, build it with " +
		"`./uni build friendslop`; an export without it is broken")
	set_process(false)
	set_process_unhandled_input(false)
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
	detail.text = ("This copy of the game is incomplete or damaged. Download it again." if OS.has_feature("template")
		else "Build it first: ./uni build friendslop")
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
	if "--smoke-test" in OS.get_cmdline_user_args():
		quit_app.call_deferred(1)
