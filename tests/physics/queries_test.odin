// The mover queries, the per-body and per-shape queries, contact data, body and joint events (src/physics/SPEC.md,
// What physics covers) through physics; entity tags in every kind of result and through save/restore and a portable
// image; check_refs' orphans and broken refs; despawn and destroy_refs.
package test_physics

import "core:strings"
import "core:testing"

import "unified:physics"
import "unified:sim"

API_CAT_GROUND :: u64(1 << 0)
API_CAT_WALL :: u64(1 << 6)
API_CAT_BALL :: u64(1 << 7)
API_WALL_TAG :: u64(7)

// A ground (top at y = 0), a wall from x = 2.5 to 3.5 (tag 7, material 77) and a sensor box at x = −3.
Mover_Scene :: struct {
	world:  ^physics.World,
	ground: physics.Body_Ref,
	wall:   physics.Body_Ref,
	face:   physics.Shape_Ref, // the wall's shape
	sensor: physics.Body_Ref,
}

mover_scene :: proc() -> (scene: Mover_Scene) {
	scene.world = api_world()
	shape_def := physics.default_shape_def()
	shape_def.filter.category = API_CAT_GROUND
	scene.ground, _ = box(scene.world, {0, -0.5, 0}, {20, 0.5, 20}, .Static, 1, shape_def)
	shape_def.filter.category = API_CAT_WALL
	shape_def.base_material.user_material_id = 77
	scene.wall, scene.face = box(scene.world, {3, 2, 0}, {0.5, 2, 2}, .Static, API_WALL_TAG, shape_def)
	sensor_def := physics.default_shape_def()
	sensor_def.is_sensor = true
	scene.sensor, _ = box(scene.world, {-3, 2, 0}, {0.5, 2, 2}, .Static, 9, sensor_def)
	return
}

// A capsule mover 1.8 m tall (radius 0.4), its feet 0.1 m above its origin.
MOVER :: physics.Capsule{{0, 0.5, 0}, {0, 1.5, 0}, 0.4}

@(test)
mover_world_queries :: proc(t: ^testing.T) {
	scene := mover_scene()
	defer physics.destroy(scene.world)
	// Sweeping +x, the capsule (front at x + 0.4) meets the wall's face at 2.5: 2.1 of 5.
	fraction := physics.world_cast_mover(scene.world, {0, 0, 0}, MOVER, {5, 0, 0})
	testing.expectf(t, near_f32(fraction, 0.42, 2e-3), "fraction %v", fraction) // Box3D stops a little short
	testing.expect_value(
		t,
		physics.world_cast_mover(scene.world, {0, 0, 0}, MOVER, {5, 0, 0}, ignore = physics.link(scene.wall)),
		1,
	)
	testing.expect_value(
		t,
		physics.world_cast_mover(scene.world, {0, 0, 0}, MOVER, {5, 0, 0}, {mask = API_CAT_GROUND}),
		1,
	)
	testing.expect_value(t, physics.world_cast_mover(scene.world, {0, 0, 0}, MOVER, {-5, 0, 0}), 1) // the sensor isn't solid

	// Sunk 0.1 m into the ground and 0.1 m into the wall: a plane against each, the ground's first (body index).
	planes: [dynamic]physics.Mover_Plane
	defer delete(planes)
	append(&planes, physics.Mover_Plane{tag = 99})
	physics.world_collide_mover(scene.world, {2.2, -0.2, 0}, MOVER, &planes)
	testing.expect_value(t, len(planes), 2)
	if len(planes) == 2 {
		testing.expect(t, planes[0].body == physics.link(scene.ground) && planes[0].tag == 1)
		testing.expect(t, near(planes[0].plane.normal, {0, 1, 0}, 1e-4) && planes[0].category == API_CAT_GROUND)
		testing.expect(t, planes[1].body == physics.link(scene.wall) && planes[1].shape == scene.face)
		testing.expect(t, planes[1].tag == API_WALL_TAG && planes[1].category == API_CAT_WALL)
		testing.expect(t, near(planes[1].plane.normal, {-1, 0, 0}, 1e-4))
	}
	physics.world_collide_mover(scene.world, {2.2, -0.2, 0}, MOVER, &planes, ignore = physics.link(scene.ground))
	testing.expect(t, len(planes) == 1 && planes[0].body == physics.link(scene.wall))
	physics.world_collide_mover(scene.world, {-2.8, 1, 0}, MOVER, &planes) // inside the sensor, off the ground
	testing.expect_value(t, len(planes), 0)
}

