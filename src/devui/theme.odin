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
	theme := gd.Theme_new()
	s.theme = theme
	gd.Theme_set_default_font(theme, sans)
	gd.Theme_set_default_font_size(theme, FONT_SIZE)

	// panels: 1 px border, small margins; the title bar a shade lighter
	flat(theme, "panel", "PanelContainer", BG, 2, {3, 3, 3, 3}, LINE)
	gd.Theme_set_type_variation(theme, "DevTitle", "PanelContainer")
	flat(theme, "panel", "DevTitle", FRAME, 2, {4, 0, 1, 0})
	gd.Theme_set_type_variation(theme, "DevOverlay", "PanelContainer")
	flat(theme, "panel", "DevOverlay", {0.06, 0.065, 0.08, 0.92}, 2, {5, 4, 5, 4}, LINE)
	gd.Theme_set_type_variation(theme, "DevTitleLabel", "Label")
	gd.Theme_set_color(theme, "font_color", "DevTitleLabel", DIM)
	// graph titles and legends, over the graph
	// the stat grid's keys
	gd.Theme_set_type_variation(theme, "DevKey", "Label")
	gd.Theme_set_color(theme, "font_color", "DevKey", DIM)
	gd.Theme_set_type_variation(theme, "DevGraphLabel", "Label")
	gd.Theme_set_font_size(theme, "font_size", "DevGraphLabel", 10)
	gd.Theme_set_color(theme, "font_color", "DevGraphLabel", DIM)
	gd.Theme_set_color(theme, "font_shadow_color", "DevGraphLabel", {0, 0, 0, 0.8})
	gd.Theme_set_constant(theme, "shadow_offset_x", "DevGraphLabel", 1)
	gd.Theme_set_constant(theme, "shadow_offset_y", "DevGraphLabel", 1)

	// buttons: flat, 1 px vertical padding
	flat(theme, "normal", "Button", FRAME, 2, {5, 0, 5, 0})
	flat(theme, "disabled", "Button", FRAME, 2, {5, 0, 5, 0})
	flat(theme, "hover", "Button", HOVER, 2, {5, 0, 5, 0})
	flat(theme, "pressed", "Button", ON, 2, {5, 0, 5, 0})
	flat(theme, "hover_pressed", "Button", ON, 2, {5, 0, 5, 0})
	gd.Theme_set_type_variation(theme, "DevToggle", "Button")
	flat(theme, "normal", "DevToggle", {0, 0, 0, 0.35}, 2, {5, 0, 5, 0})
	gd.Theme_set_type_variation(theme, "DevTitleButton", "Button")
	for name in ([]string{"normal", "disabled"}) do flat(theme, name, "DevTitleButton", {}, 0, {4, 0, 4, 0})
	flat(theme, "hover", "DevTitleButton", HOVER, 0, {4, 0, 4, 0})
	flat(theme, "pressed", "DevTitleButton", ON, 0, {4, 0, 4, 0})
	empty := gd.StyleBoxEmpty_new()
	defer gd.unref(empty)
	gd.Theme_set_stylebox(theme, "focus", "Button", empty)
	for name in ([]string{"normal", "hover", "pressed", "hover_pressed", "disabled", "focus"}) {
		gd.Theme_set_stylebox(theme, name, "CheckBox", empty)
	}
	gd.Theme_set_constant(theme, "h_separation", "CheckBox", 2)
	gd.Theme_set_constant(theme, "check_v_offset", "CheckBox", 3)
	icon(theme, "unchecked", "CheckBox", 10, 10, DARK, DIM)
	icon(theme, "checked", "CheckBox", 10, 10, ON, TEXT)
	for name in ([]string{"grabber", "grabber_highlight", "grabber_disabled"}) do icon(theme, name, "HSlider", 6, 12, TEXT, TEXT)
	gd.Theme_set_constant(theme, "h_separation", "Button", 2)

	for type in ([]string{"Button", "CheckBox", "Label", "Tree", "TextEdit"}) {
		gd.Theme_set_font(theme, "font", type, sans)
		gd.Theme_set_font_size(theme, "font_size", type, FONT_SIZE)
	}
	for type in ([]string{"Button", "CheckBox"}) {
		for color_name in ([]string{"font_color", "font_hover_color", "font_focus_color", "font_hover_pressed_color", "font_pressed_color"}) {
			gd.Theme_set_color(theme, color_name, type, TEXT)
		}
	}
	gd.Theme_set_color(theme, "font_color", "Label", TEXT)
	gd.Theme_set_color(theme, "font_shadow_color", "Label", {0, 0, 0, 0})
	gd.Theme_set_constant(theme, "shadow_offset_y", "Label", 0)
	gd.Theme_set_constant(theme, "line_spacing", "Label", 0)

	// trees: dense rows, no lines between them
	flat(theme, "panel", "Tree", DARK, 0, {2, 1, 2, 1})
	gd.Theme_set_stylebox(theme, "focus", "Tree", empty)
	flat(theme, "selected", "Tree", FRAME, 0, {})
	flat(theme, "selected_focus", "Tree", FRAME, 0, {})
	flat(theme, "hovered", "Tree", {1, 1, 1, 0.05}, 0, {})
	gd.Theme_set_color(theme, "font_color", "Tree", TEXT)
	gd.Theme_set_color(theme, "font_selected_color", "Tree", TEXT)
	gd.Theme_set_constant(theme, "v_separation", "Tree", 2)
	gd.Theme_set_constant(theme, "h_separation", "Tree", 4)
	gd.Theme_set_constant(theme, "inner_item_margin_left", "Tree", 2)
	gd.Theme_set_constant(theme, "inner_item_margin_right", "Tree", 2)
	gd.Theme_set_constant(theme, "draw_guides", "Tree", 1)
	gd.Theme_set_color(theme, "guide_color", "Tree", {1, 1, 1, 0.05})
	gd.Theme_set_constant(theme, "draw_relationship_lines", "Tree", 1)
	for color_name in ([]string{"relationship_line_color", "parent_hl_line_color", "children_hl_line_color"}) {
		gd.Theme_set_color(theme, color_name, "Tree", {1, 1, 1, 0.12})
	}
	for color_name in ([]string{"relationship_line_width", "parent_hl_line_width", "children_hl_line_width"}) {
		gd.Theme_set_constant(theme, color_name, "Tree", 1)
	}
	gd.Theme_set_constant(theme, "item_margin", "Tree", 14)
	gd.Theme_set_constant(theme, "scroll_speed", "Tree", 24)

	flat(theme, "normal", "TextEdit", DARK, 2, {3, 2, 3, 2})
	flat(theme, "focus", "TextEdit", {}, 2, {3, 2, 3, 2}, ON)
	gd.Theme_set_color(theme, "font_color", "TextEdit", TEXT)
	gd.Theme_set_color(theme, "font_placeholder_color", "TextEdit", DIM)
	gd.Theme_set_color(theme, "caret_color", "TextEdit", TEXT)

	flat(theme, "slider", "HSlider", FRAME, 2, {0, 2, 0, 2})
	flat(theme, "grabber_area", "HSlider", ON, 2, {0, 2, 0, 2})
	flat(theme, "grabber_area_highlight", "HSlider", ON, 2, {0, 2, 0, 2})
	for type in ([]string{"VBoxContainer", "HBoxContainer"}) do gd.Theme_set_constant(theme, "separation", type, 3)
}

