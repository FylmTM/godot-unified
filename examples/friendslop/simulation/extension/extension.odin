// friendslop's GDExtension (game/friendslop.gdextension -> .out/bin/libfriendslop.*): the friendslop sim run by
// unified:godot, plus the game's glue (this file) and the constants for the scripts; the view contract and the frame
// (frame.odin), how the InputMap and the camera become an Input (input.odin) and the HUD's session data (hud.odin).
// Built by `uni build friendslop`.
package friendslop_extension

import "unified:eos"
import "unified:godot"

import g "../friendslop"

@(export, link_name = "friendslop_init")
friendslop_init :: proc "c" (
	get_proc_address: godot.Get_Proc_Address,
	library: godot.Class_Library,
	initialization: ^godot.Initialization,
) -> godot.Init_Result {
	// online play: EOS lobbies and P2P
	return godot.init(&g.GAME, GLUE, get_proc_address, library, initialization, eos.lobby({}), constants = constants)
}

// ---- glue

GLUE := godot.Glue(g.Game, View, MultiView) {
	sample_input = sample_input,
	fill_frame   = fill_frame,
	data         = Data,
	// an item the local player holds is drawn at their hand, at render rate (marker_view.gd)
	view_policy  = {{View_Marker, {pose = .Script}}},
	event_key    = event_key,
	input_values = Input_Values,
}

// ---- constants for the scripts (Unified.constants), from the sim's own definitions

// An item kind's size as the sim simulates it (a sphere: its diameter on every axis).
Item_Size :: struct {
	kind: g.Item_Kind, // EnumItemKind
	_pad: [3]u8,
	size: [3]f32,
}

Data_Constants :: struct {
	feet:               f32, // from the capsule centre down to the ground it stands on
	player_radius:      f32,
	player_half_height: f32,
	handle_outset:      f32, // a two-handle item's grab points are this far past its ends
	hold_dist:          f32, // a held thing is this far in front of the holder (along the facing)
	hold_up:            f32, // and this far above the capsule centre
	hold_pitch:         f32, // plus the look's pitch (its y) times this
	item_sizes:         [len(g.Item_Kind)]Item_Size, // by kind
}

// godot.init calls it once: the item sizes come from g.ITEM_SPECS.
constants :: proc() -> Data_Constants {
	constants := Data_Constants {
		feet               = g.FEET,
		player_radius      = g.PLAYER_RADIUS,
		player_half_height = g.PLAYER_HALF_HEIGHT,
		handle_outset      = g.HANDLE_OUTSET,
		hold_dist          = g.HOLD_DIST,
		hold_up            = g.HOLD_UP,
		hold_pitch         = g.HOLD_PITCH,
	}
	for spec, kind in g.ITEM_SPECS {
		size := spec.half == {} ? [3]f32{spec.radius, spec.radius, spec.radius} * 2 : spec.half * 2
		constants.item_sizes[int(kind)] = {
			kind = kind,
			size = size,
		}
	}
	return constants
}
