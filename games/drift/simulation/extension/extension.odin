// drift's GDExtension (game/drift.gdextension -> .out/bin/libdrift.*): the drift sim run by unified:godot_host,
// plus the game's glue (the view contract, games/drift/SPEC.md "View"): 2D scene and bulk views in pixels, typed
// scene data, the HUD, constants, and how the InputMap and the aim become an Input. Built by
// `python tools/dev.py game build drift`.
package drift_extension

import "base:runtime"
import "core:math"
import "unified:eos"
import gd "unified:gdext"
import "unified:gdext/gdi"
import gh "unified:godot_host"
import "unified:netcode"
import "unified:physics"
import "unified:sim"
import "unified:view"

import dr "../drift"

S :: dr.State

@(export, link_name = "drift_init")
drift_init :: proc "c" (
	gpa: gdi.InterfaceGetProcAddress,
	lib: gdi.ClassLibraryPtr,
	init: ^gdi.Initialization,
) -> gdi.Bool {
	context = runtime.default_context()
	gh.install(&dr.GAME, GLUE)
	gh.set_transport(&EOS_TRANSPORT)
	return gh.entry(gpa, lib, init)
}

// ---- online play: EOS (lobby codes, P2P with Epic relays), through godot_host's transport interface

// Game + net protocol version: lobby search only finds lobbies of the same bucket.
BUCKET :: "drift/1"
#assert(netcode.PROTOCOL_VERSION == 6, "netcode protocol changed: bump BUCKET with it")

