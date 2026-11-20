// src/physics/README.md, Ragdoll: the sample's human built as Box3D bodies and joints (facing +Z, its left at +X), its
// limits, springs and frictions as the table says, the springs holding the pose it was made in, its limits and
// filters holding through a fall, its setters, a posed and a scaled one, and ragdolls under rollback (made, tuned,
// thrown and destroyed mid-run) through the real harness: save, restore, re-sim, a late joiner's snapshot, and the same
// bits on 4 workers.
package test_physics

import "core:slice"
import "core:testing"

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// The sample's numbers the tests hold the ragdoll to (shared/human.c).
@(private = "file")
DEG :: f32(0.017453292519943295)
@(private = "file")
KNEE_LIMIT :: 30 * DEG
@(private = "file")
ELBOW_LIMIT :: 35 * DEG
@(private = "file")
SHOULDER_CONE :: 45 * DEG

@(private = "file")
conjugate :: proc(quat: [4]f32) -> [4]f32 {
	return {-quat.x, -quat.y, -quat.z, quat.w}
}

// A spherical joint's frame B relative to its frame A, from its bodies as they are (what its spring targets).
@(private = "file")
relative_rotation :: proc(world: ^physics.World, joint: physics.Joint_Ref) -> [4]f32 {
	a, _ := physics.resolve(world, physics.joint_body_a(world, joint))
	b, _ := physics.resolve(world, physics.joint_body_b(world, joint))
	frame_a := dmath.quat_mul(physics.body_rotation(world, a), physics.joint_local_frame_a(world, joint).q)
	frame_b := dmath.quat_mul(physics.body_rotation(world, b), physics.joint_local_frame_b(world, joint).q)
	return dmath.quat_mul(conjugate(frame_a), frame_b)
}

// Two unit quaternions are the same rotation within `tolerance` (q and -q are).
@(private = "file")
same_rotation :: proc(a, b: [4]f32, tolerance: f32 = 1e-3) -> bool {
	return 1 - abs(a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w) <= tolerance
}

