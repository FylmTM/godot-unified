// What the sim shows a developer (src/sim/README.md, Debug draws and zones): shapes and text drawn from tick code,
// kept per tick in the ring beside the events, and the time each system of a tick takes. Neither is state: never in
// the block, never hashed, never in a snapshot or on the wire. A tick re-simulated after a rollback draws again and
// replaces what it drew before. All of it hangs off one Dev the host attaches to a Sim (dev_attach); without one, or in
// a build without the dev UI (DEV false), every call here returns at once. Tick code can't read the Dev (the lint bans
// `.dev` outside this package), so a clock reading or a draw list can never reach state.
package sim

import "base:builtin"
import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:strings"

// The dev UI's build switch (`-define:UNIFIED_DEVUI=false`: a public build): false leaves every draw and zone call an
// empty proc and filters dev commands out (the lint allows this one #config in this package).
DEV :: #config(UNIFIED_DEVUI, true)

// A colour for a debug draw: 0xRRGGBB (any value casts: `sim.Debug_Color(0x80ff00)`).
Debug_Color :: enum u32 {
	White   = 0xffffff,
	Gray    = 0x909090,
	Red     = 0xff4040,
	Orange  = 0xff9020,
	Yellow  = 0xffe040,
	Green   = 0x40e040,
	Cyan    = 0x40e0e0,
	Blue    = 0x4080ff,
	Magenta = 0xe040e0,
}

// What a Debug_Shape is.
Debug_Kind :: enum u8 {
	Line, // a to b
	Point, // at a, `size` across
	Sphere, // centre a, radius size
	Capsule, // segment a to b, radius size
	Box, // centre a, half extents b, rotation rot
	Text, // at a: text[0] bytes of Debug_Draws.text from text[1]
}

// One debug draw, in sim units.
Debug_Shape :: struct {
	kind:  Debug_Kind,
	group: u8, // the draw group it belongs to (Dev.groups): the zone it was made in, else DEBUG_GROUP_OTHER
	_pad:  [2]u8,
	color: u32, // 0xRRGGBB (Debug_Color)
	a, b:  [3]f32,
	size:  f32,
	rot:   [4]f32, // a unit quaternion (Box; zero: identity)
	text:  [2]u32, // Text: length, offset into Debug_Draws.text
}

// A tick's debug draws (debug_draws), in the order they were made.
Debug_Draws :: struct {
	shapes: [dynamic]Debug_Shape,
	text:   [dynamic]u8, // the texts' bytes
}

// Most draws one tick keeps: past it a draw loop is a runaway (a panic).
DEBUG_DRAWS_LIMIT :: 1 << 16
// Most zones a game's zone enum has (its members count up from 0).
ZONES_MAX :: 32
// Deepest zone nesting.
ZONE_DEPTH :: 8
// The draw groups (Dev.groups): 0 ..< ZONES_MAX the zones by their enum value, DEBUG_GROUP_OTHER a draw outside any
// zone, the rest named by libraries (debug_sink).
DEBUG_GROUP_OTHER :: ZONES_MAX
DEBUG_GROUPS :: 64

// The development attachment of a Sim (dev_attach): what is drawn and timed. Owned by the Sim; its fields are the
// host's to read between steps (the session thread), never tick code's.
Dev :: struct {
	enabled:    u64, // the draw groups kept from the next step on (dev_enable); 0: no draws at all
	groups:     [DEBUG_GROUPS]string, // their names ("": none yet): the zones' lowercased, "other", the libraries'
	group_seq:  u32, // bumped whenever a name is added
	clock:      proc "contextless" () -> i64, // the host's clock (ns); nil: zones are not timed
	zone_type:  typeid, // the game's zone enum (its first zone call)
	zone_count: int, // its members
	zone_ns:    [ZONES_MAX + 1]i64, // each zone's self time, summed over every step since attach; [ZONES_MAX]: outside any
	zone_calls: [ZONES_MAX + 1]u64,
	draws:      ^Debug_Draws, // the stepped tick's list while any group is enabled, else nil
	stack:      [ZONE_DEPTH]Open_Zone, // the zones open in the tick being stepped (stack[:depth])
	depth:      int,
	zoned:      i64, // this step's time in top-level zones
	allocator:  runtime.Allocator, // the names'
}

