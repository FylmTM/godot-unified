// drift's GDExtension (game/drift.gdextension -> .out/bin/libdrift.*): the drift sim run by unified:godot_host,
// plus the game's glue (the view contract, games/drift/SPEC.md "View"): 2D scene and bulk views in pixels, typed
// scene data, the HUD, constants, and how the InputMap and the aim become an Input. Built by
// `uni build drift`.
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
BUCKET :: "drift/4"
#assert(netcode.PROTOCOL_VERSION == 9, "netcode protocol changed: bump BUCKET with it")

@(private)
eos_init :: proc(events: ^gh.Transport_Events) -> bool {
	if eos.init({product_name = "drift", product_version = gh.app_version}) do return true
	events.fail(events.ctx, eos.status().detail)
	return false
}

EOS_TRANSPORT := gh.Transport {
	name = "EOS",
	open_host = proc(_: rawptr, events: ^gh.Transport_Events) -> (netcode.Link, bool) {
		if !eos_init(events) do return {}, false
		link, ok := eos.open_host(BUCKET)
		if !ok do events.fail(events.ctx, eos.status().detail)
		return link, ok
	},
	open_join = proc(_: rawptr, code: string, events: ^gh.Transport_Events) -> (netcode.Link, bool) {
		if !eos_init(events) do return {}, false
		link, ok := eos.open_join(BUCKET, code)
		if !ok do events.fail(events.ctx, eos.status().detail)
		return link, ok
	},
	pump = proc(_: rawptr, events: ^gh.Transport_Events) {
		result := eos.pump()
		if result.code != "" do events.code(events.ctx, result.code)
		if result.failed != "" do events.fail(events.ctx, result.failed)
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

// Spawn keys: ships 1 + player, the station 100, gates 200 + index (a view lives as long as its entity).
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
	poll_input = poll_input,
	scripted_input = dr.scripted_input,
	scripted_commands = dr.scripted_commands,
	hud = hud,
	constants = constants,
	event_key = event_key,
	// events in pixels too, like the views: the level's scale (World.px_per_m)
	event_pos = proc(position: sim.Position, world: ^dr.World) -> sim.Position {
		return {position.x * world.px_per_m, position.y * world.px_per_m, 0}
	},
	level = "res://game/levels/arena.level",
}

// Station hits go to the station's view (they have no subject). Setting event_key replaces the routing by
// subject, so a player's events go to their ship's view here too (a rock hit: the shooter's), and the rest
// (the rock events' subject, a rock, has no scene view) to none.
event_key :: proc(event: ^sim.Raw_Event) -> view.Key {
	player := -1
	switch value in sim.event_value(event, dr.Event) {
	case dr.Station_Hit:
		return KEY_STATION
	case dr.Joined:
		player = int(value.player)
	case dr.Left:
		player = int(value.player)
	case dr.Fired:
		player = int(value.player)
	case dr.Boosted:
		player = int(value.player)
	case dr.Warped:
		player = int(value.player)
	case dr.Rock_Hit:
		player = int(value.player)
	case dr.Gem_Picked:
		player = int(value.player)
	case dr.Match_Started:
		player = int(value.player)
	case dr.Rock_Split, dr.Rock_Destroyed, dr.Wave, dr.Match_Over:
	}
	return player >= 0 ? view.Key(KEY_SHIP + player) : 0
}

// ---- input (session thread, the one local player)

poll_input :: proc(actions: gh.Actions, player: int, tick: u32, state: ^dr.State) -> dr.Input {
	input := dr.Input {
		move_x = quantize(actions.move.x), // get_vector(left, right, up, down): +y is down, the plane's +y
		move_y = quantize(actions.move.y),
	}
	aim := actions.vectors[VEC_AIM]
	length := math.sqrt(aim.x * aim.x + aim.y * aim.y)
	if length > 1e-4 {
		input.aim_x = quantize(aim.x / length)
		input.aim_y = quantize(aim.y / length)
	}
	buttons := actions.held | actions.pressed
	if buttons & (1 << BUTTON_FIRE) != 0 do input.buttons |= dr.BUTTON_FIRE
	if buttons & (1 << BUTTON_BOOST) != 0 do input.buttons |= dr.BUTTON_BOOST
	return input
}

// −1..1 to an axis of −127..127.
quantize :: proc(x: f32) -> i8 {
	return i8(clamp(x, -1, 1) * 127)
}

// ---- frame extraction (session thread): metres -> pixels (the level's px_per_m)

// The previous tick's pose of physics-driven bulk items (rocks): Box3D holds only the current tick, so extract
// remembers what it showed for tick − 1, by table slot and generation.
Rock_Seen :: struct {
	tick:       u32,
	generation: u32,
	pos:        [2]f32,
	yaw:        f32,
}
rocks_seen: [dr.MAX_ROCKS]Rock_Seen

// A point on the plane (metres) in pixels.
pixels :: proc(point: [2]f32, px_per_m: f32) -> [3]f32 {
	return {point.x * px_per_m, point.y * px_per_m, 0}
}

extract :: proc(current, previous: ^dr.State, world: ^dr.World, out: ^gh.Frame) {
	px_per_m := world.px_per_m
	tick := out.tick
	for player in 0 ..< dr.PLAYERS {
		ship := &current.ships[player]
		if !ship.active do continue
		pos, rotation := physics.pose_2d(world.phys, ship.body)
		gh.push_scene(
			out,
			{
				key = view.Key(KEY_SHIP + player),
				kind = SCENE_SHIP,
				player = i8(player),
				pos = pixels(pos, px_per_m),
				rot = physics.quat_2d(rotation),
			},
			Ship_View{boost_ready = 1 - f32(ship.boost_cooldown) / f32(dr.BOOST_COOLDOWN_TICKS), thrust = ship.thrust},
		)
	}
	{
		pos, rotation := physics.pose_2d(world.phys, current.station)
		gh.push_scene(
			out,
			{
				key = KEY_STATION,
				kind = SCENE_STATION,
				player = -1,
				entity = 1,
				pos = pixels(pos, px_per_m),
				rot = physics.quat_2d(rotation),
			},
			Station_View{hp_frac = f32(current.station_hp) / f32(dr.STATION_HP)},
		)
	}
	for gate in 0 ..< world.gate_count {
		gh.push_scene(
			out,
			{
				key = view.Key(KEY_GATE + gate),
				kind = SCENE_GATE,
				player = -1,
				entity = u64(KEY_GATE + gate),
				pos = pixels(world.gates[gate].pos, px_per_m),
			},
			Gate_View{charge = f32(current.gates[gate].charge) / f32(dr.GATE_CHARGE_TICKS)},
		)
	}
	// rocks: rotation from the body, scaled per axis by the radius (squashed for a moment when hit)
	rocks := sim.iterate(&current.rocks)
	for rock, handle in sim.next(&rocks) {
		pos, rotation := physics.pose_2d(world.phys, rock.body)
		yaw := math.atan2(rotation.y, rotation.x)
		radius := dr.ROCK_RADIUS[rock.size] * px_per_m
		flash := rock.hit_tick > 0 && tick >= rock.hit_tick ? max(0, 1 - f32(tick - rock.hit_tick) / 8) : 0
		item := gh.Bulk_Item {
			kind   = u8(BULK_ROCK + int(rock.variant)),
			pos    = pixels(pos, px_per_m),
			yaw    = yaw,
			scale  = {radius * (1 + 0.08 * flash), radius * (1 - 0.08 * flash), 1},
			custom = {f32(rock.size), flash, 0, 0},
		}
		seen := &rocks_seen[handle.index]
		if seen.tick + 1 == tick && seen.generation == handle.generation {
			item.has_prev = true
			item.prev_pos = pixels(seen.pos, px_per_m)
			item.prev_yaw = seen.yaw
		}
		// a re-extract of the same tick keeps tick − 1's pose
		if seen.tick != tick do seen^ = {tick, handle.generation, pos, yaw}
		gh.push_bulk(out, item) or_break
	}
	// bullets: stretched along their velocity, tinted with the owner's colour (the bulk view's colour index)
	previous_bullets := previous != nil ? &previous.bullets : nil
	bullets := sim.iterate(&current.bullets)
	for bullet, handle in sim.next(&bullets) {
		item := gh.Bulk_Item {
			kind   = BULK_BULLET,
			pos    = pixels(bullet.pos, px_per_m),
			yaw    = math.atan2(bullet.vel.y, bullet.vel.x),
			scale  = {1.6, 0.6, 1},
			custom = {f32(bullet.owner), 0, 0, 0},
		}
		if before, ok := sim.prev_item(previous_bullets, &current.bullets, int(handle.index)); ok {
			item.has_prev = true
			item.prev_pos = pixels(before.pos, px_per_m)
			item.prev_yaw = math.atan2(before.vel.y, before.vel.x)
		}
		gh.push_bulk(out, item) or_break
	}
	// gems: spin, a squash-and-stretch pulse, fading before they expire
	previous_gems := previous != nil ? &previous.gems : nil
	gems := sim.iterate(&current.gems)
	for gem, handle in sim.next(&gems) {
		age := f32(tick - gem.spawn_tick) / dr.TICK_HZ
		pulse := math.sin(age * 6) * 0.18
		fade := clamp((f32(dr.GEM_LIFE_S) - age) / 2, 0, 1)
		item := gh.Bulk_Item {
			kind   = BULK_GEM,
			pos    = pixels(gem.pos, px_per_m),
			yaw    = age * 2,
			scale  = {1 + pulse, 1 - pulse, 1},
			color  = {1, 0.85, 0.3, 0.25 + 0.75 * fade},
			custom = {age, 0, 0, 0},
		}
		if before, ok := sim.prev_item(previous_gems, &current.gems, int(handle.index)); ok {
			item.has_prev = true
			item.prev_pos = pixels(before.pos, px_per_m)
			item.prev_yaw = f32(tick - 1 - before.spawn_tick) / dr.TICK_HZ * 2
		}
		gh.push_bulk(out, item) or_break
	}
	(^Hud)(&out.hud[0])^ = hud_of(current, tick)
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
	players:     [dr.PLAYERS]Hud_Player,
}

#assert(size_of(Hud) <= gh.HUD_BYTES)

PHASE_NAMES := [dr.Phase]string {
	.Lobby = "lobby",
	.Match = "match",
	.Over  = "over",
}

hud_of :: proc(state: ^dr.State, tick: u32) -> (packed: Hud) {
	packed.tick = tick
	packed.phase = state.phase
	packed.waves = state.waves
	packed.station_hp = state.station_hp
	packed.score = state.score
	packed.matches = state.matches
	packed.rocks = u32(state.rocks.count)
	switch state.phase {
	case .Lobby:
	case .Match:
		packed.time_s = f32(tick - state.match_tick) / dr.TICK_HZ
		packed.next_wave_s = state.next_wave_tick > tick ? f32(state.next_wave_tick - tick) / dr.TICK_HZ : 0
	case .Over:
		packed.time_s = f32(state.over_tick - state.match_tick) / dr.TICK_HZ
		end := state.over_tick + dr.OVER_HOLD_TICKS
		packed.reset_in_s = end > tick ? f32(end - tick) / dr.TICK_HZ : 0
	}
	for &ship, player in state.ships {
		packed.players[player] = {
			shots  = ship.shots,
			gems   = ship.gems,
			active = ship.active,
		}
	}
	return
}

hud :: proc(frame: ^gh.Frame, dict: ^gd.Dictionary) {
	packed: Hud
	if frame != nil do packed = (^Hud)(&frame.hud[0])^
	gd.dict_set(dict, "phase", PHASE_NAMES[packed.phase])
	gd.dict_set(dict, "tick", i64(packed.tick))
	gd.dict_set(dict, "wave", i64(packed.waves))
	gd.dict_set(dict, "station_hp", i64(packed.station_hp))
	gd.dict_set(dict, "station_max", i64(dr.STATION_HP))
	gd.dict_set(dict, "score", i64(packed.score))
	gd.dict_set(dict, "matches", i64(packed.matches))
	gd.dict_set(dict, "rocks", i64(packed.rocks))
	gd.dict_set(dict, "time_s", f64(packed.time_s))
	gd.dict_set(dict, "next_wave_s", f64(packed.next_wave_s))
	gd.dict_set(dict, "reset_in_s", f64(packed.reset_in_s))
	gd.dict_set(dict, "local_player", frame != nil ? i64(frame.local_player) : -1)
	players := gd.array_new()
	if frame != nil {
		for &info, player in packed.players {
			entry := gd.dict_new()
			gd.dict_set(&entry, "player", i64(player))
			gd.dict_set(&entry, "present", info.active)
			gd.dict_set(&entry, "shots", i64(info.shots))
			gd.dict_set(&entry, "gems", i64(info.gems))
			if name := gh.frame_player_name(frame, player); name != "" do gd.dict_set(&entry, "name", name)
			gd.array_push_move(&players, &entry)
		}
	}
	gd.dict_set_move(dict, "players", &players)
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
