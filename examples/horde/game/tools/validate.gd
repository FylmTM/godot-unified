extends UnifiedValidate
## horde's project check (the library's UnifiedValidate) and what its scripts assume: a HUD button per level-up offer,
## and a level-up card for every upgrade, in EnumUpgrade's order (the HUD looks a card up by its offer's value).

const HUD_SCENE := "res://game/ui/hud.tscn"
const OFFERS := 3  # upgrade_offers deals three per level-up


func _play_scene() -> String:
	return "res://game/arena/arena.tscn"


func _check_contract() -> String:
	var hud := (load(HUD_SCENE) as PackedScene).instantiate()
	var buttons := hud.get_node(^"%Options").get_child_count()
	hud.free()
	if buttons != OFFERS:
		log_capture.add("%d level-up offers, the HUD has %d buttons" % [OFFERS, buttons], HUD_SCENE)
	var cards := Unified.constants.upgrades
	var upgrades: Array = ClassDB.class_call_static(&"EnumUpgrade", &"names")
	if cards.size() != upgrades.size():
		log_capture.add("%d level-up cards for %d upgrades" % [cards.size(), upgrades.size()], HUD_SCENE)
	for i in cards.size():
		var card: DataUpgradeCard = cards[i]
		if card.upgrade != i:
			log_capture.add("level-up card %d is for %s" % [i, EnumUpgrade.name(card.upgrade)], HUD_SCENE)
		if card.name == "" or card.detail == "":
			log_capture.add("upgrade card %s has no name or detail" % EnumUpgrade.name(card.upgrade), HUD_SCENE)
	return "ok"
