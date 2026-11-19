class_name UnifiedValidate
extends UnifiedTool
## The headless project check, no editor (the godot suite's `validate` step):
##   godot --headless -d --path examples/<game> -s <this script> -- --no-settings [--frames=N]
## 1. compiles every script of the project (`-d` makes Godot print GDScript warnings; uni fails on them): all of
## res:// but hidden directories, those with a .gdignore and res://addons/unified (unified's own, checked by its
## suites), 2. loads and instantiates every scene and resource there (missing dependencies, and the unknown
## properties Godot silently drops), 3. checks the game's own contract with its sim (`_check_contract()`, in a game's
## game/tools/validate.gd that extends this), 4. runs the main scene for N frames (default 30) to catch runtime errors.

## Also: no preload() in the scripts the play scene loads (`_play_scene()`: the main scene unless a game's validate says
## otherwise), the play scene draws every MultiMesh kind of the game (EnumMultiView) once, and the project keeps
## GDScript strictly typed. unified's library tooling (src/godot/README.md, Library tooling), mirrored into every game
## as res://addons/unified/.

## Left out of the walk besides hidden and .gdignore'd directories: unified's tool scripts.
const SKIP_DIRS: Array[String] = ["res://addons/unified"]


func _run() -> void:
	var files: Array[String] = []
	_walk("res://", files)
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
	_check_multi_views()
	_check_strict_typing()
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


## The scene the game plays in (default: the main scene). A game whose menu is its main scene returns its play scene
## here (its game/tools/validate.gd), so the checks below cover it.
func _play_scene() -> String:
	return ProjectSettings.get_setting("application/run/main_scene")


## The scripts the play scene loads (its scenes' scripts, recursively) use no preload(): a play scene loaded on a
## worker thread (a menu that loads it in the background) leaks, in Godot 4.7, a resource a script first preloads
## there at exit. They load() what they need when they need it.
func _check_play_scene_preloads() -> void:
	var seen := {}
	var todo: Array[String] = [_play_scene()]
	while not todo.is_empty():
		var path: String = todo.pop_back()
		if seen.has(path):
			continue
		seen[path] = true
		if path.ends_with(".gd") and FileAccess.get_file_as_string(path).contains("preload("):
			log_capture.add("a script of the play scene preloads (load() it instead: it loads on a thread)", path)
		for dep in ResourceLoader.get_dependencies(path):
			todo.append(dep.get_slice("::", 2) if dep.contains("::") else dep)


## The project makes untyped and unsafe GDScript an error (every unified game does; a copied project.godot must not
## lose it).
const STRICT_WARNINGS: Array[String] = ["untyped_declaration", "unsafe_property_access", "unsafe_method_access",
	"unsafe_cast", "unsafe_call_argument"]


func _check_strict_typing() -> void:
	for warning in STRICT_WARNINGS:
		var setting := "debug/gdscript/warnings/" + warning
		if int(ProjectSettings.get_setting(setting, 0)) != 2:
			log_capture.add("%s is not an error (2) in project.godot: unified games are strictly typed" % setting,
				"res://project.godot")


## Every MultiView member of the game (EnumMultiView) has one UnifiedMultiView in the play scene, under a
## MultiMeshInstance: a kind the sim pushes with no marker would draw nothing, one with two would draw twice.
func _check_multi_views() -> void:
	if not ClassDB.class_exists(&"EnumMultiView"):
		return  # no MultiMesh views
	var play_scene := _play_scene()
	var scene := load(play_scene) as PackedScene
	if scene == null:
		return  # reported with the scenes
	var root_node := scene.instantiate()
	var found := {}
	for marker: Node in root_node.find_children("*", "UnifiedMultiView", true, false):
		var kind := (marker as UnifiedMultiView).kind
		found[kind] = int(found.get(kind, 0)) + 1
	root_node.free()
	for member: String in ClassDB.class_get_integer_constant_list(&"EnumMultiView", true):
		var kind := member.to_lower()
		var count: int = found.get(kind, 0)
		if count != 1:
			log_capture.add("MultiMesh view %s: %d UnifiedMultiView markers in the play scene, want 1" % [kind, count],
				play_scene)


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
	if not DirAccess.dir_exists_absolute(dir) or dir in SKIP_DIRS or FileAccess.file_exists(dir.path_join(".gdignore")):
		return
	for f in DirAccess.get_files_at(dir):
		out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with("."):
			_walk(dir.path_join(d), out)
