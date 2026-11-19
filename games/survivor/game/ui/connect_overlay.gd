extends Control
## Shown by `Game` while an online session connects: the live status, the lobby code when hosting, Cancel.

const DOTS: Array[String] = ["", ".", "..", "..."]

var _t := 0.0

@onready var _status: Label = %Status
@onready var _detail: Label = %Detail
@onready var _code_box: Control = %CodeBox
@onready var _code: Label = %Code
@onready var _copy: Button = %Copy
@onready var _cancel: Button = %Cancel
@onready var _key_hint: Label = %KeyHint


func _ready() -> void:
	Game.status_changed.connect(func(_s: UnifiedSession.Status, _d: String) -> void: _refresh())
	Unified.session.join_code_changed.connect(func(_c: String) -> void: _refresh())
	Game.input_device_changed.connect(func(_pad: bool) -> void: _refresh())
	_copy.pressed.connect(func() -> void: Game.copy_with_feedback(_copy, _code.text))
	_cancel.pressed.connect(func() -> void:
		Sfx.play(&"click")
		Game.leave_to_menu())
	_cancel.grab_focus()
	_refresh()


func _process(delta: float) -> void:
	_t += delta
	if Game.status == UnifiedSession.STATUS_CONNECTING:
		_status.text = "Connecting" + DOTS[int(_t * 3.0) % DOTS.size()]


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel") or event.is_action_pressed(&"menu"):
		get_viewport().set_input_as_handled()
		Game.leave_to_menu()


func _refresh() -> void:
	_status.text = "Connected" if Game.status == UnifiedSession.STATUS_CONNECTED else "Connecting"
	_detail.text = Game.status_detail if Game.status_detail != "" else "Talking to the lobby service."
	_code.text = Unified.session.join_code if Game.mode == Game.Mode.HOST else ""  # online: the lobby code
	_code_box.visible = _code.text != ""
	_key_hint.text = "%s to cancel" % Game.input_label(&"ui_cancel")
