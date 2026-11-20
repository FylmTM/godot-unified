extends Control
## The start panel. While no session runs (before the first, and after one ends, saying why) it starts one: alone,
## hosting online (an EOS lobby) or on the LAN, joining by lobby code or by address. While one runs, the corner shows
## what friends join with (Copy) and Leave, which brings the panel back. It follows the session's status, whoever
## started the session: these buttons, the session flags, `uni coop`, a tool.

const LAN_PORT := 7000
const WELCOME := "Hold the yard alone, or with friends online or on the LAN."

@onready var _menu: Control = %Menu
@onready var _status: Label = %Status
@onready var _code: LineEdit = %Code
@onready var _address: LineEdit = %Address
@onready var _cancel: Button = %Cancel
@onready var _corner: Control = %Corner
@onready var _shared: Label = %Shared
@onready var _copy: Button = %Copy


func _ready() -> void:
	var session := Unified.session
	(%Single as Button).pressed.connect(func() -> void: session.start_single())
	(%HostOnline as Button).pressed.connect(func() -> void: session.host_online())
	(%HostLan as Button).text = "Host on the LAN (port %d)" % LAN_PORT
	(%HostLan as Button).pressed.connect(func() -> void: session.host_direct(LAN_PORT))
	(%JoinOnline as Button).pressed.connect(_join_online)
	_code.text_submitted.connect(_join_online.unbind(1))
	(%JoinLan as Button).pressed.connect(_join_lan)
	_address.placeholder_text = "127.0.0.1:%d" % LAN_PORT
	_address.text_submitted.connect(_join_lan.unbind(1))
	_cancel.pressed.connect(session.leave)
	(%Leave as Button).pressed.connect(session.leave)
	_copy.pressed.connect(func() -> void: DisplayServer.clipboard_set(session.join_code))
	session.status_changed.connect(_on_status_changed)
	session.join_code_changed.connect(_refresh.unbind(1))
	_status.text = WELCOME
	_refresh()


func _join_online() -> void:
	if _code.text.strip_edges() != "":
		Unified.session.join_online(_code.text)


func _join_lan() -> void:
	var address := _address.text.strip_edges()
	Unified.session.join_direct(address if address != "" else _address.placeholder_text)


func _on_status_changed(status: UnifiedSession.Status, detail: String) -> void:
	match status:
		UnifiedSession.STATUS_CONNECTING:
			_status.text = "Connecting..."
		UnifiedSession.STATUS_FAILED:
			_status.text = "Could not start: %s" % detail if detail != "" else "Could not start."
		UnifiedSession.STATUS_DISCONNECTED:
			_status.text = "Disconnected: %s" % detail if detail != "" else "Disconnected."
		UnifiedSession.STATUS_LEFT:
			_status.text = WELCOME
	_refresh()


func _refresh() -> void:
	var session := Unified.session
	var status := session.status
	var playing := status in [UnifiedSession.STATUS_CONNECTED, UnifiedSession.STATUS_RECONNECTING, UnifiedSession.STATUS_RECOVERING]
	_menu.visible = not playing
	_cancel.visible = status == UnifiedSession.STATUS_CONNECTING
	_corner.visible = playing
	var code := session.join_code
	_shared.visible = code != ""
	_copy.visible = code != ""
	_shared.text = ("Lobby code  %s" if session.mode == UnifiedSession.MODE_HOST_ONLINE else "LAN address  %s") % code
	if not playing:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
