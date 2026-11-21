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
## numbers `Unified.constants`; what friends join a hosted session with, `Unified.session.join_code`.

signal status_changed(status: UnifiedSession.Status, detail: String)
## The last input came from a gamepad (true) or keyboard and mouse (false): hints and key labels follow it.
signal input_device_changed(pad: bool)

enum Flow { MENU, CONNECTING, PLAYING }
enum Mode { SINGLE, HOST, HOST_LAN, JOIN }

const LAN_PORT := 7777
## The scenes the flow switches between: every game keeps its menu and play scene at these paths.
const MENU_SCENE := "res://game/ui/main_menu.tscn"
const PLAY_SCENE := "res://game/arena/arena.tscn"
const CONNECT_OVERLAY := preload("res://game/ui/connect_overlay.tscn")
## Keys labelled by the character they type rather than their name ("BracketLeft").
const SYMBOL_KEYS: Dictionary[Key, String] = {KEY_BRACKETLEFT: "[", KEY_BRACKETRIGHT: "]", KEY_MINUS: "-",
	KEY_EQUAL: "=", KEY_COMMA: ",", KEY_PERIOD: ".", KEY_SLASH: "/", KEY_SEMICOLON: ";", KEY_APOSTROPHE: "'"}
## A pad's buttons by `JoyButton` index, as an Xbox pad labels them.
const PAD_BUTTONS: Array[String] = ["A", "B", "X", "Y", "Back", "Guide", "Start", "L3", "R3", "LB", "RB", "D-pad up",
	"D-pad down", "D-pad left", "D-pad right"]

var session: UnifiedSession
var flow := Flow.MENU
var mode := Mode.SINGLE
var status := UnifiedSession.STATUS_IDLE
var status_detail := ""
## The port Host on LAN listens on (a tool may pick another, so parallel runs don't collide).
var lan_port := LAN_PORT
## This single-player session was opened to friends from the pause menu (invite_friends): it stays the host's.
var invited := false
## Shown by the main menu once after a failure, then cleared.
var last_error := ""
## True while the player is using a gamepad (the last input event came from one).
var using_pad := false

var _quitting := false
## An invite asked for online and its lobby isn't up yet: if it fails, the invite falls back to the LAN port.
var _inviting_online := false
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
	session.view_root = null  # no scene views until the play scene hands over its Views node (else: under this autoload)
	# before it enters the tree, where the command line's session flags start it: the flow follows from there
	session.local_name = Settings.player_name
	session.status_changed.connect(_on_status_changed)
	session.join_code_changed.connect(_on_join_code)
	session.mode_changed.connect(_on_mode_changed)
	add_child(session)


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
	session.host_direct(port)


## Opens the running single-player session to friends and keeps it running: online (the lobby service; the code a
## friend types) when this build can, else on the LAN port. The join code arrives with join_code_changed, the new mode
## with mode_changed.
func invite_friends() -> void:
	_inviting_online = session.open_online()  # false, or a failure later, when this build has no online play
	invited = _inviting_online or session.open_direct(lan_port)


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
	_hide_connect_overlay()
	if flow != Flow.MENU:
		flow = Flow.MENU
		get_tree().change_scene_to_file(MENU_SCENE)


## Quits the app (menus, the window's close button, tools): Sfx plays nothing more, and UnifiedSession.quit ends the
## session, stops every sound and quits once the AudioServer has freed their playbacks.
func quit_app(exit_code := 0) -> void:
	if _quitting:
		return
	_quitting = true
	Sfx.close()
	if session != null:
		session.quit(exit_code)
	else:
		get_tree().quit(exit_code)


func is_online() -> bool:
	return mode != Mode.SINGLE