// A zone being timed (Dev.stack).
Open_Zone :: struct {
	index: u8, // the zone's enum value
	start: i64, // the clock when it opened
	inner: i64, // the time of the zones it opened (self time is the rest)
}

// The scope sim.zone returns for its deferred end: nothing tick code can read (`.dev` is the harness's).
Zone_Scope :: struct {
	dev: ^Dev,
}

// Attaches a Dev to the Sim (once; again returns the one it has): draws and zones from the next step on. `clock`: the
// host's (nanoseconds, any origin), so the sim reads none itself; nil: zones still name draw groups but are not
// timed. Nothing in a build without the dev UI (nil).
dev_attach :: proc(simulation: ^Sim($G), clock: proc "contextless" () -> i64 = nil) -> ^Dev {
	when !DEV do return nil
	if simulation.dev == nil {
		simulation.dev = new(Dev)
		simulation.dev.allocator = context.allocator
		simulation.dev.groups[DEBUG_GROUP_OTHER] = "other"
		simulation.dev.group_seq = 1 // a reader that starts at 0 copies the names once
	}
	if clock != nil do simulation.dev.clock = clock
	return simulation.dev
}

// Frees a Dev (sim.destroy calls it).
@(private)
dev_destroy :: proc(dev: ^Dev) {
	if dev == nil do return
	context.allocator = dev.allocator
	for name, i in dev.groups do if i != DEBUG_GROUP_OTHER do delete(name)
	free(dev)
}

// Which draw groups the following steps keep (bit n: Dev.groups[n]; 0: none, every draw call returns at once).
dev_enable :: proc(simulation: ^Sim($G), groups: u64) {
	if simulation.dev != nil do simulation.dev.enabled = groups
}

// The draws the step to `tick` made (nil when the ring no longer holds it); empty when no group was enabled then.
debug_draws :: proc(simulation: ^Sim($G), tick: u32) -> ^Debug_Draws {
	slot := &simulation.ring[ring_slot(simulation, tick)]
	return &slot.draws if slot.valid && slot.tick == tick else nil
}

// ---- drawing (tick code)

// Whether draws made here are kept (the current zone's group is enabled): skip the work a draw needs, not just the
// draw, when nobody looks.
drawing :: proc(t: ^Tick($G)) -> bool {
	when !DEV do return false
	return draw_group(t.dev) >= 0
}

// The group a draw made now belongs to, or -1 when it is not kept.
@(private)
draw_group :: #force_inline proc "contextless" (dev: ^Dev) -> int {
	if dev == nil || dev.draws == nil do return -1
	group := dev.depth > 0 ? int(dev.stack[dev.depth - 1].index) : DEBUG_GROUP_OTHER
	return dev.enabled & (1 << uint(group)) != 0 ? group : -1
}

// A point as a draw takes it: a sim.Position or a [3]f32 (a physics position), each argument on its own.
@(private)
point_of :: #force_inline proc "contextless" (point: $P) -> [3]f32 where P == Position || P == [3]f32 {
	return ([3]f32)(point)
}

// Draws a line: from tick code, in the zone's group (`sim.debug_line(t, enemy.pos, target.pos, .Yellow)`), or into a
// library's group (a Debug_Sink: `sim.debug_line(sink, a, b, color)`). The six draws (line, point, sphere, capsule,
// box, text) each take either target.
debug_line :: proc {
	debug_line_tick,
	debug_line_sink,
}

// Draws a point (`size` sim units across).
debug_point :: proc {
	debug_point_tick,
	debug_point_sink,
}

// Draws a sphere's outline.
debug_sphere :: proc {
	debug_sphere_tick,
	debug_sphere_sink,
}