@(test)
mover_body_queries :: proc(t: ^testing.T) {
	scene := mover_scene()
	defer physics.destroy(scene.world)
	world := scene.world
	hit, ok := physics.body_cast_ray(world, scene.wall, {0, 1, 0}, {5, 0, 0})
	testing.expect(t, ok && hit.body == physics.link(scene.wall) && hit.shape == scene.face)
	testing.expect(t, hit.tag == API_WALL_TAG && hit.category == API_CAT_WALL && hit.material == 77)
	testing.expect(t, near(hit.point, {2.5, 1, 0}) && near(hit.normal, {-1, 0, 0}) && near_f32(hit.fraction, 0.5))
	_, ok = physics.body_cast_ray(world, scene.wall, {0, 1, 0}, {5, 0, 0}, max_fraction = 0.4)
	testing.expect(t, !ok)
	_, ok = physics.body_cast_ray(
		world,
		scene.wall,
		{0, 1, 0},
		{5, 0, 0},
		pose = physics.Transform{{30, 0, 0}, {0, 0, 0, 1}},
	)
	testing.expect(t, !ok, "the body where `pose` puts it")
	_, ok = physics.body_cast_ray(world, scene.ground, {0, 1, 0}, {5, 0, 0})
	testing.expect(t, !ok, "this body only")

	ball := physics.make_proxy([][3]f32{{}}, 0.25)
	hit, ok = physics.body_cast_shape(world, scene.wall, {0, 1, 0}, ball, {5, 0, 0})
	testing.expectf(t, ok && near_f32(hit.fraction, 0.45, 2e-3) && hit.tag == API_WALL_TAG, "%v", hit)
	testing.expect(t, physics.body_overlap_shape(world, scene.wall, {2.4, 1, 0}, ball))
	testing.expect(t, !physics.body_overlap_shape(world, scene.wall, {2, 1, 0}, ball))
	point, distance := physics.body_closest_point(world, scene.wall, {0, 1, 0})
	testing.expect(t, near(point, {2.5, 1, 0}) && near_f32(distance, 2.5))

	planes: [dynamic]physics.Mover_Plane
	defer delete(planes)
	append(&planes, physics.Mover_Plane{}, physics.Mover_Plane{})
	physics.body_collide_mover(world, scene.wall, {2.2, -0.2, 0}, MOVER, &planes)
	testing.expect_value(t, len(planes), 1)
	if len(planes) == 1 do testing.expect(t, planes[0].shape == scene.face && planes[0].tag == API_WALL_TAG && near(planes[0].plane.normal, {-1, 0, 0}, 1e-4))

	hit, ok = physics.body_time_of_impact_mover(world, scene.wall, {0, 0, 0}, MOVER, {5, 0, 0})
	testing.expectf(
		t,
		ok && near_f32(hit.fraction, 0.42, 2e-3) && hit.shape == scene.face && hit.tag == API_WALL_TAG,
		"%v",
		hit,
	)
	testing.expect(t, near(hit.normal, {-1, 0, 0}, 1e-3) && hit.material == 77)
	// The wall coming 1 m closer during the sweep meets the mover earlier.
	at := physics.body_transform(world, scene.wall)
	closer := at
	closer.p.x -= 1
	moving, moving_ok := physics.body_time_of_impact_mover(
		world,
		scene.wall,
		{0, 0, 0},
		MOVER,
		{5, 0, 0},
		pose1 = at,
		pose2 = closer,
	)
	testing.expect(t, moving_ok && moving.fraction < hit.fraction)
	_, ok = physics.body_time_of_impact_mover(world, scene.wall, {0, 0, 0}, MOVER, {-5, 0, 0})
	testing.expect(t, !ok)
}

