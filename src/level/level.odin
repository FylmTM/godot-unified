// Godot-authored levels for the sim (src/level/README.md): the `UNLV` file the exporter writes, read into
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

import "base:intrinsics"
import "base:runtime"

import "unified:wire"

MAGIC :: "UNLV"
VERSION :: 2 // bump on any change to a .level file's bytes (the sim-change skill)

// What a level shape is: a Godot box, sphere, capsule or convex polygon (a 2D level's extruded).
Shape_Kind :: enum u8 {
	Box,
	Sphere,
	Capsule,
	Hull,
}

// One collision shape of a level body, in the body's frame: only its kind's fields are set.
Shape :: struct {
	kind:        Shape_Kind,
	pos:         [3]f32, // body-local
	rot:         [4]f32,
	half:        [3]f32, // Box
	radius:      f32, // Sphere, Capsule
	half_height: f32, // Capsule: half the segment, along local Y
	points:      [][3]f32, // Hull, body-local
}

// A static body of the level (a StaticBody3D, a StaticBody2D or a TileMapLayer): its pose, its surface (friction and
// restitution from its PhysicsMaterial, category and material from its metadata) and its shapes.
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

// A property's type tag in the file.
Prop_Type :: enum u8 {
	Bool,
	Int,
	Float,
	Vec3,
	String,
	Ref,
}

// A marker property: an exported script property (a Vector2 is a [3]f32 with z = 0; a NodePath to another marker is
// its Marker_Ref).
Prop :: struct {
	key:   string,
	value: Prop_Value,
}

// A property's value, by the type it was exported as.
Prop_Value :: union {
	bool,
	i32,
	f32,
	[3]f32,
	string,
	Marker_Ref,
}

// Another marker: its index in Level.markers (-1: none).
Marker_Ref :: distinct i32

// A marker node: its kind (the game's vocabulary), name, transform, exported script properties and path.
Marker :: struct {
	index: int, // in Level.markers (scene-tree order)
	kind:  string,
	name:  string,
	pos:   [3]f32,
	rot:   [4]f32,
	scale: [3]f32, // 2D: (sx, sy, 1)
	props: []Prop,
	path:  [][3]f32, // a Path3D or Path2D child's points, world space, metres (empty: none)
}

// A loaded level file (load): its bodies and markers in scene-tree order, in storage that destroy frees. A game keeps
// it in its World, outside the block.
Level :: struct {
	// A 2D level's pixels per metre (its view maps metres back to pixels with it); 0: a 3D level.
	px_per_m:  f32,
	bodies:    []Body,
	markers:   []Marker,
	// Backing storage the slices above point into, and the allocator load made it with (destroy frees with it).
	allocator: runtime.Allocator,
	strings:   []string,
	shapes:    []Shape,
	props:     []Prop,
	points:    [][3]f32,
}

// Frees the slices load allocated (with the allocator it was given) and zeroes the Level. Its strings point into the
// file bytes, which the caller owns.
destroy :: proc(level: ^Level) {
	context.allocator = level.allocator
	delete(level.bodies)
	delete(level.markers)
	delete(level.strings)
	delete(level.shapes)
	delete(level.props)
	delete(level.points)
	level^ = {}
}

@(private)
Decoder :: struct {
	reader:  wire.Reader,
	strings: []string,
	shapes:  [dynamic]Shape,
	props:   [dynamic]Prop,
	points:  [dynamic][3]f32,
	ok:      bool,
}

@(private)
read_vec3 :: proc(decoder: ^Decoder) -> [3]f32 {
	return {wire.r_f32(&decoder.reader), wire.r_f32(&decoder.reader), wire.r_f32(&decoder.reader)}
}

@(private)
read_quat :: proc(decoder: ^Decoder) -> [4]f32 {
	reader := &decoder.reader
	return {wire.r_f32(reader), wire.r_f32(reader), wire.r_f32(reader), wire.r_f32(reader)}
}

// A string by its index in the string table.
@(private)
read_string :: proc(decoder: ^Decoder) -> string {
	index := int(wire.r_u32(&decoder.reader))
	if index >= len(decoder.strings) {
		decoder.ok = false
		return ""
	}
	return decoder.strings[index]
}

// Where a list of points, shapes or props went in its backing array: slices are fixed up at the end (the arrays may
// grow while reading).
@(private)
Span :: struct {
	start, count: int,
}

