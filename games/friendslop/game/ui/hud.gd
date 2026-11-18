extends CanvasLayer
## The in-game HUD (hud.tscn): the run clock and the best time, the checkpoint, a crosshair, the local player's state
## (holding, charge, held, stunned, fallen), the session panel and controls list, and banners for run events.
## Redrawn when the session data (Unified.data.hud), the roster, the lobby code or the input device changes.

const KEYS_HELD := [["Space (mash)", "Break free"], ["Esc", "Menu"]]
const PAD_HELD := [["A (mash)", "Break free"], ["Start", "Menu"]]
const KEYS_HOLDING := [["WASD", "Move"], ["Mouse", "Look"], ["Space", "Jump"], ["LMB / E", "Drop"],
	["Hold RMB / Q", "Charge, release to throw"], ["Esc", "Menu"]]
const PAD_HOLDING := [["Left stick", "Move"], ["Right stick", "Look"], ["A", "Jump"], ["RT", "Drop"],
	["Hold LT", "Charge, release to throw"], ["Start", "Menu"]]
const KEYS := [["WASD", "Move"], ["Mouse", "Look"], ["Space", "Jump"], ["LMB / E", "Grab"], ["Esc", "Menu"]]
const PAD := [["Left stick", "Move"], ["Right stick", "Look"], ["A", "Jump"], ["RT", "Grab"], ["Start", "Menu"]]

@onready var _phase: Label = %Phase
@onready var _clock: Label = %Clock
@onready var _best: Label = %Best
@onready var _state: Label = %State
@onready var _charge: ProgressBar = %Charge
@onready var _banner: Banner = %Banner
@onready var _session: SessionPanel = %Session
@onready var _controls: ControlsPanel = %Controls


func _ready() -> void:
	Unified.data.hud.changed.connect(_on_hud_changed)
	Unified.session.roster_changed.connect(_on_hud_changed)
	Unified.session.sim_event.connect(_on_sim_event)
	Game.lobby_code_changed.connect(_on_hud_changed.unbind(1))
	Game.input_device_changed.connect(_on_hud_changed.unbind(1))
	_on_hud_changed()


func _on_hud_changed() -> void:
	var h := Unified.data.hud
	if h.phase == EnumPhase.RUN:
		_phase.text = "RUN  ·  checkpoint %d" % maxi(h.checkpoint, 0)
		_clock.text = UiTheme.clock(h.run_s)
	elif h.phase == EnumPhase.FINISHED:
		_phase.text = "FINISHED  ·  back to the hub in %d" % ceili(h.reset_in_s)
		_clock.text = UiTheme.clock(h.run_s)
	else:
		_phase.text = "HUB"
		_clock.text = ""
	var best := _best_time(h.best_s)
	_best.text = "best %s" % UiTheme.clock(best) if best > 0.0 else ""
	_session.refresh(_session_rows(), h.phase == EnumPhase.HUB, "Walk through the start gate to start the run.")

	var me := _local_row()
	var holding := me != null and me.holding != EnumHeldKind.NONE
	var held := me != null and me.held
	_charge.value = me.charge if me != null else 0.0
	_charge.visible = holding and _charge.value > 0.0
	if held:
		_state.text = Game.hint("Mash Space to break free!", "Mash A to break free!")
	elif me != null and me.fallen:
		_state.text = "Oops!"
	elif me != null and me.stunned:
		_state.text = "Dazed"
	else:
		_state.text = ""
	if held:
		_controls.refresh(KEYS_HELD, PAD_HELD)
	elif holding:
		_controls.refresh(KEYS_HOLDING, PAD_HOLDING)
	else:
		_controls.refresh(KEYS, PAD)


func _session_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for player: int in Unified.session.get_players():
		var p := Unified.data.hud.players[Unified.session.get_player_slot(player)] as DataHudPlayer
		var tags: Array[String] = []
		if p.held:
			tags.append("held")
		if p.stunned:
			tags.append("dazed")
		if p.fallen:
			tags.append("fell")
		rows.append({"player": player, "name": Unified.session.get_player_name(player), "status": ", ".join(tags)})
	return rows


## The better of this session's best (the sim's) and the personal best kept in the settings; 0 when neither.
static func _best_time(session_best: float) -> float:
	var saved := Settings.best_time
	if saved <= 0.0 or (session_best > 0.0 and session_best < saved):
		return session_best
	return saved


## Verified events only (as the banners always were).
func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state != UnifiedSession.EVENT_CONFIRMED:
		return
	if event is EventRunStarted:
		_banner.show_message("GO!", UiTheme.GOOD)
	elif event is EventCheckpoint:
		var checkpoint := event as EventCheckpoint
		_banner.show_message("Checkpoint %d" % checkpoint.index)
	elif event is EventRunFinished:
		var finished := event as EventRunFinished
		var seconds := finished.duration_s
		_banner.show_message("Finished in %s" % UiTheme.clock(seconds), UiTheme.GOLD, 4.0)
		var saved := Settings.best_time
		if saved <= 0.0 or seconds < saved:
			Settings.best_time = seconds


## The local player's row of the HUD data (null until they hold a slot).
func _local_row() -> DataHudPlayer:
	var slot := Unified.session.get_player_slot(Unified.session.local_player)
	return Unified.data.hud.players[slot] as DataHudPlayer if slot >= 0 else null
