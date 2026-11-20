package playground

import "unified:dmath"
import "unified:physics"

// Builds a scene's bodies and joints (the level is its static ground, already made), in a fixed order, the way the
// Box3D sample of the same name builds them, scaled to the body budget (examples/playground/README.md, Scenes).
build_scene :: proc(t: ^Tick, scene: Scene) {
	switch scene {
	case .Pyramid:
		build_pyramid(t)
	case .Dominoes:
		build_dominoes(t)
	case .Bridge:
		build_bridge(t)
	case .Driving:
		build_driving(t)
	case .Ragdolls:
		build_ragdolls(t)
	case .Bounce_House:
		build_bounce_house(t)
	case .Bullets:
		build_bullets(t)
	case .Conveyor:
		build_conveyor(t)
	case .Wind:
		build_wind(t)
	case .Sensors:
		build_sensors(t)
	case .Breakable:
		build_breakable(t)
	case .Rain: // the rain falls in by rule (rain)
	}
}

PYRAMID_ROWS :: 13 // 91 boxes
PYRAMID_HALF :: f32(0.4)

// A box pyramid of PYRAMID_ROWS rows, a hair apart so it settles without popping.
build_pyramid :: proc(t: ^Tick) {
	step := 2 * PYRAMID_HALF + 0.02
	for row in 0 ..< PYRAMID_ROWS {
		count := PYRAMID_ROWS - row
		for column in 0 ..< count {
			x := (f32(column) - f32(count - 1) / 2) * step
			y := PYRAMID_HALF + f32(row) * 2 * PYRAMID_HALF
			spawn_prop(t, {kind = .Box, size = PYRAMID_HALF, pos = {x, y, 0}})
		}
	}
}

DOMINO_COUNT :: 80
DOMINO_HALF :: [3]f32{0.08, 0.5, 0.25}
DOMINO_GAP :: f32(0.55) // between two dominoes along the spiral

// An outward spiral of DOMINO_COUNT dominoes, each facing along the spiral, and a ball rolling into the first.
build_dominoes :: proc(t: ^Tick) {
	turns: f32 = 0
	for i in 0 ..< DOMINO_COUNT {
		radius := 2 + 0.06 * f32(i)
		around := dmath.angle_vec(turns) // {cos, sin} of the angle around the centre
		facing := [2]f32{-around.y, around.x} // the spiral's tangent (x, z)
		pos := [3]f32{around.x * radius, DOMINO_HALF.y, around.y * radius}
		spawn_prop(
			t,
			{kind = .Box, size = DOMINO_HALF, pos = pos, rot = dmath.quat_yaw({facing.y, -facing.x}), friction = 0.6},
		)
		turns += DOMINO_GAP / (dmath.TAU * radius)
	}
	first := [3]f32{2, 0.3, -2.5}
	spawn_prop(t, {kind = .Sphere, size = 0.3, pos = first, velocity = {0, 0, 5}, density = 3000})
}

BRIDGE_PLANKS :: 24
BRIDGE_HALF :: [3]f32{0.25, 0.06, 1}
BRIDGE_Y :: f32(4)

