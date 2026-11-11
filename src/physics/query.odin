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
query_filter :: proc(q: Query) -> b3.Query_Filter {
	f := b3.default_query_filter()
	if q.category != 0 do f.category_bits = q.category
	if q.mask != 0 do f.mask_bits = q.mask
	return f
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
ray_first :: proc(w: ^World, origin, translation: [3]f32, q := Query{}) -> (hit: Ray_Hit, ok: bool) {
	r := b3.world_cast_ray_closest(w.id, origin, translation, query_filter(q)) or_return
	return {link_of(b3.shape_get_body(r.shape_id)), r.point, r.normal, r.fraction, r.user_material_id}, true
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
	w: ^World,
	origin, translation: [3]f32,
	q := Query{},
	ignore := Body_Link{},
) -> (
	hit: Ray_Hit,
	ok: bool,
) {
	ctx := Ray_Ctx {
		ignore = link_id(w, ignore),
	}
	b3.world_cast_ray(w.id, origin, translation, query_filter(q), ray_callback, &ctx)
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
	c := (^Ray_Ctx)(user)
	body := b3.shape_get_body(shape)
	if (c.ignore.index1 != 0 && body.index1 == c.ignore.index1 && body.generation == c.ignore.generation) ||
	   b3.shape_is_sensor(shape) {
		return -1
	}
	c.hit = {link_of(body), point, normal, fraction, material}
	c.found = true
	return fraction
}

// Appends every body with a shape overlapping the box [lo, hi] (fat AABBs, so "near" rather than
// exact), sorted by body index, without duplicates.
overlap_aabb :: proc(w: ^World, lo, hi: [3]f32, out: ^[dynamic]Body_Link, q := Query{}) {
	start := len(out)
	b3.world_overlap_aabb(w.id, {lo, hi}, query_filter(q), overlap_callback, out)
	got := out[start:]
	// Insertion sort: a handful of bodies, and no core:slice in tick code.
	for i in 1 ..< len(got) {
		x := got[i]
		j := i
		for j > 0 && got[j - 1].index1 > x.index1 {
			got[j] = got[j - 1]
			j -= 1
		}
		got[j] = x
	}
	n := 0
	for l, i in got {
		if i > 0 && l == got[n - 1] do continue
		got[n] = l
		n += 1
	}
	resize(out, start + n)
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
hit_events :: proc(w: ^World, out: ^[dynamic]Hit_Event) {
	for h in b3.world_get_contact_events(w.id).hit_events {
		append(
			out,
			Hit_Event {
				link_of(b3.shape_get_body(h.shape_id_a)),
				link_of(b3.shape_get_body(h.shape_id_b)),
				h.point,
				h.normal,
				h.approach_speed,
				h.user_material_id_a,
				h.user_material_id_b,
			},
		)
	}
}

// ---- body helpers (thin; anything else goes through body_id and unified:b3)

position :: proc(w: ^World, r: Body_Ref) -> [3]f32 {
	return b3.body_get_position(body_id(w, r))
}

velocity :: proc(w: ^World, r: Body_Ref) -> [3]f32 {
	return b3.body_get_linear_velocity(body_id(w, r))
}

set_velocity :: proc(w: ^World, r: Body_Ref, v: [3]f32) {
	b3.body_set_linear_velocity(body_id(w, r), v)
}

rotation :: proc(w: ^World, r: Body_Ref) -> [4]f32 {
	return b3.body_get_rotation(body_id(w, r))
}

mass :: proc(w: ^World, r: Body_Ref) -> f32 {
	return b3.body_get_mass(body_id(w, r))
}

impulse :: proc(w: ^World, r: Body_Ref, j: [3]f32) {
	b3.body_apply_linear_impulse_to_center(body_id(w, r), j, true)
}

// Moves a body (respawns, resets): its velocities are zeroed.
teleport :: proc(w: ^World, r: Body_Ref, pos: [3]f32, rot := [4]f32{0, 0, 0, 1}) {
	id := body_id(w, r)
	b3.body_set_transform(id, pos, rot)
	b3.body_set_linear_velocity(id, {})
	b3.body_set_angular_velocity(id, {})
}
