// friendslop's GDExtension (game/friendslop.gdextension -> .out/bin/libfriendslop.*): the friendslop sim run by
// unified:godot, plus the game's glue: views, session data, constants, and how the InputMap and the camera become an
// Input.
// Built by `uni build friendslop`.
package friendslop_extension

import "unified:dmath"
import "unified:eos"
import "unified:godot"
import "unified:physics"
import "unified:sim"

import g "../friendslop"

@(export, link_name = "friendslop_init")
friendslop_init :: proc "c" (
	gpa: godot.Get_Proc_Address,
	lib: godot.Class_Library,
	init: ^godot.Initialization,
) -> godot.Init_Result {
	// online play: EOS lobbies and P2P
	return godot.init(&g.GAME, GLUE, gpa, lib, init, eos.lobby({}), constants = constants)
}

// ---- glue

// Scene views (the view index: a scene per kind, with a UnifiedView marker). A player's view is keyed by
// sim.player_key. Every sim object the level placed (items, platforms, bells, plates, switches) is a `marker` view
// keyed by its level marker index (its events' `entity` is sim.entity of that index); the view adopts that marker's
// visuals.
View :: enum u8 {
	Player,
	Marker,
}

// No MultiMesh views.
MultiView :: enum u8 {}

Frame :: godot.Frame(g.Game, View, MultiView)

GLUE := godot.Glue(g.Game, View, MultiView) {
	sample_input = sample_input,
	fill_frame   = fill_frame,
	data         = Data,
	event_key    = event_key,
	input_values = Input_Values,
}

// An event about a player goes to that player's view. So grabbed, dropped and thrown stay with the holder's view, and
// a switch a player touched with the player's, where the default routing would send them to the item's or the
// switch's view (its `entity`: the marker view keyed by that marker's index). The rest: by their subject.
event_key :: proc(_: g.Event, subject: godot.Subject) -> (kind: View, key: u64, route: godot.Event_Route) {
	if subject.player != {} do return .Player, sim.player_key(subject.player), .View
	return
}

// ---- input (main thread): move relative to the camera, aim = the camera's look

// What the camera rig sets every frame (Unified.input.look, .right): movement is relative to them.
Input_Values :: struct {
	look:  [3]f32, // the camera's look direction
	right: [3]f32, // its flat right
}

// A jump or grab tap shorter than a frame still counts (action_down).
sample_input :: proc(input: ^g.Input) {
	values := godot.input_values(Input_Values)
	look, right := values.look, values.right
	if look == {} do look = {0, 0, -1}
	if right == {} do right = {1, 0, 0}
	forward := dmath.normalize(look.xz)
	flat_right := dmath.normalize(right.xz)
	// get_vector: x right, y back (Godot's forward is -Z); the camera's forward is `forward`.
	move := godot.action_vector("move_left", "move_right", "move_forward", "move_back")
	input.move_x = dmath.axis_i8(flat_right.x * move.x - forward.x * move.y)
	input.move_z = dmath.axis_i8(flat_right.y * move.x - forward.y * move.y)
	input.aim = dmath.dir3(look)
	input.buttons = godot.buttons(g.Buttons, {.Jump = "jump", .Grab = "grab", .Throw = "throw"})
}

// ---- the frame (session thread)

// The player view's data: set as its properties when it changes.
Player_View :: struct {
	limp:    bool, // stunned or held: the body tips over
	holding: bool,
	charge:  f32, // throw charge 0..1
}

fill_frame :: proc(f: ^Frame) {
	players := sim.iterate_present(&f.state.players)
	for character, player in sim.next(&players) {
		godot.push_view(f, player, {
			kind = .Player,
			pos  = sim.Position(physics.body_position(f.world.phys, character.controller.body)),
			rot  = dmath.quat_yaw(character.facing),
		}, Player_View {
			limp    = character.stun > 0 || character.held_by != {},
			holding = character.held_kind != .None,
			charge  = f32(character.charge) / f32(g.THROW_CHARGE_TICKS),
		})
	}
	add_body :: proc(f: ^Frame, body: physics.Body_Ref, marker: int) {
		if body.index1 == 0 do return
		godot.push_view(f, sim.entity(marker), {
			kind = .Marker,
			pos  = sim.Position(physics.body_position(f.world.phys, body)),
			rot  = physics.body_rotation(f.world.phys, body),
		})
	}
	for i in 0 ..< f.world.item_count {
		if f.state.items[i].alive do add_body(f, f.state.items[i].body, f.world.items[i].marker)
	}
	for i in 0 ..< f.world.platform_count do add_body(f, f.state.platforms[i].body, f.world.platforms[i].marker)
	for i in 0 ..< f.world.trigger_count {
		marker := f.world.triggers[i].marker
		godot.push_view(f, sim.entity(marker), {
			kind = .Marker,
			pos  = sim.Position(f.world.triggers[i].volume.pos),
			rot  = f.world.level.markers[marker].rot,
		})
	}
	godot.push_data(f, hud_of(f.state, f.tick))
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
	item_sizes:         [len(g.Item_Kind)]Item_Size, // by kind
}

// godot.init calls it once: the item sizes come from g.ITEM_SPECS.
constants :: proc() -> Data_Constants {
	constants := Data_Constants {
		feet               = g.FEET,
		player_radius      = g.PLAYER_RADIUS,
		player_half_height = g.PLAYER_HALF_HEIGHT,
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