// A bridge of BRIDGE_PLANKS planks on revolute joints (hinged about z), its ends on the World's anchor at the level's
// two pillars; boxes dropped on it; beside it a ball and chain of capsules on spherical joints.
build_bridge :: proc(t: ^Tick) {
	world := t.world.phys
	span := 2 * BRIDGE_HALF.x * BRIDGE_PLANKS
	left := -span / 2
	previous := physics.world_anchor(world)
	previous_point := [3]f32{left, BRIDGE_Y, 0} // in the anchor's frame: the world
	for i in 0 ..< BRIDGE_PLANKS {
		x := left + BRIDGE_HALF.x * (2 * f32(i) + 1)
		prop, _, _ := spawn_prop(t, {kind = .Box, size = BRIDGE_HALF, pos = {x, BRIDGE_Y, 0}, density = 300})
		joint_def := physics.default_revolute_joint_def()
		joint_def.base.local_frame_a.p = previous_point
		joint_def.base.local_frame_b.p = {-BRIDGE_HALF.x, 0, 0}
		physics.create_revolute_joint(world, previous, physics.link(prop.body), joint_def)
		previous, previous_point = physics.link(prop.body), {BRIDGE_HALF.x, 0, 0}
	}
	end_def := physics.default_revolute_joint_def()
	end_def.base.local_frame_a.p = previous_point
	end_def.base.local_frame_b.p = {span / 2, BRIDGE_Y, 0}
	physics.create_revolute_joint(world, previous, physics.world_anchor(world), end_def)
	for i in 0 ..< 6 {
		spawn_prop(t, {kind = i % 2 == 0 ? .Box : .Sphere, size = 0.35, pos = {f32(i) * 1.5 - 3.75, BRIDGE_Y + 2, 0}})
	}
	// the ball and chain: 12 links down from (0, 9, -5), a heavy ball at the end
	link_half := f32(0.25)
	top := [3]f32{0, 9, -5}
	above := physics.world_anchor(world)
	above_point := top
	for i in 0 ..< 12 {
		center := top - {0, link_half * (2 * f32(i) + 1), 0}
		prop, _, _ := spawn_prop(
			t,
			{kind = .Capsule, size = {0.08, link_half - 0.08, 0}, pos = center, density = 1000},
		)
		joint_def := physics.default_spherical_joint_def()
		joint_def.base.local_frame_a.p = above_point
		joint_def.base.local_frame_b.p = {0, link_half, 0}
		physics.create_spherical_joint(world, above, physics.link(prop.body), joint_def)
		above, above_point = physics.link(prop.body), {0, -link_half, 0}
	}
	ball, _, _ := spawn_prop(t, {kind = .Sphere, size = 0.8, pos = top - {0, 24 * link_half + 0.8, 0}, density = 3000})
	ball_joint := physics.default_spherical_joint_def()
	ball_joint.base.local_frame_a.p = above_point
	ball_joint.base.local_frame_b.p = {0, 0.8, 0}
	physics.create_spherical_joint(world, above, physics.link(ball.body), ball_joint)
}

// A car per slot (build_car) on the level's height field, and a stack of crates to drive into.
build_driving :: proc(t: ^Tick) {
	for i in 0 ..< MAX_CARS do build_car(t, i)
	for row in 0 ..< 4 {
		for column in 0 ..< 3 {
			spawn_prop(t, {kind = .Box, size = 0.5, pos = {f32(column) * 1.05 - 1, 0.5 + f32(row) * 1.0 + 1.5, -14}})
		}
	}
}

RAGDOLL_SCALE :: f32(1) // the ragdolls' size (the views draw their capsules at it)

// MAX_RAGDOLLS ragdolls (physics.Ragdoll, the sample's human) dropped in two rows above the level's incline, each
// turned another eighth.
build_ragdolls :: proc(t: ^Tick) {
	def := physics.RAGDOLL_DEFAULT
	def.category = CAT_PROP
	def.friction_torque = 10
	def.hertz = 0.5 // the sample's pile
	def.density = DENSITY
	def.scale = RAGDOLL_SCALE
	for &ragdoll, i in t.state.ragdolls {
		pos := [3]f32{f32(i % 4) * 1.6 - 2.4, 6 + f32(i / 4) * 2, f32(i / 4) * 1.5 - 4}
		facing := dmath.DIR8[i % 8]
		physics.ragdoll_create(t.world.phys, &ragdoll, def, pos, dmath.quat_yaw(facing), tag = RAGDOLL_TAG + u64(i))
	}
}

