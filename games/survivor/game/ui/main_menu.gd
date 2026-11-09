extends Node
## Main menu: start single player, host, join by code or address, settings, quit. Shows the last error once.

const SETTINGS_PANEL := preload("res://game/ui/settings_panel.tscn")
const CODE_CHARS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

@onready var _buttons: VBoxContainer = $UI/Root/Left/VBox/Buttons
@onready var _side: CenterContainer = $UI/Root/Side
@onready var _join_panel: PanelContainer = $UI/Root/Side/JoinPanel
@onready var _code: LineEdit = $UI/Root/Side/JoinPanel/VBox/Code
@onready var _code_go: Button = $UI/Root/Side/JoinPanel/VBox/Row/Go
@onready var _code_error: Label = $UI/Root/Side/JoinPanel/VBox/Error
@onready var _addr_panel: PanelContainer = $UI/Root/Side/AddressPanel
@onready var _addr: LineEdit = $UI/Root/Side/AddressPanel/VBox/Address
@onready var _addr_error: Label = $UI/Root/Side/AddressPanel/VBox/Error
@onready var _error_panel: PanelContainer = $UI/Root/Side/ErrorPanel
var _settings: Control


func _ready() -> void:
	_preload_arena()
	_place_props()
	$UI/Root/Left/VBox/Footer.text = "v%s  ·  %s" % [
		ProjectSettings.get_setting("application/config/version"),
		"mock session (no game library)" if Game.is_mock else "game library loaded",
	]
	_buttons.get_node(^"Single").pressed.connect(_click.bind(Game.play_single))
	_buttons.get_node(^"Host").pressed.connect(_click.bind(Game.host_online))
	_buttons.get_node(^"Join").pressed.connect(_click.bind(_show.bind(_join_panel)))
	_buttons.get_node(^"Address").pressed.connect(_click.bind(_show.bind(_addr_panel)))
	_buttons.get_node(^"Settings").pressed.connect(_click.bind(_show_settings))
	_buttons.get_node(^"Quit").pressed.connect(_click.bind(get_tree().quit))
	_code.text_changed.connect(_on_code_changed)
	_code.text_submitted.connect(func(_t: String) -> void: _join_code())
	_code_go.pressed.connect(_click.bind(_join_code))
	$UI/Root/Side/JoinPanel/VBox/Row/Paste.pressed.connect(_click.bind(_paste_code))
	$UI/Root/Side/JoinPanel/VBox/Row/Back.pressed.connect(_click.bind(_show.bind(null)))
	_addr.text_submitted.connect(func(_t: String) -> void: _join_address())
	$UI/Root/Side/AddressPanel/VBox/Row/Go.pressed.connect(_click.bind(_join_address))
	$UI/Root/Side/AddressPanel/VBox/Row/Back.pressed.connect(_click.bind(_show.bind(null)))
	$UI/Root/Side/AddressPanel/VBox/HostLan.pressed.connect(_click.bind(Game.host_direct.bind(Game.LAN_PORT)))
	$UI/Root/Side/ErrorPanel/VBox/Ok.pressed.connect(_click.bind(_show.bind(null)))
	if Game.last_error != "":
		$UI/Root/Side/ErrorPanel/VBox/Message.text = Game.last_error
		$UI/Root/Side/ErrorPanel/VBox/Heading.text = "Disconnected" if Game.last_error.begins_with("Disconnected") else "Couldn't connect"
		Game.last_error = ""
		_show(_error_panel)
	else:
		_show(null)


## Loads the arena in the background once the menu is on screen: loading its materials and meshes starts Godot's
## shader compiles on worker threads, instead of in the menu -> arena frame (cold cache: ~140 -> ~50 ms here).
func _preload_arena() -> void:
	var tree := get_tree()
	for i in 2:
		await tree.process_frame
	if not is_inside_tree():
		return
	ResourceLoader.load_threaded_request(Game.ARENA_SCENE)


