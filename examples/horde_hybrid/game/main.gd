extends Node2D
## The hybrid horde: the world is drawn in Odin from the State every frame (simulation/extension/draw.odin, immediate
## mode), the HUD is GDScript Controls on session data (game/ui/hud.gd). This script only starts the session and
## sends the HUD's picks.

@onready var session: UnifiedSession = %UnifiedSession
@onready var hud: Hud = %Hud
@onready var probe: Probe = %Probe


func _ready() -> void:
	hud.pick.connect(_on_pick)
	probe.attach(session)
	if not session.running:
		session.start_single()


func _on_pick(upgrade: int) -> void:
	var command := CommandPick.new()
	command.upgrade = upgrade
	session.send_command(command)