@(test)
ragdoll_is_the_samples_human_facing_plus_z :: proc(t: ^testing.T) {
	world := new_world()
	defer physics.destroy(world)
	ground(world)
	ragdoll: physics.Ragdoll
	def := physics.RAGDOLL_DEFAULT
	def.material = 9
	physics.ragdoll_create(world, &ragdoll, def, {1, 0, 2}, tag = 77)
	revolute := 0
	for bone in physics.Ragdoll_Bone {
		body := ragdoll.bones[bone]
		testing.expect_value(t, physics.body_tag(world, body), 77)
		testing.expect_value(t, physics.body_type(world, body), physics.Body_Type.Dynamic)
		_, capsule_count := physics.ragdoll_capsules(bone)
		testing.expect_value(t, physics.body_shape_count(world, body), capsule_count)
		joint_type, has_joint := physics.ragdoll_joint_type(bone)
		if !has_joint {
			testing.expect_value(t, bone, physics.Ragdoll_Bone.Pelvis)
			testing.expect_value(t, ragdoll.joints[bone], physics.Joint_Ref{})
			continue
		}
		testing.expect_value(t, physics.joint_type(world, ragdoll.joints[bone]), joint_type)
		if joint_type == .Revolute do revolute += 1
	}
	testing.expect_value(t, revolute, 4) // knees and elbows
	for filter in ragdoll.filters do testing.expect(t, physics.joint_valid(world, filter))

	// standing on its feet at (1, 0, 2): the pelvis about a metre up, the head highest, facing +Z with its left at +X
	pelvis := physics.body_position(world, ragdoll.bones[.Pelvis])
	testing.expectf(t, near(pelvis, {1, 0.996219, 2 + 0.023868}), "pelvis at %v", pelvis)
	testing.expectf(t, physics.body_position(world, ragdoll.bones[.Head]).y > 1.4, "the head on top")
	for side in ([2][2]physics.Ragdoll_Bone{{.Left_Thigh, .Left_Upper_Arm}, {.Right_Thigh, .Right_Upper_Arm}}) {
		sign: f32 = side[0] == .Left_Thigh ? 1 : -1
		for bone in side {
			x := physics.body_position(world, ragdoll.bones[bone]).x - 1
			testing.expectf(t, x * sign > 0.05, "%v at x %v", bone, x)
		}
	}
	for calf in ([2]physics.Ragdoll_Bone{.Left_Calf, .Right_Calf}) {
		// the calf's origin is the knee: its ankle is the shin's far end, the foot points from there
		capsules, _ := physics.ragdoll_capsules(calf)
		shin, foot := capsules[0], capsules[1]
		ankle := dmath.length3(shin.center1) > dmath.length3(shin.center2) ? shin.center1 : shin.center2
		toward := physics.body_world_vector(world, ragdoll.bones[calf], (foot.center1 + foot.center2) / 2 - ankle)
		testing.expectf(t, toward.z > 0.04 && abs(toward.x) < toward.z, "%v's foot points %v", calf, toward)
	}
	mass: f32
	for body in ragdoll.bones do mass += physics.body_mass(world, body)
	testing.expectf(t, mass > 140 && mass < 150, "the sample's human at water's density: %v kg", mass)

	// the table's limits and frictions, and springs holding the pose it was made in
	for knee in ([2]physics.Ragdoll_Bone{.Left_Calf, .Right_Calf}) {
		joint := physics.Revolute_Joint_Ref{ragdoll.joints[knee]}
		testing.expect(t, near_f32(physics.revolute_joint_lower_limit(world, joint), -KNEE_LIMIT))
		testing.expect(t, near_f32(physics.revolute_joint_upper_limit(world, joint), KNEE_LIMIT))
		testing.expect(t, near_f32(physics.revolute_joint_max_motor_torque(world, joint), 5))
		testing.expect(
			t,
			near_f32(physics.revolute_joint_target_angle(world, joint), physics.revolute_joint_angle(world, joint)),
		)
	}
	for elbow in ([2]physics.Ragdoll_Bone{.Left_Forearm, .Right_Forearm}) {
		joint := physics.Revolute_Joint_Ref{ragdoll.joints[elbow]}
		testing.expect(t, near_f32(physics.revolute_joint_upper_limit(world, joint), ELBOW_LIMIT))
		testing.expect(t, near_f32(physics.revolute_joint_max_motor_torque(world, joint), 0.06 * 5))
	}
	for shoulder in ([2]physics.Ragdoll_Bone{.Left_Upper_Arm, .Right_Upper_Arm}) {
		joint := physics.Spherical_Joint_Ref{ragdoll.joints[shoulder]}
		testing.expect(t, near_f32(physics.spherical_joint_cone_limit(world, joint), SHOULDER_CONE))
		testing.expect(t, near_f32(physics.spherical_joint_max_motor_torque(world, joint), 0.8 * 5))
	}
	for bone in physics.Ragdoll_Bone {
		if joint_type, _ := physics.ragdoll_joint_type(bone); joint_type != .Spherical do continue
		joint := physics.Spherical_Joint_Ref{ragdoll.joints[bone]}
		testing.expect(t, physics.spherical_joint_is_spring_enabled(world, joint))
		target := physics.spherical_joint_target_rotation(world, joint)
		testing.expectf(
			t,
			same_rotation(target, relative_rotation(world, joint)),
			"%v's spring targets its made pose",
			bone,
		)
	}

	// turned a quarter about +Y: facing +X, its left thigh (at +X unturned) goes to -Z
	turned: physics.Ragdoll
	quarter := [4]f32{0, 0.70710678, 0, 0.70710678}
	physics.ragdoll_create(world, &turned, def, {5, 0, 0}, quarter)
	thigh := physics.body_position(world, turned.bones[.Left_Thigh])
	testing.expectf(t, near(thigh, {5 + 0.011177, 0.971562, -0.092175}, 1e-3), "turned thigh at %v", thigh)
	rest := physics.body_rotation(world, ragdoll.bones[.Chest])
	testing.expect(
		t,
		same_rotation(physics.body_rotation(world, turned.bones[.Chest]), dmath.quat_mul(quarter, rest), 1e-6),
	)

	physics.ragdoll_destroy(world, &ragdoll)
	testing.expect_value(t, ragdoll, physics.Ragdoll{})
	testing.expect(t, physics.body_valid(world, physics.link(turned.bones[.Pelvis])), "the other ragdoll stays")
}

