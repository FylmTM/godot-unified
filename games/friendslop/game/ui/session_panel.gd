class_name SessionPanel
extends PanelContainer
## The HUD's session panel, top-right: who is in the session and how friends join.
## In the lobby (a game's gathering phase): a "Lobby" heading, the join code (or LAN address) large with a
## Copy button, the players, and a hint (waiting for a friend, or how to start). While playing: "Players", the code in
## one small line (friends can still join), the players. Hidden when solo and offline.
## The game passes its rows; the panel owns the look. Built in code.

## One per present player, in player order: {player: int, name: String, status: String, bar: float (0..1, < 0 hides)}.
var _rows: Array[Dictionary] = []
var _heading: Label
var _code_row: HBoxContainer
var _code_label: Label
var _code: Label
var _copy: Button
var _code_small: Label
var _list: VBoxContainer
var _hint: Label


func _init() -> void:
	name = &"Session"  # stable paths for the UI checks: Session/VBox/CodeRow/Code


func _ready() -> void:
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	custom_minimum_size = Vector2(300, 0)
	offset_left = -320.0
	offset_right = -20.0
	offset_top = 20.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vbox := VBoxContainer.new()
	vbox.name = &"VBox"
	vbox.add_theme_constant_override(&"separation", 8)
	add_child(vbox)
	_heading = _label(vbox, &"Heading")
	_heading.add_theme_font_size_override(&"font_size", 22)
	_code_row = HBoxContainer.new()
	_code_row.name = &"CodeRow"
	vbox.add_child(_code_row)
	_code_label = _label(_code_row, &"Dim")
	_code = _label(_code_row, &"")
	_code.name = &"Code"
	_code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code.add_theme_color_override(&"font_color", UiTheme.CYAN)
	_copy = Button.new()
	_copy.text = "Copy"
	_copy.focus_mode = Control.FOCUS_NONE  # Space and pad A are gameplay, never "press the focused button"
	_copy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_copy.add_theme_font_size_override(&"font_size", 15)
	_copy.pressed.connect(func() -> void: Game.copy_with_feedback(_copy, _code_text().get_slice(",", 0)))
	_code_row.add_child(_copy)
	_code_small = _label(vbox, &"Dim")
	_code_small.add_theme_font_size_override(&"font_size", 14)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override(&"separation", 6)
	vbox.add_child(_list)
	_hint = _label(vbox, &"Dim")
	_hint.add_theme_font_size_override(&"font_size", 14)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	visible = false


## Called by the game's HUD when its data, the roster or the code changes. `rows`: see `_rows`. `start_hint`: how a full lobby starts playing.
func refresh(rows: Array, lobby: bool, start_hint: String) -> void:
	visible = Game.is_online() or (lobby and rows.size() > 1)
	if not visible:
		return
	_heading.text = "Lobby" if lobby else "Players"
	var code := _code_text()
	var is_code := Game.lobby_code != ""
	_code_row.visible = lobby and code != ""
	_code_small.visible = not lobby and code != ""
	if code != "":
		_code_label.text = "Code" if is_code else "LAN"
		_code.text = code
		_code.add_theme_font_size_override(&"font_size", 30 if is_code else 18)
		_code_small.text = "%s  %s" % ["Code" if is_code else "LAN", code]
		# Mouse-look games capture the mouse while playing; the button is only offered when it can be clicked.
		_copy.visible = Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	_hint.visible = lobby
	if lobby:
		if rows.size() < 2:
			match Game.mode:
				Game.Mode.HOST:
					_hint.text = "Waiting for a friend. Share the code; they join from the main menu."
				Game.Mode.HOST_LAN:
					_hint.text = "Waiting for a friend. They pick Join by address and type the address above."
				_:
					_hint.text = "Waiting for players."
		else:
			_hint.text = start_hint
	while _rows.size() < rows.size():
		_rows.append(_make_row())
	var local_player := Unified.session.local_player
	for i in _rows.size():
		var row := _rows[i]
		row.box.visible = i < rows.size()
		if not row.box.visible:
			continue
		var r: Dictionary = rows[i]
		var player: int = r["player"]
		var player_name: String = r["name"]
		row.dot.color = UiTheme.player_color(Unified.session.get_player_slot(player))
		row.name.text = player_name + (" (you)" if player == local_player else "")
		row.status.text = r.get("status", "")
		var bar: float = r.get("bar", -1.0)
		row.bar.visible = bar >= 0.0
		row.bar.value = bar


func _code_text() -> String:
	return Game.lobby_code if Game.lobby_code != "" else Game.lan_address


func _label(parent: Control, variation: StringName) -> Label:
	var l := Label.new()
	l.theme_type_variation = variation
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _make_row() -> Dictionary:
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 2)
	var line := HBoxContainer.new()
	line.add_theme_constant_override(&"separation", 8)
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(12, 12)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(dot)
	var label := _label(line, &"")
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var status := _label(line, &"Dim")
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 6)
	bar.show_percentage = false
	bar.max_value = 1.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(line)
	box.add_child(bar)
	_list.add_child(box)
	return {"box": box, "dot": dot, "name": label, "status": status, "bar": bar}
