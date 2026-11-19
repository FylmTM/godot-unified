extends CanvasLayer
## The in-game HUD (hud.tscn): the phase and wave, the match time, the station's HP bar, the score; the lobby's start
## prompt (Enter or the Start button: the `start` command) and the restart prompt when the match is over
## (`restart`); banners for waves and the match's start and end; the session panel (code + players) and the
## controls list. It follows the HUD data (`changed`), the roster and the input device.

## Directions that make one control in the controls list (ControlsPanel.refresh).
const MOVE: Array[StringName] = [&"move_up", &"move_left", &"move_down", &"move_right"]
const AIM: Array[StringName] = [&"aim_up", &"aim_left", &"aim_down", &"aim_right"]

var _phase_shown := -1  ## the phase the controls list is for
var _hp_target := 1.0  ## the fraction the HP bar eases to
var _hp_tween: Tween

## The prompt's button (Start in the lobby, Restart when over); the tools click it.
@onready var start_button: Button = %Start
@onready var _phase: Label = %Phase
@onready var _time: Label = %Time
@onready var _hp: ProgressBar = %StationHp
@onready var _hp_label: Label = %StationHpLabel
@onready var _hp_fill := _hp.get_theme_stylebox(&"fill") as StyleBoxFlat
@onready var _score: Label = %Score
@onready var _prompt: Control = %Prompt
@onready var _prompt_text: Label = %PromptText
@onready var _prompt_sub: Label = %PromptSub
@onready var _banner: Banner = %Banner
@onready var _session: SessionPanel = %Session
@onready var _controls: ControlsPanel = %Controls


func _ready() -> void:
	start_button.pressed.connect(_start_or_restart)
	Unified.data.hud.changed.connect(_on_hud_changed)
	Unified.session.roster_changed.connect(_refresh_players)
	Unified.session.sim_event.connect(_on_sim_event)
	Game.input_device_changed.connect(_on_input_device_changed)
	Unified.session.join_code_changed.connect(_refresh_players.unbind(1))
	get_viewport().size_changed.connect(_refresh_controls)  # the controls list keeps to the bottom-right corner
	_on_hud_changed()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"start"):
		get_viewport().set_input_as_handled()
		_start_or_restart()


## The lobby's `start` or the over screen's `restart` command (anyone may send either).
func _start_or_restart() -> void:
	match Unified.data.hud.phase:
		EnumPhase.LOBBY:
			Sfx.play(&"click")
			Unified.session.send_command(CommandStart.new())
		EnumPhase.OVER:
			Sfx.play(&"click")
			Unified.session.send_command(CommandRestart.new())


func _on_hud_changed() -> void:
	var h: DataHud = Unified.data.hud
	var keys := Game.input_label(&"start")
	match h.phase:
		EnumPhase.MATCH:
			_phase.text = "WAVE %d  ·  next wave in %d s" % [h.wave, ceili(h.next_wave_s)]
			_time.text = UiTheme.clock(h.time_s)
		EnumPhase.OVER:
			_phase.text = "STATION LOST  ·  wave %d" % h.wave
			_time.text = UiTheme.clock(h.time_s)
			_prompt_text.text = "The station is lost: you held out %s" % UiTheme.clock(h.time_s)
			_prompt_sub.text = "Back to the lobby in %d s" % ceili(h.reset_in_s)
			start_button.text = "Restart"
		_:
			_phase.text = "LOBBY"
			_time.text = ""
			_prompt_text.text = "Press %s or click Start to start" % keys
			_prompt_sub.text = "Rocks drift in from the edges in waves. Keep them off the station."
			start_button.text = "Start"
	_prompt.visible = h.phase != EnumPhase.MATCH
	_show_station_hp(h.station_hp)
	var best := Settings.best_time
	_score.text = "score %d  ·  rocks %d%s" % [h.score, h.rocks,
		("  ·  best %s" % UiTheme.clock(best)) if best > 0.0 else ""]
	_refresh_players()
	if h.phase != _phase_shown:
		_phase_shown = h.phase
		_refresh_controls()


## The bar eases to the station's HP and takes its colour (good, gold, bad).
func _show_station_hp(hp: int) -> void:
	var full := Unified.constants.station_hp
	var fraction := float(hp) / full
	_hp_label.text = "STATION  %d / %d" % [hp, full]
	if fraction == _hp_target:
		return
	_hp_target = fraction
	_hp_fill.bg_color = UiTheme.health_color(fraction)
	if _hp_tween != null:
		_hp_tween.kill()
	_hp_tween = create_tween()
	_hp_tween.tween_property(_hp, "value", fraction, 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


func _on_input_device_changed(_pad: bool) -> void:
	_on_hud_changed()
	_refresh_controls()


## The session panel: every player with their gems.
func _refresh_players() -> void:
	var slots := Unified.data.hud.players
	var rows: Array[Dictionary] = []
	for player in Unified.session.get_players():
		var info := slots[Unified.session.get_player_slot(player)] as DataHudPlayer
		rows.append({"player": player, "name": Unified.session.get_player_name(player), "status": "%d gems" % info.gems})
	_session.refresh(rows, Unified.data.hud.phase == EnumPhase.LOBBY,
		"Press %s or click Start when everyone is in." % Game.input_label(&"start"))


## The controls list for the phase and the device in use.
func _refresh_controls() -> void:
	var rows := [[MOVE, "Move"], [AIM, "Aim", "Mouse"], [&"fire", "Fire"], [&"boost", "Boost"]]
	if _phase_shown != EnumPhase.MATCH:
		rows.append([&"start", "Start" if _phase_shown == EnumPhase.LOBBY else "Restart"])
	rows.append([&"menu", "Menu"])
	_controls.refresh(rows)


## Banners and the best time, once an event's tick is confirmed.
func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state != UnifiedSession.EVENT_CONFIRMED:
		return
	if event is EventMatchStarted:
		_banner.show_message("Defend the station!")
	elif event is EventWave:
		var wave := (event as EventWave).wave
		if wave > 1:
			_banner.show_message("Wave %d" % wave)
	elif event is EventMatchOver:
		_banner.show_message("Station lost", UiTheme.TEXT, 2.5)
		var survived := (event as EventMatchOver).duration_s
		if survived > Settings.best_time:
			Settings.best_time = survived
