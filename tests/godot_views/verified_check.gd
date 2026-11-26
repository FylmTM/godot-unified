# unified:godot's verified timeline forced by the dev UI (`--verified-players`, which the suite passes): run headless by
# `uni test --suite godot-bindings` on the view test game (ext/). Its predicted3d kind is no `.Verified` kind and its
# data is wider than any that is, so its samples need the slots the switch widens to when it is first on: the remote
# player's predicted3d view plays late, behind the verified tick, with its sample's whole data.
# Prints one line per check and "VERIFIED TESTS: <n> failed"; exits with the failure count.
extends SceneTree

var failed := 0


func check(name: String, ok: bool, detail: Variant = "") -> void:
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, str(detail)])
	if not ok:
		failed += 1


func _initialize() -> void:
	var views := Node3D.new()
	root.add_child(views)
	var session := UnifiedSession.new()
	session.local_name = "player"
	root.add_child(session)
	session.view_root = views
	check("start_single", session.start_single())
	var predicted: Node3D = null
	for i in 200:  # up to ~4 s
		await create_timer(0.02).timeout
		if predicted == null:
			for child in views.get_children():
				var view_marker := child.get_node_or_null(^"UnifiedView") as UnifiedView
				if view_marker != null and view_marker.kind == "predicted3d":
					predicted = child as Node3D
		if predicted != null and (predicted.get("frames") as Array).size() >= 60:
			break
	check("the remote player's predicted3d view", predicted != null)
	if predicted != null:
		var frames: Array = predicted.get("frames")
		var behind := frames.filter(func(frame: Array) -> bool: return frame[0] <= frame[1] - 2)
		check("forced onto the verified timeline: its data is its sample's, behind the verified tick",
			frames.size() >= 40 and behind.size() * 4 >= frames.size() * 3, [behind.size(), frames.size()])
		check("its data, wider than any .Verified kind's, is its sample's whole", predicted.get("torn") == 0,
			predicted.get("torn"))
	session.leave()
	for i in 50:
		if not session.running:
			break
		await create_timer(0.02).timeout
	views.queue_free()
	session.queue_free()
	await process_frame
	print("VERIFIED TESTS: %d failed" % failed)
	quit(failed)
