// Godot-authored levels for the sim (src/level/SPEC.md): the `UNLV` file the exporter writes, read into
// plain slices. Deterministic and pointer-free in what it returns to the sim (the Level lives in the
// World, outside the block). The bytes stay owned by the caller: strings are views into them.
//
// File (little-endian, unified:wire): "UNLV", version u16, px_per_m f32 (0: a 3D level), then
//   strings: count u32, each len u16 + UTF-8 bytes (index 0 is "")
//   bodies:  count u32, each name u32, pos 3f32, rot 4f32 (x y z w), friction f32, restitution f32,
//            category u64, material u64, shape count u16, each shape:
//              kind u8, pos 3f32, rot 4f32 (body-local), then box: half 3f32 | sphere: radius f32 |
//              capsule: radius f32, half_height f32 (segment along local Y) | hull: count u16, points 3f32
//   markers: count u32, each kind u32, name u32, pos 3f32, rot 4f32, scale 3f32,
//            prop count u16, each key u32, type u8, value (bool u8 | int i32 | float f32 | vec3 3f32 |
//            string u32 | ref i32: marker index, -1 none), then path point count u16, points 3f32 (world)
package level

import "unified:wire"

MAGIC :: "UNLV"
VERSION :: 2

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
	// A 2D level's pixels per metre (its view maps metres back to pixels with it); 0: a 3D level.
	px_per_m: f32,
	bodies:   []Body,
	markers:  []Marker,
	// Backing storage the slices above point into.
	strings:  []string,
	shapes:   []Shape,
	props:    []Prop,
	points:   [][3]f32,
}

