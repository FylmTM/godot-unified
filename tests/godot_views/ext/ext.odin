// The godot_host view test extension: the toy game (no physics: it also proves godot_host links without
// Box3D) with a Glue that shows fixed 2D and 3D scene and bulk items. tests/godot_views/test.gd starts a single
// player session under headless Godot (`python tools/dev.py godot-test`) and checks where the views end up.
package views_test_ext

import "base:runtime"
import "unified:gdext/gdi"
import gh "unified:godot_host"
import "unified:view"

import "../../toy"

// Fixed poses (has_prev with the same pose: the interpolated pose is exact at any alpha).
POS_2D :: [3]f32{120, 80, 5} // pos.z is unused in 2D
ANGLE_2D :: 0.5
POS_3D :: [3]f32{1, 2, 3}
YAW_3D :: 0.75

GLUE := gh.Glue(toy.State, toy.Input, toy.World) {
	scene_kinds = {"typed2d", "plain2d", "plain3d"},
	scene_dir = "res://views",
	bulk_kinds = {"bulk2d", "bulk3d"},
	smoothing = {tau_s = 0.1, teleport_dist = 64},
	extract = proc(cur, prev: ^toy.State, w: ^toy.World, out: ^gh.Frame) {
		q2 := view.quat_angle2d(ANGLE_2D)
		q3 := view.quat_yaw(YAW_3D)
		out.scene[0] = {
			key      = 1,
			kind     = 0,
			slot     = 0,
			has_prev = true,
			pos      = POS_2D,
			rot      = q2,
			prev_pos = POS_2D,
			prev_rot = q2,
		}
		out.scene[1] = {
			key    = 2,
			kind   = 1,
			slot   = -1,
			entity = 7,
			pos    = POS_2D + {10, 0, 0},
			rot    = q2,
		}
		out.scene[2] = {
			key    = 3,
			kind   = 2,
			slot   = -1,
			entity = 8,
			pos    = POS_3D,
			rot    = q3,
		}
		out.n_scene = 3
		out.bulk[0] = {
			kind     = 0,
			has_prev = true,
			pos      = {30, 40, 0},
			prev_pos = {30, 40, 0},
			yaw      = 0.25,
			scale    = 2,
			color    = {1, 0.5, 0.25, 1},
			custom   = {1, 2, 3, 4},
		}
		// color zero: white; scale zero: 1
		out.bulk[1] = {
			kind = 0,
			pos  = {-5, 6, 0},
		}
		out.bulk[2] = {
			kind  = 1,
			pos   = POS_3D,
			yaw   = YAW_3D,
			scale = 1,
			color = {0, 1, 0, 1},
		}
		out.n_bulk = 3
	},
	sample = proc(a: gh.Actions, slot: int, tick: u32, state: ^toy.State) -> toy.Input {return {}},
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