@(private)
read_points :: proc(decoder: ^Decoder) -> Span {
	count := int(wire.r_u16(&decoder.reader))
	span := Span{len(decoder.points), count}
	for _ in 0 ..< count {
		append(&decoder.points, read_vec3(decoder))
	}
	return span
}

// Parses a level file: not ok for a truncated or malformed file, trailing bytes, or another version than VERSION
// (readers accept only the current one). The strings are views into `data`, which must outlive the Level.
load :: proc(data: []u8, allocator := context.allocator) -> (level: Level, ok: bool) {
	context.allocator = allocator
	decoder := Decoder {
		reader = wire.reader_make(data),
		ok     = true,
	}
	magic := wire.r_bytes(&decoder.reader, 4)
	version := wire.r_u16(&decoder.reader)
	if !decoder.reader.ok || string(magic) != MAGIC || version != VERSION do return
	px_per_m := wire.r_f32(&decoder.reader)
	string_count := int(wire.r_u32(&decoder.reader))
	if string_count > len(data) do return
	string_table := make([]string, string_count)
	for i in 0 ..< string_count {
		count := int(wire.r_u16(&decoder.reader))
		string_table[i] = string(wire.r_bytes(&decoder.reader, count))
	}
	decoder.strings = string_table

	shape_pts: [dynamic]Span
	defer delete(shape_pts)
	body_shapes: [dynamic]Span
	defer delete(body_shapes)
	body_count := int(wire.r_u32(&decoder.reader))
	if body_count > len(data) do body_count = 0
	bodies := make([]Body, body_count)
	for &body in bodies {
		body.name = read_string(&decoder)
		body.pos = read_vec3(&decoder)
		body.rot = read_quat(&decoder)
		body.friction = wire.r_f32(&decoder.reader)
		body.restitution = wire.r_f32(&decoder.reader)
		body.category = wire.r_u64(&decoder.reader)
		body.material = wire.r_u64(&decoder.reader)
		count := int(wire.r_u16(&decoder.reader))
		append(&body_shapes, Span{len(decoder.shapes), count})
		for _ in 0 ..< count {
			shape := Shape {
				kind = Shape_Kind(wire.r_u8(&decoder.reader)),
				pos  = read_vec3(&decoder),
				rot  = read_quat(&decoder),
			}
			span: Span
			switch shape.kind {
			case .Box:
				shape.half = read_vec3(&decoder)
			case .Sphere:
				shape.radius = wire.r_f32(&decoder.reader)
			case .Capsule:
				shape.radius = wire.r_f32(&decoder.reader)
				shape.half_height = wire.r_f32(&decoder.reader)
			case .Hull:
				span = read_points(&decoder)
			case:
				decoder.ok = false
			}
			append(&shape_pts, span)
			append(&decoder.shapes, shape)
		}
		if !decoder.reader.ok || !decoder.ok do break
	}

	marker_props: [dynamic]Span
	defer delete(marker_props)
	marker_path: [dynamic]Span
	defer delete(marker_path)
	marker_count := int(wire.r_u32(&decoder.reader))
	if marker_count > len(data) do marker_count = 0
	markers := make([]Marker, marker_count)
	for &marker, i in markers {
		marker.index = i
		marker.kind = read_string(&decoder)
		marker.name = read_string(&decoder)
		marker.pos = read_vec3(&decoder)
		marker.rot = read_quat(&decoder)
		marker.scale = read_vec3(&decoder)
		prop_count := int(wire.r_u16(&decoder.reader))
		append(&marker_props, Span{len(decoder.props), prop_count})
		for _ in 0 ..< prop_count {
			property := Prop {
				key = read_string(&decoder),
			}
			switch Prop_Type(wire.r_u8(&decoder.reader)) {
			case .Bool:
				property.value = wire.r_u8(&decoder.reader) != 0
			case .Int:
				property.value = i32(wire.r_u32(&decoder.reader))
			case .Ref:
				property.value = Marker_Ref(wire.r_u32(&decoder.reader))
			case .Float:
				property.value = wire.r_f32(&decoder.reader)
			case .Vec3:
				property.value = read_vec3(&decoder)
			case .String:
				property.value = read_string(&decoder)
			case:
				decoder.ok = false
			}
			append(&decoder.props, property)
		}
		append(&marker_path, read_points(&decoder))
		if !decoder.reader.ok || !decoder.ok do break
	}

	level = {
		allocator = allocator,
		px_per_m  = px_per_m,
		bodies    = bodies,
		markers   = markers,
		strings   = string_table,
		shapes    = decoder.shapes[:],
		props     = decoder.props[:],
		points    = decoder.points[:],
	}
	if !decoder.reader.ok || !decoder.ok || decoder.reader.pos != len(data) {
		destroy(&level)
		return {}, false
	}
	for &shape, i in level.shapes {
		span := shape_pts[i]
		shape.points = level.points[span.start:][:span.count]
	}
	for &body, i in level.bodies {
		span := body_shapes[i]
		body.shapes = level.shapes[span.start:][:span.count]
	}
	for &marker, i in level.markers {
		span := marker_props[i]
		marker.props = level.props[span.start:][:span.count]
		path_span := marker_path[i]
		marker.path = level.points[path_span.start:][:path_span.count]
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

// The marker's property with this key (nil: none); the typed prop_* getters read through it.
@(private)
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
	#partial switch value in property.value {
	case f32:
		return value
	case i32:
		return f32(value)
	}
	return default
}

