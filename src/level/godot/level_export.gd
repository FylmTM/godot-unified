extends SceneTree
## unified's level exporter (spec/level.md, the UNLV format in src/level/level.odin). The tools copy it into a
## game's .uni/tools/ and run it headless:
##   godot --headless --path games/<game> -s res://.uni/tools/level_export.gd -- [--check] [--scene=res://...]
## Exports every res://game/levels/*.tscn (not subfolders: those hold the parts a level instances) to the
## .level file next to it. --check writes nothing and fails when a committed file differs from a fresh export.
## Geometry: StaticBody3D + CollisionShape3D children (box, sphere, capsule, convex polygon); the body's
## physics_material_override gives friction and bounce, metadata unified_category / unified_material the filter
## category and user material. Markers: nodes whose script has `const UNIFIED_KIND` (or metadata unified_kind):
## kind, name, global transform, every exported script property, the points of a Path3D child.
## Prints one `LEVEL_JSON {...}` line.

const MAGIC := "UNLV"
const VERSION := 1
enum Shape { BOX, SPHERE, CAPSULE, HULL }
enum Prop { BOOL, INT, FLOAT, VEC3, STRING, REF }

var errors: Array[String] = []


func _initialize() -> void:
	var check := false
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a == "--check":
			check = true
		elif a.begins_with("--scene="):
			only = a.trim_prefix("--scene=")
	var scenes: Array[String] = []
	if only != "":
		scenes.append(only)
	else:
		var dir := DirAccess.open("res://game/levels")
		if dir:
			for f in dir.get_files():
				if f.ends_with(".tscn"):
					scenes.append("res://game/levels/" + f)
	scenes.sort()
	var out := []
	var ok := true
	for path in scenes:
		var bytes := export_scene(path)
		if bytes.is_empty():
			ok = false
			continue
		var target := path.get_basename() + ".level"
		var old := FileAccess.get_file_as_bytes(target)
		var same := old == bytes
		if not check and not same:
			var f := FileAccess.open(target, FileAccess.WRITE)
			if f == null:
				errors.append("cannot write " + target)
				ok = false
				continue
			f.store_buffer(bytes)
			f.close()
		if check and not same:
			errors.append("%s is stale: run `python tools/dev.py game export-level`" % target)
			ok = false
		out.append({"scene": path, "level": target, "bytes": bytes.size(), "changed": not same})
	ok = ok and errors.is_empty()
	print("LEVEL_JSON " + JSON.stringify({"ok": ok, "check": check, "levels": out, "errors": errors}))
	quit(0 if ok else 1)


func export_scene(path: String) -> PackedByteArray:
	var ps := load(path) as PackedScene
	if ps == null:
		errors.append("cannot load " + path)
		return PackedByteArray()
	var root := ps.instantiate()
	get_root().add_child(root)
	var bodies := []
	var markers := []
	_collect(root, bodies, markers)
	var marker_index := {}
	for i in markers.size():
		marker_index[markers[i]] = i
	var strings := [""]
	var bytes := _encode(bodies, markers, marker_index, strings)
	root.queue_free()
	return bytes


func _collect(n: Node, bodies: Array, markers: Array) -> void:
	if n is StaticBody3D:
		bodies.append(n)
	if _kind(n) != "":
		markers.append(n)
	for c in n.get_children():
		_collect(c, bodies, markers)


func _kind(n: Node) -> String:
	var s: Script = n.get_script()
	if s != null:
		var consts := s.get_script_constant_map()
		if consts.has("UNIFIED_KIND"):
			return str(consts["UNIFIED_KIND"])
	if n.has_meta("unified_kind"):
		return str(n.get_meta("unified_kind"))
	return ""


func _intern(strings: Array, s: String) -> int:
	var i := strings.find(s)
	if i >= 0:
		return i
	strings.append(s)
	return strings.size() - 1


## Exported script properties of a marker, in declaration order.
func _props(n: Node) -> Array:
	var out := []
	var s: Script = n.get_script()
	if s == null:
		return out
	for p in s.get_script_property_list():
		var usage: int = p["usage"]
		if usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0 or usage & PROPERTY_USAGE_EDITOR == 0:
			continue
		out.append([p["name"], n.get(p["name"])])
	return out


