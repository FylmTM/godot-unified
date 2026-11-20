// The unified:godot view test extension: the toy game (no physics: it also proves unified:godot links without
// Box3D) with a Glue that shows fixed 2D and 3D scene views and MultiMesh items, the toy's command counters as
// session data (Unified.data.toy) and a few constants (Unified.constants). tests/godot_views/test.gd starts a single
// player session under headless Godot (`uni test --suite godot-bindings`) and checks where the views end up, the
// data, constants, enum, event and command classes, the view lifecycle and the input sample.
package views_test_ext

import "core:math"
import "unified:godot"
import "unified:sim"

import "../../toy"

View :: enum u8 {
	Typed2D,
	Plain2D,
	Plain3D,
	Decoy2D,
	Card, // a Control: data only, never posed
	Scripted3D, // posed by its script (GLUE.views: pose = .Script)
	Bench2D, // the view benchmark's player view: no data (typed2d's data leaves a field out on purpose)
	Remote3D, // another player's on the verified timeline (GLUE.views: remote = .Verified)
	Rider3D, // a thing's that shows a player (a car's driver), the same policy
	Predicted3D, // a kind left on the prediction, showing the remote player
}

// The decoy views' subject: another table's handle, given each thing's key (fill_frame).
Decoy :: struct {}

MultiView :: enum u8 {
	Multi2D,
	Multi3D,
	Smooth3D, // corrections glide: a track per instance (GLUE.multi_policy)
}

Frame :: godot.Frame(toy.Game, View, MultiView)

// The typed2d view's data: set as its properties, each when its bytes change. The script leaves out `pad_check` on
// purpose: the host reports the missing property as an error the suite expects.
Typed2D_Data :: struct {
	shown:     bool,
	mode:      Mode, // an enum only view data uses: an int, with its class (EnumMode): GLUE.views declares the type
	_pad:      [2]u8,
	hp:        i32,
	ticks:     u32, // the frame's tick: changes every frame
	charge:    f32,
	dir:       [2]f32,
	tint:      godot.Color,
	pad_check: f32,
	area:      toy.Mark_Area, // a nested struct: an object of its class (DataMarkArea)
}

// The remote3d views' data: the tick it is of (on the verified timeline, the sample's).
Remote3D_Data :: struct {
	tick: u32,
}

// The card view's data (a Control root: the host sets data, never a pose): one card per thing. `holder` is not
// `owner`: a data field is set as the root's property, and a Node's own `owner` is another.
Card_Data :: struct {
	life:   i32,
	shape:  toy.Shape,
	_pad:   [3]u8,
	holder: sim.Player, // its key
}

Mode :: enum u8 {
	Idle,
	Open,
}

Data :: union {
	Data_Toy,
}

// The session data (Unified.data.toy): the local player's command counters and position.
Data_Toy :: struct {
	bumps:       u32,
	bump_sum:    i32,
	marks:       u32,
	mark_at:     [2]f32,
	mark_normal: [3]f32,
	mark_weight: f32,
	mark_count:  i16,
	mark_shape:  toy.Shape, // an int; EnumShape names it
	mark_shapes: toy.Shapes, // an Array of ints
	mark_loud:   bool,
	_pad:        [3]u8,
	mark_target: sim.Handle(toy.Thing), // its key
	mark_place:  [3]f32, // sim units (a sim.Position here would be shown in view units)
	mark_area:   toy.Mark_Area,
	at:          sim.Position, // the local player's position: a view unit Vector2 (x, y) * VIEW_SCALE
	x:           f32,
	y:           f32,
	spawned:     u32,
	tint:        [4]f32, // by shape: a Vector4 (godot.Color is a Color)
	turn:        godot.Quat, // a Quaternion
	cell:        [2]i32, // a Vector2i
	_pad2:       [4]u8,
	lamp:        sim.Entity, // its index (sim.entity(4): 4)
	no_lamp:     sim.Entity, // the zero Entity: -1
	open:        sim.Bits(10), // {1, 7}: an Array of the indices
	recent:      sim.List(sim.Handle(toy.Thing), 4), // the live things (up to 4): an Array of their keys
	queue:       sim.Queue(u8, 3), // 2, 3, 4 (wrapped): an Array, oldest first
	_pad3:       [7]u8,
	trail:       sim.List(sim.Position, 3), // the local player's last Command_Trail: an Array of view-unit Vector2s
	trail_box:   Trail_Box, // the same, inside a nested struct
	areas:       sim.List(toy.Mark_Area, 2), // an Array of DataMarkArea objects
	trail_first: [3]f32, // the trail's first point in sim units (the sim got it so)
}

