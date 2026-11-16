// unified:b3's own procs, against the library: what isn't game-facing (world creation and the step, snapshots, images,
// hashes, the query filter physics starts from). Every game-facing proc is tested once, through physics
// (tests/physics: body, shape, world, geometry, query and joint tests).
package test_b3

import "core:testing"

import box3d "box3d:bindings"
import "unified:b3"
import "unified:physics"

// ---- world

@(test)
test_default_world_def :: proc(t: ^testing.T) {
	world_def := b3.default_world_def()
	testing.expect_value(t, world_def.gravity, [3]f32{0, -10, 0})
	testing.expect(t, world_def.enable_sleep && world_def.enable_continuous)
	testing.expect(t, world_def.hit_event_threshold > 0 && world_def.contact_hertz > 0)
	testing.expect(t, world_def.internal_value != 0)
}

// create_world and destroy_world through physics.create/destroy, which serialise them (Box3D's world table is global).
@(test)
test_create_world_destroy_world :: proc(t: ^testing.T) {
	world := world_make([3]f32{1, -2, 3})
	id := world.id
	testing.expect(t, id.index1 != 0)
	testing.expect(t, box3d.World_IsValid(id))
	physics.destroy(world)
	testing.expect(t, !box3d.World_IsValid(id))
}

@(test)
test_world_step :: proc(t: ^testing.T) {
	world := world_make()
	defer physics.destroy(world)
	body := box_body(world.id, .Dynamic_Body, {0, 5, 0}, {0.5, 0.5, 0.5})
	b3.world_step(world.id, DT, SUBSTEPS)
	testing.expect(t, b3.body_get_position(body).y < 5)
	testing.expect(t, b3.body_get_linear_velocity(body).y < 0)
}

// ---- snapshots, images, hashes

@(test)
test_world_save_snapshot_restore_destroy :: proc(t: ^testing.T) {
	scene: Scene
	scene_make(&scene)
	defer scene_destroy(&scene)
	snap: b3.World_Snapshot
	step(scene.world, 30)
	b3.world_save_snapshot(scene.world, &snap)
	testing.expect(t, snap.data != nil && snap.size > 0)
	saved_hash := state_hash(scene.bodies[:])
	step(scene.world, 60)
	advanced_hash := state_hash(scene.bodies[:])
	testing.expect(t, advanced_hash != saved_hash)
	testing.expect(t, b3.world_restore_snapshot(scene.world, &snap))
	testing.expect_value(t, state_hash(scene.bodies[:]), saved_hash)
	step(scene.world, 60)
	testing.expect_value(t, state_hash(scene.bodies[:]), advanced_hash)
	b3.destroy_world_snapshot(&snap)
	testing.expect(t, snap.data == nil && snap.size == 0 && snap.capacity == 0)
}

@(test)
test_world_state_and_images :: proc(t: ^testing.T) {
	scene_a, scene_b: Scene
	scene_make(&scene_a)
	defer scene_destroy(&scene_a)
	scene_make(&scene_b)
	defer scene_destroy(&scene_b)
	world_state := b3.create_world_state()
	defer b3.destroy_world_state(world_state)
	testing.expect(t, world_state != nil)
	step(scene_a.world, 100)
	image_size := b3.world_save_image(scene_a.world, world_state, true)
	data := b3.world_state_get_data(world_state)
	testing.expect(t, image_size > 0)
	testing.expect_value(t, len(data), int(image_size))
	image := make([]u8, len(data), context.temp_allocator)
	copy(image, data)
	testing.expect(t, b3.world_load_image(scene_b.world, image))
	testing.expect_value(t, state_hash(scene_b.bodies[:]), state_hash(scene_a.bodies[:]))
	testing.expect_value(t, b3.world_hash_state(scene_b.world), b3.world_hash_state(scene_a.world))
	step(scene_a.world, 60)
	step(scene_b.world, 60)
	testing.expect_value(t, state_hash(scene_b.bodies[:]), state_hash(scene_a.bodies[:]))
	// Damaged images are refused.
	testing.expect(t, !b3.world_load_image(scene_b.world, nil))
	testing.expect(t, !b3.world_load_image(scene_b.world, image[:20]))
}

@(test)
test_world_hash_state :: proc(t: ^testing.T) {
	scene_a, scene_b: Scene
	scene_make(&scene_a)
	defer scene_destroy(&scene_a)
	scene_make(&scene_b)
	defer scene_destroy(&scene_b)
	testing.expect_value(t, b3.world_hash_state(scene_a.world), b3.world_hash_state(scene_b.world))
	hash := b3.world_hash_state(scene_a.world)
	step(scene_a.world, 1)
	testing.expect(t, b3.world_hash_state(scene_a.world) != hash)
	testing.expect_value(t, b3.world_hash_state(scene_a.world), box3d.World_HashState(scene_a.world))
}

@(test)
test_world_hash_awake_bodies :: proc(t: ^testing.T) {
	scene_a, scene_b: Scene
	scene_make(&scene_a)
	defer scene_destroy(&scene_a)
	scene_make(&scene_b)
	defer scene_destroy(&scene_b)
	testing.expect_value(t, b3.world_hash_awake_bodies(scene_a.world), b3.world_hash_awake_bodies(scene_b.world))
	hash := b3.world_hash_awake_bodies(scene_a.world)
	step(scene_a.world, 1)
	step(scene_b.world, 1)
	testing.expect(t, b3.world_hash_awake_bodies(scene_a.world) != hash)
	testing.expect_value(t, b3.world_hash_awake_bodies(scene_a.world), b3.world_hash_awake_bodies(scene_b.world))
	testing.expect_value(t, b3.world_hash_awake_bodies(scene_a.world), box3d.World_HashAwakeBodies(scene_a.world))
	// Which bodies are awake counts: putting one to sleep changes the hash.
	box3d.Body_SetAwake(scene_b.bodies[len(scene_b.bodies) - 1], false)
	testing.expect(t, b3.world_hash_awake_bodies(scene_a.world) != b3.world_hash_awake_bodies(scene_b.world))
	// So does any awake body's velocity.
	b3.body_set_linear_velocity(scene_a.bodies[2], {0, 1, 0})
	b3.body_set_linear_velocity(scene_b.bodies[2], {0, 1.5, 0})
	box3d.Body_SetAwake(scene_b.bodies[len(scene_b.bodies) - 1], true)
	testing.expect(t, b3.world_hash_awake_bodies(scene_a.world) != b3.world_hash_awake_bodies(scene_b.world))
}

// ---- queries

// The filter physics' queries start from (physics.Query's zero value: everything).
@(test)
test_default_query_filter :: proc(t: ^testing.T) {
	filter := b3.default_query_filter()
	box_filter := box3d.DefaultQueryFilter()
	testing.expect_value(t, filter.category_bits, box_filter.categoryBits)
	testing.expect_value(t, filter.mask_bits, box_filter.maskBits)
	testing.expect_value(t, filter.mask_bits, max(u64))
}
