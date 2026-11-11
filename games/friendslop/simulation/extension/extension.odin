// friendslop's GDExtension (game/friendslop.gdextension -> .out/bin/libfriendslop.*): the friendslop sim run by
// unified:godot_host, plus the game's glue: views, the HUD, and how the InputMap and the camera become an Input.
// Built by `uni build friendslop`.
package friendslop_extension

import "base:runtime"
import "core:math"
import "unified:b3"
import "unified:eos"
import gd "unified:gdext"
import "unified:gdext/gdi"
import gh "unified:godot_host"
import "unified:netcode"
import "unified:physics"
import "unified:sim"
import "unified:view"

import fs "../friendslop"

S :: fs.State

@(export, link_name = "friendslop_init")
friendslop_init :: proc "c" (
	gpa: gdi.InterfaceGetProcAddress,
	lib: gdi.ClassLibraryPtr,
	init: ^gdi.Initialization,
) -> gdi.Bool {
	context = runtime.default_context()
	gh.install(&fs.GAME, GLUE)
	gh.set_transport(&EOS_TRANSPORT)
	return gh.entry(gpa, lib, init)
}

// ---- online play: EOS (lobby codes, P2P with Epic relays), through godot_host's transport interface

// Game + net protocol version: lobby search only finds lobbies of the same bucket.
BUCKET :: "friendslop/3"
#assert(netcode.PROTOCOL_VERSION == 7, "netcode protocol changed: bump BUCKET with it")

@(private)
eos_init :: proc(ev: ^gh.Transport_Events) -> bool {
	if eos.init({product_name = "friendslop", product_version = "0.1"}) do return true
	ev.fail(ev.ctx, eos.status().detail)
	return false
}

EOS_TRANSPORT := gh.Transport {
	name = "EOS",
	open_host = proc(_: rawptr, ev: ^gh.Transport_Events) -> (netcode.Link, bool) {
		if !eos_init(ev) do return {}, false
		l, ok := eos.open_host(BUCKET)
		if !ok do ev.fail(ev.ctx, eos.status().detail)
		return l, ok
	},
	open_join = proc(_: rawptr, code: string, ev: ^gh.Transport_Events) -> (netcode.Link, bool) {
		if !eos_init(ev) do return {}, false
		l, ok := eos.open_join(BUCKET, code)
		if !ok do ev.fail(ev.ctx, eos.status().detail)
		return l, ok
	},
	pump = proc(_: rawptr, ev: ^gh.Transport_Events) {
		r := eos.pump()
		if r.code != "" do ev.code(ev.ctx, r.code)
		if r.failed != "" do ev.fail(ev.ctx, r.failed)
	},
	close = proc(_: rawptr) {eos.close()},
	main_frame = proc(_: rawptr) {eos.pump_main_run_loop()},
	shutdown = proc(_: rawptr) {eos.shutdown()},
}

// ---- glue

// Scene views (res://game/views/<kind>.tscn). Every sim object the level placed (items, platforms, bells, plates,
// switches) is a "marker" view: entity = its level marker index + 1, and the view adopts that marker's visuals.
SCENE_PLAYER :: 0
SCENE_MARKER :: 1

BUTTON_JUMP :: 0
BUTTON_GRAB :: 1
BUTTON_THROW :: 2

// Input vectors the camera sets (UnifiedSession.set_input_vector): its look direction and its flat right.
VEC_LOOK :: 0
VEC_RIGHT :: 1

GLUE := gh.Glue(fs.State, fs.Input, fs.World) {
	scenes = {{"player", Player_View}, {name = "marker"}},
	scene_dir = "res://game/views",
	actions = {move = {"move_left", "move_right", "move_forward", "move_back"}, buttons = {"jump", "grab", "throw"}},
	extract = extract,
	sample = sample,
	scripted = proc(seed: u64, slot: int, tick: u32, state: ^S) -> fs.Input {
		return fs.script(seed, slot, tick, state)
	},
	hud = hud,
	constants = constants,
	event_key = event_key,
	level = "res://game/levels/park.level",
}

