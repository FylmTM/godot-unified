// World queries and the step's events (src/physics/SPEC.md, What physics covers), in deterministic order: Box3D's
// trees and event arrays are part of the world state, so the same world answers the same way after a restore or on
// another machine, and collected results are sorted on top. Every result names the body (a link), the shape, the
// body's tag and the shape's category bits, so a game knows what it hit without decoding anything.
package physics

import "unified:b3"

// Which shapes a query sees: shapes whose category is in `mask` (and whose own mask has one of `category`'s bits).
// Zero value: everything.
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

// A ray or shape cast's hit.
Ray_Hit :: struct {
	body:     Body_Link,
	shape:    Shape_Ref,
	tag:      u64, // the body's (create_body)
	category: u64, // the shape's category bits
	material: u64, // the shape's user material id
	point:    [3]f32,
	normal:   [3]f32,
	fraction: f32, // along `translation`
}

// A shape an overlap, a sensor or a contact names.
Overlap :: struct {
	body:     Body_Link,
	shape:    Shape_Ref,
	tag:      u64, // the body's
	category: u64, // the shape's category bits
}

// The overlap record of a shape (zero for a shape that no longer exists: an end event after a destroy).
@(private)
overlap_of :: proc(world: ^World, id: b3.Shape_Id) -> Overlap {
	if id.index1 == 0 || !b3.shape_is_valid(id) do return {}
	body := b3.shape_get_body(id)
	return {link_of(body), shape_ref_of(id), tag_of(world, body.index1), b3.shape_get_filter(id).category_bits}
}

@(private)
Ray_Ctx :: struct {
	world:  ^World,
	ignore: b3.Body_Id,
	hit:    Ray_Hit,
	found:  bool,
	out:    ^[dynamic]Ray_Hit, // every hit (world_cast_ray, world_cast_shape); nil: the closest only
}

// The closest hit along `translation` from `origin`, skipping sensors and the `ignore` body (a ray that starts inside
// a shape reports it, so callers skip their own body).
world_cast_ray_closest :: proc(
	world: ^World,
	origin, translation: [3]f32,
	query := Query{},
	ignore := Body_Link{},
) -> (
	hit: Ray_Hit,
	ok: bool,
) {
	ctx := Ray_Ctx {
		world  = world,
		ignore = link_id(world, ignore),
	}
	b3.world_cast_ray(world.id, origin, translation, query_filter(query), ray_callback, &ctx)
	return ctx.hit, ctx.found
}

// Every hit along `translation` from `origin` into `out` (replaced, never appended to), sensors skipped, sorted by
// fraction, then body and shape index.
world_cast_ray :: proc(world: ^World, origin, translation: [3]f32, out: ^[dynamic]Ray_Hit, query := Query{}) {
	clear(out)
	ctx := Ray_Ctx {
		world = world,
		out   = out,
	}
	b3.world_cast_ray(world.id, origin, translation, query_filter(query), ray_callback, &ctx)
	sort_hits(out[:])
}

// Every shape the proxy at `origin`, swept by `translation`, hits, into `out` (replaced), sensors skipped, sorted like
// world_cast_ray's.
world_cast_shape :: proc(
	world: ^World,
	origin: [3]f32,
	proxy: Shape_Proxy,
	translation: [3]f32,
	out: ^[dynamic]Ray_Hit,
	query := Query{},
) {
	clear(out)
	ctx := Ray_Ctx {
		world = world,
		out   = out,
	}
	proxy := proxy
	b3.world_cast_shape(world.id, origin, &proxy, translation, query_filter(query), ray_callback, &ctx)
	sort_hits(out[:])
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
	hit := Ray_Hit {
		body     = link_of(body),
		shape    = shape_ref_of(shape),
		tag      = tag_of(ctx.world, body.index1),
		category = b3.shape_get_filter(shape).category_bits,
		material = material,
		point    = point,
		normal   = normal,
		fraction = fraction,
	}
	if ctx.out != nil {
		append(ctx.out, hit)
		return 1
	}
	ctx.hit = hit
	ctx.found = true
	return fraction
}

// Every shape whose fat AABB overlaps the box [lo, hi] ("near" rather than exact: world_overlap_shape is exact), into
// `out` (replaced), sorted by body index, then shape index. A game keeps `out` in its World as scratch: it never
// holds anything from an earlier call, so it can't carry a result into another tick (src/sim/SPEC.md, World).
world_overlap_aabb :: proc(world: ^World, lo, hi: [3]f32, out: ^[dynamic]Overlap, query := Query{}) {
	clear(out)
	ctx := Overlap_Ctx{world, out}
	b3.world_overlap_aabb(world.id, {lo, hi}, query_filter(query), overlap_callback, &ctx)
	sort_overlaps(out[:])
}

// Every shape the proxy at `origin` overlaps (exactly), into `out` (replaced), sorted like world_overlap_aabb's.
world_overlap_shape :: proc(
	world: ^World,
	origin: [3]f32,
	proxy: Shape_Proxy,
	out: ^[dynamic]Overlap,
	query := Query{},
) {
	clear(out)
	ctx := Overlap_Ctx{world, out}
	proxy := proxy
	b3.world_overlap_shape(world.id, origin, &proxy, query_filter(query), overlap_callback, &ctx)
	sort_overlaps(out[:])
}

