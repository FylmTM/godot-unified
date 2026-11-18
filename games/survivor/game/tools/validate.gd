extends UnifiedValidate
## survivor's project check (the library's UnifiedValidate) and what its scripts assume: a HUD button per level-up
## card (Unified.constants), and the level's items placed as their own kind's view scene (an instance whose `kind`
## was changed would play as one kind and look like another).

const HUD_SCENE := "res://game/ui/hud.tscn"
const LEVEL_SCENE := "res://game/levels/arena.tscn"


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
	var level := (load(LEVEL_SCENE) as PackedScene).instantiate()
	for marker: Node in Unified.level_markers(level):
		var item := marker as SurvivorPropView
		if item != null and item.scene_file_path != "res://game/views/%s.tscn" % item.kind:
			log_capture.add("item %s is a %s with kind \"%s\"" % [item.name, item.scene_file_path, item.kind],
				LEVEL_SCENE)
	level.free()
	return "ok"