// Weightless, its limbs knocked about, a sprung ragdoll comes back to the pose it was made in.
@(test)
ragdoll_springs_hold_the_made_pose :: proc(t: ^testing.T) {
	world := physics.create({tick_hz = HZ, gravity = [3]f32{}})
	defer physics.destroy(world)
	ragdoll: physics.Ragdoll
	def := physics.RAGDOLL_DEFAULT
	def.hertz, def.damping_ratio, def.friction_torque = 4, 1, 0
	physics.ragdoll_create(world, &ragdoll, def, {0, 0, 0})
	targets: [physics.Ragdoll_Bone][4]f32
	angles: [physics.Ragdoll_Bone]f32
	for bone in physics.Ragdoll_Bone {
		joint_type, has_joint := physics.ragdoll_joint_type(bone)
		if !has_joint do continue
		if joint_type == .Revolute {
			angles[bone] = physics.revolute_joint_angle(world, {ragdoll.joints[bone]}) // as made
		} else {
			targets[bone] = relative_rotation(world, ragdoll.joints[bone])
		}
	}
	physics.body_apply_angular_impulse(world, ragdoll.bones[.Left_Forearm], {1.5, 1.5, 1.5})
	physics.body_apply_angular_impulse(world, ragdoll.bones[.Right_Calf], {0, 0.5, 0.5})
	physics.body_apply_angular_impulse(world, ragdoll.bones[.Head], {0.2, 0.2, 0})
	steps(world, HZ / 4)
	moved := abs(physics.revolute_joint_angle(world, {ragdoll.joints[.Left_Forearm]}) - angles[.Left_Forearm])
	testing.expectf(t, moved > 0.05, "the knock moved the elbow (%v rad)", moved)
	steps(world, 4 * HZ)
	for bone in physics.Ragdoll_Bone {
		joint_type, has_joint := physics.ragdoll_joint_type(bone)
		if !has_joint do continue
		if joint_type == .Revolute {
			angle := physics.revolute_joint_angle(world, {ragdoll.joints[bone]})
			testing.expectf(
				t,
				near_f32(angle, angles[bone], 0.02),
				"%v back at %v rad (made at %v)",
				bone,
				angle,
				angles[bone],
			)
		} else {
			testing.expectf(
				t,
				same_rotation(relative_rotation(world, ragdoll.joints[bone]), targets[bone], 1e-3),
				"%v back in its pose",
				bone,
			)
		}
	}
}

// A ragdoll dropped from a metre and a half: it lands, stays in one piece above the ground, its knees and elbows within
// the table's limits (with the solver's slack), its filtered pairs never touching, and comes to rest.
@(test)
ragdoll_falls_in_one_piece :: proc(t: ^testing.T) {
	world := new_world()
	defer physics.destroy(world)
	ground(world)
	ragdoll: physics.Ragdoll
	physics.ragdoll_create(world, &ragdoll, physics.RAGDOLL_DEFAULT, {0, 1.5, 0})
	physics.body_apply_angular_impulse(world, ragdoll.bones[.Spine], {3, 0, 2})
	filtered := [5][2]physics.Ragdoll_Bone {
		{.Left_Thigh, .Right_Thigh},
		{.Head, .Left_Upper_Arm},
		{.Head, .Right_Upper_Arm},
		{.Spine, .Left_Thigh},
		{.Spine, .Right_Thigh},
	}
	contacts := make([dynamic]physics.Contact_Data, context.temp_allocator)
	slack: f32 = 0.1
	for _ in 0 ..< 4 * HZ {
		physics.step(world)
		for bone in ([4]physics.Ragdoll_Bone{.Left_Calf, .Right_Calf, .Left_Forearm, .Right_Forearm}) {
			limit := bone == .Left_Calf || bone == .Right_Calf ? KNEE_LIMIT : ELBOW_LIMIT
			angle := physics.revolute_joint_angle(world, {ragdoll.joints[bone]})
			testing.expectf(t, abs(angle) <= limit + slack, "%v at %v rad", bone, angle)
		}
		for pair in filtered {
			physics.body_contact_data(world, ragdoll.bones[pair[0]], &contacts)
			other := physics.link(ragdoll.bones[pair[1]])
			for contact in contacts {
				testing.expectf(
					t,
					contact.a.body != other && contact.b.body != other,
					"%v touched %v",
					pair[0],
					pair[1],
				)
			}
		}
	}
	pelvis := physics.body_position(world, ragdoll.bones[.Pelvis])
	for body in ragdoll.bones {
		pos := physics.body_position(world, body)
		testing.expectf(t, pos.y > 0 && pos.y < 1, "a bone lying on the ground: %v", pos)
		testing.expectf(t, dmath.dist_sq3(pos, pelvis) < 1, "a bone near the pelvis: %v vs %v", pos, pelvis)
		testing.expectf(t, dmath.length3(physics.body_linear_velocity(world, body)) < 0.5, "at rest")
	}
}

