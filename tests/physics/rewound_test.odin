// The rewound ray (world_cast_ray_closest_rewound): the same answer as a plain cast on the world with every moving
// body moved back, through the filter rules, sensors, `ignore`, a mesh and ties; the bodies it names by the body
// table's generations through a restore and a late joiner's load. And Box3D's plane solver (solve_planes,
// clip_vector) on a mover's planes.
package test_physics

import "core:log"
import "core:testing"

import "unified:physics"
import "unified:sim"

// A moving body of the rewind scene: where it is, how it moves, what it is.
@(private = "file")
Mover :: struct {
	pos, velocity: [3]f32,
	kind:          enum {
		Runner, // a kinematic capsule with a head sphere
		Box, // a kinematic box
		Ball, // a dynamic sphere
		Sensor, // a kinematic sensor box: never hit
		Picky, // a kinematic box whose shapes accept CAT_BOX queries only
		Mesh, // a kinematic box mesh
	},
}

@(private = "file")
MOVERS := [?]Mover {
	{{1, 0, 0}, {6, 0, 0}, .Runner},
	{{-2, 0.9, 1}, {0, 0, -5}, .Box},
	{{0, 2.5, 0.5}, {-4, 3, 0}, .Ball},
	{{3, 1, 0}, {-6, 0, 0}, .Sensor},
	{{-3.5, 1, -1}, {2, 0, 0}, .Picky},
	{{2.5, 1, 1.5}, {-3, 0, 1}, .Mesh},
}

// The scene: a ground, a wall at z = −6 and MOVERS, each `moved_back` by its velocity times `rewind_s` and still, or
// where it is with its velocity. Bodies are made in one order, so the two worlds' indices match.
@(private = "file")
rewind_scene :: proc(
	moved_back: bool,
	rewind_s: f32,
) -> (
	world: ^physics.World,
	bodies: [len(MOVERS)]physics.Body_Ref,
	mesh: ^physics.Mesh_Data, // the caller frees it after the world
) {
	mesh = physics.create_box_mesh({}, {0.4, 0.8, 0.4})
	world = api_world({0, 0, 0})
	box(world, {0, -0.5, 0}, {20, 0.5, 20})
	box(world, {0, 1, -6}, {6, 1, 0.2})
	for mover, i in MOVERS {
		pos := mover.pos - mover.velocity * rewind_s if moved_back else mover.pos
		type: physics.Body_Type = .Dynamic if mover.kind == .Ball else .Kinematic
		def := physics.body_def(type, pos)
		def.enable_sleep = false
		bodies[i] = physics.create_body(world, def, u64(100 + i))
		shape_def := physics.shape_def(CAT_BOX)
		switch mover.kind {
		case .Runner:
			physics.create_capsule_shape(world, bodies[i], shape_def, {{0, 0.4, 0}, {0, 1.4, 0}, 0.35})
			physics.create_sphere_shape(world, bodies[i], shape_def, {{0, 1.75, 0}, 0.2})
		case .Box:
			physics.create_box_shape(world, bodies[i], physics.shape_def(CAT_PLATFORM), {0.3, 0.9, 0.3})
		case .Ball:
			physics.create_sphere_shape(world, bodies[i], shape_def, {{}, 0.3})
		case .Sensor:
			shape_def.is_sensor = true
			physics.create_box_shape(world, bodies[i], shape_def, {0.5, 1, 0.5})
		case .Picky:
			physics.create_box_shape(world, bodies[i], physics.shape_def(CAT_BOX, CAT_BOX), {0.4, 1, 0.4})
		case .Mesh:
			physics.create_mesh_shape(world, bodies[i], shape_def, mesh)
		}
		if !moved_back do physics.body_set_linear_velocity(world, bodies[i], mover.velocity)
	}
	return
}

// Whether two hits are the same hit: the same body and shape, the point, normal and fraction within rounding (the
// rewound cast moves the ray, the plain one the body).
@(private = "file")
same_hit :: proc(a, b: physics.Hit) -> bool {
	return(
		a.body == b.body &&
		a.shape == b.shape &&
		a.tag == b.tag &&
		a.category == b.category &&
		near(a.point, b.point, 2e-4) &&
		near(a.normal, b.normal, 1e-3) &&
		near_f32(a.fraction, b.fraction, 1e-4) \
	)
}

