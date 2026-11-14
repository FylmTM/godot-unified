// friendslop's GDExtension (game/friendslop.gdextension -> .out/bin/libfriendslop.*): the friendslop sim run by
// unified:godot_host, plus the game's glue: views, the HUD, and how the InputMap and the camera become an Input.
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

// ---- online play: EOS (lobby codes, P2P with Epic relays), through godot_host's transport interface

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

// ---- glue

// Scene views (res://game/views/<kind>.tscn). Every sim object the level placed (items, platforms, bells, plates,
// switches) is a "marker" view: entity = its level marker index + 1 (the `entity` of its events), and the view
// adopts that marker's visuals.
SCENE_PLAYER :: 0
SCENE_MARKER :: 1

BUTTON_JUMP :: 0
BUTTON_GRAB :: 1
BUTTON_THROW :: 2

// Input vectors the camera sets (UnifiedSession.set_input_vector): its look direction and its flat right.
VECTOR_LOOK :: 0
VECTOR_RIGHT :: 1

GLUE := godot.Glue(fs.State, fs.Input, fs.World) {
	scenes = {{"player", Player_View}, {name = "marker"}},
	scene_dir = "res://game/views",
	actions = {move = {"move_left", "move_right", "move_forward", "move_back"}, buttons = {"jump", "grab", "throw"}},
	extract = extract,
	poll_input = poll_input,
	scripted_input = fs.scripted_input,
	hud = hud,
	constants = constants,
	event_key = event_key,
	level = "res://game/levels/park.level",
}

PLAYER_KEY :: 1 // + player
MARKER_KEY :: 0x100 // + marker index

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

// ---- input (session thread): move relative to the camera, aim = the camera's look

poll_input :: proc(actions: godot.Actions, player: int, tick: u32, state: ^fs.State) -> fs.Input {
	look := actions.vectors[VECTOR_LOOK]
	right := actions.vectors[VECTOR_RIGHT]
	if look == {} do look = {0, 0, -1}
	if right == {} do right = {1, 0, 0}
	forward := normalize2({look.x, look.z})
	flat_right := normalize2({right.x, right.z})
	// get_vector: x right, y back (Godot's forward is -Z); the camera's forward is `forward`.
	move_x := flat_right.x * actions.move.x - forward.x * actions.move.y
	move_z := flat_right.y * actions.move.x - forward.y * actions.move.y
	look_length := length3(look)
	input := fs.Input {
		move_x = quantize(move_x),
		move_z = quantize(move_z),
		aim_x  = quantize(look.x / look_length),
		aim_y  = quantize(look.y / look_length),
		aim_z  = quantize(look.z / look_length),
	}
	if actions.held & (1 << BUTTON_JUMP) != 0 || actions.pressed & (1 << BUTTON_JUMP) != 0 {
		input.buttons |= fs.BUTTON_JUMP
	}
	if actions.held & (1 << BUTTON_GRAB) != 0 || actions.pressed & (1 << BUTTON_GRAB) != 0 {
		input.buttons |= fs.BUTTON_GRAB
	}
	if actions.held & (1 << BUTTON_THROW) != 0 do input.buttons |= fs.BUTTON_THROW
	return input
}

// -1..1 to an i8 axis.
quantize :: proc(x: f32) -> i8 {
	return i8(clamp(x, -1, 1) * 127)
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

// ---- frame extraction (session thread)

// The player view's data (Scene_Kind.data): set as its properties when it changes.
Player_View :: struct {
	limp:    bool, // stunned or held: the body tips over
	holding: bool,
	_pad:    [2]u8,
	charge:  f32, // throw charge 0..1
}

extract :: proc(current, previous: ^fs.State, world: ^fs.World, out: ^godot.Frame) {
	for player in 0 ..< fs.PLAYERS {
		character := &current.players[player]
		if !character.active do continue
		godot.push_scene(
			out,
			{
				key = view.Key(PLAYER_KEY + player),
				kind = SCENE_PLAYER,
				player = i8(player),
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
	add_body :: proc(out: ^godot.Frame, world: ^fs.World, body: physics.Body_Ref, marker: int) {
		if body.index1 == 0 do return
		id := physics.body_id(world.phys, body)
		pos := b3.body_get_position(id)
		godot.push_scene(
			out,
			{
				key = view.Key(MARKER_KEY + marker),
				kind = SCENE_MARKER,
				player = -1,
				entity = fs.marker_entity(marker),
				pos = {pos.x, pos.y, pos.z},
				rot = b3.body_get_rotation(id),
			},
		)
	}
	add_static :: proc(out: ^godot.Frame, pos: [3]f32, rot: [4]f32, marker: int) {
		godot.push_scene(
			out,
			{
				key = view.Key(MARKER_KEY + marker),
				kind = SCENE_MARKER,
				player = -1,
				entity = fs.marker_entity(marker),
				pos = pos,
				rot = rot,
			},
		)
	}
	for i in 0 ..< world.item_count {
		if current.items[i].alive do add_body(out, world, current.items[i].body, world.items[i].marker)
	}
	for i in 0 ..< world.platform_count do add_body(out, world, current.platforms[i].body, world.platforms[i].marker)
	for i in 0 ..< world.trigger_count {
		marker := world.triggers[i].marker
		add_static(out, world.triggers[i].volume.pos, world.level.markers[marker].rot, marker)
	}
	(^fs.Hud)(&out.hud[0])^ = fs.hud(current, out.tick)
}

#assert(size_of(fs.Hud) <= godot.HUD_BYTES)

// ---- HUD (main thread)

hud :: proc(frame: ^godot.Frame, dict: ^gd.Dictionary) {
	state: fs.Hud
	if frame != nil do state = (^fs.Hud)(&frame.hud[0])^
	gd.dict_set(dict, "phase", fs.PHASE_NAMES[state.phase])
	gd.dict_set(dict, "tick", i64(state.tick))
	gd.dict_set(dict, "run_s", f64(state.run_s))
	gd.dict_set(dict, "best_s", f64(state.best_s))
	gd.dict_set(dict, "runs", i64(state.runs))
	gd.dict_set(dict, "checkpoint", i64(state.checkpoint))
	gd.dict_set(dict, "reset_in_s", f64(state.reset_in_s))
	gd.dict_set(dict, "triggers", i64(state.triggers))
	gd.dict_set(dict, "local_player", frame != nil ? i64(frame.local_player) : -1)
	players := gd.array_new()
	if frame != nil {
		for &hud_player, player in state.players {
			entry := gd.dict_new()
			gd.dict_set(&entry, "player", i64(player))
			gd.dict_set(&entry, "present", hud_player.present)
			gd.dict_set(&entry, "holding", i64(hud_player.holding))
			gd.dict_set(&entry, "held", hud_player.held)
			gd.dict_set(&entry, "stunned", hud_player.stunned)
			gd.dict_set(&entry, "fallen", hud_player.fallen)
			gd.dict_set(&entry, "charge", f64(hud_player.charge))
			if name := godot.frame_player_name(frame, player); name != "" do gd.dict_set(&entry, "name", name)
			gd.array_push_move(&players, &entry)
		}
	}
	gd.dict_set_move(dict, "players", &players)
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
