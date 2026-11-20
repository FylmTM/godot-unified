class_name HeroPanel
extends PanelContainer
## One hero of the run (Unified.data.heroes.heroes[index]): their player, HP, block, energy, statuses, relics, whether
## they ended their turn or sleep, what they aim at (their Input, live), and their hand, open to everyone (an ally's
## cards, small; the local hero's are in the big hand below). Hits, heals and block flash on their events (main.gd).

const COLORS: Array[Color] = [Color(1, 0.45, 0.4), Color(0.5, 1, 0.45), Color(0.4, 0.85, 1), Color(0.85, 0.5, 1)]

@export var index := 0

var _style := StyleBoxFlat.new()

@onready var _name: Label = %Name
@onready var _hp: ProgressBar = %HP
@onready var _stats: Label = %Stats
@onready var _aim: Label = %Aim
@onready var _hand: HFlowContainer = %Hand


func _ready() -> void:
	_style.bg_color = Color(0.14, 0.15, 0.18)
	_style.set_corner_radius_all(8)
	_style.set_content_margin_all(8)
	_style.border_color = COLORS[index]
	add_theme_stylebox_override(&"panel", _style)
	_hp.add_theme_stylebox_override(&"fill", Bars.fill(Color(0.3, 0.7, 0.3)))
	_hp.add_theme_stylebox_override(&"background", Bars.fill(Color(0.1, 0.1, 0.1)))
	_hand.add_to_group(StringName("hand_%d" % index))
	gui_input.connect(_on_gui_input)
	mouse_entered.connect(func() -> void: get_tree().call_group(&"table", &"hero_hovered", index))
	Unified.data.heroes.changed.connect(refresh)
	refresh()


func row() -> DataHeroRow:
	return Unified.data.heroes.heroes[index]


func refresh() -> void:
	var hero := row()
	visible = hero.in_run
	if not hero.in_run:
		return
	var player_name := Unified.session.get_player_name(hero.player) if hero.awake else ""
	if player_name == "":
		player_name = "Hero %d" % (index + 1)
	_name.text = "%s - %s%s" % [player_name, EnumHeroClass.name(hero.hero_class).capitalize(),
		"" if hero.awake else " (asleep)"]
	_hp.max_value = maxi(hero.max_hp, 1)
	_hp.value = hero.hp
	var stats := "%d/%d HP   %d block   %d energy" % [hero.hp, hero.max_hp, hero.block, hero.energy]
	stats += "   draw %d  discard %d" % [hero.draw, hero.discard]
	if hero.strength != 0:
		stats += "\nStrength %d" % hero.strength
	if hero.weak > 0:
		stats += "  Weak %d" % hero.weak
	if hero.vulnerable > 0:
		stats += "  Vulnerable %d" % hero.vulnerable
	if not hero.relics.is_empty():
		var names: Array[String] = []
		for relic: int in hero.relics:
			names.append(EnumRelic.name(relic).capitalize())
		stats += "\nRelics: " + ", ".join(names)
	_stats.text = stats
	_aim.text = _aim_text(hero)
	_style.set_border_width_all(4 if hero.local else 2)
	modulate = Color(0.55, 0.55, 0.55) if hero.down or not hero.awake else Color.WHITE
	if hero.ready:
		_name.text += "  [ready]"


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


## A hit, a heal or block: a short flash of its colour.
func flash(color: Color) -> void:
	modulate = color
	create_tween().tween_property(self, ^"modulate", Color.WHITE, 0.3)


func _on_gui_input(event: InputEvent) -> void:
	var press := event as InputEventMouseButton
	if press != null and press.pressed and press.button_index == MOUSE_BUTTON_LEFT:
		get_tree().call_group(&"table", &"hero_clicked", index)
