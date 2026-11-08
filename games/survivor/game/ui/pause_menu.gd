extends CanvasLayer
## Esc menu: Resume, Settings, Leave to menu. The sim never pauses (online it can't; offline the session has no
## pause either), so this is an overlay only.

const SETTINGS_PANEL := preload("res://game/ui/settings_panel.tscn")

@onready var _panel: PanelContainer = $Center/Panel
var _settings: Control


func _ready() -> void:
	$Center/Panel/VBox/Resume.pressed.connect(_click.bind(close))
	$Center/Panel/VBox/Settings.pressed.connect(_click.bind(_open_settings))
	$Center/Panel/VBox/Leave.pressed.connect(_click.bind(Game.leave_to_menu.bind("")))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"menu") or (visible and event.is_action_pressed(&"ui_cancel")):
		get_viewport().set_input_as_handled()
		if not visible:
			open()
		elif _settings != null and _settings.visible:
			_close_settings()
		else:
			close()


func open() -> void:
	visible = true
	_panel.visible = true
	$Center/Panel/VBox/Resume.grab_focus()


func close() -> void:
	if _settings != null:
		_settings.visible = false
	visible = false


func _click(action: Callable) -> void:
	Sfx.play(&"click")
	action.call()


func _open_settings() -> void:
	if _settings == null:
		_settings = SETTINGS_PANEL.instantiate()
		$Center.add_child(_settings)
		_settings.closed.connect(_close_settings)
	_panel.visible = false
	_settings.visible = true


func _close_settings() -> void:
	_settings.visible = false
	_panel.visible = true
	$Center/Panel/VBox/Resume.grab_focus()
