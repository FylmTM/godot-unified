// The dev UI's theme: compact, and complete. A game may change Godot's default theme in place (survivor merges its
// UI theme into it) and theme lookup ends there, so every item the dev UI's controls use is set here: nothing of
// the game's look leaks in. The fonts are the system's (sans-serif, monospace for the overlay's numbers).
package devui

import gd "unified:gdext"

@(private)
FONT_SIZE :: 12

@(private)
BG :: gd.Color{0.1, 0.11, 0.13, 0.94}
@(private)
DARK :: gd.Color{0.07, 0.075, 0.09, 1}
@(private)
FRAME :: gd.Color{0.19, 0.21, 0.25, 1}
@(private)
HOVER :: gd.Color{0.26, 0.29, 0.35, 1}
@(private)
ON :: gd.Color{0.25, 0.4, 0.62, 1}
@(private)
LINE :: gd.Color{0.28, 0.31, 0.37, 1}
@(private)
TEXT :: gd.Color{0.88, 0.9, 0.93, 1}
@(private)
DIM :: gd.Color{0.6, 0.63, 0.68, 1}

@(private)
theme_init :: proc() {
	sans := system_font({"Segoe UI", "Helvetica Neue", "Noto Sans", "DejaVu Sans", "sans-serif"})
	defer gd.unref(sans)
	s.mono = system_font({"Consolas", "Menlo", "DejaVu Sans Mono", "monospace"})
	t := gd.Theme_new()
	s.theme = t
	gd.Theme_set_default_font(t, sans)
	gd.Theme_set_default_font_size(t, FONT_SIZE)

	// panels: 1 px border, small margins; the title bar a shade lighter
	flat(t, "panel", "PanelContainer", BG, 2, {3, 3, 3, 3}, LINE)
	gd.Theme_set_type_variation(t, "DevTitle", "PanelContainer")
	flat(t, "panel", "DevTitle", FRAME, 2, {4, 0, 1, 0})
	gd.Theme_set_type_variation(t, "DevOverlay", "PanelContainer")
	flat(t, "panel", "DevOverlay", {0.05, 0.055, 0.07, 0.6}, 2, {4, 3, 4, 3})
	gd.Theme_set_type_variation(t, "DevTitleLabel", "Label")
	gd.Theme_set_color(t, "font_color", "DevTitleLabel", DIM)
	// graph titles and legends, over the graph
	gd.Theme_set_type_variation(t, "DevGraphLabel", "Label")
	gd.Theme_set_font_size(t, "font_size", "DevGraphLabel", 10)
	gd.Theme_set_color(t, "font_color", "DevGraphLabel", DIM)
	gd.Theme_set_color(t, "font_shadow_color", "DevGraphLabel", {0, 0, 0, 0.8})
	gd.Theme_set_constant(t, "shadow_offset_x", "DevGraphLabel", 1)
	gd.Theme_set_constant(t, "shadow_offset_y", "DevGraphLabel", 1)

	// buttons: flat, 1 px vertical padding
	flat(t, "normal", "Button", FRAME, 2, {5, 0, 5, 0})
	flat(t, "disabled", "Button", FRAME, 2, {5, 0, 5, 0})
	flat(t, "hover", "Button", HOVER, 2, {5, 0, 5, 0})
	flat(t, "pressed", "Button", ON, 2, {5, 0, 5, 0})
	flat(t, "hover_pressed", "Button", ON, 2, {5, 0, 5, 0})
	gd.Theme_set_type_variation(t, "DevToggle", "Button")
	flat(t, "normal", "DevToggle", {0, 0, 0, 0.35}, 2, {5, 0, 5, 0})
	gd.Theme_set_type_variation(t, "DevTitleButton", "Button")
	for name in ([]string{"normal", "disabled"}) do flat(t, name, "DevTitleButton", {}, 0, {4, 0, 4, 0})
	flat(t, "hover", "DevTitleButton", HOVER, 0, {4, 0, 4, 0})
	flat(t, "pressed", "DevTitleButton", ON, 0, {4, 0, 4, 0})
	empty := gd.StyleBoxEmpty_new()
	defer gd.unref(empty)
	gd.Theme_set_stylebox(t, "focus", "Button", empty)
	for name in ([]string{"normal", "hover", "pressed", "hover_pressed", "disabled", "focus"}) {
		gd.Theme_set_stylebox(t, name, "CheckBox", empty)
	}
	gd.Theme_set_constant(t, "h_separation", "CheckBox", 2)
	gd.Theme_set_constant(t, "check_v_offset", "CheckBox", 3)
	icon(t, "unchecked", "CheckBox", 10, 10, DARK, DIM)
	icon(t, "checked", "CheckBox", 10, 10, ON, TEXT)
	for name in ([]string{"grabber", "grabber_highlight", "grabber_disabled"}) do icon(t, name, "HSlider", 6, 12, TEXT, TEXT)
	gd.Theme_set_constant(t, "h_separation", "Button", 2)

	for type in ([]string{"Button", "CheckBox", "Label", "Tree", "TextEdit"}) {
		gd.Theme_set_font(t, "font", type, sans)
		gd.Theme_set_font_size(t, "font_size", type, FONT_SIZE)
	}
	for type in ([]string{"Button", "CheckBox"}) {
		for c in ([]string{"font_color", "font_hover_color", "font_focus_color", "font_hover_pressed_color", "font_pressed_color"}) {
			gd.Theme_set_color(t, c, type, TEXT)
		}
	}
	gd.Theme_set_color(t, "font_color", "Label", TEXT)
	gd.Theme_set_color(t, "font_shadow_color", "Label", {0, 0, 0, 0})
	gd.Theme_set_constant(t, "shadow_offset_y", "Label", 0)
	gd.Theme_set_constant(t, "line_spacing", "Label", 0)

	// trees: dense rows, no lines between them
	flat(t, "panel", "Tree", DARK, 0, {2, 1, 2, 1})
	gd.Theme_set_stylebox(t, "focus", "Tree", empty)
	flat(t, "selected", "Tree", FRAME, 0, {})
	flat(t, "selected_focus", "Tree", FRAME, 0, {})
	flat(t, "hovered", "Tree", {1, 1, 1, 0.05}, 0, {})
	gd.Theme_set_color(t, "font_color", "Tree", TEXT)
	gd.Theme_set_color(t, "font_selected_color", "Tree", TEXT)
	gd.Theme_set_constant(t, "v_separation", "Tree", 2)
	gd.Theme_set_constant(t, "h_separation", "Tree", 4)
	gd.Theme_set_constant(t, "inner_item_margin_left", "Tree", 2)
	gd.Theme_set_constant(t, "inner_item_margin_right", "Tree", 2)
	gd.Theme_set_constant(t, "draw_guides", "Tree", 1)
	gd.Theme_set_color(t, "guide_color", "Tree", {1, 1, 1, 0.05})
	gd.Theme_set_constant(t, "draw_relationship_lines", "Tree", 1)
	for c in ([]string{"relationship_line_color", "parent_hl_line_color", "children_hl_line_color"}) {
		gd.Theme_set_color(t, c, "Tree", {1, 1, 1, 0.12})
	}
	for c in ([]string{"relationship_line_width", "parent_hl_line_width", "children_hl_line_width"}) {
		gd.Theme_set_constant(t, c, "Tree", 1)
	}
	gd.Theme_set_constant(t, "item_margin", "Tree", 14)
	gd.Theme_set_constant(t, "scroll_speed", "Tree", 24)

	flat(t, "normal", "TextEdit", DARK, 2, {3, 2, 3, 2})
	flat(t, "focus", "TextEdit", {}, 2, {3, 2, 3, 2}, ON)
	gd.Theme_set_color(t, "font_color", "TextEdit", TEXT)
	gd.Theme_set_color(t, "font_placeholder_color", "TextEdit", DIM)
	gd.Theme_set_color(t, "caret_color", "TextEdit", TEXT)

	flat(t, "slider", "HSlider", FRAME, 2, {0, 2, 0, 2})
	flat(t, "grabber_area", "HSlider", ON, 2, {0, 2, 0, 2})
	flat(t, "grabber_area_highlight", "HSlider", ON, 2, {0, 2, 0, 2})
	for type in ([]string{"VBoxContainer", "HBoxContainer"}) do gd.Theme_set_constant(t, "separation", type, 3)
}

