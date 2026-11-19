class_name SettingsPanel
extends PanelContainer
## The settings form, in the main menu and the in-game menu: a row for each setting in `Settings.LABELS`, its control
## from the property's type and hint (a name field, a check button, an option list for an enum or a sim enum's class
## in `Settings.SIM_ENUMS`, a slider for a range). Every change applies at once; the Settings autoload saves it.

signal closed

@onready var _grid: GridContainer = %Grid


func _ready() -> void:
	var properties: Dictionary[String, Dictionary] = {}
	for property in Settings.get_property_list():
		var property_name: String = property["name"]
		properties[property_name] = property
	for setting: StringName in Settings.LABELS:
		_row(Settings.LABELS[setting], setting, properties[String(setting)])
	(%Path as Label).text = "Saved to " + ProjectSettings.globalize_path(Settings.PATH)
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


func _row(text: String, setting: StringName, property: Dictionary) -> void:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = 160
	_grid.add_child(label)
	var hint: int = property["hint"]
	var hint_string: String = property["hint_string"]
	match property["type"]:
		TYPE_STRING:
			_grid.add_child(_name_field(setting))
		TYPE_BOOL:
			_grid.add_child(_check(setting))
		TYPE_INT when Settings.SIM_ENUMS.has(setting):  # its class's names(), in value order
			var names: Array = ClassDB.class_call_static(Settings.SIM_ENUMS[setting], &"names")
			_grid.add_child(_options(setting, PackedStringArray(names)))
		TYPE_INT when hint == PROPERTY_HINT_ENUM:
			_grid.add_child(_options(setting, hint_string.split(",")))
		TYPE_FLOAT when hint == PROPERTY_HINT_RANGE:
			_grid.add_child(_slider(setting, hint_string.split(",")))
		_:
			push_error("SettingsPanel: no control for the setting %s" % setting)


## A name: a blank one is not taken.
func _name_field(setting: StringName) -> LineEdit:
	var edit := LineEdit.new()
	edit.text = Settings.get(setting)
	edit.max_length = 16
	edit.custom_minimum_size = Vector2(280, 0)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var commit := func(_text := "") -> void:
		var entered := edit.text.strip_edges()
		if entered != "":
			Settings.set(setting, entered)
	edit.text_submitted.connect(commit)
	edit.focus_exited.connect(commit)
	return edit


func _check(setting: StringName) -> CheckButton:
	var check := CheckButton.new()
	check.button_pressed = Settings.get(setting)
	check.text = "On" if check.button_pressed else "Off"
	check.toggled.connect(func(on: bool) -> void:
		check.text = "On" if on else "Off"
		Settings.set(setting, on))
	return check


## An enum's members (a hint's "Windowed,Fullscreen", each optionally ":value"; a class's names()), by value.
func _options(setting: StringName, members: PackedStringArray) -> OptionButton:
	var options := OptionButton.new()
	for member in members:
		options.add_item(member.get_slice(":", 0).capitalize())
	options.selected = Settings.get(setting)
	options.item_selected.connect(func(i: int) -> void: Settings.set(setting, i))
	return options


## A range (its hint: "min,max,step[,suffix:%]"): a slider; with a % suffix, its value shown as a percentage beside it.
func _slider(setting: StringName, hint: PackedStringArray) -> Control:
	var slider := HSlider.new()
	slider.min_value = float(hint[0])
	slider.max_value = float(hint[1])
	slider.step = float(hint[2]) if hint.size() > 2 else 0.05
	slider.value = Settings.get(setting)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.value_changed.connect(func(value: float) -> void: Settings.set(setting, value))
	slider.drag_ended.connect(func(_changed: bool) -> void: Sfx.play(&"gem"))
	if "suffix:%" not in hint:
		return slider
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var shown := Label.new()
	shown.custom_minimum_size.x = 56
	shown.text = "%d%%" % roundi(slider.value * 100)
	slider.value_changed.connect(func(value: float) -> void: shown.text = "%d%%" % roundi(value * 100))
	row.add_child(slider)
	row.add_child(shown)
	return row