@(test)
rewound_ray_is_the_world_moved_back :: proc(t: ^testing.T) {
	filters := [?]physics.Filter{{}, {mask = CAT_BOX}, {category = CAT_CHARACTER}}
	hits_on: [len(MOVERS)]int
	mismatches, rays := 0, 0
	for rewind_s in ([?]f32{0.03, 0.1}) {
		live, bodies, live_mesh := rewind_scene(false, rewind_s)
		defer physics.destroy_mesh(live_mesh)
		defer physics.destroy(live)
		back, _, back_mesh := rewind_scene(true, rewind_s)
		defer physics.destroy_mesh(back_mesh)
		defer physics.destroy(back)
		for filter in filters {
			for ignore in ([?]physics.Body_Link{{}, physics.link(bodies[0])}) {
				for i in 0 ..< 600 {
					// From a shooter in front, across the movers to the wall; then from above, down onto them.
					origin := [3]f32{0.13, 1.6, 8}
					target := [3]f32{-4.37 + f32(i % 30) * 0.29, 0.07 + f32(i / 30) * 0.13, 0}
					if i >= 300 {
						origin = {-4.37 + f32(i % 30) * 0.29, 6, -1.93 + f32((i - 300) / 30) * 0.31}
						target = origin - {0, 6.5, 0}
					}
					translation := (target - origin) * 1.7
					got, got_ok := physics.world_cast_ray_closest_rewound(
						live,
						origin,
						translation,
						rewind_s,
						filter,
						ignore,
					)
					want, want_ok := physics.world_cast_ray_closest(back, origin, translation, filter, ignore)
					rays += 1
					if got_ok != want_ok || (got_ok && !same_hit(got, want)) {
						if mismatches == 0 {
							log.errorf(
								"ray %v (rewind %v, filter %v): %v %v, moved back %v %v",
								i,
								rewind_s,
								filter,
								got_ok,
								got,
								want_ok,
								want,
							)
						}
						mismatches += 1
					}
					for body, k in bodies do hits_on[k] += int(got_ok && got.body == physics.link(body))
				}
			}
		}
	}
	testing.expectf(t, mismatches == 0, "%v of %v rays differ from the world moved back", mismatches, rays)
	testing.expectf(
		t,
		hits_on[0] > 0 && hits_on[1] > 0 && hits_on[2] > 0 && hits_on[4] > 0 && hits_on[5] > 0,
		"every solid mover is hit: %v",
		hits_on,
	)
	testing.expect_value(t, hits_on[3], 0) // the sensor
}

// No rewind (0, less, not finite) is the plain cast, and a moving body is found where it was, not where it is.
@(test)
rewound_ray_without_rewind_and_on_a_runner :: proc(t: ^testing.T) {
	world, bodies, mesh := rewind_scene(false, 0)
	defer physics.destroy_mesh(mesh)
	defer physics.destroy(world)
	origin, translation := [3]f32{0, 1.75, 8}, [3]f32{0, 0, -20} // at head height, through x = 0
	plain, plain_ok := physics.world_cast_ray_closest(world, origin, translation)
	nan, inf := transmute(f32)u32(0x7FC0_0000), transmute(f32)u32(0x7F80_0000)
	for rewind_s in ([?]f32{0, -1, nan, inf, -inf}) {
		hit, ok := physics.world_cast_ray_closest_rewound(world, origin, translation, rewind_s)
		testing.expect(t, ok == plain_ok && hit == plain, "no rewind: the plain cast")
	}
	testing.expect(t, plain_ok && plain.body != physics.link(bodies[0]), "the runner is at x = 1 now")
	// 1/6 s ago the runner (6 m/s along +x) was at x = 0: the ray at head height meets its head sphere there.
	hit, ok := physics.world_cast_ray_closest_rewound(world, origin, translation, 1.0 / 6)
	testing.expect(t, ok && hit.body == physics.link(bodies[0]) && hit.tag == 100)
	testing.expectf(t, near(hit.point, {0, 1.75, 0.2}, 1e-3), "on the head where it was: %v", hit.point)
}

