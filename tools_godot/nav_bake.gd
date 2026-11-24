extends SceneTree
## unified's navigation baker (src/level/README.md, Authoring), run by `uni bake --nav` before the level exporter:
##   godot --headless --path <project> -s res://unified/tools_godot/nav_bake.gd -- --scene=res://... [--scene=...]
## What the editor's Bake NavigationMesh button does, for the level scenes whose NavigationRegion3D opts in (metadata
## `unified_nav_bake = true`; any other region, a hand-made bake among them, is left alone): bakes the region with its
## own settings exactly as the author set them (`region.bake_navigation_mesh`), and saves the scene. A region must
## parse static colliders (the geometry the sim walks: headless Godot has no meshes to parse) or it is an error naming
## it, never a setting changed behind the author's back. The exporter never bakes: this is the authoring step it reads.
## Prints one `UNIFIED_RESULT {ok, scenes: [{scene, polygons, vertices}], errors}` line; each error names its node.

var errors: Array[String] = []


func _initialize() -> void:
	var scenes: Array[String] = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--scene="):
			scenes.append(a.trim_prefix("--scene="))
	var baked: Array[Dictionary] = []
	for path in scenes:
		var result := await _bake(path)
		if not result.is_empty():
			baked.append(result)
	var ok := errors.is_empty()
	print("UNIFIED_RESULT " + JSON.stringify({"ok": ok, "scenes": baked, "errors": errors}))
	quit(0 if ok else 1)


## Bakes the scene's NavigationRegion3D when it opts in, and saves the scene: what it baked ({}: nothing to bake, or
## an error).
func _bake(path: String) -> Dictionary:
	var packed := load(path) as PackedScene
	if packed == null:
		errors.append("%s: cannot load the scene" % path)
		return {}
	# as the editor opens a scene: an instanced scene's own values stay its own, so the save writes back only what the
	# scene overrides (a plain instantiate() would copy each instance's properties into the scene, which then shadow
	# any later change to the instanced scene)
	var scene := packed.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	var region: NavigationRegion3D = null
	for node in scene.find_children("*", "NavigationRegion3D", true, false):
		if node.get_meta("unified_nav_bake", false):
			if region != null:
				errors.append("%s: %s: a second NavigationRegion3D (a level has one)" % [path, scene.get_path_to(node)])
				scene.free()
				return {}
			region = node as NavigationRegion3D
	if region == null:
		scene.free()
		return {}
	var where := "%s: %s" % [path, scene.get_path_to(region)]
	var mesh := region.navigation_mesh
	if mesh == null or mesh.geometry_parsed_geometry_type != NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS:
		errors.append("%s: its NavigationMesh must parse Static Colliders (Geometry > Parsed Geometry Type)" % where)
		scene.free()
		return {}
	root.add_child(scene)  # the bake reads global transforms
	await process_frame
	region.bake_navigation_mesh(false)
	root.remove_child(scene)
	var result := {}
	if mesh.get_polygon_count() == 0:
		errors.append("%s: the bake found nothing to walk on" % where)
	else:
		var out := PackedScene.new()
		if out.pack(scene) != OK or ResourceSaver.save(out, path) != OK:
			errors.append("%s: cannot save the scene" % path)
		else:
			result = {"scene": path, "polygons": mesh.get_polygon_count(), "vertices": mesh.get_vertices().size()}
	scene.free()
	return result
