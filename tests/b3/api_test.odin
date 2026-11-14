// One test per unified:b3 proc, against the library. Setters are read back through the bindings' getters where the
// wrapper has none, so a wrong conversion shows.
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

@(test)
test_world_get_gravity :: proc(t: ^testing.T) {
	world := world_make([3]f32{1, -2, 3})
	defer physics.destroy(world)
	testing.expect_value(t, b3.world_get_gravity(world.id), [3]f32{1, -2, 3})
}

@(test)
test_world_get_contact_events :: proc(t: ^testing.T) {
	world := physics.create({hit_threshold = 1})
	defer physics.destroy(world)
	shape_def := b3.default_shape_def()
	shape_def.enable_hit_events = true
	shape_def.base_material.user_material_id = 7
	ground := box_body(world.id, .Static_Body, {0, -0.5, 0}, {10, 0.5, 10}, &shape_def)
	shape_def.base_material.user_material_id = 9
	ball := box_body(world.id, .Dynamic_Body, {0, 1, 0}, {0.5, 0.5, 0.5}, &shape_def)
	b3.body_set_linear_velocity(ball, {0, -10, 0})
	hits: int
	for _ in 0 ..< 16 {
		b3.world_step(world.id, DT, SUBSTEPS)
		events := b3.world_get_contact_events(world.id)
		for hit in events.hit_events {
			hits += 1
			body_a, body_b := b3.shape_get_body(hit.shape_id_a), b3.shape_get_body(hit.shape_id_b)
			testing.expect(t, (body_a == ground && body_b == ball) || (body_a == ball && body_b == ground))
			testing.expect(t, hit.approach_speed > 1)
			testing.expect(t, hit.point.y > -0.1 && hit.point.y < 0.1, "the hit is on the ground's top face")
			testing.expect(t, abs(hit.normal.y) > 0.99)
			testing.expect(t, hit.user_material_id_a + hit.user_material_id_b == 16)
		}
		if len(events.begin_events) > 0 {
			testing.expect(
				t,
				b3.shape_get_body(events.begin_events[0].shape_id_a) !=
				b3.shape_get_body(events.begin_events[0].shape_id_b),
			)
		}
	}
	testing.expect_value(t, hits, 1)
}

Overlap_Got :: struct {
	bodies: [dynamic]b3.Body_Id,
	ctx_ok: bool,
	stop:   bool,
}

@(test)
test_world_overlap_aabb :: proc(t: ^testing.T) {
	world := world_make()
	defer physics.destroy(world)
	body := box_body(world.id, .Static_Body, {0, 0, 0}, {0.5, 0.5, 0.5})
	box_body(world.id, .Static_Body, {10, 0, 0}, {0.5, 0.5, 0.5})
	got := Overlap_Got {
		bodies = make([dynamic]b3.Body_Id, context.temp_allocator),
		ctx_ok = true,
	}
	context.user_index = 4242 // the trampoline carries the caller's context into the callback
	fcn :: proc(shape: b3.Shape_Id, user: rawptr) -> bool {
		collector := (^Overlap_Got)(user)
		collector.ctx_ok &&= context.user_index == 4242
		append(&collector.bodies, b3.shape_get_body(shape))
		return !collector.stop
	}
	b3.world_overlap_aabb(world.id, {{-1, -1, -1}, {1, 1, 1}}, b3.default_query_filter(), fcn, &got)
	testing.expect_value(t, len(got.bodies), 1)
	testing.expect(t, len(got.bodies) == 1 && got.bodies[0] == body)
	testing.expect(t, got.ctx_ok)
	// Returning false stops the query.
	clear(&got.bodies)
	got.stop = true
	b3.world_overlap_aabb(world.id, {{-20, -20, -20}, {20, 20, 20}}, b3.default_query_filter(), fcn, &got)
	testing.expect_value(t, len(got.bodies), 1)
}

Cast_Got :: struct {
	count:    int,
	point:    [3]f32,
	normal:   [3]f32,
	fraction: f32,
	material: u64,
	ctx_ok:   bool,
}

