extends UnifiedValidate
## friendslop's project check (the library's, UnifiedValidate) and its contract: the level's item markers draw
## items at the sizes the sim simulates them (constants().item_sizes).

const ITEM_SCRIPT := "res://game/levels/markers/item.gd"


func _check_contract() -> String:
	var sizes: Dictionary = game.constants.get("item_sizes", {})
	var drawn: Dictionary = (load(ITEM_SCRIPT) as Script).get_script_constant_map()["SIZES"]
	for kind: String in sizes:
		if not drawn.has(kind):
			log_capture.add("item kind %s has no size in item.gd" % kind, ITEM_SCRIPT)
		elif not (drawn[kind] as Vector3).is_equal_approx(sizes[kind]):
			log_capture.add("item %s: item.gd draws %s, the sim simulates %s" % [kind, drawn[kind], sizes[kind]],
				ITEM_SCRIPT)
	return "ok"
