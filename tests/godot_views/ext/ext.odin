// The unified:godot view test extension: the toy game (no physics: it also proves unified:godot links without
// Box3D) with a Glue that shows fixed 2D and 3D scene views and MultiMesh items, the toy's command counters as
// session data (Unified.data.toy) and a few constants (Unified.constants). tests/godot_views/test.gd starts a single
// player session under headless Godot (`uni test --suite godot-bindings`) and checks where the views end up, the
// data, constants, enum, event and command classes, the view lifecycle and the input sample.
package views_test_ext

import "base:runtime"
import "core:math"
import "unified:gdext/gdi"
import "unified:godot"
import "unified:sim"

import "../../toy"

View :: enum u8 {
	Typed2D,
	Plain2D,
	Plain3D,
}

MultiView :: enum u8 {
	Multi2D,
	Multi3D,
}

Frame :: godot.Frame(toy.Game, View, MultiView)

// The typed2d view's data: set as its properties, each when its bytes change. The script leaves out `pad_check` on
// purpose: the host reports the missing property as an error the suite expects.
Typed2D_Data :: struct {
	shown:     bool,
	mode:      Mode, // an enum only view data uses: an int, no class
	_pad:      [2]u8,
	hp:        i32,
	ticks:     u32, // the frame's tick: changes every frame
	charge:    f32,
	dir:       [2]f32,
	tint:      godot.Color,
	pad_check: f32,
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
}

// The constants (Unified.constants), copied at install.
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

CONSTANTS := Data_Constants {
	speed = 4.5,
	name = "toy",
	favorite = .Ring,
	sizes = {1, 2, 3, 4, 5},
	limits = {low = -1, high = 9},
	ranges = {{low = 0, high = 1}, {low = 2, high = 3}},
	by_shape = {.Dot = 0.5, .Ring = 1, .Star = 2},
}

// Fixed poses: every tick the same, so the interpolated pose is exact at any alpha. In view units (what test.gd
// expects): fill_frame pushes them in sim units (/ VIEW_SCALE) and the host maps them back.
VIEW_SCALE :: 10
POS_2D :: [3]f32{120, 80, 5} // pos.z is unused in 2D
ANGLE_2D :: 0.5
POS_3D :: [3]f32{1, 2, 3}
YAW_3D :: 0.75
TUMBLE_3D :: 0.3 // a MultiMesh instance's rotation about +X after the yaw: a full rotation, not a yaw only
BLINK_FROM :: 20 // the blink view (plain2d key 5) exists for ticks BLINK_FROM ..< BLINK_TO
BLINK_TO :: 40

GLUE := godot.Glue(toy.Game, View, MultiView) {
	sample_input = sample_input,
	fill_frame   = fill_frame,
	data         = Data,
	constants    = CONSTANTS,
	is_2d        = true,
	view_scale   = VIEW_SCALE,
	event_key    = event_key,
	input_values = Input_Values,
	bench        = bench_prepare,
}

// The view-sync benchmark (view_bench.gd, `uni view-bench`): `-- --bench N` makes every frame N moving Multi3D
// instances and BENCH_SCENE_VIEWS moving plain3d views instead of the fixed items. Set on the session thread before
// its first tick, read by fill_frame on the same thread.
BENCH_SCENE_VIEWS :: 64
bench_instances: int

bench_prepare :: proc(state: ^toy.State, world: ^toy.World, count: int) {
	bench_instances = count
}

// The benchmark's frame: the local player's typed2d view (the player's events reach it), BENCH_SCENE_VIEWS plain3d views circling, and the instances on a grid, each turning and bobbing (every value
// changes every tick, so nothing is the same as the tick before).
bench_frame :: proc(f: ^Frame) {
	godot.push_view(f, {key = 1, kind = .Typed2D, player = f.local_player})
	seconds := f32(f.tick) / toy.HZ
	for i in 0 ..< BENCH_SCENE_VIEWS {
		angle := seconds + f32(i) * math.TAU / BENCH_SCENE_VIEWS
		godot.push_view(f, {
			key  = u64(100 + i),
			kind = .Plain3D,
			pos  = {math.cos(angle), 0, math.sin(angle)},
			rot  = godot.quat_yaw(angle),
		})
	}
	side := max(int(math.sqrt(f32(bench_instances))), 1)
	for i in 0 ..< bench_instances {
		phase := seconds + f32(i) * 0.01
		godot.push_multi_view(f, {
			key    = u64(i + 1),
			kind   = .Multi3D,
			pos    = {f32(i % side) * 0.2, 0.1 * math.sin(phase), f32(i / side) * 0.2},
			rot    = godot.quat_yaw(phase),
			custom = {phase, 0, 0, 0},
		}) or_break
	}
}