// The value of a property of type T, or `default` when the marker has none of that key and type.
@(private)
prop_value :: proc(marker: ^Marker, key: string, default: $T) -> T {
	property := prop(marker, key)
	if property == nil do return default
	return property.value.(T) or_else default
}

// An Int property, or `default` when it is missing or of another type.
prop_int :: proc(marker: ^Marker, key: string, default: int = 0) -> int {
	return int(prop_value(marker, key, i32(default)))
}

// A Bool property, or `default` when it is missing or of another type.
prop_bool :: proc(marker: ^Marker, key: string, default := false) -> bool {
	return prop_value(marker, key, default)
}

// A Vector3 property, or `default` when it is missing or of another type.
prop_vec3 :: proc(marker: ^Marker, key: string, default := [3]f32{}) -> [3]f32 {
	return prop_value(marker, key, default)
}

// A Vector2 property: written as a Vec3 with z = 0, raw (not converted to metres).
prop_vec2 :: proc(marker: ^Marker, key: string, default := [2]f32{}) -> [2]f32 {
	return prop_value(marker, key, [3]f32{default.x, default.y, 0}).xy
}

// A String property (pointing into the file bytes), or `default` when it is missing or of another type.
prop_string :: proc(marker: ^Marker, key: string, default := "") -> string {
	return prop_value(marker, key, default)
}

// A String property naming a member of the enum E (`@export_enum("crate", "ball")` in the marker's script): the member
// whose name, lowercased, is the string (`Item_Kind.Crate` for "crate", `.Ping_Pong` for "ping_pong"); `default` when
// it is missing. `known` is false for a property that names no member (a typo in a scene, a renamed member) or is not
// a String: `default` then too, and the game asserts.
//
//   kind, known := level.prop_enum(&marker, "kind", Item_Kind.Crate)
//   assert(known, "an item's kind is no Item_Kind")
prop_enum :: proc(
	marker: ^Marker,
	key: string,
	default: $E,
) -> (
	value: E,
	known: bool,
) where intrinsics.type_is_enum(E) #optional_ok {
	property := prop(marker, key)
	if property == nil do return default, true
	name, is_string := property.value.(string)
	if !is_string do return default, false
	info := runtime.type_info_base(type_info_of(E)).variant.(runtime.Type_Info_Enum)
	for member, i in info.names {
		if lower_equal(member, name) do return E(info.values[i]), true
	}
	return default, false
}

// Whether `name` is `lowercase` with its ASCII letters lowercased (no allocation).
@(private)
lower_equal :: proc(name, lowercase: string) -> bool {
	if len(name) != len(lowercase) do return false
	for i in 0 ..< len(name) {
		char := name[i]
		if char >= 'A' && char <= 'Z' do char += 'a' - 'A'
		if char != lowercase[i] do return false
	}
	return true
}

// A NodePath property pointing at another marker: its index, or -1.
prop_ref :: proc(marker: ^Marker, key: string) -> int {
	return int(prop_value(marker, key, Marker_Ref(-1)))
}
