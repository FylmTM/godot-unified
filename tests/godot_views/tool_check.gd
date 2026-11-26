# UnifiedTool's own checks (tools_godot/tool.gd, mirrored as res://unified/tools_godot/): run headless by
# `uni test --suite godot-bindings`. A headless run's window is the project's window size, not Godot's 64x64; click
# and click_at give real mouse events of the button asked for, where they aim (a target past 64x64 is hit); pad_button
# and pad_axis give a pad's events as the pad asked for; the --frames log splits a drawn frame into its scene process
# and render draw. Validate's runtime check names a running game's file that names a tool script (by class or path,
# in code, not in a comment), never a game tool's or unified's runtime files.
# Prints one line per check and "TOOL TESTS: <n> failed"; a failure fails the run.
extends UnifiedTool

var failures := 0
var clicks: Array[String] = []
var pads: Array[String] = []


func check(what: String, ok: bool, detail: Variant = "") -> void:
	print("%s %s %s" % ["PASS" if ok else "FAIL", what, str(detail)])
	if not ok:
		failures += 1


func _run() -> void:
	var width: int = ProjectSettings.get_setting("display/window/size/viewport_width")
	var height: int = ProjectSettings.get_setting("display/window/size/viewport_height")
	check("a headless run's window is the project's size", root.size == Vector2i(width, height), root.size)
	var target := Control.new()
	target.position = Vector2(600, 300)
	target.size = Vector2(100, 50)
	target.gui_input.connect(func(event: InputEvent) -> void:
		var button := event as InputEventMouseButton
		if button != null:
			clicks.append("%d %s" % [button.button_index, "down" if button.pressed else "up"]))
	root.add_child(target)
	await frames(2)
	await click(target)
	check("click: the left button, on the control", clicks == ["1 down", "1 up"], clicks)
	clicks.clear()
	await click(target, MOUSE_BUTTON_RIGHT)
	check("click with the right button", clicks == ["2 down", "2 up"], clicks)
	clicks.clear()
	await click_at(Vector2(690, 340), MOUSE_BUTTON_RIGHT)
	check("click_at a point inside the control", clicks == ["2 down", "2 up"], clicks)
	clicks.clear()
	await click_at(Vector2(10, 10))
	check("click_at a point outside it misses", clicks.is_empty(), clicks)
	# a pad's events go to the focused control, carrying the pad's device
	target.focus_mode = Control.FOCUS_ALL
	target.gui_input.connect(func(event: InputEvent) -> void:
		var button := event as InputEventJoypadButton
		if button != null:
			pads.append("%d %d %s" % [button.device, button.button_index, "down" if button.pressed else "up"]))
	target.grab_focus()
	await pad_button(JOY_BUTTON_A)
	check("pad_button: the first pad's press and release", pads == ["0 0 down", "0 0 up"], pads)
	pads.clear()
	await pad_button(JOY_BUTTON_B, 1)
	check("pad_button as a second pad", pads == ["1 1 down", "1 1 up"], pads)
	await pad_axis(JOY_AXIS_LEFT_X, -0.75, 1)
	check("pad_axis holds the second pad's stick", is_equal_approx(Input.get_joy_axis(1, JOY_AXIS_LEFT_X), -0.75),
		Input.get_joy_axis(1, JOY_AXIS_LEFT_X))
	await pad_axis(JOY_AXIS_LEFT_X, 0.0, 1)
	check("pad_axis 0 lets go", Input.get_joy_axis(1, JOY_AXIS_LEFT_X) == 0.0, Input.get_joy_axis(1, JOY_AXIS_LEFT_X))
	check_frame_split()
	check_runtime_without_tools()
	print("TOOL TESTS: %d failed" % failures)
	if failures > 0:
		fail("%d checks failed" % failures)


# UnifiedFrameLog splits a drawn frame into its scene process (its start to frame_pre_draw) and render draw
# (frame_pre_draw to frame_post_draw). A headless run draws nothing, so the check emits RenderingServer's two signals
# itself, around sleeps of known length.
func check_frame_split() -> void:
	var split_log := UnifiedFrameLog.new()
	split_log.frame()
	OS.delay_usec(15000)  # the scene process
	RenderingServer.frame_pre_draw.emit()
	OS.delay_usec(12000)  # the render draw
	RenderingServer.frame_post_draw.emit()
	OS.delay_usec(1000)
	split_log.frame()  # frame 0: drawn, a hitch (over 25 ms)
	OS.delay_usec(2000)
	split_log.frame()  # frame 1: not drawn
	RenderingServer.frame_pre_draw.emit()
	OS.delay_usec(2000)
	split_log.frame()  # frame 2: a pre-draw with no post-draw is not drawn
	var report := split_log.report()
	check("frame log: every frame counted, only the drawn one split", report.count == 3 and report.drawn == 1,
		report)
	var hitches: Array[Dictionary] = report.hitches
	if not hitches.is_empty():
		var hitch := hitches[0]
		check("frame log: the drawn frame's process and draw at least their sleeps",
			hitch.frame == 0 and hitch.process_ms >= 15.0 and hitch.draw_ms >= 12.0, hitch)
		check("frame log: process + draw within the frame", hitch.process_ms + hitch.draw_ms <= hitch.ms, hitch)
	check("frame log: one hitch, the drawn frame", hitches.size() == 1, hitches)
	check("frame log: the summary's split is the drawn frame's", report.get("process_max_ms", 0.0) >= 15.0
		and report.get("draw_max_ms", 0.0) >= 12.0
		and report.get("process_max_ms", 0.0) + report.get("draw_max_ms", 0.0) <= report.max_ms, report)


func check_runtime_without_tools() -> void:
	var dir := "user://runtime_check/"
	DirAccess.make_dir_recursive_absolute(dir)
	var files: Dictionary[String, String] = {
		"by_class.gd": "extends Node\nvar recipe: UnifiedCrowdRecipe\n",
		"in_a_comment.gd": "extends Node\n## Baked by UnifiedCrowdBake (a tool).\nvar clips: UnifiedCrowdClips\n",
		"by_path.tscn":
		"[gd_scene format=3]\n[ext_resource type=\"Script\" path=\"res://unified/tools_godot/tool.gd\" id=\"1\"]\n",
		"shader.gdshader": "shader_type spatial;\n// UnifiedTool in a comment\n",
	}
	var paths: Array[String] = []
	for file in files:
		var handle := FileAccess.open(dir + file, FileAccess.WRITE)
		handle.store_string(files[file])
		handle.close()
		paths.append(dir + file)
	paths.append("res://game/tools/anything.gd")  # a game's tool: never read
	var found: Array[String] = []
	for named in UnifiedValidate.tools_named_in(paths):
		found.append("%s %s" % [named[0].get_file(), named[1]])
	check("validate: a running game's file naming a tool script, by class or path, not in a comment",
		found == ["by_class.gd UnifiedCrowdRecipe", "by_path.tscn unified/tools_godot/"], found)
	var runtime: Array[String] = []
	for file in DirAccess.get_files_at("res://unified/godot_runtime/"):
		runtime.append("res://unified/godot_runtime/" + file)
	check("validate: unified's runtime files name no tool script", not runtime.is_empty()
		and UnifiedValidate.tools_named_in(runtime).is_empty(), UnifiedValidate.tools_named_in(runtime))