## What an input action is bound to (`InputMap`, so `[input]` in project.godot is the one home of the bindings), on
## the device the player uses: "Space", "LMB / E", "A", "LT / A". `input` is an action, or the actions that make one
## control together (a stick's directions: "WASD / Arrows", "Left stick / D-pad"). `fallback` when the action has no
## binding on that device (mouse look is no action).
func input_label(input: Variant, fallback := "") -> String:
	var actions: Array = input if input is Array else [input]
	var bindings: Array[PackedStringArray] = []  # per action: its events' labels on this device, in order
	for action: StringName in actions:
		var labels := PackedStringArray()
		for event: InputEvent in InputMap.action_get_events(action):
			if (event is InputEventJoypadButton or event is InputEventJoypadMotion) == using_pad:
				labels.append(_event_label(event, actions.size() > 1))
		bindings.append(labels)
	var shown := PackedStringArray()
	var count: int = bindings.map(func(b: PackedStringArray) -> int: return b.size()).min()
	for i in count:
		var parts := PackedStringArray(bindings.map(func(b: PackedStringArray) -> String: return b[i]))
		var label := parts[0]  # every direction on one stick or one set of keys: "Left stick", "Arrows"
		if parts.count(label) != parts.size():
			var letters := not using_pad and Array(parts).all(func(p: String) -> bool: return p.length() == 1 and p != p.to_lower())
			label = ("" if letters else " ").join(parts)  # "WASD", "1 2 3", "X Y B"
		if label not in shown:
			shown.append(label)
	return " / ".join(shown) if not shown.is_empty() else fallback


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
	invited = false
	_inviting_online = false
	session.local_name = Settings.player_name
	flow = Flow.CONNECTING
	if m != Mode.SINGLE:
		_show_connect_overlay()


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
				flow = Flow.PLAYING
				get_tree().change_scene_to_file(PLAY_SCENE)
			elif flow == Flow.PLAYING:
				_hide_connect_overlay()  # back from reconnecting or recovering
		UnifiedSession.STATUS_RECONNECTING, UnifiedSession.STATUS_RECOVERING:
			# The library brings the session back by itself (a new connection, or the state put right): the play
			# scene stays, frozen, under the overlay; Cancel leaves.
			if flow == Flow.PLAYING:
				_show_connect_overlay()
		UnifiedSession.STATUS_FAILED:
			leave_to_menu(detail if detail != "" else "Connection failed.")
		UnifiedSession.STATUS_LEFT:
			if flow != Flow.MENU:
				leave_to_menu("")  # this player left through the session (a tool, say), not through the menus
		UnifiedSession.STATUS_DISCONNECTED:
			if flow != Flow.MENU:
				leave_to_menu("Disconnected" + (": " + detail if detail != "" else "."))


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


## The session's mode changed while it ran (a single-player session opened to friends), or an open failed: the flow
## follows the mode; a failure's reason is the last error (shown on the menu when the player leaves). An online invite
## that fails opens on the LAN port instead.
func _on_mode_changed(new_mode: UnifiedSession.Mode, detail: String) -> void:
	var fell_back := _inviting_online and new_mode == UnifiedSession.MODE_SINGLE
	_inviting_online = false
	if fell_back and session.open_direct(lan_port):
		return
	if detail != "":
		last_error = detail
	match new_mode:
		UnifiedSession.MODE_HOST_ONLINE:
			mode = Mode.HOST
		UnifiedSession.MODE_HOST_DIRECT:
			mode = Mode.HOST_LAN
		UnifiedSession.MODE_SINGLE:
			mode = Mode.SINGLE
			invited = false


func _on_join_code(code: String) -> void:
	if mode == Mode.HOST and code != "":
		clipboard_set(code)  # the host's next move is pasting the lobby code to a friend


## One binding's label. In a group (`grouped`: one of several actions that make one control), a stick's axis, a
## D-pad button and an arrow key say what they belong to.
static func _event_label(event: InputEvent, grouped: bool) -> String:
	if event is InputEventKey:
		var key := event as InputEventKey
		var code := key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
		if grouped and code in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN]:
			return "Arrows"
		if code == KEY_ESCAPE:
			return "Esc"
		var label: String = SYMBOL_KEYS.get(code, OS.get_keycode_string(code))
		return label
	if event is InputEventMouseButton:
		var index := (event as InputEventMouseButton).button_index
		return {MOUSE_BUTTON_LEFT: "LMB", MOUSE_BUTTON_RIGHT: "RMB", MOUSE_BUTTON_MIDDLE: "MMB"}.get(index, "Mouse %d" % index)
	if event is InputEventJoypadButton:
		var button := (event as InputEventJoypadButton).button_index
		if grouped and button in [JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT]:
			return "D-pad"
		return PAD_BUTTONS[button] if button < PAD_BUTTONS.size() else "Button %d" % button
	if event is InputEventJoypadMotion:
		var axis := (event as InputEventJoypadMotion).axis
		return ["Left stick", "Left stick", "Right stick", "Right stick", "LT", "RT"][axis] if axis < 6 else "Axis %d" % axis
	return event.as_text()


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
