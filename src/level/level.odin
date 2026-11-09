// Godot-authored levels for the sim (spec/level.md): the `UNLV` file the exporter writes, read into
// plain slices. Deterministic and pointer-free in what it returns to the sim (the Level lives in the
// World, outside the block). The bytes stay owned by the caller: strings are views into them.
//
// File (little-endian, unified:wire): "UNLV", version u16, then
//   strings: count u32, each len u16 + UTF-8 bytes (index 0 is "")
//   bodies:  count u32, each name u32, pos 3f32, rot 4f32 (x y z w), friction f32, restitution f32,
//            category u64, material u64, shape count u16, each shape:
//              kind u8, pos 3f32, rot 4f32 (body-local), then box: half 3f32 | sphere: radius f32 |
//              capsule: radius f32, half_height f32 (segment along local Y) | hull: count u16, points 3f32
//   markers: count u32, each kind u32, name u32, pos 3f32, rot 4f32, scale 3f32,
//            prop count u16, each key u32, type u8, value (bool u8 | int i32 | float f32 | vec3 3f32 |
//            string u32 | ref i32: marker index, -1 none), then path point count u16, points 3f32 (world)
package level

import "../wire"

MAGIC :: "UNLV"
VERSION :: 1

Shape_Kind :: enum u8 {
	Box,
	Sphere,
	Capsule,
	Hull,
}

Shape :: struct {
	kind:        Shape_Kind,
	pos:         [3]f32, // body-local
	rot:         [4]f32,
	half:        [3]f32, // Box
	radius:      f32, // Sphere, Capsule
	half_height: f32, // Capsule: half the segment, along local Y
	points:      [][3]f32, // Hull, body-local
}

Body :: struct {
	name:        string,
	pos:         [3]f32,
	rot:         [4]f32,
	friction:    f32,
	restitution: f32,
	category:    u64, // filter bits (0: the game's default)
	material:    u64, // user material id (0: none)
	shapes:      []Shape,
}

Prop_Type :: enum u8 {
	Bool,
	Int,
	Float,
	Vec3,
	String,
	Ref,
}

Prop :: struct {
	key:  string,
	type: Prop_Type,
	b:    bool,
	i:    i32, // Int; Ref: the marker index (-1: none)
	f:    f32,
	v:    [3]f32,
	s:    string,
}

Marker :: struct {
	index: int, // in Level.markers (scene-tree order)
	kind:  string,
	name:  string,
	pos:   [3]f32,
	rot:   [4]f32,
	scale: [3]f32,
	props: []Prop,
	path:  [][3]f32, // a Path3D child's points, world space (empty: none)
}

Level :: struct {
	bodies:  []Body,
	markers: []Marker,
	// Backing storage the slices above point into.
	strings: []string,
	shapes:  []Shape,
	props:   []Prop,
	points:  [][3]f32,
}

// The level's identity (XXH3 of the file), as recorded in logs and snapshots: sim.content_hash.

destroy :: proc(l: ^Level) {
	delete(l.bodies)
	delete(l.markers)
	delete(l.strings)
	delete(l.shapes)
	delete(l.props)
	delete(l.points)
	l^ = {}
}

@(private)
Rd :: struct {
	r:       wire.Reader,
	strings: []string,
	shapes:  [dynamic]Shape,
	props:   [dynamic]Prop,
	points:  [dynamic][3]f32,
	ok:      bool,
}

@(private)
f32_ :: proc(d: ^Rd) -> f32 {
	return transmute(f32)wire.r_u32(&d.r)
}

@(private)
v3_ :: proc(d: ^Rd) -> [3]f32 {
	return {f32_(d), f32_(d), f32_(d)}
}

@(private)
q_ :: proc(d: ^Rd) -> [4]f32 {
	return {f32_(d), f32_(d), f32_(d), f32_(d)}
}

@(private)
str_ :: proc(d: ^Rd) -> string {
	i := int(wire.r_u32(&d.r))
	if i >= len(d.strings) {
		d.ok = false
		return ""
	}
	return d.strings[i]
}

// Points are read into one array; slices are fixed up at the end (it may grow while reading).
@(private)
Span :: struct {
	start, n: int,
}

@(private)
points_ :: proc(d: ^Rd) -> Span {
	n := int(wire.r_u16(&d.r))
	s := Span{len(d.points), n}
	for _ in 0 ..< n {
		append(&d.points, v3_(d))
	}
	return s
}

