// friendslop's GDExtension (game/friendslop.gdextension -> .out/bin/libfriendslop.*): the friendslop sim run by
// unified:godot, plus the game's glue: views, the HUD view, and how the InputMap and the camera become an Input.
// Built by `uni build friendslop`.
package friendslop_extension

import "base:runtime"
import "core:math"
import "core:reflect"
import "unified:b3"
import "unified:eos"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:godot"
import "unified:netcode"
import "unified:physics"
import "unified:sim"
import "unified:view"

import fs "../friendslop"

@(export, link_name = "friendslop_init")
friendslop_init :: proc "c" (
	gpa: gdi.InterfaceGetProcAddress,
	lib: gdi.ClassLibraryPtr,
	init: ^gdi.Initialization,
) -> gdi.Bool {
	context = runtime.default_context()
	godot.install(&fs.GAME, GLUE)
	godot.set_transport(&EOS_TRANSPORT)
	return godot.entry(gpa, lib, init)
}

// ---- online play: EOS (lobby codes, P2P with Epic relays), through unified:godot's transport interface

// Game + net protocol version: lobby search only finds lobbies of the same bucket.
BUCKET :: "friendslop/5"
#assert(netcode.PROTOCOL_VERSION == 9, "netcode protocol changed: bump BUCKET with it")

@(private)
eos_init :: proc(events: ^godot.Transport_Events) -> bool {
	if eos.init({product_name = "friendslop", product_version = "0.1"}) do return true
	events.fail(events.ctx, eos.status().detail)
	return false
}

EOS_TRANSPORT := godot.Transport {
	name = "EOS",
	open_host = proc(_: rawptr, events: ^godot.Transport_Events) -> (netcode.Link, bool) {
		if !eos_init(events) do return {}, false
		link, ok := eos.open_host(BUCKET)
		if !ok do events.fail(events.ctx, eos.status().detail)
		return link, ok
	},
	open_join = proc(_: rawptr, code: string, events: ^godot.Transport_Events) -> (netcode.Link, bool) {
		if !eos_init(events) do return {}, false
		link, ok := eos.open_join(BUCKET, code)
		if !ok do events.fail(events.ctx, eos.status().detail)
		return link, ok
	},
	pump = proc(_: rawptr, events: ^godot.Transport_Events) {
		result := eos.pump()
		if result.code != "" do events.code(events.ctx, result.code)
		if result.failed != "" do events.fail(events.ctx, result.failed)
	},
	close = proc(_: rawptr) {eos.close()},
	main_frame = proc(_: rawptr) {eos.pump_main_run_loop()},
	shutdown = proc(_: rawptr) {eos.shutdown()},
}

/// ---- glue

// Scene views (the view index: a scene per kind, with a UnifiedView marker). Every sim object the level placed
// (items, platforms, bells, plates, switches) is a `marker` view: entity = its level marker index + 1 (the
// `entity` of its events), and the view adopts that marker's visuals. The HUD view feeds Game.hud.
View :: enum u8 {
	Player,
	Marker,
	Hud,
}

// No MultiMesh views.
MultiView :: enum u8 {}

Frame :: godot.Frame(fs.State, fs.World, View, MultiView)

GLUE := godot.Glue(fs.State, fs.Input, fs.World, View, MultiView) {
	sample_input   = sample_input,
	fill_frame     = fill_frame,
	scripted_input = fs.scripted_input,
	constants      = constants,
	event_key      = event_key,
	level          = "res://game/levels/park.level",
}

PLAYER_KEY :: 1 // + player
MARKER_KEY :: 0x100 // + marker index
HUD_KEY :: 0x1000

// An event about a player goes to that player's view, else one about a level marker to the marker's view. So
// grabbed, dropped and thrown stay with the holder's view, and a switch a player touched with the player's,
// where the default routing would send them to the item's or the switch's view.
event_key :: proc(event: ^sim.Raw_Event) -> view.Key {
	value := sim.event_value(event, fs.Event)
	fields := any{&value, reflect.union_variant_typeid(value)}
	if player, ok := reflect.struct_field_value_by_name(fields, "player").(u8); ok && player != sim.NO_PLAYER {
		return view.Key(PLAYER_KEY + int(player))
	}
	if entity, ok := reflect.struct_field_value_by_name(fields, "entity").(u64); ok && entity != 0 {
		return view.Key(MARKER_KEY + int(entity) - 1)
	}
	return 0
}

// ---- input (main thread): move relative to the camera, aim = the camera's look

