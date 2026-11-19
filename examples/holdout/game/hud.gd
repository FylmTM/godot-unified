extends Control
## The HUD, from the session data (Unified.data.hud: the newest prediction, so it may roll back) and a few events:
## the wave and phase, the core's health, the local player's health and grenade, a crosshair, and the big message
## (the countdown, downed and getting up, the result). The result shows from CONFIRMED events only: a prediction can
## still take it back.

@onready var _wave: Label = %Wave
@onready var _core_bar: ProgressBar = %CoreBar
@onready var _hp_bar: ProgressBar = %HpBar
@onready var _grenade: ProgressBar = %Grenade
@onready var _kills: Label = %Kills
@onready var _message: Label = %Message
@onready var _hurt: ColorRect = %Hurt
@onready var _crosshair: Control = %Crosshair

var _result := ""


func _ready() -> void:
	_core_bar.max_value = Unified.constants.core_hp
	Unified.session.sim_event.connect(_on_sim_event)


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


func _message_of(hud: DataHud) -> String:
	if hud.phase == EnumPhase.OVER and _result != "":
		return _result
	if hud.downed:
		if hud.revive > 0.0:
			return "Getting up... %d%%" % roundi(hud.revive * 100.0)
		return "Down! Up at your spawn in %d (a teammate can revive you: hold E)" % ceili(hud.respawn_s)
	if hud.phase == EnumPhase.LOBBY:
		return "Press R when everyone is ready"
	if hud.phase == EnumPhase.COUNTDOWN:
		return "%d" % ceili(hud.timer_s)
	return ""


func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if event is EventPlayerHurt and state == UnifiedSession.EVENT_EMITTED:
		if (event as EventPlayerHurt).player == Unified.session.local_player:
			_hurt.color.a = 0.35
	if state != UnifiedSession.EVENT_CONFIRMED:
		return
	if event is EventVictory:
		_result = "The yard held! %d kills" % (event as EventVictory).kills
	elif event is EventCoreDestroyed:
		_result = "The core fell in wave %d" % (event as EventCoreDestroyed).wave
	elif event is EventLobby:
		_result = ""
