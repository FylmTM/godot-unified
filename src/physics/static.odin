// Static geometry from a level file (src/level/SPEC.md): one static body per level body, in file order.
package physics

import b3 "unified:box3d_port"
import "unified:level"

// Creates every static body of the level, in file order, and returns how many. Shapes without a
// category in the file get `default_category`.
create_static :: proc(w: ^World, lvl: ^level.Level, default_category: u64 = 1) -> int {
	for &b in lvl.bodies {
		bd := b3.DefaultBodyDef()
		bd.position = v3(b.pos)
		bd.rotation = quat(b.rot)
		id := b3.CreateBody(w.id, &bd)
		sd := b3.DefaultShapeDef()
		sd.baseMaterial.friction = b.friction
		sd.baseMaterial.restitution = b.restitution
		sd.baseMaterial.userMaterialId = b.material
		sd.filter.categoryBits = b.category if b.category != 0 else default_category
		for &sh in b.shapes {
			create_shape(id, &sd, &sh)
		}
	}
	return len(lvl.bodies)
}

// Adds one level shape to a body (any type: games use it for their own level bodies too).
create_shape :: proc(body: b3.BodyId, sd: ^b3.ShapeDef, sh: ^level.Shape) {
	identity := sh.rot == {0, 0, 0, 1}
	switch sh.kind {
	case .Box:
		h := b3.MakeBoxHull(sh.half.x, sh.half.y, sh.half.z)
		if identity && sh.pos == {} {
			b3.CreateHullShape(body, sd, &h.base)
		} else {
			t := b3.CloneAndTransformHull(&h.base, {v3(sh.pos), quat(sh.rot)}, {1, 1, 1})
			b3.CreateHullShape(body, sd, t)
			b3.DestroyHull(t)
		}
	case .Sphere:
		s := b3.Sphere{v3(sh.pos), sh.radius}
		b3.CreateSphereShape(body, sd, &s)
	case .Capsule:
		axis := rotate(sh.rot, {0, sh.half_height, 0})
		c := b3.Capsule{v3(sh.pos - axis), v3(sh.pos + axis), sh.radius}
		b3.CreateCapsuleShape(body, sd, &c)
	case .Hull:
		if len(sh.points) < 4 do return
		h := b3.CreateHull(([^]b3.Vec3)(raw_data(sh.points)), i32(len(sh.points)), 64)
		if h == nil do return
		b3.CreateHullShape(body, sd, h)
		b3.DestroyHull(h)
	}
}

quat :: #force_inline proc "contextless" (q: [4]f32) -> b3.Quat {
	return {{q.x, q.y, q.z}, q.w}
}

// Rotates v by the unit quaternion q (x, y, z, w): v + 2w(u×v) + 2u×(u×v), each term written out.
rotate :: proc "contextless" (q: [4]f32, v: [3]f32) -> [3]f32 {
	u := [3]f32{q.x, q.y, q.z}
	t := [3]f32{2 * (u.y * v.z - u.z * v.y), 2 * (u.z * v.x - u.x * v.z), 2 * (u.x * v.y - u.y * v.x)}
	c := [3]f32{u.y * t.z - u.z * t.y, u.z * t.x - u.x * t.z, u.x * t.y - u.y * t.x}
	return {v.x + q.w * t.x + c.x, v.y + q.w * t.y + c.y, v.z + q.w * t.z + c.z}
}
