class_name UnifiedTool
extends SceneTree
## The base of every tool script (`uni tool <game> <name>`, the godot suite's steps), run with Godot's `-s`. It
## drives the real game the way a player would and reports one `UNIFIED_RESULT {json}` line, which uni judges
## strictly: any engine or script error fails the run.
##
## A script overrides `_run()` (a coroutine, started on the first frame, once the autoloads exist), reports with
## `step()`, `expect()` and `fail()`, and may `finish()` early. A failure ends the run at once: every wait returns and
## every input helper does nothing after it. The result carries `ok`, `ms`, `steps`, `failed`, `errors` and what the
## script adds to `result` (`uni tool` prints those on its result line: the way to read a value out of Godot). The
## run ends through the game's own quit when it has a Game autoload with `quit_app(exit_code)`, else `quit()`. A
## headless run's window is the project's window size (Godot's headless one is 64x64), so a UI lays out as a player
## sees it.
## unified's library tooling (src/godot/README.md, Library tooling), at res://unified/tools_godot/ in every project.
## It knows no game's menus: a game drives its own UI from its tool scripts (game/tools/).
##
## Arguments come after `--`: `arg("name")` reads `--name=value` (or `--name value`), `flag("name")` `--name`. Every
## tool takes `--shots=<dir>` (PNGs from `shot()`, a windowed run) and `--frames` (frame times and first-use hitches,
## UnifiedFrameLog; a script tags its own moments with `frame_tag()`).

## The Game autoload, when the game has one. Untyped on purpose: a `-s` script compiles before the autoloads exist,
## so it names no script that uses them.
var game: Node
## The game's UnifiedSession (`Unified.session`: null until a session node is in the tree, e.g. before the main
## scene of a game that keeps it there is loaded).
var session: UnifiedSession:
	get:
		return Unified.session
## Engine and script errors and warnings, collected in-process.
var log_capture := UnifiedLogCapture.new()
## Where `shot()` saves PNGs (`--shots=<dir>`, a windowed run); empty: no shots.
var shots_dir := ""
## Extra data for the result line.
var result := {}
## A prefix for printed steps (coop: the role).
var tag := ""
## Frame times, with `--frames` (else null).
var frame_log: UnifiedFrameLog

var _steps: Array[Dictionary] = []
var _failed := ""
var _done := false
var _started := false
var _t0 := 0


func _init() -> void:
	OS.add_logger(log_capture)
	shots_dir = arg("shots")
	if flag("frames"):
		frame_log = UnifiedFrameLog.new()


func _process(_delta: float) -> bool:
	if frame_log != null:
		frame_log.frame()
	if not _started:
		_started = true
		_t0 = Time.get_ticks_msec()
		_size_headless_window()  # here: the engine sets the root's size once more after _init and _initialize
		_start()
	return false


## The script's work. Returning finishes the run.
func _run() -> void:
	pass


# --- Arguments ---------------------------------------------------------------------------------------------------


func arg(arg_name: String, default := "") -> String:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i].begins_with("--%s=" % arg_name):
			return args[i].get_slice("=", 1)
		if args[i] == "--" + arg_name and i + 1 < args.size() and not args[i + 1].begins_with("--"):
			return args[i + 1]
	return default


func flag(arg_name: String) -> bool:
	return ("--" + arg_name) in OS.get_cmdline_user_args()


# --- Reporting ---------------------------------------------------------------------------------------------------


func failed() -> bool:
	return _failed != ""


func step(what: String) -> void:
	if failed():
		return
	var ms := Time.get_ticks_msec() - _t0
	_steps.append({"step": what, "ms": ms})
	frame_tag("step: " + what)
	print("  %s ok %6d ms  %s" % [tag, ms, what] if tag != "" else "  ok %6d ms  %s" % [ms, what])


## Tags this frame in the `--frames` log, as "FIRST <t>" the first time (no-op without `--frames`).
func frame_tag(t: String) -> void:
	if frame_log != null:
		frame_log.tag_first(t)


func expect(cond: bool, what: String) -> void:
	if not cond:
		fail("expected: " + what)


