class_name UnifiedValidate
extends UnifiedTool
## The headless project check, no editor (the godot suite's `validate` step):
##   godot --headless -d --path games/<game> -s <this script> -- --no-settings [--frames=N]
## 1. compiles every script under res://game and res://addons/shared (`-d` makes Godot print GDScript warnings; uni
## fails on them), 2. loads and instantiates every scene and resource there (missing dependencies, and the unknown
## properties Godot silently drops), 3. checks the game's own contract with its sim (`_check_contract()`, in a game's
## game/tools/validate.gd that extends this), 4. runs the main scene for N frames (default 30) to catch runtime errors.

const ROOTS: Array[String] = ["res://game", "res://addons/shared"]


func _run() -> void:
	var files: Array[String] = []
	for dir in ROOTS:
		_walk(dir, files)
	var t0 := Time.get_ticks_usec()
	var scripts := 0
	for f in files:
		if f.ends_with(".gd"):
			scripts += 1
			var s: Script = ResourceLoader.load(f)  # a fresh process: the cache holds only what already compiled
			if s == null or not s.can_instantiate():
				log_capture.add("script failed to compile", f)
	var t1 := Time.get_ticks_usec()
	var resources := 0
	for f in files:
		if f.get_extension() in ["tscn", "tres", "gdshader"]:
			resources += 1
			var r := ResourceLoader.load(f)
			if r == null:
				log_capture.add("resource failed to load", f)
			elif r is PackedScene:
				_check_scene(f, r)
	var t2 := Time.get_ticks_usec()
	_check_play_scene_preloads()
	var errors_before := log_capture.errors.size()
	var contract := _check_contract()
	if contract == "ok" and log_capture.errors.size() > errors_before:
		contract = "differs"
	step("%d scripts, %d resources; contract: %s" % [scripts, resources, contract])
	var frames_to_run := int(arg("frames", "30"))
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	var t3 := Time.get_ticks_usec()
	await frames(frames_to_run)
	step("the main scene ran %d frames" % frames_to_run)
	result = {"scripts": scripts, "resources": resources, "contract": contract, "frames": frames_to_run,
		"warnings": log_capture.warnings.size(),
		"ms": {"scripts": _ms(t1 - t0), "resources": _ms(t2 - t1), "run": _ms(Time.get_ticks_usec() - t3)}}


## The scripts the play scene loads (its scenes' scripts, recursively) use no preload(): the main menu loads the
## play scene on a thread, and in Godot 4.7 a resource a script first preloads on a worker thread leaks at exit
## (games/shared/SPEC.md, Play scene). They load() what they need when they need it.
func _check_play_scene_preloads() -> void:
	var seen := {}
	var todo: Array[String] = [game.PLAY_SCENE]
	while not todo.is_empty():
		var path: String = todo.pop_back()
		if seen.has(path):
			continue
		seen[path] = true
		if path.ends_with(".gd") and FileAccess.get_file_as_string(path).contains("preload("):
			log_capture.add("a script of the play scene preloads (load() it instead: it loads on a thread)", path)
		for dep in ResourceLoader.get_dependencies(path):
			todo.append(dep.get_slice("::", 2) if dep.contains("::") else dep)


## The game's contract with its sim (constants the scripts read, sizes the scenes draw), each mismatch reported with
## `log_capture.add()`. Returns "ok" (or why it was skipped).
func _check_contract() -> String:
	return "none"


## Instantiates a scene and checks every property its file sets exists: Godot silently drops unknown ones (typos).
func _check_scene(file: String, scene: PackedScene) -> void:
	var inst := scene.instantiate()
	if inst == null:
		log_capture.add("scene failed to instantiate", file)
		return
	var state := scene.get_state()
	for i in state.get_node_count():
		var node := inst.get_node_or_null(state.get_node_path(i))
		if node == null:
			continue
		for p in state.get_node_property_count(i):
			var prop := state.get_node_property_name(i, p)
			if prop not in node:
				log_capture.add("unknown property '%s' on %s" % [prop, state.get_node_path(i)], file)
	inst.free()


## A value for a message, at most 160 characters.
static func short(v: Variant) -> String:
	var s := var_to_str(v).replace("\n", " ")
	return s if s.length() <= 160 else s.left(160) + "..."


static func _ms(usec: int) -> int:
	return roundi(usec / 1000.0)


static func _walk(dir: String, out: Array[String]) -> void:
	for f in DirAccess.get_files_at(dir):
		out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_walk(dir.path_join(d), out)