@(private)
eos_init :: proc(ev: ^gh.Transport_Events) -> bool {
	if eos.init({product_name = "drift", product_version = gh.app_version}) do return true
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

// ---- the view contract

// Scene views (res://game/views/<kind>.tscn), each with its typed data (set as the view's properties).
SCENE_SHIP :: 0
SCENE_STATION :: 1
SCENE_GATE :: 2

Ship_View :: struct {
	boost_ready: f32, // 0 just boosted .. 1 ready
	thrust:      bool,
	_pad:        [3]u8,
}

Station_View :: struct {
	hp_frac: f32, // 0..1
}

Gate_View :: struct {
	charge: f32, // 0 ready .. 1 just used
}

// Bulk views (MultiMeshInstance2D, TRANSFORM_2D, colors + custom data), in this order.
BULK_ROCK :: 0 // + variant (rock_0..rock_3): a unit-radius polygon mesh, scaled by the rock's radius
BULK_BULLET :: 4
BULK_GEM :: 5

// Spawn keys: ships 1 + slot, the station 100, gates 200 + index (a view lives as long as its entity).
KEY_SHIP :: 1
KEY_STATION :: 100
KEY_GATE :: 200

BUTTON_FIRE :: 0
BUTTON_BOOST :: 1

// The aim: a world-space direction the game's scripts set (UnifiedSession.set_input_vector(VEC_AIM, ...)) from
// the mouse (relative to the local ship) or the right stick; zero keeps the heading.
VEC_AIM :: 0

GLUE := gh.Glue(dr.State, dr.Input, dr.World) {
	scenes = {{"ship", Ship_View}, {"station", Station_View}, {"gate", Gate_View}},
	scene_dir = "res://game/views",
	bulk_kinds = {"rock_0", "rock_1", "rock_2", "rock_3", "bullet", "gem"},
	smoothing = {tau_s = 0.1, teleport_dist = 64}, // pixels: a warp snaps
	actions = {move = {"move_left", "move_right", "move_up", "move_down"}, buttons = {"fire", "boost"}},
	extract = extract,
	sample = sample,
	scripted = proc(seed: u64, slot: int, tick: u32, state: ^S) -> dr.Input {
		return dr.script(seed, slot, tick, state)
	},
	scripted_commands = dr.script_commands,
	hud = hud,
	constants = constants,
	event_key = event_key,
	// events in pixels too, like the views: the level's scale (World.px_per_m)
	event_pos = proc(pos: [3]f32, w: ^dr.World) -> [3]f32 {return {pos.x * w.px_per_m, pos.y * w.px_per_m, 0}},
	level = "res://game/levels/arena.level",
}

// Ship events go to that ship's view; station hits to the station; the rest have no scene view.
event_key :: proc(e: sim.Event) -> view.Key {
	if e.slot != sim.NO_SLOT do return view.Key(KEY_SHIP + int(e.slot))
	if dr.Event_Kind(e.kind) == .Station_Hit do return KEY_STATION
	return 0
}

// ---- input (session thread, the one local player)

sample :: proc(a: gh.Actions, slot: int, tick: u32, state: ^S) -> dr.Input {
	in_ := dr.Input {
		move_x = q8(a.move.x), // get_vector(left, right, up, down): +y is down, the plane's +y
		move_y = q8(a.move.y),
	}
	aim := a.vectors[VEC_AIM]
	l := math.sqrt(aim.x * aim.x + aim.y * aim.y)
	if l > 1e-4 {
		in_.aim_x = q8(aim.x / l)
		in_.aim_y = q8(aim.y / l)
	}
	if a.held & (1 << BUTTON_FIRE) != 0 || a.pressed & (1 << BUTTON_FIRE) != 0 do in_.buttons |= dr.BUTTON_FIRE
	if a.held & (1 << BUTTON_BOOST) != 0 || a.pressed & (1 << BUTTON_BOOST) != 0 do in_.buttons |= dr.BUTTON_BOOST
	return in_
}

q8 :: proc(x: f32) -> i8 {
	return i8(clamp(x, -1, 1) * 127)
}

// ---- frame extraction (session thread): metres -> pixels (the level's px_per_m)

// The previous tick's pose of physics-driven bulk items (rocks): Box3D holds only the current tick, so extract
// remembers what it showed for tick − 1, by table slot and generation.
Rock_Seen :: struct {
	tick:       u32,
	generation: u16,
	pos:        [2]f32,
	yaw:        f32,
}
g_rocks: [dr.MAX_ROCKS]Rock_Seen

extract :: proc(cur, prev: ^S, w: ^dr.World, out: ^gh.Frame) {
	k := w.px_per_m
	t := out.tick
	px :: proc(v: [2]f32, k: f32) -> [3]f32 {return {v.x * k, v.y * k, 0}}
	for p in 0 ..< dr.MAX_PLAYERS {
		sh := &cur.ships[p]
		if !sh.active do continue
		pos, rot := physics.pose_2d(w.phys, sh.body)
		gh.push_scene(
			out,
			{
				key = view.Key(KEY_SHIP + p),
				kind = SCENE_SHIP,
				slot = i8(p),
				pos = px(pos, k),
				rot = physics.quat_2d(rot),
			},
			Ship_View{boost_ready = 1 - f32(sh.boost_cd) / f32(dr.BOOST_COOLDOWN_TICKS), thrust = sh.thrust},
		)
	}
	{
		pos, rot := physics.pose_2d(w.phys, cur.station)
		gh.push_scene(
			out,
			{
				key = KEY_STATION,
				kind = SCENE_STATION,
				slot = -1,
				entity = 1,
				pos = px(pos, k),
				rot = physics.quat_2d(rot),
			},
			Station_View{hp_frac = f32(cur.station_hp) / f32(dr.STATION_HP)},
		)
	}
	for g in 0 ..< w.n_gates {
		gh.push_scene(
			out,
			{
				key = view.Key(KEY_GATE + g),
				kind = SCENE_GATE,
				slot = -1,
				entity = u32(200 + g),
				pos = px(w.gates[g].pos, k),
			},
			Gate_View{charge = f32(cur.gates[g].charge) / f32(dr.GATE_CHARGE_TICKS)},
		)
	}
	// rocks: rotation from the body, scaled per axis by the radius (squashed for a moment when hit)
	for i in 0 ..< cur.rocks.high_water {
		r := sim.at(&cur.rocks, i) or_continue
		pos, rot := physics.pose_2d(w.phys, r.body)
		yaw := math.atan2(rot.y, rot.x)
		radius := dr.ROCK_RADIUS[r.size] * k
		flash := r.hit_tick > 0 && t >= r.hit_tick ? max(0, 1 - f32(t - r.hit_tick) / 8) : 0
		b := gh.Bulk_Item {
			kind   = u8(BULK_ROCK + int(r.variant)),
			pos    = px(pos, k),
			yaw    = yaw,
			scale  = {radius * (1 + 0.08 * flash), radius * (1 - 0.08 * flash), 1},
			custom = {f32(r.size), flash, 0, 0},
		}
		gen := cur.rocks.slots[i].generation
		seen := &g_rocks[i]
		if seen.tick + 1 == t && seen.generation == gen {
			b.has_prev = true
			b.prev_pos = px(seen.pos, k)
			b.prev_yaw = seen.yaw
		}
		if seen.tick != t do seen^ = {t, gen, pos, yaw} // a re-extract of the same tick keeps tick − 1's pose
		gh.push_bulk(out, b) or_break
	}
	// bullets: stretched along their velocity, tinted with the owner's colour (the bulk view's colour index)
	for i in 0 ..< cur.bullets.high_water {
		bl := sim.at(&cur.bullets, i) or_continue
		b := gh.Bulk_Item {
			kind   = BULK_BULLET,
			pos    = px(bl.pos, k),
			yaw    = math.atan2(bl.vel.y, bl.vel.x),
			scale  = {1.6, 0.6, 1},
			custom = {f32(bl.owner), 0, 0, 0},
		}
		if pb, ok := sim.prev_item(prev != nil ? &prev.bullets : nil, &cur.bullets, i); ok {
			b.has_prev = true
			b.prev_pos = px(pb.pos, k)
			b.prev_yaw = math.atan2(pb.vel.y, pb.vel.x)
		}
		gh.push_bulk(out, b) or_break
	}
	// gems: spin, a squash-and-stretch pulse, fading before they expire
	for i in 0 ..< cur.gems.high_water {
		g := sim.at(&cur.gems, i) or_continue
		age := f32(t - g.spawn_tick) / dr.TICK_HZ
		pulse := math.sin(age * 6) * 0.18
		fade := clamp((f32(dr.GEM_LIFE_S) - age) / 2, 0, 1)
		b := gh.Bulk_Item {
			kind   = BULK_GEM,
			pos    = px(g.pos, k),
			yaw    = age * 2,
			scale  = {1 + pulse, 1 - pulse, 1},
			color  = {1, 0.85, 0.3, 0.25 + 0.75 * fade},
			custom = {age, 0, 0, 0},
		}
		if pg, ok := sim.prev_item(prev != nil ? &prev.gems : nil, &cur.gems, i); ok {
			b.has_prev = true
			b.prev_pos = px(pg.pos, k)
			b.prev_yaw = f32(t - 1 - pg.spawn_tick) / dr.TICK_HZ * 2
		}
		gh.push_bulk(out, b) or_break
	}
	(^Hud)(&out.hud[0])^ = hud_of(cur, w, t)
}

// ---- HUD: packed on the session thread (hud_of), a Dictionary on the main thread (hud)

Hud_Player :: struct {
	shots:  u32,
	gems:   u32,
	active: bool,
	_pad:   [3]u8,
}

Hud :: struct {
	tick:        u32,
	phase:       dr.Phase,
	_pad:        u8,
	waves:       u16,
	station_hp:  i32,
	score:       u32,
	matches:     u32,
	rocks:       u32,
	time_s:      f32, // match time (over: survived)
	next_wave_s: f32, // match: until the next wave
	reset_in_s:  f32, // over: until back to the lobby
	players:     [dr.MAX_PLAYERS]Hud_Player,
}

#assert(size_of(Hud) <= gh.HUD_BYTES)

PHASE_NAMES := [dr.Phase]string {
	.Lobby = "lobby",
	.Match = "match",
	.Over  = "over",
}

hud_of :: proc(s: ^S, w: ^dr.World, t: u32) -> (h: Hud) {
	h.tick = t
	h.phase = s.phase
	h.waves = s.waves
	h.station_hp = s.station_hp
	h.score = s.score
	h.matches = s.matches
	h.rocks = u32(s.rocks.count)
	switch s.phase {
	case .Lobby:
	case .Match:
		h.time_s = f32(t - s.match_tick) / dr.TICK_HZ
		h.next_wave_s = s.next_wave_tick > t ? f32(s.next_wave_tick - t) / dr.TICK_HZ : 0
	case .Over:
		h.time_s = f32(s.over_tick - s.match_tick) / dr.TICK_HZ
		end := s.over_tick + dr.OVER_HOLD_TICKS
		h.reset_in_s = end > t ? f32(end - t) / dr.TICK_HZ : 0
	}
	for &sh, p in s.ships {
		h.players[p] = {
			shots  = sh.shots,
			gems   = sh.gems,
			active = sh.active,
		}
	}
	return
}

hud :: proc(f: ^gh.Frame, d: ^gd.Dictionary) {
	h: Hud
	if f != nil do h = (^Hud)(&f.hud[0])^
	gd.dict_set(d, "phase", PHASE_NAMES[h.phase])
	gd.dict_set(d, "tick", i64(h.tick))
	gd.dict_set(d, "wave", i64(h.waves))
	gd.dict_set(d, "station_hp", i64(h.station_hp))
	gd.dict_set(d, "station_max", i64(dr.STATION_HP))
	gd.dict_set(d, "score", i64(h.score))
	gd.dict_set(d, "matches", i64(h.matches))
	gd.dict_set(d, "rocks", i64(h.rocks))
	gd.dict_set(d, "time_s", f64(h.time_s))
	gd.dict_set(d, "next_wave_s", f64(h.next_wave_s))
	gd.dict_set(d, "reset_in_s", f64(h.reset_in_s))
	gd.dict_set(d, "local_slot", f != nil ? i64(f.local_slot) : -1)
	players := gd.array_new()
	if f != nil {
		for &p, slot in h.players {
			pd := gd.dict_new()
			gd.dict_set(&pd, "slot", i64(slot))
			gd.dict_set(&pd, "present", p.active)
			gd.dict_set(&pd, "shots", i64(p.shots))
			gd.dict_set(&pd, "gems", i64(p.gems))
			if name := gh.frame_player_name(f, slot); name != "" do gd.dict_set(&pd, "name", name)
			gd.array_push_move(&players, &pd)
		}
	}
	gd.dict_set_move(d, "players", &players)
}

// ---- constants for the scripts (UnifiedSession.constants()), from the sim's own definitions

constants :: proc(d: ^gd.Dictionary) {
	gd.dict_set(d, "ship_radius", f64(dr.SHIP_RADIUS))
	gd.dict_set(d, "station_radius", f64(dr.STATION_RADIUS))
	gd.dict_set(d, "gate_radius", f64(dr.GATE_RADIUS))
	gd.dict_set(d, "station_hp", i64(dr.STATION_HP))
	gd.dict_set(d, "over_hold_s", f64(dr.OVER_HOLD_S))
	gd.dict_set(d, "wave_every_s", f64(dr.WAVE_EVERY_S))
	radii := gd.array_new()
	for r in dr.ROCK_RADIUS do gd.array_push(&radii, f64(r))
	gd.dict_set_move(d, "rock_radius", &radii)
	// rock_shapes[variant]: the 8 corners at radius 1 (metres); bodies are their convex hull, scaled by the radius
	shapes := gd.array_new()
	for v in 0 ..< dr.ROCK_VARIANTS {
		pts := gd.array_new()
		for c in dr.rock_points(v, .Small) {
			r := dr.ROCK_RADIUS[.Small]
			gd.array_push(&pts, gd.Vector2{c.x / r, c.y / r})
		}
		gd.array_push_move(&shapes, &pts)
	}
	gd.dict_set_move(d, "rock_shapes", &shapes)
}
