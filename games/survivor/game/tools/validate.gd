extends UnifiedValidate
## survivor's project check (the shared one, UnifiedValidate) and its view contract (simulation/extension): the
## constants the scripts read (the level-up cards with their Pick ids, the item grid with a view scene and a rest
## height per kind), and every MultiMesh kind present once in the arena.

const MULTI_KINDS: Array[String] = ["brute", "gem", "grunt", "projectile", "runner"]  # Multi, sorted
const MENU_SCRIPT := "res://game/ui/main_menu.gd"


func _check_contract() -> String:
	var c: Dictionary = game.constants
	for key: String in ["over_hold_s", "arena_half", "start_radius", "upgrades", "items"]:
		if not c.has(key):
			log_capture.add("constants() has no %s" % key, "res://game")
	var upgrades: Array = c.get("upgrades", [])
	if upgrades.size() != 3:
		log_capture.add("constants().upgrades has %d cards, the HUD shows 3" % upgrades.size(), "res://game/ui/hud.gd")
	for u: Dictionary in upgrades:
		for key: String in ["id", "name", "detail"]:
			if not u.has(key):
				log_capture.add("an upgrade card has no %s" % key, "res://game/ui/hud.gd")
	var rest_y: Dictionary = (load(MENU_SCRIPT) as Script).get_script_constant_map()["REST_Y"]
	for item: Dictionary in c.get("items", []):
		var kind: String = item.get("kind", "")
		if not ResourceLoader.exists("res://game/views/%s.tscn" % kind) or not rest_y.has(kind):
			log_capture.add("item kind %s has no view scene or rest height" % kind, MENU_SCRIPT)
	var arena := (load(game.PLAY_SCENE) as PackedScene).instantiate()
	var kinds: Array[String] = []
	for b in arena.get_node(^"Bulk").get_children():
		kinds.append((b.get_node(^"UnifiedMultiView") as UnifiedMultiView).kind)
	kinds.sort()
	if kinds != MULTI_KINDS:
		log_capture.add("MultiMesh views %s, the sim's kinds %s" % [kinds, MULTI_KINDS], game.PLAY_SCENE)
	arena.free()
	return "ok"
