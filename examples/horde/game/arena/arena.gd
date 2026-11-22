class_name HordeArena
extends Node2D
## The match scene: hands its `Views` node to the session (heroes, bombs and blasts spawn there; the crowds are the
## MultiMesh views under `MultiViews`) and turns the sim's events into effects, sounds, shake and rumble. Those play
## when an event is emitted, a prediction too, so a hit answers at once; one a rollback cancels is left as it played.
## Banners and the match's record wait for the confirmation (hud.gd). Positions arrive in pixels (Glue.view_scale).

@onready var _views: Node2D = $Views
@onready var _camera: HordeCamera = $Camera
@onready var _sparks: Sparks = $Fx/Sparks
@onready var _numbers: Numbers = $Fx/Numbers
@onready var _arcs: Arcs = $Fx/Arcs


func _ready() -> void:
	Unified.session.view_root = _views
	Unified.session.sim_event.connect(_on_sim_event)


func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	if state != UnifiedSession.EVENT_EMITTED:
		return
	var local := Unified.session.local_player
	if event is EventEnemyHit:
		var hit := event as EventEnemyHit
		var color := Palette.SOURCE_COLORS[hit.source]
		_numbers.show_number(hit.position, hit.damage, color)
		_sparks.burst(hit.position, 3, color, 120.0, 2.5, 0.3)
	elif event is EventEnemyDied:
		var died := event as EventEnemyDied
		_sparks.burst(died.position, 14, Palette.ENEMY_COLORS[died.enemy_kind], 220.0, 3.5, 0.6)
		Sfx.play(&"pop", -14.0, randf_range(0.85, 1.3))
	elif event is EventArc:
		var arc := event as EventArc
		_arcs.add(arc.from, arc.to)
		if arc.link == 0:
			Sfx.play(&"zap", -12.0 if arc.player == local else -18.0, randf_range(0.9, 1.2))
	elif event is EventBoltFired:
		Sfx.play(&"bolt", -12.0 if (event as EventBoltFired).player == local else -18.0, randf_range(0.95, 1.1))
	elif event is EventBombLanded:
		var landed := event as EventBombLanded
		_sparks.burst(landed.position, 30, Palette.BLAST, 360.0, 4.0, 0.7)
		_camera.shake(4.0)
		Sfx.play(&"boom", -8.0, randf_range(0.9, 1.1))
	elif event is EventGemCollected:
		var gem := event as EventGemCollected
		_sparks.burst(gem.position, 4, Palette.GEM, 80.0, 2.0, 0.3)
		if gem.player == local:
			Sfx.play(&"gem", -10.0, randf_range(0.95, 1.15))
	elif event is EventLevelUp:
		var level_up := event as EventLevelUp
		_sparks.burst(level_up.position, 40, Palette.LEVEL_UP, 300.0, 3.0, 0.9)
		if level_up.player == local:
			Sfx.play(&"level")
	elif event is EventHeroHurt:
		var hurt := event as EventHeroHurt
		_sparks.burst(hurt.position, 6, UiTheme.BAD, 140.0, 3.0, 0.35)
		if hurt.player == local:
			Sfx.play(&"hurt", -4.0)
			Game.rumble(0.25, 0.35, 0.12)
	elif event is EventHeroDown:
		var down := event as EventHeroDown
		_sparks.burst(down.position, 36, UiTheme.BAD, 260.0, 4.0, 0.8)
		Sfx.play(&"down")
		if down.player == local:
			_camera.shake(10.0)
			Game.rumble(0.6, 0.8, 0.35)
	elif event is EventMatchOver:
		Sfx.play(&"over")
	elif event is EventPlayerJoined:
		Sfx.play(&"join", -6.0)