// Fast bodies bouncing in the level's closed room with restitution 1 and no friction: continuous collision keeps them
// in. A sphere, a capsule, a box and a cylinder at speed, and a dozen small balls.
build_bounce_house :: proc(t: ^Tick) {
	spawn_prop(
		t,
		{kind = .Sphere, size = 0.4, pos = {-2, 2, 0}, velocity = {30, 10, 17}, restitution = 1, friction = 0.01},
	)
	spawn_prop(t, {
		kind        = .Capsule,
		size        = {0.2, 0.4, 0},
		pos         = {2, 2, 0},
		velocity    = {-25, 5, 20},
		restitution = 1,
		friction    = 0.01,
	})
	spawn_prop(
		t,
		{kind = .Box, size = 0.3, pos = {0, 3, 2}, velocity = {20, -15, -30}, restitution = 1, friction = 0.01},
	)
	spawn_prop(t, {
		kind        = .Cylinder,
		size        = {0.3, 0.3, 0},
		pos         = {0, 3, -2},
		velocity    = {-18, 12, -24},
		restitution = 1,
		friction    = 0.01,
	})
	for i in 0 ..< 12 {
		around := dmath.DIR8[i % 8]
		velocity := [3]f32{around.x * 12, 4 + f32(i % 3) * 3, around.y * 12}
		spawn_prop(t, {
			kind        = .Sphere,
			size        = 0.15,
			pos         = {around.x, 1 + f32(i / 8), around.y},
			velocity    = velocity,
			restitution = 1,
			friction    = 0.01,
		})
	}
}

// A wall of crates, and the turret (a static box) the rule fires bullets from at it (rules: turret).
build_bullets :: proc(t: ^Tick) {
	for row in 0 ..< 8 {
		for column in 0 ..< 5 {
			spawn_prop(t, {kind = .Box, size = 0.3, pos = {0, 0.3 + f32(row) * 0.6, f32(column) * 0.62 - 1.24}})
		}
	}
	spawn_prop(t, {kind = .Box, size = {0.5, 0.5, 0.5}, pos = TURRET_AT, role = .Anchor, fixed = true})
}

TURRET_AT :: [3]f32{-16, 2, 0}

// Balls on the level's slope, half of them with rolling resistance (they stop; the others roll on); the crates come
// onto the belts by rule (rules: conveyor).
build_conveyor :: proc(t: ^Tick) {
	for i in 0 ..< 8 {
		rolling: f32 = i % 2 == 0 ? 0.2 : 0
		spawn_prop(t, {kind = .Sphere, size = 0.3, pos = {f32(i) * 0.8 - 2.8, 4.5, -8}, rolling = rolling})
	}
}

// Three chains of light capsules hanging from the World's anchor, and loose light bodies on the ground: the rule blows
// a turning wind through all of them (rules: wind).
build_wind :: proc(t: ^Tick) {
	world := t.world.phys
	link_half := f32(0.3)
	for chain in 0 ..< 3 {
		top := [3]f32{f32(chain) * 4 - 4, 8, -3}
		above := physics.world_anchor(world)
		above_point := top
		for i in 0 ..< 8 {
			center := top - {0, link_half * (2 * f32(i) + 1), 0}
			prop, _, _ := spawn_prop(
				t,
				{kind = .Capsule, size = {0.1, link_half - 0.1, 0}, pos = center, density = 100, no_sleep = true},
			)
			joint_def := physics.default_spherical_joint_def()
			joint_def.base.local_frame_a.p = above_point
			joint_def.base.local_frame_b.p = {0, link_half, 0}
			physics.create_spherical_joint(world, above, physics.link(prop.body), joint_def)
			above, above_point = physics.link(prop.body), {0, -link_half, 0}
		}
	}
	for i in 0 ..< 24 {
		kind := Shape(i % 4)
		size := kind == .Capsule || kind == .Cylinder ? [3]f32{0.15, 0.25, 0} : [3]f32{0.25, 0.25, 0.25}
		spawn_prop(
			t,
			{kind = kind, size = size, pos = {f32(i % 6) * 1.2 - 3, 0.5, f32(i / 6) * 1.2 + 1}, density = 50},
		)
	}
}

@(rodata)
SENSOR_AT := [MAX_SENSORS][3]f32{{-5, 1, 0}, {0, 1, 0}, {5, 1, 0}}
SENSOR_HALF :: [3]f32{1.5, 1, 1.5}

