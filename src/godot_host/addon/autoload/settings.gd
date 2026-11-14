class_name UnifiedSettings
extends Node
## Player settings, the base of a game's `Settings` autoload: loaded from user://settings.cfg at boot, applied at
## once, saved on change. Read with `Settings.get_value(key)`; change with `Settings.set_value(key, v)` (applies
## and saves; `persist = false` applies only, e.g. while a slider is dragged, then `save()`).
##
## Every game has the library's keys (DEFAULTS). A game adds its own in `_game_keys()`: a stat it keeps, or one of
## the standard optional keys (OPTIONAL), each of which the settings panel shows as a row when the game has it.
## Tool scripts run with `--no-settings`: defaults, nothing read or written, no window changes.

signal changed(key: StringName, value: Variant)

const PATH := "user://settings.cfg"
const WINDOWED := 0
const FULLSCREEN := 1

## key -> [config section, default]. Volumes are linear 0..1.
const DEFAULTS := {
	&"master_volume": ["audio", 0.8],
	&"sfx_volume": ["audio", 0.8],
	&"window_mode": ["video", WINDOWED],
	&"vsync": ["video", true],
	&"show_fps": ["video", false],
	&"player_name": ["player", ""],
}
## Standard keys a game may add, with their defaults: the 3D resolution scale (3D games) and mouse look.
const OPTIONAL := {
	&"render_scale": ["video", 1.0],
	&"mouse_sensitivity": ["input", 1.0],
	&"invert_y": ["input", false],
}

## key -> [config section, default]: DEFAULTS plus the game's keys.
var _keys := {}
var _values := {}
var _isolated := false
var _apply_window := true


func _ready() -> void:
	_isolated = "--no-settings" in OS.get_cmdline_user_args()
	_apply_window = not _isolated and DisplayServer.get_name() != "headless"
	_keys = DEFAULTS.duplicate()
	_keys.merge(_game_keys())
	var cfg := ConfigFile.new()
	if not _isolated:
		cfg.load(PATH)  # a missing file means defaults
	for key: StringName in _keys:
		var d: Array = _keys[key]
		var v: Variant = cfg.get_value(d[0], key, d[1])
		_values[key] = v if typeof(v) == typeof(d[1]) else d[1]
	if String(_values[&"player_name"]).strip_edges() == "":
		_values[&"player_name"] = _default_name()
	for key: StringName in _values:
		_apply(key)


## The game's own keys, key -> [config section, default]: its stats, and those of OPTIONAL it uses.
func _game_keys() -> Dictionary:
	return {}


func has(key: StringName) -> bool:
	return _values.has(key)


func get_value(key: StringName) -> Variant:
	return _values[key]


func set_value(key: StringName, value: Variant, persist := true) -> void:
	if _values.get(key) == value:
		return
	_values[key] = value
	_apply(key)
	if persist:
		save()
	changed.emit(key, value)


func save() -> void:
	if _isolated:
		return
	var cfg := ConfigFile.new()
	for key: StringName in _values:
		cfg.set_value(_keys[key][0], key, _values[key])
	cfg.save(PATH)


func _apply(key: StringName) -> void:
	var v: Variant = _values[key]
	match key:
		&"master_volume":
			_set_bus_volume(&"Master", v)
		&"sfx_volume":
			_set_bus_volume(&"SFX", v)
		&"window_mode":
			if _apply_window:
				var mode := (DisplayServer.WINDOW_MODE_FULLSCREEN if v == FULLSCREEN
					else DisplayServer.WINDOW_MODE_WINDOWED)
				if DisplayServer.window_get_mode() != mode:
					DisplayServer.window_set_mode(mode)
		&"vsync":
			if _apply_window:
				DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if v else DisplayServer.VSYNC_DISABLED)
		&"render_scale":
			# the UI always renders at full resolution
			get_viewport().scaling_3d_scale = clampf(v, 0.5, 1.0)


static func _set_bus_volume(bus: StringName, linear: float) -> void:
	var i := AudioServer.get_bus_index(bus)
	if i < 0:
		return
	AudioServer.set_bus_volume_db(i, linear_to_db(maxf(linear, 0.0001)))
	AudioServer.set_bus_mute(i, linear <= 0.001)


static func _default_name() -> String:
	var user := OS.get_environment("USER") if OS.has_environment("USER") else OS.get_environment("USERNAME")
	user = user.strip_edges().left(16)
	return user if user != "" else "Player"
