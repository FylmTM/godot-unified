extends CanvasLayer
## The in-game HUD (hud.tscn), from the session data (Unified.data.hud: the newest prediction, so it may roll back)
## and the sim's events: the wave and phase, the core's health, the local player's health, grenade and kills, a
## crosshair with its hit marker, the big message (the countdown, downed and getting up, the result), banners for the
## run's turns, the session panel (in the lobby: the code to share and who is in) and the controls list. The result
## and the banners come from CONFIRMED events only: a prediction can still take them back.
##
## The hit marker follows the local player's own shots at once (EMITTED): a shot that hit (EventShot.hit) flashes the
## X, red when an EventEnemyHit of the same tick was on a head where that shot struck (the shot's end is the hit's
## point), and the kill ring when an enemy dies to them (EventEnemyDied.killer). Each with its sound.

const MOVE: Array[StringName] = [&"move_forward", &"move_left", &"move_back", &"move_right"]
const LOOK: Array[StringName] = [&"look_up", &"look_left", &"look_down", &"look_right"]
## The controls list per context (action, what it does): see ControlsPanel.refresh.
const CONTROLS_LOBBY := [[&"ready", "Start the run"], [MOVE, "Move"], [LOOK, "Look", "Mouse"], [&"jump", "Jump"],
	[&"fire", "Fire"], [&"grenade", "Grenade"], [&"camera", "Yard views"], [&"menu", "Menu"]]
const CONTROLS := [[MOVE, "Move"], [LOOK, "Look", "Mouse"], [&"jump", "Jump"], [&"fire", "Fire"],
	[&"grenade", "Grenade"], [&"use", "Revive (hold)"], [&"camera", "Yard views"], [&"menu", "Menu"]]
const CONTROLS_DOWNED := [[&"camera", "Yard views"], [&"menu", "Menu"]]
## A shot's end and an enemy hit's point are the same sim position: this close (metres) is a match.
const SAME_POINT := 0.01

var _result := ""
## This frame's EMITTED hit feedback, resolved in _process (a tick's events can come in either order).
var _shots_hit: Array[Vector3] = []  # where the local player's shots that hit struck
var _head_hits: Array[Vector3] = []  # where heads were hit
var _killed := 0
var _countdown := -1  # the whole second the countdown or break last beeped at
## The controls list on show (one of the CONTROLS consts) and the device it was labelled for.
var _controls_for: Array = []
var _controls_pad := false

@onready var _wave: Label = %Wave
@onready var _core_bar: ProgressBar = %CoreBar
@onready var _hp_bar: ProgressBar = %HpBar
@onready var _grenade: ProgressBar = %Grenade
@onready var _kills: Label = %Kills
@onready var _message: Label = %Message
@onready var _hurt: ColorRect = %Hurt
@onready var _crosshair: Control = %Crosshair
@onready var _hit_marker: HitMarker = %HitMarker
@onready var _banner: Banner = %Banner
@onready var _session: SessionPanel = %Session
@onready var _controls: ControlsPanel = %Controls


func _ready() -> void:
	_core_bar.max_value = Unified.constants.core_hp
	Unified.session.sim_event.connect(_on_sim_event)
	Unified.data.hud.changed.connect(_on_panels_changed)
	Unified.session.roster_changed.connect(_on_panels_changed)
	Unified.session.join_code_changed.connect(_on_panels_changed.unbind(1))
	Game.input_device_changed.connect(_on_panels_changed.unbind(1))
	_on_panels_changed()


func _process(delta: float) -> void:
	var hud := Unified.data.hud
	var waves: int = Unified.constants.waves
	match hud.phase:
		EnumPhase.LOBBY:
			_wave.text = "Lobby"
		EnumPhase.COUNTDOWN:
			_wave.text = "Wave 1 in %d" % ceili(hud.timer_s)
		EnumPhase.WAVE:
			_wave.text = "Wave %d / %d   enemies %d" % [hud.wave, waves, hud.enemies]
		EnumPhase.BREAK:
			_wave.text = "Wave %d in %d" % [hud.wave + 1, ceili(hud.timer_s)]
		EnumPhase.OVER:
			_wave.text = "Wave %d / %d" % [hud.wave, waves]
	_core_bar.value = hud.core_hp
	_hp_bar.value = hud.hp
	_grenade.value = 1.0 - hud.grenade
	_kills.text = "kills %d (team %d)" % [hud.my_kills, hud.kills]
	_crosshair.visible = hud.up
	_message.text = _message_of(hud)
	_hurt.color.a = move_toward(_hurt.color.a, 0.0, delta * 1.5)
	_beep_countdown(hud)
	_show_hits()