// Every setter, read back; a zero ragdoll and one partly destroyed are skipped, not read out of bounds.
@(test)
ragdoll_setters :: proc(t: ^testing.T) {
	world := new_world()
	defer physics.destroy(world)
	ragdoll: physics.Ragdoll
	physics.ragdoll_create(world, &ragdoll, physics.RAGDOLL_DEFAULT, {0, 3, 0})
	physics.ragdoll_set_friction_torque(world, &ragdoll, 20)
	testing.expect(t, near_f32(physics.spherical_joint_max_motor_torque(world, {ragdoll.joints[.Left_Upper_Arm]}), 16))
	testing.expect(t, near_f32(physics.revolute_joint_max_motor_torque(world, {ragdoll.joints[.Left_Calf]}), 20))
	physics.ragdoll_set_spring_hertz(world, &ragdoll, 0)
	testing.expect(t, !physics.spherical_joint_is_spring_enabled(world, {ragdoll.joints[.Spine]}))
	testing.expect(t, !physics.revolute_joint_is_spring_enabled(world, {ragdoll.joints[.Right_Forearm]}))
	physics.ragdoll_set_spring_hertz(world, &ragdoll, 2)
	testing.expect(t, physics.spherical_joint_is_spring_enabled(world, {ragdoll.joints[.Spine]}))
	testing.expect(t, near_f32(physics.revolute_joint_spring_hertz(world, {ragdoll.joints[.Right_Forearm]}), 2))
	physics.ragdoll_set_spring_damping_ratio(world, &ragdoll, 1.5)
	testing.expect(t, near_f32(physics.spherical_joint_spring_damping_ratio(world, {ragdoll.joints[.Head]}), 1.5))
	testing.expect(t, near_f32(physics.revolute_joint_spring_damping_ratio(world, {ragdoll.joints[.Left_Calf]}), 1.5))
	physics.ragdoll_set_bullet(world, &ragdoll, true)
	for body in ragdoll.bones do testing.expect(t, physics.body_is_bullet(world, body))

	// as one rigid body: v + ω × (centre − the pelvis's centre), and ω
	linear, angular := [3]f32{2, 1, 0}, [3]f32{0, 3, 0}
	physics.ragdoll_set_velocity(world, &ragdoll, linear, angular)
	pivot := physics.body_world_center(world, ragdoll.bones[.Pelvis])
	for body in ragdoll.bones {
		offset := physics.body_world_center(world, body) - pivot
		want := linear + [3]f32{3 * offset.z, 0, -3 * offset.x}
		testing.expectf(
			t,
			near(physics.body_linear_velocity(world, body), want),
			"%v vs %v",
			physics.body_linear_velocity(world, body),
			want,
		)
		testing.expect(t, near(physics.body_angular_velocity(world, body), angular))
	}

	nothing: physics.Ragdoll
	physics.ragdoll_set_friction_torque(world, &nothing, 1)
	physics.ragdoll_set_spring_hertz(world, &nothing, 1)
	physics.ragdoll_set_spring_damping_ratio(world, &nothing, 1)
	physics.ragdoll_set_velocity(world, &nothing, {1, 0, 0})
	physics.ragdoll_set_bullet(world, &nothing, true)
	physics.destroy_body(world, &ragdoll.bones[.Left_Forearm]) // its elbow goes with it
	physics.ragdoll_set_friction_torque(world, &ragdoll, 3)
	physics.ragdoll_set_spring_hertz(world, &ragdoll, 1)
	physics.ragdoll_set_velocity(world, &ragdoll, {0, 0, 1})
	physics.ragdoll_set_bullet(world, &ragdoll, false)
	testing.expect(t, near(physics.body_linear_velocity(world, ragdoll.bones[.Head]), {0, 0, 1}))
}

