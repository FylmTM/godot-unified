class_name MapNode
extends Button
## A node of the act's map (MapView), drawn in code: a disc with its kind's glyph (Glyph.of_node), ringed gold where the
## party stands, faded once passed, lit and growing under the mouse while the party may vote for it, and a dot per vote
## in the voter's colour.

## Its lane (what a vote names).
var lane := 0
## What it holds (an EnumNodeKind value).
var kind := 0
## The party stands here.
var here := false
## A floor the party has climbed past.
var passed := false
## The heroes voting for it, by index.
var votes: Array[int] = []


func _init() -> void:
	flat = true
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state: StringName in [&"normal", &"hover", &"pressed", &"disabled", &"focus", &"hover_pressed"]:
		add_theme_stylebox_override(state, StyleBoxEmpty.new())
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)


func _draw() -> void:
	var centre := size * 0.5
	var open := not disabled
	var hovered := open and is_hovered()
	var radius := size.x * (0.5 if hovered else 0.42)
	var glyph_color := UiTheme.TEXT if open or here else UiTheme.TEXT_DIM
	var fill := Color("33261c")
	if open:
		fill = Color("4a3622") if not hovered else Color("6b4a26")
	if passed:
		glyph_color = Color(UiTheme.TEXT_DIM, 0.45)
		fill = Color("241b15")
	if kind == EnumNodeKind.BOSS:
		radius *= 1.25
		glyph_color = Color("c58bf0") if not passed else glyph_color
	draw_circle(centre + Vector2(0, 3), radius, Color(0, 0, 0, 0.4))
	draw_circle(centre, radius, fill)
	var ring := UiTheme.GOLD if here else (UiTheme.ACCENT if open else UiTheme.LINE)
	draw_arc(centre, radius, 0, TAU, 32, ring, 3.0 if here or hovered else 1.5, true)
	Glyph.draw(self, Glyph.of_node(kind), centre, radius * 0.55, glyph_color)
	for i in votes.size():
		var dot := centre + Vector2((i - (votes.size() - 1) * 0.5) * 11.0, radius + 8.0)
		draw_circle(dot, 5.0, UiTheme.player_color(votes[i]))