func _exit_tree() -> void:
	# Collect the background load (the arena now holds what it needs), or the loader keeps it until exit.
	if ResourceLoader.load_threaded_get_status(Game.ARENA_SCENE) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		ResourceLoader.load_threaded_get(Game.ARENA_SCENE)


## Backdrop: crates and barrels on the sim's 5x8 item grid (visual only, nothing simulates them here).
func _place_props() -> void:
	var crate: PackedScene = load("res://game/views/crate.tscn")
	var barrel: PackedScene = load("res://game/views/barrel.tscn")
	for i in 40:
		var is_barrel := i % 5 == 2
		var p := Vector3((i % 8) * 4 - 14, 0.7 if is_barrel else 0.5, (i / 8) * 4 - 8)
		if Vector2(p.x, p.z).length() < 7.5:
			continue  # keep the start circle clear
		var v: Node3D = (barrel if is_barrel else crate).instantiate()
		v.position = p
		v.rotation.y = i * 0.7
		v.set(&"pop_in", false)
		$Props.add_child(v)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel") and _visible_panel() != null:
		_show(null)
		get_viewport().set_input_as_handled()


func _click(action: Callable) -> void:
	Sfx.play(&"click")
	action.call()


func _show(panel: Control) -> void:
	for c in _side.get_children():
		c.visible = c == panel
	if panel == null:
		_buttons.get_node(^"Single").grab_focus()
	elif panel == _join_panel:
		_code_error.visible = false
		_prefill_code()
		_code.grab_focus()
		_code.caret_column = _code.text.length()
	elif panel == _addr_panel:
		_addr_error.visible = false
		_addr.grab_focus()
	elif panel == _error_panel:
		$UI/Root/Side/ErrorPanel/VBox/Ok.grab_focus()


func _visible_panel() -> Control:
	for c: Control in _side.get_children():
		if c.visible:
			return c
	return null


func _show_settings() -> void:
	if _settings == null:
		_settings = SETTINGS_PANEL.instantiate()
		_side.add_child(_settings)
		_settings.closed.connect(_show.bind(null))
	_show(_settings)


## Codes are case-insensitive and pasted from chats: keep letters and digits, uppercase, at most 6.
func _on_code_changed(text: String) -> void:
	var clean := _clean_code(text)
	if clean != text:
		var caret := _code.caret_column
		_code.text = clean
		_code.caret_column = mini(caret, clean.length())
	_code_go.disabled = clean.length() != 6
	_code_error.visible = false


## Opening the Join panel with a lobby code on the clipboard (copied from a chat) fills it in.
func _prefill_code() -> void:
	var clip := Game.clipboard_get().strip_edges()
	var code := _clean_code(clip)
	var looks_like_code := code.length() == 6 and clip.length() <= 12
	$UI/Root/Side/JoinPanel/VBox/Pasted.visible = looks_like_code and _code.text != code
	if looks_like_code and _code.text == "":
		_code.text = code
		_on_code_changed(code)
	else:
		$UI/Root/Side/JoinPanel/VBox/Pasted.visible = false


func _paste_code() -> void:
	_code.text = _clean_code(Game.clipboard_get())
	_on_code_changed(_code.text)
	_code.caret_column = _code.text.length()
	_code.grab_focus()


static func _clean_code(text: String) -> String:
	var out := ""
	for ch in text.to_upper():
		if CODE_CHARS.contains(ch):
			out += ch
	return out.left(6)


func _join_code() -> void:
	if _code.text.length() != 6:
		_code_error.text = "Lobby codes have 6 letters or digits."
		_code_error.visible = true
		return
	Game.join_online(_code.text)


func _join_address() -> void:
	var a := _addr.text.strip_edges()
	if a == "":
		a = _addr.placeholder_text
	var colon := a.rfind(":")
	if colon <= 0 or not a.substr(colon + 1).is_valid_int():
		_addr_error.text = "Use host:port, for example 192.168.1.20:7777."
		_addr_error.visible = true
		return
	Game.join_direct(a)
