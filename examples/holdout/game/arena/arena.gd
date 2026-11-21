class_name HoldoutArena
extends Node3D
## The play scene (Game.PLAY_SCENE): the level root the session instances the yard under, the views root handed to
## the session (Game owns it: `Unified.session`), the first-person rig, the bolts and grenades, the effects, the HUD
## and the pause menu. Routes the sim's events to sounds: what happens in the yard at once (EMITTED: a shot, a throw, a
## blast, a death; short enough that a cancelled one needs no undoing), the run's turns once verified (CONFIRMED). The
## hit marker's own sounds are the HUD's.


func _ready() -> void:
	Unified.session.view_root = %Views
	Unified.session.level_root = %Level
	Unified.session.sim_event.connect(_on_sim_event)


func _on_sim_event(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
	var me := Unified.session.local_player
	if state == UnifiedSession.EVENT_EMITTED:
		if event is EventShot:
			var shot := event as EventShot
			if shot.player == me:
				Sfx.play(&"shot", 0.0, randf_range(0.95, 1.05))
		elif event is EventGrenadeThrown:
			if (event as EventGrenadeThrown).player == me:
				Sfx.play(&"throw")
		elif event is EventExplosion:
			Sfx.play(&"boom")
		elif event is EventEnemyDied:
			Sfx.play(&"enemy_die", -4.0, randf_range(0.9, 1.1))
		elif event is EventBoltFired:
			Sfx.play(&"spit", -8.0)
		elif event is EventPlayerHurt:
			if (event as EventPlayerHurt).player == me:
				Sfx.play(&"hurt")
		return
	if state != UnifiedSession.EVENT_CONFIRMED:
		return
	if event is EventShot:
		if (event as EventShot).player != me:  # a teammate's, as their late body fires it
			Sfx.play(&"shot", -9.0, randf_range(0.9, 1.0))
	elif event is EventCoreHit:
		Sfx.play(&"core_hit", -4.0)
	elif event is EventPlayerDowned:
		Sfx.play(&"downed", 0.0 if (event as EventPlayerDowned).player == me else -6.0)
	elif event is EventPlayerRevived or event is EventPlayerRespawned:
		Sfx.play(&"revived")
	elif event is EventWaveStarted:
		Sfx.play(&"wave")
	elif event is EventWaveCleared:
		Sfx.play(&"cleared")
	elif event is EventVictory:
		Sfx.play(&"victory")
	elif event is EventCoreDestroyed:
		Sfx.play(&"defeat")
