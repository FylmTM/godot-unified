extends Node
## The demo games' HUD view: the root script of a game's `hud` view scene (a Node with a UnifiedView marker of kind
## `hud`). The host sets each field of the game's HUD data as a property of this node when it changes; this script
## keeps them in `Game.hud`, where the menus, the HUD panels and the tools read them (`Game.hud.get("score", 0)`).
## Any field name is a property: reads return the last value set (0 before the first frame).


func _set(property: StringName, value: Variant) -> bool:
	Game.hud[property] = value
	return true


func _get(property: StringName) -> Variant:
	return Game.hud.get(property, 0)


func _exit_tree() -> void:
	Game.hud.clear()
