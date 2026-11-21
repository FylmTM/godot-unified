extends CanvasLayer
## The in-game menu (the `menu` action, Esc or Start): Resume, Settings, Leave to menu. In single player it pauses the
## session (UnifiedSession.paused); with other players it is an overlay only (online a pause would be the game's own
## state). Game input is off while it is open (UnifiedSession.game_input: its clicks and keys don't reach the sim). A
## play scene instances pause_menu.tscn as `PauseMenu`. Clicks beside its panel reach the HUD under it: the mouse is
## free only while it is open, so that is where the session panel's Copy is clicked.

## Loaded at first use, not preloaded: this scene is part of the play scene, which loads on a thread.
const SETTINGS_PANEL := "res://game/ui/settings_panel.tscn"

var _settings: SettingsPanel

@onready var _panel: PanelContainer = %Panel
@onready var _resume: Button = %Resume


func _ready() -> void:
	tree_exiting.connect(_release)  # left to the menu while open
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
	Unified.session.game_input = false
	Unified.session.paused = true  # single player: the game stops; with others it is an overlay (reads back false)
	visible = true
	_panel.visible = true
	_resume.grab_focus()


func close() -> void:
	if _settings != null:
		_settings.visible = false
	visible = false
	_release()


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


## Input back on and the single-player pause off (closing, or leaving the play scene while open).
func _release() -> void:
	Unified.session.paused = false
	Unified.session.game_input = true
