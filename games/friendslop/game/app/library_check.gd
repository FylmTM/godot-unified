extends Node
## The first autoload: without the game library (UnifiedSession and the game's classes missing: an export that
## lost its library, or a checkout that never built it) nothing can run, and the Game autoload, which names the
## library's classes, fails to load. Says so and offers Quit instead. Names no class of the library.


func _ready() -> void:
	if ClassDB.class_exists(&"UnifiedSession"):
		queue_free()
		return
	var exported := OS.has_feature("template")
	var game_name: String = ProjectSettings.get_setting("application/config/name")
	push_error("%s: the game library failed to load (UnifiedSession missing): %s" % [game_name,
		"the export is broken" if exported else "build it with ./uni build"])
	get_tree().unload_current_scene.call_deferred()
	var layer := CanvasLayer.new()
	layer.layer = 200
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = UiTheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(box)
	var title := Label.new()
	title.theme_type_variation = &"Heading"
	title.text = "The game library failed to load"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var detail := Label.new()
	detail.theme_type_variation = &"Dim"
	detail.text = ("This copy of the game is incomplete or damaged. Download it again." if exported
		else "Build it first: ./uni build")
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(detail)
	var quit := Button.new()
	quit.theme_type_variation = &"PrimaryButton"
	quit.text = "Quit"
	quit.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	quit.pressed.connect(func() -> void: get_tree().quit())
	box.add_child(quit)
	quit.grab_focus.call_deferred()
