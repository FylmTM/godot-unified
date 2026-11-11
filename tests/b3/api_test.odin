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
	d := b3.default_world_def()
	testing.expect_value(t, d.gravity, [3]f32{0, -10, 0})
	testing.expect(t, d.enable_sleep && d.enable_continuous)
	testing.expect(t, d.hit_event_threshold > 0 && d.contact_hertz > 0)
	testing.expect(t, d.internal_value != 0)
}

// create_world and destroy_world through physics.create/destroy, which serialise them (Box3D's world table is global).
@(test)
test_create_world_destroy_world :: proc(t: ^testing.T) {
	w := world_make([3]f32{1, -2, 3})
	id := w.id
	testing.expect(t, id.index1 != 0)
	testing.expect(t, box3d.World_IsValid(id))
	physics.destroy(w)
	testing.expect(t, !box3d.World_IsValid(id))
}

@(test)
test_world_step :: proc(t: ^testing.T) {
	pw := world_make()
	defer physics.destroy(pw)
	b := box_body(pw.id, .Dynamic_Body, {0, 5, 0}, {0.5, 0.5, 0.5})
	b3.world_step(pw.id, DT, SUBSTEPS)
	testing.expect(t, b3.body_get_position(b).y < 5)
	testing.expect(t, b3.body_get_linear_velocity(b).y < 0)
}

@(test)
test_world_get_gravity :: proc(t: ^testing.T) {
	pw := world_make([3]f32{1, -2, 3})
	defer physics.destroy(pw)
	testing.expect_value(t, b3.world_get_gravity(pw.id), [3]f32{1, -2, 3})
}

