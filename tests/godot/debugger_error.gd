# A script error under Godot's debugger (-d), as `uni tool` runs headless tool scripts: the debugger stops at its
# prompt, and the `quit` uni puts on every child's stdin must end the run at once, with the error printed.
# Run by `uni test --suite godot-bindings`; it errors on purpose.
extends SceneTree


func _initialize() -> void:
	var missing: Dictionary = {}
	print("DEBUGGER ERROR: about to fail")
	var text := String(missing.get("absent"))
	print("DEBUGGER ERROR: not reached ", text)
	quit(0)