// A nested struct holding a List of positions (DataTrailBox): its points read in view units too.
Trail_Box :: struct {
	points: sim.List(sim.Position, 3),
}

// The constants (Unified.constants): what `constants` returns, copied at install.
Data_Constants :: struct {
	speed:    f32,
	name:     string,
	favorite: toy.Shape,
	sizes:    [5]i32, // an Array[int] ([2]/[3]/[4]i32 would be a Vector2i/3i/4i)
	limits:   Limits, // a nested struct: an object of its class (DataLimits)
	ranges:   [2]Limits, // an Array[DataLimits]
	by_shape: [toy.Shape]f32, // an enumerated array: an Array in the enum's order
}

Limits :: struct {
	low, high: i32,
}

constants :: proc() -> Data_Constants {
	return {
		speed = 4.5,
		name = "toy",
		favorite = .Ring,
		sizes = {1, 2, 3, 4, 5},
		limits = {low = -1, high = 9},
		ranges = {{low = 0, high = 1}, {low = 2, high = 3}},
		by_shape = {.Dot = 0.5, .Ring = 1, .Star = 2},
	}
}

// Fixed poses: every tick the same, so the interpolated pose is exact at any alpha. In view units (what test.gd
// expects): fill_frame pushes them in sim units (/ VIEW_SCALE) and the host maps them back.
VIEW_SCALE :: 10
POS_2D :: sim.Position{120, 80, 5} // pos.z is unused in 2D
ANGLE_2D :: 0.5 // radians, as test.gd reads Node2D.rotation
POS_3D :: sim.Position{1, 2, 3}
YAW_3D :: 0.75
TUMBLE_3D :: 0.3 // a MultiMesh instance's rotation about +X after the yaw: a full rotation, not a yaw only
BLINK_FROM :: 20 // the blink view (plain2d key 5) exists for ticks BLINK_FROM ..< BLINK_TO
BLINK_TO :: 40
// The remote3d walk (remote_walk, remote_x): along x at REMOTE_SPEED a tick, REMOTE_JUMP further from the middle of
// each REMOTE_PERIOD ticks, back to 0 at its start; each jump a warp. A player no session has (never local) shows it,
// the local player too, a predicted3d view of the remote player, and a thing (key REMOTE_THING) that shows the remote
// player for the first half of each period and the local one the second. The remote player gets an Event_Spawned at
// its walk's position every REMOTE_EVENT_EVERY ticks (drawn_tick). A second remote player (REMOTE_BLINK) walks its own
// lane for ticks REMOTE_BLINK_FROM ..< REMOTE_BLINK_TO only.
REMOTE_SPEED :: 0.01
REMOTE_JUMP :: 2 // under the default teleport_dist: only the warp keeps playback from gliding across it
REMOTE_PERIOD :: 64
REMOTE_EVENT_EVERY :: 16 // at phase REMOTE_EVENT_AT of each such stretch: away from the jumps
REMOTE_EVENT_AT :: 10
REMOTE_PLAYER :: sim.Player {
	index = 3,
	id    = 77,
}
REMOTE_BLINK :: sim.Player {
	index = 2,
	id    = 78,
}
REMOTE_BLINK_FROM :: 60
REMOTE_BLINK_TO :: 100
REMOTE_THING :: 9

GLUE := godot.Glue(toy.Game, View, MultiView) {
	sample_input = sample_input,
	fill_frame = fill_frame,
	data = Data,
	is_2d = true,
	view_scale = VIEW_SCALE,
	event_key = event_key,
	input_values = Input_Values,
	views = #partial {
		// every kind with data declares it, as Glue.data's
		.Typed2D = {data = Typed2D_Data},
		.Card = {data = Card_Data},
		.Remote3D = {data = Remote3D_Data, policy = {remote = .Verified}},
		.Scripted3D = {policy = {appear = .Verified, pose = .Script}},
		.Rider3D = {policy = {remote = .Verified}},
		.Predicted3D = {policy = {remote = .Predicted}},
		.Plain3D = {policy = {smoothing = {tau_s = 0.05}}},
	},
	multi_policy = #partial{.Smooth3D = {smoothing = godot.SMOOTHING_DEFAULT}},
}

