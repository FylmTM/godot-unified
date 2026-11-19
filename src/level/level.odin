// Godot-authored levels for the sim (src/level/README.md): the `UNLV` file the exporter writes, read into
// plain slices. Deterministic and pointer-free in what it returns to the sim (the Level lives in the
// World, outside the block). The bytes stay owned by the caller: strings are views into them.
//
// File (little-endian, unified:wire): "UNLV", version u16, px_per_m f32 (0: a 3D level), then
//   strings: count u32, each len u16 + UTF-8 bytes (index 0 is "")
//   scene:   u32 (string: the res:// path of the scene it was exported from, "": none)
//   bodies:  count u32, each name u32, pos 3f32, rot 4f32 (x y z w), surface, category u64, shape count u16,
//            each shape:
//              kind u8, pos 3f32, rot 4f32 (body-local), own u8 (1: a surface follows; 0: the body's), surface?,
//              then box: half 3f32 | sphere: radius f32 | capsule: radius f32, half_height f32 (segment along
//              local Y) | hull: count u16, points 3f32 |
//              mesh: vertex count u32, vertices 3f32, triangle count u32, indices 3u32 each (counter-clockwise
//              seen from the front), material index count u32 (0: none; else the triangle count) + u8 each,
//              extra surface count u8 + surface each (a triangle's material index 0 is the shape's surface,
//              k > 0 the k-th extra one) |
//              height field: count_x u16, count_z u16, scale 3f32 (cell x, height, cell z), heights f32
//              (count_x * count_z, row by row along x; the shape's pose is the grid's corner)
//   surface: friction f32, restitution f32, rolling_resistance f32, tangent_velocity 3f32, material u64
//   markers: count u32, each kind u32, name u32, pos 3f32, rot 4f32, scale 3f32,
//            prop count u16, each key u32, type u8, value (bool u8 | int i32 | float f32 | vec3 3f32 |
//            string u32 | ref i32: marker index, -1 none | curve CURVE_SAMPLES f32), then path point count u16,
//            points 3f32 (world)
package level

import "base:intrinsics"
import "base:runtime"

import "unified:dmath"
import "unified:wire"

MAGIC :: "UNLV"
VERSION :: 3 // bump on any change to a .level file's bytes (the sim-change skill)

// How many evenly spaced samples of its domain a Curve property holds.
CURVE_SAMPLES :: 32

// What a level shape is: a Godot box, sphere, capsule or convex polygon (a 2D level's extruded; a cylinder is a hull
// of its points), a concave polygon (a triangle mesh) or a height map.
Shape_Kind :: enum u8 {
	Box,
	Sphere,
	Capsule,
	Hull,
	Mesh,
	Height_Field,
}

// What a contact with a level shape mixes (Box3D's surface material) and the game's id for it: from the body's
// PhysicsMaterial and metadata, or a CollisionShape's own metadata.
Surface :: struct {
	friction:           f32,
	restitution:        f32,
	rolling_resistance: f32,
	tangent_velocity:   [3]f32, // a conveyor's surface speed, m/s
	material:           u64, // user material id (0: none)
}

// One collision shape of a level body, in the body's frame: only its kind's fields are set.
Shape :: struct {
	kind:               Shape_Kind,
	pos:                [3]f32, // body-local; a Height_Field's corner
	rot:                [4]f32,
	surface:            Surface, // the body's, unless the shape has its own
	half:               [3]f32, // Box
	radius:             f32, // Sphere, Capsule
	half_height:        f32, // Capsule: half the segment, along local Y
	points:             [][3]f32, // Hull, Mesh: body-local
	triangles:          [][3]u32, // Mesh: indices into points, counter-clockwise seen from the front
	triangle_materials: []u8, // Mesh: each triangle's index into materials (empty: all 0)
	materials:          []Surface, // Mesh: what its triangles' material indices name; materials[0] is `surface`
	count_x, count_z:   int, // Height_Field: grid lines along x and z (at least 2 each)
	scale:              [3]f32, // Height_Field: cell size along x, height scale, cell size along z
	heights:            []f32, // Height_Field: count_x * count_z, row by row along x (heights[z * count_x + x])
}