@(test)
mover_shape_queries :: proc(t: ^testing.T) {
	scene := mover_scene()
	defer physics.destroy(scene.world)
	world := scene.world
	hit, ok := physics.shape_ray_cast(world, scene.face, {0, 1, 0}, {5, 0, 0})
	testing.expect(t, ok && hit.shape == scene.face && hit.tag == API_WALL_TAG && hit.material == 77)
	testing.expect(t, near(hit.point, {2.5, 1, 0}) && near_f32(hit.fraction, 0.5))
	_, ok = physics.shape_ray_cast(world, scene.face, {0, 1, 0}, {-5, 0, 0})
	testing.expect(t, !ok)
	testing.expect(t, near(physics.shape_closest_point(world, scene.face, {0, 1, 0}), {2.5, 1, 0}))

	// On a mesh, the material is the hit triangle's.
	mesh := physics.create_grid_mesh(4, 4, 1, material_count = 2)
	defer physics.destroy_mesh(mesh)
	materials := [2]physics.Surface_Material {
		{friction = 0.5, user_material_id = 10},
		{friction = 0.5, user_material_id = 11},
	}
	mesh_def := physics.default_shape_def()
	mesh_def.materials = &materials[0]
	mesh_def.material_count = 2
	mesh_def.base_material.user_material_id = 1
	body_def := physics.default_body_def()
	body_def.position = {0, 10, 0}
	floor_body := physics.create_body(world, body_def)
	floor := physics.create_mesh_shape(world, floor_body, mesh_def, mesh)
	seen: bit_set[0 ..< 2]
	for x in ([]f32{-1.5, -0.5, 0.5, 1.5}) {
		for z in ([]f32{-1.5, -0.5, 0.5, 1.5}) {
			mesh_hit, mesh_ok := physics.shape_ray_cast(world, floor, {x + 0.1, 11, z + 0.2}, {0, -2, 0})
			testing.expect(t, mesh_ok && (mesh_hit.material == 10 || mesh_hit.material == 11))
			if mesh_ok && mesh_hit.material >= 10 do seen += {int(mesh_hit.material - 10)}
		}
	}
	testing.expect_value(t, seen, bit_set[0 ..< 2]{0, 1})
}

@(test)
contact_data_sorted_and_replaced :: proc(t: ^testing.T) {
	world := api_world()
	defer physics.destroy(world)
	ground, _ := box(world, {0, -0.5, 0}, {20, 0.5, 20}, .Static, 1)
	near, near_shape := box(world, {0, 0.5, 0}, {0.5, 0.5, 0.5}, .Dynamic, tag = 2)
	far, _ := box(world, {5, 0.5, 0}, {0.5, 0.5, 0.5}, .Dynamic, tag = 3)
	steps(world, 10)
	contacts: [dynamic]physics.Contact_Data
	defer delete(contacts)
	append(&contacts, physics.Contact_Data{}, physics.Contact_Data{}, physics.Contact_Data{})
	physics.body_contact_data(world, ground, &contacts)
	testing.expect_value(t, len(contacts), 2)
	if len(contacts) == 2 {
		for contact, i in contacts {
			box := contact.a.body == physics.link(ground) ? contact.b : contact.a
			testing.expect(t, (contact.a.body == physics.link(ground)) != (contact.b.body == physics.link(ground)))
			testing.expect_value(t, box.tag, u64(2 + i)) // by body index: near, then far
			testing.expect(t, contact.manifold.point_count == 4 && abs(contact.manifold.normal.y) > 0.99)
			testing.expect(t, contact.manifold.points[0].total_normal_impulse > 0)
		}
		testing.expect(t, (contacts[1].a.body == physics.link(far)) || (contacts[1].b.body == physics.link(far)))
	}
	physics.shape_contact_data(world, near_shape, &contacts)
	testing.expect_value(t, len(contacts), 1)
	if len(contacts) == 1 {
		pair := [2]physics.Overlap{contacts[0].a, contacts[0].b}
		testing.expect(t, pair[0].shape == near_shape || pair[1].shape == near_shape)
		testing.expect(t, pair[0].tag + pair[1].tag == 3) // the ground (1) and near (2)
	}
	physics.body_set_transform(world, near, {0, 10, 0}, {0, 0, 0, 1})
	steps(world, 1)
	physics.body_contact_data(world, near, &contacts)
	testing.expect_value(t, len(contacts), 0)
}