// The toy with the view benchmark's hook (sim.Game.bench_prepare), set by the entry point.
GAME: toy.Game

// The view-sync benchmark (view_bench.gd, `uni view-bench`): `-- --bench N` makes every frame N moving Multi3D
// instances and BENCH_SCENE_VIEWS moving plain3d views instead of the fixed items. Set on the session thread before
// its first tick, read by fill_frame on the same thread.
BENCH_SCENE_VIEWS :: 64
BENCH_STATIC_VIEWS :: 64 // and as many at rest (a level's markers, a crate on the floor)
bench_instances: int

// Holds no sim state: the count only drives the views (bench_frame).
bench_prepare :: proc(state: ^toy.State, world: ^toy.World, count: int) {
	bench_instances = count
}

// The benchmark's frame: the local player's bench2d view (the player's events reach it), BENCH_SCENE_VIEWS plain3d views circling, and the instances on a grid, each turning and bobbing (every value
// changes every tick, so nothing is the same as the tick before).
bench_frame :: proc(f: ^Frame) {
	godot.push_view(f, f.local_players[0], {kind = .Bench2D})
	seconds := f32(f.tick) / toy.HZ
	for i in 0 ..< BENCH_SCENE_VIEWS {
		angle := seconds + f32(i) * math.TAU / BENCH_SCENE_VIEWS
		godot.push_view(f, sim.entity(100 + i), {
			kind = .Plain3D,
			pos  = {math.cos(angle), 0, math.sin(angle)},
			rot  = quat_yaw_angle(angle),
		})
	}
	for i in 0 ..< BENCH_STATIC_VIEWS {
		godot.push_view(f, sim.entity(200 + i), {kind = .Plain3D, pos = {f32(i % 8), 2, f32(i / 8)}})
	}
	side := max(int(math.sqrt(f32(bench_instances))), 1)
	for i in 0 ..< bench_instances {
		phase := seconds + f32(i) * 0.01
		godot.push_multi_view(f, {
			key    = u64(i + 1),
			kind   = .Multi3D,
			pos    = {f32(i % side) * 0.2, 0.1 * math.sin(phase), f32(i / side) * 0.2},
			rot    = quat_yaw_angle(phase),
			custom = {phase, 0, 0, 0},
		})
	}
}

// The player drifts right; pressing ui_accept spawns one thing (on the press: held, it doesn't repeat), a `Spawned`
// event with a handle, a position, the player and an enum, which expires a few dozen ticks later; Unified.input.drift
// moves it down.
sample_input :: proc(_: int, input: ^toy.Input) {
	input.dx = 2
	input.dy = i8(godot.input_values(Input_Values).drift)
	input.buttons = godot.buttons(toy.Buttons, {.Spawn = "ui_accept"})
}

// What test.gd sets on Unified.input.
Input_Values :: struct {
	drift: f32,
	_pad:  [4]u8,
	pick:  sim.Entity, // a fixed thing's index, set and read back (-1: none)
	picks: sim.List(u8, 3), // an Array of up to 3 ints, set and read back
	_pad2: [4]u8,
	flags: sim.Bits(10), // an Array of indices below 10, set and read back
	order: sim.Queue(u8, 3), // set as an Array, read back from its oldest (head 0)
	_pad3: [3]u8,
}

