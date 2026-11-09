// The godot_host view test extension: the toy game (no physics: it also proves godot_host links without
// Box3D) with a Glue that shows fixed 2D and 3D scene and bulk items, and the toy's command counters in the
// HUD. tests/godot_views/test.gd starts a single player session under headless Godot (`python tools/dev.py
// godot-test`) and checks where the views end up and what send_command delivers.
package views_test_ext

import "base:runtime"
import "core:math"
import gd "unified:gdext"
import "unified:gdext/gdi"
import gh "unified:godot_host"
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

GLUE := gh.Glue(toy.State, toy.Input, toy.World) {
	scenes = {{name = "typed2d", data = Typed2D_Data}, {name = "plain2d"}, {name = "plain3d"}},
	scene_dir = "res://views",
	bulk_kinds = {"bulk2d", "bulk3d"},
	smoothing = {tau_s = 0.1, teleport_dist = 64},
	extract = proc(cur, prev: ^toy.State, w: ^toy.World, out: ^gh.Frame) {
		q2 := view.quat_angle2d(ANGLE_2D)
		q3 := view.quat_yaw(YAW_3D)
		gh.push_scene(
			out,
			{key = 1, kind = 0, slot = 0, has_prev = true, pos = POS_2D, rot = q2, prev_pos = POS_2D, prev_rot = q2},
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
		gh.push_scene(out, {key = 2, kind = 1, slot = -1, entity = 7, pos = POS_2D + {10, 0, 0}, rot = q2})
		gh.push_scene(out, {key = 3, kind = 2, slot = -1, entity = 8, pos = POS_3D, rot = q3})
		// prev_yaw a full turn away: the shorter arc is no turn at all, so the rotation is exact at any alpha
		gh.push_bulk(
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
		gh.push_bulk(out, {kind = 0, pos = {-5, 6, 0}}) // color zero: white; scale zero: 1
		gh.push_bulk(out, {kind = 1, pos = POS_3D, yaw = YAW_3D, scale = {1, 2, 1}, color = {0, 1, 0, 1}})
		(^Hud)(&out.hud[0])^ = {cur.bumps[0], cur.bump_sum[0], cur.marks[0], cur.last_mark[0]}
	},
	hud = proc(f: ^gh.Frame, d: ^gd.Dictionary) {
		h: Hud
		if f != nil do h = (^Hud)(&f.hud[0])^
		m := &h.mark
		gd.dict_set(d, "bumps", i64(h.bumps))
		gd.dict_set(d, "bump_sum", i64(h.bump_sum))
		gd.dict_set(d, "marks", i64(h.marks))
		gd.dict_set(d, "mark_at", gd.Vector2{m.at.x, m.at.y})
		gd.dict_set(d, "mark_normal", gd.Vector3{m.normal.x, m.normal.y, m.normal.z})
		gd.dict_set(d, "mark_weight", f64(m.weight))
		gd.dict_set(d, "mark_count", i64(m.count))
		gd.dict_set(d, "mark_shape", i64(m.shape))
		gd.dict_set(d, "mark_shapes", i64(transmute(u8)m.shapes))
		gd.dict_set(d, "mark_loud", m.loud)
	},
	sample = proc(a: gh.Actions, slot: int, tick: u32, state: ^toy.State) -> toy.Input {return {}},
}

// The local player's (slot 0) command counters, for the HUD Dictionary.
Hud :: struct {
	bumps:    u32,
	bump_sum: i32,
	marks:    u32,
	mark:     toy.Cmd_Mark,
}

@(export, link_name = "views_test_init")
views_test_init :: proc "c" (
	gpa: gdi.InterfaceGetProcAddress,
	lib: gdi.ClassLibraryPtr,
	init: ^gdi.Initialization,
) -> gdi.Bool {
	context = runtime.default_context()
	gh.install(&toy.GAME, GLUE)
	return gh.entry(gpa, lib, init)
}
