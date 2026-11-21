extends Node3D
## The play scene (Game.PLAY_SCENE): the level root the session instances each scene's level under, the views root
## handed to the session (the `Game` autoload owns the session: the menus, the session flags or `uni coop` start it),
## the flying camera, the HUD, the pause menu and a loading view while a level's scene loads. It turns the tools' keys
## into commands while the game has the input (the grab is a held button of the Input), and routes sim events to
## sounds and camera shake.

## Beyond this distance (metres) from the camera an event is silent.
const HEARING := 40.0
## Within this distance (metres) an explosion shakes the camera, the more the closer.
const SHAKE_RANGE := 18.0

## The shape the spawn tool makes next (`next_shape` cycles it).
var spawn_shape := 0
## Per predicted shot (its event id): the token of its sound, stopped if a rollback cancels the shot.
var _shots: Dictionary[int, int] = {}

@onready var camera_rig: CameraRig = $CameraRig
@onready var hud: Hud = $HUD
@onready var _loading: CanvasLayer = $Loading


func _ready() -> void:
	var session := Unified.session
	session.view_root = %Views
	session.level_root = %Level
	session.level_changing.connect(func(_to: int) -> void: _loading.visible = true)
	session.level_changed.connect(func(_level_id: int) -> void: _loading.visible = false)
	session.sim_event.connect(_on_sim_event)
	hud.show_shape(spawn_shape)


func _unhandled_input(event: InputEvent) -> void:
	var session := Unified.session
	if session.status != UnifiedSession.STATUS_CONNECTED or not session.game_input:
		return
	if event.is_action_pressed(&"shoot"):
		session.send_command(CommandShoot.new())
	elif event.is_action_pressed(&"spawn"):
		var spawn := CommandSpawn.new()
		spawn.shape = spawn_shape
		session.send_command(spawn)
	elif event.is_action_pressed(&"next_shape"):
		spawn_shape = (spawn_shape + 1) % EnumShape.names().size()
		hud.show_shape(spawn_shape)
		Sfx.play(&"click")
	elif event.is_action_pressed(&"explode"):
		session.send_command(CommandExplode.new())
	elif event.is_action_pressed(&"drive"):
		session.send_command(CommandDrive.new())
	elif event.is_action_pressed(&"reset_scene"):
		go_to(Unified.data.hud.scene)
	elif event.is_action_pressed(&"next_scene"):
		go_to((Unified.data.hud.scene + 1) % EnumLevel.names().size())
	elif event.is_action_pressed(&"previous_scene"):
		var count := EnumLevel.names().size()
		go_to((Unified.data.hud.scene + count - 1) % count)


## Everyone goes to `scene` (the current one: it resets).
func go_to(scene: int) -> void:
	var command := CommandScene.new()
	command.scene = scene
	Unified.session.send_command(command)


## Effects play when an event is first shown (predicted, or confirmed when nothing predicted it): a cancelled shot's
## sound stops; the other effects are short and left as they played. The scene change waits for its confirmed tick
## (its banner is the HUD's).
func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if event is EventShot:
		var shot := event as EventShot
		match state:
			UnifiedSession.EVENT_EMITTED:
				var mine := shot.player == Unified.session.local_player
				var token := Sfx.play(&"shoot", -4.0 if mine else _volume(shot.position, -10.0), randf_range(0.95, 1.08))
				if token != 0:
					_shots[event.id] = token
				if mine:
					camera_rig.shake(0.08)
			UnifiedSession.EVENT_CANCELLED:
				if _shots.has(event.id):
					Sfx.stop(_shots[event.id])
					_shots.erase(event.id)
			UnifiedSession.EVENT_CONFIRMED:
				_shots.erase(event.id)
		return
	if event is EventSceneEntered:
		if state == UnifiedSession.EVENT_CONFIRMED:
			Sfx.play(&"scene", -4.0)
		return
	if state != UnifiedSession.EVENT_EMITTED:
		return
	if event is EventExploded:
		var exploded := event as EventExploded
		Sfx.play(&"boom", _volume(exploded.position, -2.0), randf_range(0.9, 1.1))
		var near := 1.0 - exploded.position.distance_to(camera_rig.global_position) / SHAKE_RANGE
		if near > 0.0:
			camera_rig.shake(0.15 + 0.35 * near)
			Game.rumble(0.3 * near, 0.6 * near, 0.25)
	elif event is EventSpawned:
		var spawned := event as EventSpawned
		Sfx.play(&"pop", _volume(spawned.position, -4.0), randf_range(0.9, 1.15))
	elif event is EventGrabbed:
		var grabbed := event as EventGrabbed
		Sfx.play(&"grab", -6.0 if grabbed.player == Unified.session.local_player else _volume(grabbed.position, -14.0))
	elif event is EventReleased:
		if (event as EventReleased).player == Unified.session.local_player:
			Sfx.play(&"release", -8.0)
	elif event is EventJointBroke:
		var broke := event as EventJointBroke
		Sfx.play(&"crack", _volume(broke.position, -8.0), randf_range(0.85, 1.2))
	elif event is EventSensorEntered:
		var entered := event as EventSensorEntered
		Sfx.play(&"blip", _volume(entered.position, -10.0), 1.0 + 0.15 * entered.sensor)


## A sound's volume (dB) at `at`: `loudest` at the camera, quieter with distance, silent past HEARING.
func _volume(at: Vector3, loudest: float) -> float:
	var distance := at.distance_to(camera_rig.global_position)
	return loudest - 24.0 * minf(distance / HEARING, 1.0) - (80.0 if distance > HEARING else 0.0)
