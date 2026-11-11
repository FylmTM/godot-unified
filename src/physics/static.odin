// Static geometry from a level file (src/level/SPEC.md): one static body per level body, in file order.
package physics

import "unified:b3"
import "unified:level"

// Creates every static body of the level, in file order, and returns how many. Shapes without a
// category in the file get `default_category`.
create_static :: proc(w: ^World, lvl: ^level.Level, default_category: u64 = 1) -> int {
	for &b in lvl.bodies {
		bd := b3.default_body_def()
		bd.position = b.pos
		bd.rotation = b.rot
		id := b3.create_body(w.id, &bd)
		sd := b3.default_shape_def()
		sd.base_material.friction = b.friction
		sd.base_material.restitution = b.restitution
		sd.base_material.user_material_id = b.material
		sd.filter.category_bits = b.category if b.category != 0 else default_category
		for &sh in b.shapes {
			create_shape(id, &sd, &sh)
		}
	}
	return len(lvl.bodies)
}

// Adds one level shape to a body (any type: games use it for their own level bodies too).
create_shape :: proc(body: b3.Body_Id, sd: ^b3.Shape_Def, sh: ^level.Shape) {
	identity := sh.rot == {0, 0, 0, 1}
	switch sh.kind {
	case .Box:
		h := b3.make_box_hull(sh.half.x, sh.half.y, sh.half.z)
		if identity && sh.pos == {} {
			b3.create_hull_shape(body, sd, &h.base)
		} else {
			t := b3.clone_and_transform_hull(&h.base, {sh.pos, sh.rot}, {1, 1, 1})
			b3.create_hull_shape(body, sd, t)
			b3.destroy_hull(t)
		}
	case .Sphere:
		s := b3.Sphere{sh.pos, sh.radius}
		b3.create_sphere_shape(body, sd, &s)
	case .Capsule:
		axis := rotate(sh.rot, {0, sh.half_height, 0})
		c := b3.Capsule{sh.pos - axis, sh.pos + axis, sh.radius}
		b3.create_capsule_shape(body, sd, &c)
	case .Hull:
		if len(sh.points) < 4 do return
		h := b3.create_hull(sh.points, 64)
		if h == nil do return
		b3.create_hull_shape(body, sd, h)
		b3.destroy_hull(h)
	}
}

// Rotates v by the unit quaternion q (x, y, z, w): v + 2w(u×v) + 2u×(u×v), each term written out.
rotate :: proc "contextless" (q: [4]f32, v: [3]f32) -> [3]f32 {
	u := [3]f32{q.x, q.y, q.z}
	t := [3]f32{2 * (u.y * v.z - u.z * v.y), 2 * (u.z * v.x - u.x * v.z), 2 * (u.x * v.y - u.y * v.x)}
	c := [3]f32{u.y * t.z - u.z * t.y, u.z * t.x - u.x * t.z, u.x * t.y - u.y * t.x}
	return {v.x + q.w * t.x + c.x, v.y + q.w * t.y + c.y, v.z + q.w * t.z + c.z}
}
