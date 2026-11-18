extends UnifiedValidate
## drift's project check (the library's UnifiedValidate) and its view contract (simulation/extension): every
## rock shape (Unified.constants.rock_shapes) a polygon, a rock MultiMesh view (rock_<v>) in the arena per rock shape variant, every
## MultiMesh kind present once, and the level's scale. The level export being current is the godot suite's `bake` step.


func _play_scene() -> String:
	return "res://game/arena/arena.tscn"


func _check_contract() -> String:
	var shapes: Array = Unified.constants.rock_shapes
	var want: Array[String] = ["bullet", "gem"]
	for v in shapes.size():
		want.append("rock_%d" % v)
		if (shapes[v] as Array).size() < 3:
			log_capture.add("rock_shapes[%d] has %d points" % [v, (shapes[v] as Array).size()],
				"res://game/multi/rock_view.gd")
	var arena := (load(_play_scene()) as PackedScene).instantiate()
	var kinds: Array[String] = []
	for b in arena.get_node(^"MultiViews").get_children():
		kinds.append((b.get_node(^"UnifiedMultiView") as UnifiedMultiView).kind)
	kinds.sort()
	want.sort()
	if kinds != want:
		log_capture.add("MultiMesh views %s, the sim's kinds %s" % [kinds, want], _play_scene())
	arena.free()
	return "ok"
