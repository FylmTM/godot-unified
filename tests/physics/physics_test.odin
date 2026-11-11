// The physics plug-in: Body_Ref discovery by RTTI, save/restore through the ring, the body hash,
// and a portable image restored into a second world.
package test_physics

import "core:testing"

import b3 "unified:box3d_port"
import "unified:physics"
import "unified:sim"

Crate :: struct {
	body: physics.Body_Ref,
	hp:   i32,
}

State :: struct {
	player: physics.Body_Ref,
	crates: [3]Crate,
	misc:   sim.Table(Crate, 4),
	n:      u32,
}

make_world :: proc(s: ^State) -> ^physics.World {
	w := physics.create()
	bd := b3.DefaultBodyDef()
	ground := b3.CreateBody(w.id, &bd)
	sd := b3.DefaultShapeDef()
	hull := b3.MakeBoxHull(10, 0.5, 10)
	b3.CreateHullShape(ground, &sd, &hull.base)
	for &c, i in s.crates {
		cd := b3.DefaultBodyDef()
		cd.type = .dynamicBody
		cd.position = {f32(i) * 2 - 2, 2 + f32(i), 0}
		body := b3.CreateBody(w.id, &cd)
		ch := b3.MakeBoxHull(0.5, 0.5, 0.5)
		csd := b3.DefaultShapeDef()
		csd.density = 1
		b3.CreateHullShape(body, &csd, &ch.base)
		c.body = physics.ref_of(body)
	}
	return w
}

checksum :: proc(s: ^State, e: ^sim.Extra) -> u64 {
	buf: [dynamic]u8
	defer delete(buf)
	e.hash(e.data, s, 0, &buf) // tick 0: the whole world (sim.DEEP_CHECKSUM_EVERY)
	return sim.hash_bytes(buf[:])
}

@(test)
save_restore_hash :: proc(t: ^testing.T) {
	s: State
	w := make_world(&s)
	defer physics.destroy(w)
	e := physics.extra(w, State)
	testing.expect_value(t, len(w.refs), 1 + 3 + 4) // player, crates, table items (memory order)
	e.save(e.data, 0)
	h0 := checksum(&s, &e)
	for _ in 0 ..< 30 {
		b3.World_Step(w.id, 1.0 / 64, 4)
	}
	h30 := checksum(&s, &e)
	testing.expect(t, h30 != h0)
	e.save(e.data, 1)
	testing.expect(t, e.restore(e.data, 0))
	testing.expect_value(t, checksum(&s, &e), h0)
	testing.expect(t, e.restore(e.data, 1))
	testing.expect_value(t, checksum(&s, &e), h30)

	// Destroying a body clears the ref, and the hash skips it.
	physics.destroy_body(w, &s.crates[1].body)
	testing.expect(t, s.crates[1].body == physics.Body_Ref{})
	testing.expect(t, checksum(&s, &e) != h30)

	// A second world built the same way loads the first one's image bit-exactly.
	s2: State
	w2 := make_world(&s2)
	defer physics.destroy(w2)
	e2 := physics.extra(w2, State)
	e2.save(e2.data, 0) // fills the geometry registry in creation order
	testing.expect(t, e2.load(e2.data, e.image(e.data, 1)))
	s2 = s
	s2.crates[1].body = s2.crates[0].body // any ref layout works: refs come from the block
	s.crates[1].body = s.crates[0].body
	testing.expect(t, e.restore(e.data, 1))
	testing.expect_value(t, checksum(&s2, &e2), checksum(&s, &e))
}
