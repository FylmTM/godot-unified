// src/physics/README.md, Ragdoll: the sample's human built as Box3D bodies and joints, its rest pose, its limits
// holding through a fall, and ragdolls under rollback (made, tuned, thrown and destroyed mid-run) through the real
// harness: save, restore, re-sim, a late joiner's snapshot, and the same bits on 4 workers.
package test_physics

import "core:slice"
import "core:testing"

import "unified:dmath"
import "unified:physics"
import "unified:sim"

@(test)
ragdoll_is_the_samples_human :: proc(t: ^testing.T) {
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
		if bone == .Pelvis {
			_, pelvis_joint := physics.ragdoll_joint_type(bone)
			testing.expect(t, !pelvis_joint)
			testing.expect_value(t, ragdoll.joints[bone], physics.Joint_Ref{})
			continue
		}
		joint_type, has_joint := physics.ragdoll_joint_type(bone)
		testing.expect(t, has_joint)
		testing.expect_value(t, physics.joint_type(world, ragdoll.joints[bone]), joint_type)
		if joint_type == .Revolute do revolute += 1
	}
	testing.expect_value(t, revolute, 4) // knees and elbows
	for filter in ragdoll.filters do testing.expect(t, physics.joint_valid(world, filter))
	// standing on its feet: the pelvis about a metre above `pos`, the head highest
	pelvis := physics.body_position(world, ragdoll.bones[.Pelvis])
	testing.expectf(t, near(pelvis, {1, 0.996219, 2 - 0.023868}), "pelvis at %v", pelvis)
	head := physics.body_position(world, ragdoll.bones[.Head])
	testing.expectf(t, head.y > 1.4, "head at %v", head)
	mass: f32
	for body in ragdoll.bones do mass += physics.body_mass(world, body)
	testing.expectf(t, mass > 140 && mass < 150, "the sample's human at water's density: %v kg", mass)

	// turned a quarter about +Y: the left thigh (at +x in the rest pose) goes to -z
	turned: physics.Ragdoll
	quarter := [4]f32{0, 0.70710678, 0, 0.70710678}
	physics.ragdoll_create(world, &turned, def, {5, 0, 0}, quarter)
	thigh := physics.body_position(world, turned.bones[.Left_Thigh])
	testing.expectf(t, near(thigh, {5 - 0.011177, 0.971562, -0.092175}, 1e-3), "turned thigh at %v", thigh)
	rest := physics.body_rotation(world, ragdoll.bones[.Chest])
	testing.expect(t, near4(physics.body_rotation(world, turned.bones[.Chest]), dmath.quat_mul(quarter, rest)))

	physics.ragdoll_destroy(world, &ragdoll)
	testing.expect_value(t, ragdoll, physics.Ragdoll{})
	testing.expect(t, physics.body_valid(world, physics.link(turned.bones[.Pelvis])), "the other ragdoll stays")
}

// A ragdoll dropped from a metre and a half: it lands, stays in one piece above the ground, its knees and elbows within
// their limits (with the solver's slack), and comes to rest.
@(test)
ragdoll_falls_in_one_piece :: proc(t: ^testing.T) {
	world := new_world()
	defer physics.destroy(world)
	ground(world)
	ragdoll: physics.Ragdoll
	physics.ragdoll_create(world, &ragdoll, physics.RAGDOLL_DEFAULT, {0, 1.5, 0})
	physics.body_apply_angular_impulse(world, ragdoll.bones[.Spine], {3, 0, 2})
	slack: f32 = 0.1
	for _ in 0 ..< 4 * HZ {
		physics.step(world)
		for bone in physics.Ragdoll_Bone {
			if joint_type, _ := physics.ragdoll_joint_type(bone); joint_type != .Revolute do continue
			joint := physics.Revolute_Joint_Ref{ragdoll.joints[bone]}
			angle := physics.revolute_joint_angle(world, joint)
			testing.expectf(
				t,
				angle >= physics.revolute_joint_lower_limit(world, joint) - slack &&
				angle <= physics.revolute_joint_upper_limit(world, joint) + slack,
				"%v at %v rad",
				bone,
				angle,
			)
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

// ---- ragdolls under rollback: a pile made in init, tuned, thrown, made bullets, one destroyed and made again

RAGDOLL_TICKS :: 240

Ragdolls :: struct {
	ragdolls: [3]physics.Ragdoll,
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
			physics.ragdoll_set_velocity(world, &pile[2], {4, 3, 0}) // thrown
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
	testing.expect(t, physics.body_is_bullet(world, simulation.state.ragdolls[0].bones[.Head]))
	testing.expect_value(t, physics.check_refs(world, &simulation.state), "")
}

near4 :: proc(a, b: [4]f32, tolerance: f32 = 1e-5) -> bool {
	delta := a - b
	return(
		abs(delta.x) <= tolerance &&
		abs(delta.y) <= tolerance &&
		abs(delta.z) <= tolerance &&
		abs(delta.w) <= tolerance \
	)
}
