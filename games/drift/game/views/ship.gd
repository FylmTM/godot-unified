extends Node2D
## A player's ship, drawn in code. The host sets the root's position (pixels) and rotation (the heading: 0 = +x,
## the nose) and the Ship_View data below; everything else is view-only: the hull in the colour of the player's slot,
## a flame while thrusting, a ring that fills while boost recharges, a squash on shots and boosts, a muzzle flash, a
## warp flash, a name tag over other players' ships, and a shrink when the ship leaves. The view outlives a leave:
## a player who comes back (in any slot) gets it back, in their new slot's colour.

## The view's marker: `player` is the ship's player's key (set by the host before _ready).
@onready var view: UnifiedView = %UnifiedView

## Ship_View (simulation/extension), set by the host when it changes.
var boost_ready := 1.0:  ## 0 just boosted .. 1 ready
	set(v):
		if v >= 1.0 and boost_ready < 1.0:
			_ready_pulse = 1.0
		boost_ready = v
var thrust := false

var _r := 16.0  ## the sim's ship radius, in pixels
var _color := Color.WHITE
var _slot := -1  ## the slot _color is for
var _squash := 0.0  ## > 0 stretches along the heading, < 0 squashes
var _muzzle := 0.0
var _warp := 0.0
var _ready_pulse := 0.0
var _leaving := 0.0  ## 0 here .. 1 gone (despawned, lingering)
var _gone := false
var _t := 0.0
var _tag: Label


func _ready() -> void:
	view.despawned.connect(func() -> void: _gone = true)
	view.revived.connect(func() -> void: _gone = false)
	z_index = 2
	var radius: float = Game.constants.get("ship_radius", 0.5)
	_r = radius * Game.px_per_m
	_tag = Label.new()
	_tag.top_level = true  # never turns with the ship
	_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tag.custom_minimum_size = Vector2(160, 0)
	_tag.add_theme_font_size_override(&"font_size", 13)
	_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_tag)
	_follow_slot()
	_warp = 1.0  # a spawn flash


func _process(delta: float) -> void:
	_t += delta
	_squash = move_toward(_squash, 0.0, delta * 5.0)
	_muzzle = maxf(_muzzle - delta * 12.0, 0.0)
	_warp = maxf(_warp - delta * 2.5, 0.0)
	_ready_pulse = maxf(_ready_pulse - delta * 3.0, 0.0)
	_leaving = move_toward(_leaving, 1.0 if _gone else 0.0, delta * 4.0)
	_follow_slot()
	var local := view.player == Game.local_player()
	_tag.visible = not local and _leaving < 0.5
	if _tag.visible:
		var tag := Game.player_name({"player": view.player})  # the synced name, else "P<slot + 1>"
		if _tag.text != tag:
			_tag.text = tag
		_tag.global_position = global_position + Vector2(-80, -_r - 26)
	queue_redraw()


func _draw() -> void:
	var s := (1.0 - _leaving)
	if s <= 0.0:
		return
	var stretch := 1.0 + _squash * 0.3
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(stretch, 1.0 / stretch) * s)
	var r := _r
	# boost: a faint ring that fills as it recharges, bright for a moment when ready
	var ring_r := r * 1.55
	if boost_ready < 1.0:
		draw_arc(Vector2.ZERO, ring_r, -PI / 2.0, -PI / 2.0 + TAU * boost_ready, 32, Color(_color, 0.45), 2.0, true)
	else:
		draw_arc(Vector2.ZERO, ring_r, 0.0, TAU, 32, Color(_color, 0.18 + 0.6 * _ready_pulse),
			1.5 + 2.0 * _ready_pulse, true)
	# thrust flame behind the hull, flickering
	if thrust:
		var f := 0.8 + 0.25 * sin(_t * 47.0) + 0.15 * sin(_t * 31.0)
		var flame := PackedVector2Array([Vector2(-r * 0.55, -r * 0.38), Vector2(-r * (0.9 + 0.75 * f), 0),
			Vector2(-r * 0.55, r * 0.38)])
		draw_colored_polygon(flame, Color(1.0, 0.72, 0.3, 0.9))
		var core := PackedVector2Array([Vector2(-r * 0.55, -r * 0.2), Vector2(-r * (0.75 + 0.35 * f), 0),
			Vector2(-r * 0.55, r * 0.2)])
		draw_colored_polygon(core, Color(1.0, 0.95, 0.8))
	# hull: a dart, nose along +x
	var hull := PackedVector2Array([Vector2(r * 1.25, 0), Vector2(-r * 0.8, -r * 0.85), Vector2(-r * 0.45, 0),
		Vector2(-r * 0.8, r * 0.85)])
	draw_colored_polygon(hull, _color)
	var outline := hull.duplicate()
	outline.append(hull[0])
	draw_polyline(outline, _color.lightened(0.45), 1.5, true)
	draw_circle(Vector2(r * 0.25, 0), r * 0.22, _color.darkened(0.45))
	# muzzle flash at the nose
	if _muzzle > 0.0:
		draw_circle(Vector2(r * 1.45, 0), r * 0.35 * _muzzle, Color(1, 1, 0.85, _muzzle))
	# warp (and spawn) flash: a ring expanding from the ship
	if _warp > 0.0:
		draw_arc(Vector2.ZERO, r * (1.0 + (1.0 - _warp) * 2.5), 0.0, TAU, 32, Color(UiTheme.CYAN, _warp), 3.0, true)


## Effects play once, when an event is first shown (predicted, or confirmed when nothing predicted it); a
## cancelled one has already played and is left as is.
func _sim_event(event: UnifiedEvent, state: int) -> void:
	if state != UnifiedSession.EVENT_EMITTED:
		return
	var local := view.player == Game.local_player()
	match event.kind:
		"fired":
			_muzzle = 1.0
			_squash = minf(_squash, -0.25)
			Sfx.play(&"fire", -12.0 if local else -18.0, randf_range(0.95, 1.08))
		"boosted":
			_squash = 1.0
			Sfx.play(&"boost", -4.0 if local else -10.0)
			if local:
				Game.rumble(0.3, 0.2, 0.12)
		"warped":
			_warp = 1.0
			Sfx.play(&"warp", -4.0)
		"gem_picked":
			_ready_pulse = 1.0
		"spawned":
			_warp = 1.0


## The hull and tag in the colour of the slot the player holds (kept while they are away: the view lingers).
func _follow_slot() -> void:
	var slot := Game.player_slot(view.player)
	if slot < 0 or slot == _slot:
		return
	_slot = slot
	_color = UiTheme.player_color(slot)
	_tag.add_theme_color_override(&"font_color", _color.lightened(0.35))