func _message_of(hud: DataHud) -> String:
	if hud.phase == EnumPhase.OVER and _result != "":
		return _result
	if hud.downed:
		if hud.revive > 0.0:
			return "Getting up... %d%%" % roundi(hud.revive * 100.0)
		return "Down! Up at your spawn in %d (a teammate can revive you: hold %s)" % [ceili(hud.respawn_s),
			Game.input_label(&"use")]
	if hud.phase == EnumPhase.LOBBY:
		return "Press %s when everyone is ready" % Game.input_label(&"ready")
	if hud.phase == EnumPhase.COUNTDOWN:
		return "%d" % ceili(hud.timer_s)
	return ""


## The session panel and the controls list, when the session data, the roster, the code or the input device changes.
func _on_panels_changed() -> void:
	var hud := Unified.data.hud
	var lobby := hud.phase == EnumPhase.LOBBY
	_session.refresh(_session_rows(), lobby, "Press %s to start the run." % Game.input_label(&"ready"))
	var controls: Array = CONTROLS_DOWNED if hud.downed else (CONTROLS_LOBBY if lobby else CONTROLS)
	if not is_same(controls, _controls_for) or Game.using_pad != _controls_pad:
		_controls_for = controls
		_controls_pad = Game.using_pad
		_controls.refresh(controls)


## A row per present player for the session panel: "down" from their player view (the HUD data's players_down
## changes with it, so the panel is redrawn).
func _session_rows() -> Array[SessionPanel.Row]:
	var rows: Array[SessionPanel.Row] = []
	for player: int in Unified.session.get_players():
		var row := SessionPanel.Row.new(player, Unified.session.get_player_name(player))
		var view := Unified.session.get_player_view(EnumView.PLAYER, player)
		if view != null:
			var data: ViewPlayer = view.get(&"data")
			if data.downed:
				row.status = "down"
		rows.append(row)
	return rows


## A beep on each of the countdown's last seconds, and the break's.
func _beep_countdown(hud: DataHud) -> void:
	var second := ceili(hud.timer_s) if hud.phase in [EnumPhase.COUNTDOWN, EnumPhase.BREAK] else -1
	if second != _countdown and second >= 1 and second <= 3:
		Sfx.play(&"beep", -2.0, 1.0 if second > 1 else 1.25)
	_countdown = second


## This frame's hits and kills of the local player's on the hit marker, with their sounds.
func _show_hits() -> void:
	var headshot := false
	for at in _shots_hit:
		var on_head := _head_hits.any(func(h: Vector3) -> bool: return h.distance_to(at) < SAME_POINT)
		headshot = headshot or on_head
		_hit_marker.hit(on_head)
	if not _shots_hit.is_empty():
		Sfx.play(&"headshot" if headshot else &"hit")
		Game.rumble(0.2, 0.0, 0.05)
	if _killed > 0:
		_hit_marker.kill()
		Sfx.play(&"kill")
	_shots_hit.clear()
	_head_hits.clear()
	_killed = 0


func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	var me := Unified.session.local_player
	if state == UnifiedSession.EVENT_EMITTED:
		if event is EventPlayerHurt and (event as EventPlayerHurt).player == me:
			_hurt.color.a = 0.35
		elif event is EventShot:
			var shot := event as EventShot
			if shot.player == me and shot.hit:
				_shots_hit.append(shot.to)
		elif event is EventEnemyHit:
			var hit := event as EventEnemyHit
			if hit.headshot:
				_head_hits.append(hit.at)
		elif event is EventEnemyDied and (event as EventEnemyDied).killer == me:
			_killed += 1
		return
	if state != UnifiedSession.EVENT_CONFIRMED:
		return
	var waves: int = Unified.constants.waves
	if event is EventWaveStarted:
		var wave := (event as EventWaveStarted).wave
		_banner.show_message("Final wave" if wave == waves else "Wave %d" % wave, UiTheme.ACCENT)
	elif event is EventWaveCleared:
		_banner.show_message("Wave %d cleared" % (event as EventWaveCleared).wave, UiTheme.GOOD)
	elif event is EventVictory:
		_result = "The yard held! %d kills" % (event as EventVictory).kills
		_banner.show_message("THE YARD HELD", UiTheme.GOLD, 4.0)
	elif event is EventCoreDestroyed:
		_result = "The core fell in wave %d" % (event as EventCoreDestroyed).wave
		_banner.show_message("THE CORE FELL", UiTheme.BAD, 4.0)
	elif event is EventLobby:
		_result = ""