// A static body of the level (a StaticBody3D, a StaticBody2D or a TileMapLayer): its pose, its surface (from its
// PhysicsMaterial and metadata), its filter category (metadata) and its shapes.
Body :: struct {
	name:     string,
	pos:      [3]f32,
	rot:      [4]f32,
	surface:  Surface,
	category: u64, // filter bits (0: the game's default)
	shapes:   []Shape,
}

// A property's type tag in the file.
Prop_Type :: enum u8 {
	Bool,
	Int,
	Float,
	Vec3,
	String,
	Ref,
	Curve,
}

// A marker property: an exported script property (a Vector2 is a [3]f32 with z = 0; a NodePath to another marker is
// its Marker_Ref; a Curve its Curve_Ref).
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
	Curve_Ref,
}

// Another marker: its index in Level.markers (-1: none).
Marker_Ref :: distinct i32

// A Curve property's samples: its index in Level.curves.
Curve_Ref :: distinct i32

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
	scene:     string, // the res:// path of the scene it was exported from ("": none)
	bodies:    []Body,
	markers:   []Marker,
	// A Curve property's CURVE_SAMPLES values, evenly spaced over its domain (Curve_Ref indexes them).
	curves:    [][CURVE_SAMPLES]f32,
	// Backing storage the slices above point into, and the allocator load made it with (destroy frees with it).
	allocator: runtime.Allocator,
	strings:   []string,
	shapes:    []Shape,
	props:     []Prop,
	points:    [][3]f32,
	triangles: [][3]u32,
	bytes:     []u8,
	surfaces:  []Surface,
	heights:   []f32,
}

// Frees the slices load allocated (with the allocator it was given) and zeroes the Level. Its strings point into the
// file bytes, which the caller owns.
destroy :: proc(level: ^Level) {
	context.allocator = level.allocator
	delete(level.bodies)
	delete(level.markers)
	delete(level.curves)
	delete(level.strings)
	delete(level.shapes)
	delete(level.props)
	delete(level.points)
	delete(level.triangles)
	delete(level.bytes)
	delete(level.surfaces)
	delete(level.heights)
	level^ = {}
}

// The res:// path of the scene a level file was exported from, from its header alone ("": none, or not a level
// file of this version). A view into `data`.
scene_of :: proc(data: []u8) -> string {
	reader := wire.reader_make(data)
	magic := wire.r_bytes(&reader, 4)
	version := wire.r_u16(&reader)
	if !reader.ok || string(magic) != MAGIC || version != VERSION do return ""
	_ = wire.r_f32(&reader)
	string_count := int(wire.r_u32(&reader))
	if string_count > len(data) do return ""
	scene := ""
	strings_start := reader.pos
	for _ in 0 ..< string_count {
		count := int(wire.r_u16(&reader))
		wire.r_bytes(&reader, count)
	}
	index := int(wire.r_u32(&reader))
	if !reader.ok || index >= string_count do return ""
	reader.pos = strings_start
	for i in 0 ..= index {
		count := int(wire.r_u16(&reader))
		text := wire.r_bytes(&reader, count)
		if i == index do scene = string(text)
	}
	return scene
}