// Frees the slices load allocated, through the context allocator (so under the one load was given), and zeroes
// the Level. Its strings point into the file bytes, which the caller owns.
destroy :: proc(level: ^Level) {
	delete(level.bodies)
	delete(level.markers)
	delete(level.strings)
	delete(level.shapes)
	delete(level.props)
	delete(level.points)
	level^ = {}
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
f32_ :: proc(decoder: ^Rd) -> f32 {
	return transmute(f32)wire.r_u32(&decoder.r)
}

@(private)
v3_ :: proc(decoder: ^Rd) -> [3]f32 {
	return {f32_(decoder), f32_(decoder), f32_(decoder)}
}

@(private)
q_ :: proc(decoder: ^Rd) -> [4]f32 {
	return {f32_(decoder), f32_(decoder), f32_(decoder), f32_(decoder)}
}

@(private)
str_ :: proc(decoder: ^Rd) -> string {
	i := int(wire.r_u32(&decoder.r))
	if i >= len(decoder.strings) {
		decoder.ok = false
		return ""
	}
	return decoder.strings[i]
}

// Points are read into one array; slices are fixed up at the end (it may grow while reading).
@(private)
Span :: struct {
	start, n: int,
}

@(private)
points_ :: proc(decoder: ^Rd) -> Span {
	count := int(wire.r_u16(&decoder.r))
	span := Span{len(decoder.points), count}
	for _ in 0 ..< count {
		append(&decoder.points, v3_(decoder))
	}
	return span
}

// Parses a level file. The strings are views into `data`, which must outlive the Level.
load :: proc(data: []u8, allocator := context.allocator) -> (level: Level, ok: bool) {
	context.allocator = allocator
	decoder := Rd {
		r  = wire.reader_make(data),
		ok = true,
	}
	magic := wire.r_bytes(&decoder.r, 4)
	version := wire.r_u16(&decoder.r)
	if !decoder.r.ok || string(magic) != MAGIC || version != VERSION do return
	px_per_m := f32_(&decoder)
	string_count := int(wire.r_u32(&decoder.r))
	if string_count > len(data) do return
	string_table := make([]string, string_count)
	for i in 0 ..< string_count {
		count := int(wire.r_u16(&decoder.r))
		string_table[i] = string(wire.r_bytes(&decoder.r, count))
	}
	decoder.strings = string_table

	shape_pts: [dynamic]Span
	defer delete(shape_pts)
	body_shapes: [dynamic]Span
	defer delete(body_shapes)
	body_count := int(wire.r_u32(&decoder.r))
	if body_count > len(data) do body_count = 0
	bodies := make([]Body, body_count)
	for &body in bodies {
		body.name = str_(&decoder)
		body.pos = v3_(&decoder)
		body.rot = q_(&decoder)
		body.friction = f32_(&decoder)
		body.restitution = f32_(&decoder)
		body.category = wire.r_u64(&decoder.r)
		body.material = wire.r_u64(&decoder.r)
		count := int(wire.r_u16(&decoder.r))
		append(&body_shapes, Span{len(decoder.shapes), count})
		for _ in 0 ..< count {
			shape := Shape {
				kind = Shape_Kind(wire.r_u8(&decoder.r)),
				pos  = v3_(&decoder),
				rot  = q_(&decoder),
			}
			span: Span
			switch shape.kind {
			case .Box:
				shape.half = v3_(&decoder)
			case .Sphere:
				shape.radius = f32_(&decoder)
			case .Capsule:
				shape.radius = f32_(&decoder)
				shape.half_height = f32_(&decoder)
			case .Hull:
				span = points_(&decoder)
			case:
				decoder.ok = false
			}
			append(&shape_pts, span)
			append(&decoder.shapes, shape)
		}
		if !decoder.r.ok || !decoder.ok do break
	}

	marker_props: [dynamic]Span
	defer delete(marker_props)
	marker_path: [dynamic]Span
	defer delete(marker_path)
	marker_count := int(wire.r_u32(&decoder.r))
	if marker_count > len(data) do marker_count = 0
	markers := make([]Marker, marker_count)
	for &marker, i in markers {
		marker.index = i
		marker.kind = str_(&decoder)
		marker.name = str_(&decoder)
		marker.pos = v3_(&decoder)
		marker.rot = q_(&decoder)
		marker.scale = v3_(&decoder)
		prop_count := int(wire.r_u16(&decoder.r))
		append(&marker_props, Span{len(decoder.props), prop_count})
		for _ in 0 ..< prop_count {
			property := Prop {
				key  = str_(&decoder),
				type = Prop_Type(wire.r_u8(&decoder.r)),
			}
			switch property.type {
			case .Bool:
				property.b = wire.r_u8(&decoder.r) != 0
			case .Int, .Ref:
				property.i = i32(wire.r_u32(&decoder.r))
			case .Float:
				property.f = f32_(&decoder)
			case .Vec3:
				property.v = v3_(&decoder)
			case .String:
				property.s = str_(&decoder)
			case:
				decoder.ok = false
			}
			append(&decoder.props, property)
		}
		append(&marker_path, points_(&decoder))
		if !decoder.r.ok || !decoder.ok do break
	}

	level = {
		px_per_m = px_per_m,
		bodies   = bodies,
		markers  = markers,
		strings  = string_table,
		shapes   = decoder.shapes[:],
		props    = decoder.props[:],
		points   = decoder.points[:],
	}
	if !decoder.r.ok || !decoder.ok || decoder.r.pos != len(data) {
		destroy(&level)
		return {}, false
	}
	for &shape, i in level.shapes {
		span := shape_pts[i]
		shape.points = level.points[span.start:][:span.n]
	}
	for &body, i in level.bodies {
		span := body_shapes[i]
		body.shapes = level.shapes[span.start:][:span.n]
	}
	for &marker, i in level.markers {
		span := marker_props[i]
		marker.props = level.props[span.start:][:span.n]
		path_span := marker_path[i]
		marker.path = level.points[path_span.start:][:path_span.n]
	}
	return level, true
}


// The first marker with this name (nil: none).
find_named :: proc(level: ^Level, name: string) -> ^Marker {
	for &marker in level.markers {
		if marker.name == name do return &marker
	}
	return nil
}

// The marker's property with this key (nil: none); the typed prop_* getters below read through it.
prop :: proc(marker: ^Marker, key: string) -> ^Prop {
	for &property in marker.props {
		if property.key == key do return &property
	}
	return nil
}

// A Float property, or an Int one converted, so an exported float that holds a whole number reads the same;
// `default` when it is missing or of another type.
prop_f32 :: proc(marker: ^Marker, key: string, default: f32 = 0) -> f32 {
	property := prop(marker, key)
	if property == nil do return default
	#partial switch property.type {
	case .Float:
		return property.f
	case .Int:
		return f32(property.i)
	}
	return default
}

// An Int property, or `default` when it is missing or of another type.
prop_int :: proc(marker: ^Marker, key: string, default: int = 0) -> int {
	property := prop(marker, key)
	if property == nil || property.type != .Int do return default
	return int(property.i)
}

// A Bool property, or `default` when it is missing or of another type.
prop_bool :: proc(marker: ^Marker, key: string, default := false) -> bool {
	property := prop(marker, key)
	if property == nil || property.type != .Bool do return default
	return property.b
}

// A Vector3 property, or `default` when it is missing or of another type.
prop_vec3 :: proc(marker: ^Marker, key: string, default := [3]f32{}) -> [3]f32 {
	property := prop(marker, key)
	if property == nil || property.type != .Vec3 do return default
	return property.v
}

// A Vector2 property: written as a Vec3 with z = 0, raw (not converted to metres).
prop_vec2 :: proc(marker: ^Marker, key: string, default := [2]f32{}) -> [2]f32 {
	property := prop(marker, key)
	if property == nil || property.type != .Vec3 do return default
	return property.v.xy
}

// A String property (pointing into the file bytes), or `default` when it is missing or of another type.
prop_string :: proc(marker: ^Marker, key: string, default := "") -> string {
	property := prop(marker, key)
	if property == nil || property.type != .String do return default
	return property.s
}

// A NodePath property pointing at another marker: its index, or -1.
prop_ref :: proc(marker: ^Marker, key: string) -> int {
	property := prop(marker, key)
	if property == nil || property.type != .Ref do return -1
	return int(property.i)
}