// Draws a capsule's outline (the segment a to b, swept by `radius`).
debug_capsule :: proc {
	debug_capsule_tick,
	debug_capsule_sink,
}

// Draws a box's edges (`half` its half extents, `rot` a unit quaternion; zero: identity).
debug_box :: proc {
	debug_box_tick,
	debug_box_sink,
}

// Draws text at a point: from tick code formatted like fmt.printf (`sim.debug_text(t, pos, "hp %d", hp, color =
// .Red)`; at most 96 bytes; a hidden group formats nothing), into a sink as given.
debug_text :: proc {
	debug_text_tick,
	debug_text_sink,
}

// debug_line from tick code.
debug_line_tick :: proc(
	t: ^Tick($G),
	a: $A,
	b: $B,
	color := Debug_Color.White,
) where (A == Position || A == [3]f32) &&
	(B == Position || B == [3]f32) {
	when DEV do if group := draw_group(t.dev); group >= 0 do dev_shape(t.dev, {kind = .Line, group = u8(group), color = u32(color), a = point_of(a), b = point_of(b)})
}

// debug_point from tick code.
debug_point_tick :: proc(
	t: ^Tick($G),
	point: $P,
	color := Debug_Color.White,
	size: f32 = 0.1,
) where P == Position ||
	P == [3]f32 {
	when DEV do if group := draw_group(t.dev); group >= 0 do dev_shape(t.dev, {kind = .Point, group = u8(group), color = u32(color), a = point_of(point), size = size})
}

// debug_sphere from tick code.
debug_sphere_tick :: proc(
	t: ^Tick($G),
	centre: $P,
	radius: f32,
	color := Debug_Color.White,
) where P == Position ||
	P == [3]f32 {
	when DEV do if group := draw_group(t.dev); group >= 0 do dev_shape(t.dev, {kind = .Sphere, group = u8(group), color = u32(color), a = point_of(centre), size = radius})
}

// debug_capsule from tick code.
debug_capsule_tick :: proc(
	t: ^Tick($G),
	a: $A,
	b: $B,
	radius: f32,
	color := Debug_Color.White,
) where (A == Position || A == [3]f32) &&
	(B == Position || B == [3]f32) {
	when DEV do if group := draw_group(t.dev); group >= 0 do dev_shape(t.dev, {kind = .Capsule, group = u8(group), color = u32(color), a = point_of(a), b = point_of(b), size = radius})
}

// debug_box from tick code.
debug_box_tick :: proc(
	t: ^Tick($G),
	centre: $P,
	half: [3]f32,
	rot: [4]f32 = {},
	color := Debug_Color.White,
) where P == Position ||
	P == [3]f32 {
	when DEV do if group := draw_group(t.dev); group >= 0 do dev_shape(t.dev, {kind = .Box, group = u8(group), color = u32(color), a = point_of(centre), b = half, rot = rot})
}

// debug_text from tick code.
debug_text_tick :: proc(
	t: ^Tick($G),
	pos: $P,
	format: string,
	args: ..any,
	color := Debug_Color.White,
) where P == Position ||
	P == [3]f32 {
	when DEV {
		group := draw_group(t.dev)
		if group < 0 do return
		buffer: [96]u8
		dev_text(t.dev, u8(group), point_of(pos), fmt.bprintf(buffer[:], format, ..args), u32(color))
	}
}

// Appends a shape to the tick's draws.
@(private)
dev_shape :: proc(dev: ^Dev, shape: Debug_Shape) {
	draws := dev.draws
	if len(draws.shapes) >= DEBUG_DRAWS_LIMIT do panic("sim: more than DEBUG_DRAWS_LIMIT debug draws in one tick: a runaway loop?")
	builtin.append(&draws.shapes, shape)
}

@(private)
dev_text :: proc(dev: ^Dev, group: u8, pos: [3]f32, text: string, color: u32) {
	draws := dev.draws
	offset := len(draws.text)
	builtin.append(&draws.text, text)
	dev_shape(dev, {kind = .Text, group = group, color = color, a = pos, text = {u32(len(text)), u32(offset)}})
}

