extends SceneTree
## unified's level exporter (src/level/SPEC.md; the UNLV format in src/level/level.odin), run by `uni bake`:
##   godot --headless --path <project> -s res://addons/unified/level_export.gd -- [--check] [--scene=res://...]...
## Exports the --scene ones (uni bake passes a game's level scenes: src/level/SPEC.md, Baking), else every
## res://game/levels/*.tscn (not subfolders: those hold the parts a level instances), to the .level file next to each. --check writes nothing and fails when a committed file differs from a fresh
## export. A scene with findings is not written. Level scenes are instantiated, not run: no node is added to the
## tree and no _ready runs.
## A 3D level (any root but a Node2D): StaticBody3D + CollisionShape3D children (box, sphere, capsule, convex
## polygon); the body's physics_material_override gives friction and bounce, metadata unified_category /
## unified_material the filter category and user material.
## A 2D level (a Node2D root) maps onto the sim's XY plane at z = 0 (x right, y down, rotations about +Z), pixels
## divided by the game's view_scale (Unified.view_scale; a fixture baked without a game: the root's metadata
## unified_px_per_m), shapes extruded to ±unified_depth_m / 2 (default 1): StaticBody2D + CollisionShape2D
## (rectangle, circle, capsule, convex polygon) or CollisionPolygon2D (solids, split into convex parts) children, and
## TileMapLayers (one body each, the tiles' physics layer 0 polygons).
## Markers: nodes whose script has `const UNIFIED_KIND` (or a `unified_kind` property, or metadata): kind, name,
## global transform, every exported script property, the points of a Path3D / Path2D child.
## Prints one `UNIFIED_RESULT {ok, check, levels: [{scene, level, bytes, changed}], errors}` line; each error names its
## node. A plain SceneTree script, not a UnifiedTool: it also runs in projects without unified's extension (the 2D
## fixture in tests/godot).

const MAGIC := "UNLV"
const VERSION := 2
const MAX_POLYGON := 32  # points of one 2D convex part: extruded, a hull of 64, Box3D's vertex cap
enum Shape { BOX, SPHERE, CAPSULE, HULL }
enum Prop { BOOL, INT, FLOAT, VEC3, STRING, REF }


## One shape as the file stores it, in its body's frame (metres), from either dimension.
class ShapeRec:
	var kind: Shape
	var pos := Vector3.ZERO
	var rot := Quaternion.IDENTITY
	var half := Vector3.ZERO  # BOX
	var radius := 0.0  # SPHERE, CAPSULE
	var half_height := 0.0  # CAPSULE: half the segment, along local Y
	var points := PackedVector3Array()  # HULL


var errors: Array[String] = []
var _root: Node
var _ppm := 0.0  # a 2D level's pixels per metre; 0: a 3D level
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
	_ppm = 0.0
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
	w.put_u32(bodies.size())
	for b in bodies:
		_body(w, b, strings)
	w.put_u32(markers.size())
	for i in markers.size():
		_marker(w, markers[i], marker_props[i], marker_index, strings)
	return w.data_array


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
				_shape3d(recs, frame.affine_inverse() * _xf(c), c.shape, _where(c))
	else:
		# a StaticBody2D or TileMapLayer: the node's position and rotation about Z
		var g := _xf2(b)
		var u := _unit(g.x)
		var inv := Transform2D(u, Vector2(-u.y, u.x), g.origin).affine_inverse()
		origin = _m3(g.origin)
		rot = _qdir(u)
		mat = _shapes2d(recs, b as Node2D, inv, g)
	w.put_u32(_intern(strings, b.name))
	_v3(w, origin)
	_quat(w, rot)
	w.put_float(mat.friction if mat else 0.6)
	w.put_float(mat.bounce if mat else 0.0)
	w.put_u64(int(b.get_meta("unified_category", 0)))
	w.put_u64(int(b.get_meta("unified_material", 0)))
	w.put_u16(recs.size())
	for r in recs:
		_write_shape(w, r)


func _write_shape(w: StreamPeerBuffer, r: ShapeRec) -> void:
	w.put_u8(r.kind)
	_v3(w, r.pos)
	_quat(w, r.rot)
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
	elif s is ConvexPolygonShape3D:
		var r := _rec(Shape.HULL)
		for p in (s as ConvexPolygonShape3D).points:
			r.points.append(local * p)
		recs.append(r)
	else:
		_error(where, "unsupported shape %s (box, sphere, capsule, convex polygon)" % s.get_class())


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