// A w x h icon for `type`'s `name`: `fill` inside a 1 px `border`.
@(private)
icon :: proc(t: gd.Theme, name, type: string, w, h: int, fill, border: gd.Color) {
	img := gd.Image_create_empty(w, h, false, .FORMAT_RGBA8)
	defer gd.unref(img)
	gd.Image_fill(img, border)
	gd.Image_fill_rect(img, {{1, 1}, {i32(w - 2), i32(h - 2)}}, fill)
	tex := gd.ImageTexture_create_from_image(img)
	defer gd.unref(tex)
	gd.Theme_set_icon(t, name, type, tex)
}

@(private)
system_font :: proc(names: []string) -> gd.Ref(gd.SystemFont) {
	f := gd.SystemFont_new()
	list := gd.PackedStringArray_new0()
	defer gd.PackedStringArray_destroy(&list)
	for n in names do gd.PackedStringArray_push_back(&list, n)
	gd.SystemFont_set_font_names(f, list)
	return f
}

// A flat stylebox for `type`'s `name`: background, corner radius, content margins (left, top, right, bottom),
// an optional 1 px border. The theme keeps its own reference.
@(private)
flat :: proc(t: gd.Theme, name, type: string, bg: gd.Color, radius: int, margin: [4]f32, border := gd.Color{}) {
	b := gd.StyleBoxFlat_new()
	defer gd.unref(b)
	gd.StyleBoxFlat_set_bg_color(b, bg)
	gd.StyleBoxFlat_set_corner_radius_all(b, radius)
	for m, side in margin do gd.StyleBox_set_content_margin(b, gd.Side(side), m)
	if border.a > 0 {
		gd.StyleBoxFlat_set_border_width_all(b, 1)
		gd.StyleBoxFlat_set_border_color(b, border)
	}
	gd.Theme_set_stylebox(t, name, type, b)
}
