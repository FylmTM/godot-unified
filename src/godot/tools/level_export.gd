extends SceneTree
## unified's level exporter (src/level/README.md; the UNLV format in src/level/level.odin), run by `uni bake`:
##   godot --headless --path <project> -s res://addons/unified/level_export.gd -- [--check] [--scene=res://...]...
## Exports the --scene ones (uni bake passes a game's level scenes: src/level/README.md, Baking), else every
## res://game/levels/*.tscn (not subfolders: those hold the parts a level instances), to the .level file next to each. --check writes nothing and fails when a committed file differs from a fresh
## export. A scene with findings is not written. Level scenes are instantiated, not run: no node is added to the
## tree and no _ready runs.
## A 3D level (any root but a Node2D): StaticBody3D + CollisionShape3D children (box, sphere, capsule, cylinder,
## convex polygon, concave polygon, height map); the body's physics_material_override gives friction and bounce,
## metadata unified_category the filter category, unified_material the user material, unified_rolling_resistance and
## unified_tangent_velocity the rest of its surface. A CollisionShape3D's own unified_material,
## unified_rolling_resistance or unified_tangent_velocity give its shape a surface of its own.
## A 2D level (a Node2D root) maps onto the sim's XY plane at z = 0 (x right, y down, rotations about +Z), pixels
## divided by the game's view_scale (Unified.view_scale; a fixture baked without a game: the root's metadata
## unified_px_per_m), shapes extruded to ±unified_depth_m / 2 (default 1): StaticBody2D + CollisionShape2D
## (rectangle, circle, capsule, convex polygon) or CollisionPolygon2D (solids, split into convex parts) children, and
## TileMapLayers (one body each, the tiles' physics layer 0 polygons).
## Markers: nodes whose script has `const UNIFIED_KIND` (or a `unified_kind` property, or metadata): kind, name,
## global transform, every exported script property, the points of a Path3D / Path2D child.
## Navigation (a 3D level): one NavigationRegion3D's saved bake, its vertices in level space, welded and lowered onto
## the static floor under them, and its polygons turned counter-clockwise seen from above, leaving out those enclosed in
## a solid static shape (the hollow inside a tall box, which Godot's bake finds walkable). Never baked here: the bytes
## are what the author baked (in the editor, or `uni bake --nav`) and saved.
## Prints one `UNIFIED_RESULT {ok, check, levels: [{scene, level, bytes, changed}], errors}` line; each error names its
## node. A plain SceneTree script, not a UnifiedTool: it also runs in projects without unified's extension (the 2D
## fixture in tests/godot).

const MAGIC := "UNLV"
const VERSION := 4
const MAX_POLYGON := 32  # points of one 2D convex part: extruded, a prism of 64 points and 96 edges
## Points of a 3D convex shape: a hull of V points has at most 3V - 6 edges, so 44 always fit Box3D's 128.
const MAX_HULL := 44
## A Curve property's samples, evenly spaced over its domain (level.CURVE_SAMPLES).
const CURVE_SAMPLES := 32
## cos(k * 22.5 degrees), k = 0..15: a cylinder's 16 sides with no trig of the platform's (sin is cos 4 steps back).
const CIRCLE_16: Array[float] = [1.0, 0.9238795325112867, 0.7071067811865476, 0.3826834323650898, 0.0,
		-0.3826834323650898, -0.7071067811865476, -0.9238795325112867, -1.0, -0.9238795325112867,
		-0.7071067811865476, -0.3826834323650898, 0.0, 0.3826834323650898, 0.7071067811865476, 0.9238795325112867]
enum Shape { BOX, SPHERE, CAPSULE, HULL, MESH, HEIGHT_FIELD }
enum Prop { BOOL, INT, FLOAT, VEC3, STRING, REF, CURVE }


## What a contact with a level shape mixes, and the game's id for it (level.Surface).
class Surface:
	var friction := 0.6
	var restitution := 0.0
	var rolling_resistance := 0.0
	var tangent_velocity := Vector3.ZERO
	var material := 0


## One shape as the file stores it, in its body's frame (metres), from either dimension.
class ShapeRec:
	var kind: Shape
	var pos := Vector3.ZERO
	var rot := Quaternion.IDENTITY
	var surface_node: Node = null  # the CollisionShape3D whose metadata gives it a surface of its own (null: none)
	var half := Vector3.ZERO  # BOX
	var radius := 0.0  # SPHERE, CAPSULE
	var half_height := 0.0  # CAPSULE: half the segment, along local Y
	var points := PackedVector3Array()  # HULL, MESH
	var triangles := PackedInt32Array()  # MESH: 3 indices each, counter-clockwise seen from the front
	var count_x := 0  # HEIGHT_FIELD
	var count_z := 0
	var scale := Vector3.ONE
	var heights := PackedFloat32Array()


var errors: Array[String] = []
var _root: Node
var _scene_path := ""
var _ppm := 0.0  # a 2D level's pixels per metre; 0: a 3D level
var _navs: Array[Node] = []  # the level's NavigationRegion3Ds, in scene-tree order (one is allowed)
## The level's static shapes in level space, for the floor under a navigation vertex (_floor_under): each a
## Dictionary of its kind and what that kind needs (points and triangles, or a centre and radius), with its bounds.
var _floors: Array[Dictionary] = []
var _depth := 0.0  # a 2D level's extrusion depth, metres