PLAYER_KEY :: 1 // + slot
MARKER_KEY :: 0x100 // + marker index

// Player events (slot set) go to that player's view; the rest carry entity = marker index + 1.
event_key :: proc(e: sim.Event) -> view.Key {
	if e.slot != sim.NO_SLOT do return view.Key(PLAYER_KEY + int(e.slot))
	if e.entity >= 1 do return view.Key(MARKER_KEY + int(e.entity) - 1)
	return 0
}

// ---- input (session thread): move relative to the camera, aim = the camera's look

sample :: proc(a: gh.Actions, slot: int, tick: u32, state: ^S) -> fs.Input {
	look := a.vectors[VEC_LOOK]
	right := a.vectors[VEC_RIGHT]
	if look == {} do look = {0, 0, -1}
	if right == {} do right = {1, 0, 0}
	flat := norm2({look.x, look.z})
	r := norm2({right.x, right.z})
	// get_vector: x right, y back (Godot's forward is -Z); the camera's forward is `flat`.
	mx := r.x * a.move.x - flat.x * a.move.y
	mz := r.y * a.move.x - flat.y * a.move.y
	l := len3(look)
	in_ := fs.Input {
		move_x = q8(mx),
		move_z = q8(mz),
		aim_x  = q8(look.x / l),
		aim_y  = q8(look.y / l),
		aim_z  = q8(look.z / l),
	}
	if a.held & (1 << BUTTON_JUMP) != 0 || a.pressed & (1 << BUTTON_JUMP) != 0 do in_.buttons |= fs.BUTTON_JUMP
	if a.held & (1 << BUTTON_GRAB) != 0 || a.pressed & (1 << BUTTON_GRAB) != 0 do in_.buttons |= fs.BUTTON_GRAB
	if a.held & (1 << BUTTON_THROW) != 0 do in_.buttons |= fs.BUTTON_THROW
	return in_
}

q8 :: proc(x: f32) -> i8 {
	return i8(clamp(x, -1, 1) * 127)
}

norm2 :: proc(v: [2]f32) -> [2]f32 {
	l := v.x * v.x + v.y * v.y
	if l < 1e-8 do return {0, -1}
	s := 1 / sqrt(l)
	return {v.x * s, v.y * s}
}

len3 :: proc(v: [3]f32) -> f32 {
	l := sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	return l > 1e-6 ? l : 1
}

sqrt :: proc(x: f32) -> f32 {
	return math.sqrt(x)
}

// ---- frame extraction (session thread)

// The player view's data (Scene_Kind.data): set as its properties when it changes.
Player_View :: struct {
	limp:    bool, // stunned or held: the body tips over
	holding: bool,
	_pad:    [2]u8,
	charge:  f32, // throw charge 0..1
}

