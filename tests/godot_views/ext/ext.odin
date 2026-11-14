// The godot_host view test extension: the toy game (no physics: it also proves godot_host links without
// Box3D) with a Glue that shows fixed 2D and 3D scene and bulk items, and the toy's command counters in the
// HUD. tests/godot_views/test.gd starts a single player session under headless Godot (`uni test --suite
// godot-bindings`) and checks where the views end up and what send_command delivers.
package views_test_ext

import "base:runtime"
import "core:math"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:godot"
import "unified:sim"
import "unified:view"

import "../../toy"

// The typed2d kind's data: set as the view's properties (Scene_Kind.data), each when its bytes change.
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

// Fixed poses (has_prev with the same pose: the interpolated pose is exact at any alpha).
POS_2D :: [3]f32{120, 80, 5} // pos.z is unused in 2D
ANGLE_2D :: 0.5
POS_3D :: [3]f32{1, 2, 3}
YAW_3D :: 0.75

GLUE := godot.Glue(toy.State, toy.Input, toy.World) {
	scenes = {{name = "typed2d", data = Typed2D_Data}, {name = "plain2d"}, {name = "plain3d"}},
	scene_dir = "res://views",
	bulk_kinds = {"bulk2d", "bulk3d"},
	smoothing = {tau_s = 0.1, teleport_dist = 64},
	extract = proc(current, previous: ^toy.State, world: ^toy.World, out: ^godot.Frame) {
		q2 := view.quat_angle2d(ANGLE_2D)
		q3 := view.quat_yaw(YAW_3D)
		godot.push_scene(
			out,
			{key = 1, kind = 0, player = 0, has_prev = true, pos = POS_2D, rot = q2, prev_pos = POS_2D, prev_rot = q2},
			Typed2D_Data {
				shown = true,
				mode = .Open,
				hp = -3,
				ticks = out.tick,
				charge = 0.5,
				dir = {0.6, -0.8},
				tint = {1, 0.5, 0.25, 1},
			},
		)
		godot.push_scene(out, {key = 2, kind = 1, player = -1, entity = 7, pos = POS_2D + {10, 0, 0}, rot = q2})
		godot.push_scene(out, {key = 3, kind = 2, player = -1, entity = 8, pos = POS_3D, rot = q3})
		// prev_yaw a full turn away: the shorter arc is no turn at all, so the rotation is exact at any alpha
		godot.push_bulk(
			out,
			{
				kind = 0,
				has_prev = true,
				pos = {30, 40, 0},
				prev_pos = {30, 40, 0},
				yaw = 0.25,
				prev_yaw = 0.25 + math.TAU,
				scale = {2, 3, 0},
				color = {1, 0.5, 0.25, 1},
				custom = {1, 2, 3, 4},
			},
		)
		godot.push_bulk(out, {kind = 0, pos = {-5, 6, 0}}) // color zero: white; scale zero: 1
		godot.push_bulk(out, {kind = 1, pos = POS_3D, yaw = YAW_3D, scale = {1, 2, 1}, color = {0, 1, 0, 1}})
		(^Hud)(&out.hud[0])^ = {current.bumps[0], current.bump_sum[0], current.marks[0], current.last_mark[0]}
	},
	hud = proc(frame: ^godot.Frame, dict: ^gd.Dictionary) {
		hud: Hud
		if frame != nil do hud = (^Hud)(&frame.hud[0])^
		mark := &hud.mark
		gd.dict_set(dict, "bumps", i64(hud.bumps))
		gd.dict_set(dict, "bump_sum", i64(hud.bump_sum))
		gd.dict_set(dict, "marks", i64(hud.marks))
		gd.dict_set(dict, "mark_at", gd.Vector2{mark.at.x, mark.at.y})
		gd.dict_set(dict, "mark_normal", gd.Vector3{mark.normal.x, mark.normal.y, mark.normal.z})
		gd.dict_set(dict, "mark_weight", f64(mark.weight))
		gd.dict_set(dict, "mark_count", i64(mark.count))
		gd.dict_set(dict, "mark_shape", i64(mark.shape))
		gd.dict_set(dict, "mark_shapes", i64(transmute(u8)mark.shapes))
		gd.dict_set(dict, "mark_loud", mark.loud)
	},
	// the player drifts right and presses once at tick 5: one thing spawned (a `spawned` event with a handle, a
	// position, the player and an enum), which expires a few dozen ticks later
	poll_input = proc(actions: godot.Actions, player: int, tick: u32, state: ^toy.State) -> toy.Input {
		return {dx = 2, buttons = u8(tick == 5)}
	},
	// the toy's {x, 0, y} (sim units) to the view's pixels: ×10 on the plane
	event_pos = proc(position: sim.Position, world: ^toy.World) -> sim.Position {
		return {position.x * 10, position.z * 10, 0}
	},
}

// The local player's (player 0) command counters, for the HUD Dictionary.
Hud :: struct {
	bumps:    u32,
	bump_sum: i32,
	marks:    u32,
	mark:     toy.Cmd_Mark,
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
