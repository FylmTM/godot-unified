// Writing a level file from Odin values: tests, fixtures and levels built in code use it; the Godot
// exporter writes the same format from a scene.
package level

import "unified:wire"

// Encodes bodies and markers (their `index` fields are ignored; Ref props hold marker indices).
encode :: proc(bodies: []Body, markers: []Marker, allocator := context.allocator) -> []u8 {
	strs := make([dynamic]string, 0, 64, context.temp_allocator)
	append(&strs, "")
	intern :: proc(strs: ^[dynamic]string, s: string) -> u32 {
		for x, i in strs {
			if x == s do return u32(i)
		}
		append(strs, s)
		return u32(len(strs) - 1)
	}
	// Strings first, in the order the reader meets them.
	for &b in bodies do intern(&strs, b.name)
	for &m in markers {
		intern(&strs, m.kind)
		intern(&strs, m.name)
		for &p in m.props {
			intern(&strs, p.key)
			if p.type == .String do intern(&strs, p.s)
		}
	}

	w := wire.writer_make(1024, allocator)
	f :: proc(w: ^wire.Writer, x: f32) {wire.w_u32(w, transmute(u32)x)}
	v :: proc(w: ^wire.Writer, x: [3]f32) {f(w, x.x); f(w, x.y); f(w, x.z)}
	q :: proc(w: ^wire.Writer, x: [4]f32) {f(w, x.x); f(w, x.y); f(w, x.z); f(w, x.w)}
	pts :: proc(w: ^wire.Writer, ps: [][3]f32) {
		wire.w_u16(w, u16(len(ps)))
		for p in ps do v(w, p)
	}
	wire.w_bytes(&w, transmute([]u8)string(MAGIC))
	wire.w_u16(&w, VERSION)
	wire.w_u32(&w, u32(len(strs)))
	for s in strs {
		wire.w_u16(&w, u16(len(s)))
		wire.w_bytes(&w, transmute([]u8)s)
	}
	wire.w_u32(&w, u32(len(bodies)))
	for &b in bodies {
		wire.w_u32(&w, intern(&strs, b.name))
		v(&w, b.pos)
		q(&w, b.rot)
		f(&w, b.friction)
		f(&w, b.restitution)
		wire.w_u64(&w, b.category)
		wire.w_u64(&w, b.material)
		wire.w_u16(&w, u16(len(b.shapes)))
		for &sh in b.shapes {
			wire.w_u8(&w, u8(sh.kind))
			v(&w, sh.pos)
			q(&w, sh.rot)
			switch sh.kind {
			case .Box:
				v(&w, sh.half)
			case .Sphere:
				f(&w, sh.radius)
			case .Capsule:
				f(&w, sh.radius)
				f(&w, sh.half_height)
			case .Hull:
				pts(&w, sh.points)
			}
		}
	}
	wire.w_u32(&w, u32(len(markers)))
	for &m in markers {
		wire.w_u32(&w, intern(&strs, m.kind))
		wire.w_u32(&w, intern(&strs, m.name))
		v(&w, m.pos)
		q(&w, m.rot)
		v(&w, m.scale)
		wire.w_u16(&w, u16(len(m.props)))
		for &p in m.props {
			wire.w_u32(&w, intern(&strs, p.key))
			wire.w_u8(&w, u8(p.type))
			switch p.type {
			case .Bool:
				wire.w_u8(&w, u8(p.b))
			case .Int, .Ref:
				wire.w_u32(&w, u32(p.i))
			case .Float:
				f(&w, p.f)
			case .Vec3:
				v(&w, p.v)
			case .String:
				wire.w_u32(&w, intern(&strs, p.s))
			}
		}
		pts(&w, m.path)
	}
	return w.buf[:]
}
