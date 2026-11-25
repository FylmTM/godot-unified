package playground

import "unified:physics"
import "unified:sim"

// How a prop is made (spawn_prop): its body's type and pose, its shape's surface and events.
Prop_Def :: struct {
	kind:        Shape,
	size:        [3]f32, // Prop.size's meaning
	pos:         [3]f32,
	rot:         [4]f32, // zero: identity
	velocity:    [3]f32,
	role:        Role,
	fixed:       bool, // a static body (the turret) rather than a dynamic one
	density:     f32, // 0: DENSITY
	friction:    f32, // 0: 0.6
	restitution: f32,
	rolling:     f32, // rolling resistance
	owner:       sim.Player,
	bullet:      bool,
	hit_events:  bool,
	no_sleep:    bool,
}

// Makes a prop: a table item, then its body tagged with the item's key and its one shape. Not ok when the table is
// full (MAX_PROPS): nothing was made.
spawn_prop :: proc(t: ^Tick, def: Prop_Def) -> (prop: ^Prop, handle: sim.Handle(Prop), ok: bool) {
	prop, handle = sim.spawn(&t.state.props) or_return
	world := t.world.phys
	rot := def.rot == {} ? [4]f32{0, 0, 0, 1} : def.rot
	body_def := physics.body_def(def.fixed ? .Static : .Dynamic, def.pos, rot)
	body_def.linear_velocity = def.velocity
	body_def.is_bullet = def.bullet
	body_def.enable_sleep = !def.no_sleep
	shape_def := physics.shape_def(CAT_PROP)
	shape_def.density = def.density == 0 ? DENSITY : def.density
	shape_def.base_material.friction = def.friction == 0 ? 0.6 : def.friction
	shape_def.base_material.restitution = def.restitution
	shape_def.base_material.rolling_resistance = def.rolling
	shape_def.enable_hit_events = def.hit_events
	shape_def.enable_sensor_events = true // the Sensors scene's volumes see every prop
	body := physics.create_body(world, body_def, sim.handle_key(handle))
	shape: physics.Shape_Ref
	switch def.kind {
	case .Box:
		shape = physics.create_box_shape(world, body, shape_def, def.size)
	case .Sphere:
		shape = physics.create_sphere_shape(world, body, shape_def, {radius = def.size.x})
	case .Capsule:
		shape = physics.create_capsule_shape(
			world,
			body,
			shape_def,
			{{0, -def.size.y, 0}, {0, def.size.y, 0}, def.size.x},
		)
	case .Cylinder:
		scale := [3]f32{def.size.x, def.size.y, def.size.x}
		shape = physics.create_transformed_hull_shape(
			world,
			body,
			shape_def,
			t.world.cylinder,
			{q = {0, 0, 0, 1}},
			scale,
		)
	}
	prop^ = {
		body  = body,
		shape = shape,
		size  = def.size,
		owner = def.owner,
		born  = t.time,
		kind  = def.kind,
		role  = def.role,
	}
	return prop, handle, true
}

// Frees a prop and its body; everyone who held it lets go first (their grab joints go with the body).
despawn_prop :: proc(t: ^Tick, handle: sim.Handle(Prop)) {
	prop := sim.get(&t.state.props, handle)
	if prop == nil do return
	release_holders(t, physics.link(prop.body))
	physics.despawn(t.world.phys, &t.state.props, handle)
}

// The oldest prop of `role` (made by `owner`, unless {}: anyone's), to make room: not found when there is none.
oldest_prop :: proc(t: ^Tick, role: Role, owner := sim.Player{}) -> (oldest: sim.Handle(Prop), found: bool) {
	born: sim.Game_Time
	props := sim.iterate(&t.state.props)
	for prop, handle in sim.next(&props) {
		if prop.role != role || (owner != {} && prop.owner != owner) do continue
		if !found || prop.born < born {
			oldest, born, found = handle, prop.born, true
		}
	}
	return
}

// The prop a body is, from its tag (a query's or an event's), if it is one.
prop_of :: proc(t: ^Tick, tag: u64) -> (prop: ^Prop, handle: sim.Handle(Prop)) {
	handle = sim.handle_of_key(Prop, tag)
	return sim.get(&t.state.props, handle), handle
}

// Props below KILL_Y go; a car that fell goes back to its start.
remove_fallen :: proc(t: ^Tick) {
	world := t.world.phys
	props := sim.iterate(&t.state.props)
	for prop, handle in sim.next(&props) {
		if physics.body_position(world, prop.body).y < KILL_Y do despawn_prop(t, handle)
	}
	for &ragdoll in t.state.ragdolls {
		if ragdoll.bones[.Pelvis] == {} do continue
		if physics.body_position(world, ragdoll.bones[.Pelvis]).y < KILL_Y {
			for bone in ragdoll.bones do release_body_holders(t, {bone})
			physics.ragdoll_destroy(world, &ragdoll)
		}
	}
	for &car, i in t.state.cars {
		if car.chassis == {} do continue
		if physics.body_position(world, car.chassis).y < KILL_Y do reset_car(t, i)
	}
}

// Whoever holds one of `bodies` lets go (before they are destroyed).
release_body_holders :: proc(t: ^Tick, bodies: []physics.Body_Ref) {
	for body in bodies {
		release_holders(t, physics.link(body))
	}
}
