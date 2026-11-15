// drift's GDExtension (game/drift.gdextension -> .out/bin/libdrift.*): the drift sim run by unified:godot,
// plus the game's glue (the view contract, games/drift/SPEC.md "View"): 2D scene and MultiMesh views in pixels,
// typed view data, the HUD view, constants, and how the InputMap and the aim become an Input. Built by
// `uni build drift`.
package drift_extension

import "base:runtime"
import "core:math"
import "unified:eos"
import gd "unified:gdext"
import "unified:gdext/gdi"
import "unified:godot"
import "unified:netcode"
import "unified:physics"
import "unified:sim"
import "unified:view"

import dr "../drift"

@(export, link_name = "drift_init")
drift_init :: proc "c" (
	gpa: gdi.InterfaceGetProcAddress,
	lib: gdi.ClassLibraryPtr,
	init: ^gdi.Initialization,
) -> gdi.Bool {
	context = runtime.default_context()
	godot.install(&dr.GAME, GLUE)
	godot.set_transport(&EOS_TRANSPORT)
	return godot.entry(gpa, lib, init)
}

// ---- online play: EOS (lobby codes, P2P with Epic relays), through unified:godot's transport interface

// Game + net protocol version: lobby search only finds lobbies of the same bucket.
BUCKET :: "drift/4"
#assert(netcode.PROTOCOL_VERSION == 9, "netcode protocol changed: bump BUCKET with it")

