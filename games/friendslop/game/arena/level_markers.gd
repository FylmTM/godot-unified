class_name LevelMarkers
## The level's markers in the order the exporter writes them (src/godot/tools/level_export.gd): depth-first,
## parents before children, every node that declares a unified kind. Marker index i here = marker i in the
## level file, so a sim view with entity i + 1 finds its marker's node (and adopts its visuals).


static func collect(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	_walk(root, out)
	return out


static func kind_of(n: Node) -> String:
	var s: Script = n.get_script()
	if s != null and s.get_script_constant_map().has("UNIFIED_KIND"):
		return str(s.get_script_constant_map()["UNIFIED_KIND"])
	if "unified_kind" in n:
		return str(n.get("unified_kind"))
	if n.has_meta("unified_kind"):
		return str(n.get_meta("unified_kind"))
	return ""


static func _walk(n: Node, out: Array[Node]) -> void:
	if kind_of(n) != "":
		out.append(n)
	for c in n.get_children():
		_walk(c, out)