@(test)
body_and_joint_events :: proc(t: ^testing.T) {
	world := api_world()
	defer physics.destroy(world)
	ground, _ := box(world, {0, -0.5, 0}, {20, 0.5, 20}, .Static, 1)
	falling, _ := box(world, {0, 0.6, 0}, {0.5, 0.5, 0.5}, .Dynamic, tag = 2)
	hanging, _ := box(world, {5, 3, 0}, {0.5, 0.5, 0.5}, .Dynamic, tag = 3)
	weld_def := physics.default_weld_joint_def()
	weld_def.base.local_frame_a = {{5, 3.5, 0}, {0, 0, 0, 1}} // the ground's origin is 0.5 m down
	weld_def.base.force_threshold = 1 // its 1 kg holds it up with ~10 N
	weld := physics.create_weld_joint(world, physics.link(ground), physics.link(hanging), weld_def)

	moves: [dynamic]physics.Body_Move_Event
	defer delete(moves)
	joints: [dynamic]physics.Joint_Ref
	defer delete(joints)
	append(&moves, physics.Body_Move_Event{tag = 99})
	append(&joints, physics.Joint_Ref{index1 = 99})
	steps(world, 1)
	physics.world_body_events(world, &moves)
	testing.expect_value(t, len(moves), 2)
	tags: u64
	for move in moves {
		tags += move.tag
		ref, ok := physics.resolve(world, move.body)
		testing.expect(t, ok && move.transform == physics.body_transform(world, ref) && !move.fell_asleep)
	}
	testing.expect_value(t, tags, 5)
	physics.world_joint_events(world, &joints)
	testing.expect(t, len(joints) == 1 && joints[0] == weld.joint)

	physics.joint_set_force_threshold(world, weld, 1000)
	fell_asleep := false
	for _ in 0 ..< 600 {
		steps(world, 1)
		physics.world_joint_events(world, &joints)
		testing.expect_value(t, len(joints), 0)
		physics.world_body_events(world, &moves)
		for move in moves do fell_asleep ||= move.fell_asleep && move.body == physics.link(falling)
		if fell_asleep do break
	}
	testing.expect(t, fell_asleep, "the box settles and reports it")
	steps(world, 1)
	physics.world_body_events(world, &moves)
	for move in moves do testing.expect(t, move.body != physics.link(falling), "a sleeping body doesn't move")
}