// Three sensor volumes on the ground (static sensor boxes that see props) and a grid of balls and crates raining onto
// and rolling through them; every prop here reports hits, which light it (rules: sense).
build_sensors :: proc(t: ^Tick) {
	world := t.world.phys
	for &sensor, i in t.state.sensors {
		shape_def := physics.shape_def(CAT_SENSOR, CAT_PROP)
		shape_def.is_sensor = true
		shape_def.enable_sensor_events = true
		sensor.body, sensor.shape = physics.create_box(
			world,
			physics.body_def(.Static, SENSOR_AT[i]),
			shape_def,
			SENSOR_HALF,
			u64(i),
		)
	}
	for i in 0 ..< 36 {
		x := f32(i % 9) * 1.4 - 5.6
		z := f32(i / 9) * 1.4 - 2
		kind: Shape = i % 3 == 0 ? .Box : .Sphere
		spawn_prop(t, {
			kind       = kind,
			size       = 0.3,
			pos        = {x, 4 + f32(i % 4), z},
			velocity   = {0, 0, f32(i % 5) - 2},
			hit_events = true,
		})
	}
}

WALL_COLUMNS :: 8
WALL_ROWS :: 6
WALL_HALF :: [3]f32{0.4, 0.3, 0.3}

// A wall of crates welded to their right and upper neighbours, and a chain of planks hung between the level's two
// posts on revolute joints; every joint breaks past BREAK_FORCE or BREAK_TORQUE (rules: break_joints).
build_breakable :: proc(t: ^Tick) {
	world := t.world.phys
	bodies: [WALL_ROWS][WALL_COLUMNS]physics.Body_Ref
	for row in 0 ..< WALL_ROWS {
		for column in 0 ..< WALL_COLUMNS {
			pos := [3]f32{(f32(column) - 3.5) * 2 * WALL_HALF.x, WALL_HALF.y * (2 * f32(row) + 1), 0}
			prop, _, _ := spawn_prop(t, {kind = .Box, size = WALL_HALF, pos = pos})
			bodies[row][column] = prop.body
		}
	}
	weld :: proc(world: ^physics.World, a, b: physics.Body_Ref, offset: [3]f32) {
		joint_def := physics.default_weld_joint_def()
		joint_def.base.local_frame_a.p = offset / 2
		joint_def.base.local_frame_b.p = -offset / 2
		joint_def.base.force_threshold = BREAK_FORCE
		joint_def.base.torque_threshold = BREAK_TORQUE
		physics.create_weld_joint(world, physics.link(a), physics.link(b), joint_def)
	}
	for row in 0 ..< WALL_ROWS {
		for column in 0 ..< WALL_COLUMNS {
			if column + 1 < WALL_COLUMNS do weld(world, bodies[row][column], bodies[row][column + 1], {2 * WALL_HALF.x, 0, 0})
			if row + 1 < WALL_ROWS do weld(world, bodies[row][column], bodies[row + 1][column], {0, 2 * WALL_HALF.y, 0})
		}
	}
	// the chain: 14 planks between the posts at x = ±4.2, z = -6, y = 3
	plank_half := [3]f32{0.3, 0.05, 0.3}
	left := [3]f32{-4.2, 3, -6}
	previous := physics.world_anchor(world)
	previous_point := left
	for i in 0 ..< 14 {
		prop, _, _ := spawn_prop(
			t,
			{kind = .Box, size = plank_half, pos = left + {plank_half.x * (2 * f32(i) + 1), 0, 0}, density = 300},
		)
		joint_def := physics.default_revolute_joint_def()
		joint_def.base.local_frame_a.p = previous_point
		joint_def.base.local_frame_b.p = {-plank_half.x, 0, 0}
		joint_def.base.force_threshold = BREAK_FORCE / 2
		physics.create_revolute_joint(world, previous, physics.link(prop.body), joint_def)
		previous, previous_point = physics.link(prop.body), {plank_half.x, 0, 0}
	}
	end_def := physics.default_revolute_joint_def()
	end_def.base.local_frame_a.p = previous_point
	end_def.base.local_frame_b.p = {4.2, 3, -6}
	end_def.base.force_threshold = BREAK_FORCE / 2
	physics.create_revolute_joint(world, previous, physics.world_anchor(world), end_def)
}