fill_frame :: proc(f: ^Frame) {
	local := sim.player_data(&f.state.players, f.local_players[0])
	if local == nil do return // before the local player's join tick
	if bench_instances > 0 {
		bench_frame(f)
		return
	}
	q2 := godot.quat_turns_2d(ANGLE_2D / math.TAU)
	q3 := quat_yaw_angle(YAW_3D)
	godot.push_view(f, f.local_players[0], {
		kind = .Typed2D,
		pos  = POS_2D / VIEW_SCALE,
		rot  = q2,
	}, Typed2D_Data {
		shown = true,
		mode = .Open,
		hp = -3,
		ticks = f.tick,
		charge = 0.5,
		dir = {0.6, -0.8},
		tint = {1, 0.5, 0.25, 1},
		area = {corner = {1, 2}, layer = 3},
	})
	godot.push_view(f, sim.entity(2), {
		kind = .Plain2D,
		pos  = (POS_2D + {10, 0, 0}) / VIEW_SCALE,
		rot  = q2,
	})
	// the same key in another kind: another view
	godot.push_view(f, sim.entity(2), {
		kind = .Plain3D,
		pos  = POS_3D / VIEW_SCALE,
		rot  = q3,
	})
	godot.push_view(f, sim.entity(3), {
		kind = .Scripted3D,
		pos  = POS_3D / VIEW_SCALE,
		rot  = q3,
	})
	remote_walk(f)
	if f.tick >= BLINK_FROM && f.tick < BLINK_TO {
		godot.push_view(f, sim.entity(5), {
			kind = .Plain2D,
			pos  = {-5, -5, 0},
		})
	}
	// A decoy per thing: a view of another table's handle with the thing's key. A Spawned event (its subject a
	// Handle(Thing)) reaches only views pushed with a Handle(Thing), so not these: it falls back to its player's view.
	things := sim.iterate(&f.state.things)
	for item, thing in sim.next(&things) {
		decoy := sim.Handle(Decoy) {
			index      = thing.index,
			generation = thing.generation,
		}
		godot.push_view(f, decoy, {kind = .Decoy2D, pos = {-9, -9, 0}})
		godot.push_view(
			f,
			decoy,
			{kind = .Card, pos = {5, 5, 0}}, // never shown: a data-only view is not posed
			Card_Data{life = item.life, shape = toy.Shape(item.life % 3), holder = item.owner},
		)
	}
	mark := &local.last_mark
	collections: struct {
		open:   sim.Bits(10),
		recent: sim.List(sim.Handle(toy.Thing), 4),
		queue:  sim.Queue(u8, 3),
	}
	sim.incl(&collections.open, 1)
	sim.incl(&collections.open, 7)
	live := sim.iterate(&f.state.things)
	for _, thing in sim.next(&live) do sim.append(&collections.recent, thing) // full: the rest left out
	for item in ([]u8{1, 2, 3}) do sim.append(&collections.queue, item)
	sim.pop_front(&collections.queue)
	sim.append(&collections.queue, 4)
	areas: sim.List(toy.Mark_Area, 2)
	sim.append(&areas, toy.Mark_Area{corner = {1, 2}, layer = 3})
	sim.append(&areas, toy.Mark_Area{corner = {4, 5}, layer = 6})
	godot.push_data(f, Data_Toy {
		trail = local.trail,
		trail_first = ([3]f32)(local.trail.items[0]),
		trail_box = {points = local.trail},
		areas = areas,
		bumps = local.bumps,
		bump_sum = local.bump_sum,
		marks = local.marks,
		mark_at = mark.at,
		mark_normal = mark.normal,
		mark_weight = mark.weight,
		mark_count = mark.count,
		mark_shape = mark.shape,
		mark_shapes = mark.shapes,
		mark_loud = mark.loud,
		mark_target = mark.target,
		mark_place = ([3]f32)(mark.place),
		mark_area = mark.area,
		at = {local.pos.x, local.pos.y, 0},
		x = local.pos.x,
		y = local.pos.y,
		spawned = f.state.spawned,
		tint = {1, 2, 3, 4},
		turn = {0, 0, 0, 1},
		cell = {-3, 7},
		lamp = sim.entity(4),
		open = collections.open,
		recent = collections.recent,
		queue = collections.queue,
	})
	// the rotation negated every other tick (the same rotation): on the shorter arc it doesn't turn at all, so it is
	// exact at any alpha
	angle := godot.quat_turns_2d(0.25 / math.TAU) // 0.25 rad
	godot.push_multi_view(f, {
		key    = 1,
		kind   = .Multi2D,
		pos    = {3, 4, 0},
		rot    = f.tick % 2 == 0 ? -angle : angle,
		scale  = {2, 3, 0},
		color  = {1, 0.5, 0.25, 1},
		custom = {1, 2, 3, 4},
	})
	godot.push_multi_view(f, {kind = .Multi2D, pos = {-0.5, 0.75, 0}}) // no key; color zero: white; scale zero: 1
	tumble := [4]f32{math.sin(f32(TUMBLE_3D) / 2), 0, 0, math.cos(f32(TUMBLE_3D) / 2)}
	godot.push_multi_view(f, {
		key   = 2,
		kind  = .Smooth3D,
		pos   = POS_3D / VIEW_SCALE,
		rot   = godot.qmul(q3, tumble),
		scale = {1, 2, 1},
		color = {0, 1, 0, 1},
	})
}

