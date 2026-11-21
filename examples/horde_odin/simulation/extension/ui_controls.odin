// The HUD and the level-up cards as Godot Controls made and updated from Odin (`-- --ui controls`): Godot lays them
// out, themes them and draws text; Odin polls the buttons and sends the pick. The library has no Odin API for
// Controls, so this file reaches into unified:gdext itself (the one example file that does): what such an API would
// have to cover is what this file does by hand.
package horde_odin_extension

import "core:fmt"
import gd "unified:gdext"
import "unified:godot"

import g "../../../horde/simulation/horde"

Controls_Ui :: struct {
	made:      bool,
	status:    gd.Label,
	fps:       gd.Label,
	level:     gd.Label,
	hp_fill:   gd.PanelContainer,
	xp_fill:   gd.PanelContainer,
	cards:     gd.HBoxContainer,
	buttons:   [3]gd.Button,
	held:      [3]bool, // each button was held down last frame (a click is its release over it)
	banner:    gd.Label,
	shown:     [4]string, // the texts last set (status, fps, level, banner): set again only when they change
	offers:    [3]g.Upgrade,
	pending:   bool,
	keys_prev: [3]bool,
}

controls_ui: Controls_Ui

ui_controls :: proc(d: ^Draw) {
	ui := &controls_ui
	if !ui.made do controls_make(ui)
	hud := hud_of(d)
	fps := fps_update(d)
	set_text(
		ui.status,
		&ui.shown[0],
		fmt.tprintf(
			"Wave %d   %d:%02d   enemies %d   kills %d",
			hud.wave + 1,
			int(hud.time_s) / 60,
			int(hud.time_s) % 60,
			hud.enemies,
			hud.kills,
		),
	)
	set_text(ui.fps, &ui.shown[1], fmt.tprintf("%.0f fps  %.1f ms", fps, d.dt * 1000))
	set_text(ui.level, &ui.shown[2], fmt.tprintf("Level %d", hud.level))
	gd.Control_set_size(as_control(ui.hp_fill), {260 * clamp(f32(hud.hp) / f32(max(hud.hp_max, 1)), 0, 1), 14})
	gd.Control_set_size(as_control(ui.xp_fill), {260 * clamp(f32(hud.xp) / f32(max(hud.xp_next, 1)), 0, 1), 14})
	banner := hud.over ? fmt.tprintf("Overrun at wave %d, %d kills", hud.wave + 1, hud.kills) : ""
	set_text(ui.banner, &ui.shown[3], banner)
	if hud.pending != ui.pending || hud.offers != ui.offers {
		ui.pending, ui.offers = hud.pending, hud.offers
		gd.CanvasItem_set_visible(as_control(ui.cards), hud.pending)
		for button, i in ui.buttons do gd.Button_set_text(button, fmt.tprintf("%d\n%s", i + 1, UPGRADE_TEXT[hud.offers[i]]))
	}
	if !hud.pending do return
	for button, i in ui.buttons {
		base := gd.cast_to(gd.BaseButton, gd.Object{button.ptr})
		held := gd.BaseButton_is_pressed(base)
		clicked := ui.held[i] && !held && gd.BaseButton_is_hovered(base)
		ui.held[i] = held
		key := godot.key_down(KEY_1 + i)
		pressed_key := key && !ui.keys_prev[i]
		ui.keys_prev[i] = key
		if clicked || pressed_key do godot.send(d, g.Command_Pick{hud.offers[i]})
	}
}

controls_make :: proc(ui: ^Controls_Ui) {
	tree := gd.cast_to(gd.SceneTree, gd.Object{gd.Engine_get_main_loop(gd.Engine_singleton()).ptr})
	scene := gd.SceneTree_get_current_scene(tree)
	layer := gd.CanvasLayer_new()
	gd.Node_add_child(scene, as_node(layer))
	top := gd.VBoxContainer_new()
	gd.Control_set_position(as_control(top), {16, 12})
	gd.Node_add_child(as_node(layer), as_node(top))
	ui.status = label(top, 20)
	ui.fps = label(top, 14)
	ui.level = label(top, 16)
	ui.hp_fill = progress(top, {0.3, 0.9, 0.4, 1})
	ui.xp_fill = progress(top, {0.3, 0.75, 1.0, 1})
	ui.cards = gd.HBoxContainer_new()
	size := godot.screen_size()
	gd.Control_set_position(as_control(ui.cards), {size.x / 2 - (3 * CARD_SIZE.x + 2 * CARD_GAP) / 2, size.y - 170})
	gd.Control_add_theme_constant_override(as_control(ui.cards), "separation", int(CARD_GAP))
	gd.CanvasItem_set_visible(as_control(ui.cards), false)
	gd.Node_add_child(as_node(layer), as_node(ui.cards))
	for &button in ui.buttons {
		button = gd.Button_new()
		gd.Control_set_custom_minimum_size(as_control(button), {CARD_SIZE.x, CARD_SIZE.y})
		gd.Control_add_theme_font_size_override(as_control(button), "font_size", 20)
		gd.Node_add_child(as_node(ui.cards), as_node(button))
	}
	ui.banner = label(layer, 40)
	gd.Control_set_position(as_control(ui.banner), {size.x / 2 - 280, size.y / 2 - 30})
	ui.made = true
}

// A label under `parent`, `font_size` points, outlined black.
label :: proc(parent: $T, font_size: int) -> gd.Label {
	node := gd.Label_new()
	control := as_control(node)
	gd.Control_add_theme_font_size_override(control, "font_size", font_size)
	gd.Control_add_theme_constant_override(control, "outline_size", 4)
	gd.Control_add_theme_color_override(control, "font_outline_color", {0, 0, 0, 1})
	gd.Control_set_mouse_filter(control, .MOUSE_FILTER_IGNORE)
	gd.Node_add_child(as_node(parent), as_node(node))
	return node
}

// A bar under `parent` (260 × 14): a dark back and a fill whose width the caller sets.
progress :: proc(parent: $T, color: godot.Color) -> gd.PanelContainer {
	holder := gd.Control_new()
	gd.Control_set_custom_minimum_size(holder, {260, 14})
	gd.Node_add_child(as_node(parent), as_node(holder))
	back := panel({0, 0, 0, 0.5})
	gd.Control_set_size(as_control(back), {260, 14})
	gd.Node_add_child(as_node(holder), as_node(back))
	fill := panel(color)
	gd.Node_add_child(as_node(holder), as_node(fill))
	return fill
}

// A flat panel of one colour.
panel :: proc(color: godot.Color) -> gd.PanelContainer {
	node := gd.PanelContainer_new()
	style := gd.StyleBoxFlat_new()
	gd.StyleBoxFlat_set_bg_color(style, transmute(gd.Color)color)
	gd.Control_add_theme_stylebox_override(as_control(node), "panel", gd.cast_to(gd.StyleBox, gd.Object{style.ptr}))
	gd.unref(style) // the panel holds it now
	gd.Control_set_mouse_filter(as_control(node), .MOUSE_FILTER_IGNORE)
	return node
}

// A label's text, set only when it changed (a set makes a Godot String and a redraw).
set_text :: proc(node: gd.Label, shown: ^string, text: string) {
	if text == shown^ do return
	delete(shown^)
	shown^ = fmt.aprint(text)
	gd.Label_set_text(node, text)
}

as_node :: proc(object: $T) -> gd.Node {
	return gd.cast_to(gd.Node, gd.Object{object.ptr})
}

as_control :: proc(object: $T) -> gd.Control {
	return gd.cast_to(gd.Control, gd.Object{object.ptr})
}
