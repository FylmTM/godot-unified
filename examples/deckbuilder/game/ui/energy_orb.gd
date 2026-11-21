class_name EnergyOrb
extends Control
## The local hero's energy at the hand's left, drawn in code: a glowing orb with the energy left, dimmed at none, and a
## pulse when it changes; their draw and discard piles' counts under it.

const SIZE := Vector2(130, 150)
const CENTRE := Vector2(65, 58)
const RADIUS := 42.0

var _energy := -1
var _draw_pile := 0
var _discard := 0
var _pulse := 0.0
var _font: Font = UiTheme.serif(800)
var _body_font: Font = ThemeDB.fallback_font


func _ready() -> void:
	custom_minimum_size = SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	if _pulse > 0.0:
		_pulse = move_toward(_pulse, 0.0, delta * 2.5)
		queue_redraw()


## Shows the local hero's energy and pile counts.
func show_hero(hero: DataHeroRow) -> void:
	if hero.energy != _energy and _energy >= 0:
		_pulse = 1.0
	_energy = hero.energy
	_draw_pile = hero.draw
	_discard = hero.discard
	queue_redraw()


func _draw() -> void:
	if _energy < 0:
		return
	var lit := _energy > 0
	var core := Color("f2c060") if lit else Color("6e5e4a")
	var radius := RADIUS * (1.0 + 0.08 * _pulse)
	draw_circle(CENTRE + Vector2(0, 5), radius, Color(0, 0, 0, 0.45))
	if lit:
		for i in 4:
			draw_circle(CENTRE, radius + 10.0 - i * 3.0, Color(core, 0.05 + 0.04 * i))
	draw_circle(CENTRE, radius, Color("2a1f17"))
	draw_circle(CENTRE, radius - 5, core.darkened(0.45))
	draw_circle(CENTRE - Vector2(0, radius * 0.25), radius * 0.6, Color(core, 0.35))
	draw_arc(CENTRE, radius - 2, 0, TAU, 48, Color("b8893a"), 3.0, true)
	draw_string(_font, CENTRE + Vector2(-40, 16), str(_energy), HORIZONTAL_ALIGNMENT_CENTER, 80, 44, Color.WHITE)
	draw_string(_body_font, Vector2(0, CENTRE.y + RADIUS + 26), "draw %d   discard %d" % [_draw_pile, _discard],
		HORIZONTAL_ALIGNMENT_CENTER, SIZE.x, 13, UiTheme.TEXT_DIM)