// What the tag test doesn't cover: a ray skips its `ignore` body and filters by category, misses, and every collecting
// proc replaces its `out` (a stale result can't carry over into another tick).
@(test)
queries_filter_ignore_and_replace :: proc(t: ^testing.T) {
	world := physics.create({tick_hz = HZ, hit_event_threshold = 1})
	defer physics.destroy(world)
	ground(world)
	faller, _ := box(world, {0, 2, 0}, {0.5, 0.5, 0.5}, .Dynamic, category = CAT_BOX, hit = true)
	side_box, _ := box(world, {3, 0.5, 0}, {0.5, 0.5, 0.5}, .Dynamic, category = CAT_BOX)
	// A ray from inside a body skips it when told to, and finds the ground under it.
	hit, ok := physics.world_cast_ray_closest(world, {0, 2, 0}, {0, -5, 0}, {}, physics.link(faller))
	testing.expect(t, ok && abs(hit.point.y) < 1e-4 && hit.normal.y > 0.99)
	hit, ok = physics.world_cast_ray_closest(world, {0, 2, 0}, {0, -5, 0})
	testing.expect(t, ok && hit.body == physics.link(faller))
	hit, ok = physics.world_cast_ray_closest(world, {0, 5, 0}, {0, -8, 0}, {mask = CAT_STATIC})
	testing.expect(t, ok && abs(hit.point.y) < 1e-4)
	_, ok = physics.world_cast_ray_closest(world, {0, 10, 0}, {0, 1, 0})
	testing.expect(t, !ok)
	got: [dynamic]physics.Overlap
	defer delete(got)
	append(&got, physics.Overlap{body = physics.link(faller)}, physics.Overlap{body = physics.link(faller)})
	physics.world_overlap_aabb(world, {-5, 0.2, -1}, {5, 3, 1}, &got, {mask = CAT_BOX})
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 do testing.expect(t, got[0].body.index1 < got[1].body.index1 && got[1].body == physics.link(side_box))
	physics.world_overlap_aabb(world, {10, 10, 10}, {11, 11, 11}, &got)
	testing.expect_value(t, len(got), 0)
	// The landing's hit events, then none at rest, and never the stale entry `events` held.
	events: [dynamic]physics.Contact_Event
	defer delete(events)
	append(&events, physics.Contact_Event{kind = .Hit, speed = -1})
	hits := 0
	for _ in 0 ..< 64 {
		steps(world, 1)
		physics.world_contact_events(world, &events)
		for event in events {
			testing.expect(t, event.speed >= 0)
			hits += int(event.kind == .Hit)
		}
	}
	testing.expect(t, hits >= 1)
	steps(world, 1)
	physics.world_contact_events(world, &events)
	testing.expect_value(t, len(events), 0)
}

// ---- tags

Tag_Block :: struct {
	balls:  [2]physics.Body_Ref,
	sensor: physics.Body_Ref,
}

// A static ground (tag 1, made before extra), two balls (tags 21 and 22) falling onto it with hit and contact events,
// and a sensor (tag 30) the first falls through.
tag_world :: proc(block: ^Tag_Block) -> (world: ^physics.World, extra: sim.Extra) {
	world = api_world(nil, 0.5)
	ground_def := physics.default_shape_def()
	ground_def.enable_contact_events = true
	ground_def.filter.category = API_CAT_GROUND
	box(world, {0, -0.5, 0}, {20, 0.5, 20}, .Static, 1, ground_def)
	extra = physics.extra(world, Tag_Block)
	ball_def := physics.default_shape_def()
	ball_def.enable_hit_events = true
	ball_def.enable_contact_events = true
	ball_def.enable_sensor_events = true
	ball_def.filter.category = API_CAT_BALL
	for x, i in ([2]f32{0, 5}) {
		block.balls[i], _ = box(world, {x, 3, 0}, {0.25, 0.25, 0.25}, .Dynamic, u64(21 + i), ball_def)
	}
	sensor_def := physics.default_shape_def()
	sensor_def.is_sensor = true
	sensor_def.enable_sensor_events = true
	block.sensor, _ = box(world, {0, 1.5, 0}, {1, 0.25, 1}, .Static, 30, sensor_def)
	return
}