@(test)
test_world_cast_ray :: proc(t: ^testing.T) {
	world := world_make()
	defer physics.destroy(world)
	shape_def := b3.default_shape_def()
	shape_def.base_material.user_material_id = 31
	box_body(world.id, .Static_Body, {0, 0, 0}, {1, 1, 1}, &shape_def)
	shape_def.base_material.user_material_id = 32
	box_body(world.id, .Static_Body, {0, 0, 5}, {1, 1, 1}, &shape_def)
	got := Cast_Got {
		ctx_ok = true,
	}
	context.user_index = 77
	fcn :: proc(
		shape: b3.Shape_Id,
		point, normal: [3]f32,
		fraction: f32,
		material: u64,
		triangle, child: i32,
		user: rawptr,
	) -> f32 {
		collector := (^Cast_Got)(user)
		collector.ctx_ok &&= context.user_index == 77
		collector.count += 1
		if collector.count == 1 || fraction < collector.fraction {
			collector^ = {collector.count, point, normal, fraction, material, collector.ctx_ok}
		}
		return 1 // don't clip: see every shape
	}
	b3.world_cast_ray(world.id, {0, 0, -5}, {0, 0, 20}, b3.default_query_filter(), fcn, &got)
	testing.expect_value(t, got.count, 2)
	testing.expect_value(t, got.material, 31)
	testing.expect_value(t, got.normal, [3]f32{0, 0, -1})
	testing.expectf(t, abs(got.point.z + 1) < 1e-4, "hit at %v", got.point)
	testing.expectf(t, abs(got.fraction - 0.2) < 1e-4, "fraction %v", got.fraction)
	testing.expect(t, got.ctx_ok)
}

