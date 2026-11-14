class_name UnifiedTool
extends SceneTree
## The base of every tool script (`uni tool <game> <name>`, the godot suite's steps), run with Godot's `-s`. It
## drives the real game the way a player would and reports one `UNIFIED_RESULT {json}` line, which uni judges
## strictly: any engine or script error fails the run.
##
## A script overrides `_run()` (a coroutine, started on the first frame, once the autoloads exist), reports with
## `step()`, `expect()` and `fail()`, and may `finish()` early. A failure ends the run at once: every wait returns
## and every input helper does nothing after it. The result carries `ok`, `ms`, `steps`, `failed`, `errors` and
## what the script adds to `result`. The run ends through the game's own quit (Game.quit_app).
##
## Arguments come after `--`: `arg("name")` reads `--name=value` (or `--name value`), `flag("name")` `--name`. Every
## tool takes `--shots=<dir>` (PNGs from `shot()`, a windowed run) and `--frames` (frame times and first-use hitches,
## UnifiedFrameLog; a script tags its own moments with `frame_tag()`).

## The Game autoload (a UnifiedGame). Untyped on purpose: a `-s` script compiles before the autoloads exist, so it
## names no script that uses them.
var game: Node
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
	var script_name := (get_script() as Script).resource_path.get_file().get_basename()
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
	if game != null:
		game.quit_app(0 if ok else 1)
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


## A real click: motion, press and release at the control's centre, in window coordinates.
func click(c: Control) -> void:
	if c == null or failed():
		return
	if not c.is_visible_in_tree():
		fail("cannot click hidden " + str(c.get_path()))
		return
	var pos := c.get_viewport().get_final_transform() * (c.get_global_transform_with_canvas() * (c.size / 2.0))
	Input.warp_mouse(pos)  # windowed: the real cursor sits on the control, so its motion can't pull the click off
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	Input.parse_input_event(motion)
	await process_frame
	for pressed: bool in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
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


## The main menu's UI (the library's MainMenu), when the menu is the current scene.
func menu() -> CanvasLayer:
	return current_scene.get_node_or_null(^"Menu") as CanvasLayer if scene_is("MainMenu") else null


## A node by path from `from`; fails when it isn't there.
func find(from: Node, path: NodePath) -> Node:
	var n := from.get_node_or_null(path) if from != null else null
	if n == null and not failed():
		fail("node not found: %s" % path)
	return n


## Clicks the menu's button or field by its unique name (Single, Host, Join, JoinAddress, HostLan, CodeJoin, ...).
func click_menu(unique_name: String) -> void:
	await click(find(menu(), "%" + unique_name) as Control)


## The views of `kind` under the play scene's Views.
func views(kind: StringName) -> Array[Node]:
	var out: Array[Node] = []
	var root_views := current_scene.get_node_or_null(^"Views") if current_scene != null else null
	if root_views != null:
		for v in root_views.get_children():
			if str(v.get(&"kind")) == String(kind) and not v.is_queued_for_deletion():
				out.append(v)
	return out


## The instances a bulk view of `kind` draws (0 without one).
func bulk_count(kind: StringName) -> int:
	for n in get_nodes_in_group(&"sim_bulk"):
		var mmi := n as MultiMeshInstance3D
		var mm: MultiMesh = mmi.multimesh if mmi != null else (n as MultiMeshInstance2D).multimesh
		if str(n.get(&"kind")) == String(kind) and mm != null:
			return mm.visible_instance_count
	return 0


## A player setting (the Settings autoload's value).
func setting(key: StringName) -> Variant:
	return root.get_node(^"Settings").get_value(key)


## "slot:name, ..." of the present players.
func player_names() -> String:
	var out: Array[String] = []
	for p: Dictionary in game.present_players():
		out.append("%d:%s" % [p.slot, game.player_name(p)])
	return ", ".join(out)


func _start() -> void:
	game = root.get_node_or_null(^"Game")
	if game == null:
		fail("no Game autoload")
		return
	if game.session == null:
		fail("no session: build the game library (uni build)")
		return
	if frame_log != null:
		game.session.sim_event.connect(func(k: StringName, _t: int, _e: int, _p: Vector3, _v: float) -> void:
			frame_tag(k))
		if game.session.has_signal(&"sim_event_2d"):
			game.session.sim_event_2d.connect(func(k: StringName, _t: int, _e: int, _p: Vector2, _v: float) -> void:
				frame_tag(k))
		# A window that loses focus or gets covered can stall a frame in the driver: tag it, not to blame the game.
		root.focus_entered.connect(frame_tag.bind("window focused"))
		root.focus_exited.connect(frame_tag.bind("window unfocused"))
	await _run()
	finish()
