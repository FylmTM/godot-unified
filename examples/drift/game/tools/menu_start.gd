extends RefCounted
## Starting a session through drift's main menu, as a player does, with real clicks and key events: hosting online
## or on the LAN, joining a lobby code or an address. The walk (ui_walk.gd) and `uni coop drift --menus` (coop.gd's
## _start_host and _start_join) both start this way, so the godot suite's walk drives the menus a menu-driven coop
## goes through. Static, on the tool running it: a tool script never names a script that uses an autoload.


## Hosts through the menu: Host online, or with a `port` (LAN) the address panel's Host on LAN, on that port (the
## Game's lan_port, which the menu's button names).
static func host(tool: UnifiedTool, port: int) -> void:
	if port > 0:
		tool.game.set(&"lan_port", port)
	await open(tool)
	if port > 0:
		await click(tool, "JoinAddress")
		await click(tool, "HostLan")
	else:
		await click(tool, "Host")


## Joins `code` through the menu: an address (host:port) in the address panel, else a lobby code in the code panel,
## typed with key events into its field, then the panel's join button.
static func join(tool: UnifiedTool, code: String) -> void:
	await open(tool)
	var address := code.contains(":")
	await click(tool, "JoinAddress" if address else "Join")
	var field := tool.find(menu(tool), "%AddressEdit" if address else "%CodeEdit") as LineEdit
	if tool.failed():
		return
	await tool.click(field)
	field.clear()  # the code panel prefills a code from the clipboard (a windowed run's is the real one)
	await tool.type_text(code)
	await tool.frames(2)  # LineEdit emits text_changed deferred
	await click(tool, "AddressConnect" if address else "CodeJoin")


## The main menu on screen: loaded as the main scene when there is no scene (a tool run starts with none), else
## waited for (the app goes back to it when a session ends).
static func open(tool: UnifiedTool) -> void:
	if tool.current_scene == null:
		tool.change_scene_to_file(str(ProjectSettings.get_setting("application/run/main_scene")))
	await tool.wait_for_scene("MainMenu", 10.0)
	await tool.frames(3)


## The main menu's UI (the MainMenu scene's `Menu`), or null when another scene is on screen.
static func menu(tool: UnifiedTool) -> CanvasLayer:
	return tool.current_scene.get_node_or_null(^"Menu") as CanvasLayer if tool.scene_is("MainMenu") else null


## Clicks the menu's button or field by its unique name (Host, Join, JoinAddress, HostLan, CodeJoin, ...).
static func click(tool: UnifiedTool, unique_name: String) -> void:
	await tool.click(tool.find(menu(tool), "%" + unique_name) as Control)
