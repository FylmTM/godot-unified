extends Node3D
## The play scene: the session (single player unless the command line or `uni coop` started another mode), the
## yard the session shows under Level, the views under Views, the first-person rig, the bolts and grenades, the
## effects and the HUD.

@onready var session: UnifiedSession = %UnifiedSession


func _ready() -> void:
	session.level_root = %Level
	session.view_root = %Views
	session.sim_event.connect(_on_sim_event)
	if not session.running:
		session.start_single()


func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state != UnifiedSession.EVENT_CONFIRMED:  # printed once final: an EMITTED event can still be cancelled
		return
	if event is EventWaveStarted:
		print("tick %d: wave %d" % [event.tick, (event as EventWaveStarted).wave])
	elif event is EventVictory:
		print("tick %d: the yard held (%d kills)" % [event.tick, (event as EventVictory).kills])
	elif event is EventCoreDestroyed:
		print("tick %d: the core fell in wave %d" % [event.tick, (event as EventCoreDestroyed).wave])