@(test)
test_world_get_contact_events :: proc(t: ^testing.T) {
	pw := physics.create({hit_threshold = 1})
	defer physics.destroy(pw)
	sd := b3.default_shape_def()
	sd.enable_hit_events = true
	sd.base_material.user_material_id = 7
	ground := box_body(pw.id, .Static_Body, {0, -0.5, 0}, {10, 0.5, 10}, &sd)
	sd.base_material.user_material_id = 9
	ball := box_body(pw.id, .Dynamic_Body, {0, 1, 0}, {0.5, 0.5, 0.5}, &sd)
	b3.body_set_linear_velocity(ball, {0, -10, 0})
	hits: int
	for _ in 0 ..< 16 {
		b3.world_step(pw.id, DT, SUBSTEPS)
		ev := b3.world_get_contact_events(pw.id)
		for h in ev.hit_events {
			hits += 1
			a, b := b3.shape_get_body(h.shape_id_a), b3.shape_get_body(h.shape_id_b)
			testing.expect(t, (a == ground && b == ball) || (a == ball && b == ground))
			testing.expect(t, h.approach_speed > 1)
			testing.expect(t, h.point.y > -0.1 && h.point.y < 0.1, "the hit is on the ground's top face")
			testing.expect(t, abs(h.normal.y) > 0.99)
			testing.expect(t, h.user_material_id_a + h.user_material_id_b == 16)
		}
		if len(ev.begin_events) > 0 {
			testing.expect(
				t,
				b3.shape_get_body(ev.begin_events[0].shape_id_a) != b3.shape_get_body(ev.begin_events[0].shape_id_b),
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
	pw := world_make()
	defer physics.destroy(pw)
	a := box_body(pw.id, .Static_Body, {0, 0, 0}, {0.5, 0.5, 0.5})
	box_body(pw.id, .Static_Body, {10, 0, 0}, {0.5, 0.5, 0.5})
	got := Overlap_Got {
		bodies = make([dynamic]b3.Body_Id, context.temp_allocator),
		ctx_ok = true,
	}
	context.user_index = 4242 // the trampoline carries the caller's context into the callback
	fcn :: proc(shape: b3.Shape_Id, user: rawptr) -> bool {
		g := (^Overlap_Got)(user)
		g.ctx_ok &&= context.user_index == 4242
		append(&g.bodies, b3.shape_get_body(shape))
		return !g.stop
	}
	b3.world_overlap_aabb(pw.id, {{-1, -1, -1}, {1, 1, 1}}, b3.default_query_filter(), fcn, &got)
	testing.expect_value(t, len(got.bodies), 1)
	testing.expect(t, len(got.bodies) == 1 && got.bodies[0] == a)
	testing.expect(t, got.ctx_ok)
	// Returning false stops the query.
	clear(&got.bodies)
	got.stop = true
	b3.world_overlap_aabb(pw.id, {{-20, -20, -20}, {20, 20, 20}}, b3.default_query_filter(), fcn, &got)
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
	pw := world_make()
	defer physics.destroy(pw)
	sd := b3.default_shape_def()
	sd.base_material.user_material_id = 31
	box_body(pw.id, .Static_Body, {0, 0, 0}, {1, 1, 1}, &sd)
	sd.base_material.user_material_id = 32
	box_body(pw.id, .Static_Body, {0, 0, 5}, {1, 1, 1}, &sd)
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
		g := (^Cast_Got)(user)
		g.ctx_ok &&= context.user_index == 77
		g.count += 1
		if g.count == 1 || fraction < g.fraction {
			g^ = {g.count, point, normal, fraction, material, g.ctx_ok}
		}
		return 1 // don't clip: see every shape
	}
	b3.world_cast_ray(pw.id, {0, 0, -5}, {0, 0, 20}, b3.default_query_filter(), fcn, &got)
	testing.expect_value(t, got.count, 2)
	testing.expect_value(t, got.material, 31)
	testing.expect_value(t, got.normal, [3]f32{0, 0, -1})
	testing.expectf(t, abs(got.point.z + 1) < 1e-4, "hit at %v", got.point)
	testing.expectf(t, abs(got.fraction - 0.2) < 1e-4, "fraction %v", got.fraction)
	testing.expect(t, got.ctx_ok)
}

@(test)
test_world_cast_ray_closest :: proc(t: ^testing.T) {
	pw := world_make()
	defer physics.destroy(pw)
	CAT_A :: u64(1 << 1)
	CAT_B :: u64(1 << 2)
	sd := b3.default_shape_def()
	sd.base_material.user_material_id = 1007
	sd.filter.category_bits = CAT_A
	a := box_body(pw.id, .Static_Body, {0, 0, 0}, {1, 1, 1}, &sd)
	sd.base_material.user_material_id = 2002
	sd.filter.category_bits = CAT_B
	box_body(pw.id, .Static_Body, {0, 0, 5}, {1, 1, 1}, &sd)
	qf := b3.default_query_filter()
	r, ok := b3.world_cast_ray_closest(pw.id, {0, 0, -5}, {0, 0, 20}, qf)
	testing.expect(t, ok)
	testing.expect_value(t, r.user_material_id, 1007)
	testing.expect_value(t, b3.shape_get_body(r.shape_id), a)
	testing.expectf(t, abs(r.point.z + 1) < 1e-4, "hit at %v", r.point)
	testing.expectf(t, abs(r.fraction - 0.2) < 1e-4, "fraction %v", r.fraction)
	testing.expect_value(t, r.normal, [3]f32{0, 0, -1})
	qf.mask_bits = CAT_B
	r, ok = b3.world_cast_ray_closest(pw.id, {0, 0, -5}, {0, 0, 20}, qf)
	testing.expect(t, ok)
	testing.expect_value(t, r.user_material_id, 2002)
	qf.mask_bits = 1 << 5
	_, ok = b3.world_cast_ray_closest(pw.id, {0, 0, -5}, {0, 0, 20}, qf)
	testing.expect(t, !ok)
}

// ---- snapshots, images, hashes

@(test)
test_world_save_snapshot_restore_destroy :: proc(t: ^testing.T) {
	s: Scene
	scene_make(&s)
	defer scene_destroy(&s)
	snap: b3.World_Snapshot
	step(s.world, 30)
	b3.world_save_snapshot(s.world, &snap)
	testing.expect(t, snap.data != nil && snap.size > 0)
	h0 := state_hash(s.bodies[:])
	step(s.world, 60)
	h1 := state_hash(s.bodies[:])
	testing.expect(t, h1 != h0)
	testing.expect(t, b3.world_restore_snapshot(s.world, &snap))
	testing.expect_value(t, state_hash(s.bodies[:]), h0)
	step(s.world, 60)
	testing.expect_value(t, state_hash(s.bodies[:]), h1)
	b3.destroy_world_snapshot(&snap)
	testing.expect(t, snap.data == nil && snap.size == 0 && snap.capacity == 0)
}

@(test)
test_world_state_and_images :: proc(t: ^testing.T) {
	a, b: Scene
	scene_make(&a)
	defer scene_destroy(&a)
	scene_make(&b)
	defer scene_destroy(&b)
	st := b3.create_world_state()
	defer b3.destroy_world_state(st)
	testing.expect(t, st != nil)
	step(a.world, 100)
	n := b3.world_save_image(a.world, st, true)
	data := b3.world_state_get_data(st)
	testing.expect(t, n > 0)
	testing.expect_value(t, len(data), int(n))
	image := make([]u8, len(data), context.temp_allocator)
	copy(image, data)
	testing.expect(t, b3.world_load_image(b.world, image))
	testing.expect_value(t, state_hash(b.bodies[:]), state_hash(a.bodies[:]))
	testing.expect_value(t, b3.world_hash_state(b.world), b3.world_hash_state(a.world))
	step(a.world, 60)
	step(b.world, 60)
	testing.expect_value(t, state_hash(b.bodies[:]), state_hash(a.bodies[:]))
	// Damaged images are refused.
	testing.expect(t, !b3.world_load_image(b.world, nil))
	testing.expect(t, !b3.world_load_image(b.world, image[:20]))
}

@(test)
test_world_hash_state :: proc(t: ^testing.T) {
	a, b: Scene
	scene_make(&a)
	defer scene_destroy(&a)
	scene_make(&b)
	defer scene_destroy(&b)
	testing.expect_value(t, b3.world_hash_state(a.world), b3.world_hash_state(b.world))
	h := b3.world_hash_state(a.world)
	step(a.world, 1)
	testing.expect(t, b3.world_hash_state(a.world) != h)
	testing.expect_value(t, b3.world_hash_state(a.world), box3d.World_HashState(a.world))
}

// ---- bodies

@(test)
test_default_body_def :: proc(t: ^testing.T) {
	d := b3.default_body_def()
	testing.expect_value(t, d.type, b3.Body_Type.Static_Body)
	testing.expect_value(t, d.rotation, [4]f32{0, 0, 0, 1})
	testing.expect_value(t, d.gravity_scale, 1)
	testing.expect(t, d.enable_sleep && d.is_awake && d.is_enabled)
	testing.expect(t, d.internal_value != 0)
}

@(test)
test_create_body_destroy_body_body_is_valid :: proc(t: ^testing.T) {
	pw := world_make()
	defer physics.destroy(pw)
	bd := b3.default_body_def()
	bd.type = .Dynamic_Body
	bd.position = {1, 2, 3}
	bd.rotation = {0, 0.6, 0, 0.8}
	bd.linear_velocity = {4, 5, 6}
	bd.angular_velocity = {0, 1, 0}
	bd.gravity_scale = 0.5
	bd.motion_locks = {
		angular_x = true,
	}
	bd.name = "body"
	id := b3.create_body(pw.id, &bd)
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
	pw := world_make()
	defer physics.destroy(pw)
	for type in b3.Body_Type {
		testing.expect_value(t, b3.body_get_type(box_body(pw.id, type, {}, {0.5, 0.5, 0.5})), type)
	}
}

@(test)
test_body_get_position_rotation_set_transform :: proc(t: ^testing.T) {
	pw := world_make()
	defer physics.destroy(pw)
	b := box_body(pw.id, .Dynamic_Body, {0, 1, 0}, {0.5, 0.5, 0.5})
	b3.body_set_transform(b, {7, 8, 9}, {0, 0, 0.6, 0.8})
	testing.expect_value(t, b3.body_get_position(b), [3]f32{7, 8, 9})
	testing.expect_value(t, b3.body_get_rotation(b), [4]f32{0, 0, 0.6, 0.8})
	testing.expect_value(t, b3.body_get_position(b), transmute([3]f32)box3d.Body_GetPosition(b))
}

@(test)
test_body_get_local_point :: proc(t: ^testing.T) {
	pw := world_make()
	defer physics.destroy(pw)
	b := box_body(pw.id, .Static_Body, {1, 2, 3}, {0.5, 0.5, 0.5})
	testing.expect_value(t, b3.body_get_local_point(b, {2, 2, 3}), [3]f32{1, 0, 0})
}

@(test)
test_body_linear_and_angular_velocity :: proc(t: ^testing.T) {
	pw := world_make([3]f32{})
	defer physics.destroy(pw)
	b := box_body(pw.id, .Dynamic_Body, {}, {0.5, 0.5, 0.5})
	b3.body_set_linear_velocity(b, {2, -1, 0.5})
	b3.body_set_angular_velocity(b, {0, 3, 0})
	testing.expect_value(t, b3.body_get_linear_velocity(b), [3]f32{2, -1, 0.5})
	testing.expect_value(t, b3.body_get_angular_velocity(b), [3]f32{0, 3, 0})
}

@(test)
test_body_apply_linear_impulse_to_center :: proc(t: ^testing.T) {
	pw := world_make([3]f32{})
	defer physics.destroy(pw)
	b := box_body(pw.id, .Dynamic_Body, {}, {0.5, 0.5, 0.5}) // 1 m³ at density 1: mass 1
	b3.body_apply_linear_impulse_to_center(b, {0, 0, 3}, true)
	v := b3.body_get_linear_velocity(b)
	testing.expectf(t, v.x == 0 && abs(v.z - 3) < 1e-4, "after impulse: %v", v)
}

@(test)
test_body_get_mass :: proc(t: ^testing.T) {
	pw := world_make()
	defer physics.destroy(pw)
	b := box_body(pw.id, .Dynamic_Body, {}, {1, 0.5, 0.5}) // 2 m³ at density 1
	testing.expectf(t, abs(b3.body_get_mass(b) - 2) < 1e-4, "mass %v", b3.body_get_mass(b))
}

// ---- shapes and geometry

@(test)
test_default_shape_def :: proc(t: ^testing.T) {
	d := b3.default_shape_def()
	c := box3d.DefaultShapeDef()
	testing.expect_value(t, d.density, c.density)
	testing.expect_value(t, d.filter.category_bits, c.filter.categoryBits)
	testing.expect_value(t, d.filter.mask_bits, c.filter.maskBits)
	testing.expect_value(t, d.base_material.friction, c.baseMaterial.friction)
	testing.expect_value(t, d.enable_hit_events, c.enableHitEvents)
	testing.expect_value(t, d.internal_value, c.internalValue)
	testing.expect(t, d.density > 0 && d.base_material.friction > 0 && d.filter.mask_bits == max(u64))
}

@(test)
test_default_query_filter :: proc(t: ^testing.T) {
	f := b3.default_query_filter()
	c := box3d.DefaultQueryFilter()
	testing.expect_value(t, f.category_bits, c.categoryBits)
	testing.expect_value(t, f.mask_bits, c.maskBits)
	testing.expect_value(t, f.mask_bits, max(u64))
}

@(test)
test_create_sphere_shape :: proc(t: ^testing.T) {
	pw := world_make()
	defer physics.destroy(pw)
	bd := b3.default_body_def()
	bd.type = .Dynamic_Body
	b := b3.create_body(pw.id, &bd)
	sd := b3.default_shape_def()
	s := b3.Sphere{{1, 0, 0}, 0.5}
	id := b3.create_sphere_shape(b, &sd, &s)
	testing.expect_value(t, b3.shape_get_body(id), b)
	got := box3d.Shape_GetSphere(id)
	testing.expect_value(t, transmute([3]f32)got.center, [3]f32{1, 0, 0})
	testing.expect_value(t, got.radius, 0.5)
}

@(test)
test_create_capsule_shape :: proc(t: ^testing.T) {
	pw := world_make()
	defer physics.destroy(pw)
	bd := b3.default_body_def()
	b := b3.create_body(pw.id, &bd)
	sd := b3.default_shape_def()
	c := b3.Capsule{{0, -1, 0}, {0, 1, 0}, 0.25}
	id := b3.create_capsule_shape(b, &sd, &c)
	got := box3d.Shape_GetCapsule(id)
	testing.expect_value(t, transmute([3]f32)got.center1, [3]f32{0, -1, 0})
	testing.expect_value(t, transmute([3]f32)got.center2, [3]f32{0, 1, 0})
	testing.expect_value(t, got.radius, 0.25)
}

@(test)
test_create_hull_shape_make_box_hull :: proc(t: ^testing.T) {
	pw := world_make()
	defer physics.destroy(pw)
	bd := b3.default_body_def()
	bd.type = .Dynamic_Body
	b := b3.create_body(pw.id, &bd)
	sd := b3.default_shape_def()
	sd.density = 2
	h := b3.make_box_hull(1, 2, 3)
	testing.expectf(t, abs(h.base.volume - 48) < 1e-3, "volume %v", h.base.volume)
	id := b3.create_hull_shape(b, &sd, &h.base)
	testing.expect_value(t, box3d.Shape_GetType(id), box3d.ShapeType.hullShape)
	testing.expectf(t, abs(b3.body_get_mass(b) - 96) < 1e-2, "mass %v", b3.body_get_mass(b))
}

@(test)
test_shape_get_body_shape_is_sensor :: proc(t: ^testing.T) {
	pw := world_make()
	defer physics.destroy(pw)
	bd := b3.default_body_def()
	b := b3.create_body(pw.id, &bd)
	sd := b3.default_shape_def()
	s := b3.Sphere{{}, 1}
	solid := b3.create_sphere_shape(b, &sd, &s)
	sd.is_sensor = true
	sensor := b3.create_sphere_shape(b, &sd, &s)
	testing.expect_value(t, b3.shape_get_body(solid), b)
	testing.expect_value(t, b3.shape_get_body(sensor), b)
	testing.expect(t, !b3.shape_is_sensor(solid))
	testing.expect(t, b3.shape_is_sensor(sensor))
}

@(test)
test_create_hull_destroy_hull :: proc(t: ^testing.T) {
	pts := [][3]f32 {
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
	h := b3.create_hull(pts, 64)
	testing.expect(t, h != nil)
	if h != nil {
		testing.expect_value(t, h.vertexCount, 8) // the inner point is dropped
		testing.expectf(t, abs(h.volume - 8) < 1e-3, "volume %v", h.volume)
		b3.destroy_hull(h)
	}
	flat := [][3]f32{{0, 0, 0}, {1, 0, 0}, {2, 0, 0}, {3, 0, 0}}
	testing.expect(t, b3.create_hull(flat, 64) == nil, "collinear points make no hull")
}

@(test)
test_clone_and_transform_hull :: proc(t: ^testing.T) {
	h := b3.make_box_hull(1, 1, 1)
	c := b3.clone_and_transform_hull(&h.base, {{5, 0, 0}, {0, 0, 0, 1}}, {2, 1, 1})
	defer b3.destroy_hull(c)
	testing.expectf(t, abs(c.volume - 16) < 1e-3, "volume %v", c.volume)
	testing.expectf(t, abs(c.center.x - 5) < 1e-4 && abs(c.center.y) < 1e-4, "center %v", c.center)
}

// ---- joints

Joint_Rig :: struct {
	phys:   ^physics.World,
	ground: b3.Body_Id,
	body:   b3.Body_Id,
}

rig_make :: proc() -> (r: Joint_Rig) {
	r.phys = world_make()
	r.ground = box_body(r.phys.id, .Static_Body, {0, -0.5, 0}, {10, 0.5, 10})
	r.body = box_body(r.phys.id, .Dynamic_Body, {0, 2, 0}, {0.5, 0.5, 0.5})
	return
}

@(test)
test_motor_joint :: proc(t: ^testing.T) {
	r := rig_make()
	defer physics.destroy(r.phys)
	jd := b3.default_motor_joint_def()
	jd.base.body_id_a = r.ground
	jd.base.body_id_b = r.body
	jd.base.local_frame_a = {{0, 2, 0}, {0, 0, 0, 1}}
	jd.linear_hertz = 5
	jd.linear_damping_ratio = 1
	jd.max_spring_force = 1000
	j := b3.create_motor_joint(r.phys.id, &jd)
	testing.expect(t, b3.joint_is_valid(j))
	testing.expect_value(t, box3d.Joint_GetType(j), box3d.JointType.motorJoint)
	testing.expect_value(t, box3d.MotorJoint_GetLinearHertz(j), 5)
	testing.expect_value(t, box3d.MotorJoint_GetMaxSpringForce(j), 1000)
	testing.expect_value(
		t,
		transmute(b3.Transform)box3d.Joint_GetLocalFrameA(j),
		b3.Transform{{0, 2, 0}, {0, 0, 0, 1}},
	)
	testing.expect_value(t, box3d.Joint_GetBodyB(j), r.body)
}

@(test)
test_mover_joint :: proc(t: ^testing.T) {
	r := rig_make()
	defer physics.destroy(r.phys)
	jd := b3.default_mover_joint_def()
	jd.base.body_id_a = r.ground
	jd.base.body_id_b = r.body
	jd.linear_velocity = {1, 0, 0}
	jd.max_force = 50
	j := b3.create_mover_joint(r.phys.id, &jd)
	testing.expect_value(t, box3d.Joint_GetType(j), box3d.JointType.moverJoint)
	testing.expect_value(t, transmute([3]f32)box3d.MoverJoint_GetLinearVelocity(j), [3]f32{1, 0, 0})
	b3.mover_joint_set_linear_velocity(j, {0, 0, 2})
	b3.mover_joint_set_max_velocity_force(j, 75)
	testing.expect_value(t, transmute([3]f32)box3d.MoverJoint_GetLinearVelocity(j), [3]f32{0, 0, 2})
	testing.expect_value(t, box3d.MoverJoint_GetMaxVelocityForce(j), 75)
}

@(test)
test_pogo_joint :: proc(t: ^testing.T) {
	r := rig_make()
	defer physics.destroy(r.phys)
	pd := b3.default_pogo_joint_def()
	pd.base.body_id_a = r.ground
	pd.base.body_id_b = r.body
	pd.normal = {0, 1, 0}
	pd.rest_length = 1.5
	pd.hertz = 3
	pd.damping_ratio = 0.8
	pd.max_compression_force = 1000
	pd.max_tension_force = 1000
	j := b3.create_pogo_joint(r.phys.id, &pd)
	testing.expect_value(t, box3d.Joint_GetType(j), box3d.JointType.pogoJoint)
	testing.expect_value(t, box3d.PogoJoint_GetRestLength(j), 1.5)
	b3.pogo_joint_set_spring_hertz(j, 4)
	b3.pogo_joint_set_spring_damping_ratio(j, 0.5)
	b3.pogo_joint_set_max_tension_force(j, 10)
	b3.pogo_joint_set_max_compression_force(j, 2000)
	b3.pogo_joint_set_normal(j, {0, 0, 1})
	testing.expect_value(t, box3d.PogoJoint_GetSpringHertz(j), 4)
	testing.expect_value(t, box3d.PogoJoint_GetSpringDampingRatio(j), 0.5)
	testing.expect_value(t, box3d.PogoJoint_GetMaxTensionForce(j), 10)
	testing.expect_value(t, box3d.PogoJoint_GetMaxCompressionForce(j), 2000)
	testing.expect_value(t, transmute([3]f32)box3d.PogoJoint_GetNormal(j), [3]f32{0, 0, 1})
	b3.pogo_joint_set_normal(j, {0, 1, 0})
	step(r.phys.id, 30)
	testing.expect_value(t, b3.pogo_joint_get_impulse(j), box3d.PogoJoint_GetImpulse(j))
	testing.expect_value(t, b3.pogo_joint_get_current_speed(j), box3d.PogoJoint_GetCurrentSpeed(j))
	testing.expect(t, b3.pogo_joint_get_impulse(j) != 0, "the spring pushes")
}

@(test)
test_joint_get_body_a_set_local_frames_destroy_joint :: proc(t: ^testing.T) {
	r := rig_make()
	defer physics.destroy(r.phys)
	jd := b3.default_mover_joint_def()
	jd.base.body_id_a = r.ground
	jd.base.body_id_b = r.body
	j := b3.create_mover_joint(r.phys.id, &jd)
	testing.expect_value(t, b3.joint_get_body_a(j), r.ground)
	b3.joint_set_local_frame_a(j, {{1, 2, 3}, {0, 0.6, 0, 0.8}})
	b3.joint_set_local_frame_b(j, {{-1, 0, 0}, {0, 0, 0, 1}})
	fa := box3d.Joint_GetLocalFrameA(j)
	fb := box3d.Joint_GetLocalFrameB(j)
	testing.expect_value(t, transmute(b3.Transform)fa, b3.Transform{{1, 2, 3}, {0, 0.6, 0, 0.8}})
	testing.expect_value(t, transmute(b3.Transform)fb, b3.Transform{{-1, 0, 0}, {0, 0, 0, 1}})
	testing.expect(t, b3.joint_is_valid(j))
	b3.destroy_joint(j, true)
	testing.expect(t, !b3.joint_is_valid(j))
}
