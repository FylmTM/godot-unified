class_name ControlsPanel
extends PanelContainer
## The HUD's controls list, bottom-right: one row per binding, key on the left, action on the right, for the
## device the player is using (keyboard and mouse, or pad). Always shown while playing. The game passes the actions
## for the current context (others while holding something, say); the panel rebuilds only when the rows change.
## Built in code.

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
	get_viewport().size_changed.connect(_place)


## Called by the game's HUD when the context or the input device changes, with [[input, action], ...]: `input` an
## input action, or the actions that make one control, labelled with what they are bound to on the device in use
## (`Game.input_label`); a third element is shown where `input` has no binding on that device ([look, "Look",
## "Mouse"]: mouse look is no action). The panel keeps its corner when the window is resized.
func refresh(rows: Array) -> void:
	var want: Array = []
	for row: Array in rows:
		var fallback: String = row[2] if row.size() > 2 else ""
		want.append([Game.input_label(row[0], fallback), row[1]])
	_place()
	if want == _shown:
		return
	_shown = want
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
