// The reader's round-trip oracle: a level file written from Odin values, in the format the Godot exporter writes from a
// scene (src/level/level.odin's header).
package test_level

import "unified:level"
import "unified:wire"

// Encodes bodies and markers (their `index` fields are ignored; Ref props hold marker indices), in the
// current version. `px_per_m`: a 2D level's pixels per metre (Level.px_per_m), 0 for a 3D level.
encode :: proc(
	bodies: []level.Body,
	markers: []level.Marker,
	px_per_m: f32 = 0,
	allocator := context.allocator,
) -> []u8 {
	string_table := make([dynamic]string, 0, 64, context.temp_allocator)
	append(&string_table, "")
	intern :: proc(string_table: ^[dynamic]string, text: string) -> u32 {
		for existing, i in string_table {
			if existing == text do return u32(i)
		}
		append(string_table, text)
		return u32(len(string_table) - 1)
	}
	// Strings first, in the order the reader meets them.
	for &body in bodies do intern(&string_table, body.name)
	for &marker in markers {
		intern(&string_table, marker.kind)
		intern(&string_table, marker.name)
		for &property in marker.props {
			intern(&string_table, property.key)
			if text, is_string := property.value.(string); is_string do intern(&string_table, text)
		}
	}

	writer := wire.writer_make(1024, allocator)
	write_vec3 :: proc(writer: ^wire.Writer, x: [3]f32) {wire.w_f32(writer, x.x); wire.w_f32(writer, x.y); wire.w_f32(
			writer,
			x.z,
		)}
	write_quat :: proc(writer: ^wire.Writer, x: [4]f32) {wire.w_f32(writer, x.x); wire.w_f32(writer, x.y); wire.w_f32(
			writer,
			x.z,
		)
		wire.w_f32(writer, x.w)}
	write_points :: proc(writer: ^wire.Writer, points: [][3]f32) {
		wire.w_u16(writer, u16(len(points)))
		for point in points do write_vec3(writer, point)
	}
	wire.w_bytes(&writer, transmute([]u8)string(level.MAGIC))
	wire.w_u16(&writer, level.VERSION)
	wire.w_f32(&writer, px_per_m)
	wire.w_u32(&writer, u32(len(string_table)))
	for text in string_table {
		wire.w_u16(&writer, u16(len(text)))
		wire.w_bytes(&writer, transmute([]u8)text)
	}
	wire.w_u32(&writer, u32(len(bodies)))
	for &body in bodies {
		wire.w_u32(&writer, intern(&string_table, body.name))
		write_vec3(&writer, body.pos)
		write_quat(&writer, body.rot)
		wire.w_f32(&writer, body.friction)
		wire.w_f32(&writer, body.restitution)
		wire.w_u64(&writer, body.category)
		wire.w_u64(&writer, body.material)
		wire.w_u16(&writer, u16(len(body.shapes)))
		for &shape in body.shapes {
			wire.w_u8(&writer, u8(shape.kind))
			write_vec3(&writer, shape.pos)
			write_quat(&writer, shape.rot)
			switch shape.kind {
			case .Box:
				write_vec3(&writer, shape.half)
			case .Sphere:
				wire.w_f32(&writer, shape.radius)
			case .Capsule:
				wire.w_f32(&writer, shape.radius)
				wire.w_f32(&writer, shape.half_height)
			case .Hull:
				write_points(&writer, shape.points)
			}
		}
	}
	wire.w_u32(&writer, u32(len(markers)))
	for &marker in markers {
		wire.w_u32(&writer, intern(&string_table, marker.kind))
		wire.w_u32(&writer, intern(&string_table, marker.name))
		write_vec3(&writer, marker.pos)
		write_quat(&writer, marker.rot)
		write_vec3(&writer, marker.scale)
		wire.w_u16(&writer, u16(len(marker.props)))
		for &property in marker.props {
			wire.w_u32(&writer, intern(&string_table, property.key))
			switch value in property.value {
			case bool:
				wire.w_u8(&writer, u8(level.Prop_Type.Bool))
				wire.w_u8(&writer, u8(value))
			case i32:
				wire.w_u8(&writer, u8(level.Prop_Type.Int))
				wire.w_u32(&writer, u32(value))
			case f32:
				wire.w_u8(&writer, u8(level.Prop_Type.Float))
				wire.w_f32(&writer, value)
			case [3]f32:
				wire.w_u8(&writer, u8(level.Prop_Type.Vec3))
				write_vec3(&writer, value)
			case string:
				wire.w_u8(&writer, u8(level.Prop_Type.String))
				wire.w_u32(&writer, intern(&string_table, value))
			case level.Marker_Ref:
				wire.w_u8(&writer, u8(level.Prop_Type.Ref))
				wire.w_u32(&writer, u32(value))
			}
		}
		write_points(&writer, marker.path)
	}
	return writer.buf[:]
}