// ---- library draw groups

// Where a library (physics.debug_draw) draws into a group of its own: a value non-generic code can keep, valid for the
// tick it was taken in.
Debug_Sink :: struct {
	dev:   ^Dev,
	group: u8,
}

// The library draw group named `name` (lowercase, no spaces: "physics_shapes"; registered on first use, at most DEBUG_GROUPS - DEBUG_GROUP_OTHER - 1 of
// them), and whether it is kept this tick: draw into it (`sim.debug_line(sink, ...)`) only when `shown`.
debug_sink :: proc(t: ^Tick($G), name: string) -> (sink: Debug_Sink, shown: bool) {
	when !DEV do return
	dev := t.dev
	if dev == nil do return
	group := DEBUG_GROUPS
	for i in DEBUG_GROUP_OTHER + 1 ..< DEBUG_GROUPS {
		if dev.groups[i] == name {
			group = i
			break
		}
		if dev.groups[i] == "" {
			dev.groups[i] = strings.clone(name, dev.allocator)
			dev.group_seq += 1
			group = i
			break
		}
	}
	if group == DEBUG_GROUPS do panic("sim.debug_sink: more library draw groups than DEBUG_GROUPS has room for")
	return {dev, u8(group)}, dev.draws != nil && dev.enabled & (1 << uint(group)) != 0
}

// debug_line into a sink's group.
debug_line_sink :: proc(sink: Debug_Sink, a, b: [3]f32, color := Debug_Color.White) {
	dev_shape(sink.dev, {kind = .Line, group = sink.group, color = u32(color), a = a, b = b})
}

// debug_point into a sink's group.
debug_point_sink :: proc(sink: Debug_Sink, point: [3]f32, color := Debug_Color.White, size: f32 = 0.1) {
	dev_shape(sink.dev, {kind = .Point, group = sink.group, color = u32(color), a = point, size = size})
}

// debug_sphere into a sink's group.
debug_sphere_sink :: proc(sink: Debug_Sink, centre: [3]f32, radius: f32, color := Debug_Color.White) {
	dev_shape(sink.dev, {kind = .Sphere, group = sink.group, color = u32(color), a = centre, size = radius})
}

// debug_capsule into a sink's group.
debug_capsule_sink :: proc(sink: Debug_Sink, a, b: [3]f32, radius: f32, color := Debug_Color.White) {
	dev_shape(sink.dev, {kind = .Capsule, group = sink.group, color = u32(color), a = a, b = b, size = radius})
}

// debug_box into a sink's group.
debug_box_sink :: proc(sink: Debug_Sink, centre, half: [3]f32, rot: [4]f32 = {}, color := Debug_Color.White) {
	dev_shape(sink.dev, {kind = .Box, group = sink.group, color = u32(color), a = centre, b = half, rot = rot})
}

// debug_text into a sink's group: the text as given (a library formats its own).
debug_text_sink :: proc(sink: Debug_Sink, pos: [3]f32, text: string, color := Debug_Color.White) {
	dev_text(sink.dev, sink.group, pos, text, u32(color))
}

// ---- zones (tick code)

// Times the rest of the enclosing scope as a zone of the game's zone enum, and makes it the group of the draws made in
// it: `sim.zone(t, Zone.Steer)` (the enum named: `.Steer` has nothing to infer it from). A zone's time is its self
// time (the zones it opens are their own), so a tick's zones and "other" add up to its step. A game names its zones
// with one enum whose members count up from 0, at most ZONES_MAX.
@(deferred_out = zone_end)
zone :: proc(t: ^Tick($G), zone: $Z) -> Zone_Scope where intrinsics.type_is_enum(Z) {
	when !DEV do return {}
	dev := t.dev
	if dev == nil do return {}
	if dev.zone_type != Z do zone_learn(dev, Z)
	assert(dev.depth < ZONE_DEPTH, "sim.zone: zones nested deeper than ZONE_DEPTH")
	dev.stack[dev.depth] = {
		index = u8(zone),
		start = dev.clock != nil ? dev.clock() : 0,
	}
	dev.depth += 1
	return {dev}
}

