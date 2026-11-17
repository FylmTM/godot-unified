# The main thread's view-sync benchmark, run by `uni view-bench` (one Godot process per instance count):
#   godot [--headless] --path tests/godot_views -s res://view_bench.gd -- --bench N [--seconds S]
# A single player toy session whose Glue (ext/ext.odin, bench_frame) makes every tick N moving instances of one
# MultiMeshInstance3D (3D transforms and custom data, like the survivor's enemies), 64 moving plain3d scene views
# with _sim_update, and the local player's typed2d view; ui_accept is down on even ticks and up on odd ones, so the
# toy spawns a thing every other tick and expires as many (events to the player's view and the sim_event signal).
# After a second of warm-up it reads UnifiedSession.take_sync_stats over S seconds (default 2) and prints one line,
# "VIEW BENCH {json}": the per-frame means in microseconds and the per-event cost. Headless, set_buffer reaches
# Godot's dummy renderer; in a window it reaches the real one (and frames are paced by the display).
extends SceneTree

func arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	return args[at + 1] if at >= 0 and at + 1 < args.size() else fallback


func _initialize() -> void:
	var instances := int(arg("bench", "0"))
	var seconds := float(arg("seconds", "2"))
	if instances <= 0:
		printerr("view_bench: want -- --bench N (N > 0)")
		quit(1)
		return
	var world := Node3D.new()
	root.add_child(world)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.look_at_from_position(Vector3(12, 30, 40), Vector3(12, 0, 12))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = BoxMesh.new()
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = mm
	var marker := UnifiedMultiView.new()
	marker.kind = "multi3d"
	instance.add_child(marker)
	world.add_child(instance)
	var views := Node3D.new()
	world.add_child(views)
	var session := UnifiedSession.new()
	root.add_child(session)
	session.view_root = views
	await process_frame  # the session reads the command line when it is ready
	if not session.start_single():
		printerr("view_bench: start_single failed")
		quit(1)
		return
	var tick0 := 0
	var phase := 0  # 0: warm-up, 1: measuring
	var started_ms := Time.get_ticks_msec()
	while true:
		await process_frame
		var now := Time.get_ticks_msec()
		var down := session.get_tick() % 2 == 0
		if down != Input.is_action_pressed(&"ui_accept"):
			if down:
				Input.action_press(&"ui_accept")
			else:
				Input.action_release(&"ui_accept")
		if phase == 0 and now - started_ms >= 1000:
			if mm.visible_instance_count != instances:
				printerr("view_bench: %d instances shown, want %d" % [mm.visible_instance_count, instances])
				quit(1)
				return
			session.take_sync_stats()
			tick0 = session.get_tick()
			started_ms = now
			phase = 1
		elif phase == 1 and now - started_ms >= seconds * 1000.0:
			break
	var stats: Dictionary = session.take_sync_stats()
	var frames := maxf(stats.frames, 1)
	var out := {
		"instances": instances,
		"scene_views": views.get_child_count(),
		"frames": stats.frames,
		"fresh": stats.fresh,
		"fps": snappedf(stats.frames * 1000.0 / maxf(Time.get_ticks_msec() - started_ms, 1), 0.1),
		"ticks": session.get_tick() - tick0,
		"scene_us": snappedf(stats.scene_us / frames, 0.1),
		"multi_build_us": snappedf(stats.multi_build_us / frames, 0.1),
		"multi_upload_us": snappedf(stats.multi_upload_us / frames, 0.1),
		"delivery_us": snappedf(stats.delivery_us / frames, 0.1),
		"total_us": snappedf(stats.total_us / frames, 0.1),
		"total_max_us": snappedf(stats.total_max_us, 0.1),
		"events": stats.events,
		"event_us": snappedf(stats.delivery_us / maxf(stats.events, 1), 0.01),
	}
	print("VIEW BENCH ", JSON.stringify(out))
	session.leave()
	session.queue_free()
	await process_frame
	quit(0)