// Parses a level file. The strings are views into `data`, which must outlive the Level.
load :: proc(data: []u8, allocator := context.allocator) -> (l: Level, ok: bool) {
	context.allocator = allocator
	d := Rd {
		r  = wire.reader_make(data),
		ok = true,
	}
	magic := wire.r_bytes(&d.r, 4)
	version := wire.r_u16(&d.r)
	if !d.r.ok || string(magic) != MAGIC || version != VERSION do return
	ns := int(wire.r_u32(&d.r))
	if ns > len(data) do return
	strs := make([]string, ns)
	for i in 0 ..< ns {
		n := int(wire.r_u16(&d.r))
		strs[i] = string(wire.r_bytes(&d.r, n))
	}
	d.strings = strs

	shape_pts: [dynamic]Span
	defer delete(shape_pts)
	body_shapes: [dynamic]Span
	defer delete(body_shapes)
	nb := int(wire.r_u32(&d.r))
	if nb > len(data) do nb = 0
	bodies := make([]Body, nb)
	for &b in bodies {
		b.name = str_(&d)
		b.pos = v3_(&d)
		b.rot = q_(&d)
		b.friction = f32_(&d)
		b.restitution = f32_(&d)
		b.category = wire.r_u64(&d.r)
		b.material = wire.r_u64(&d.r)
		n := int(wire.r_u16(&d.r))
		append(&body_shapes, Span{len(d.shapes), n})
		for _ in 0 ..< n {
			sh := Shape {
				kind = Shape_Kind(wire.r_u8(&d.r)),
				pos  = v3_(&d),
				rot  = q_(&d),
			}
			span: Span
			switch sh.kind {
			case .Box:
				sh.half = v3_(&d)
			case .Sphere:
				sh.radius = f32_(&d)
			case .Capsule:
				sh.radius = f32_(&d)
				sh.half_height = f32_(&d)
			case .Hull:
				span = points_(&d)
			case:
				d.ok = false
			}
			append(&shape_pts, span)
			append(&d.shapes, sh)
		}
		if !d.r.ok || !d.ok do break
	}

	marker_props: [dynamic]Span
	defer delete(marker_props)
	marker_path: [dynamic]Span
	defer delete(marker_path)
	nm := int(wire.r_u32(&d.r))
	if nm > len(data) do nm = 0
	markers := make([]Marker, nm)
	for &m, i in markers {
		m.index = i
		m.kind = str_(&d)
		m.name = str_(&d)
		m.pos = v3_(&d)
		m.rot = q_(&d)
		m.scale = v3_(&d)
		np := int(wire.r_u16(&d.r))
		append(&marker_props, Span{len(d.props), np})
		for _ in 0 ..< np {
			p := Prop {
				key  = str_(&d),
				type = Prop_Type(wire.r_u8(&d.r)),
			}
			switch p.type {
			case .Bool:
				p.b = wire.r_u8(&d.r) != 0
			case .Int, .Ref:
				p.i = i32(wire.r_u32(&d.r))
			case .Float:
				p.f = f32_(&d)
			case .Vec3:
				p.v = v3_(&d)
			case .String:
				p.s = str_(&d)
			case:
				d.ok = false
			}
			append(&d.props, p)
		}
		append(&marker_path, points_(&d))
		if !d.r.ok || !d.ok do break
	}

	l = {
		bodies  = bodies,
		markers = markers,
		strings = strs,
		shapes  = d.shapes[:],
		props   = d.props[:],
		points  = d.points[:],
	}
	if !d.r.ok || !d.ok || d.r.pos != len(data) {
		destroy(&l)
		return {}, false
	}
	for &sh, i in l.shapes {
		sp := shape_pts[i]
		sh.points = l.points[sp.start:][:sp.n]
	}
	for &b, i in l.bodies {
		sp := body_shapes[i]
		b.shapes = l.shapes[sp.start:][:sp.n]
	}
	for &m, i in l.markers {
		sp := marker_props[i]
		m.props = l.props[sp.start:][:sp.n]
		pp := marker_path[i]
		m.path = l.points[pp.start:][:pp.n]
	}
	return l, true
}

// The markers of one kind, in file order (temp-allocated by default).
find_all :: proc(l: ^Level, kind: string, allocator := context.temp_allocator) -> []^Marker {
	out := make([dynamic]^Marker, 0, 8, allocator)
	for &m in l.markers {
		if m.kind == kind do append(&out, &m)
	}
	return out[:]
}

// The first marker with this name (nil: none).
find_named :: proc(l: ^Level, name: string) -> ^Marker {
	for &m in l.markers {
		if m.name == name do return &m
	}
	return nil
}

prop :: proc(m: ^Marker, key: string) -> ^Prop {
	for &p in m.props {
		if p.key == key do return &p
	}
	return nil
}

prop_f32 :: proc(m: ^Marker, key: string, default: f32 = 0) -> f32 {
	p := prop(m, key)
	if p == nil do return default
	#partial switch p.type {
	case .Float:
		return p.f
	case .Int:
		return f32(p.i)
	}
	return default
}

prop_int :: proc(m: ^Marker, key: string, default: int = 0) -> int {
	p := prop(m, key)
	if p == nil || p.type != .Int do return default
	return int(p.i)
}

prop_bool :: proc(m: ^Marker, key: string, default := false) -> bool {
	p := prop(m, key)
	if p == nil || p.type != .Bool do return default
	return p.b
}

prop_vec3 :: proc(m: ^Marker, key: string, default := [3]f32{}) -> [3]f32 {
	p := prop(m, key)
	if p == nil || p.type != .Vec3 do return default
	return p.v
}

prop_string :: proc(m: ^Marker, key: string, default := "") -> string {
	p := prop(m, key)
	if p == nil || p.type != .String do return default
	return p.s
}

// A NodePath property pointing at another marker: its index, or -1.
prop_ref :: proc(m: ^Marker, key: string) -> int {
	p := prop(m, key)
	if p == nil || p.type != .Ref do return -1
	return int(p.i)
}
