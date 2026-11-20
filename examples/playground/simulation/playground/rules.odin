package playground

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// What can be rolled (sim.roll_*): the purpose keeps each kind of roll apart.
Roll :: enum u8 {
	Rain_X,
	Rain_Z,
	Rain_Shape,
	Turret_Aim,
	Conveyor_Shape,
}

// What the scene does before the step: Bullets' turret fires, Conveyor drops crates, Wind blows, Rain rains.
run_scene_rules :: proc(t: ^Tick) {
	since := u32(t.time - t.state.entered)
	#partial switch t.state.level.id {
	case .Bullets:
		if since % TURRET_EVERY_TICKS == TURRET_EVERY_TICKS / 2 do turret(t)
	case .Conveyor:
		if since % CONVEYOR_EVERY_TICKS == 0 do conveyor(t)
	case .Wind:
		wind(t, since)
	case .Rain:
		if since % RAIN_EVERY_TICKS == 0 do rain(t)
	}
}

// What the scene reads after the step: Sensors' sensor and hit events, Breakable's joint events; and every scene's
// bullets age.
after_step :: proc(t: ^Tick) {
	#partial switch t.state.level.id {
	case .Sensors:
		sense(t)
	case .Breakable:
		break_joints(t)
	}
	props := sim.iterate(&t.state.props)
	for prop, handle in sim.next(&props) {
		if prop.role == .Bullet && u32(t.time - prop.born) >= SHOT_TICKS do despawn_prop(t, handle)
	}
}

// Bullets: a bullet from TURRET_AT at the wall, a little higher or lower each time.
turret :: proc(t: ^Tick) {
	height := 0.4 + 4 * sim.roll_f32(t, Roll.Turret_Aim)
	target := [3]f32{0, height, 0}
	direction := dmath.normalize(target - TURRET_AT)
	fire_bullet(t, {}, TURRET_AT + direction, direction * SHOT_SPEED)
}

// Conveyor: a crate (or a ball) drops onto the first belt; past CONVEYOR_CAP the oldest goes.
conveyor :: proc(t: ^Tick) {
	if oldest, found := oldest_prop(t, .Rain); found && count_role(t, .Rain) >= CONVEYOR_CAP do despawn_prop(t, oldest)
	kind: Shape = sim.roll_below(t, 3, Roll.Conveyor_Shape) == 0 ? .Sphere : .Box
	spawn_prop(t, {kind = kind, size = 0.35, pos = {-10, 3.5, 4}, role = .Rain})
}

// Wind: the air blows at WIND_SPEED along a direction that turns once around every WIND_TURN_TICKS, on every dynamic
// prop's shape (shape_apply_wind: drag and lift on its facing area).
wind :: proc(t: ^Tick, since: u32) {
	world := t.world.phys
	turn := dmath.angle_vec(f32(since % WIND_TURN_TICKS) / WIND_TURN_TICKS)
	air := [3]f32{turn.x, 0, turn.y} * WIND_SPEED
	props := sim.iterate(&t.state.props)
	for prop in sim.next(&props) {
		if prop.role == .Anchor do continue
		physics.shape_apply_wind(world, prop.shape, air, WIND_DRAG, WIND_LIFT, 2 * WIND_SPEED)
	}
}

// Rain: a body of a rolled shape falls in from 14 m over a rolled point; past RAIN_CAP the oldest goes.
rain :: proc(t: ^Tick) {
	if oldest, found := oldest_prop(t, .Rain); found && count_role(t, .Rain) >= RAIN_CAP do despawn_prop(t, oldest)
	x := 12 * sim.roll_f32(t, Roll.Rain_X) - 6
	z := 12 * sim.roll_f32(t, Roll.Rain_Z) - 6
	kind := Shape(sim.roll_below(t, 4, Roll.Rain_Shape))
	size := kind == .Capsule || kind == .Cylinder ? [3]f32{0.25, 0.35, 0} : [3]f32{0.35, 0.35, 0.35}
	spawn_prop(t, {kind = kind, size = size, pos = {x, 14, z}, role = .Rain})
}

// How many props of `role` there are.
count_role :: proc(t: ^Tick, role: Role) -> (count: int) {
	props := sim.iterate(&t.state.props)
	for prop in sim.next(&props) do count += int(prop.role == role)
	return
}

// Sensors: each sensor begin event counts a visit (Event_Sensor_Entered); then every sensor's overlaps say which props
// are inside (Prop.inside, Sensor.inside); a hit event lights the props it names for FLASH_TICKS.
sense :: proc(t: ^Tick) {
	world := t.world.phys
	physics.world_sensor_events(world, &t.world.sensed)
	for event in t.world.sensed {
		if event.kind != .Begin || event.sensor.tag >= MAX_SENSORS do continue
		sensor := &t.state.sensors[event.sensor.tag]
		sensor.visits += 1
		at := physics.body_position(world, sensor.body)
		sim.emit(t, Event_Sensor_Entered{position = sim.Position(at), sensor = u8(event.sensor.tag)})
	}
	props := sim.iterate(&t.state.props)
	for prop in sim.next(&props) do prop.inside = 0
	for &sensor in t.state.sensors {
		physics.shape_sensor_data(world, sensor.shape, &t.world.overlaps)
		sensor.inside = u32(len(t.world.overlaps))
		for overlap in t.world.overlaps {
			if prop, _ := prop_of(t, overlap.tag); prop != nil do prop.inside += 1
		}
	}
	physics.world_contact_events(world, &t.world.contacts)
	for event in t.world.contacts {
		if event.kind != .Hit do continue
		for side in ([2]physics.Overlap{event.a, event.b}) {
			if prop, _ := prop_of(t, side.tag); prop != nil do sim.timer_start_ticks(t, &prop.flash, FLASH_TICKS)
		}
	}
}

// Breakable: every joint past its force or torque threshold this step breaks (Event_Joint_Broke where its first body
// is).
break_joints :: proc(t: ^Tick) {
	world := t.world.phys
	physics.world_joint_events(world, &t.world.joints)
	for &joint in t.world.joints {
		if !physics.joint_valid(world, joint) do continue
		at: [3]f32
		if body, alive := physics.resolve(world, physics.joint_body_a(world, joint)); alive do at = physics.body_position(world, body)
		physics.destroy_joint(world, &joint)
		sim.emit(t, Event_Joint_Broke{position = sim.Position(at)})
	}
}