// The camera rig sets its look direction and its flat right every frame (UnifiedSession.set_input_value: &"look",
// &"right"); movement is relative to them. A jump or grab tap shorter than a tick still counts (action_pressed).
sample_input :: proc(input: ^fs.Input) {
	look := godot.input_value("look")
	right := godot.input_value("right")
	if look == {} do look = {0, 0, -1}
	if right == {} do right = {1, 0, 0}
	forward := normalize2({look.x, look.z})
	flat_right := normalize2({right.x, right.z})
	// get_vector: x right, y back (Godot's forward is -Z); the camera's forward is `forward`.
	move := godot.action_vector("move_left", "move_right", "move_forward", "move_back")
	look_length := length3(look)
	input.move_x = godot.axis_i8(flat_right.x * move.x - forward.x * move.y)
	input.move_z = godot.axis_i8(flat_right.y * move.x - forward.y * move.y)
	input.aim_x = godot.axis_i8(look.x / look_length)
	input.aim_y = godot.axis_i8(look.y / look_length)
	input.aim_z = godot.axis_i8(look.z / look_length)
	if godot.action_held("jump") || godot.action_pressed("jump") do input.buttons |= fs.BUTTON_JUMP
	if godot.action_held("grab") || godot.action_pressed("grab") do input.buttons |= fs.BUTTON_GRAB
	if godot.action_held("throw") do input.buttons |= fs.BUTTON_THROW
}

normalize2 :: proc(v: [2]f32) -> [2]f32 {
	length_sq := v.x * v.x + v.y * v.y
	if length_sq < 1e-8 do return {0, -1}
	scale := 1 / math.sqrt(length_sq)
	return {v.x * scale, v.y * scale}
}

length3 :: proc(v: [3]f32) -> f32 {
	length := math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	return length > 1e-6 ? length : 1
}

// ---- the frame (session thread)

// The player view's data: set as its properties when it changes.
Player_View :: struct {
	limp:    bool, // stunned or held: the body tips over
	holding: bool,
	charge:  f32, // throw charge 0..1
}

fill_frame :: proc(frame: ^Frame) {
	state, world := frame.state, frame.world
	for player in 0 ..< fs.PLAYERS {
		character := &state.players[player]
		if !character.active do continue
		godot.push_view(
			frame,
			{
				key = view.Key(PLAYER_KEY + player),
				kind = .Player,
				player = player,
				pos = physics.position(world.phys, character.controller.body),
				rot = fs.yaw_quat(character.facing),
			},
			Player_View {
				limp = character.stun > 0 || character.held_by != 0,
				holding = character.held_kind != .None,
				charge = f32(character.charge) / f32(fs.THROW_CHARGE_TICKS),
			},
		)
	}
	add_body :: proc(frame: ^Frame, body: physics.Body_Ref, marker: int) {
		if body.index1 == 0 do return
		id := physics.body_id(frame.world.phys, body)
		pos := b3.body_get_position(id)
		godot.push_view(
			frame,
			{
				key = view.Key(MARKER_KEY + marker),
				kind = .Marker,
				entity = fs.marker_entity(marker),
				pos = {pos.x, pos.y, pos.z},
				rot = b3.body_get_rotation(id),
			},
		)
	}
	for i in 0 ..< world.item_count {
		if state.items[i].alive do add_body(frame, state.items[i].body, world.items[i].marker)
	}
	for i in 0 ..< world.platform_count do add_body(frame, state.platforms[i].body, world.platforms[i].marker)
	for i in 0 ..< world.trigger_count {
		marker := world.triggers[i].marker
		godot.push_view(
			frame,
			{
				key = view.Key(MARKER_KEY + marker),
				kind = .Marker,
				entity = fs.marker_entity(marker),
				pos = world.triggers[i].volume.pos,
				rot = world.level.markers[marker].rot,
			},
		)
	}
	godot.push_view(frame, {key = HUD_KEY, kind = .Hud}, fs.hud(state, frame.tick))
}

// ---- constants for the scripts (UnifiedSession.constants()), from the sim's own definitions

constants :: proc(dict: ^gd.Dictionary) {
	gd.dict_set(dict, "finish_hold_s", f64(fs.FINISH_HOLD_S))
	gd.dict_set(dict, "respawn_s", f64(fs.RESPAWN_S))
	gd.dict_set(dict, "feet", f64(fs.FEET))
	gd.dict_set(dict, "player_radius", f64(fs.PLAYER_RADIUS))
	gd.dict_set(dict, "player_half_height", f64(fs.PLAYER_HALF_HEIGHT))
	sizes := gd.dict_new()
	for spec, kind in fs.ITEM_SPECS {
		size := spec.half == {} ? [3]f32{spec.radius, spec.radius, spec.radius} * 2 : spec.half * 2
		gd.dict_set(&sizes, fs.ITEM_KIND_NAMES[kind], gd.Vector3{size.x, size.y, size.z})
	}
	gd.dict_set_move(dict, "item_sizes", &sizes)
}
