class_name UiTheme
## The game's UI theme, built in code (readable, diffable, no editor needed) and merged into Godot's default theme
## at boot (`install`), so every Control uses it, including those under CanvasLayers.
## Palette: deep slate panels, warm orange accent (players), cyan secondary (start circle, codes).

const BG := Color("151821")
const PANEL := Color("1d2230f0")
const PANEL_LIGHT := Color("2a3142")
const LINE := Color("3a4358")
const TEXT := Color("eef1f6")
const TEXT_DIM := Color("9aa3b5")
const ACCENT := Color("ff8a3d")
const ACCENT_HOVER := Color("ffa463")
const CYAN := Color("5de0ff")
const GOOD := Color("5dffb1")
const BAD := Color("ff5d6c")
const XP := Color("7ad7ff")
const SLOT_COLORS: Array[Color] = [Color("ff8a3d"), Color("ffd23f"), Color("ff5d8f"), Color("b98cff")]


static func install() -> void:
	var t := build()
	ThemeDB.get_default_theme().merge_with(t)
	ThemeDB.fallback_font = t.default_font
	ThemeDB.fallback_font_size = t.default_font_size


static func build() -> Theme:
	var t := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Avenir Next", "Segoe UI", "Helvetica Neue", "Arial"])
	font.font_weight = 500
	var bold := SystemFont.new()
	bold.font_names = font.font_names
	bold.font_weight = 800
	t.default_font = font
	t.default_font_size = 18

	t.set_stylebox(&"panel", &"PanelContainer", box(PANEL, 14, 24, LINE))
	t.set_stylebox(&"panel", &"Panel", box(PANEL, 14, 0, LINE))

	t.set_type_variation(&"Title", &"Label")
	t.set_font(&"font", &"Title", bold)
	t.set_font_size(&"font_size", &"Title", 56)
	t.set_color(&"font_color", &"Title", TEXT)
	t.set_type_variation(&"Heading", &"Label")
	t.set_font(&"font", &"Heading", bold)
	t.set_font_size(&"font_size", &"Heading", 28)
	t.set_type_variation(&"Dim", &"Label")
	t.set_color(&"font_color", &"Dim", TEXT_DIM)
	t.set_font_size(&"font_size", &"Dim", 16)
	t.set_type_variation(&"Big", &"Label")
	t.set_font(&"font", &"Big", bold)
	t.set_font_size(&"font_size", &"Big", 64)
	t.set_color(&"font_color", &"Big", CYAN)
	t.set_color(&"font_color", &"Label", TEXT)
	t.set_color(&"font_shadow_color", &"Label", Color(0, 0, 0, 0.45))
	t.set_constant(&"shadow_offset_y", &"Label", 2)

	var btn_n := box(PANEL_LIGHT, 10, 0, LINE)
	var btn_h := box(Color("343c50"), 10, 0, ACCENT)
	var btn_p := box(ACCENT, 10, 0, ACCENT)
	var btn_d := box(Color("222734"), 10, 0, Color("2a3040"))
	for s: StyleBoxFlat in [btn_n, btn_h, btn_p, btn_d]:
		s.content_margin_left = 22
		s.content_margin_right = 22
		s.content_margin_top = 10
		s.content_margin_bottom = 10
	t.set_stylebox(&"normal", &"Button", btn_n)
	t.set_stylebox(&"hover", &"Button", btn_h)
	t.set_stylebox(&"pressed", &"Button", btn_p)
	t.set_stylebox(&"hover_pressed", &"Button", btn_p)
	t.set_stylebox(&"disabled", &"Button", btn_d)
	t.set_stylebox(&"focus", &"Button", box(Color(0, 0, 0, 0), 10, 0, CYAN, 2))
	t.set_color(&"font_color", &"Button", TEXT)
	t.set_color(&"font_hover_color", &"Button", Color.WHITE)
	t.set_color(&"font_pressed_color", &"Button", BG)
	t.set_color(&"font_focus_color", &"Button", Color.WHITE)
	t.set_color(&"font_disabled_color", &"Button", Color("5c6578"))
	t.set_font(&"font", &"Button", bold)
	t.set_font_size(&"font_size", &"Button", 20)

	t.set_type_variation(&"PrimaryButton", &"Button")
	var prim := box(ACCENT, 10, 0, ACCENT)
	var prim_h := box(ACCENT_HOVER, 10, 0, Color.WHITE)
	for s: StyleBoxFlat in [prim, prim_h]:
		s.content_margin_left = 22
		s.content_margin_right = 22
		s.content_margin_top = 12
		s.content_margin_bottom = 12
	t.set_stylebox(&"normal", &"PrimaryButton", prim)
	t.set_stylebox(&"hover", &"PrimaryButton", prim_h)
	t.set_color(&"font_color", &"PrimaryButton", BG)
	t.set_color(&"font_hover_color", &"PrimaryButton", BG)
	t.set_color(&"font_focus_color", &"PrimaryButton", BG)

	var edit := box(Color("12151d"), 8, 0, LINE)
	edit.content_margin_left = 14
	edit.content_margin_right = 14
	edit.content_margin_top = 8
	edit.content_margin_bottom = 8
	var edit_f := edit.duplicate() as StyleBoxFlat
	edit_f.border_color = CYAN
	t.set_stylebox(&"normal", &"LineEdit", edit)
	t.set_stylebox(&"focus", &"LineEdit", edit_f)
	t.set_color(&"font_color", &"LineEdit", TEXT)
	t.set_color(&"font_placeholder_color", &"LineEdit", Color("5c6578"))
	t.set_color(&"caret_color", &"LineEdit", CYAN)
	t.set_font_size(&"font_size", &"LineEdit", 22)

	t.set_stylebox(&"normal", &"OptionButton", btn_n)
	t.set_stylebox(&"hover", &"OptionButton", btn_h)
	t.set_stylebox(&"pressed", &"OptionButton", btn_h)
	t.set_stylebox(&"focus", &"OptionButton", box(Color(0, 0, 0, 0), 10, 0, CYAN, 2))
	t.set_font_size(&"font_size", &"OptionButton", 18)
	t.set_stylebox(&"panel", &"PopupMenu", box(PANEL_LIGHT, 8, 6, LINE))

	var track := box(Color("12151d"), 4, 0, LINE)
	track.content_margin_top = 4
	track.content_margin_bottom = 4
	t.set_stylebox(&"slider", &"HSlider", track)
	t.set_stylebox(&"grabber_area", &"HSlider", box(ACCENT, 4, 0))
	t.set_stylebox(&"grabber_area_highlight", &"HSlider", box(ACCENT_HOVER, 4, 0))
	t.set_icon(&"grabber", &"HSlider", _dot(18, Color.WHITE))
	t.set_icon(&"grabber_highlight", &"HSlider", _dot(20, Color.WHITE))

	t.set_stylebox(&"background", &"ProgressBar", box(Color("0d0f15d0"), 6, 0, Color("00000000")))
	t.set_stylebox(&"fill", &"ProgressBar", box(GOOD, 6, 0))
	t.set_color(&"font_color", &"ProgressBar", TEXT)
	t.set_font_size(&"font_size", &"ProgressBar", 14)

	t.set_constant(&"separation", &"VBoxContainer", 12)
	t.set_constant(&"separation", &"HBoxContainer", 12)
	t.set_color(&"font_color", &"CheckButton", TEXT)
	t.set_color(&"font_hover_color", &"CheckButton", Color.WHITE)
	t.set_color(&"font_pressed_color", &"CheckButton", TEXT)
	t.set_color(&"font_focus_color", &"CheckButton", TEXT)
	t.set_color(&"font_hover_pressed_color", &"CheckButton", Color.WHITE)
	t.set_stylebox(&"focus", &"CheckButton", box(Color(0, 0, 0, 0), 8, 0, CYAN, 2))
	t.set_stylebox(&"panel", &"TooltipPanel", box(PANEL_LIGHT, 6, 8, LINE))
	return t


## A rounded flat box: fill colour, corner radius, content margin, optional border.
static func box(fill: Color, radius: int, margin: int, border := Color(0, 0, 0, 0), border_w := 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = fill
	s.set_corner_radius_all(radius)
	s.set_content_margin_all(margin)
	if border.a > 0.0:
		s.border_color = border
		s.set_border_width_all(border_w)
	s.anti_aliasing = true
	return s


static func slot_color(slot: int) -> Color:
	return SLOT_COLORS[clampi(slot, 0, SLOT_COLORS.size() - 1)]


static func _dot(size: int, color: Color) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := (size - 1) / 2.0
	for y in size:
		for x in size:
			var d := Vector2(x - c, y - c).length()
			img.set_pixel(x, y, Color(color, clampf(c - d + 0.5, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)
