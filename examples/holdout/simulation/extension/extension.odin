// holdout's GDExtension (game/holdout.gdextension -> .out/bin/libholdout.*): the holdout sim run by unified:godot,
// plus the game's glue (this file) and the constants for the scripts; the view contract and the frame (frame.odin),
// how the InputMap and the camera rig become an Input (input.odin) and the HUD's session data (hud.odin). Built by
// `uni build holdout`.
package holdout_extension

import "unified:dmath"
import "unified:eos"
import "unified:godot"

import g "../holdout"

@(export, link_name = "holdout_init")
holdout_init :: proc "c" (
	get_proc_address: godot.Get_Proc_Address,
	library: godot.Class_Library,
	initialization: ^godot.Initialization,
) -> godot.Init_Result {
	// online play: EOS lobbies and P2P
	return godot.init(&g.GAME, GLUE, get_proc_address, library, initialization, eos.lobby({}), constants = constants)
}

GLUE := godot.Glue(g.Game, View, MultiView) {
	sample_input = sample_input,
	fill_frame   = fill_frame,
	data         = Data,
	// teammates on the verified timeline: a few ticks late, never corrected (src/godot/README.md)
	view_policy  = {{View_Player, {remote = .Verified}}},
	event_key    = event_key,
	input_values = Input_Values,
}

// ---- constants for the scripts (Unified.constants), from the sim's own definitions

// An enemy kind's body as the sim simulates it.
Enemy_Size :: struct {
	kind:        g.Enemy_Kind, // EnumEnemyKind
	_pad:        [3]u8,
	radius:      f32,
	half_height: f32,
	head_radius: f32,
}

Data_Constants :: struct {
	player_radius:       f32,
	player_half_height:  f32,
	eye_height:          f32, // the eye above the capsule's centre
	pitch_limit:         f32, // turns: the most the camera may look up or down (dmath.AIM_PITCH_LIMIT)
	fire_interval_ticks: i32,
	grenade_radius:      f32,
	blast_radius:        f32,
	core_hp:             i32,
	waves:               i32,
	enemy_sizes:         [len(g.Enemy_Kind)]Enemy_Size, // by kind
}

constants :: proc() -> Data_Constants {
	constants := Data_Constants {
		player_radius       = g.PLAYER_RADIUS,
		player_half_height  = g.PLAYER_HALF_HEIGHT,
		eye_height          = g.EYE_HEIGHT,
		pitch_limit         = dmath.AIM_PITCH_LIMIT,
		fire_interval_ticks = g.FIRE_INTERVAL_TICKS,
		grenade_radius      = g.GRENADE_RADIUS,
		blast_radius        = g.BLAST_RADIUS,
		core_hp             = g.CORE_HP,
		waves               = g.WAVES,
	}
	for spec, kind in g.ENEMY_SPECS {
		constants.enemy_sizes[int(kind)] = {
			kind        = kind,
			radius      = spec.radius,
			half_height = spec.half_height,
			head_radius = spec.head_radius,
		}
	}
	return constants
}
