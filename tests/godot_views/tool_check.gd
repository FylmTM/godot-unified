# UnifiedTool's own checks (src/godot/tools/tool.gd, mirrored as res://addons/unified/): run headless by
# `uni test --suite godot-bindings`. A headless run's window is the project's window size, not Godot's 64x64; click
# and click_at give real mouse events of the button asked for, where they aim (a target past 64x64 is hit).
# Prints one line per check and "TOOL TESTS: <n> failed"; a failure fails the run.
extends UnifiedTool

var failures := 0
var clicks: Array[String] = []


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
	print("TOOL TESTS: %d failed" % failures)
	if failures > 0:
		fail("%d checks failed" % failures)
