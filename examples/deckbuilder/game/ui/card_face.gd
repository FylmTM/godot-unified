class_name CardFace
extends Control
## A card's face, drawn in code: a frame in its kind's colour (an attack crimson, a card for an ally green, one for
## yourself steel blue), parchment inside, its name on a ribbon, its glyph (Glyph.of_card) in the art box, its kind and
## rules text below, and its cost in a gem at the top left. `compact` draws an ally's small card: the frame and the
## glyph (its owner's tooltip names it). Everything a face shows comes from `show_card` (the card views, the reward and rest panels,
## the menu's backdrop); it lays itself out on every resize. It takes no input: its owner does.

const ATTACK := Color("9c2f2a")
const ALLY := Color("3d7a3a")
const SELF := Color("2f5a8a")
const PARCHMENT := Color("eadcbf")
const ART := Color("d8c39c")
const INK := Color("3a2716")
const GEM := Color("2b6db0")

## Drawn with a gold edge (held up, or chosen).
var highlighted := false:
	set(value):
		highlighted = value
		queue_redraw()
## The small face of an ally's hand.
var compact := false:
	set(value):
		compact = value
		_layout()

var _id := 0
var _cost := 0
var _target := 0
var _name := Label.new()
var _kind := Label.new()
var _text := Label.new()
var _gem := Label.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for label: Label in [_name, _kind, _text, _gem]:
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_constant_override(&"shadow_offset_y", 0)
		label.add_theme_color_override(&"font_shadow_color", Color(0, 0, 0, 0))
		add_child(label)
	_name.add_theme_font_override(&"font", UiTheme.serif(700))
	_name.add_theme_color_override(&"font_color", Color("f6ecd6"))
	_name.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.6))
	_name.add_theme_constant_override(&"outline_size", 3)
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_kind.add_theme_color_override(&"font_color", INK.lightened(0.25))
	_text.add_theme_color_override(&"font_color", INK)
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_gem.add_theme_font_override(&"font", UiTheme.serif(800))
	_gem.add_theme_color_override(&"font_color", Color.WHITE)
	_gem.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.7))
	_gem.add_theme_constant_override(&"outline_size", 4)
	resized.connect(_layout)


## Shows the card `id` (an EnumCardId value), upgraded or not: its name, cost, kind and rules text from the sim's
## constants (Unified.constants.cards). `cost` overrides the printed cost (-1: the card's own).
func show_card(id: int, upgraded: bool, cost := -1) -> void:
	var info: DataCardText = Unified.constants.cards[id]
	_id = id
	_cost = info.cost if cost < 0 else cost
	_target = info.target
	_name.text = EnumCardId.name(id).capitalize() + ("+" if upgraded else "")
	_name.add_theme_color_override(&"font_color", Color("b8f0a0") if upgraded else Color("f6ecd6"))
	_gem.text = str(_cost)
	var kind := "Attack" if _is_attack() else "Skill"
	if _target == EnumTargetKind.ALLY:
		kind += " · Ally"
	elif _target == EnumTargetKind.ALL_ENEMIES:
		kind += " · All"
	_kind.text = kind.to_upper()
	_text.text = info.upgraded if upgraded else info.text
	_layout()
	queue_redraw()


## The frame's colour: what the card is played at.
func frame_color() -> Color:
	if _is_attack():
		return ATTACK
	return ALLY if _target == EnumTargetKind.ALLY else SELF


func _is_attack() -> bool:
	return _target == EnumTargetKind.ENEMY or _target == EnumTargetKind.ALL_ENEMIES


