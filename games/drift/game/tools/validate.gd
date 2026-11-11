extends SceneTree
## Headless project check, no editor:
##   godot --headless -d --path games/drift -s res://game/tools/validate.gd -- --no-settings [--frames=N]
## 1. compiles every .gd under res://game (`-d` makes Godot print GDScript warnings; tools/game.py fails on them),
## 2. loads and instantiates every .tscn/.tres (missing deps, and the unknown properties Godot silently drops),
## 3. with the game library loaded, checks the view contract the scripts rely on (the sim's constants, one rock bulk
## view per rock shape, the level's px_per_m), 4. runs the main scene for N frames (default 30) to catch runtime
## errors. The level export being current is checked after this script by tools/game.py (export-level --check). Prints a summary and one `UNIFIED_RESULT {...}` line; exits 1 on any error.

var cap: Logger
var frames := 30
var report := {}
var _t := 0
var _left := 0
var _quitting := false


func _init() -> void:
	cap = load("res://game/tools/log_capture.gd").new()
	OS.add_logger(cap)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--frames="):
			frames = int(a.trim_prefix("--frames="))


## Runs on the first frame: autoload names (Game, Settings, Sfx) only resolve once the autoloads exist.
func _check_files() -> void:
	var files := []
	_walk("res://game", files)
	var t0 := Time.get_ticks_usec()
	var n_gd := 0
	for f: String in files:
		if f.ends_with(".gd"):
			n_gd += 1
			var s: Script = ResourceLoader.load(f)  # fresh process: the cache only holds what already compiled
			if s == null or not s.can_instantiate():
				cap.add("script failed to compile", f)
	var t1 := Time.get_ticks_usec()
	var n_res := 0
	for f: String in files:
		if f.ends_with(".tscn") or f.ends_with(".tres") or f.ends_with(".gdshader"):
			n_res += 1
			var r := ResourceLoader.load(f)
			if r == null:
				cap.add("resource failed to load", f)
			elif r is PackedScene:
				var inst := (r as PackedScene).instantiate()
				if inst == null:
					cap.add("scene failed to instantiate", f)
				else:
					_check_props(f, (r as PackedScene).get_state(), inst)
					inst.free()
	var t2 := Time.get_ticks_usec()
	report = {"scripts": n_gd, "resources": n_res, "ms": {"scripts": _ms(t1 - t0), "resources": _ms(t2 - t1)}}
	report["contract"] = _check_contract()
	_t = Time.get_ticks_usec()
	_left = frames
	if frames > 0:
		change_scene_to_file.call_deferred(ProjectSettings.get_setting("application/run/main_scene"))


func _process(_delta: float) -> bool:
	if _quitting:
		return false
	if report.is_empty():
		_check_files()
		return false
	if _left > 0:
		_left -= 1
		return false
	report["ms"]["run"] = _ms(Time.get_ticks_usec() - _t)
	report["frames"] = frames
	report["errors"] = cap.errors
	report["warnings"] = cap.warnings.size()
	var ok: bool = cap.errors.is_empty()
	print("validate: %d scripts, %d resources, %d frames: %s (scripts %d ms, resources %d ms, run %d ms)" % [
		report.scripts, report.resources, frames, "OK" if ok else "%d ERRORS" % cap.errors.size(),
		report.ms.scripts, report.ms.resources, report.ms.run])
	if not ok or not cap.warnings.is_empty():
		print(cap.report())
	print("UNIFIED_RESULT " + JSON.stringify(report))
	OS.remove_logger(cap)
	_quitting = true
	root.get_node(^"Game").quit_app(0 if ok else 1)  # stops the audio first: a live playback leaks at exit
	return false


## The view contract the scripts rely on (simulation/extension/extension.odin): the constants they read, a rock
## bulk view (rock_<v>) in the arena per rock shape variant, every bulk kind present once, and the level's scale.
func _check_contract() -> String:
	var game: Node = root.get_node(^"Game")
	if game.session == null:
		return "skipped (no game library)"
	var n: int = cap.errors.size()
	var c: Dictionary = game.constants
	for key: String in ["ship_radius", "station_radius", "gate_radius", "rock_radius", "rock_shapes", "station_hp"]:
		if not c.has(key):
			cap.add("constants() has no %s" % key, "res://game/views")
	var shapes: Array = c.get("rock_shapes", [])
	var want := ["bullet", "gem"]
	for v in shapes.size():
		want.append("rock_%d" % v)
		if (shapes[v] as Array).size() < 3:
			cap.add("rock_shapes[%d] has %d points" % [v, (shapes[v] as Array).size()], "res://game/bulk/rock_view.gd")
	var arena := (load(game.ARENA_SCENE) as PackedScene).instantiate()
	var kinds := []
	for b in arena.get_node(^"Bulk").get_children():
		kinds.append(String(b.get(&"kind")))
	kinds.sort()
	want.sort()
	if kinds != want:
		cap.add("bulk views %s, the sim's kinds %s" % [kinds, want], game.ARENA_SCENE)
	var level: Node = arena.get_node(^"Level")
	if float(level.get_meta(&"unified_px_per_m", 0.0)) <= 0.0:
		cap.add("the level root has no unified_px_per_m", "res://game/levels/arena.tscn")
	arena.free()
	return "ok" if cap.errors.size() == n else "differs"


static func _short(v: Variant) -> String:
	var s := var_to_str(v).replace("\n", " ")
	return s if s.length() <= 160 else s.left(160) + "..."


static func _ms(usec: int) -> int:
	return roundi(usec / 1000.0)


## Godot silently drops unknown properties in .tscn files; catch typos here.
func _check_props(file: String, state: SceneState, inst: Node) -> void:
	for i in state.get_node_count():
		var node := inst.get_node_or_null(state.get_node_path(i))
		if node == null:
			continue
		for p in state.get_node_property_count(i):
			var prop := state.get_node_property_name(i, p)
			if not (prop in node):
				cap.add("unknown property '%s' on %s" % [prop, state.get_node_path(i)], file)


func _walk(dir: String, out: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_walk(dir.path_join(d), out)
