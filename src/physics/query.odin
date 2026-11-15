// Queries and contact hit events, in deterministic order: Box3D's trees and contact arrays are part
// of the world state, so the same world answers the same way after a restore or on another machine.
package physics


import "unified:b3"

// Which shapes a query sees: shapes whose category is in `mask` (and whose own mask has one of
// `category`'s bits). Zero value: everything.
Query :: struct {
	category: u64,
	mask:     u64,
}

@(private)
query_filter :: proc(query: Query) -> b3.Query_Filter {
	filter := b3.default_query_filter()
	if query.category != 0 do filter.category_bits = query.category
	if query.mask != 0 do filter.mask_bits = query.mask
	return filter
}

Ray_Hit :: struct {
	body:     Body_Link,
	point:    [3]f32,
	normal:   [3]f32,
	fraction: f32, // along `translation`
	material: u64, // the shape's user material id
}

// Box3D's closest hit along `translation` from `origin` (b3World_CastRayClosest), filtered by `q` only. The cheapest
// ray; ray_closest also skips a given body and sensors.
ray_first :: proc(world: ^World, origin, translation: [3]f32, query := Query{}) -> (hit: Ray_Hit, ok: bool) {
	result := b3.world_cast_ray_closest(world.id, origin, translation, query_filter(query)) or_return
	return {
			link_of(b3.shape_get_body(result.shape_id)),
			result.point,
			result.normal,
			result.fraction,
			result.user_material_id,
		}, true
}

@(private)
Ray_Ctx :: struct {
	ignore: b3.Body_Id,
	hit:    Ray_Hit,
	found:  bool,
}

// The closest hit along `translation` from `origin`, skipping sensors and the `ignore` body (a ray
// that starts inside a shape reports it, so callers skip their own body).
ray_closest :: proc(
	world: ^World,
	origin, translation: [3]f32,
	query := Query{},
	ignore := Body_Link{},
) -> (
	hit: Ray_Hit,
	ok: bool,
) {
	ctx := Ray_Ctx {
		ignore = link_id(world, ignore),
	}
	b3.world_cast_ray(world.id, origin, translation, query_filter(query), ray_callback, &ctx)
	return ctx.hit, ctx.found
}

@(private)
ray_callback :: proc(
	shape: b3.Shape_Id,
	point: [3]f32,
	normal: [3]f32,
	fraction: f32,
	material: u64,
	_: i32,
	_: i32,
	user: rawptr,
) -> f32 {
	ctx := (^Ray_Ctx)(user)
	body := b3.shape_get_body(shape)
	if (ctx.ignore.index1 != 0 && body.index1 == ctx.ignore.index1 && body.generation == ctx.ignore.generation) ||
	   b3.shape_is_sensor(shape) {
		return -1
	}
	ctx.hit = {link_of(body), point, normal, fraction, material}
	ctx.found = true
	return fraction
}

// Appends every body with a shape overlapping the box [lo, hi] (fat AABBs, so "near" rather than
// exact), sorted by body index, without duplicates.
overlap_aabb :: proc(world: ^World, lo, hi: [3]f32, out: ^[dynamic]Body_Link, query := Query{}) {
	start := len(out)
	b3.world_overlap_aabb(world.id, {lo, hi}, query_filter(query), overlap_callback, out)
	got := out[start:]
	// Insertion sort: a handful of bodies, and no core:slice in tick code.
	for i in 1 ..< len(got) {
		held := got[i]
		j := i
		for j > 0 && got[j - 1].index1 > held.index1 {
			got[j] = got[j - 1]
			j -= 1
		}
		got[j] = held
	}
	kept := 0
	for body_link, i in got {
		if i > 0 && body_link == got[kept - 1] do continue
		got[kept] = body_link
		kept += 1
	}
	resize(out, start + kept)
}

@(private)
overlap_callback :: proc(shape: b3.Shape_Id, user: rawptr) -> bool {
	append((^[dynamic]Body_Link)(user), link_of(b3.shape_get_body(shape)))
	return true
}

Hit_Event :: struct {
	a, b:       Body_Link,
	point:      [3]f32,
	normal:     [3]f32, // from a to b
	speed:      f32, // approach speed
	material_a: u64,
	material_b: u64,
}

// The step's hit events (contacts between shapes with `enable_hit_events` that approached faster than
// Settings.hit_threshold), in Box3D's order. Read them right after the step, before destroying
// bodies; a re-simulation regenerates them.
hit_events :: proc(world: ^World, out: ^[dynamic]Hit_Event) {
	for contact in b3.world_get_contact_events(world.id).hit_events {
		append(out, Hit_Event {
			link_of(b3.shape_get_body(contact.shape_id_a)),
			link_of(b3.shape_get_body(contact.shape_id_b)),
			contact.point,
			contact.normal,
			contact.approach_speed,
			contact.user_material_id_a,
			contact.user_material_id_b,
		})
	}
}

// ---- body helpers (thin; anything else goes through body_id and unified:b3)

// A body's world position.
position :: proc(world: ^World, ref: Body_Ref) -> [3]f32 {
	return b3.body_get_position(body_id(world, ref))
}

// A body's linear velocity (m/s).
velocity :: proc(world: ^World, ref: Body_Ref) -> [3]f32 {
	return b3.body_get_linear_velocity(body_id(world, ref))
}

// Sets a body's linear velocity.
set_velocity :: proc(world: ^World, ref: Body_Ref, vel: [3]f32) {
	b3.body_set_linear_velocity(body_id(world, ref), vel)
}

// A body's world rotation (x, y, z, w).
rotation :: proc(world: ^World, ref: Body_Ref) -> [4]f32 {
	return b3.body_get_rotation(body_id(world, ref))
}

// A body's mass (kg).
mass :: proc(world: ^World, ref: Body_Ref) -> f32 {
	return b3.body_get_mass(body_id(world, ref))
}

// Adds an impulse (N·s) at a body's centre of mass, waking it.
impulse :: proc(world: ^World, ref: Body_Ref, linear_impulse: [3]f32) {
	b3.body_apply_linear_impulse_to_center(body_id(world, ref), linear_impulse, true)
}

// Moves a body (respawns, resets): its velocities are zeroed.
teleport :: proc(world: ^World, ref: Body_Ref, pos: [3]f32, rot := [4]f32{0, 0, 0, 1}) {
	id := body_id(world, ref)
	b3.body_set_transform(id, pos, rot)
	b3.body_set_linear_velocity(id, {})
	b3.body_set_angular_velocity(id, {})
}