func _layout() -> void:
	var w := size.x
	var h := size.y
	if w <= 0.0 or h <= 0.0:
		return
	var unit := w / 128.0  # the faces are laid out for a 128 px wide card and scaled
	for label: Label in [_name, _kind, _text, _gem]:
		label.visible = not compact
	if not compact:
		_name.position = Vector2(8 * unit, 10 * unit)
		_name.size = Vector2(w - 16 * unit, 22 * unit)
		_name.add_theme_font_size_override(&"font_size", int(15 * unit))
		_kind.position = Vector2(8 * unit, h * 0.53)
		_kind.size = Vector2(w - 16 * unit, 14 * unit)
		_kind.add_theme_font_size_override(&"font_size", int(9 * unit))
		_text.position = Vector2(10 * unit, h * 0.53 + 15 * unit)
		_text.size = Vector2(w - 20 * unit, h * 0.47 - 22 * unit)
		_text.add_theme_font_size_override(&"font_size", int(12 * unit))
	var gem := 15.0 * unit
	_gem.position = Vector2(-gem * 0.35, -gem * 0.35)
	_gem.size = Vector2(gem * 2, gem * 2)
	_gem.add_theme_font_size_override(&"font_size", int(gem * 1.2))
	queue_redraw()


func _draw() -> void:
	if _id == 0:
		return
	var w := size.x
	var h := size.y
	var unit := w / 128.0
	var frame := frame_color()
	var radius := maxi(3, int(9 * unit))
	# the shadow, the frame, the parchment
	draw_style_box(UiTheme.box(Color(0, 0, 0, 0.35), radius, 0), Rect2(Vector2(3, 5) * unit, size))
	var edge := Color("ffd25a") if highlighted else frame.darkened(0.45)
	draw_style_box(UiTheme.box(frame, radius, 0, edge, int(4 * unit) if highlighted else maxi(1, int(2 * unit))),
		Rect2(Vector2.ZERO, size))
	var inset := maxf(2.0, 5.0 * unit)
	var inner := Rect2(Vector2(inset, inset), size - Vector2(inset, inset) * 2)
	if compact:
		draw_style_box(UiTheme.box(PARCHMENT.darkened(0.1), 2, 0), inner)
		Glyph.draw(self, Glyph.of_card(_id), size * 0.5, minf(w, h) * 0.32, frame.darkened(0.1))
		return
	else:
		draw_style_box(UiTheme.box(PARCHMENT, int(6 * unit), 0), inner)
		# the name's ribbon
		var ribbon := Rect2(Vector2(inset - 2 * unit, 9 * unit), Vector2(w - inset * 2 + 4 * unit, 24 * unit))
		draw_style_box(UiTheme.box(frame.darkened(0.25), int(4 * unit), 0, frame.darkened(0.6), maxi(1, int(unit))), ribbon)
		# the art box and its glyph, on a wash of the frame's colour
		var art := Rect2(Vector2(inset + 5 * unit, 37 * unit), Vector2(w - inset * 2 - 10 * unit, h * 0.53 - 40 * unit))
		draw_style_box(UiTheme.box(ART, int(4 * unit), 0, INK.lightened(0.3), maxi(1, int(unit))), art)
		draw_circle(art.get_center(), art.size.y * 0.42, Color(frame, 0.18))
		Glyph.draw(self, Glyph.of_card(_id), art.get_center(), art.size.y * 0.36, frame.lightened(0.05))
		# the rule between the kind and the text
		var y := h * 0.53 + 14 * unit
		draw_line(Vector2(w * 0.25, y), Vector2(w * 0.75, y), Color(INK, 0.35), maxf(1.0, unit))
	# the cost's gem
	var gem_r := 15.0 * unit
	var gem_at := Vector2(gem_r * 0.65, gem_r * 0.65)
	draw_circle(gem_at + Vector2(1, 2) * unit, gem_r, Color(0, 0, 0, 0.4))
	draw_circle(gem_at, gem_r, Color("e0a43a"))
	draw_circle(gem_at, gem_r * 0.8, GEM)
	draw_circle(gem_at - Vector2(gem_r, gem_r) * 0.25, gem_r * 0.3, Color(1, 1, 1, 0.25))
