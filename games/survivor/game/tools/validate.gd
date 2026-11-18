extends UnifiedValidate
## survivor's project check (the shared one, UnifiedValidate) and its view contract (simulation/extension): the
## constants the scripts read (Unified.constants: the level-up cards, the item grid with a view scene and a rest
## height per kind), and every MultiMesh kind present once in the arena.

const MULTI_KINDS: Array[String] = ["brute", "gem", "grunt", "projectile", "runner"]  # Multi, sorted
const MENU_SCRIPT := "res://game/ui/main_menu.gd"


func _check_contract() -> String:
	var constants := Unified.constants
	var cards := constants.upgrades
	if cards.size() != 3:
		log_capture.add("Unified.constants.upgrades has %d cards, the HUD shows 3" % cards.size(), "res://game/ui/hud.gd")
	for card: DataUpgradeCard in cards:
		if card.name == "" or card.detail == "":
			log_capture.add("upgrade card %s has no name or detail" % EnumUpgrade.name(card.upgrade),
				"res://game/ui/hud.gd")
	var rest_y: Dictionary = (load(MENU_SCRIPT) as Script).get_script_constant_map()["REST_Y"]
	for item: DataItemSpot in constants.items:
		var kind: String = EnumItemKind.name(item.kind)
		if not ResourceLoader.exists("res://game/views/%s.tscn" % kind) or not rest_y.has(item.kind):
			log_capture.add("item kind %s has no view scene or rest height" % kind, MENU_SCRIPT)
	var arena := (load(game.PLAY_SCENE) as PackedScene).instantiate()
	var kinds: Array[String] = []
	for b in arena.get_node(^"MultiViews").get_children():
		kinds.append((b.get_node(^"UnifiedMultiView") as UnifiedMultiView).kind)
	kinds.sort()
	if kinds != MULTI_KINDS:
		log_capture.add("MultiMesh views %s, the sim's kinds %s" % [kinds, MULTI_KINDS], game.PLAY_SCENE)
	arena.free()
	return "ok"