func _initialize() -> void:
	var check := false
	var scenes: Array[String] = []
	for a in OS.get_cmdline_user_args():
		if a == "--check":
			check = true
		elif a.begins_with("--scene="):
			scenes.append(a.trim_prefix("--scene="))
	if scenes.is_empty():
		var dir := DirAccess.open("res://game/levels")
		if dir:
			for f in dir.get_files():
				if f.ends_with(".tscn"):
					scenes.append("res://game/levels/" + f)
	scenes.sort()
	var levels: Array[Dictionary] = []
	for path in scenes:
		var before := errors.size()
		var bytes := export_scene(path)
		if bytes.is_empty() or errors.size() > before:
			continue
		var target := path.get_basename() + ".level"
		var same := FileAccess.get_file_as_bytes(target) == bytes
		if check and not same:
			_error(target, "stale: run `uni bake`")
		elif not same:
			var f := FileAccess.open(target, FileAccess.WRITE)
			if f == null:
				_error(target, "cannot write it")
				continue
			f.store_buffer(bytes)
			f.close()
		levels.append({"scene": path, "level": target, "bytes": bytes.size(), "changed": not same})
	var ok := errors.is_empty()
	print("UNIFIED_RESULT " + JSON.stringify({"ok": ok, "check": check, "levels": levels, "errors": errors}))
	_quit_quietly(0 if ok else 1)


## An export error, naming the node or file.
func _error(where: String, what: String) -> void:
	errors.append("%s: %s" % [where, what])


## Quits once the sounds the game's autoloads started have stopped and the AudioServer has freed their playbacks
## (at most 1 s): quitting with a sound playing reports it as leaked at exit, which fails the run.
func _quit_quietly(code: int) -> void:
	await process_frame  # the autoloads' _ready has run
	var playbacks: Array[WeakRef] = []
	for type: String in ["AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D"]:
		for n: Node in root.find_children("*", type, true, false):
			if n.get("playing"):
				playbacks.append(weakref(n.call("get_stream_playback")))
				n.call("stop")
	var deadline := Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < deadline and playbacks.any(func(w: WeakRef) -> bool: return w.get_ref() != null):
		await process_frame
	quit(code)


func export_scene(path: String) -> PackedByteArray:
	var ps := load(path) as PackedScene
	if ps == null:
		_error(path, "cannot load the scene")
		return PackedByteArray()
	# Not added to the tree (it isn't running yet): transforms are composed by _xf / _xf2, and no _ready runs.
	var scene := ps.instantiate()
	_root = scene
	_scene_path = path
	_ppm = 0.0
	_navs = []
	_floors = []
	if scene is Node2D:
		# pixels per metre: the game's Glue.view_scale (Unified.view_scale); a level baked without a game (a fixture)
		# says it in its root's metadata. Both, and they differ: a finding (the views would draw it at another scale).
		var game_scale := 0.0
		if Engine.has_singleton(&"Unified"):
			game_scale = float(Engine.get_singleton(&"Unified").get(&"view_scale"))
		_ppm = float(scene.get_meta("unified_px_per_m", game_scale))
		_depth = float(scene.get_meta("unified_depth_m", 1.0))
		if game_scale > 0.0 and _ppm != game_scale:
			_error(path, "unified_px_per_m is %s, the game's view_scale %s: drop the metadata" % [_ppm, game_scale])
		if _ppm <= 0.0 or _depth <= 0.0:
			_error(path, "pixels per metre (the game's view_scale, or the root's unified_px_per_m) and " +
				"unified_depth_m must be positive")
	var bodies: Array[Node] = []
	var markers: Array[Node] = []
	_collect(scene, bodies, markers)
	var marker_index := {}
	for i in markers.size():
		marker_index[markers[i]] = i
	var strings: Array[String] = [""]
	var bytes := _encode(bodies, markers, marker_index, strings)
	scene.free()
	return bytes


