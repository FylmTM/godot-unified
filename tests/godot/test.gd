# Binding tests for unified:gdext, and unified:level's exporter on levels/ (src/level/SPEC.md): run headless by
# `uni test --suite godot-bindings`. Prints one line per check and "GDEXT TESTS: <n> failed"; exits with the failure
# count. After changing the exporter or levels/level_2d.tscn on purpose, rewrite levels/level_2d.level (from
# tests/godot, once this has run): godot --headless --path . -s res://.out/tools/level_export.gd -- \
#   --scene=res://levels/level_2d.tscn
extends SceneTree

var failed := 0
var fired := []

func check(name: String, ok: bool, detail = "") -> void:
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, str(detail)])
	if not ok:
		failed += 1

func _initialize() -> void:
	var t = load("res://sub.gd").new()
	root.add_child(t)
	check("class registered", ClassDB.class_exists("Tester"))
	check("parent class", t is Node3D)
	check("add (2 int args, int result)", t.add(40, 2) == 42, t.add(40, 2))
	check("greet (String in/out)", t.greet("Godot") == "hello Godot", t.greet("Godot"))
	check("scale (Vector3, float)", t.scale(Vector3(1, 2, 3), 2.0) == Vector3(2, 4, 6), t.scale(Vector3(1, 2, 3), 2.0))
	var d: Dictionary = t.make_dict()
	check("make_dict (Dictionary result)", d.get("name") == "odin" and d.get("n") == 3 and d.get("list") == [1, 2.5, "x"], d)
	check("sum_array (Array arg)", is_equal_approx(t.sum_array([1, 2.5, 3]), 6.5), t.sum_array([1, 2.5, 3]))
	check("node_name (Object arg)", t.node_name(root) == "root", t.node_name(root))
	t.value = 17
	check("property", t.value == 17 and t.get("value") == 17, t.value)
	t.fired.connect(func(n, msg, pos): fired.append([n, msg, pos]))
	t.fire(5)
	check("signal with args", fired == [[5, "fired 5", Vector3(5, 0, 0)]], fired)
	t.call_back(9)
	check("script virtual called from Odin", t.got == 9, t.got)
	var c: Callable = t.callable()
	check("Callable from Odin", c.call(20, 22) == 42, c.call(20, 22))
	check("vararg wrapper (Object.call)", t.call_add_via_vararg() == 7, t.call_add_via_vararg())
	check("Ref ownership (Image round trip)", t.image_size() == 12, t.image_size())
	check("interned StringName", t.sn_same())
	check("nested callback keeps the caller's temp data", t.nested_temp())
	# The same bindings through typed calls: GDScript ptrcalls a method whose types it knows at compile time.
	var tt: Tester = t
	var before: Vector2i = tt.call_counts()
	check("typed add", tt.add(40, 2) == 42, tt.add(40, 2))
	check("typed greet", tt.greet("Godot") == "hello Godot", tt.greet("Godot"))
	check("typed scale", tt.scale(Vector3(1, 2, 3), 2.0) == Vector3(2, 4, 6), tt.scale(Vector3(1, 2, 3), 2.0))
	var td: Dictionary = tt.make_dict()
	check("typed make_dict", td.get("name") == "odin" and td.get("list") == [1, 2.5, "x"], td)
	check("typed sum_array", is_equal_approx(tt.sum_array([1, 2.5, 3]), 6.5), tt.sum_array([1, 2.5, 3]))
	check("typed node_name", tt.node_name(root) == "root", tt.node_name(root))
	tt.value = 23
	check("typed property", tt.value == 23, tt.value)
	check("typed nested_temp", tt.nested_temp())
	var after: Vector2i = tt.call_counts()
	check("typed calls took ptrcall", after.y - before.y >= 10, [before, after])
	await process_frame
	await process_frame
	check("_ready virtual", t.is_readied())
	check("_process virtual", t.processed_count() > 0, t.processed_count())
	await process_frame
	check("dev UI draws (ImGui -> canvas items)", t.devui_items() > 0, t.devui_items())
	check("one live instance", t.instances() == 1, t.instances())
	t.queue_free()
	check_level_export()
	print("GDEXT TESTS: %d failed" % failed)
	quit(failed)


## The level exporter, installed as the tools install it into a game and run in its own Godot process: the 2D
## fixture exports to the committed file (tests/level reads it), and an unsupported shape fails naming the node.
func check_level_export() -> void:
	var repo := ProjectSettings.globalize_path("res://").path_join("../..").simplify_path()
	var src := FileAccess.get_file_as_bytes(repo.path_join("src/level/godot/level_export.gd"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.out/tools"))
	var f := FileAccess.open("res://.out/tools/level_export.gd", FileAccess.WRITE)
	f.store_buffer(src)
	f.close()
	var out := []
	var code := OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"-s", "res://.out/tools/level_export.gd", "--", "--check", "--scene=res://levels/level_2d.tscn",
			"--scene=res://levels/bad_2d.tscn"], out, true)
	var data = null
	for line in "".join(out).split("\n"):
		if line.begins_with("UNIFIED_RESULT "):
			data = JSON.parse_string(line.trim_prefix("UNIFIED_RESULT "))
	check("level export ran", data is Dictionary and code == 1, code)
	if not data is Dictionary:
		return
	var levels: Array = data["levels"]
	check("2D level exports to the committed file", levels.size() == 1 and levels[0]["scene"] ==
			"res://levels/level_2d.tscn" and not levels[0]["changed"], levels)
	var errs: Array = data["errors"]
	check("unsupported 2D shape fails with the node's name", errs.size() == 1 and errs[0].begins_with("Rail/Edge: ")
			and "SegmentShape2D" in errs[0], errs)
