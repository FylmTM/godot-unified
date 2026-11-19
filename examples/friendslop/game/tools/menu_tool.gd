class_name MenuTool
extends UnifiedTool
## The base of the tool scripts that drive the game's own menus (ui_walk, tour): the main menu, its buttons by
## unique name, and the player's settings.


## The main menu's UI (the MainMenu scene's `Menu`), when the menu is the current scene.
func menu() -> CanvasLayer:
	return current_scene.get_node_or_null(^"Menu") as CanvasLayer if scene_is("MainMenu") else null


## Clicks the menu's button or field by its unique name (Single, Host, Join, JoinAddress, HostLan, CodeJoin, ...).
func click_menu(unique_name: String) -> void:
	await click(find(menu(), "%" + unique_name) as Control)


## A player setting (the Settings autoload's value).
func setting(key: StringName) -> Variant:
	return root.get_node(^"Settings").get(key)


## The local player's row of the HUD data (null until they hold a slot).
func local_row() -> DataHudPlayer:
	if session == null:
		return null
	var slot := session.get_player_slot(session.local_player)
	return Unified.data.hud.players[slot] as DataHudPlayer if slot >= 0 else null