@(test)
test_world_cast_ray_closest :: proc(t: ^testing.T) {
	world := world_make()
	defer physics.destroy(world)
	CAT_A :: u64(1 << 1)
	CAT_B :: u64(1 << 2)
	shape_def := b3.default_shape_def()
	shape_def.base_material.user_material_id = 1007
	shape_def.filter.category_bits = CAT_A
	body_a := box_body(world.id, .Static_Body, {0, 0, 0}, {1, 1, 1}, &shape_def)
	shape_def.base_material.user_material_id = 2002
	shape_def.filter.category_bits = CAT_B
	box_body(world.id, .Static_Body, {0, 0, 5}, {1, 1, 1}, &shape_def)
	filter := b3.default_query_filter()
	ray, ok := b3.world_cast_ray_closest(world.id, {0, 0, -5}, {0, 0, 20}, filter)
	testing.expect(t, ok)
	testing.expect_value(t, ray.user_material_id, 1007)
	testing.expect_value(t, b3.shape_get_body(ray.shape_id), body_a)
	testing.expectf(t, abs(ray.point.z + 1) < 1e-4, "hit at %v", ray.point)
	testing.expectf(t, abs(ray.fraction - 0.2) < 1e-4, "fraction %v", ray.fraction)
	testing.expect_value(t, ray.normal, [3]f32{0, 0, -1})
	filter.mask_bits = CAT_B
	ray, ok = b3.world_cast_ray_closest(world.id, {0, 0, -5}, {0, 0, 20}, filter)
	testing.expect(t, ok)
	testing.expect_value(t, ray.user_material_id, 2002)
	filter.mask_bits = 1 << 5
	_, ok = b3.world_cast_ray_closest(world.id, {0, 0, -5}, {0, 0, 20}, filter)
	testing.expect(t, !ok)
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

// ---- bodies

@(test)
test_default_body_def :: proc(t: ^testing.T) {
	body_def := b3.default_body_def()
	testing.expect_value(t, body_def.type, b3.Body_Type.Static_Body)
	testing.expect_value(t, body_def.rotation, [4]f32{0, 0, 0, 1})
	testing.expect_value(t, body_def.gravity_scale, 1)
	testing.expect(t, body_def.enable_sleep && body_def.is_awake && body_def.is_enabled)
	testing.expect(t, body_def.internal_value != 0)
}

@(test)
test_create_body_destroy_body_body_is_valid :: proc(t: ^testing.T) {
	world := world_make()
	defer physics.destroy(world)
	body_def := b3.default_body_def()
	body_def.type = .Dynamic_Body
	body_def.position = {1, 2, 3}
	body_def.rotation = {0, 0.6, 0, 0.8}
	body_def.linear_velocity = {4, 5, 6}
	body_def.angular_velocity = {0, 1, 0}
	body_def.gravity_scale = 0.5
	body_def.motion_locks = {
		angular_x = true,
	}
	body_def.name = "body"
	id := b3.create_body(world.id, &body_def)
	testing.expect(t, b3.body_is_valid(id))
	testing.expect_value(t, b3.body_get_position(id), [3]f32{1, 2, 3})
	testing.expect_value(t, b3.body_get_rotation(id), [4]f32{0, 0.6, 0, 0.8})
	testing.expect_value(t, b3.body_get_linear_velocity(id), [3]f32{4, 5, 6})
	testing.expect_value(t, box3d.Body_GetGravityScale(id), 0.5)
	testing.expect(t, box3d.Body_GetMotionLocks(id).angularX && !box3d.Body_GetMotionLocks(id).angularY)
	b3.destroy_body(id)
	testing.expect(t, !b3.body_is_valid(id))
}

@(test)
test_body_get_type :: proc(t: ^testing.T) {
	world := world_make()
	defer physics.destroy(world)
	for type in b3.Body_Type {
		testing.expect_value(t, b3.body_get_type(box_body(world.id, type, {}, {0.5, 0.5, 0.5})), type)
	}
}

@(test)
test_body_get_position_rotation_set_transform :: proc(t: ^testing.T) {
	world := world_make()
	defer physics.destroy(world)
	body := box_body(world.id, .Dynamic_Body, {0, 1, 0}, {0.5, 0.5, 0.5})
	b3.body_set_transform(body, {7, 8, 9}, {0, 0, 0.6, 0.8})
	testing.expect_value(t, b3.body_get_position(body), [3]f32{7, 8, 9})
	testing.expect_value(t, b3.body_get_rotation(body), [4]f32{0, 0, 0.6, 0.8})
	testing.expect_value(t, b3.body_get_position(body), transmute([3]f32)box3d.Body_GetPosition(body))
}

@(test)
test_body_get_local_point :: proc(t: ^testing.T) {
	world := world_make()
	defer physics.destroy(world)
	body := box_body(world.id, .Static_Body, {1, 2, 3}, {0.5, 0.5, 0.5})
	testing.expect_value(t, b3.body_get_local_point(body, {2, 2, 3}), [3]f32{1, 0, 0})
}

@(test)
test_body_linear_and_angular_velocity :: proc(t: ^testing.T) {
	world := world_make([3]f32{})
	defer physics.destroy(world)
	body := box_body(world.id, .Dynamic_Body, {}, {0.5, 0.5, 0.5})
	b3.body_set_linear_velocity(body, {2, -1, 0.5})
	b3.body_set_angular_velocity(body, {0, 3, 0})
	testing.expect_value(t, b3.body_get_linear_velocity(body), [3]f32{2, -1, 0.5})
	testing.expect_value(t, b3.body_get_angular_velocity(body), [3]f32{0, 3, 0})
}

@(test)
test_body_apply_linear_impulse_to_center :: proc(t: ^testing.T) {
	world := world_make([3]f32{})
	defer physics.destroy(world)
	body := box_body(world.id, .Dynamic_Body, {}, {0.5, 0.5, 0.5}) // 1 m³ at density 1: mass 1
	b3.body_apply_linear_impulse_to_center(body, {0, 0, 3}, true)
	velocity := b3.body_get_linear_velocity(body)
	testing.expectf(t, velocity.x == 0 && abs(velocity.z - 3) < 1e-4, "after impulse: %velocity", velocity)
}

@(test)
test_body_get_mass :: proc(t: ^testing.T) {
	world := world_make()
	defer physics.destroy(world)
	body := box_body(world.id, .Dynamic_Body, {}, {1, 0.5, 0.5}) // 2 m³ at density 1
	testing.expectf(t, abs(b3.body_get_mass(body) - 2) < 1e-4, "mass %v", b3.body_get_mass(body))
}

// ---- shapes and geometry

@(test)
test_default_shape_def :: proc(t: ^testing.T) {
	shape_def := b3.default_shape_def()
	box_def := box3d.DefaultShapeDef()
	testing.expect_value(t, shape_def.density, box_def.density)
	testing.expect_value(t, shape_def.filter.category_bits, box_def.filter.categoryBits)
	testing.expect_value(t, shape_def.filter.mask_bits, box_def.filter.maskBits)
	testing.expect_value(t, shape_def.base_material.friction, box_def.baseMaterial.friction)
	testing.expect_value(t, shape_def.enable_hit_events, box_def.enableHitEvents)
	testing.expect_value(t, shape_def.internal_value, box_def.internalValue)
	testing.expect(
		t,
		shape_def.density > 0 && shape_def.base_material.friction > 0 && shape_def.filter.mask_bits == max(u64),
	)
}

@(test)
test_default_query_filter :: proc(t: ^testing.T) {
	filter := b3.default_query_filter()
	box_filter := box3d.DefaultQueryFilter()
	testing.expect_value(t, filter.category_bits, box_filter.categoryBits)
	testing.expect_value(t, filter.mask_bits, box_filter.maskBits)
	testing.expect_value(t, filter.mask_bits, max(u64))
}

@(test)
test_create_sphere_shape :: proc(t: ^testing.T) {
	world := world_make()
	defer physics.destroy(world)
	body_def := b3.default_body_def()
	body_def.type = .Dynamic_Body
	body := b3.create_body(world.id, &body_def)
	shape_def := b3.default_shape_def()
	sphere := b3.Sphere{{1, 0, 0}, 0.5}
	id := b3.create_sphere_shape(body, &shape_def, &sphere)
	testing.expect_value(t, b3.shape_get_body(id), body)
	got := box3d.Shape_GetSphere(id)
	testing.expect_value(t, transmute([3]f32)got.center, [3]f32{1, 0, 0})
	testing.expect_value(t, got.radius, 0.5)
}

@(test)
test_create_capsule_shape :: proc(t: ^testing.T) {
	world := world_make()
	defer physics.destroy(world)
	body_def := b3.default_body_def()
	body := b3.create_body(world.id, &body_def)
	shape_def := b3.default_shape_def()
	capsule := b3.Capsule{{0, -1, 0}, {0, 1, 0}, 0.25}
	id := b3.create_capsule_shape(body, &shape_def, &capsule)
	got := box3d.Shape_GetCapsule(id)
	testing.expect_value(t, transmute([3]f32)got.center1, [3]f32{0, -1, 0})
	testing.expect_value(t, transmute([3]f32)got.center2, [3]f32{0, 1, 0})
	testing.expect_value(t, got.radius, 0.25)
}

@(test)
test_create_hull_shape_make_box_hull :: proc(t: ^testing.T) {
	world := world_make()
	defer physics.destroy(world)
	body_def := b3.default_body_def()
	body_def.type = .Dynamic_Body
	body := b3.create_body(world.id, &body_def)
	shape_def := b3.default_shape_def()
	shape_def.density = 2
	hull := b3.make_box_hull(1, 2, 3)
	testing.expectf(t, abs(hull.base.volume - 48) < 1e-3, "volume %v", hull.base.volume)
	id := b3.create_hull_shape(body, &shape_def, &hull.base)
	testing.expect_value(t, box3d.Shape_GetType(id), box3d.ShapeType.hullShape)
	testing.expectf(t, abs(b3.body_get_mass(body) - 96) < 1e-2, "mass %v", b3.body_get_mass(body))
}

@(test)
test_shape_get_body_shape_is_sensor :: proc(t: ^testing.T) {
	world := world_make()
	defer physics.destroy(world)
	body_def := b3.default_body_def()
	body := b3.create_body(world.id, &body_def)
	shape_def := b3.default_shape_def()
	sphere := b3.Sphere{{}, 1}
	solid := b3.create_sphere_shape(body, &shape_def, &sphere)
	shape_def.is_sensor = true
	sensor := b3.create_sphere_shape(body, &shape_def, &sphere)
	testing.expect_value(t, b3.shape_get_body(solid), body)
	testing.expect_value(t, b3.shape_get_body(sensor), body)
	testing.expect(t, !b3.shape_is_sensor(solid))
	testing.expect(t, b3.shape_is_sensor(sensor))
}

@(test)
test_create_hull_destroy_hull :: proc(t: ^testing.T) {
	points := [][3]f32 {
		{-1, -1, -1},
		{1, -1, -1},
		{1, 1, -1},
		{-1, 1, -1},
		{-1, -1, 1},
		{1, -1, 1},
		{1, 1, 1},
		{-1, 1, 1},
		{0, 0, 0},
	}
	hull := b3.create_hull(points, 64)
	testing.expect(t, hull != nil)
	if hull != nil {
		testing.expect_value(t, hull.vertexCount, 8) // the inner point is dropped
		testing.expectf(t, abs(hull.volume - 8) < 1e-3, "volume %v", hull.volume)
		b3.destroy_hull(hull)
	}
	flat := [][3]f32{{0, 0, 0}, {1, 0, 0}, {2, 0, 0}, {3, 0, 0}}
	testing.expect(t, b3.create_hull(flat, 64) == nil, "collinear points make no hull")
}

@(test)
test_clone_and_transform_hull :: proc(t: ^testing.T) {
	hull := b3.make_box_hull(1, 1, 1)
	cloned := b3.clone_and_transform_hull(&hull.base, {{5, 0, 0}, {0, 0, 0, 1}}, {2, 1, 1})
	defer b3.destroy_hull(cloned)
	testing.expectf(t, abs(cloned.volume - 16) < 1e-3, "volume %v", cloned.volume)
	testing.expectf(t, abs(cloned.center.x - 5) < 1e-4 && abs(cloned.center.y) < 1e-4, "center %v", cloned.center)
}

// ---- joints

Joint_Rig :: struct {
	phys:   ^physics.World,
	ground: b3.Body_Id,
	body:   b3.Body_Id,
}

rig_make :: proc() -> (rig: Joint_Rig) {
	rig.phys = world_make()
	rig.ground = box_body(rig.phys.id, .Static_Body, {0, -0.5, 0}, {10, 0.5, 10})
	rig.body = box_body(rig.phys.id, .Dynamic_Body, {0, 2, 0}, {0.5, 0.5, 0.5})
	return
}

@(test)
test_motor_joint :: proc(t: ^testing.T) {
	rig := rig_make()
	defer physics.destroy(rig.phys)
	joint_def := b3.default_motor_joint_def()
	joint_def.base.body_id_a = rig.ground
	joint_def.base.body_id_b = rig.body
	joint_def.base.local_frame_a = {{0, 2, 0}, {0, 0, 0, 1}}
	joint_def.linear_hertz = 5
	joint_def.linear_damping_ratio = 1
	joint_def.max_spring_force = 1000
	joint := b3.create_motor_joint(rig.phys.id, &joint_def)
	testing.expect(t, b3.joint_is_valid(joint))
	testing.expect_value(t, box3d.Joint_GetType(joint), box3d.JointType.motorJoint)
	testing.expect_value(t, box3d.MotorJoint_GetLinearHertz(joint), 5)
	testing.expect_value(t, box3d.MotorJoint_GetMaxSpringForce(joint), 1000)
	testing.expect_value(
		t,
		transmute(b3.Transform)box3d.Joint_GetLocalFrameA(joint),
		b3.Transform{{0, 2, 0}, {0, 0, 0, 1}},
	)
	testing.expect_value(t, box3d.Joint_GetBodyB(joint), rig.body)
}

@(test)
test_mover_joint :: proc(t: ^testing.T) {
	rig := rig_make()
	defer physics.destroy(rig.phys)
	joint_def := b3.default_mover_joint_def()
	joint_def.base.body_id_a = rig.ground
	joint_def.base.body_id_b = rig.body
	joint_def.linear_velocity = {1, 0, 0}
	joint_def.max_force = 50
	joint := b3.create_mover_joint(rig.phys.id, &joint_def)
	testing.expect_value(t, box3d.Joint_GetType(joint), box3d.JointType.moverJoint)
	testing.expect_value(t, transmute([3]f32)box3d.MoverJoint_GetLinearVelocity(joint), [3]f32{1, 0, 0})
	b3.mover_joint_set_linear_velocity(joint, {0, 0, 2})
	b3.mover_joint_set_max_velocity_force(joint, 75)
	testing.expect_value(t, transmute([3]f32)box3d.MoverJoint_GetLinearVelocity(joint), [3]f32{0, 0, 2})
	testing.expect_value(t, box3d.MoverJoint_GetMaxVelocityForce(joint), 75)
}

@(test)
test_pogo_joint :: proc(t: ^testing.T) {
	rig := rig_make()
	defer physics.destroy(rig.phys)
	pogo_def := b3.default_pogo_joint_def()
	pogo_def.base.body_id_a = rig.ground
	pogo_def.base.body_id_b = rig.body
	pogo_def.normal = {0, 1, 0}
	pogo_def.rest_length = 1.5
	pogo_def.hertz = 3
	pogo_def.damping_ratio = 0.8
	pogo_def.max_compression_force = 1000
	pogo_def.max_tension_force = 1000
	joint := b3.create_pogo_joint(rig.phys.id, &pogo_def)
	testing.expect_value(t, box3d.Joint_GetType(joint), box3d.JointType.pogoJoint)
	testing.expect_value(t, box3d.PogoJoint_GetRestLength(joint), 1.5)
	b3.pogo_joint_set_spring_hertz(joint, 4)
	b3.pogo_joint_set_spring_damping_ratio(joint, 0.5)
	b3.pogo_joint_set_max_tension_force(joint, 10)
	b3.pogo_joint_set_max_compression_force(joint, 2000)
	b3.pogo_joint_set_normal(joint, {0, 0, 1})
	testing.expect_value(t, box3d.PogoJoint_GetSpringHertz(joint), 4)
	testing.expect_value(t, box3d.PogoJoint_GetSpringDampingRatio(joint), 0.5)
	testing.expect_value(t, box3d.PogoJoint_GetMaxTensionForce(joint), 10)
	testing.expect_value(t, box3d.PogoJoint_GetMaxCompressionForce(joint), 2000)
	testing.expect_value(t, transmute([3]f32)box3d.PogoJoint_GetNormal(joint), [3]f32{0, 0, 1})
	b3.pogo_joint_set_normal(joint, {0, 1, 0})
	step(rig.phys.id, 30)
	testing.expect_value(t, b3.pogo_joint_get_impulse(joint), box3d.PogoJoint_GetImpulse(joint))
	testing.expect_value(t, b3.pogo_joint_get_current_speed(joint), box3d.PogoJoint_GetCurrentSpeed(joint))
	testing.expect(t, b3.pogo_joint_get_impulse(joint) != 0, "the spring pushes")
}

@(test)
test_joint_get_body_a_set_local_frames_destroy_joint :: proc(t: ^testing.T) {
	rig := rig_make()
	defer physics.destroy(rig.phys)
	joint_def := b3.default_mover_joint_def()
	joint_def.base.body_id_a = rig.ground
	joint_def.base.body_id_b = rig.body
	joint := b3.create_mover_joint(rig.phys.id, &joint_def)
	testing.expect_value(t, b3.joint_get_body_a(joint), rig.ground)
	b3.joint_set_local_frame_a(joint, {{1, 2, 3}, {0, 0.6, 0, 0.8}})
	b3.joint_set_local_frame_b(joint, {{-1, 0, 0}, {0, 0, 0, 1}})
	frame_a := box3d.Joint_GetLocalFrameA(joint)
	frame_b := box3d.Joint_GetLocalFrameB(joint)
	testing.expect_value(t, transmute(b3.Transform)frame_a, b3.Transform{{1, 2, 3}, {0, 0.6, 0, 0.8}})
	testing.expect_value(t, transmute(b3.Transform)frame_b, b3.Transform{{-1, 0, 0}, {0, 0, 0, 1}})
	testing.expect(t, b3.joint_is_valid(joint))
	b3.destroy_joint(joint, true)
	testing.expect(t, !b3.joint_is_valid(joint))
}