// The player drifts right; pressing ui_accept spawns one thing (on the press: held, it doesn't repeat), a `Spawned`
// event with a handle, a position, the player and an enum, which expires a few dozen ticks later; Unified.input.drift
// moves it down.
sample_input :: proc(input: ^toy.Input) {
	input.dx = 2
	input.dy = i8(godot.input_values(Input_Values).drift)
	input.buttons = godot.buttons(toy.Buttons, {.Spawn = "ui_accept"})
}

// What test.gd sets on Unified.input.
Input_Values :: struct {
	drift: f32,
}

fill_frame :: proc(f: ^Frame) {
	local := sim.player_data(&f.state.players, f.local_player)
	if local == nil do return // before the local player's join tick
	if bench_instances > 0 {
		bench_frame(f)
		return
	}
	q2 := godot.quat_angle2d(ANGLE_2D)
	q3 := godot.quat_yaw(YAW_3D)
	godot.push_view(f, {
		key    = 1,
		kind   = .Typed2D,
		player = f.local_player,
		pos    = POS_2D / VIEW_SCALE,
		rot    = q2,
	}, Typed2D_Data {
		shown  = true,
		mode   = .Open,
		hp     = -3,
		ticks  = f.tick,
		charge = 0.5,
		dir    = {0.6, -0.8},
		tint   = {1, 0.5, 0.25, 1},
	})
	godot.push_view(f, {
		key    = 2,
		kind   = .Plain2D,
		entity = 7,
		pos    = (POS_2D + {10, 0, 0}) / VIEW_SCALE,
		rot    = q2,
	})
	// the same key in another kind: another view; its entity is its key
	godot.push_view(f, {
		key  = 2,
		kind = .Plain3D,
		pos  = POS_3D / VIEW_SCALE,
		rot  = q3,
	})
	if f.tick >= BLINK_FROM && f.tick < BLINK_TO {
		godot.push_view(f, {
			key  = 5,
			kind = .Plain2D,
			pos  = {-5, -5, 0},
		})
	}
	mark := &local.last_mark
	godot.push_data(f, Data_Toy {
		bumps       = local.bumps,
		bump_sum    = local.bump_sum,
		marks       = local.marks,
		mark_at     = mark.at,
		mark_normal = mark.normal,
		mark_weight = mark.weight,
		mark_count  = mark.count,
		mark_shape  = mark.shape,
		mark_shapes = mark.shapes,
		mark_loud   = mark.loud,
		mark_target = mark.target,
		mark_place  = ([3]f32)(mark.place),
		mark_area   = mark.area,
		at          = {local.pos.x, local.pos.y, 0},
		x           = local.pos.x,
		y           = local.pos.y,
		spawned     = f.state.spawned,
		tint        = {1, 2, 3, 4},
		turn        = {0, 0, 0, 1},
		cell        = {-3, 7},
	})
	// the rotation negated every other tick (the same rotation): on the shorter arc it doesn't turn at all, so it is
	// exact at any alpha
	angle := godot.quat_angle2d(0.25)
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
		kind  = .Multi3D,
		pos   = POS_3D / VIEW_SCALE,
		rot   = godot.qmul(q3, tumble),
		scale = {1, 2, 1},
		color = {0, 1, 0, 1},
	})
}

// Expired to the plain2d view keyed 2 (by its subject, a thing, it would reach no view), Joined to none (by its
// subject: the player's view), the rest by their subject (Spawned: the player's view, its thing having none).
event_key :: proc(event: ^sim.Raw_Event, subject: godot.Subject) -> (kind: View, key: u64, route: godot.Event_Route) {
	#partial switch _ in sim.event_value(event, toy.Event) {
	case toy.Event_Expired:
		return .Plain2D, 2, .View
	case sim.Event_Player_Joined:
		return {}, 0, .No_View
	}
	return
}

@(export, link_name = "views_test_init")
views_test_init :: proc "c" (
	get_proc_address: gdi.InterfaceGetProcAddress,
	library: gdi.ClassLibraryPtr,
	init: ^gdi.Initialization,
) -> gdi.Bool {
	context = runtime.default_context()
	return godot.init(&toy.GAME, GLUE, get_proc_address, library, init)
}
