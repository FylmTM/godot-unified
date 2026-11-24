# Unified.level_markers against unified's level exporter: run headless by `uni test --suite godot-bindings`. The
# exporter is mirrored here (res://unified/tools_godot/) and this script extends it, so its own `_collect` gives the
# order the .level file holds the markers in; Unified.level_markers (Odin, src/godot/level_markers.odin) must return the
# same nodes in the same order, for a level whose markers declare their kind each supported way, nested.
# Prints one line per check and "MARKERS TESTS: <n> failed"; exits with the failure count.
extends "res://unified/tools_godot/level_export.gd"

var failed := 0


func check(name: String, ok: bool, detail: Variant = "") -> void:
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, str(detail)])
	if not ok:
		failed += 1


func _initialize() -> void:
	var level := _level()
	_root = level
	var bodies: Array[Node] = []
	var exported: Array[Node] = []
	_collect(level, bodies, exported)
	var got: Array[Node] = Unified.level_markers(level)
	check("the exporter takes the fixture", errors.is_empty() and bodies.size() == 1, errors)
	check("Unified.level_markers: the exporter's markers in its order", got == exported, [_names(got), _names(exported)])
	check("every way to declare a kind, nested, and none of the rest", _names(got) == ["Spawn", "Pad", "Crate", "Bell",
			"Key", "Both"], _names(got))
	check("no root: none", Unified.level_markers(null).is_empty())
	level.free()
	print("MARKERS TESTS: %d failed" % failed)
	quit(failed)


## Level ─ Ground (a body) ─ Spawn (metadata) ─ Decor ─ Pad (a property)
##       ─ Group ─ Crate (a const) ─ Bell (a property)
##               ─ Plain (a script without a kind) ─ Key (a const)
##       ─ Empty (metadata "": no marker) ─ Off (a property "": no marker) ─ Both (a const and metadata)
func _level() -> Node3D:
	var with_const := _script("const UNIFIED_KIND := \"item\"")
	var with_property := _script("var unified_kind := \"bell\"")
	var level := _node(null, "Level")
	_node(level, "Ground", StaticBody3D.new())
	var spawn := _node(level, "Spawn")
	spawn.set_meta(&"unified_kind", "spawn")
	_node(_node(spawn, "Decor"), "Pad", null, with_property).set(&"unified_kind", "pad")
	var group := _node(level, "Group")
	_node(_node(group, "Crate", null, with_const), "Bell", null, with_property)
	_node(_node(group, "Plain", null, _script("var size := 1.0")), "Key", null, with_const)
	_node(level, "Empty").set_meta(&"unified_kind", "")
	_node(level, "Off", null, with_property).set(&"unified_kind", "")
	_node(level, "Both", null, with_const).set_meta(&"unified_kind", "spawn")
	return level


func _node(parent: Node, node_name: String, node: Node3D = null, script: GDScript = null) -> Node3D:
	var n := node if node != null else Node3D.new()
	n.name = node_name
	if script != null:
		n.set_script(script)
	if parent != null:
		parent.add_child(n)
	return n


func _script(body: String) -> GDScript:
	var script := GDScript.new()
	script.source_code = "extends Node3D\n%s\n" % body
	script.reload()
	return script


func _names(nodes: Array[Node]) -> Array[String]:
	var names: Array[String] = []
	for n in nodes:
		names.append(str(n.name))
	return names
