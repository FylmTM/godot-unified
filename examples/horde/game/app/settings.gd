extends Node
## horde's player settings (the `Settings` autoload): typed properties, loaded from user://settings.cfg at boot and
## applied as they are set. Each `@export` var is a setting, its `@export_category` its section in the file; a change
## is saved a moment later (one write for a slider's drag). The settings panel shows a row for each one in LABELS,
## built from its type and hint, or from the sim's enum class for one in SIM_ENUMS. Tool scripts run with `--no-settings`: defaults, nothing read or written, no window
## changes.

## A setting changed (its property's name).
signal changed(setting: StringName)

enum WindowMode { WINDOWED, FULLSCREEN }

const PATH := "user://settings.cfg"
## The settings the panel shows, in this order, with their row labels.
const LABELS: Dictionary[StringName, String] = {
	&"player_name": "Player name",
	&"master_volume": "Master volume",
	&"sfx_volume": "Effects volume",
	&"window_mode": "Window",
	&"vsync": "V-Sync",
	&"show_fps": "Show FPS",
}
## The settings that hold a sim enum's value, with its class: none here.
const SIM_ENUMS: Dictionary[StringName, StringName] = {}

@export_category("player")
@export var player_name := "":
	set(value):
		player_name = value
		_changed(&"player_name")

@export_category("audio")
## Linear, 0..1.
@export_range(0.0, 1.0, 0.05) var master_volume := 0.8:
	set(value):
		master_volume = value
		_set_bus_volume(&"Master", value)
		_changed(&"master_volume")
@export_range(0.0, 1.0, 0.05) var sfx_volume := 0.8:
	set(value):
		sfx_volume = value
		_set_bus_volume(&"SFX", value)
		_changed(&"sfx_volume")

@export_category("video")
@export var window_mode := WindowMode.WINDOWED:
	set(value):
		window_mode = value
		if _apply_window:
			var mode := (DisplayServer.WINDOW_MODE_FULLSCREEN if value == WindowMode.FULLSCREEN
				else DisplayServer.WINDOW_MODE_WINDOWED)
			if DisplayServer.window_get_mode() != mode:
				DisplayServer.window_set_mode(mode)
		_changed(&"window_mode")
@export var vsync := true:
	set(value):
		vsync = value
		if _apply_window:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if value else DisplayServer.VSYNC_DISABLED)
		_changed(&"vsync")
@export var show_fps := false:
	set(value):
		show_fps = value
		_changed(&"show_fps")

@export_category("stats")
## The furthest wave a match this player played reached (the HUD raises it when a match's end is confirmed).
@export var best_wave := 0:
	set(value):
		best_wave = value
		_changed(&"best_wave")

var _isolated := false
var _apply_window := false
var _loading := true
var _save_timer: Timer


func _ready() -> void:
	_isolated = "--no-settings" in OS.get_cmdline_user_args()
	_apply_window = not _isolated and DisplayServer.get_name() != "headless"
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.3
	_save_timer.timeout.connect(save)
	add_child(_save_timer)
	var cfg := ConfigFile.new()
	if not _isolated:
		cfg.load(PATH)  # a missing file means defaults
	var sections := _sections()
	for setting: StringName in sections:
		var value: Variant = get(setting)
		var saved: Variant = cfg.get_value(sections[setting], setting, value)
		set(setting, saved if typeof(saved) == typeof(value) else value)  # applies it
	if player_name.strip_edges() == "":
		player_name = _default_name()
	_loading = false


func _exit_tree() -> void:
	if not _save_timer.is_stopped():
		save()


## Writes every setting to the file now (a change does it by itself a moment later).
func save() -> void:
	_save_timer.stop()
	if _isolated:
		return
	var cfg := ConfigFile.new()
	var sections := _sections()
	for setting: StringName in sections:
		cfg.set_value(sections[setting], setting, get(setting))
	cfg.save(PATH)


## Every setting (an exported property) with the category it is under: its section in the file.
func _sections() -> Dictionary[StringName, String]:
	var out: Dictionary[StringName, String] = {}
	var section := ""
	for property in get_property_list():
		var usage: int = property["usage"]
		var property_name: String = property["name"]
		if usage & PROPERTY_USAGE_CATEGORY:
			section = property_name
		elif usage & PROPERTY_USAGE_SCRIPT_VARIABLE and usage & PROPERTY_USAGE_EDITOR and section != "":
			out[StringName(property_name)] = section
	return out


func _changed(setting: StringName) -> void:
	if _loading:
		return
	changed.emit(setting)
	_save_timer.start()


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
