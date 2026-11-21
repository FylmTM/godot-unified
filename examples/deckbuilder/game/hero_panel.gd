class_name HeroPanel
extends Control
## One hero of the run (Unified.data.heroes.heroes[index]), drawn in code on a walnut plate edged in their colour (thick
## for the local hero): a portrait with their class's emblem, their player's name and class, HP, block, energy,
## strength and statuses, relics (named in the tooltip), whether they ended their turn, sleep or are down, what they
## hold up and at whom (their Input, live), and their hand, open to everyone (an ally's cards, small; the local hero's
## are in the big hand below). Hits, heals and block flash it (the table calls `flash`); while the local player holds
## up a card for an ally, it pulses gold under the mouse.

const SIZE := Vector2(268, 156)
const PORTRAIT := Vector2(40, 46)

@export var index := 0

## The local player holds up a card that can be played at it (the table sets it).
var targetable := false:
	set(value):
		targetable = value
		queue_redraw()

var _hovered := false
var _time := 0.0
var _font: Font = UiTheme.serif(700)
var _body_font: Font = ThemeDB.fallback_font

@onready var _hand: HFlowContainer = %Hand


func _ready() -> void:
	custom_minimum_size = SIZE
	pivot_offset = SIZE * 0.5
	_hand.add_to_group(StringName("hand_%d" % index))
	gui_input.connect(_on_gui_input)
	mouse_entered.connect(func() -> void:
		_hovered = true
		get_tree().call_group(&"table", &"hero_hovered", index))
	mouse_exited.connect(func() -> void: _hovered = false)
	Unified.data.heroes.changed.connect(refresh)
	refresh()


func _process(delta: float) -> void:
	_time += delta
	if targetable:
		queue_redraw()


func row() -> DataHeroRow:
	return Unified.data.heroes.heroes[index]


func refresh() -> void:
	var hero := row()
	visible = hero.in_run
	if not hero.in_run:
		return
	var relics: Array[String] = []
	for relic: int in hero.relics:
		relics.append("%s: %s" % [EnumRelic.name(relic).capitalize(), Unified.constants.relics[relic]])
	tooltip_text = "\n".join(relics)
	modulate = Color(0.6, 0.6, 0.6) if hero.down or not hero.awake else Color.WHITE
	queue_redraw()


## A hit, a heal or block: a short flash of its colour and a bump.
func flash(color: Color) -> void:
	modulate = color
	scale = Vector2(1.04, 1.04)
	var tween := create_tween().set_parallel()
	tween.tween_property(self, ^"modulate", Color.WHITE, 0.35)
	tween.tween_property(self, ^"scale", Vector2.ONE, 0.25)


