class_name SettingsPanel
extends PanelContainer
## The settings form, in the main menu and the in-game menu: one row per setting the game has (UnifiedSettings).
## Every change applies at once and is saved, except while a slider is dragged: that saves once on release.

signal closed

@onready var _grid: GridContainer = %Grid


func _ready() -> void:
	_name_row()
	_slider_row("Master volume", &"master_volume")
	_slider_row("Effects volume", &"sfx_volume")
	if Settings.has(&"mouse_sensitivity"):
		_slider_row("Mouse sensitivity", &"mouse_sensitivity", 0.2, 3.0)
	if Settings.has(&"invert_y"):
		_check_row("Invert look", &"invert_y")
	_option_row("Window", &"window_mode", ["Windowed", "Fullscreen"])
	_check_row("V-Sync", &"vsync")
	if Settings.has(&"render_scale"):
		_percent_row("3D resolution", &"render_scale", 0.5, 1.0)
	_check_row("Show FPS", &"show_fps")
	(%Path as Label).text = "Saved to " + ProjectSettings.globalize_path(UnifiedSettings.PATH)
	(%Back as Button).pressed.connect(func() -> void:
		Sfx.play(&"click")
		closed.emit())
	visibility_changed.connect(func() -> void:
		if visible:
			(_grid.get_child(1) as Control).grab_focus())


## The input control of the row labelled `text` (for tools), or null.
func control(text: String) -> Control:
	for i in range(0, _grid.get_child_count() - 1, 2):
		if (_grid.get_child(i) as Label).text == text:
			return _grid.get_child(i + 1)
	return null


func _label(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size.x = 160
	_grid.add_child(l)


func _name_row() -> void:
	_label("Player name")
	var e := LineEdit.new()
	e.text = Settings.get_value(&"player_name")
	e.max_length = 16
	e.custom_minimum_size = Vector2(280, 0)
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var commit := func(_t := "") -> void:
		var n := e.text.strip_edges()
		if n != "":
			Settings.set_value(&"player_name", n)
	e.text_submitted.connect(commit)
	e.focus_exited.connect(commit)
	_grid.add_child(e)


func _slider_row(text: String, key: StringName, lo := 0.0, hi := 1.0) -> void:
	_label(text)
	var s := _slider(key, lo, hi)
	s.drag_ended.connect(func(_c: bool) -> void: Sfx.play(&"gem"))
	_grid.add_child(s)


## A slider with its value shown as a percentage next to it.
func _percent_row(text: String, key: StringName, lo: float, hi: float) -> void:
	_label(text)
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var s := _slider(key, lo, hi)
	var v := Label.new()
	v.custom_minimum_size.x = 56
	v.text = "%d%%" % roundi(s.value * 100)
	s.value_changed.connect(func(x: float) -> void: v.text = "%d%%" % roundi(x * 100))
	row.add_child(s)
	row.add_child(v)
	_grid.add_child(row)


func _option_row(text: String, key: StringName, items: Array[String]) -> void:
	_label(text)
	var o := OptionButton.new()
	for it in items:
		o.add_item(it)
	o.selected = Settings.get_value(key)
	o.item_selected.connect(func(i: int) -> void: Settings.set_value(key, i))
	_grid.add_child(o)


func _check_row(text: String, key: StringName) -> void:
	_label(text)
	var c := CheckButton.new()
	c.button_pressed = Settings.get_value(key)
	c.text = "On" if c.button_pressed else "Off"
	c.toggled.connect(func(on: bool) -> void:
		c.text = "On" if on else "Off"
		Settings.set_value(key, on))
	_grid.add_child(c)


## A slider that applies its value live and saves on release when dragged (not on every step), at once for keys and
## pads.
func _slider(key: StringName, lo: float, hi: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 0.05
	s.value = Settings.get_value(key)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var dragging := [false]  # captured by reference in the lambdas
	s.drag_started.connect(func() -> void: dragging[0] = true)
	s.drag_ended.connect(func(_c: bool) -> void:
		dragging[0] = false
		Settings.save())
	s.value_changed.connect(func(x: float) -> void: Settings.set_value(key, x, not dragging[0]))
	return s
