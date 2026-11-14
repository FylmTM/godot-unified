class_name MainMenu
extends CanvasLayer
## The main menu: single player, host online, join with a code or by address (or host on LAN), settings, quit; the
## last error once. A game's menu scene (Game.MENU_SCENE) is its backdrop with this scene instanced as `Menu`,
## `title` and `tagline` set.

const SETTINGS_PANEL := preload("res://addons/shared/ui/settings_panel.tscn")
const CODE_CHARS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
const CODE_LENGTH := 6

@export var title := ""
@export var tagline := ""

var _settings: SettingsPanel

@onready var _single: Button = %Single
@onready var _side: Container = %Side
@onready var _join_panel: Control = %JoinPanel
@onready var _code: LineEdit = %CodeEdit
@onready var _code_join: Button = %CodeJoin
@onready var _code_error: Label = %CodeError
@onready var _pasted: Label = %Pasted
@onready var _address_panel: Control = %AddressPanel
@onready var _address: LineEdit = %AddressEdit
@onready var _address_error: Label = %AddressError
@onready var _error_panel: Control = %ErrorPanel
@onready var _error_ok: Button = %ErrorOk


func _ready() -> void:
	(%Title as Label).text = title
	(%Tagline as Label).text = tagline
	(%Footer as Label).text = "v%s%s" % [ProjectSettings.get_setting("application/config/version"),
		"  ·  mock session (no game library)" if Game.is_mock else ""]
	(%HostLan as Button).text = "Host on LAN instead (port %d)" % Game.lan_port
	_address.placeholder_text = "127.0.0.1:%d" % Game.lan_port
	_single.pressed.connect(_click.bind(Game.play_single))
	(%Host as Button).pressed.connect(_click.bind(Game.host_online))
	(%Join as Button).pressed.connect(_click.bind(_show.bind(_join_panel)))
	(%JoinAddress as Button).pressed.connect(_click.bind(_show.bind(_address_panel)))
	(%Settings as Button).pressed.connect(_click.bind(_show_settings))
	(%Quit as Button).pressed.connect(_click.bind(Game.quit_app))
	_code.text_changed.connect(_on_code_changed)
	_code.text_submitted.connect(func(_t: String) -> void: _join_code())
	_code_join.pressed.connect(_click.bind(_join_code))
	(%Paste as Button).pressed.connect(_click.bind(_paste_code))
	(%CodeBack as Button).pressed.connect(_click.bind(_show.bind(null)))
	_address.text_submitted.connect(func(_t: String) -> void: _join_address())
	(%AddressConnect as Button).pressed.connect(_click.bind(_join_address))
	(%AddressBack as Button).pressed.connect(_click.bind(_show.bind(null)))
	(%HostLan as Button).pressed.connect(_click.bind(func() -> void: Game.host_direct()))
	_error_ok.pressed.connect(_click.bind(_show.bind(null)))
	if Game.last_error != "":
		(%ErrorMessage as Label).text = Game.last_error
		(%ErrorHeading as Label).text = (
			"Disconnected" if Game.last_error.begins_with("Disconnected") else "Couldn't connect")
		Game.last_error = ""
		_show(_error_panel)
	else:
		_show(null)
	_preload_play_scene()


func _exit_tree() -> void:
	# Collect the background load (the play scene now holds what it needs), or the loader keeps it until exit.
	if ResourceLoader.load_threaded_get_status(Game.PLAY_SCENE) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		ResourceLoader.load_threaded_get(Game.PLAY_SCENE)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel") and visible_panel() != null:
		_show(null)
		get_viewport().set_input_as_handled()


## Loads the play scene in the background once the menu is on screen: loading its materials and meshes starts
## Godot's shader compiles on worker threads instead of in the menu -> play frame.
func _preload_play_scene() -> void:
	for i in 2:
		await get_tree().process_frame
	if is_inside_tree():
		ResourceLoader.load_threaded_request(Game.PLAY_SCENE)


func _click(action: Callable) -> void:
	Sfx.play(&"click")
	action.call()


func _show(panel: Control) -> void:
	for c: Control in _side.get_children():
		c.visible = c == panel
	if panel == null:
		_single.grab_focus()
	elif panel == _join_panel:
		_code_error.visible = false
		_prefill_code()
		_code.grab_focus()
		_code.caret_column = _code.text.length()
	elif panel == _address_panel:
		_address_error.visible = false
		_address.grab_focus()
	elif panel == _error_panel:
		_error_ok.grab_focus()


## The side panel on show (join, address, error, settings), or null.
func visible_panel() -> Control:
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


## Codes are case-insensitive and pasted from chats: keeps letters and digits, uppercased, at most CODE_LENGTH.
func _on_code_changed(text: String) -> void:
	var clean := _clean_code(text)
	if clean != text:
		var caret := _code.caret_column
		_code.text = clean
		_code.caret_column = mini(caret, clean.length())
	_code_join.disabled = clean.length() != CODE_LENGTH
	_code_error.visible = false


## Opening the Join panel with a lobby code on the clipboard (copied from a chat) fills it in.
func _prefill_code() -> void:
	var clip := Game.clipboard_get().strip_edges()
	var code := _clean_code(clip)
	var looks_like_code := code.length() == CODE_LENGTH and clip.length() <= 2 * CODE_LENGTH
	_pasted.visible = looks_like_code and _code.text == ""
	if _pasted.visible:
		_code.text = code
		_on_code_changed(code)


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
	return out.left(CODE_LENGTH)


func _join_code() -> void:
	if _code.text.length() != CODE_LENGTH:
		_code_error.text = "Lobby codes have %d letters or digits." % CODE_LENGTH
		_code_error.visible = true
		return
	Game.join_online(_code.text)


func _join_address() -> void:
	var a := _address.text.strip_edges()
	if a == "":
		a = _address.placeholder_text
	var colon := a.rfind(":")
	if colon <= 0 or not a.substr(colon + 1).is_valid_int():
		_address_error.text = "Use host:port, for example 192.168.1.20:%d." % Game.LAN_PORT
		_address_error.visible = true
		return
	Game.join_direct(a)