// Expired to its thing's card (by its subject, a thing, it would reach no view; the card has gone that tick and
// lingers), Joined to none (by its subject: the player's view), the remote player's Spawned (drawn_tick) to its
// remote3d view, the rest by their subject (Spawned: the player's view, its thing having none: the decoys and cards
// have its key, not its type).
event_key :: proc(event: toy.Event, subject: godot.Subject) -> godot.Event_Target(View) {
	#partial switch value in event {
	case toy.Event_Expired:
		return godot.to_view(
			View.Card,
			sim.Handle(Decoy){index = value.thing.index, generation = value.thing.generation},
		)
	case sim.Event_Player_Joined:
		return {route = .No_View}
	case toy.Event_Spawned:
		if value.player == REMOTE_PLAYER do return godot.to_view(View.Remote3D, REMOTE_PLAYER)
	}
	return {}
}

@(export, link_name = "views_test_init")
views_test_init :: proc "c" (
	get_proc_address: godot.Get_Proc_Address,
	library: godot.Class_Library,
	init: ^godot.Initialization,
) -> godot.Init_Result {
	GAME = toy.GAME
	GAME.bench_prepare = bench_prepare
	GAME.tick = drawn_tick
	return godot.init(&GAME, GLUE, get_proc_address, library, init, constants = constants)
}

// The toy's tick with two debug draws (outside any zone: the "other" group) and the remote player's events (remote_walk).
// Never state: the session's checksums stay the offline binary's.
drawn_tick :: proc(t: ^toy.Tick) {
	toy.tick(t)
	sim.debug_line(t, sim.Position{0, 0, 0}, sim.Position{1, 1, 0}, .Green)
	sim.debug_text(t, sim.Position{1, 1, 0}, "tick %d", t.number)
	if bench_instances == 0 && t.number % REMOTE_EVENT_EVERY == REMOTE_EVENT_AT {
		sim.emit(t, toy.Event_Spawned{position = sim.Position{remote_x(t.number), 0, 0}, player = REMOTE_PLAYER})
	}
}

// Where the remote walk is at `tick` (sim units, along x).
remote_x :: proc(tick: u32) -> f32 {
	phase := tick % REMOTE_PERIOD
	return REMOTE_SPEED * f32(phase) + (REMOTE_JUMP if phase >= REMOTE_PERIOD / 2 else 0)
}

// The remote walk's views (REMOTE_PERIOD).
remote_walk :: proc(f: ^Frame) {
	item := godot.View_Item(View) {
		kind = .Remote3D,
		pos  = {remote_x(f.tick), 0, 0},
		warp = u8(f.tick / (REMOTE_PERIOD / 2)), // a teleport at each jump
	}
	data := Remote3D_Data{f.tick}
	godot.push_view(f, REMOTE_PLAYER, item, data)
	godot.push_view(f, f.local_players[0], item, data)
	predicted := item
	predicted.kind, predicted.player = .Predicted3D, REMOTE_PLAYER
	godot.push_view(f, sim.entity(REMOTE_THING), predicted)
	item.kind = .Rider3D
	item.player = REMOTE_PLAYER if f.tick % REMOTE_PERIOD < REMOTE_PERIOD / 2 else f.local_players[0]
	godot.push_view(f, sim.entity(REMOTE_THING), item)
	if f.tick >= REMOTE_BLINK_FROM && f.tick < REMOTE_BLINK_TO {
		blink := godot.View_Item(View) {
			kind = .Remote3D,
			pos  = {REMOTE_SPEED * f32(f.tick - REMOTE_BLINK_FROM), 0, 5},
		}
		godot.push_view(f, REMOTE_BLINK, blink, data)
	}
}

// Rotation about +Y by `yaw` radians (Godot's up axis).
quat_yaw_angle :: proc(yaw: f32) -> [4]f32 {
	return {0, math.sin(yaw * 0.5), 0, math.cos(yaw * 0.5)}
}
