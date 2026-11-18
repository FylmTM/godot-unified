extends UnifiedValidate
## friendslop's project check (the shared one, UnifiedValidate) and its contract: the level's item markers draw
## items at the sizes the sim simulates them (Unified.constants.item_sizes).

const ITEM_SCRIPT := "res://game/levels/markers/item.gd"


func _check_contract() -> String:
	var sizes := Unified.constants.item_sizes
	if sizes.is_empty():
		log_capture.add("Unified.constants.item_sizes is empty", ITEM_SCRIPT)
	var drawn: Dictionary = (load(ITEM_SCRIPT) as Script).get_script_constant_map()["SIZES"]
	for entry: DataItemSize in sizes:
		var kind := EnumItemKind.name(entry.kind)
		var size := entry.size
		if not drawn.has(kind):
			log_capture.add("item kind %s has no size in item.gd" % kind, ITEM_SCRIPT)
		elif not (drawn[kind] as Vector3).is_equal_approx(size):
			log_capture.add("item %s: item.gd draws %s, the sim simulates %s" % [kind, drawn[kind], size],
				ITEM_SCRIPT)
	return "ok"
