extends UnifiedValidate
## survivor's project check (the library's UnifiedValidate) and what its scripts assume of the constants
## (Unified.constants): a HUD button per level-up card, and a view scene per item kind (the menu backdrop's).

const HUD_SCENE := "res://game/ui/hud.tscn"


func _play_scene() -> String:
	return "res://game/arena/arena.tscn"


func _check_contract() -> String:
	var constants := Unified.constants
	var hud := (load(HUD_SCENE) as PackedScene).instantiate()
	var buttons := hud.get_node(^"%Options").get_child_count()
	hud.free()
	if constants.upgrades.size() != buttons:
		log_capture.add("%d level-up cards, the HUD has %d buttons" % [constants.upgrades.size(), buttons], HUD_SCENE)
	for card: DataUpgradeCard in constants.upgrades:
		if card.name == "" or card.detail == "":
			log_capture.add("upgrade card %s has no name or detail" % EnumUpgrade.name(card.upgrade), HUD_SCENE)
	for item: DataItemSpot in constants.items:
		var scene := "res://game/views/%s.tscn" % EnumItemKind.name(item.kind)
		if not ResourceLoader.exists(scene):
			log_capture.add("item kind %s has no view scene" % EnumItemKind.name(item.kind), "res://game/ui/main_menu.gd")
	return "ok"
