extends Node3D
## The play scene: starts a session (a single-player one unless the session's flags say host or join), loads each
## scene's level under Level, and turns the tools' keys into commands (the grab is a held button of the Input).

@onready var session: UnifiedSession = %UnifiedSession
@onready var hud: Hud = $Hud

## The shape the spawn tool makes next (G cycles it).
var spawn_shape := 0


func _ready() -> void:
	session.view_root = %Views
	session.level_root = %Level
	if not session.running:
		session.start_single()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"shoot"):
		session.send_command(CommandShoot.new())
	elif event.is_action_pressed(&"spawn"):
		var spawn := CommandSpawn.new()
		spawn.shape = spawn_shape
		session.send_command(spawn)
	elif event.is_action_pressed(&"next_shape"):
		spawn_shape = (spawn_shape + 1) % EnumShape.names().size()
		hud.show_shape(spawn_shape)
	elif event.is_action_pressed(&"explode"):
		session.send_command(CommandExplode.new())
	elif event.is_action_pressed(&"drive"):
		session.send_command(CommandDrive.new())
	elif event.is_action_pressed(&"reset_scene"):
		_go_to(Unified.data.hud.scene)
	elif event.is_action_pressed(&"next_scene"):
		_go_to((Unified.data.hud.scene + 1) % EnumLevel.names().size())
	elif event.is_action_pressed(&"previous_scene"):
		var count := EnumLevel.names().size()
		_go_to((Unified.data.hud.scene + count - 1) % count)


## Everyone goes to `scene` (the current one: it resets).
func _go_to(scene: int) -> void:
	var command := CommandScene.new()
	command.scene = scene
	session.send_command(command)
