// The physics plug-in: Body_Ref discovery by RTTI, save/restore through the ring, the world hash,
// and a portable image restored into a second world.
package test_physics

import "core:testing"

import "unified:b3"
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
	count:  u32,
}

make_world :: proc(state: ^State) -> ^physics.World {
	world := physics.create()
	body_def := b3.default_body_def()
	ground := b3.create_body(world.id, &body_def)
	shape_def := b3.default_shape_def()
	hull := b3.make_box_hull(10, 0.5, 10)
	b3.create_hull_shape(ground, &shape_def, &hull.base)
	for &crate, i in state.crates {
		crate_body_def := b3.default_body_def()
		crate_body_def.type = .Dynamic_Body
		crate_body_def.position = {f32(i) * 2 - 2, 2 + f32(i), 0}
		body := b3.create_body(world.id, &crate_body_def)
		crate_hull := b3.make_box_hull(0.5, 0.5, 0.5)
		crate_shape_def := b3.default_shape_def()
		crate_shape_def.density = 1
		b3.create_hull_shape(body, &crate_shape_def, &crate_hull.base)
		crate.body = physics.ref_of(body)
	}
	return world
}

checksum :: proc(state: ^State, extra: ^sim.Extra) -> u64 {
	buf: [dynamic]u8
	defer delete(buf)
	extra.hash(extra.data, state, 0, &buf) // tick 0: the whole world (sim.DEEP_CHECKSUM_EVERY)
	return sim.hash_bytes(buf[:])
}

@(test)
save_restore_hash :: proc(t: ^testing.T) {
	state: State
	world := make_world(&state)
	defer physics.destroy(world)
	extra := physics.extra(world, State)
	testing.expect_value(t, len(world.refs.bodies), 1 + 3 + 4) // player, crates, table items (memory order)
	extra.save(extra.data, 0)
	hash_0 := checksum(&state, &extra)
	for _ in 0 ..< 30 {
		b3.world_step(world.id, 1.0 / 64, 4)
	}
	hash_30 := checksum(&state, &extra)
	testing.expect(t, hash_30 != hash_0)
	extra.save(extra.data, 1)
	testing.expect(t, extra.restore(extra.data, 0))
	testing.expect_value(t, checksum(&state, &extra), hash_0)
	testing.expect(t, extra.restore(extra.data, 1))
	testing.expect_value(t, checksum(&state, &extra), hash_30)

	// Destroying a body clears the ref and changes the world's hash; destroying it again (a stale ref) is a no-op.
	physics.destroy_body(world, &state.crates[1].body)
	testing.expect(t, state.crates[1].body == physics.Body_Ref{})
	testing.expect(t, checksum(&state, &extra) != hash_30)

	// A second world built the same way loads the first one's image bit-exactly.
	state2: State
	world2 := make_world(&state2)
	defer physics.destroy(world2)
	extra2 := physics.extra(world2, State)
	testing.expect(t, extra2.load(extra2.data, extra.image(extra.data, 1)))
	state2 = state
	state2.crates[1].body = state2.crates[0].body // the hash reads the world, not the block's refs
	state.crates[1].body = state.crates[0].body
	testing.expect(t, extra.restore(extra.data, 1))
	testing.expect_value(t, checksum(&state2, &extra2), checksum(&state, &extra))
}

// create_body returns the block's ref; destroy_body checks it, so a stale ref (its body gone and the index reused, as
// Box3D does last in, first out) leaves the new body alone. The release library wouldn't stop it.
@(test)
create_body_and_a_stale_destroy :: proc(t: ^testing.T) {
	world := physics.create()
	defer physics.destroy(world)
	body_def := b3.default_body_def()
	body_def.type = .Dynamic_Body
	first := physics.create_body(world, &body_def)
	testing.expect(t, physics.body_valid(world, physics.link(first)))
	testing.expect_value(t, b3.body_get_type(physics.body_id(world, first)), b3.Body_Type.Dynamic_Body)
	stale := first
	physics.destroy_body(world, &first)
	testing.expect(t, first == physics.Body_Ref{})
	second := physics.create_body(world, &body_def)
	testing.expect_value(t, second.index1, stale.index1)
	testing.expect(t, !physics.body_valid(world, physics.link(stale)))
	physics.destroy_body(world, &stale)
	testing.expect(t, stale == physics.Body_Ref{})
	testing.expect(t, physics.body_valid(world, physics.link(second)))
}
