// Queries and contact hit events, in deterministic order: Box3D's trees and contact arrays are part
// of the world state, so the same world answers the same way after a restore or on another machine.
package physics

import "base:runtime"

import b3 "../box3d"

// Which shapes a query sees: shapes whose category is in `mask` (and whose own mask has one of
// `category`'s bits). Zero value: everything.
Query :: struct {
	category: u64,
	mask:     u64,
}

@(private)
query_filter :: proc(q: Query) -> b3.QueryFilter {
	f := b3.DefaultQueryFilter()
	if q.category != 0 do f.categoryBits = q.category
	if q.mask != 0 do f.maskBits = q.mask
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
	r := b3.World_CastRayClosest(w.id, v3(origin), v3(translation), query_filter(q))
	if !r.hit do return
	return {
			link_of(b3.Shape_GetBody(r.shapeId)),
			{r.point.x, r.point.y, r.point.z},
			{r.normal.x, r.normal.y, r.normal.z},
			r.fraction,
			r.userMaterialId,
		},
		true
}

@(private)
Ray_Ctx :: struct {
	w:      ^World,
	ignore: b3.BodyId,
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
		w      = w,
		ignore = link_id(w, ignore),
	}
	b3.World_CastRay(w.id, v3(origin), v3(translation), query_filter(q), ray_callback, &ctx)
	return ctx.hit, ctx.found
}

@(private)
ray_callback :: proc "c" (
	shape: b3.ShapeId,
	point: b3.Pos,
	normal: b3.Vec3,
	fraction: f32,
	material: u64,
	_: i32,
	_: i32,
	ctx: rawptr,
) -> f32 {
	c := (^Ray_Ctx)(ctx)
	body := b3.Shape_GetBody(shape)
	if (c.ignore.index1 != 0 && body.index1 == c.ignore.index1 && body.generation == c.ignore.generation) ||
	   b3.Shape_IsSensor(shape) {
		return -1
	}
	c.hit = {link_of(body), {point.x, point.y, point.z}, {normal.x, normal.y, normal.z}, fraction, material}
	c.found = true
	return fraction
}

@(private)
Overlap_Ctx :: struct {
	out: ^[dynamic]Body_Link,
	ctx: runtime.Context, // the caller's (append may allocate)
}

// Appends every body with a shape overlapping the box [lo, hi] (fat AABBs, so "near" rather than
// exact), sorted by body index, without duplicates.
overlap_aabb :: proc(w: ^World, lo, hi: [3]f32, out: ^[dynamic]Body_Link, q := Query{}) {
	start := len(out)
	ctx := Overlap_Ctx{out, context}
	b3.World_OverlapAABB(w.id, {v3(lo), v3(hi)}, query_filter(q), overlap_callback, &ctx)
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
overlap_callback :: proc "c" (shape: b3.ShapeId, ctx: rawptr) -> bool {
	c := (^Overlap_Ctx)(ctx)
	context = c.ctx
	append(c.out, link_of(b3.Shape_GetBody(shape)))
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

// The step's hit events (contacts between shapes with `enableHitEvents` that approached faster than
// Settings.hit_threshold), in Box3D's order. Read them right after the step, before destroying
// bodies; a re-simulation regenerates them.
hit_events :: proc(w: ^World, out: ^[dynamic]Hit_Event) {
	ev := b3.World_GetContactEvents(w.id)
	for i in 0 ..< int(ev.hitCount) {
		h := ev.hitEvents[i]
		append(
			out,
			Hit_Event {
				link_of(b3.Shape_GetBody(h.shapeIdA)),
				link_of(b3.Shape_GetBody(h.shapeIdB)),
				{h.point.x, h.point.y, h.point.z},
				{h.normal.x, h.normal.y, h.normal.z},
				h.approachSpeed,
				h.userMaterialIdA,
				h.userMaterialIdB,
			},
		)
	}
}

// ---- body helpers (thin; anything else goes through body_id and unified:box3d)

position :: proc(w: ^World, r: Body_Ref) -> [3]f32 {
	p := b3.Body_GetPosition(body_id(w, r))
	return {p.x, p.y, p.z}
}

velocity :: proc(w: ^World, r: Body_Ref) -> [3]f32 {
	v := b3.Body_GetLinearVelocity(body_id(w, r))
	return {v.x, v.y, v.z}
}

set_velocity :: proc(w: ^World, r: Body_Ref, v: [3]f32) {
	b3.Body_SetLinearVelocity(body_id(w, r), v3(v))
}

rotation :: proc(w: ^World, r: Body_Ref) -> [4]f32 {
	q := b3.Body_GetRotation(body_id(w, r))
	return {q.v.x, q.v.y, q.v.z, q.s}
}

mass :: proc(w: ^World, r: Body_Ref) -> f32 {
	return b3.Body_GetMass(body_id(w, r))
}

impulse :: proc(w: ^World, r: Body_Ref, j: [3]f32) {
	b3.Body_ApplyLinearImpulseToCenter(body_id(w, r), v3(j), true)
}

// Moves a body (respawns, resets): its velocities are zeroed.
teleport :: proc(w: ^World, r: Body_Ref, pos: [3]f32, rot := [4]f32{0, 0, 0, 1}) {
	id := body_id(w, r)
	b3.Body_SetTransform(id, v3(pos), {{rot.x, rot.y, rot.z}, rot.w})
	b3.Body_SetLinearVelocity(id, {})
	b3.Body_SetAngularVelocity(id, {})
}
