extends CanvasLayer
## The in-game menu (the `menu` action, Esc or Start): Resume, Invite friends (a single-player session opens to friends,
## online when the build can, else on the LAN port, and keeps running: the join code shows on the session panel; Stop
## inviting lets nobody new in), Settings, Leave to menu. In single player it pauses the session (UnifiedSession.paused;
## inviting friends ends the pause); with other players it is an overlay only (online a pause would be the game's own
## state). Game input is off while it is open (UnifiedSession.game_input: its clicks and keys don't reach the sim). A
## play scene instances pause_menu.tscn as `PauseMenu`.

## Loaded at first use, not preloaded: this scene is part of the play scene, which loads on a thread.
const SETTINGS_PANEL := "res://game/ui/settings_panel.tscn"

var _settings: SettingsPanel

@onready var _panel: PanelContainer = %Panel
@onready var _resume: Button = %Resume


func _ready() -> void:
	tree_exiting.connect(_release)  # left to the menu while open
	_resume.pressed.connect(_click.bind(close))
	(%Invite as Button).pressed.connect(_click.bind(_invite))
	(%StopInviting as Button).pressed.connect(_click.bind(_stop_inviting))
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
	var session := Unified.session
	var single := session.mode == UnifiedSession.MODE_SINGLE
	var opened := Game.invited and session.mode in [UnifiedSession.MODE_HOST_ONLINE, UnifiedSession.MODE_HOST_DIRECT]
	(%Invite as Button).visible = single or (opened and session.join_code == "")
	(%StopInviting as Button).visible = opened and session.join_code != ""
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


## Opens the running single-player session to friends (the session goes on; nobody waits): Game.invite_friends.
func _invite() -> void:
	Game.invite_friends()
	close()


## Nobody new gets in; the friends playing stay, and one who drops may come back.
func _stop_inviting() -> void:
	Unified.session.close_online()
	close()


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
