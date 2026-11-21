class_name UiTheme
## The UI theme every game shares, built in code (readable, diffable, no editor needed) and merged into Godot's
## default theme at boot (`install`), so every Control uses it, including those under CanvasLayers.
## deckbuilder's palette is the tabletop's: dark walnut panels with bronze lines, a gold accent, arcane teal secondary
## (codes, highlights), parchment text and a serif face for titles, headings and buttons; one colour per hero.

const BG := Color("16110d")
const PANEL := Color("231a14f0")
const PANEL_LIGHT := Color("33261c")
const LINE := Color("6b5232")
const TEXT := Color("f3e9d2")
const TEXT_DIM := Color("b3a184")
const ACCENT := Color("e0a43a")
const ACCENT_HOVER := Color("f2c060")
const CYAN := Color("6fd6c4")
const GOOD := Color("7fd36b")
const BAD := Color("e2574c")
const XP := Color("7ad7ff")
const GOLD := Color("ffd25a")
## The heroes' colours, by hero index (a slot's, in the session panel): their frames, aims and dots.
const PLAYER_COLORS: Array[Color] = [Color("e8664f"), Color("7fd36b"), Color("5fb8e8"), Color("c58bf0")]
## The serif faces of titles, headings, buttons and card names, the first one the system has.
const SERIF: Array[String] = ["Palatino Linotype", "Book Antiqua", "Palatino", "Georgia", "Cambria", "Times New Roman"]


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
	bold.font_names = PackedStringArray(SERIF)
	bold.font_weight = 700
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
	var btn_h := box(Color("43321f"), 10, 0, ACCENT)
	var btn_p := box(ACCENT, 10, 0, ACCENT)
	var btn_d := box(Color("241b15"), 10, 0, Color("2e241b"))
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
	t.set_color(&"font_disabled_color", &"Button", Color("6e5e4a"))
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

	var edit := box(Color("120d0a"), 8, 0, LINE)
	edit.content_margin_left = 14
	edit.content_margin_right = 14
	edit.content_margin_top = 8
	edit.content_margin_bottom = 8
	var edit_f := edit.duplicate() as StyleBoxFlat
	edit_f.border_color = CYAN
	t.set_stylebox(&"normal", &"LineEdit", edit)
	t.set_stylebox(&"focus", &"LineEdit", edit_f)
	t.set_color(&"font_color", &"LineEdit", TEXT)
	t.set_color(&"font_placeholder_color", &"LineEdit", Color("6e5e4a"))
	t.set_color(&"caret_color", &"LineEdit", CYAN)
	t.set_font_size(&"font_size", &"LineEdit", 22)

	t.set_stylebox(&"normal", &"OptionButton", btn_n)
	t.set_stylebox(&"hover", &"OptionButton", btn_h)
	t.set_stylebox(&"pressed", &"OptionButton", btn_h)
	t.set_stylebox(&"focus", &"OptionButton", box(Color(0, 0, 0, 0), 10, 0, CYAN, 2))
	t.set_font_size(&"font_size", &"OptionButton", 18)
	t.set_stylebox(&"panel", &"PopupMenu", box(PANEL_LIGHT, 8, 6, LINE))

	var track := box(Color("120d0a"), 4, 0, LINE)
	track.content_margin_top = 4
	track.content_margin_bottom = 4
	t.set_stylebox(&"slider", &"HSlider", track)
	t.set_stylebox(&"grabber_area", &"HSlider", box(ACCENT, 4, 0))
	t.set_stylebox(&"grabber_area_highlight", &"HSlider", box(ACCENT_HOVER, 4, 0))
	t.set_icon(&"grabber", &"HSlider", _dot(18, Color.WHITE))
	t.set_icon(&"grabber_highlight", &"HSlider", _dot(20, Color.WHITE))

	t.set_stylebox(&"background", &"ProgressBar", box(Color("0e0a08d0"), 6, 0, Color("00000000")))
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


## A slot's colour (UnifiedSession.get_player_slot of a player), or a hero's by their index.
static func player_color(slot: int) -> Color:
	return PLAYER_COLORS[clampi(slot, 0, PLAYER_COLORS.size() - 1)]


## A match clock: "m:ss".
static func clock(seconds: float) -> String:
	var whole := maxi(int(seconds), 0)
	@warning_ignore("integer_division")
	return "%d:%02d" % [whole / 60, whole % 60]


## A health bar's colour by the fraction left: good above a half, gold above a quarter, bad below.
static func health_color(fraction: float) -> Color:
	return GOOD if fraction > 0.5 else (GOLD if fraction > 0.25 else BAD)


## The serif face at `weight` (card names, the table's numbers).
static func serif(weight := 700) -> SystemFont:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(SERIF)
	font.font_weight = weight
	return font


static func _dot(size: int, color: Color) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := (size - 1) / 2.0
	for y in size:
		for x in size:
			var d := Vector2(x - c, y - c).length()
			img.set_pixel(x, y, Color(color, clampf(c - d + 0.5, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)