// Made in a pose of the game's (the left elbow bent 20° more than the rest pose): the bodies are where the pose puts
// them and the elbow's spring holds the bend. Made at half size: half the height and radii, an eighth of the mass.
@(test)
ragdoll_posed_and_scaled :: proc(t: ^testing.T) {
	world := new_world()
	defer physics.destroy(world)
	rest: physics.Ragdoll
	physics.ragdoll_create(world, &rest, physics.RAGDOLL_DEFAULT, {0, 0, 0})
	elbow := physics.Revolute_Joint_Ref{rest.joints[.Left_Forearm]}
	upper_arm := rest.bones[.Left_Upper_Arm]
	frame := physics.joint_local_frame_a(world, elbow)
	anchor := physics.body_world_point(world, upper_arm, frame.p)
	axis := dmath.quat_rotate(dmath.quat_mul(physics.body_rotation(world, upper_arm), frame.q), {0, 0, 1})
	sin_half, cos_half := f32(0.17364818), f32(0.98480775) // 10°: a 20° turn
	bend := [4]f32{axis.x * sin_half, axis.y * sin_half, axis.z * sin_half, cos_half}
	pose := physics.ragdoll_rest_pose({0, 0, 0})
	forearm := pose[.Left_Forearm]
	pose[.Left_Forearm] = {anchor + dmath.quat_rotate(bend, forearm.p - anchor), dmath.quat_mul(bend, forearm.q)}
	rest_angle := physics.revolute_joint_target_angle(world, elbow)

	posed: physics.Ragdoll
	physics.ragdoll_create(world, &posed, physics.RAGDOLL_DEFAULT, {}, pose = pose)
	for bone in physics.Ragdoll_Bone {
		testing.expect(t, near(physics.body_position(world, posed.bones[bone]), pose[bone].p))
	}
	posed_angle := physics.revolute_joint_target_angle(world, {posed.joints[.Left_Forearm]})
	testing.expectf(
		t,
		near_f32(abs(posed_angle - rest_angle), 20 * DEG, 1e-3),
		"bent 20°: %v vs %v",
		posed_angle,
		rest_angle,
	)

	half: physics.Ragdoll
	def := physics.RAGDOLL_DEFAULT
	def.scale = 0.5
	physics.ragdoll_create(world, &half, def, {4, 0, 0})
	testing.expect(t, near_f32(physics.body_position(world, half.bones[.Pelvis]).y, 0.996219 / 2))
	shapes := make([dynamic]physics.Shape_Ref, context.temp_allocator)
	physics.body_shapes(world, half.bones[.Head], &shapes)
	full, _ := physics.ragdoll_capsules(.Head)
	testing.expect(t, near_f32(physics.shape_capsule(world, shapes[0]).radius, full[0].radius / 2))
	full_mass, half_mass: f32
	for bone in physics.Ragdoll_Bone {
		full_mass += physics.body_mass(world, rest.bones[bone])
		half_mass += physics.body_mass(world, half.bones[bone])
	}
	testing.expectf(
		t,
		near_f32(half_mass, full_mass / 8, 0.01 * full_mass),
		"%v kg at half size, %v at full",
		half_mass,
		full_mass,
	)
}

// ---- ragdolls under rollback: a pile made in init, tuned, thrown, made bullets, one destroyed and made again

RAGDOLL_TICKS :: 240

Ragdolls :: struct {
	ragdolls: [3]physics.Ragdoll,
	thrown:   f32, // pile[2]'s pelvis velocity along x the tick after it was thrown
	_pad:     [4]u8,
	players:  sim.Players(u32, sim.No_Profile, sim.No_Input, 1),
}

Ragdolls_World :: struct {
	phys: ^physics.World,
}

Ragdolls_Game :: sim.Game(
	Ragdolls,
	sim.No_Input,
	Ragdolls_World,
	Library_Events,
	sim.No_Commands,
	sim.No_Setup,
	sim.No_Profile,
	1,
)
Ragdolls_Tick :: sim.Tick(Ragdolls_Game)