// A w x h icon for `type`'s `name`: `fill` inside a 1 px `border`.
@(private)
icon :: proc(theme: gd.Theme, name, type: string, width, height: int, fill, border: gd.Color) {
	img := gd.Image_create_empty(width, height, false, .FORMAT_RGBA8)
	defer gd.unref(img)
	gd.Image_fill(img, border)
	gd.Image_fill_rect(img, {{1, 1}, {i32(width - 2), i32(height - 2)}}, fill)
	tex := gd.ImageTexture_create_from_image(img)
	defer gd.unref(tex)
	gd.Theme_set_icon(theme, name, type, tex)
}

@(private)
system_font :: proc(names: []string) -> gd.Ref(gd.SystemFont) {
	font := gd.SystemFont_new()
	list := gd.PackedStringArray_new0()
	defer gd.PackedStringArray_destroy(&list)
	for font_name in names do gd.PackedStringArray_push_back(&list, font_name)
	gd.SystemFont_set_font_names(font, list)
	return font
}

// A flat stylebox for `type`'s `name`: background, corner radius, content margins (left, top, right, bottom),
// an optional 1 px border. The theme keeps its own reference.
@(private)
flat :: proc(
	theme: gd.Theme,
	name, type: string,
	background: gd.Color,
	radius: int,
	margin: [4]f32,
	border := gd.Color{},
) {
	style := gd.StyleBoxFlat_new()
	defer gd.unref(style)
	gd.StyleBoxFlat_set_bg_color(style, background)
	gd.StyleBoxFlat_set_corner_radius_all(style, radius)
	for inset, side in margin do gd.StyleBox_set_content_margin(style, gd.Side(side), inset)
	if border.a > 0 {
		gd.StyleBoxFlat_set_border_width_all(style, 1)
		gd.StyleBoxFlat_set_border_color(style, border)
	}
	gd.Theme_set_stylebox(theme, name, type, style)
}