// Hits at the same fraction go to the lower body index, whether moving or still: two equal boxes in one place.
@(test)
rewound_ray_ties_go_to_the_lower_body :: proc(t: ^testing.T) {
	// 0.25 s at 4 m/s along +z: a moving box at z = 1 was at z = 0, exactly where the still one is.
	Order :: enum {
		Moving_First,
		Still_First,
		Both_Moving,
	}
	for order in Order {
		world := api_world({0, 0, 0})
		defer physics.destroy(world)
		bodies: [2]physics.Body_Ref
		for i in 0 ..< 2 {
			moving := order == .Both_Moving || (order == .Moving_First) == (i == 0)
			def := physics.body_def(.Kinematic, {0, 1, 1} if moving else {0, 1, 0})
			bodies[i], _ = physics.create_box(world, def, physics.shape_def(CAT_BOX), {0.5, 0.5, 0.5}, u64(i + 1))
			if moving do physics.body_set_linear_velocity(world, bodies[i], {0, 0, 4})
		}
		hit, ok := physics.world_cast_ray_closest_rewound(world, {0, 1, 5}, {0, 0, -10}, 0.25)
		testing.expectf(t, ok && hit.body == physics.link(bodies[0]), "%v: the lower body: %v", order, hit.body)
		testing.expectf(t, ok && hit.fraction == 0.45, "%v: at the face z = 0.5: %v", order, hit.fraction)
	}
}

Rewind_Block :: struct {
	movers:   [3]physics.Body_Ref,
	pooled:   physics.Body_Ref, // disabled at the save, enabled after the load
	filtered: physics.Body_Ref, // its shape in no category until after the load
	bare:     physics.Body_Ref, // no shape until after the load
	shape:    physics.Shape_Ref, // filtered's
}

// The body table's generations come back with a restore (a body destroyed and its index reused after the save), and a
// late joiner's load rebuilds them: the rewound ray finds the same moving body in both.
@(test)
rewound_ray_after_a_restore_and_a_load :: proc(t: ^testing.T) {
	make_world :: proc(block: ^Rewind_Block, with_movers: bool) -> (^physics.World, sim.Extra) {
		world := api_world({0, 0, 0})
		box(world, {0, -0.5, 0}, {20, 0.5, 20})
		extra := physics.extra(world, Rewind_Block)
		if with_movers {
			for i in 0 ..< 3 {
				def := physics.body_def(.Kinematic, {f32(i) * 2 - 2, 1, 0})
				block.movers[i], _ = physics.create_box(
					world,
					def,
					physics.shape_def(CAT_BOX),
					{0.4, 1, 0.4},
					u64(10 + i),
				)
				physics.body_set_linear_velocity(world, block.movers[i], {0, 0, 4})
			}
		}
		return world, extra
	}
	block: Rewind_Block
	world, extra := make_world(&block, true)
	defer physics.destroy(world)
	ray :: proc(world: ^physics.World) -> (physics.Hit, bool) {
		// 0.25 s ago the middle mover (at x = 0, 4 m/s along +z) was 1 m back, at z = −1: a ray along x there meets it.
		return physics.world_cast_ray_closest_rewound(world, {0, 1, 5}, {0, 0, -10}, 0.25, {mask = CAT_BOX})
	}
	before, before_ok := ray(world)
	testing.expect(t, before_ok && before.body == physics.link(block.movers[1]))
	extra.save(extra.data, 0)
	physics.destroy_body(world, &block.movers[1])
	reused := physics.create_body(world, physics.body_def(.Kinematic, {9, 1, 9}), 11)
	testing.expect_value(t, reused.index1, before.body.index1) // the index is reused, a new generation
	physics.destroy_body(world, &reused)
	testing.expect(t, extra.restore(extra.data, 0))
	after, after_ok := ray(world)
	testing.expect(t, after_ok && same_hit(after, before), "the restored body is rewound again")

	late_block: Rewind_Block
	late, late_extra := make_world(&late_block, false)
	defer physics.destroy(late)
	testing.expect(t, late_extra.load(late_extra.data, extra.image(extra.data, 0, true)))
	loaded, loaded_ok := ray(late)
	testing.expect(t, loaded_ok && same_hit(loaded, before), "a loaded world rewinds its moving bodies")
}

