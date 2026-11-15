// The unified:godot view test extension: the toy game (no physics: it also proves unified:godot links without
// Box3D) with a Glue that shows fixed 2D, 3D and Control scene views and MultiMesh items, and the toy's command
// counters in a HUD view. tests/godot_views/test.gd starts a single player session under headless Godot
// (`uni test --suite godot-bindings`) and checks where the views end up, the event and command classes and the
// input sample.
package views_test_ext

import "base:runtime"
import "core:math"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:godot"
import "unified:sim"
import "unified:view"

import "../../toy"

View :: enum u8 {
	Typed2D,
	Plain2D,
	Plain3D,
	Hud,
}

MultiView :: enum u8 {
	Multi2D,
	Multi3D,
}

Frame :: godot.Frame(toy.State, toy.World, View, MultiView)

// The typed2d view's data: set as its properties, each when its bytes change.
Typed2D_Data :: struct {
	shown:  bool,
	mode:   Mode,
	_pad:   [2]u8,
	hp:     i32,
	ticks:  u32, // the frame's tick: changes every frame
	charge: f32,
	dir:    [2]f32,
	tint:   [4]f32,
}

Mode :: enum u8 {
	Idle,
	Open,
}

// The HUD view's data (player 0's command counters and position): more than 64 bytes.
Hud_Data :: struct {
	bumps:       u32,
	bump_sum:    i32,
	marks:       u32,
	mark_at:     [2]f32,
	mark_normal: [3]f32,
	mark_weight: f32,
	mark_count:  i16,
	mark_shape:  toy.Shape,
	mark_shapes: u8,
	mark_loud:   bool,
	x:           f32,
	y:           f32,
	spawned:     u32,
	pad_check:   [4]f32,
	tint:        gd.Vector4, // Godot's own types: as they are (a plain [4]f32 is a Color)
	turn:        gd.Quaternion,
}

HUD_KEY :: view.Key(100)

// Fixed poses: every tick the same, so the interpolated pose is exact at any alpha.
POS_2D :: [3]f32{120, 80, 5} // pos.z is unused in 2D
ANGLE_2D :: 0.5
POS_3D :: [3]f32{1, 2, 3}
YAW_3D :: 0.75

GLUE := godot.Glue(toy.State, toy.Input, toy.World, View, MultiView) {
	sample_input = sample_input,
	fill_frame = fill_frame,
	smoothing = {tau_s = 0.1, teleport_dist = 64},
	is_2d = true,
	event_pos = event_pos,
}

// The player drifts right; ui_accept pressed spawns one thing (a `Spawned` event with a handle, a position, the
// player and an enum), which expires a few dozen ticks later; the input value "drift" moves it down.
sample_input :: proc(input: ^toy.Input) {
	input.dx = 2
	input.dy = i8(godot.input_value("drift").x)
	input.buttons = u8(godot.action_pressed("ui_accept"))
}

fill_frame :: proc(frame: ^Frame) {
	state := frame.state
	q2 := view.quat_angle2d(ANGLE_2D)
	q3 := view.quat_yaw(YAW_3D)
	godot.push_view(frame, {
		key    = 1,
		kind   = .Typed2D,
		player = 0,
		pos    = POS_2D,
		rot    = q2,
	}, Typed2D_Data {
		shown  = true,
		mode   = .Open,
		hp     = -3,
		ticks  = frame.tick,
		charge = 0.5,
		dir    = {0.6, -0.8},
		tint   = {1, 0.5, 0.25, 1},
	})
	godot.push_view(frame, {
		key    = 2,
		kind   = .Plain2D,
		entity = 7,
		pos    = POS_2D + {10, 0, 0},
		rot    = q2,
	})
	godot.push_view(frame, {
		key    = 3,
		kind   = .Plain3D,
		entity = 8,
		pos    = POS_3D,
		rot    = q3,
	})
	mark := &state.last_mark[0]
	godot.push_view(frame, {key = HUD_KEY, kind = .Hud}, Hud_Data {
		bumps       = state.bumps[0],
		bump_sum    = state.bump_sum[0],
		marks       = state.marks[0],
		mark_at     = mark.at,
		mark_normal = mark.normal,
		mark_weight = mark.weight,
		mark_count  = mark.count,
		mark_shape  = mark.shape,
		mark_shapes = transmute(u8)mark.shapes,
		mark_loud   = mark.loud,
		x           = state.pos[0].x,
		y           = state.pos[0].y,
		spawned     = state.spawned,
		pad_check   = {1, 2, 3, 4},
		tint        = {1, 2, 3, 4},
		turn        = {0, 0, 0, 1},
	})
	// the yaw a full turn away every other tick: the shorter arc is no turn at all, so the rotation is exact at any
	// alpha
	godot.push_multi(frame, {
		key    = 1,
		kind   = .Multi2D,
		pos    = {30, 40, 0},
		yaw    = 0.25 + (frame.tick % 2 == 0 ? math.TAU : 0),
		scale  = {2, 3, 0},
		color  = {1, 0.5, 0.25, 1},
		custom = {1, 2, 3, 4},
	})
	godot.push_multi(frame, {kind = .Multi2D, pos = {-5, 6, 0}}) // no key; color zero: white; scale zero: 1
	godot.push_multi(frame, {
		key   = 2,
		kind  = .Multi3D,
		pos   = POS_3D,
		yaw   = YAW_3D,
		scale = {1, 2, 1},
		color = {0, 1, 0, 1},
	})
}

// The toy's {x, 0, y} (sim units) to the view's pixels: ×10 on the plane.
event_pos :: proc(position: sim.Position, world: ^toy.World) -> sim.Position {
	return {position.x * 10, position.z * 10, 0}
}

@(export, link_name = "views_test_init")
views_test_init :: proc "c" (
	get_proc_address: gdi.InterfaceGetProcAddress,
	library: gdi.ClassLibraryPtr,
	init: ^gdi.Initialization,
) -> gdi.Bool {
	context = runtime.default_context()
	godot.install(&toy.GAME, GLUE)
	return godot.entry(get_proc_address, library, init)
}
