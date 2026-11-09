extends SceneTree
## Headless project check, no editor:
##   godot --headless -d --path games/survivor -s res://game/tools/validate.gd -- --no-settings [--frames=N]
## 1. compiles every .gd under res://game (`-d` makes Godot print GDScript warnings; tools/game.py fails on them),
## 2. loads and instantiates every .tscn/.tres (missing deps, and the unknown properties Godot silently drops),
## 3. with the game library loaded, checks the mock session against the native one (constants() and the idle
## hud() must be equal, so the mock's copy of the sim's numbers can't drift), 4. runs the main scene for N frames
## (default 30) to catch runtime errors. Prints a summary and one `VALIDATE_JSON {...}` line; exits 1 on any error.

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
	report["mock_contract"] = _check_mock()
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
	print("VALIDATE_JSON " + JSON.stringify(report))
	OS.remove_logger(cap)
	_quitting = true
	root.get_node(^"Game").quit_app(0 if ok else 1)  # stops the audio first: a live playback leaks at exit
	return false


## The mock must report what the native session reports: every constants() key, and hud() before any session.
## Returns "ok", or "skipped" without the game library.
func _check_mock() -> String:
	var game: Node = root.get_node(^"Game")
	if game.is_mock:
		return "skipped (mock session)"
	var mock: Node = load(game.MOCK_SESSION).new()
	var native: Node = game.session
	var n: int = cap.errors.size()
	_compare("constants()", mock.constants(), native.constants())
	_compare("hud() before a session", mock.hud(), native.hud())
	mock.free()
	return "ok" if cap.errors.size() == n else "differs"


func _compare(what: String, mock: Dictionary, native: Dictionary) -> void:
	const AT := "res://game/session/mock_session.gd"
	for key: String in native:
		if not mock.has(key):
			cap.add("mock %s lacks key %s" % [what, key], AT)
		elif var_to_str(mock[key]) != var_to_str(native[key]):
			cap.add("mock %s[%s] differs from the native session: %s vs %s" % [what, key, _short(mock[key]), _short(native[key])], AT)
	for key: String in mock:
		if not native.has(key):
			cap.add("mock %s has key %s the native session lacks" % [what, key], AT)


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
