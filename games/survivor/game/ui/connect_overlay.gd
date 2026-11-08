extends Control
## Shown by `Game` while an online session connects: live status, the lobby code when hosting, Cancel.

const DOTS := ["", ".", "..", "..."]

@onready var _status: Label = $Center/Panel/VBox/Status
@onready var _detail: Label = $Center/Panel/VBox/Detail
@onready var _code_box: Control = $Center/Panel/VBox/CodeBox
@onready var _code: Label = $Center/Panel/VBox/CodeBox/Row/Code
@onready var _copy: Button = $Center/Panel/VBox/CodeBox/Row/Copy
var _t := 0.0


func _ready() -> void:
	Game.status_changed.connect(func(_s: String, _d: String) -> void: _refresh())
	Game.lobby_code_changed.connect(func(_c: String) -> void: _refresh())
	_copy.pressed.connect(_copy_code)
	$Center/Panel/VBox/Bottom/Cancel.pressed.connect(func() -> void:
		Sfx.play(&"click")
		Game.leave_to_menu())
	$Center/Panel/VBox/Bottom/Cancel.grab_focus()
	_refresh()


func _process(delta: float) -> void:
	_t += delta
	if Game.status == "connecting":
		_status.text = "Connecting" + DOTS[int(_t * 3.0) % DOTS.size()]


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel") or event.is_action_pressed(&"menu"):
		get_viewport().set_input_as_handled()
		Game.leave_to_menu()


func _refresh() -> void:
	_status.text = "Connected" if Game.status == "connected" else "Connecting"
	_detail.text = Game.status_detail if Game.status_detail != "" else "Talking to the lobby service."
	_code_box.visible = Game.lobby_code != ""
	_code.text = Game.lobby_code
	$Center/Panel/VBox/Bottom/KeyHint.text = Game.hint("Esc to cancel", "B to cancel")


func _copy_code() -> void:
	Game.clipboard_set(Game.lobby_code)
	Sfx.play(&"gem")
	_copy.text = "Copied!"
	get_tree().create_timer(1.2).timeout.connect(func() -> void:
		if is_instance_valid(_copy):
			_copy.text = "Copy")
