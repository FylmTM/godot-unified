extends Node2D
## The naive horde (the render experiment's baseline): a scene view per hero, enemy, bolt, gem, bomb and blast
## (game/views/), every effect a node made per event (game/fx/), the HUD in Controls (game/ui/hud.gd). Written the
## straightforward way on purpose; examples/horde_tuned is the same game done well with nodes.

var _number_scene: PackedScene
var _lightning_script: GDScript
var _shake := 0.0

@onready var session: UnifiedSession = %UnifiedSession
@onready var camera: Camera2D = %Camera
@onready var sparks: Sparks = %Sparks
@onready var fx: Node2D = %Fx
@onready var hud: Hud = %Hud
@onready var probe: Probe = %Probe


func _ready() -> void:
	_number_scene = load("res://game/fx/damage_number.tscn")
	_lightning_script = load("res://game/fx/lightning.gd")
	session.sim_event.connect(_on_sim_event)
	hud.pick.connect(_on_pick)
	probe.attach(session)
	if not session.running:
		session.start_single()


func _process(delta: float) -> void:
	var hero := session.get_player_view(EnumView.HERO, session.local_player) as Node2D
	if hero != null:
		camera.position = camera.position.lerp(hero.position, 1.0 - exp(-8.0 * delta))
	_shake = maxf(_shake - delta * 30.0, 0.0)
	camera.offset = Vector2(randf_range(-1, 1), randf_range(-1, 1)) * _shake


func _on_pick(upgrade: int) -> void:
	var command := CommandPick.new()
	command.upgrade = upgrade
	session.send_command(command)


func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state == UnifiedSession.EVENT_CONFIRMED:
		if event is EventMatchOver:
			var over := event as EventMatchOver
			hud.show_over(over.wave, over.kills)
		return
	if state != UnifiedSession.EVENT_EMITTED:
		return
	if event is EventEnemyHit:
		var hit := event as EventEnemyHit
		var number := _number_scene.instantiate() as Label
		number.text = str(hit.damage)
		number.modulate = Palette.SOURCE_COLORS[hit.source]
		number.position = hit.position + Vector2(-20, -30)
		fx.add_child(number)
		sparks.burst(hit.position, 3, Palette.SOURCE_COLORS[hit.source], 120.0, 2.5, 0.3)
	elif event is EventEnemyDied:
		var died := event as EventEnemyDied
		sparks.burst(died.position, 14, Palette.ENEMY_COLORS[died.enemy_kind], 220.0, 3.5, 0.6)
	elif event is EventArc:
		var arc := event as EventArc
		var line := Line2D.new()
		line.set_script(_lightning_script)
		line.set(&"from", arc.from)
		line.set(&"to", arc.to)
		line.z_index = 10
		fx.add_child(line)
	elif event is EventBombLanded:
		var landed := event as EventBombLanded
		sparks.burst(landed.position, 30, Color(1.0, 0.6, 0.25), 360.0, 4.0, 0.7)
		_shake = minf(_shake + 4.0, 12.0)
	elif event is EventGemCollected:
		var gem := event as EventGemCollected
		sparks.burst(gem.position, 4, Color(0.4, 0.95, 1.0), 80.0, 2.0, 0.3)
	elif event is EventLevelUp:
		var up := event as EventLevelUp
		sparks.burst(up.position, 40, Color(1.0, 0.95, 0.5), 300.0, 3.0, 0.9)
