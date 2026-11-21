// The HUD and the level-up cards, immediate mode: drawn every frame on a screen layer, clicks and keys read in Odin, a
// pick sent as a command from here. No node, no script.
package horde_odin_extension

import "core:fmt"
import "unified:godot"

import g "../../../horde/simulation/horde"

CARD_SIZE :: [2]f32{200, 110}
CARD_GAP :: f32(16)
KEY_1 :: 49 // Godot's Key for the 1 key

Immediate_Ui :: struct {
	layer:     godot.Layer,
	made:      bool,
	keys_prev: [3]bool,
}

immediate_ui: Immediate_Ui

ui_immediate :: proc(d: ^Draw) {
	ui := &immediate_ui
	if !ui.made {
		ui.layer = godot.layer(10, screen = true)
		ui.made = true
	}
	hud := hud_of(d)
	fps := fps_update(d)
	layer := ui.layer
	shadow_text(
		layer,
		{16, 34},
		fmt.tprintf(
			"Wave %d   %d:%02d   enemies %d   kills %d",
			hud.wave + 1,
			int(hud.time_s) / 60,
			int(hud.time_s) % 60,
			hud.enemies,
			hud.kills,
		),
		20,
	)
	shadow_text(layer, {16, 56}, fmt.tprintf("%.0f fps  %.1f ms", fps, d.dt * 1000), 14)
	shadow_text(layer, {16, 80}, fmt.tprintf("Level %d", hud.level), 16)
	bar(layer, {16, 90}, {260, 14}, f32(hud.hp) / f32(max(hud.hp_max, 1)), {0.3, 0.9, 0.4, 1})
	bar(layer, {16, 108}, {260, 14}, f32(hud.xp) / f32(max(hud.xp_next, 1)), {0.3, 0.75, 1.0, 1})
	if hud.over {
		text := fmt.tprintf("Overrun at wave %d, %d kills", hud.wave + 1, hud.kills)
		size := godot.screen_size()
		shadow_text(layer, {size.x / 2 - godot.text_width(text, 40) / 2, size.y / 2}, text, 40)
	}
	if !hud.pending do return
	size := godot.screen_size()
	left := size.x / 2 - (3 * CARD_SIZE.x + 2 * CARD_GAP) / 2
	top := size.y - 170
	mouse := godot.mouse_screen()
	for upgrade, i in hud.offers {
		pos := [2]f32{left + f32(i) * (CARD_SIZE.x + CARD_GAP), top}
		hover := mouse.x >= pos.x && mouse.x < pos.x + CARD_SIZE.x && mouse.y >= pos.y && mouse.y < pos.y + CARD_SIZE.y
		godot.rect(
			layer,
			pos,
			CARD_SIZE,
			hover ? godot.Color{0.3, 0.32, 0.4, 0.95} : godot.Color{0.18, 0.19, 0.24, 0.95},
		)
		godot.text(layer, pos + {12, 34}, fmt.tprintf("%d", i + 1), 20, {1, 0.85, 0.3, 1})
		godot.text(layer, pos + {12, 70}, UPGRADE_TEXT[upgrade], 20, {1, 1, 1, 1})
		key := godot.key_down(KEY_1 + i)
		pressed_key := key && !ui.keys_prev[i]
		ui.keys_prev[i] = key
		if (hover && godot.mouse_pressed(1)) || pressed_key do godot.send(d, g.Command_Pick{upgrade})
	}
}

shadow_text :: proc(layer: godot.Layer, pos: [2]f32, text: string, size: int) {
	godot.text(layer, pos + {2, 2}, text, size, {0, 0, 0, 1})
	godot.text(layer, pos, text, size, {1, 1, 1, 1})
}

bar :: proc(layer: godot.Layer, pos, size: [2]f32, fill: f32, color: godot.Color) {
	godot.rect(layer, pos, size, {0, 0, 0, 0.5})
	godot.rect(layer, pos, {size.x * clamp(fill, 0, 1), size.y}, color)
}