// Closes the zone sim.zone opened (its deferred end).
zone_end :: proc(scope: Zone_Scope) {
	when !DEV do return
	dev := scope.dev
	if dev == nil do return
	dev.depth -= 1
	open := dev.stack[dev.depth]
	dev.zone_calls[open.index] += 1
	if dev.clock == nil do return
	took := dev.clock() - open.start
	dev.zone_ns[open.index] += took - open.inner
	if dev.depth > 0 {
		dev.stack[dev.depth - 1].inner += took
	} else {
		dev.zoned += took
	}
}

// The first zone call: the game's zone enum, its names as draw groups.
@(private)
zone_learn :: proc(dev: ^Dev, zone_type: typeid) {
	if dev.zone_type != nil {
		panic(fmt.tprintf("sim.zone: a game names its zones with one enum (%v, then %v)", dev.zone_type, zone_type))
	}
	info, is_enum := runtime.type_info_base(type_info_of(zone_type)).variant.(runtime.Type_Info_Enum)
	assert(is_enum && len(info.names) <= ZONES_MAX, "sim.zone: a zone enum has at most ZONES_MAX members")
	for name, i in info.names {
		if int(info.values[i]) != i do panic("sim.zone: the zone enum's members count up from 0")
		dev.groups[i] = strings.to_lower(name, dev.allocator)
	}
	dev.zone_type, dev.zone_count = zone_type, len(info.names)
	dev.group_seq += 1
}

// Each zone's self time and calls since attach (cumulative, like a step counter: a reader takes differences), the
// game's zones by enum value then "other" (the step outside any zone), with their names; empty before the first zone.
Zone_Totals :: struct {
	names: []string,
	ns:    []i64,
	calls: []u64,
}

// The Sim's Zone_Totals (views into its Dev, valid until the next step).
zone_totals :: proc(simulation: ^Sim($G)) -> Zone_Totals {
	dev := simulation.dev
	if dev == nil || dev.zone_count == 0 do return {}
	totals := Zone_Totals {
		names = make([]string, dev.zone_count + 1, context.temp_allocator),
		ns    = make([]i64, dev.zone_count + 1, context.temp_allocator),
		calls = make([]u64, dev.zone_count + 1, context.temp_allocator),
	}
	for i in 0 ..< dev.zone_count {
		totals.names[i], totals.ns[i], totals.calls[i] = dev.groups[i], dev.zone_ns[i], dev.zone_calls[i]
	}
	totals.names[dev.zone_count] = "other"
	totals.ns[dev.zone_count], totals.calls[dev.zone_count] = dev.zone_ns[ZONES_MAX], dev.zone_calls[ZONES_MAX]
	return totals
}

// ---- the harness (step)

// Before a step's `tick`: its draws go to the slot's list (cleared: a re-simulation replaces them) while any group is
// enabled; returns the clock at the start.
@(private)
dev_step_begin :: proc(dev: ^Dev, draws: ^Debug_Draws) -> i64 {
	builtin.clear(&draws.shapes)
	builtin.clear(&draws.text)
	if dev == nil do return 0
	dev.draws = dev.enabled != 0 ? draws : nil
	dev.depth, dev.zoned = 0, 0
	return dev.clock != nil ? dev.clock() : 0
}

// After a step's `tick`: the time outside any zone is "other".
@(private)
dev_step_end :: proc(dev: ^Dev, started: i64) {
	if dev == nil do return
	assert(dev.depth == 0, "sim.zone: a zone left open at the end of the tick")
	dev.draws = nil
	dev.zone_calls[ZONES_MAX] += 1
	if dev.clock != nil do dev.zone_ns[ZONES_MAX] += dev.clock() - started - dev.zoned
}
