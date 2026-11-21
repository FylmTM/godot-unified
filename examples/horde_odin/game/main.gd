extends Node2D
## The all-Odin horde: the world, the effects and the UI are drawn in Odin (simulation/extension). This script only
## starts the session (the library has no project setting for that) and hands it to the measurement probe.

@onready var session: UnifiedSession = %UnifiedSession
@onready var probe: Probe = %Probe


func _ready() -> void:
	probe.attach(session)
	if not session.running:
		session.start_single()
