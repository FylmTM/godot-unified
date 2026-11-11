extends PanelContainer
## Settings form, used by the main menu and the in-game menu. Every change applies at once and is saved, except
## while a slider is dragged: that saves once on release.

signal closed

@onready var _grid: GridContainer = $VBox/Grid


func _ready() -> void:
	_name_row()
	_slider_row("Master volume", &"master_volume")
	_slider_row("Effects volume", &"sfx_volume")
	_option_row("Window", &"window_mode", ["Windowed", "Fullscreen"])
	_check_row("V-Sync", &"vsync")
	_scale_row()
	_check_row("Show FPS", &"show_fps")
	$VBox/Path.text = "Saved to " + ProjectSettings.globalize_path(Settings.PATH)
	$VBox/Back.pressed.connect(func() -> void:
		Sfx.play(&"click")
		closed.emit())
	visibility_changed.connect(func() -> void:
		if visible:
			_grid.get_child(1).grab_focus())


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


func _slider_row(text: String, key: StringName) -> void:
	_label(text)
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.05
	s.value = Settings.get_value(key)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_live_slider(s, key)
	s.drag_ended.connect(func(_c: bool) -> void: Sfx.play(&"gem"))
	_grid.add_child(s)


func _option_row(text: String, key: StringName, items: Array) -> void:
	_label(text)
	var o := OptionButton.new()
	for it: String in items:
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


func _scale_row() -> void:
	_label("3D resolution")
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var s := HSlider.new()
	s.min_value = 0.5
	s.max_value = 1.0
	s.step = 0.05
	s.value = Settings.get_value(&"render_scale")
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var v := Label.new()
	v.custom_minimum_size.x = 56
	v.text = "%d%%" % roundi(s.value * 100)
	s.value_changed.connect(func(x: float) -> void: v.text = "%d%%" % roundi(x * 100))
	_live_slider(s, &"render_scale")
	row.add_child(s)
	row.add_child(v)
	_grid.add_child(row)


## Applies a slider's value live; saves on release when dragged (not on every step), at once for keys and pads.
func _live_slider(s: HSlider, key: StringName) -> void:
	var dragging := [false]  # captured by reference in the lambdas
	s.drag_started.connect(func() -> void: dragging[0] = true)
	s.drag_ended.connect(func(_c: bool) -> void:
		dragging[0] = false
		Settings.save())
	s.value_changed.connect(func(x: float) -> void: Settings.set_value(key, x, not dragging[0]))
