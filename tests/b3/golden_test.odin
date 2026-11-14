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
	world_id: b3.World_Id,
	type: b3.Body_Type,
	pos: [3]f32,
	half: [3]f32,
	shape_def: ^b3.Shape_Def = nil,
) -> b3.Body_Id {
	body_def := b3.default_body_def()
	body_def.type = type
	body_def.position = pos
	body := b3.create_body(world_id, &body_def)
	def := b3.default_shape_def()
	if shape_def != nil {
		def = shape_def^
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
		position := b3.body_get_position(id)
		rotation := b3.body_get_rotation(id)
		velocity := b3.body_get_linear_velocity(id)
		angular_velocity := b3.body_get_angular_velocity(id)
		vals := [13]f32 {
			position.x,
			position.y,
			position.z,
			rotation.x,
			rotation.y,
			rotation.z,
			rotation.w,
			velocity.x,
			velocity.y,
			velocity.z,
			angular_velocity.x,
			angular_velocity.y,
			angular_velocity.z,
		}
		append(&buf, ..([^]u8)(&vals)[:size_of(vals)])
	}
	return sim.hash_bytes(buf[:])
}

step :: proc(world_id: b3.World_Id, count: int) {
	for _ in 0 ..< count {
		b3.world_step(world_id, DT, SUBSTEPS)
	}
}

// A scene with every body type, contacts that settle and sleep, a spinning capsule and a sphere.
Scene :: struct {
	phys:   ^physics.World,
	world:  b3.World_Id,
	bodies: [dynamic]b3.Body_Id,
}

scene_make :: proc(scene: ^Scene) {
	scene.phys = world_make()
	scene.world = scene.phys.id
	append(&scene.bodies, box_body(scene.world, .Static_Body, {0, -0.5, 0}, {20, 0.5, 20}))
	kin := box_body(scene.world, .Kinematic_Body, {-6, 1, 0}, {1, 0.25, 1})
	b3.body_set_linear_velocity(kin, {1, 0, 0})
	append(&scene.bodies, kin)
	for i in 0 ..< 6 { 	// a stack: contacts, then sleep
		append(&scene.bodies, box_body(scene.world, .Dynamic_Body, {3, 0.5 + f32(i) * 1.01, 0}, {0.5, 0.5, 0.5}))
	}
	body_def := b3.default_body_def()
	body_def.type = .Dynamic_Body
	body_def.position = {0, 3, 4}
	body_def.angular_velocity = {0, 5, 2}
	cap_body := b3.create_body(scene.world, &body_def)
	shape_def := b3.default_shape_def()
	shape_def.density = 1
	capsule := b3.Capsule{{0, -0.4, 0}, {0, 0.4, 0}, 0.3}
	b3.create_capsule_shape(cap_body, &shape_def, &capsule)
	append(&scene.bodies, cap_body)
	body_def.position = {-3, 5, -3}
	body_def.angular_velocity = {}
	ball := b3.create_body(scene.world, &body_def)
	sphere := b3.Sphere{{0, 0, 0}, 0.5}
	b3.create_sphere_shape(ball, &shape_def, &sphere)
	append(&scene.bodies, ball)
}

scene_destroy :: proc(scene: ^Scene) {
	physics.destroy(scene.phys)
	delete(scene.bodies)
}

// The library's cross-platform pin: a fixed scene (every body type, a stack that sleeps, a spinning capsule), hashed
// every 60 ticks. The values must match on every platform; an intended change updates them in the same commit.
GOLDEN := [4]u64{0x3125e350623f9163, 0x3f3637eb749e2a37, 0xf0d63788ca5d305b, 0xa2fd5716d15ff9f4}

@(test)
golden_trace :: proc(t: ^testing.T) {
	scene: Scene
	scene_make(&scene)
	defer scene_destroy(&scene)
	got: [4]u64
	for k in 0 ..< 4 {
		step(scene.world, 60)
		got[k] = state_hash(scene.bodies[:])
	}
	testing.expectf(t, got == GOLDEN, "golden trace changed: %x (pinned %x)", got, GOLDEN)
}
