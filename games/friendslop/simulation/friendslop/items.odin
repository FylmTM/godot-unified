package friendslop

import "unified:physics"

// Creates an item's dynamic body at its level placement (a sphere or a box, its density set from the item's mass),
// tagged with its index, with hit events on and sensor events on (plates and locks see it).
create_item_body :: proc(world: ^World, index: int) -> physics.Body_Ref {
	def := &world.items[index]
	spec := &ITEM_SPECS[def.kind]
	body_def := physics.body_def(.Dynamic, def.pos, def.rot)
	shape_def := physics.shape_def(CAT_ITEM)
	shape_def.base_material.friction = spec.friction
	shape_def.base_material.restitution = spec.restitution
	shape_def.enable_hit_events = true
	shape_def.enable_sensor_events = true
	if spec.half == {} {
		shape_def.density = physics.sphere_density(spec.mass, spec.radius)
		body, _ := physics.create_sphere(world.phys, body_def, shape_def, spec.radius, u64(index))
		return body
	}
	shape_def.density = physics.box_density(spec.mass, spec.half)
	body, _ := physics.create_box(world.phys, body_def, shape_def, spec.half, u64(index))
	return body
}

// The offset of an item's grab point `point` in the item's local frame: the centre, or past either end along x.
grab_point_offset :: proc(kind: Item_Kind, point: int) -> [3]f32 {
	spec := &ITEM_SPECS[kind]
	if spec.grab_points < 2 do return {}
	x := spec.half.x + HANDLE_OUTSET
	return {point == 0 ? -x : x, 0, 0}
}

// Puts an item back where the level placed it, at rest and let go of, no longer anybody's throw.
send_item_home :: proc(t: ^Tick, index: int) {
	item := &t.state.items[index]
	for holder in item.holders {
		if holder != {} do drop(t, holder)
	}
	physics.body_teleport(t.world.phys, item.body, t.world.items[index].pos, t.world.items[index].rot)
	item.thrown_ticks = 0
	item.thrown_by = {}
}

// Items that fell below KILL_Y go home.
return_fallen_items :: proc(t: ^Tick) {
	for i in 0 ..< t.world.item_count {
		item := &t.state.items[i]
		if item.alive && physics.body_position(t.world.phys, item.body).y < KILL_Y do send_item_home(t, i)
	}
}

// Counts down the thrown items' tags.
age_throws :: proc(t: ^Tick) {
	for i in 0 ..< t.world.item_count {
		if t.state.items[i].thrown_ticks > 0 do t.state.items[i].thrown_ticks -= 1
	}
}