## A node's transform relative to the level's root, composed up the parents (the level root is the origin).
func _xf(n: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var c := n
	while c != null and c != _root:
		if c is Node3D:
			t = (c as Node3D).transform * t
		c = c.get_parent()
	return t


## A 2D node's transform relative to the level's root, in pixels.
func _xf2(n: Node) -> Transform2D:
	var t := Transform2D.IDENTITY
	var c := n
	while c != null and c != _root:
		if c is Node2D:
			t = (c as Node2D).transform * t
		c = c.get_parent()
	return t


func _where(n: Node) -> String:
	return str(_root.get_path_to(n))


## Bodies and markers depth-first, parents before children: the marker order Unified.level_markers (Odin) returns
## too (tests/godot_views/markers_check.gd compares them).
func _collect(n: Node, bodies: Array[Node], markers: Array[Node]) -> void:
	var is_2d := _ppm > 0.0
	if n is StaticBody3D or n is StaticBody2D or (n is TileMapLayer and _tile_collision(n)):
		if (n is StaticBody3D) == is_2d:
			_error(_where(n), "a %s body in a %s level" % ["3D" if is_2d else "2D", "2D" if is_2d else "3D"])
		else:
			bodies.append(n)
	if n is NavigationRegion3D:
		if is_2d:
			_error(_where(n), "a NavigationRegion3D in a 2D level (navigation is exported for 3D levels)")
		else:
			_navs.append(n)
	if _kind(n) != "":
		if not (n is Node2D if is_2d else n is Node3D):
			_error(_where(n), "a marker in a %s level must be a %s" % ["2D" if is_2d else "3D",
				"Node2D" if is_2d else "Node3D"])
		else:
			markers.append(n)
	for c in n.get_children():
		_collect(c, bodies, markers)


func _tile_collision(l: TileMapLayer) -> bool:
	return l.collision_enabled and l.tile_set != null and l.tile_set.get_physics_layers_count() > 0


func _kind(n: Node) -> String:
	var s: Script = n.get_script()
	if s != null:
		var consts := s.get_script_constant_map()
		if consts.has("UNIFIED_KIND"):
			return str(consts["UNIFIED_KIND"])
	if "unified_kind" in n:
		return str(n.get("unified_kind"))
	if n.has_meta("unified_kind"):
		return str(n.get_meta("unified_kind"))
	return ""


func _intern(strings: Array[String], s: String) -> int:
	var i := strings.find(s)
	if i >= 0:
		return i
	strings.append(s)
	return strings.size() - 1


## Exported script properties of a marker, in declaration order: [name, value] pairs.
func _props(n: Node) -> Array[Array]:
	var out: Array[Array] = []
	var s: Script = n.get_script()
	if s == null:
		return out
	for p in s.get_script_property_list():
		var usage: int = p["usage"]
		if usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0 or usage & PROPERTY_USAGE_EDITOR == 0:
			continue
		out.append([p["name"], n.get(p["name"])])
	return out


func _encode(bodies: Array[Node], markers: Array[Node], marker_index: Dictionary, strings: Array[String]) \
		-> PackedByteArray:
	# The string table comes first, in the order the reader meets the strings.
	_intern(strings, _scene_path)
	for b in bodies:
		_intern(strings, b.name)
	var marker_props: Array[Array] = []
	for m in markers:
		_intern(strings, _kind(m))
		_intern(strings, m.name)
		var ps := _props(m)
		marker_props.append(ps)
		for p: Array in ps:
			_intern(strings, p[0])
			if p[1] is String or p[1] is StringName:
				_intern(strings, str(p[1]))
	var w := StreamPeerBuffer.new()
	w.big_endian = false
	w.put_data(MAGIC.to_ascii_buffer())
	w.put_u16(VERSION)
	w.put_float(_ppm)
	w.put_u32(strings.size())
	for s in strings:
		var u: PackedByteArray = s.to_utf8_buffer()
		w.put_u16(u.size())
		w.put_data(u)
	w.put_u32(_intern(strings, _scene_path))
	w.put_u32(bodies.size())
	for b in bodies:
		_body(w, b, strings)
	w.put_u32(markers.size())
	for i in markers.size():
		_marker(w, markers[i], marker_props[i], marker_index, strings)
	_nav(w)
	return w.data_array


## The navigation section: the bake's agent (radius, height, max climb), then its vertices in level space, welded where
## exactly equal so adjacent polygons share vertex indices, and its polygons, each checked (_nav_polygon) and turned
## counter-clockwise seen from above (Godot bakes them clockwise; a mirroring region turns them back). An edge shared
## by more than two polygons is refused: the file promises that an edge joins at most two. No region: all empty.
func _nav(w: StreamPeerBuffer) -> void:
	var agent := Vector3.ZERO
	var vertices := PackedVector3Array()
	var polygons: Array[PackedInt32Array] = []
	if not _navs.is_empty():
		var region := _navs[0] as NavigationRegion3D
		for k in range(1, _navs.size()):
			_error(_where(_navs[k]), "a second NavigationRegion3D (a level has one: %s)" % _where(region))
		var mesh := region.navigation_mesh
		if mesh == null or mesh.get_polygon_count() == 0:
			_error(_where(region), "a NavigationRegion3D without a saved bake (bake it in the editor, then save)")
		else:
			agent = Vector3(mesh.agent_radius, mesh.agent_height, mesh.agent_max_climb)
			var xf := _xf(region)
			var welded := {}  # position -> index in `vertices`
			var remap := PackedInt32Array()
			for v in mesh.get_vertices():
				var p := xf * v
				if not welded.has(p):
					welded[p] = vertices.size()
					vertices.append(p)
				remap.append(welded[p])
			var edges := {}  # Vector2i(lower, higher) index -> polygons using it
			for i in mesh.get_polygon_count():
				var where := "%s: navigation polygon %d" % [_where(region), i]
				var source := mesh.get_polygon(i)
				var polygon := PackedInt32Array()
				for index in source:
					if index < 0 or index >= remap.size():
						_error(where, "a vertex index out of range")
						polygon.clear()
						break
					polygon.append(remap[index])
				if polygon.size() != source.size():
					continue
				polygon = _nav_polygon(polygon, vertices, where)
				if polygon.is_empty():
					continue
				polygons.append(polygon)
				for k in polygon.size():
					var a := polygon[k]
					var b := polygon[(k + 1) % polygon.size()]
					var edge := Vector2i(mini(a, b), maxi(a, b))
					edges[edge] = int(edges.get(edge, 0)) + 1
					if edges[edge] == 3:
						_error(where, "its edge %d-%d is shared by more than two polygons" % [edge.x, edge.y])
			# Godot's bake floats the mesh up to a couple of cells above the floor (its voxels' rounding, the detail
			# mesh's extra cell): each vertex goes down onto the static floor under it, so the sim's floor is the one
			# it collides with (triangles stay planar: every vertex of a flat or sloped floor lands on it)
			var reach := 2.0 * mesh.cell_height + mesh.agent_max_climb + 0.01
			for i in vertices.size():
				var v := vertices[i]
				var floor_y := _floor_under(v.x, v.z, v.y + 0.001, v.y - reach)
				if floor_y > -INF:
					vertices[i] = Vector3(v.x, floor_y, v.z)
			# Godot's bake rasterizes a shape's surfaces, not its inside: a box taller than the agent leaves a walkable
			# island on the floor within it, which no walker can reach and a nearest-point query may pick. A polygon
			# whose middle raised by half the agent's height is inside a solid static shape is left out (half: a
			# polygon across a crease, a ramp's top, dips under the surface a little, and an island's solid rises at
			# least the agent's height above it).
			var kept: Array[PackedInt32Array] = []
			for polygon in polygons:
				var middle := Vector3.ZERO
				for index in polygon:
					middle += vertices[index]
				middle = middle / polygon.size() + Vector3(0, mesh.agent_height / 2, 0)
				if not _inside_solid(middle):
					kept.append(polygon)
			polygons = kept
	_v3(w, agent)
	w.put_u32(vertices.size())
	for v in vertices:
		_v3(w, v)
	w.put_u32(polygons.size())
	for polygon in polygons:
		w.put_u8(polygon.size())
		for index in polygon:
			w.put_u32(index)


## A navigation polygon counter-clockwise seen from above (empty, with an error at `where`, when it isn't a simple
## convex polygon), checked in doubles on its XZ projection: 3 to 255 distinct vertices, no zero-length edge, an area,
## no reflex vertex, and exterior angles summing to one turn (a star or a polygon doubling back turns more).
func _nav_polygon(polygon: PackedInt32Array, vertices: PackedVector3Array, where: String) -> PackedInt32Array:
	var n := polygon.size()
	if n > 255:
		_error(where, "%d vertices, more than the 255 a polygon may have" % n)
		return PackedInt32Array()
	var distinct := {}
	for index in polygon:
		distinct[index] = true
	if n < 3 or distinct.size() != n:
		_error(where, "degenerate (%d vertices, %d distinct)" % [n, distinct.size()])
		return PackedInt32Array()
	for k in n:
		var a := vertices[polygon[k]]
		var b := vertices[polygon[(k + 1) % n]]
		if a.x == b.x and a.z == b.z:
			_error(where, "a zero-length edge seen from above (vertices %d and %d)" % [polygon[k],
					polygon[(k + 1) % n]])
			return PackedInt32Array()
	# twice the signed area seen from above: the y of the cross products, positive counter-clockwise
	var area := 0.0
	for k in range(1, n - 1):
		area += _cross_y(vertices[polygon[0]], vertices[polygon[k]], vertices[polygon[k + 1]])
	if absf(area) <= 1e-8:
		_error(where, "degenerate (no area seen from above)")
		return PackedInt32Array()
	var out := polygon.duplicate()
	if area < 0.0:
		out.reverse()
	var turning := 0.0
	for k in n:
		var a := vertices[out[k]]
		var b := vertices[out[(k + 1) % n]]
		var c := vertices[out[(k + 2) % n]]
		var ux := float(b.x) - float(a.x)
		var uz := float(b.z) - float(a.z)
		var vx := float(c.x) - float(b.x)
		var vz := float(c.z) - float(b.z)
		var turn := uz * vx - ux * vz  # the y of (b - a) x (c - b): positive turning left (counter-clockwise)
		if turn < -1e-6 * sqrt(ux * ux + uz * uz) * sqrt(vx * vx + vz * vz):
			_error(where, "not convex at its vertex %d" % out[(k + 1) % n])
			return PackedInt32Array()
		turning += atan2(turn, ux * vx + uz * vz)
	if absf(turning - TAU) > 1e-6:
		_error(where, "not a simple polygon (it turns %.3f times around)" % (turning / TAU))
		return PackedInt32Array()
	return out


## Adds a body's shapes (`recs`, in the body's frame `frame`) to _floors, in level space.
func _add_floors(frame: Transform3D, recs: Array[ShapeRec]) -> void:
	for r in recs:
		var xf := frame * Transform3D(Basis(r.rot), r.pos)
		var f := {"kind": r.kind, "points": PackedVector3Array(), "triangles": PackedInt32Array()}
		var points: PackedVector3Array = f["points"]
		var triangles: PackedInt32Array = f["triangles"]
		match r.kind:
			Shape.BOX:
				for i in 8:
					points.append(xf * Vector3(r.half.x * (1.0 if i & 1 != 0 else -1.0),
							r.half.y * (1.0 if i & 2 != 0 else -1.0), r.half.z * (1.0 if i & 4 != 0 else -1.0)))
			Shape.HULL:
				for q in r.points:
					points.append(xf * q)
			Shape.MESH:
				for q in r.points:
					points.append(xf * q)
				triangles.append_array(r.triangles)
			Shape.HEIGHT_FIELD:
				# the grid from its corner, split along each cell's (x + 1, z) - (x, z + 1) diagonal, as Godot and Box3D
				for z in r.count_z:
					for x in r.count_x:
						points.append(xf * Vector3(x * r.scale.x, r.heights[z * r.count_x + x] * r.scale.y,
								z * r.scale.z))
				for z in r.count_z - 1:
					for x in r.count_x - 1:
						var i := z * r.count_x + x
						triangles.append_array(PackedInt32Array([i, i + 1, i + r.count_x, i + 1, i + r.count_x + 1,
								i + r.count_x]))
			Shape.SPHERE, Shape.CAPSULE:
				f["radius"] = r.radius
				points.append(xf * Vector3(0, r.half_height, 0))
				points.append(xf * Vector3(0, -r.half_height, 0))
		f["points"] = points  # packed arrays are values: the filled ones go back in
		f["triangles"] = triangles
		var lo := points[0]
		var hi := points[0]
		for q in points:
			lo = lo.min(q)
			hi = hi.max(q)
		var pad := Vector3.ONE * float(f.get("radius", 0.0))
		f["lo"] = lo - pad
		f["hi"] = hi + pad
		_floors.append(f)


## The height of the highest floor under (x, z) between `bottom` and `top` (-INF: none): the top surface of a box,
## hull, sphere or capsule, or the highest triangle of a mesh or height field there, in doubles.
func _floor_under(x: float, z: float, top: float, bottom: float) -> float:
	var best := -INF
	for f in _floors:
		var lo: Vector3 = f["lo"]
		var hi: Vector3 = f["hi"]
		if x < lo.x or x > hi.x or z < lo.z or z > hi.z or hi.y < bottom or lo.y > top:
			continue
		var points: PackedVector3Array = f["points"]
		var h := -INF
		match f["kind"]:
			Shape.BOX, Shape.HULL:
				h = _hull_top(points, x, z)
			Shape.MESH, Shape.HEIGHT_FIELD:
				var triangles: PackedInt32Array = f["triangles"]
				for t in range(0, triangles.size(), 3):
					var at := _triangle_height(points[triangles[t]], points[triangles[t + 1]], points[triangles[t + 2]],
							x, z)
					if at <= top and at > h:
						h = at
			Shape.SPHERE, Shape.CAPSULE:
				# the top of the swept sphere: the best of the segment's points (32 steps along it)
				var radius: float = f["radius"]
				var a := points[0]
				var b := points[1]
				for k in 33:
					var along := k / 32.0  # in doubles, not Vector3.lerp: every platform computes the same
					var cx := a.x + (float(b.x) - a.x) * along
					var cy := a.y + (float(b.y) - a.y) * along
					var cz := a.z + (float(b.z) - a.z) * along
					var d2 := (x - cx) * (x - cx) + (z - cz) * (z - cz)
					if d2 <= radius * radius:
						h = maxf(h, cy + sqrt(radius * radius - d2))
		if h <= top and h >= bottom and h > best:
			best = h
	return best


## Whether `p` is inside a solid static shape: a box or hull between its bottom and top surfaces there, or within a
## sphere's or capsule's radius of its segment. A mesh or a height field is a surface with no inside.
func _inside_solid(p: Vector3) -> bool:
	for f in _floors:
		var lo: Vector3 = f["lo"]
		var hi: Vector3 = f["hi"]
		if p.x < lo.x or p.x > hi.x or p.y < lo.y or p.y > hi.y or p.z < lo.z or p.z > hi.z:
			continue
		var points: PackedVector3Array = f["points"]
		match f["kind"]:
			Shape.BOX, Shape.HULL:
				if p.y < _hull_top(points, p.x, p.z) and p.y > _hull_bottom(points, p.x, p.z):
					return true
			Shape.SPHERE, Shape.CAPSULE:
				var radius: float = f["radius"]
				var a := points[0]
				var ab := points[1] - a
				var along := 0.0
				if ab.length_squared() > 0:
					along = clampf((p - a).dot(ab) / ab.length_squared(), 0, 1)
				if p.distance_to(a + ab * along) < radius:
					return true
	return false


## The bottom surface of the convex hull of `points` at (x, z) (INF: outside it): the lowest of its triangles there.
func _hull_bottom(points: PackedVector3Array, x: float, z: float) -> float:
	var bottom := INF
	for i in points.size():
		for j in range(i + 1, points.size()):
			for k in range(j + 1, points.size()):
				var at := _triangle_height(points[i], points[j], points[k], x, z)
				if at > -INF:
					bottom = minf(bottom, at)
	return bottom


## The top surface of the convex hull of `points` at (x, z) (-INF: outside it): the highest of the triangles of three of
## its points over (x, z), which is where a linear program over the hull's points peaks.
func _hull_top(points: PackedVector3Array, x: float, z: float) -> float:
	var top := -INF
	for i in points.size():
		for j in range(i + 1, points.size()):
			for k in range(j + 1, points.size()):
				top = maxf(top, _triangle_height(points[i], points[j], points[k], x, z))
	return top


## The height of triangle a, b, c over (x, z) (-INF: not over it, or the triangle is edge-on seen from above), by
## barycentric weights in doubles.
func _triangle_height(a: Vector3, b: Vector3, c: Vector3, x: float, z: float) -> float:
	var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(d) < 1e-12:
		return -INF
	var wa := ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / d
	var wb := ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / d
	var wc := 1.0 - wa - wb
	if wa < -1e-9 or wb < -1e-9 or wc < -1e-9:
		return -INF
	return wa * a.y + wb * b.y + wc * c.y


## The y of (b - a) x (c - a), in doubles: positive when a, b, c turn counter-clockwise seen from above.
func _cross_y(a: Vector3, b: Vector3, c: Vector3) -> float:
	var ux := float(b.x) - float(a.x)
	var uz := float(b.z) - float(a.z)
	var vx := float(c.x) - float(a.x)
	var vz := float(c.z) - float(a.z)
	return uz * vx - ux * vz


## One body: its pose as Box3D sees it (no scale: scale is baked into the shapes), its material, filter and shapes.
func _body(w: StreamPeerBuffer, b: Node, strings: Array[String]) -> void:
	var recs: Array[ShapeRec] = []
	var mat: PhysicsMaterial
	var origin: Vector3
	var rot: Quaternion
	if b is StaticBody3D:
		var bt := _xf(b)
		var brot := bt.basis.orthonormalized()
		origin = bt.origin
		rot = brot.get_rotation_quaternion()
		mat = (b as StaticBody3D).physics_material_override
		var frame := Transform3D(brot, bt.origin)
		for c in b.get_children():
			if c is CollisionShape3D and c.shape != null and not c.disabled:
				var before := recs.size()
				_shape3d(recs, frame.affine_inverse() * _xf(c), c.shape, _where(c))
				if _has_surface_meta(c):
					for k in range(before, recs.size()):
						recs[k].surface_node = c
		_add_floors(frame, recs)
	else:
		# a StaticBody2D or TileMapLayer: the node's position and rotation about Z
		var g := _xf2(b)
		var u := _unit(g.x)
		var inv := Transform2D(u, Vector2(-u.y, u.x), g.origin).affine_inverse()
		origin = _m3(g.origin)
		rot = _qdir(u)
		mat = _shapes2d(recs, b as Node2D, inv, g)
	if mat and (mat.rough or mat.absorbent):
		_error(_where(b), "PhysicsMaterial rough and absorbent are not supported (Box3D mixes surfaces its own way)")
	var surface := Surface.new()
	if mat:
		surface.friction = mat.friction
		surface.restitution = mat.bounce
	_surface_meta(surface, b)
	w.put_u32(_intern(strings, b.name))
	_v3(w, origin)
	_quat(w, rot)
	_write_surface(w, surface)
	w.put_u64(int(b.get_meta("unified_category", 0)))
	w.put_u16(recs.size())
	for r in recs:
		_write_shape(w, r, surface)


## Whether a CollisionShape3D's metadata gives its shapes a surface of their own.
func _has_surface_meta(c: Node) -> bool:
	return c.has_meta(&"unified_material") or c.has_meta(&"unified_rolling_resistance") \
			or c.has_meta(&"unified_tangent_velocity")


## A node's surface metadata over `surface`: unified_material, unified_rolling_resistance, unified_tangent_velocity.
func _surface_meta(surface: Surface, n: Node) -> void:
	surface.material = int(n.get_meta(&"unified_material", surface.material))
	surface.rolling_resistance = float(n.get_meta(&"unified_rolling_resistance", surface.rolling_resistance))
	surface.tangent_velocity = n.get_meta(&"unified_tangent_velocity", surface.tangent_velocity)


func _write_surface(w: StreamPeerBuffer, surface: Surface) -> void:
	w.put_float(surface.friction)
	w.put_float(surface.restitution)
	w.put_float(surface.rolling_resistance)
	_v3(w, surface.tangent_velocity)
	w.put_u64(surface.material)


## One shape: its own surface is the body's with its CollisionShape3D's metadata over it.
func _write_shape(w: StreamPeerBuffer, r: ShapeRec, body: Surface) -> void:
	w.put_u8(r.kind)
	_v3(w, r.pos)
	_quat(w, r.rot)
	w.put_u8(0 if r.surface_node == null else 1)
	if r.surface_node != null:
		var own := Surface.new()
		own.friction = body.friction
		own.restitution = body.restitution
		own.rolling_resistance = body.rolling_resistance
		own.tangent_velocity = body.tangent_velocity
		own.material = body.material
		_surface_meta(own, r.surface_node)
		_write_surface(w, own)
	match r.kind:
		Shape.BOX:
			_v3(w, r.half)
		Shape.SPHERE:
			w.put_float(r.radius)
		Shape.CAPSULE:
			w.put_float(r.radius)
			w.put_float(r.half_height)
		Shape.HULL:
			w.put_u16(r.points.size())
			for p in r.points:
				_v3(w, p)
		Shape.MESH:
			w.put_u32(r.points.size())
			for p in r.points:
				_v3(w, p)
			w.put_u32(r.triangles.size() / 3)
			for i in r.triangles:
				w.put_u32(i)
			w.put_u32(0)  # no per-triangle materials: Godot's trimesh has none (every triangle is the shape's)
			w.put_u8(0)
		Shape.HEIGHT_FIELD:
			w.put_u16(r.count_x)
			w.put_u16(r.count_z)
			_v3(w, r.scale)
			for h in r.heights:
				w.put_float(h)


func _rec(kind: Shape, pos := Vector3.ZERO, rot := Quaternion.IDENTITY) -> ShapeRec:
	var r := ShapeRec.new()
	r.kind = kind
	r.pos = pos
	r.rot = rot
	return r


func _marker(w: StreamPeerBuffer, m: Node, props: Array, marker_index: Dictionary, strings: Array[String]) -> void:
	w.put_u32(_intern(strings, _kind(m)))
	w.put_u32(_intern(strings, m.name))
	if m is Node2D:
		var g := _xf2(m)
		var sc := g.get_scale()
		_v3(w, _m3(g.origin))
		_quat(w, _qdir(g.x))
		_v3(w, Vector3(sc.x, sc.y, 1.0))
	else:
		var gt := _xf(m)
		_v3(w, gt.origin)
		_quat(w, gt.basis.orthonormalized().get_rotation_quaternion())
		_v3(w, gt.basis.get_scale())
	var kept: Array[Array] = []
	for p: Array in props:
		if _prop_type(p[1]) >= 0:
			kept.append(p)
	w.put_u16(kept.size())
	for p in kept:
		var v: Variant = p[1]
		var t := _prop_type(v)
		w.put_u32(_intern(strings, p[0]))
		w.put_u8(t)
		match t:
			Prop.BOOL:
				w.put_u8(1 if v else 0)
			Prop.INT:
				w.put_32(v)
			Prop.FLOAT:
				w.put_float(v)
			Prop.VEC3:
				_v3(w, Vector3(v.x, v.y, 0.0) if v is Vector2 else v)  # Vector2: raw, z = 0
			Prop.STRING:
				w.put_u32(_intern(strings, str(v)))
			Prop.REF:
				var target: Node = null
				if v is NodePath and not (v as NodePath).is_empty():
					target = m.get_node_or_null(v)
				elif v is Node:
					target = v
				w.put_32(marker_index.get(target, -1))
			Prop.CURVE:
				for sample in _curve_samples(v as Curve):
					w.put_float(sample)
	var pts := PackedVector3Array()
	for c in m.get_children():
		if c is Path3D and c.curve != null:
			for k: int in c.curve.point_count:
				pts.append(_xf(c) * c.curve.get_point_position(k))
			break
		if c is Path2D and c.curve != null:
			for k: int in c.curve.point_count:
				pts.append(_m3(_xf2(c) * c.curve.get_point_position(k)))
			break
	w.put_u16(pts.size())
	for p in pts:
		_v3(w, p)


## A StaticBody2D's or TileMapLayer's shapes in its body's frame (`inv`: from the level's frame; `g`: the node in
## it). Scale (and any skew or mirroring) is baked into the shapes. Returns the physics material.
func _shapes2d(recs: Array[ShapeRec], b: Node2D, inv: Transform2D, g: Transform2D) -> PhysicsMaterial:
	if b is TileMapLayer:
		_tiles(recs, b, inv * g)
		return (b as TileMapLayer).tile_set.get_physics_layer_physics_material(0)
	for c in b.get_children():
		if c is CollisionShape2D and c.shape != null and not c.disabled:
			if c.one_way_collision:
				_error(_where(c), "one-way collision is not supported")
			_shape2d(recs, inv * _xf2(c), c.shape, _where(c))
		elif c is CollisionPolygon2D and not c.disabled:
			if c.build_mode != CollisionPolygon2D.BUILD_SOLIDS:
				_error(_where(c), "a polygon in segments mode is not supported (solids only)")
				continue
			if c.one_way_collision:
				_error(_where(c), "one-way collision is not supported")
			_polygon(recs, inv * _xf2(c), c.polygon, _where(c))
	return (b as StaticBody2D).physics_material_override


## One TileMapLayer's tiles: physics layer 0's polygons of every used cell, cells sorted by (y, x), each polygon
## split into convex parts. `local`: the layer in its body's frame.
func _tiles(recs: Array[ShapeRec], l: TileMapLayer, local: Transform2D) -> void:
	var cells := l.get_used_cells()
	cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	var flags := TileSetAtlasSource.TRANSFORM_FLIP_H | TileSetAtlasSource.TRANSFORM_FLIP_V \
			| TileSetAtlasSource.TRANSFORM_TRANSPOSE
	for cell in cells:
		var where := "%s cell %s" % [_where(l), cell]
		var src := l.tile_set.get_source(l.get_cell_source_id(cell))
		if not src is TileSetAtlasSource:
			_error(where, "scene tiles are not supported")
			continue
		var alt := l.get_cell_alternative_tile(cell)
		var td := (src as TileSetAtlasSource).get_tile_data(l.get_cell_atlas_coords(cell), alt & ~flags)
		if td == null:
			continue
		var at := local * Transform2D(0.0, l.map_to_local(cell))
		for i in td.get_collision_polygons_count(0):
			if td.is_collision_polygon_one_way(0, i):
				_error(where, "one-way collision is not supported")
			var pts := PackedVector2Array()
			for p in td.get_collision_polygon_points(0, i):
				# As the tile map applies an alternative's transform flags.
				var q := Vector2(p.y, p.x) if alt & TileSetAtlasSource.TRANSFORM_TRANSPOSE else p
				if alt & TileSetAtlasSource.TRANSFORM_FLIP_H:
					q.x = -q.x
				if alt & TileSetAtlasSource.TRANSFORM_FLIP_V:
					q.y = -q.y
				pts.append(q)
			_polygon(recs, at, pts, where)


## A polygon (any, non-self-intersecting) as hulls: Godot's convex decomposition, each part extruded.
func _polygon(recs: Array[ShapeRec], local: Transform2D, pts: PackedVector2Array, where: String) -> void:
	var parts := Geometry2D.decompose_polygon_in_convex(pts)
	if parts.is_empty():
		_error(where, "the polygon cannot be split into convex parts")
	for part in parts:
		_hull2d(recs, local, part, where)


func _hull2d(recs: Array[ShapeRec], local: Transform2D, pts: PackedVector2Array, where: String) -> void:
	if pts.size() < 3 or pts.size() > MAX_POLYGON:
		_error(where, "a convex polygon needs 3 to %d points (has %d)" % [MAX_POLYGON, pts.size()])
		return
	var r := _rec(Shape.HULL)
	for p in pts:
		var q := _m3(local * p)
		r.points.append(Vector3(q.x, q.y, -_depth * 0.5))
		r.points.append(Vector3(q.x, q.y, _depth * 0.5))
	recs.append(r)


## One 2D shape in its body's frame (`local`, pixels).
func _shape2d(recs: Array[ShapeRec], local: Transform2D, s: Shape2D, where: String) -> void:
	var sx := local.x.length()
	var sy := local.y.length()
	var pos := _m3(local.origin)
	if s is RectangleShape2D:
		var half := (s as RectangleShape2D).size * 0.5 / _ppm
		var r := _rec(Shape.BOX, pos, _qdir(local.x))
		r.half = Vector3(half.x * sx, half.y * sy, _depth * 0.5)
		recs.append(r)
	elif s is CircleShape2D:
		if not is_equal_approx(sx, sy):
			_error(where, "a circle needs a uniform scale")
		var r := _rec(Shape.SPHERE, pos)
		r.radius = (s as CircleShape2D).radius * sx / _ppm
		recs.append(r)
	elif s is CapsuleShape2D:
		if not is_equal_approx(sx, sy):
			_error(where, "a capsule needs a uniform scale")
		var cap := s as CapsuleShape2D
		var axis := local.y  # the capsule's length, mirrored or not: the rotation that turns +y onto it
		var r := _rec(Shape.CAPSULE, pos, _qdir(Vector2(axis.y, -axis.x)))
		r.radius = cap.radius * sx / _ppm
		r.half_height = maxf(cap.height * 0.5 * sy / _ppm - r.radius, 0.0)
		recs.append(r)
	elif s is ConvexPolygonShape2D:
		_hull2d(recs, local, (s as ConvexPolygonShape2D).points, where)
	else:
		_error(where, "unsupported shape %s (rectangle, circle, capsule, convex polygon)" % s.get_class())


## One 3D shape in its body's frame (`local`, which carries the node's scale).
func _shape3d(recs: Array[ShapeRec], local: Transform3D, s: Shape3D, where: String) -> void:
	var sc := local.basis.get_scale()
	var rot := local.basis.orthonormalized().get_rotation_quaternion()
	if s is BoxShape3D:
		var r := _rec(Shape.BOX, local.origin, rot)
		r.half = (s as BoxShape3D).size * 0.5 * sc
		recs.append(r)
	elif s is SphereShape3D:
		if not is_equal_approx(sc.x, sc.y) or not is_equal_approx(sc.x, sc.z):
			_error(where, "a sphere needs a uniform scale")
		var r := _rec(Shape.SPHERE, local.origin, rot)
		r.radius = (s as SphereShape3D).radius * sc.x
		recs.append(r)
	elif s is CapsuleShape3D:
		if not is_equal_approx(sc.x, sc.z):
			_error(where, "a capsule needs the same x and z scale")
		var cap := s as CapsuleShape3D
		var r := _rec(Shape.CAPSULE, local.origin, rot)
		r.radius = cap.radius * sc.x
		r.half_height = maxf(cap.height * 0.5 * sc.y - cap.radius * sc.x, 0.0)
		recs.append(r)
	elif s is CylinderShape3D:
		# a hull of 2 x 16 points (Box3D has no cylinder), the node's scale baked in
		var cyl := s as CylinderShape3D
		var r := _rec(Shape.HULL)
		for y: float in [-cyl.height * 0.5, cyl.height * 0.5]:
			for k in 16:
				r.points.append(local * Vector3(cyl.radius * CIRCLE_16[k], y, cyl.radius * CIRCLE_16[(k + 12) % 16]))
		recs.append(r)
	elif s is ConvexPolygonShape3D:
		var r := _rec(Shape.HULL)
		var distinct := {}
		for p in (s as ConvexPolygonShape3D).points:
			r.points.append(local * p)
			distinct[local * p] = true
		if distinct.size() > MAX_HULL:
			_error(where, ("a convex shape of %d points, more than %d (Box3D's 128 hull edges): use a simplified " +
					"convex collision, a CylinderShape3D, or split it") % [distinct.size(), MAX_HULL])
			return
		recs.append(r)
	elif s is ConcavePolygonShape3D:
		_mesh3d(recs, local, s as ConcavePolygonShape3D, where)
	elif s is HeightMapShape3D:
		_height_map(recs, local, s as HeightMapShape3D, where)
	else:
		_error(where, ("unsupported shape %s (box, sphere, capsule, cylinder, convex polygon, concave polygon, " +
				"height map)") % s.get_class())


## A concave polygon as a mesh: its faces in the body's frame, vertices welded where exactly equal (in face order),
## each triangle turned from Godot's clockwise front to the file's counter-clockwise (a mirroring scale turns it back).
func _mesh3d(recs: Array[ShapeRec], local: Transform3D, s: ConcavePolygonShape3D, where: String) -> void:
	if s.backface_collision:
		_error(where, "backface_collision is not supported (a level mesh collides from the front)")
		return
	var faces := s.get_faces()
	if faces.size() < 3:
		_error(where, "a concave polygon without faces")
		return
	var r := _rec(Shape.MESH)
	var index := {}
	var order: Array[int] = [0, 2, 1]
	if local.basis.determinant() < 0.0:
		order = [0, 1, 2]
	for f in range(0, faces.size() - 2, 3):
		for k in order:
			var p := local * faces[f + k]
			if not index.has(p):
				index[p] = r.points.size()
				r.points.append(p)
			r.triangles.append(index[p])
	recs.append(r)


## A height map as a height field: Godot's grid is centred on the shape, one unit per cell, scaled by the node; the
## file's pose is the grid's corner, its scale the cell size and height scale.
func _height_map(recs: Array[ShapeRec], local: Transform3D, s: HeightMapShape3D, where: String) -> void:
	if local.basis.determinant() <= 0.0:
		_error(where, "a height map needs a positive scale")
		return
	if s.map_width < 2 or s.map_depth < 2 or s.map_width > 65535 or s.map_depth > 65535:
		_error(where, "a height map needs 2 to 65535 points along each side")
		return
	for h in s.map_data:
		if is_nan(h) or is_inf(h):
			_error(where, "a height map with a NaN or infinite height")
			return
	var corner := local * Vector3(-(s.map_width - 1) * 0.5, 0.0, -(s.map_depth - 1) * 0.5)
	var r := _rec(Shape.HEIGHT_FIELD, corner, local.basis.orthonormalized().get_rotation_quaternion())
	r.count_x = s.map_width
	r.count_z = s.map_depth
	r.scale = local.basis.get_scale()
	r.heights = s.map_data
	recs.append(r)


## A Curve as CURVE_SAMPLES values over its domain: Godot's cubic between two points (control points a third of the
## way along, by each point's tangent), in doubles with + - * / only, so every platform bakes the same bytes
## (Curve.sample is the engine's float code).
func _curve_samples(curve: Curve) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for i in CURVE_SAMPLES:
		var x: float = curve.min_domain + (curve.max_domain - curve.min_domain) * float(i) / float(CURVE_SAMPLES - 1)
		out.append(_curve_at(curve, x))
	return out


func _curve_at(curve: Curve, x: float) -> float:
	var count := curve.point_count
	if count == 0:
		return 0.0
	var first := curve.get_point_position(0)
	if count == 1 or x <= first.x:
		return first.y
	var last := curve.get_point_position(count - 1)
	if x >= last.x:
		return last.y
	var k := 0
	while curve.get_point_position(k + 1).x < x:
		k += 1
	var a := curve.get_point_position(k)
	var b := curve.get_point_position(k + 1)
	var d: float = b.x - a.x
	if d <= 0.0:
		return b.y
	var t: float = (x - a.x) / d
	var ya: float = a.y + d / 3.0 * curve.get_point_right_tangent(k)
	var yb: float = b.y - d / 3.0 * curve.get_point_left_tangent(k + 1)
	var u: float = 1.0 - t
	return a.y * u * u * u + ya * u * u * t * 3.0 + yb * u * t * t * 3.0 + b.y * t * t * t


func _prop_type(v: Variant) -> int:
	if v is bool:
		return Prop.BOOL
	if v is int:
		return Prop.INT
	if v is float:
		return Prop.FLOAT
	if v is Vector3 or v is Vector2:
		return Prop.VEC3
	if v is String or v is StringName:
		return Prop.STRING
	if v is Curve:
		return Prop.CURVE
	if v is NodePath or v is Node or v == null:
		return Prop.REF if v != null else -1
	return -1


## A 2D point in pixels as a sim point in metres (z = 0).
func _m3(p: Vector2) -> Vector3:
	return Vector3(p.x / _ppm, p.y / _ppm, 0.0)


## `v` (not zero) at unit length, in doubles.
func _unit(v: Vector2) -> Vector2:
	var x := float(v.x)
	var y := float(v.y)
	var l := sqrt(x * x + y * y)
	return Vector2(x / l, y / l)


## The rotation about +Z that turns +x onto the direction `d`, as a quaternion with w >= 0. Only + − × ÷ sqrt, in
## doubles: atan2, sin and cos come from the platform's math library, and a level must export to the same bytes on
## every platform (a 180° turn gives exactly (0, 0, 1, 0)).
func _qdir(d: Vector2) -> Quaternion:
	var u := _unit(d)
	var c := float(u.x)
	var s := float(u.y)
	if c >= 0.0:
		var w := sqrt((1.0 + c) * 0.5)
		return Quaternion(0.0, 0.0, s / (2.0 * w), w)
	var z := sqrt((1.0 - c) * 0.5)
	if s < 0.0:
		z = -z
	return Quaternion(0.0, 0.0, z, s / (2.0 * z) + 0.0)  # + 0.0: no -0


func _v3(w: StreamPeerBuffer, v: Vector3) -> void:
	w.put_float(v.x)
	w.put_float(v.y)
	w.put_float(v.z)


func _quat(w: StreamPeerBuffer, q: Quaternion) -> void:
	w.put_float(q.x)
	w.put_float(q.y)
	w.put_float(q.z)
	w.put_float(q.w)