@(test)
tags_in_every_result :: proc(t: ^testing.T) {
	block: Tag_Block
	world, _ := tag_world(&block)
	defer physics.destroy(world)
	testing.expect_value(t, physics.body_tag(world, block.balls[1]), 22)

	hit, ok := physics.world_cast_ray_closest(world, {5, 10, 0}, {0, -20, 0})
	testing.expect(t, ok && hit.tag == 22 && hit.category == API_CAT_BALL)
	hits: [dynamic]physics.Hit
	defer delete(hits)
	physics.world_cast_ray(world, {0, 10, 0}, {0, -20, 0}, &hits)
	testing.expect(t, len(hits) == 2 && hits[0].tag == 21 && hits[1].tag == 1, "sensors skipped, ball then ground")
	ball := physics.make_proxy([][3]f32{{}}, 0.1)
	physics.world_cast_shape(world, {5, 10, 0}, ball, {0, -20, 0}, &hits)
	testing.expect(t, len(hits) == 2 && hits[0].tag == 22 && hits[1].tag == 1)
	overlaps: [dynamic]physics.Overlap
	defer delete(overlaps)
	physics.world_overlap_aabb(world, {-1, 2, -1}, {6, 4, 1}, &overlaps)
	testing.expect(t, len(overlaps) == 2 && overlaps[0].tag == 21 && overlaps[1].tag == 22)
	physics.world_overlap_shape(world, {5, 3, 0}, ball, &overlaps)
	testing.expect(t, len(overlaps) == 1 && overlaps[0].tag == 22 && overlaps[0].category == API_CAT_BALL)
	planes: [dynamic]physics.Mover_Plane
	defer delete(planes)
	physics.world_collide_mover(world, {5.5, 2, 0}, MOVER, &planes) // its side 0.15 m into the ball
	testing.expect(t, len(planes) >= 1 && planes[0].tag == 22)

	contacts: [dynamic]physics.Contact_Event
	defer delete(contacts)
	sensors: [dynamic]physics.Sensor_Event
	defer delete(sensors)
	inside: [dynamic]physics.Overlap
	defer delete(inside)
	begins, hit_counts: [2]int // per ball
	sensor_begins: int
	inside_tag: u64
	for _ in 0 ..< 90 {
		steps(world, 1)
		physics.world_contact_events(world, &contacts)
		for event in contacts {
			testing.expect(t, event.a.tag == 1 || event.b.tag == 1, "a ball and the ground")
			ball_tag := event.a.tag == 1 ? event.b.tag : event.a.tag
			testing.expect(t, ball_tag == 21 || ball_tag == 22)
			if ball_tag != 21 && ball_tag != 22 do continue
			#partial switch event.kind {
			case .Begin:
				begins[ball_tag - 21] += 1
			case .Hit:
				hit_counts[ball_tag - 21] += 1
			}
		}
		physics.world_sensor_events(world, &sensors)
		for event in sensors {
			testing.expect(
				t,
				event.sensor.tag == 30 && event.visitor.tag == 21 && event.visitor.category == API_CAT_BALL,
			)
			if event.kind == .Begin do sensor_begins += 1
		}
		physics.shape_sensor_data(world, physics_shape_of(world, block.sensor), &inside)
		for visitor in inside do inside_tag = visitor.tag
	}
	testing.expect_value(t, begins, [2]int{1, 1})
	testing.expectf(t, hit_counts[0] >= 1 && hit_counts[1] >= 1, "hits %v", hit_counts)
	testing.expect_value(t, sensor_begins, 1)
	testing.expect_value(t, inside_tag, 21)
}

// A body's one shape.
physics_shape_of :: proc(world: ^physics.World, body: physics.Body_Ref) -> physics.Shape_Ref {
	shapes: [dynamic]physics.Shape_Ref
	defer delete(shapes)
	physics.body_shapes(world, body, &shapes)
	return shapes[0]
}

@(test)
tags_roll_back_and_cross_in_an_image :: proc(t: ^testing.T) {
	block: Tag_Block
	world, extra := tag_world(&block)
	defer physics.destroy(world)
	extra.save(extra.data, 0)
	deep := api_deep_hash(&extra)
	physics.body_set_tag(world, block.balls[0], 99)
	testing.expect_value(t, physics.body_tag(world, block.balls[0]), 99)
	testing.expect(t, api_deep_hash(&extra) != deep, "a tag is part of the deep hash")
	hit, _ := physics.world_cast_ray_closest(world, {0, 10, 0}, {0, -20, 0})
	testing.expect_value(t, hit.tag, 99)
	testing.expect(t, extra.restore(extra.data, 0))
	testing.expect_value(t, physics.body_tag(world, block.balls[0]), 21)
	testing.expect_value(t, api_deep_hash(&extra), deep)

	// A late joiner: a world with only the ground (made before extra) loads the image and has every tag.
	late := api_world(nil, 0.5)
	defer physics.destroy(late)
	ground_def := physics.default_shape_def()
	ground_def.enable_contact_events = true
	ground_def.filter.category = API_CAT_GROUND
	box(late, {0, -0.5, 0}, {20, 0.5, 20}, .Static, 1, ground_def)
	late_extra := physics.extra(late, Tag_Block)
	testing.expect(t, late_extra.load(late_extra.data, extra.image(extra.data, 0)))
	testing.expect_value(t, physics.check_refs(late, &block), "")
	testing.expect_value(t, physics.body_tag(late, block.balls[0]), 21)
	testing.expect_value(t, physics.body_tag(late, block.balls[1]), 22)
	testing.expect_value(t, physics.body_tag(late, block.sensor), 30)
	late_hit, ok := physics.world_cast_ray_closest(late, {5, 10, 0}, {0, -20, 0})
	testing.expect(t, ok && late_hit.tag == 22)
	testing.expect_value(t, api_deep_hash(&late_extra), deep)
}