## Records the failure and ends the run.
func fail(why: String) -> void:
	if failed():
		return
	_failed = why
	print("  %s FAIL  %s" % [tag, why] if tag != "" else "  FAIL  " + why)
	finish()


## Prints the result and quits through the game (the session ends, sounds stop first). Runs once.
func finish() -> void:
	if _done:
		return
	_done = true
	var ok := not failed() and log_capture.errors.is_empty()
	var ms := Time.get_ticks_msec() - _t0
	var own_script: Script = get_script()
	var script_name := own_script.resource_path.get_file().get_basename()
	print("%s%s: %d steps, %s in %d ms" % [script_name, " " + tag if tag != "" else "", _steps.size(),
		"OK" if ok else "FAILED", ms])
	if not log_capture.errors.is_empty() or not log_capture.warnings.is_empty():
		print(log_capture.report())
	if frame_log != null:
		result["frames"] = frame_log.report()
	var out := {"ok": ok, "ms": ms, "steps": _steps, "failed": _failed, "errors": log_capture.errors}
	out.merge(result)
	print("UNIFIED_RESULT " + JSON.stringify(out))
	OS.remove_logger(log_capture)
	if game != null and game.has_method(&"quit_app"):
		game.call(&"quit_app", 0 if ok else 1)
	else:
		quit(0 if ok else 1)


# --- Waiting -----------------------------------------------------------------------------------------------------


func frames(n: int) -> void:
	for i in n:
		await process_frame