@(private)
eos_init :: proc(events: ^godot.Transport_Events) -> bool {
	if eos.init({product_name = "drift", product_version = godot.app_version}) do return true
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

/// ---- the view contract

// Scene views (the view index: a scene per kind, with a UnifiedView marker), each with its typed data (set as the
// view's properties), and the HUD (game/views/hud.tscn: Game.hud).
View :: enum u8 {
	Ship,
	Station,
	Gate,
	Hud,
}

// MultiMesh views (MultiMeshInstance2D, TRANSFORM_2D, colors + custom data): a rock mesh per variant (a unit-radius
// polygon, scaled by the rock's radius), bullets, gems.
MultiView :: enum u8 {
	Rock_0,
	Rock_1,
	Rock_2,
	Rock_3,
	Bullet,
	Gem,
}

Frame :: godot.Frame(dr.State, dr.World, View, MultiView)

Ship_View :: struct {
	boost_ready: f32, // 0 just boosted .. 1 ready
	thrust:      bool,
}

Station_View :: struct {
	hp_frac: f32, // 0..1
}

Gate_View :: struct {
	charge: f32, // 0 ready .. 1 just used
}

// Spawn keys: ships 1 + player, the station 100, gates 200 + index, the HUD 300 (a view lives as long as its
// entity).
KEY_SHIP :: 1
KEY_STATION :: 100
KEY_GATE :: 200
KEY_HUD :: 300

GLUE := godot.Glue(dr.State, dr.Input, dr.World, View, MultiView) {
	sample_input = sample_input,
	fill_frame = fill_frame,
	smoothing = {tau_s = 0.1, teleport_dist = 64}, // pixels: a warp snaps
	is_2d = true,
	scripted_input = dr.scripted_input,
	scripted_commands = dr.scripted_commands,
	constants = constants,
	event_key = event_key,
	event_pos = event_pos,
	level = "res://game/levels/arena.level",
}

// Events in pixels too, like the views: the level's scale (World.px_per_m).
event_pos :: proc(position: sim.Position, world: ^dr.World) -> sim.Position {
	return {position.x * world.px_per_m, position.y * world.px_per_m, 0}
}

// Station hits go to the station's view (they have no subject). Setting event_key replaces the routing by
// subject, so a player's events go to their ship's view here too (a rock hit: the shooter's), and the rest
// (the rock events' subject, a rock, has no scene view) to none.
event_key :: proc(event: ^sim.Raw_Event) -> view.Key {
	player := -1
	switch value in sim.event_value(event, dr.Event) {
	case dr.Event_Station_Hit:
		return KEY_STATION
	case dr.Event_Joined:
		player = int(value.player)
	case dr.Event_Left:
		player = int(value.player)
	case dr.Event_Fired:
		player = int(value.player)
	case dr.Event_Boosted:
		player = int(value.player)
	case dr.Event_Warped:
		player = int(value.player)
	case dr.Event_Rock_Hit:
		player = int(value.player)
	case dr.Event_Gem_Picked:
		player = int(value.player)
	case dr.Event_Match_Started:
		player = int(value.player)
	case dr.Event_Rock_Split, dr.Event_Rock_Destroyed, dr.Event_Wave, dr.Event_Match_Over:
	}
	return player >= 0 ? view.Key(KEY_SHIP + player) : 0
}

// ---- input (main thread, the one local player)

// The movement, fire and boost from the InputMap, and the aim: a world-space direction the arena's script sets
// (UnifiedSession.set_input_value(&"aim", ...)) from the mouse (relative to the local ship) or the right stick;
// zero keeps the heading. A tap of fire or boost shorter than a tick still counts (action_pressed).
sample_input :: proc(input: ^dr.Input) {
	move := godot.action_vector("move_left", "move_right", "move_up", "move_down") // +y is down, the plane's +y
	input.move_x, input.move_y = godot.axis_i8(move.x), godot.axis_i8(move.y)
	aim := godot.input_value("aim")
	length := math.sqrt(aim.x * aim.x + aim.y * aim.y)
	if length > 1e-4 {
		input.aim_x, input.aim_y = godot.axis_i8(aim.x / length), godot.axis_i8(aim.y / length)
	}
	if godot.action_held("fire") || godot.action_pressed("fire") do input.buttons |= dr.BUTTON_FIRE
	if godot.action_held("boost") || godot.action_pressed("boost") do input.buttons |= dr.BUTTON_BOOST
}

// ---- the frame (session thread): metres -> pixels (the level's px_per_m)

// A point on the plane (metres) in pixels.
pixels :: proc(point: [2]f32, px_per_m: f32) -> [3]f32 {
	return {point.x * px_per_m, point.y * px_per_m, 0}
}

fill_frame :: proc(frame: ^Frame) {
	state, world, tick := frame.state, frame.world, frame.tick
	px_per_m := world.px_per_m
	for player in 0 ..< dr.PLAYERS {
		ship := &state.ships[player]
		if !ship.active do continue
		pos, rotation := physics.pose_2d(world.phys, ship.body)
		godot.push_view(frame, {
			key    = view.Key(KEY_SHIP + player),
			kind   = .Ship,
			player = player,
			pos    = pixels(pos, px_per_m),
			rot    = physics.quat_2d(rotation),
		}, Ship_View{boost_ready = 1 - f32(ship.boost_cooldown) / f32(dr.BOOST_COOLDOWN_TICKS), thrust = ship.thrust})
	}
	{
		pos, rotation := physics.pose_2d(world.phys, state.station)
		godot.push_view(frame, {
			key    = KEY_STATION,
			kind   = .Station,
			entity = 1,
			pos    = pixels(pos, px_per_m),
			rot    = physics.quat_2d(rotation),
		}, Station_View{hp_frac = f32(state.station_hp) / f32(dr.STATION_HP)})
	}
	for gate in 0 ..< world.gate_count {
		godot.push_view(frame, {
			key    = view.Key(KEY_GATE + gate),
			kind   = .Gate,
			entity = u64(KEY_GATE + gate),
			pos    = pixels(world.gates[gate].pos, px_per_m),
		}, Gate_View{charge = f32(state.gates[gate].charge) / f32(dr.GATE_CHARGE_TICKS)})
	}
	// rocks: rotation from the body, scaled per axis by the radius (squashed for a moment when hit)
	rocks := sim.iterate(&state.rocks)
	for rock, handle in sim.next(&rocks) {
		pos, rotation := physics.pose_2d(world.phys, rock.body)
		radius := dr.ROCK_RADIUS[rock.size] * px_per_m
		flash := rock.hit_tick > 0 && tick >= rock.hit_tick ? max(0, 1 - f32(tick - rock.hit_tick) / 8) : 0
		godot.push_multi(frame, {
			key    = sim.handle_key(handle),
			kind   = MultiView(int(MultiView.Rock_0) + int(rock.variant)),
			pos    = pixels(pos, px_per_m),
			yaw    = math.atan2(rotation.y, rotation.x),
			scale  = {radius * (1 + 0.08 * flash), radius * (1 - 0.08 * flash), 1},
			custom = {f32(rock.size), flash, 0, 0},
		}) or_break
	}
	// bullets: stretched along their velocity, tinted with the owner's colour (the view's colour index)
	bullets := sim.iterate(&state.bullets)
	for bullet, handle in sim.next(&bullets) {
		godot.push_multi(frame, {
			key    = sim.handle_key(handle),
			kind   = .Bullet,
			pos    = pixels(bullet.pos, px_per_m),
			yaw    = math.atan2(bullet.vel.y, bullet.vel.x),
			scale  = {1.6, 0.6, 1},
			custom = {f32(bullet.owner), 0, 0, 0},
		}) or_break
	}
	// gems: spin, a squash-and-stretch pulse, fading before they expire
	gems := sim.iterate(&state.gems)
	for gem, handle in sim.next(&gems) {
		age := f32(tick - gem.spawn_tick) / dr.TICK_HZ
		pulse := math.sin(age * 6) * 0.18
		fade := clamp((f32(dr.GEM_LIFE_S) - age) / 2, 0, 1)
		godot.push_multi(frame, {
			key    = sim.handle_key(handle),
			kind   = .Gem,
			pos    = pixels(gem.pos, px_per_m),
			yaw    = age * 2,
			scale  = {1 + pulse, 1 - pulse, 1},
			color  = {1, 0.85, 0.3, 0.25 + 0.75 * fade},
			custom = {age, 0, 0, 0},
		}) or_break
	}
	godot.push_view(frame, {key = KEY_HUD, kind = .Hud}, hud_of(state, tick))
}

// ---- HUD: the HUD view's data (Game.hud, through games/shared's hud_view.gd)

Hud_Player :: struct {
	player:  u8,
	present: bool,
	shots:   u32,
	gems:    u32,
}

Hud :: struct {
	phase:       dr.Phase, // lobby, match, over
	tick:        u32,
	wave:        u16,
	station_hp:  i32,
	station_max: i32,
	score:       u32,
	matches:     u32,
	rocks:       u32,
	time_s:      f32, // match time (over: survived)
	next_wave_s: f32, // match: until the next wave
	reset_in_s:  f32, // over: until back to the lobby
	players:     [dr.PLAYERS]Hud_Player,
}

hud_of :: proc(state: ^dr.State, tick: u32) -> (hud: Hud) {
	hud.phase = state.phase
	hud.tick = tick
	hud.wave = state.waves
	hud.station_hp = state.station_hp
	hud.station_max = dr.STATION_HP
	hud.score = state.score
	hud.matches = state.matches
	hud.rocks = u32(state.rocks.count)
	switch state.phase {
	case .Lobby:
	case .Match:
		hud.time_s = f32(tick - state.match_tick) / dr.TICK_HZ
		hud.next_wave_s = state.next_wave_tick > tick ? f32(state.next_wave_tick - tick) / dr.TICK_HZ : 0
	case .Over:
		hud.time_s = f32(state.over_tick - state.match_tick) / dr.TICK_HZ
		end := state.over_tick + dr.OVER_HOLD_TICKS
		hud.reset_in_s = end > tick ? f32(end - tick) / dr.TICK_HZ : 0
	}
	for &ship, player in state.ships {
		hud.players[player] = {
			player  = u8(player),
			present = ship.active,
			shots   = ship.shots,
			gems    = ship.gems,
		}
	}
	return
}

// ---- constants for the scripts (UnifiedSession.constants()), from the sim's own definitions

constants :: proc(dict: ^gd.Dictionary) {
	gd.dict_set(dict, "ship_radius", f64(dr.SHIP_RADIUS))
	gd.dict_set(dict, "station_radius", f64(dr.STATION_RADIUS))
	gd.dict_set(dict, "gate_radius", f64(dr.GATE_RADIUS))
	gd.dict_set(dict, "station_hp", i64(dr.STATION_HP))
	gd.dict_set(dict, "over_hold_s", f64(dr.OVER_HOLD_S))
	gd.dict_set(dict, "wave_every_s", f64(dr.WAVE_EVERY_S))
	radii := gd.array_new()
	for radius in dr.ROCK_RADIUS do gd.array_push(&radii, f64(radius))
	gd.dict_set_move(dict, "rock_radius", &radii)
	// rock_shapes[variant]: the 8 corners at radius 1 (metres); bodies are their convex hull, scaled by the radius
	shapes := gd.array_new()
	small := dr.ROCK_RADIUS[.Small]
	for variant in 0 ..< dr.ROCK_VARIANTS {
		corners := gd.array_new()
		for corner in dr.rock_points(variant, .Small) {
			gd.array_push(&corners, gd.Vector2{corner.x / small, corner.y / small})
		}
		gd.array_push_move(&shapes, &corners)
	}
	gd.dict_set_move(dict, "rock_shapes", &shapes)
}
