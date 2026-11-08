# Binding tests for unified:gdext: run headless by `python tools/dev.py godot-test`. Prints one line per
# check and "GDEXT TESTS: <n> failed"; exits with the failure count.
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
	await process_frame
	await process_frame
	check("_ready virtual", t.is_readied())
	check("_process virtual", t.processed_count() > 0, t.processed_count())
	check("one live instance", t.instances() == 1, t.instances())
	t.queue_free()
	print("GDEXT TESTS: %d failed" % failed)
	quit(failed)
