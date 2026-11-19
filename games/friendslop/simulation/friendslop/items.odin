package friendslop

import "unified:dmath"
import "unified:physics"
import "unified:sim"

// Creates an item's dynamic body at its level placement (a sphere or a box, its density set from the item's mass),
// tagged with its index, with hit events on and sensor events on (plates and locks see it).
create_item_body :: proc(t: ^Tick, index: int) -> physics.Body_Ref {
	def := &places(t).items[index]
	spec := &ITEM_SPECS[def.kind]
	body_def := physics.body_def(.Dynamic, def.pos, def.rot)
	shape_def := physics.shape_def(CAT_ITEM)
	shape_def.base_material.friction = spec.friction
	shape_def.base_material.restitution = spec.restitution
	shape_def.enable_hit_events = true
	shape_def.enable_sensor_events = true
	if spec.half == {} {
		shape_def.density = physics.sphere_density(spec.mass, spec.radius)
		body, _ := physics.create_sphere(t.world.phys, body_def, shape_def, spec.radius, u64(index))
		return body
	}
	shape_def.density = physics.box_density(spec.mass, spec.half)
	body, _ := physics.create_box(t.world.phys, body_def, shape_def, spec.half, u64(index))
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
	physics.body_teleport(t.world.phys, item.body, places(t).items[index].pos, places(t).items[index].rot)
	item.thrown_ticks = 0
	item.thrown_by = {}
	physics.stop_ignoring(t.world.phys, &item.thrower_ignore)
}

// Items that fell below KILL_Y go home.
return_fallen_items :: proc(t: ^Tick) {
	for i in 0 ..< places(t).item_count {
		if physics.body_position(t.world.phys, t.state.items[i].body).y < KILL_Y do send_item_home(t, i)
	}
}

// Counts down the thrown items' tags, and ends a thrown item's ignore of its thrower once it is clear of them
// (THROW_CLEAR_DIST), its tag ran out or the thrower left (their body went with the ignore: the stale ref is zeroed
// here, before the tick ends). From then a bounce back hits the thrower like any hit.
age_throws :: proc(t: ^Tick) {
	for i in 0 ..< places(t).item_count {
		item := &t.state.items[i]
		if item.thrown_ticks > 0 do item.thrown_ticks -= 1
		if item.thrower_ignore == {} do continue
		clear := item.thrown_ticks == 0 || !sim.player_present(t, item.thrown_by)
		if !clear {
			away := physics.body_position(t.world.phys, item.body) - player_pos(t, item.thrown_by)
			clear = dmath.length_sq(away) > THROW_CLEAR_DIST * THROW_CLEAR_DIST
		}
		if clear do physics.stop_ignoring(t.world.phys, &item.thrower_ignore)
	}
}
