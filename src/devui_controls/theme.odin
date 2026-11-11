// The dev UI's own theme. A game may change Godot's default theme in place (survivor merges its UI theme into
// it), and theme lookup ends there, so every item the dev UI's controls use is set here explicitly: nothing of the
// game's look leaks in. A real version would be a .tres in the library.
package devui_controls

import gd "unified:gdext"

@(private)
FONT_SIZE :: 14

@(private)
dev_theme :: proc() -> gd.Ref(gd.Theme) {
	t := gd.Theme_new()
	font := gd.ThemeDB_get_fallback_font(gd.ThemeDB_singleton())
	defer gd.unref(font)
	gd.Theme_set_default_font(t, font)
	gd.Theme_set_default_font_size(t, FONT_SIZE)

	BG :: gd.Color{0.11, 0.12, 0.15, 0.94}
	DARK :: gd.Color{0.08, 0.09, 0.11, 1}
	FRAME :: gd.Color{0.2, 0.22, 0.27, 1}
	HOVER :: gd.Color{0.27, 0.3, 0.37, 1}
	ON :: gd.Color{0.26, 0.42, 0.66, 1}
	TEXT :: gd.Color{0.9, 0.92, 0.95, 1}

	flat(t, "panel", "PanelContainer", BG, 4, 6)
	flat(t, "panel", "Panel", BG, 4, 6)
	flat(t, "panel", "Tree", DARK, 2, 4)
	flat(t, "normal", "TextEdit", DARK, 2, 4)
	flat(t, "focus", "TextEdit", {}, 2, 4, ON)
	flat(t, "normal", "Button", FRAME, 3, 4)
	flat(t, "disabled", "Button", FRAME, 3, 4)
	flat(t, "hover", "Button", HOVER, 3, 4)
	flat(t, "pressed", "Button", ON, 3, 4)
	flat(t, "hover_pressed", "Button", ON, 3, 4)
	empty := gd.StyleBoxEmpty_new()
	defer gd.unref(empty)
	gd.Theme_set_stylebox(t, "focus", "Button", empty)
	for name in ([]string{"normal", "hover", "pressed", "hover_pressed", "disabled", "focus"}) {
		gd.Theme_set_stylebox(t, name, "CheckBox", empty)
	}
	for type in ([]string{"Button", "CheckBox", "Label"}) {
		gd.Theme_set_font(t, "font", type, font)
		gd.Theme_set_font_size(t, "font_size", type, FONT_SIZE)
		gd.Theme_set_color(t, "font_color", type, TEXT)
	}
	for type in ([]string{"Button", "CheckBox"}) {
		for c in ([]string{"font_hover_color", "font_focus_color", "font_hover_pressed_color", "font_pressed_color"}) {
			gd.Theme_set_color(t, c, type, TEXT)
		}
	}
	gd.Theme_set_color(t, "font_shadow_color", "Label", {0, 0, 0, 0})
	gd.Theme_set_constant(t, "shadow_offset_y", "Label", 0)
	flat(t, "slider", "HSlider", FRAME, 2, 0)
	flat(t, "grabber_area", "HSlider", ON, 2, 0)
	flat(t, "grabber_area_highlight", "HSlider", ON, 2, 0)
	for type in ([]string{"VBoxContainer", "HBoxContainer"}) do gd.Theme_set_constant(t, "separation", type, 4)
	return t
}

// A flat stylebox for `type`'s `name` (the theme keeps its own reference).
@(private)
flat :: proc(t: gd.Theme, name, type: string, bg: gd.Color, radius: int, margin: f32, border := gd.Color{}) {
	b := gd.StyleBoxFlat_new()
	defer gd.unref(b)
	gd.StyleBoxFlat_set_bg_color(b, bg)
	gd.StyleBoxFlat_set_corner_radius_all(b, radius)
	gd.StyleBox_set_content_margin_all(b, margin)
	if border.a > 0 {
		gd.StyleBoxFlat_set_border_width_all(b, 1)
		gd.StyleBoxFlat_set_border_color(b, border)
	}
	gd.Theme_set_stylebox(t, name, type, b)
}