// A late joiner names every live body as its peers do, whether a query could find it at the load or not: a disabled
// body, one whose shape is in no category and one with no shape, each made a moving target after the load, are
// rewound in the loaded world as in the one it came from.
@(test)
rewound_ray_names_bodies_a_load_cannot_see :: proc(t: ^testing.T) {
	block: Rewind_Block
	world := api_world({0, 0, 0})
	defer physics.destroy(world)
	box(world, {0, -0.5, 0}, {20, 0.5, 20})
	extra := physics.extra(world, Rewind_Block)
	kinematic :: proc(x: f32) -> physics.Body_Def {return physics.body_def(.Kinematic, {x, 1, 0})}
	block.pooled, _ = physics.create_box(world, kinematic(4), physics.shape_def(CAT_BOX), {0.4, 1, 0.4}, 20)
	physics.body_disable(world, block.pooled)
	block.filtered, block.shape = physics.create_box(world, kinematic(6), physics.shape_def(0), {0.4, 1, 0.4}, 21)
	block.bare = physics.create_body(world, kinematic(8), 22)
	extra.save(extra.data, 0)

	late_block := block
	late := api_world({0, 0, 0})
	defer physics.destroy(late)
	box(late, {0, -0.5, 0}, {20, 0.5, 20})
	late_extra := physics.extra(late, Rewind_Block)
	testing.expect(t, late_extra.load(late_extra.data, extra.image(extra.data, 0, true)))
	testing.expect_value(t, physics.check_refs(late, &late_block), "")

	for target in ([?]^physics.World{world, late}) {
		physics.body_enable(target, block.pooled)
		physics.shape_set_filter(target, block.shape, {category = CAT_BOX, mask = max(u64)})
		physics.create_box_shape(target, block.bare, physics.shape_def(CAT_BOX), {0.4, 1, 0.4})
		for body in ([?]physics.Body_Ref{block.pooled, block.filtered, block.bare}) {
			physics.body_set_linear_velocity(target, body, {0, 0, 4})
		}
	}
	for x, k in ([?]f32{4, 6, 8}) {
		// 0.25 s ago each was 1 m back, at z = -1: the ray along -z there meets its face at z = -0.6.
		want, want_ok := physics.world_cast_ray_closest_rewound(world, {x, 1, 5}, {0, 0, -10}, 0.25)
		got, got_ok := physics.world_cast_ray_closest_rewound(late, {x, 1, 5}, {0, 0, -10}, 0.25)
		testing.expectf(
			t,
			want_ok && want.tag == u64(20 + k) && near_f32(want.fraction, 0.56, 1e-4),
			"%v: %v",
			x,
			want,
		)
		testing.expectf(t, got_ok == want_ok && same_hit(got, want), "x = %v: loaded %v, original %v", x, got, want)
	}
}

// Box3D's plane solver on a mover's planes: sunk into the ground and the wall, it is pushed out of both and keeps its
// move along the wall; clip_vector removes what goes into them, unless a plane doesn't clip.
@(test)
solve_planes_and_clip_vector :: proc(t: ^testing.T) {
	scene := mover_scene()
	defer physics.destroy(scene.world)
	found: [dynamic]physics.Mover_Plane
	defer delete(found)
	physics.world_collide_mover(scene.world, {2.2, -0.2, 0}, MOVER, &found) // 0.1 m into the ground and the wall
	testing.expect_value(t, len(found), 2)
	if len(found) != 2 do return
	planes: [2]physics.Collision_Plane
	for mover_plane, i in found do planes[i] = {
		plane         = mover_plane.plane,
		push_limit    = max(f32),
		clip_velocity = true,
	}
	result := physics.solve_planes({1, 0, 0.5}, planes[:])
	testing.expectf(
		t,
		near(result.delta, {-0.1, 0.1, 0.5}, 0.02),
		"pushed out of both, along the wall: %v",
		result.delta,
	)
	testing.expect(t, result.iteration_count >= 1)
	testing.expectf(t, planes[0].push > 0 && planes[1].push > 0, "both pushed: %v %v", planes[0].push, planes[1].push)
	clipped := physics.clip_vector({3, -2, 1}, planes[:])
	testing.expectf(t, near(clipped, {0, 0, 1}, 1e-4), "clipped against both: %v", clipped)
	planes[1].clip_velocity = false // the wall
	clipped = physics.clip_vector({3, -2, 1}, planes[:])
	testing.expectf(t, near(clipped, {3, 0, 1}, 1e-4), "clipped against the ground only: %v", clipped)
	testing.expect_value(t, physics.clip_vector({3, -2, 1}, nil), [3]f32{3, -2, 1})
}
