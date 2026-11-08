extends Node3D

# Prints which extensions loaded; the release smoke test reads the log.
func _ready() -> void:
	print("standin: main scene ready, extensions: ", GDExtensionManager.get_loaded_extensions())
	if "--smoke-test" in OS.get_cmdline_user_args():
		print("standin: smoke test mode")
