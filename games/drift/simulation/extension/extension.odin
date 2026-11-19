// drift's GDExtension (game/drift.gdextension -> .out/bin/libdrift.*): the drift sim run by unified:godot,
// plus the game's glue (the view contract, games/drift/README.md, View contract): 2D scene and MultiMesh views and
// their typed data (frame.odin), the HUD's session data (hud.odin, Unified.data.hud), the constants
// (Unified.constants), and how the InputMap and the aim become an Input (input.odin). Built by `uni build drift`.
package extension

import "unified:eos"
import "unified:godot"

import g "../drift"

@(export, link_name = "drift_init")
drift_init :: proc "c" (
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
	is_2d        = true,
	view_scale   = 32, // pixels per metre: the scale the art and the level are drawn at (the host maps positions)
	event_key    = event_key,
	input_values = Input_Values,
}

// ---- the constants for the scripts (Unified.constants), from the sim's own definitions

// Sizes in metres (the views draw them at Unified.view_scale).
Data_Constants :: struct {
	ship_radius:    f32,
	station_radius: f32,
	gate_radius:    f32,
	station_hp:     i32, // full: the HUD's bar
	station_spin:   f32, // rad/s: the menu's station turns like the match's
	station_shape:  [6][2]f32, // the station's hexagon, its 6 corners at radius 1 (an Array of Vector2s)
	rock_shapes:    [g.ROCK_VARIANTS][8][2]f32, // per variant the 8 corners at radius 1 (an Array of Vector2s)
}

// godot.init calls it once. The shapes are the ones the sim builds its bodies from (the station's hexagon; a rock's
// convex hull, scaled by its radius), at radius 1.
constants :: proc() -> Data_Constants {
	constants := Data_Constants {
		ship_radius    = g.SHIP_RADIUS,
		station_radius = g.STATION_RADIUS,
		gate_radius    = g.GATE_RADIUS,
		station_hp     = g.STATION_HP,
		station_spin   = g.STATION_SPIN,
		station_shape  = g.HEXAGON,
	}
	small := g.ROCK_STATS[.Small].radius
	for variant in 0 ..< g.ROCK_VARIANTS {
		for corner, k in g.rock_points(variant, .Small) do constants.rock_shapes[variant][k] = corner / small
	}
	return constants
}