// ---- check_refs, despawn, destroy_refs

Item :: struct {
	body:  physics.Body_Ref,
	shape: physics.Shape_Ref,
	hinge: physics.Revolute_Joint_Ref,
}

Item_Block :: struct {
	items: sim.Table(Item, 4),
	loose: Item,
}

// An item: a ball hinged to the ground.
item_make :: proc(world: ^physics.World, ground: physics.Body_Ref, item: ^Item, x: f32, tag: u64) {
	item.body, item.shape = box(world, {x, 1, 0}, {0.25, 0.25, 0.25}, .Dynamic, tag = tag)
	hinge_def := physics.default_revolute_joint_def()
	item.hinge = physics.create_revolute_joint(world, physics.link(ground), physics.link(item.body), hinge_def)
}

@(test)
check_refs_despawn_and_destroy_refs :: proc(t: ^testing.T) {
	block: Item_Block
	world := api_world()
	defer physics.destroy(world)
	ground, _ := box(world, {0, -0.5, 0}, {20, 0.5, 20}, .Static)
	_ = physics.extra(world, Item_Block)
	testing.expect_value(t, physics.check_refs(world, &block), "")
	first, first_handle, _ := sim.spawn(&block.items)
	item_make(world, ground, first, 0, sim.handle_key(first_handle))
	second, _, _ := sim.spawn(&block.items)
	item_make(world, ground, second, 2, 2)
	item_make(world, ground, &block.loose, 4, 3)
	testing.expect_value(t, physics.check_refs(world, &block), "")

	// An orphan: a body made after extra that no ref in the block owns.
	orphan, _ := box(world, {8, 1, 0}, {0.25, 0.25, 0.25}, .Dynamic, tag = 44)
	problem := physics.check_refs(world, &block)
	testing.expectf(t, strings.contains(problem, "orphan") && strings.contains(problem, "tag 44"), "%q", problem)
	physics.destroy_body(world, &orphan)
	testing.expect_value(t, physics.check_refs(world, &block), "")

	// A broken ref: the block still names a body destroyed elsewhere.
	copy_of_second := second.body
	physics.destroy_body(world, &copy_of_second)
	problem = physics.check_refs(world, &block)
	testing.expectf(t, strings.contains(problem, "no live body"), "%q", problem)
	second.body = {}
	problem = physics.check_refs(world, &block)
	testing.expectf(t, strings.contains(problem, "no live"), "its shape and hinge went with it: %q", problem)
	second^ = {}
	testing.expect_value(t, physics.check_refs(world, &block), "")

	// despawn frees the item's joint and body, zeroes its refs, and frees the slot.
	held := first^
	testing.expect(t, physics.despawn(world, &block.items, first_handle))
	testing.expect(t, sim.get(&block.items, first_handle) == nil)
	testing.expect(t, !physics.body_valid(world, physics.link(held.body)))
	testing.expect(t, !physics.joint_valid(world, held.hinge))
	testing.expect(t, !physics.shape_valid(world, held.shape))
	testing.expect_value(t, physics.check_refs(world, &block), "")

	// destroy_refs does the same for any plain value.
	loose := block.loose
	physics.destroy_refs(world, &block.loose)
	testing.expect(t, block.loose == Item{})
	testing.expect(t, !physics.body_valid(world, physics.link(loose.body)) && !physics.joint_valid(world, loose.hinge))
	testing.expect_value(t, physics.check_refs(world, &block), "")
}