extract :: proc(cur, prev: ^S, w: ^fs.World, out: ^gh.Frame) {
	for p in 0 ..< fs.MAX_PLAYERS {
		pl := &cur.players[p]
		if !pl.active do continue
		gh.push_scene(
			out,
			{
				key = view.Key(PLAYER_KEY + p),
				kind = SCENE_PLAYER,
				slot = i8(p),
				entity = u32(p + 1),
				pos = physics.position(w.phys, pl.mover.body),
				rot = fs.yaw_quat(pl.facing),
			},
			Player_View {
				limp = pl.stun > 0 || pl.held_by != 0,
				holding = pl.held_kind != .None,
				charge = f32(pl.charge) / f32(fs.THROW_CHARGE_TICKS),
			},
		)
	}
	add_body :: proc(out: ^gh.Frame, w: ^fs.World, body: physics.Body_Ref, marker: int) {
		if body.index1 == 0 do return
		id := physics.body_id(w.phys, body)
		p := b3.body_get_position(id)
		q := b3.body_get_rotation(id)
		gh.push_scene(
			out,
			{
				key = view.Key(MARKER_KEY + marker),
				kind = SCENE_MARKER,
				slot = -1,
				entity = u32(marker + 1),
				pos = {p.x, p.y, p.z},
				rot = q,
			},
		)
	}
	add_static :: proc(out: ^gh.Frame, pos: [3]f32, rot: [4]f32, marker: int) {
		gh.push_scene(
			out,
			{
				key = view.Key(MARKER_KEY + marker),
				kind = SCENE_MARKER,
				slot = -1,
				entity = u32(marker + 1),
				pos = pos,
				rot = rot,
			},
		)
	}
	for i in 0 ..< w.n_items {
		if cur.items[i].alive do add_body(out, w, cur.items[i].body, w.items[i].marker)
	}
	for i in 0 ..< w.n_platforms do add_body(out, w, cur.platforms[i].body, w.platforms[i].marker)
	for i in 0 ..< w.n_triggers {
		m := w.triggers[i].marker
		add_static(out, w.triggers[i].vol.pos, w.lvl.markers[m].rot, m)
	}
	(^fs.Hud)(&out.hud[0])^ = fs.hud(cur, out.tick)
}

#assert(size_of(fs.Hud) <= gh.HUD_BYTES)

// ---- HUD (main thread)

hud :: proc(f: ^gh.Frame, d: ^gd.Dictionary) {
	h: fs.Hud
	if f != nil do h = (^fs.Hud)(&f.hud[0])^
	gd.dict_set(d, "phase", fs.PHASE_NAMES[h.phase])
	gd.dict_set(d, "tick", i64(h.tick))
	gd.dict_set(d, "run_s", f64(h.run_s))
	gd.dict_set(d, "best_s", f64(h.best_s))
	gd.dict_set(d, "runs", i64(h.runs))
	gd.dict_set(d, "checkpoint", i64(h.checkpoint))
	gd.dict_set(d, "reset_in_s", f64(h.reset_in_s))
	gd.dict_set(d, "triggers", i64(h.triggers))
	gd.dict_set(d, "local_slot", f != nil ? i64(f.local_slot) : -1)
	players := gd.array_new()
	if f != nil {
		for &p, slot in h.players {
			pd := gd.dict_new()
			gd.dict_set(&pd, "slot", i64(slot))
			gd.dict_set(&pd, "present", p.present)
			gd.dict_set(&pd, "holding", i64(p.holding))
			gd.dict_set(&pd, "held", p.held)
			gd.dict_set(&pd, "stunned", p.stunned)
			gd.dict_set(&pd, "fallen", p.fallen)
			gd.dict_set(&pd, "charge", f64(p.charge))
			if name := gh.frame_player_name(f, slot); name != "" do gd.dict_set(&pd, "name", name)
			gd.array_push_move(&players, &pd)
		}
	}
	gd.dict_set_move(d, "players", &players)
}

// ---- constants for the scripts (UnifiedSession.constants()), from the sim's own definitions

constants :: proc(d: ^gd.Dictionary) {
	gd.dict_set(d, "finish_hold_s", f64(fs.FINISH_HOLD_S))
	gd.dict_set(d, "respawn_s", f64(fs.RESPAWN_S))
	gd.dict_set(d, "feet", f64(fs.FEET))
	gd.dict_set(d, "player_radius", f64(fs.PLAYER_RADIUS))
	gd.dict_set(d, "player_half_height", f64(fs.PLAYER_HALF_HEIGHT))
	sizes := gd.dict_new()
	for spec, kind in fs.ITEM_SPECS {
		size := spec.half == {} ? [3]f32{spec.radius, spec.radius, spec.radius} * 2 : spec.half * 2
		gd.dict_set(&sizes, fs.ITEM_KIND_NAMES[kind], gd.Vector3{size.x, size.y, size.z})
	}
	gd.dict_set_move(d, "item_sizes", &sizes)
}