RAGDOLLS := Ragdolls_Game {
	name = "ragdolls",
	version = "1",
	tick_hz = HZ,
	world_create = proc(
		seed: u64,
		_: []sim.Level_File,
		_: sim.No_Setup,
	) -> ^Ragdolls_World {return ragdolls_world_create(1)},
	world_destroy = proc(ragdolls_world: ^Ragdolls_World) {
		physics.destroy(ragdolls_world.phys)
		free(ragdolls_world)
	},
	extra = proc(ragdolls_world: ^Ragdolls_World) -> sim.Extra {return physics.extra(ragdolls_world.phys, Ragdolls)},
	init = proc(t: ^Ragdolls_Tick) {
		for &ragdoll, i in t.state.ragdolls {
			physics.ragdoll_create(
				t.world.phys,
				&ragdoll,
				physics.RAGDOLL_DEFAULT,
				{0.3 * f32(i), 1 + 1.2 * f32(i), 0},
				tag = u64(i),
			)
		}
	},
	tick = proc(t: ^Ragdolls_Tick) {
		world := t.world.phys
		pile := &t.state.ragdolls
		switch t.number {
		case 20:
			physics.ragdoll_set_friction_torque(world, &pile[0], 20)
			physics.ragdoll_set_spring_hertz(world, &pile[1], 0) // limp
		case 40:
			physics.ragdoll_set_spring_damping_ratio(world, &pile[2], 2)
			physics.ragdoll_set_velocity(world, &pile[2], {4, 3, 0}, {0, 2, 0}) // thrown, spinning
		case 41:
			t.state.thrown = physics.body_linear_velocity(world, pile[2].bones[.Pelvis]).x
		case 60:
			physics.ragdoll_set_bullet(world, &pile[0], true)
		case 90:
			physics.ragdoll_destroy(world, &pile[1])
		case 120:
			quarter := [4]f32{0, 0.70710678, 0, 0.70710678}
			physics.ragdoll_create(world, &pile[1], physics.RAGDOLL_DEFAULT, {-1, 2, 1}, quarter, tag = 1)
		}
		physics.step(world)
	},
}

ragdolls_world_create :: proc(workers: i32) -> ^Ragdolls_World {
	ragdolls_world := new(Ragdolls_World)
	ragdolls_world.phys = physics.create({tick_hz = HZ, workers = workers})
	ground(ragdolls_world.phys)
	return ragdolls_world
}

ragdolls_inputs :: proc(tick: u32) -> sim.Inputs(Ragdolls_Game) {
	return {}
}

// The pile sync-tested (a rollback every tick, check_refs after each restore, a late joiner's snapshot resumed) on 1
// and on 4 workers: the same checksums on every tick.
@(test)
ragdolls_synctest :: proc(t: ^testing.T) {
	one_worker := synctest_and_resume(t, &RAGDOLLS, 1, RAGDOLL_TICKS, ragdolls_inputs, after = ragdolls_did_their_job)
	on_4 := RAGDOLLS
	on_4.world_create = proc(
		seed: u64,
		_: []sim.Level_File,
		_: sim.No_Setup,
	) -> ^Ragdolls_World {return ragdolls_world_create(4)}
	four_workers := synctest_and_resume(t, &on_4, 1, RAGDOLL_TICKS, ragdolls_inputs)
	testing.expect(t, slice.equal(four_workers, one_worker), "the pile on 4 workers: checksums differ from 1 worker's")
}

@(private = "file")
ragdolls_did_their_job :: proc(t: ^testing.T, simulation: ^sim.Sim(Ragdolls_Game)) {
	world := simulation.world.phys
	for &ragdoll in simulation.state.ragdolls {
		for body in ragdoll.bones do testing.expect(t, physics.body_valid(world, physics.link(body)))
	}
	testing.expectf(t, simulation.state.thrown > 2, "pile[2] thrown toward +x: %v m/s", simulation.state.thrown)
	testing.expect(t, physics.body_is_bullet(world, simulation.state.ragdolls[0].bones[.Head]))
	testing.expect_value(t, physics.check_refs(world, &simulation.state), "")
}