@(private)
Overlap_Ctx :: struct {
	world: ^World,
	out:   ^[dynamic]Overlap,
}

@(private)
overlap_callback :: proc(shape: b3.Shape_Id, user: rawptr) -> bool {
	ctx := (^Overlap_Ctx)(user)
	append(ctx.out, overlap_of(ctx.world, shape))
	return true
}

// ---- the step's events

// A contact between two shapes: touching began or ended (both shapes with contact events on), or a hit (one with
// hit events on, approaching faster than Settings.hit_threshold).
Contact_Event :: struct {
	kind:   Contact_Kind,
	a, b:   Overlap, // an End's shape may be gone (destroyed this step): zero
	point:  [3]f32, // .Hit only
	normal: [3]f32, // .Hit only: from a to b
	speed:  f32, // .Hit only: the approach speed
}

Contact_Kind :: enum u8 {
	Begin,
	End,
	Hit,
}

// The step's contact events into `out` (replaced): the begins, the ends, then the hits, each in Box3D's order. Read
// them right after the step, before destroying bodies; a re-simulation regenerates them.
world_contact_events :: proc(world: ^World, out: ^[dynamic]Contact_Event) {
	clear(out)
	events := b3.world_get_contact_events(world.id)
	for event in events.begin_events {
		append(out, Contact_Event {
			kind = .Begin,
			a    = overlap_of(world, event.shape_id_a),
			b    = overlap_of(world, event.shape_id_b),
		})
	}
	for event in events.end_events {
		append(out, Contact_Event {
			kind = .End,
			a    = overlap_of(world, event.shape_id_a),
			b    = overlap_of(world, event.shape_id_b),
		})
	}
	for event in events.hit_events {
		append(out, Contact_Event {
			kind   = .Hit,
			a      = overlap_of(world, event.shape_id_a),
			b      = overlap_of(world, event.shape_id_b),
			point  = event.point,
			normal = event.normal,
			speed  = event.approach_speed,
		})
	}
}

// A shape entered or left a sensor (the visitor's shape has sensor events on: Shape_Def.enable_sensor_events).
Sensor_Event :: struct {
	kind:    Sensor_Kind,
	sensor:  Overlap,
	visitor: Overlap, // an End's visitor may be gone: zero
}

Sensor_Kind :: enum u8 {
	Begin,
	End,
}

// The step's sensor events into `out` (replaced): the begins, then the ends, each in Box3D's order (sorted by
// unified-box3d: the same on every platform).
world_sensor_events :: proc(world: ^World, out: ^[dynamic]Sensor_Event) {
	clear(out)
	events := b3.world_get_sensor_events(world.id)
	for event in events.begin_events {
		append(
			out,
			Sensor_Event{.Begin, overlap_of(world, event.sensor_shape_id), overlap_of(world, event.visitor_shape_id)},
		)
	}
	for event in events.end_events {
		append(
			out,
			Sensor_Event{.End, overlap_of(world, event.sensor_shape_id), overlap_of(world, event.visitor_shape_id)},
		)
	}
}

// The shapes inside a sensor after the last step, into `out` (replaced), sorted by body index, then shape index.
shape_sensor_data :: proc(world: ^World, sensor: Shape_Ref, out: ^[dynamic]Overlap) {
	clear(out)
	id := shape_id(world, sensor)
	capacity := int(b3.shape_get_sensor_capacity(id))
	if capacity == 0 do return
	resize(&world.visitors, capacity)
	count := b3.shape_get_sensor_data(id, world.visitors[:])
	for visitor in world.visitors[:count] {
		append(out, overlap_of(world, visitor))
	}
	sort_overlaps(out[:])
}

// ---- deterministic order (insertion sorts: a handful of results, and no core:slice in tick code)

@(private)
sort_overlaps :: proc(items: []Overlap) {
	for i in 1 ..< len(items) {
		held := items[i]
		j := i
		for j > 0 && overlap_before(held, items[j - 1]) {
			items[j] = items[j - 1]
			j -= 1
		}
		items[j] = held
	}
}

@(private)
overlap_before :: proc(a, b: Overlap) -> bool {
	if a.body.index1 != b.body.index1 do return a.body.index1 < b.body.index1
	return a.shape.index1 < b.shape.index1
}

@(private)
sort_hits :: proc(items: []Ray_Hit) {
	for i in 1 ..< len(items) {
		held := items[i]
		j := i
		for j > 0 && hit_before(held, items[j - 1]) {
			items[j] = items[j - 1]
			j -= 1
		}
		items[j] = held
	}
}

@(private)
hit_before :: proc(a, b: Ray_Hit) -> bool {
	if a.fraction != b.fraction do return a.fraction < b.fraction
	if a.body.index1 != b.body.index1 do return a.body.index1 < b.body.index1
	return a.shape.index1 < b.shape.index1
}