func seconds(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end and not failed():
		await process_frame


## Waits until `cond` holds; fails after `timeout_s` with "timed out: <what>".
func wait_for(cond: Callable, timeout_s: float, what: String) -> void:
	var end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not failed():
		if cond.call():
			return
		if Time.get_ticks_msec() > end:
			fail("timed out (%.1f s): %s" % [timeout_s, what])
			return
		await process_frame


func wait_for_scene(scene_name: String, timeout_s: float) -> void:
	await wait_for(func() -> bool: return scene_is(scene_name), timeout_s, "the %s scene" % scene_name)


# --- Input, as a player gives it ---------------------------------------------------------------------------------


## A real click of `button` on the control's centre: motion, press and release (click_at).
func click(c: Control, button := MOUSE_BUTTON_LEFT) -> void:
	if c == null or failed():
		return
	if not c.is_visible_in_tree():
		fail("cannot click hidden " + str(c.get_path()))
		return
	var pos := c.get_viewport().get_final_transform() * (c.get_global_transform_with_canvas() * (c.size / 2.0))
	await click_at(pos, button)


## A real click of `button` at `pos`, in window coordinates (what `click` aims at, and an InputEventMouse's
## `position`): motion, then press and release a frame apart, each through the event pipeline.
func click_at(pos: Vector2, button := MOUSE_BUTTON_LEFT) -> void:
	if failed():
		return
	Input.warp_mouse(pos)  # windowed: the real cursor sits on the target, so its motion can't pull the click off
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	Input.parse_input_event(motion)
	await process_frame
	for pressed: bool in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = button
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		Input.parse_input_event(e)
		await process_frame
	await process_frame


## Presses and releases a gamepad button through the event pipeline.
func pad_button(button: JoyButton) -> void:
	if failed():
		return
	for pressed: bool in [true, false]:
		var e := InputEventJoypadButton.new()
		e.button_index = button
		e.pressed = pressed
		Input.parse_input_event(e)
		await process_frame
	await process_frame


## Types text into the focused control with key events, as a keyboard would.
func type_text(text: String) -> void:
	if failed():
		return
	for ch in text:
		for pressed: bool in [true, false]:
			var e := InputEventKey.new()
			e.pressed = pressed
			e.unicode = ch.unicode_at(0) if pressed else 0
			e.keycode = OS.find_keycode_from_string(ch.to_upper()) if ch != " " else KEY_SPACE
			Input.parse_input_event(e)
		await process_frame


## Presses and releases an InputMap action through the event pipeline (handlers and Input's state both see it).
func press_action(action: StringName) -> void:
	if failed():
		return
	for pressed: bool in [true, false]:
		var e := InputEventAction.new()
		e.action = action
		e.pressed = pressed
		Input.parse_input_event(e)
		await process_frame
	await process_frame


## Holds an action for `s` seconds (Input's state: what the session samples).
func hold(action: StringName, s: float) -> void:
	if failed():
		return
	Input.action_press(action)
	await seconds(s)
	Input.action_release(action)
	await process_frame


## Saves a screenshot as <shots_dir>/<shot_name>.png (with `--shots`).
func shot(shot_name: String) -> void:
	if shots_dir == "" or failed():
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(shots_dir)
	var path := shots_dir.path_join(shot_name + ".png")
	root.get_texture().get_image().save_png(path)
	print("  shot " + ProjectSettings.globalize_path(path))


# --- The game ----------------------------------------------------------------------------------------------------


func scene_is(scene_name: String) -> bool:
	return current_scene != null and current_scene.name == scene_name


## A node by path from `from`; fails when it isn't there.
func find(from: Node, path: NodePath) -> Node:
	var n := from.get_node_or_null(path) if from != null else null
	if n == null and not failed():
		fail("node not found: %s" % path)
	return n


## The scene views of `kind` (an EnumView value) in the sim (their roots), by key: UnifiedSession.get_views.
func views(kind: int) -> Array[Node]:
	if session == null:
		return []
	return session.get_views(kind)


## The instances the MultiMesh views of `kind` (an EnumMultiView value) draw (0 without one).
func multi_count(kind: int) -> int:
	var kind_name: String = EnumMultiView.name(kind)  # the marker's kind: the member's name, lowercased
	var count := 0
	for marker: Node in root.find_children("*", "UnifiedMultiView", true, false):
		var multi_view := marker as UnifiedMultiView
		if multi_view.kind != kind_name:
			continue
		var parent := multi_view.get_parent()
		var mm: MultiMesh = null
		if parent is MultiMeshInstance3D:
			mm = (parent as MultiMeshInstance3D).multimesh
		elif parent is MultiMeshInstance2D:
			mm = (parent as MultiMeshInstance2D).multimesh
		if mm != null:  # -1 draws every instance
			count += mm.instance_count if mm.visible_instance_count < 0 else mm.visible_instance_count
	return count


## "slot:name, ..." of the present players ("" without a session).
func player_names() -> String:
	var out: Array[String] = []
	if session != null:
		for player: int in session.get_players():
			out.append("%d:%s" % [session.get_player_slot(player), session.get_player_name(player)])
	return ", ".join(out)


## Loads the main scene, unless a session is already up (a game that keeps its session in an autoload): a game that
## keeps it in its main scene gets it this way. Waits until there is one.
func load_session(timeout_s := 5.0) -> void:
	if session == null:
		change_scene_to_file(str(ProjectSettings.get_setting("application/run/main_scene")))
	await wait_for(func() -> bool: return session != null, timeout_s, "a UnifiedSession in the tree")


# Godot's headless display server leaves the root window 64x64, where a UI lays out unlike in any real window and a
# click aimed at a control lands elsewhere: a headless run gets the window a player's opens at, the project's size.
func _size_headless_window() -> void:
	if DisplayServer.get_name() != "headless":
		return
	var width: int = ProjectSettings.get_setting("display/window/size/window_width_override", 0)
	var height: int = ProjectSettings.get_setting("display/window/size/window_height_override", 0)
	if width <= 0 or height <= 0:
		width = ProjectSettings.get_setting("display/window/size/viewport_width", 1152)
		height = ProjectSettings.get_setting("display/window/size/viewport_height", 648)
	root.size = Vector2i(width, height)


func _start() -> void:
	game = root.get_node_or_null(^"Game")
	if frame_log != null and session != null:
		session.sim_event.connect(func(event: UnifiedEvent, state: UnifiedSession.EventState) -> void:
			if state == UnifiedSession.EVENT_CONFIRMED:
				frame_tag(event.get_class()))
		# A window that loses focus or gets covered can stall a frame in the driver: tag it, not to blame the game.
		root.focus_entered.connect(frame_tag.bind("window focused"))
		root.focus_exited.connect(frame_tag.bind("window unfocused"))
	@warning_ignore("redundant_await")  # this _run is a stub: the script's own _run (an override) awaits
	await _run()
	finish()