func _encode(bodies: Array, markers: Array, marker_index: Dictionary, strings: Array) -> PackedByteArray:
	# The string table comes first, in the order the reader meets the strings.
	for b in bodies:
		_intern(strings, b.name)
	var mprops := []
	for m in markers:
		_intern(strings, _kind(m))
		_intern(strings, m.name)
		var ps := _props(m)
		mprops.append(ps)
		for p in ps:
			_intern(strings, p[0])
			if p[1] is String or p[1] is StringName:
				_intern(strings, str(p[1]))
	var w := StreamPeerBuffer.new()
	w.big_endian = false
	w.put_data(MAGIC.to_ascii_buffer())
	w.put_u16(VERSION)
	w.put_u32(strings.size())
	for s in strings:
		var u: PackedByteArray = s.to_utf8_buffer()
		w.put_u16(u.size())
		w.put_data(u)
	w.put_u32(bodies.size())
	for b: StaticBody3D in bodies:
		var bt := b.global_transform
		var brot := bt.basis.orthonormalized()
		var frame := Transform3D(brot, bt.origin)  # the body as Box3D sees it: no scale
		w.put_u32(_intern(strings, b.name))
		_v3(w, bt.origin)
		_quat(w, brot.get_rotation_quaternion())
		var mat := b.physics_material_override
		w.put_float(mat.friction if mat else 0.6)
		w.put_float(mat.bounce if mat else 0.0)
		w.put_u64(int(b.get_meta("unified_category", 0)))
		w.put_u64(int(b.get_meta("unified_material", 0)))
		var shapes := []
		for c in b.get_children():
			if c is CollisionShape3D and c.shape != null and not c.disabled:
				shapes.append(c)
		w.put_u16(shapes.size())
		for c: CollisionShape3D in shapes:
			_shape(w, frame.affine_inverse() * c.global_transform, c.shape, b.name + "/" + c.name)
	w.put_u32(markers.size())
	for i in markers.size():
		var m: Node3D = markers[i]
		var gt := m.global_transform
		w.put_u32(_intern(strings, _kind(m)))
		w.put_u32(_intern(strings, m.name))
		_v3(w, gt.origin)
		_quat(w, gt.basis.orthonormalized().get_rotation_quaternion())
		_v3(w, gt.basis.get_scale())
		var ps: Array = mprops[i]
		var kept := []
		for p in ps:
			if _prop_type(p[1]) >= 0:
				kept.append(p)
		w.put_u16(kept.size())
		for p in kept:
			var v = p[1]
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
					_v3(w, v)
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
				for k in c.curve.point_count:
					pts.append(c.global_transform * c.curve.get_point_position(k))
				break
		w.put_u16(pts.size())
		for p in pts:
			_v3(w, p)
	return w.data_array


func _prop_type(v) -> int:
	if v is bool:
		return Prop.BOOL
	if v is int:
		return Prop.INT
	if v is float:
		return Prop.FLOAT
	if v is Vector3:
		return Prop.VEC3
	if v is String or v is StringName:
		return Prop.STRING
	if v is NodePath or v is Node or v == null:
		return Prop.REF if v != null else -1
	return -1


func _shape(w: StreamPeerBuffer, local: Transform3D, s: Shape3D, where: String) -> void:
	var sc := local.basis.get_scale()
	var rot := local.basis.orthonormalized().get_rotation_quaternion()
	if s is BoxShape3D:
		w.put_u8(Shape.BOX)
		_v3(w, local.origin)
		_quat(w, rot)
		_v3(w, (s as BoxShape3D).size * 0.5 * sc)
	elif s is SphereShape3D:
		if not is_equal_approx(sc.x, sc.y) or not is_equal_approx(sc.x, sc.z):
			errors.append("%s: a sphere needs a uniform scale" % where)
		w.put_u8(Shape.SPHERE)
		_v3(w, local.origin)
		_quat(w, rot)
		w.put_float((s as SphereShape3D).radius * sc.x)
	elif s is CapsuleShape3D:
		if not is_equal_approx(sc.x, sc.z):
			errors.append("%s: a capsule needs the same x and z scale" % where)
		var cap := s as CapsuleShape3D
		w.put_u8(Shape.CAPSULE)
		_v3(w, local.origin)
		_quat(w, rot)
		w.put_float(cap.radius * sc.x)
		w.put_float(maxf(cap.height * 0.5 * sc.y - cap.radius * sc.x, 0.0))
	elif s is ConvexPolygonShape3D:
		w.put_u8(Shape.HULL)
		_v3(w, Vector3.ZERO)
		_quat(w, Quaternion.IDENTITY)
		var pts := (s as ConvexPolygonShape3D).points
		w.put_u16(pts.size())
		for p in pts:
			_v3(w, local * p)
	else:
		errors.append("%s: unsupported shape %s (box, sphere, capsule, convex polygon)" % [where, s.get_class()])
		w.put_u8(Shape.SPHERE)
		_v3(w, local.origin)
		_quat(w, rot)
		w.put_float(0.01)


func _v3(w: StreamPeerBuffer, v: Vector3) -> void:
	w.put_float(v.x)
	w.put_float(v.y)
	w.put_float(v.z)


func _quat(w: StreamPeerBuffer, q: Quaternion) -> void:
	w.put_float(q.x)
	w.put_float(q.y)
	w.put_float(q.z)
	w.put_float(q.w)
