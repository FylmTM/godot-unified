extends CanvasLayer
## The in-game menu (the `menu` action, Esc or Start): Resume, Settings, Leave to menu. The sim never pauses (online
## it can't; offline the session has no pause either), so this is an overlay only. A play scene instances
## pause_menu.tscn as `PauseMenu`.

## Loaded at first use, not preloaded: this scene is part of the play scene, which loads on a thread.
const SETTINGS_PANEL := "res://addons/shared/ui/settings_panel.tscn"

var _settings: SettingsPanel

@onready var _panel: PanelContainer = %Panel
@onready var _resume: Button = %Resume


func _ready() -> void:
	_resume.pressed.connect(_click.bind(close))
	(%Settings as Button).pressed.connect(_click.bind(_open_settings))
	(%Leave as Button).pressed.connect(_click.bind(Game.leave_to_menu.bind("")))


func _unhandled_input(event: InputEvent) -> void:
	if not (event.is_action_pressed(&"menu") or (visible and event.is_action_pressed(&"ui_cancel"))):
		return
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
	_resume.grab_focus()


func close() -> void:
	if _settings != null:
		_settings.visible = false
	visible = false


func _click(action: Callable) -> void:
	Sfx.play(&"click")
	action.call()


func _open_settings() -> void:
	if _settings == null:
		_settings = (load(SETTINGS_PANEL) as PackedScene).instantiate()
		(%Center as Control).add_child(_settings)
		_settings.closed.connect(_close_settings)
	_panel.visible = false
	_settings.visible = true


func _close_settings() -> void:
	_settings.visible = false
	_panel.visible = true
	_resume.grab_focus()
