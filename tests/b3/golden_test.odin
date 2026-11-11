// The pinned library's results: a fixed scene (every body type, a stack that settles and sleeps, a spinning capsule, a
// sphere), 240 ticks, hashed every 60, through unified:b3. The same on every platform. A library upgrade or a wrapper
// change that alters any of these values fails here first, then the games' reference runs; if the change is
// intended, update GOLDEN (and regenerate the reference runs, `uni record-reference <game>|toy`) in the same commit.
package test_b3

import "core:testing"

import "unified:b3"
import "unified:physics"
import "unified:sim"

DT :: f32(1.0 / 64)
SUBSTEPS :: 4

// Worlds come from physics.create, which serialises b3.create_world/destroy_world (they touch Box3D's global world
// table) against the other test packages running on other threads; it calls default_world_def and create_world.
world_make :: proc(gravity: Maybe([3]f32) = nil) -> ^physics.World {
	return physics.create({gravity = gravity})
}

box_body :: proc(
	w: b3.World_Id,
	type: b3.Body_Type,
	pos: [3]f32,
	half: [3]f32,
	sd: ^b3.Shape_Def = nil,
) -> b3.Body_Id {
	bd := b3.default_body_def()
	bd.type = type
	bd.position = pos
	body := b3.create_body(w, &bd)
	def := b3.default_shape_def()
	if sd != nil {
		def = sd^
	}
	def.density = 1
	hull := b3.make_box_hull(half.x, half.y, half.z)
	b3.create_hull_shape(body, &def, &hull.base)
	return body
}

// Position, rotation, velocities of each body as raw bits (−0 and +0 differ: exactness is the point).
state_hash :: proc(bodies: []b3.Body_Id) -> u64 {
	buf := make([dynamic]u8, context.temp_allocator)
	for id in bodies {
		p := b3.body_get_position(id)
		q := b3.body_get_rotation(id)
		v := b3.body_get_linear_velocity(id)
		a := b3.body_get_angular_velocity(id)
		vals := [13]f32{p.x, p.y, p.z, q.x, q.y, q.z, q.w, v.x, v.y, v.z, a.x, a.y, a.z}
		append(&buf, ..([^]u8)(&vals)[:size_of(vals)])
	}
	return sim.hash_bytes(buf[:])
}

step :: proc(w: b3.World_Id, n: int) {
	for _ in 0 ..< n {
		b3.world_step(w, DT, SUBSTEPS)
	}
}

// A scene with every body type, contacts that settle and sleep, a spinning capsule and a sphere.
Scene :: struct {
	phys:   ^physics.World,
	world:  b3.World_Id,
	bodies: [dynamic]b3.Body_Id,
}

scene_make :: proc(s: ^Scene) {
	s.phys = world_make()
	s.world = s.phys.id
	append(&s.bodies, box_body(s.world, .Static_Body, {0, -0.5, 0}, {20, 0.5, 20}))
	kin := box_body(s.world, .Kinematic_Body, {-6, 1, 0}, {1, 0.25, 1})
	b3.body_set_linear_velocity(kin, {1, 0, 0})
	append(&s.bodies, kin)
	for i in 0 ..< 6 { 	// a stack: contacts, then sleep
		append(&s.bodies, box_body(s.world, .Dynamic_Body, {3, 0.5 + f32(i) * 1.01, 0}, {0.5, 0.5, 0.5}))
	}
	bd := b3.default_body_def()
	bd.type = .Dynamic_Body
	bd.position = {0, 3, 4}
	bd.angular_velocity = {0, 5, 2}
	cap_body := b3.create_body(s.world, &bd)
	sd := b3.default_shape_def()
	sd.density = 1
	capsule := b3.Capsule{{0, -0.4, 0}, {0, 0.4, 0}, 0.3}
	b3.create_capsule_shape(cap_body, &sd, &capsule)
	append(&s.bodies, cap_body)
	bd.position = {-3, 5, -3}
	bd.angular_velocity = {}
	ball := b3.create_body(s.world, &bd)
	sphere := b3.Sphere{{0, 0, 0}, 0.5}
	b3.create_sphere_shape(ball, &sd, &sphere)
	append(&s.bodies, ball)
}

scene_destroy :: proc(s: ^Scene) {
	physics.destroy(s.phys)
	delete(s.bodies)
}

// Moved from the old tests/box3d with the scene unchanged: the values are the in-tree port's, so the library and the
// wrapper reproduce them bit for bit.
GOLDEN := [4]u64{0x3125e350623f9163, 0x3f3637eb749e2a37, 0xf0d63788ca5d305b, 0xa2fd5716d15ff9f4}

@(test)
golden_trace :: proc(t: ^testing.T) {
	s: Scene
	scene_make(&s)
	defer scene_destroy(&s)
	got: [4]u64
	for k in 0 ..< 4 {
		step(s.world, 60)
		got[k] = state_hash(s.bodies[:])
	}
	testing.expectf(t, got == GOLDEN, "golden trace changed: %x (pinned %x)", got, GOLDEN)
}