func _draw() -> void:
	var hero := row()
	if not hero.in_run:
		return
	var color := UiTheme.player_color(index)
	# the plate
	draw_style_box(UiTheme.box(Color(0, 0, 0, 0.35), 12, 0), Rect2(Vector2(3, 5), SIZE))
	draw_style_box(UiTheme.box(Color("2a1f17f2"), 12, 0, color.darkened(0.15), 4 if hero.local else 2),
		Rect2(Vector2.ZERO, SIZE))
	if targetable:
		var pulse := 0.5 + 0.5 * sin(_time * 6.0)
		draw_style_box(UiTheme.box(Color(0, 0, 0, 0), 14, 0, Color(UiTheme.GOLD, 0.4 + 0.5 * pulse if _hovered else 0.3),
			4 if _hovered else 2), Rect2(Vector2(-4, -4), SIZE + Vector2(8, 8)))
	# the portrait
	draw_circle(PORTRAIT, 31, Color("1a130e"))
	draw_circle(PORTRAIT, 28, color.darkened(0.6))
	draw_arc(PORTRAIT, 29, 0, TAU, 40, Color("b8893a"), 2.5, true)
	Glyph.draw(self, Glyph.of_class(hero.hero_class), PORTRAIT, 17.0, color.lightened(0.2))
	# the name, class and state
	var player_name := Unified.session.get_player_name(hero.player) if hero.awake else ""
	if player_name == "":
		player_name = "Hero %d" % (index + 1)
	if hero.local:
		player_name += " (you)"
	draw_string(_font, Vector2(80, 26), player_name, HORIZONTAL_ALIGNMENT_LEFT, 150, 17, UiTheme.TEXT)
	draw_string(_body_font, Vector2(80, 43), EnumHeroClass.name(hero.hero_class).capitalize(), HORIZONTAL_ALIGNMENT_LEFT,
		120, 12, UiTheme.TEXT_DIM)
	var state := ""
	var state_color := UiTheme.GOOD
	if hero.down:
		state = "DOWN"
		state_color = UiTheme.BAD
	elif not hero.awake:
		state = "ASLEEP"
		state_color = UiTheme.TEXT_DIM
	elif hero.ready:
		state = "READY"
	if state != "":
		draw_string(_font, Vector2(SIZE.x - 92, 43), state, HORIZONTAL_ALIGNMENT_RIGHT, 80, 12, state_color)
	# HP
	var bar := Rect2(Vector2(80, 50), Vector2(SIZE.x - 92, 15))
	draw_style_box(UiTheme.box(Color("120c09"), 7, 0, Color("5a4026"), 1), bar)
	var fraction := clampf(float(hero.hp) / maxf(hero.max_hp, 1), 0.0, 1.0)
	if fraction > 0.0:
		draw_style_box(UiTheme.box(UiTheme.health_color(fraction).darkened(0.15), 6, 0), Rect2(bar.position + Vector2(2, 2),
			Vector2(maxf((bar.size.x - 4) * fraction, 8.0), bar.size.y - 4)))
	draw_string(_body_font, bar.position + Vector2(0, 12), "%d / %d" % [hero.hp, hero.max_hp], HORIZONTAL_ALIGNMENT_CENTER,
		bar.size.x, 11, Color.WHITE)
	# the badges: block, energy, strength, statuses, relics
	var x := 16.0
	var y := 90.0
	if hero.block > 0:
		x = _badge(x, y, &"shield", Color("8fb3d9"), str(hero.block))
	x = _badge(x, y, &"bolt", Color("f2c060"), str(hero.energy))
	if hero.strength != 0:
		x = _badge(x, y, &"flag", Color("e8664f"), "%+d" % hero.strength)
	if hero.weak > 0:
		x = _badge(x, y, &"drop", Color("8bc36a"), str(hero.weak))
	if hero.vulnerable > 0:
		x = _badge(x, y, &"eye", Color("d08be0"), str(hero.vulnerable))
	for _relic: int in hero.relics:
		Glyph.draw(self, &"star", Vector2(x + 8, y), 8.0, UiTheme.GOLD)
		x += 20.0
	draw_string(_body_font, Vector2(SIZE.x - 118, y + 5), "draw %d  discard %d" % [hero.draw, hero.discard],
		HORIZONTAL_ALIGNMENT_RIGHT, 106, 11, UiTheme.TEXT_DIM)
	# what they hold up
	var aim := _aim_text(hero)
	if aim != "":
		draw_string(_body_font, Vector2(16, 112), aim, HORIZONTAL_ALIGNMENT_LEFT, SIZE.x - 30, 11, UiTheme.GOLD)


## One badge (a glyph and its number) at `x`; returns where the next one goes.
func _badge(x: float, y: float, glyph: StringName, color: Color, text: String) -> float:
	Glyph.draw(self, glyph, Vector2(x + 8, y), 9.0, color)
	draw_string(_font, Vector2(x + 20, y + 6), text, HORIZONTAL_ALIGNMENT_LEFT, 30, 15, color.lightened(0.2))
	return x + 26.0 + text.length() * 8.0


## What their player holds up, and at whom: their card by its place in their hand, the enemy by its index.
func _aim_text(hero: DataHeroRow) -> String:
	if hero.aim_card == 0 or hero.local:
		return ""
	var card := "a card"
	for child in _hand.get_children():
		var held := child as DeckCard
		if held != null and held.data.slot == hero.aim_card - 1:
			card = EnumCardId.name(held.data.id).capitalize()
	var text := "holds up %s" % card
	for node in get_tree().get_nodes_in_group(&"enemies"):
		var enemy := node as DeckEnemy
		if hero.aim_enemy > 0 and enemy.data.index == hero.aim_enemy - 1:
			text += " at the %s" % EnumEnemyKind.name(enemy.data.kind).capitalize()
	if hero.aim_hero > 0:
		text += " for hero %d" % hero.aim_hero
	return text


func _on_gui_input(event: InputEvent) -> void:
	var press := event as InputEventMouseButton
	if press != null and press.pressed and press.button_index == MOUSE_BUTTON_LEFT:
		get_tree().call_group(&"table", &"hero_clicked", index)
		accept_event()
