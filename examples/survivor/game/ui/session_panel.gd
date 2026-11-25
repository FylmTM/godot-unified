class_name SessionPanel
extends PanelContainer
## The HUD's session panel, top-right: who is in the session and how friends join.
## In the lobby (a game's gathering phase): a "Lobby" heading, the join code (or LAN address) large with a
## Copy button, the players, and a hint (waiting for a friend, or how to start). While playing: "Players", the code in
## one small line (friends can still join), the players, and a warning while the link to the host is slow (its round
## trip past what the game plays smoothly at). Hidden when solo and offline.
## The game passes its rows; the panel owns the look. Built in code.


## A present player's row, as the game's HUD passes it (refresh).
class Row:
	var player: int
	var player_name: String
	## Beside the name: "ready", "LV 3", "down 4s" ("": none).
	var status: String
	## A bar under the name, 0..1 (HP, say); below 0 there is none.
	var bar: float

	func _init(player_key: int, shown_name: String, status_text := "", bar_fill := -1.0) -> void:
		player = player_key
		player_name = shown_name
		status = status_text
		bar = bar_fill


## The nodes that show one Row.
class RowNodes:
	var box: VBoxContainer
	var dot: ColorRect
	var label: Label
	var status: Label
	var bar: ProgressBar


## One per present player shown so far, in player order (hidden past the rows passed).
var _rows: Array[RowNodes] = []
var _heading: Label
var _code_row: HBoxContainer
var _code_label: Label
var _code: Label
var _copy: Button
var _code_small: Label
var _list: VBoxContainer
var _hint: Label
var _link: Label


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
	_copy.pressed.connect(func() -> void: Game.copy_with_feedback(_copy, Unified.session.join_code))
	_code_row.add_child(_copy)
	_code_small = _label(vbox, &"Dim")
	_code_small.add_theme_font_size_override(&"font_size", 14)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override(&"separation", 6)
	vbox.add_child(_list)
	_hint = _label(vbox, &"Dim")
	_hint.add_theme_font_size_override(&"font_size", 14)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_link = _label(vbox, &"")
	_link.name = &"Link"
	_link.add_theme_font_size_override(&"font_size", 14)
	_link.add_theme_color_override(&"font_color", UiTheme.BAD)
	_link.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_link.visible = false
	Unified.session.link_slow_changed.connect(func(_slow: bool) -> void: _refresh_link())
	visible = false


## Called by the game's HUD when its data, the roster or the code changes: `rows` one per present player, in player
## order. `start_hint`: how a full lobby starts playing.
func refresh(rows: Array[Row], lobby: bool, start_hint: String) -> void:
	visible = Game.is_online() or (lobby and rows.size() > 1)
	if not visible:
		return
	_heading.text = "Lobby" if lobby else "Players"
	var code := Unified.session.join_code
	var is_code := Unified.session.mode != UnifiedSession.MODE_HOST_DIRECT  # a lobby code, else an address
	_code_row.visible = lobby and code != ""
	_code_small.visible = not lobby and code != ""
	if code != "":
		_code_label.text = "Code" if is_code else "LAN"
		_code.text = code
		_code.add_theme_font_size_override(&"font_size", 30 if is_code else 18)
		_code_small.text = "%s  %s" % ["Code" if is_code else "LAN", code]
		# Mouse-look games capture the mouse while playing; the button is only offered when it can be clicked.
		_copy.visible = Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	_refresh_link()
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
		var nodes := _rows[i]
		nodes.box.visible = i < rows.size()
		if not nodes.box.visible:
			continue
		var row := rows[i]
		nodes.dot.color = UiTheme.player_color(Unified.session.get_player_slot(row.player))
		nodes.label.text = row.player_name + (" (you)" if row.player == local_player else "")
		nodes.status.text = row.status
		nodes.bar.visible = row.bar >= 0.0
		nodes.bar.value = row.bar


## The slow link's line: the round trip against the game's ceiling, shown while the session says the link is slow.
func _refresh_link() -> void:
	_link.visible = Unified.session.link_slow
	if _link.visible:
		_link.text = "Slow connection: %d ms to the host (plays smoothly up to %d ms)" % [
			int(Unified.session.round_trip_ms), int(Unified.session.round_trip_ceiling_ms)]


func _label(parent: Control, variation: StringName) -> Label:
	var l := Label.new()
	l.theme_type_variation = variation
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _make_row() -> RowNodes:
	var nodes := RowNodes.new()
	nodes.box = VBoxContainer.new()
	nodes.box.add_theme_constant_override(&"separation", 2)
	var line := HBoxContainer.new()
	line.add_theme_constant_override(&"separation", 8)
	nodes.dot = ColorRect.new()
	nodes.dot.custom_minimum_size = Vector2(12, 12)
	nodes.dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	nodes.dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(nodes.dot)
	nodes.label = _label(line, &"")
	nodes.label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nodes.label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nodes.status = _label(line, &"Dim")
	nodes.bar = ProgressBar.new()
	nodes.bar.custom_minimum_size = Vector2(0, 6)
	nodes.bar.show_percentage = false
	nodes.bar.max_value = 1.0
	nodes.bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nodes.box.add_child(line)
	nodes.box.add_child(nodes.bar)
	_list.add_child(nodes.box)
	return nodes
