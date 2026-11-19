extends SceneTree
## unified's navigation baker (src/level/README.md, Authoring), run by `uni bake --nav` before the level exporter:
##   godot --headless --path <project> -s res://addons/unified/nav_bake.gd -- --scene=res://... [--scene=...]
## What the editor's Bake NavigationMesh button does, for a level scene that has a NavigationRegion3D: bakes the
## region's NavigationMesh (its agent size and other settings as the author set them; a region without one gets
## Godot's defaults) from the level's static colliders, the geometry the sim collides with, and saves the scene. A
## scene without a region is left alone. The exporter never bakes: this is the authoring step it reads.
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


## Bakes the scene's one NavigationRegion3D and saves the scene: what it baked ({}: no region, or an error).
func _bake(path: String) -> Dictionary:
	var packed := load(path) as PackedScene
	if packed == null:
		errors.append("%s: cannot load the scene" % path)
		return {}
	var scene := packed.instantiate()
	var regions := scene.find_children("*", "NavigationRegion3D", true, false)
	if regions.is_empty():
		scene.free()
		return {}
	var region := regions[0] as NavigationRegion3D
	if regions.size() > 1:
		errors.append("%s: %s: a second NavigationRegion3D (a level has one)" % [path, scene.get_path_to(regions[1])])
		scene.free()
		return {}
	root.add_child(scene)  # transforms are global ones in the tree
	await process_frame
	var mesh := region.navigation_mesh
	if mesh == null:
		mesh = NavigationMesh.new()
		region.navigation_mesh = mesh
	# the colliders, from the whole level: what the sim walks on, whatever the region's own source settings say
	mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(mesh, source, scene)
	NavigationServer3D.bake_from_source_geometry_data(mesh, source)
	var result := {}
	if mesh.get_polygon_count() == 0:
		errors.append("%s: %s: the bake found nothing to walk on" % [path, scene.get_path_to(region)])
	else:
		root.remove_child(scene)
		var out := PackedScene.new()
		if out.pack(scene) != OK or ResourceSaver.save(out, path) != OK:
			errors.append("%s: cannot save the scene" % path)
		else:
			result = {"scene": path, "polygons": mesh.get_polygon_count(), "vertices": mesh.get_vertices().size()}
	if scene.is_inside_tree():
		root.remove_child(scene)
	scene.free()
	return result
