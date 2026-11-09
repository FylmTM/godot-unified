class_name ControlsPanel
extends PanelContainer
## The HUD's controls list, bottom-right, the same in every game: one row per binding, key on the left, action on
## the right, for whichever device the player is using (keyboard and mouse, or pad). Always shown while playing.
## The game passes the bindings for the current context (e.g. different keys while holding something); the panel
## rebuilds only when they change. Built in code; this file is identical in every game.

const MARGIN := 20.0

var _grid: GridContainer
var _shown: Array = []


func _init() -> void:
	name = &"Controls"


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := UiTheme.box(Color(UiTheme.PANEL, 0.8), 10, 0, Color(0, 0, 0, 0))
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	add_theme_stylebox_override(&"panel", style)
	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override(&"h_separation", 14)
	_grid.add_theme_constant_override(&"v_separation", 2)
	add_child(_grid)
	minimum_size_changed.connect(_place)  # the new rows' size is known a frame after they are added


## Called every frame by the game's HUD with [[key, action], ...] for each device; shows the one in use.
func refresh(keys: Array, pad: Array) -> void:
	var want: Array = pad if Game.using_pad else keys
	_place()  # every frame too: the window may have been resized
	if want == _shown:
		return
	_shown = want.duplicate(true)
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.free()
	for pair: Array in want:
		var key := Label.new()
		key.text = pair[0]
		key.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		key.add_theme_font_size_override(&"font_size", 15)
		_grid.add_child(key)
		var action := Label.new()
		action.text = pair[1]
		action.theme_type_variation = &"Dim"
		action.add_theme_font_size_override(&"font_size", 15)
		_grid.add_child(action)


## Fit to the content, MARGIN px from the bottom-right corner. Placed by hand: anchors would not shrink it.
func _place() -> void:
	size = get_combined_minimum_size()
	position = get_parent_area_size() - size - Vector2(MARGIN, MARGIN)