@(private)
Decoder :: struct {
	reader:    wire.Reader,
	strings:   []string,
	shapes:    [dynamic]Shape,
	props:     [dynamic]Prop,
	points:    [dynamic][3]f32,
	triangles: [dynamic][3]u32,
	bytes:     [dynamic]u8,
	surfaces:  [dynamic]Surface,
	heights:   [dynamic]f32,
	curves:    [dynamic][CURVE_SAMPLES]f32,
	ok:        bool,
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

@(private)
read_surface :: proc(decoder: ^Decoder) -> Surface {
	return {
		friction           = wire.r_f32(&decoder.reader),
		restitution        = wire.r_f32(&decoder.reader),
		rolling_resistance = wire.r_f32(&decoder.reader),
		tangent_velocity   = read_vec3(decoder),
		material           = wire.r_u64(&decoder.reader),
	}
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

// Where a list went in its backing array: slices are fixed up at the end (the arrays may grow while reading).
@(private)
Span :: struct {
	start, count: int,
}

// A count read from the file, refused (not ok, 0) when the rest of the file can't hold that many items of `size`
// bytes: a corrupt count never allocates.
@(private)
read_count :: proc(decoder: ^Decoder, count: int, size: int) -> int {
	if count * size > wire.r_remaining(&decoder.reader) {
		decoder.ok = false
		return 0
	}
	return count
}

@(private)
read_points :: proc(decoder: ^Decoder, file_count: int) -> Span {
	count := read_count(decoder, file_count, 12)
	span := Span{len(decoder.points), count}
	for _ in 0 ..< count {
		append(&decoder.points, read_vec3(decoder))
	}
	return span
}

// Where a shape's lists went (Span), fixed up into its slices once the file is read.
@(private)
Shape_Spans :: struct {
	points, triangles, triangle_materials, materials, heights: Span,
}

// A shape's record after its pose and surface.
@(private)
read_shape_body :: proc(decoder: ^Decoder, shape: ^Shape, spans: ^Shape_Spans) {
	reader := &decoder.reader
	switch shape.kind {
	case .Box:
		shape.half = read_vec3(decoder)
	case .Sphere:
		shape.radius = wire.r_f32(reader)
	case .Capsule:
		shape.radius = wire.r_f32(reader)
		shape.half_height = wire.r_f32(reader)
	case .Hull:
		spans.points = read_points(decoder, int(wire.r_u16(reader)))
	case .Mesh:
		spans.points = read_points(decoder, int(wire.r_u32(reader)))
		triangle_count := read_count(decoder, int(wire.r_u32(reader)), 12)
		spans.triangles = {len(decoder.triangles), triangle_count}
		for _ in 0 ..< triangle_count {
			triangle := [3]u32{wire.r_u32(reader), wire.r_u32(reader), wire.r_u32(reader)}
			for index in triangle {
				if int(index) >= spans.points.count do decoder.ok = false
			}
			append(&decoder.triangles, triangle)
		}
		material_count := read_count(decoder, int(wire.r_u32(reader)), 1)
		if material_count != 0 && material_count != triangle_count do decoder.ok = false
		spans.triangle_materials = {len(decoder.bytes), material_count}
		append(&decoder.bytes, ..wire.r_bytes(reader, material_count))
		extra := int(wire.r_u8(reader))
		spans.materials = {len(decoder.surfaces), extra + 1}
		append(&decoder.surfaces, shape.surface)
		for _ in 0 ..< extra do append(&decoder.surfaces, read_surface(decoder))
		for index in decoder.bytes[spans.triangle_materials.start:] {
			if int(index) > extra do decoder.ok = false
		}
		if triangle_count == 0 do decoder.ok = false
	case .Height_Field:
		shape.count_x = int(wire.r_u16(reader))
		shape.count_z = int(wire.r_u16(reader))
		shape.scale = read_vec3(decoder)
		count := read_count(decoder, shape.count_x * shape.count_z, 4)
		spans.heights = {len(decoder.heights), count}
		for _ in 0 ..< count do append(&decoder.heights, wire.r_f32(reader))
		if shape.count_x < 2 || shape.count_z < 2 do decoder.ok = false
	case:
		decoder.ok = false
	}
}

// Parses a level file: not ok for a truncated or malformed file (an index out of range, a height field under 2 × 2),
// trailing bytes, or another version than VERSION (readers accept only the current one). The strings are views into
// `data`, which must outlive the Level.
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
	scene := read_string(&decoder)

	shape_spans: [dynamic]Shape_Spans
	defer delete(shape_spans)
	body_shapes: [dynamic]Span
	defer delete(body_shapes)
	body_count := read_count(&decoder, int(wire.r_u32(&decoder.reader)), 1)
	bodies := make([]Body, body_count)
	for &body in bodies {
		body.name = read_string(&decoder)
		body.pos = read_vec3(&decoder)
		body.rot = read_quat(&decoder)
		body.surface = read_surface(&decoder)
		body.category = wire.r_u64(&decoder.reader)
		count := int(wire.r_u16(&decoder.reader))
		append(&body_shapes, Span{len(decoder.shapes), count})
		for _ in 0 ..< count {
			shape := Shape {
				kind = Shape_Kind(wire.r_u8(&decoder.reader)),
				pos  = read_vec3(&decoder),
				rot  = read_quat(&decoder),
			}
			switch wire.r_u8(&decoder.reader) {
			case 0:
				shape.surface = body.surface
			case 1:
				shape.surface = read_surface(&decoder)
			case:
				decoder.ok = false
			}
			spans: Shape_Spans
			read_shape_body(&decoder, &shape, &spans)
			append(&shape_spans, spans)
			append(&decoder.shapes, shape)
			if !decoder.reader.ok || !decoder.ok do break
		}
		if !decoder.reader.ok || !decoder.ok do break
	}

	marker_props: [dynamic]Span
	defer delete(marker_props)
	marker_path: [dynamic]Span
	defer delete(marker_path)
	marker_count := read_count(&decoder, int(wire.r_u32(&decoder.reader)), 1)
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
			case .Curve:
				samples: [CURVE_SAMPLES]f32
				for &sample in samples do sample = wire.r_f32(&decoder.reader)
				property.value = Curve_Ref(len(decoder.curves))
				append(&decoder.curves, samples)
			case:
				decoder.ok = false
			}
			append(&decoder.props, property)
		}
		append(&marker_path, read_points(&decoder, int(wire.r_u16(&decoder.reader))))
		if !decoder.reader.ok || !decoder.ok do break
	}

	level = {
		allocator = allocator,
		px_per_m  = px_per_m,
		scene     = scene,
		bodies    = bodies,
		markers   = markers,
		curves    = decoder.curves[:],
		strings   = string_table,
		shapes    = decoder.shapes[:],
		props     = decoder.props[:],
		points    = decoder.points[:],
		triangles = decoder.triangles[:],
		bytes     = decoder.bytes[:],
		surfaces  = decoder.surfaces[:],
		heights   = decoder.heights[:],
	}
	if !decoder.reader.ok || !decoder.ok || decoder.reader.pos != len(data) {
		destroy(&level)
		return {}, false
	}
	for &shape, i in level.shapes {
		spans := shape_spans[i]
		shape.points = level.points[spans.points.start:][:spans.points.count]
		shape.triangles = level.triangles[spans.triangles.start:][:spans.triangles.count]
		shape.triangle_materials = level.bytes[spans.triangle_materials.start:][:spans.triangle_materials.count]
		shape.materials = level.surfaces[spans.materials.start:][:spans.materials.count]
		shape.heights = level.heights[spans.heights.start:][:spans.heights.count]
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

#assert(CURVE_SAMPLES == dmath.CURVE_SAMPLES)

// A Curve property as a dmath.Curve (its samples over the curve's domain, mapped to x in 0..1: curve_sample), looked
// up in the marker's level; ok is false when the marker has no such property (an unset Curve is not exported) or it
// is of another type.
prop_curve :: proc(level: ^Level, marker: ^Marker, key: string) -> (curve: dmath.Curve, ok: bool) {
	ref := prop_value(marker, key, Curve_Ref(-1))
	if ref < 0 || int(ref) >= len(level.curves) do return
	return {samples = level.curves[ref]}, true
}
