extends UnifiedCoop
## drift's co-op play (the flow is the library's, UnifiedCoop): the host starts the match from the lobby (the
## `start` command) and both fly in it for a while.
##
## With `uni coop drift --menus` neither side starts from session flags: each goes through the game's main menu
## (MenuStart: Host online, or Host on LAN from the address panel; the joiner types the host's code or address), so
## the menu-driven host and join are proved across two processes. With --rejoin the joiner's second join goes
## through the menu again, from the menu its app returned to when it left.

const MenuStart := preload("res://game/tools/menu_start.gd")


## Hosts through the main menu, on `port` (LAN) or online.
func _start_host(port: int) -> void:
	await MenuStart.host(self, port)
	await wait_for_scene("Arena", 10.0)
	step("hosted through the menus (%s)" % ("port %d" % port if port > 0 else "online"))


## Joins the host's `code` (a lobby code, or an address) through the main menu.
func _start_join(code: String) -> void:
	await MenuStart.join(self, code)
	await wait_for_scene("Arena", 30.0)
	step("joined through the menus (%s)" % code)


func _host_play() -> void:
	await wait_for_scene("Arena", 10.0)
	await wait_for(func() -> bool: return Unified.data.hud.phase == EnumPhase.LOBBY, 10.0, "the lobby")
	await click(current_scene.get_node(^"HUD").start_button)
	await wait_for(_playing, 5.0, "the match after Start")
	step("match started")
	await seconds(4.0)
	await shot("c03_coop_match")
	step("co-op match: wave %d" % Unified.data.hud.wave)


func _join_play() -> void:
	await wait_for(_playing, 40.0, "the host starts the match")
	step("match started (seen by the joiner)")


func _playing() -> bool:
	return Unified.data.hud.phase == EnumPhase.MATCH


## The host left: the friend lands on the main menu, which says why.
func _host_left() -> void:
	await wait_for_scene("MainMenu", 10.0)
	var error := find(current_scene, ^"Menu/%ErrorMessage") as Label
	if failed():
		return
	step("on the menu: %s" % (error.text if error.is_visible_in_tree() else "(no error shown)"))
