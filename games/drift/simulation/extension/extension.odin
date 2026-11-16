// drift's GDExtension (game/drift.gdextension -> .out/bin/libdrift.*): the drift sim run by unified:godot,
// plus the game's glue (the view contract, games/drift/SPEC.md "View"): 2D scene and MultiMesh views in pixels,
// typed view data, the HUD's session data (Unified.data.hud), the constants (Unified.constants), and how the InputMap
// and the aim become an Input. Built by `uni build drift`.
package drift_extension

import "base:runtime"
import "core:math"
import "unified:gdext/gdi"
import "unified:godot"
import "unified:godot_eos"
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
	constants_init()
	godot.install(&dr.GAME, GLUE)
	godot.set_transport(godot_eos.transport("drift")) // online play: EOS lobbies and P2P
	return godot.entry(gpa, lib, init)
}

/// ---- the view contract

// Scene views (the view index: a scene per kind, with a UnifiedView marker), each with its typed data (set as the
// view's properties).
View :: enum u8 {
	Ship,
	Station,
	Gate,
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

// Keys (unique within a kind): a ship its player's key (ship_key: sim.player_key, the same while they are in the
// session, so their ship's view survives a rejoin), the station 0, a gate its index.

GLUE := godot.Glue(dr.State, dr.Input, dr.World, View, MultiView) {
	sample_input = sample_input,
	fill_frame = fill_frame,
	data = Data,
	constants = CONSTANTS,
	smoothing = {tau_s = 0.1, teleport_dist = 64}, // pixels: a warp snaps
	is_2d = true,
	scripted_input = dr.scripted_input,
	scripted_commands = dr.scripted_commands,
	event_key = event_key,
	event_pos = event_pos,
	level = "res://game/levels/arena.level",
}

// Events in pixels too, like the views: the level's scale (World.px_per_m).
event_pos :: proc(position: sim.Position, world: ^dr.World) -> sim.Position {
	return {position.x * world.px_per_m, position.y * world.px_per_m, 0}
}

// Station hits go to the station's view (they have no subject); the rest by their subject: a player's events to
// their ship (keyed by their player key), a rock's to its shooter's ship (no scene view has a rock's key).
event_key :: proc(event: ^sim.Raw_Event) -> (kind: View, key: view.Key, route: godot.Event_Route) {
	#partial switch _ in sim.event_value(event, dr.Event) {
	case dr.Event_Station_Hit:
		return .Station, 0, .View
	}
	return
}

// A player's ship view's key (0 for nobody: no view).
ship_key :: proc(player: sim.Player) -> view.Key {
	return view.Key(sim.player_key(player))
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

fill_frame :: proc(f: ^Frame) {
	px_per_m := f.world.px_per_m
	ships := sim.iterate_present(&f.state.players)
	for ship, player in sim.next(&ships) {
		pos, rotation := physics.pose_2d(f.world.phys, ship.body)
		godot.push_view(f, {
			key    = ship_key(player),
			kind   = .Ship,
			player = player,
			pos    = pixels(pos, px_per_m),
			rot    = physics.quat_2d(rotation),
		}, Ship_View{boost_ready = 1 - f32(ship.boost_cooldown) / f32(dr.BOOST_COOLDOWN_TICKS), thrust = ship.thrust})
	}
	{
		pos, rotation := physics.pose_2d(f.world.phys, f.state.station)
		godot.push_view(f, {
			kind = .Station,
			pos  = pixels(pos, px_per_m),
			rot  = physics.quat_2d(rotation),
		}, Station_View{hp_frac = f32(f.state.station_hp) / f32(dr.STATION_HP)})
	}
	for gate in 0 ..< f.world.gate_count {
		godot.push_view(f, {
			key  = view.Key(gate),
			kind = .Gate,
			pos  = pixels(f.world.gates[gate].pos, px_per_m),
		}, Gate_View{charge = f32(f.state.gates[gate].charge) / f32(dr.GATE_CHARGE_TICKS)})
	}
	// rocks: rotation from the body, scaled per axis by the radius (squashed for a moment when hit)
	rocks := sim.iterate(&f.state.rocks)
	for rock, handle in sim.next(&rocks) {
		pos, rotation := physics.pose_2d(f.world.phys, rock.body)
		radius := dr.ROCK_RADIUS[rock.size] * px_per_m
		flash := rock.hit_tick > 0 && f.tick >= rock.hit_tick ? max(0, 1 - f32(f.tick - rock.hit_tick) / 8) : 0
		godot.push_multi_view(f, {
			key    = sim.handle_key(handle),
			kind   = MultiView(int(MultiView.Rock_0) + int(rock.variant)),
			pos    = pixels(pos, px_per_m),
			rot    = physics.quat_2d(rotation),
			scale  = {radius * (1 + 0.08 * flash), radius * (1 - 0.08 * flash), 1},
			custom = {f32(rock.size), flash, 0, 0},
		}) or_break
	}
	// bullets: turned to and stretched along their velocity (quat_2d normalises it), tinted with the owner's colour
	// (custom.x: the owner's slot, the view's colour index; -1 once the owner has left)
	bullets := sim.iterate(&f.state.bullets)
	for bullet, handle in sim.next(&bullets) {
		owner_slot, _ := sim.player_slot(&f.state.players, bullet.owner)
		godot.push_multi_view(f, {
			key    = sim.handle_key(handle),
			kind   = .Bullet,
			pos    = pixels(bullet.pos, px_per_m),
			rot    = physics.quat_2d(bullet.vel),
			scale  = {1.6, 0.6, 1},
			custom = {f32(owner_slot), 0, 0, 0},
		}) or_break
	}
	// gems: spin, a squash-and-stretch pulse, fading before they expire
	gems := sim.iterate(&f.state.gems)
	for gem, handle in sim.next(&gems) {
		age := f32(f.tick - gem.spawn_tick) / dr.TICK_HZ
		pulse := math.sin(age * 6) * 0.18
		fade := clamp((f32(dr.GEM_LIFE_S) - age) / 2, 0, 1)
		godot.push_multi_view(f, {
			key    = sim.handle_key(handle),
			kind   = .Gem,
			pos    = pixels(gem.pos, px_per_m),
			rot    = view.quat_angle2d(age * 2),
			scale  = {1 + pulse, 1 - pulse, 1},
			color  = {1, 0.85, 0.3, 0.25 + 0.75 * fade},
			custom = {age, 0, 0, 0},
		}) or_break
	}
	godot.push_data(f, hud_of(f.state, f.tick))
}

// ---- the session data: the HUD (Unified.data.hud; games/shared reads its `tick` and `players`)

Data :: union {
	Data_Hud,
}

// A slot's player (`player`: their key in GDScript; 0 and not `present` for an empty slot).
Hud_Player :: struct {
	player:  sim.Player,
	present: bool,
	_pad:    [3]u8,
	shots:   u32,
	gems:    u32,
}

Data_Hud :: struct {
	tick:        u32,
	players:     [dr.PLAYERS]Hud_Player,
	phase:       dr.Phase, // EnumPhase in GDScript
	_pad:        u8,
	wave:        u16,
	station_hp:  i32,
	station_max: i32,
	score:       u32,
	matches:     u32,
	rocks:       u32,
	time_s:      f32, // match time (over: survived)
	next_wave_s: f32, // match: until the next wave
	reset_in_s:  f32, // over: until back to the lobby
}

hud_of :: proc(state: ^dr.State, tick: u32) -> (hud: Data_Hud) {
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
	for slot in 0 ..< dr.PLAYERS {
		player := sim.player_in_slot(&state.players, slot)
		ship := sim.player_data(&state.players, player)
		if ship == nil do continue
		hud.players[slot] = {
			player  = player,
			present = true,
			shots   = ship.shots,
			gems    = ship.gems,
		}
	}
	return
}

// ---- the constants for the scripts (Unified.constants), from the sim's own definitions

// Sizes in metres (the views draw them at the level's scale, Game.px_per_m).
Data_Constants :: struct {
	ship_radius:    f32,
	station_radius: f32,
	gate_radius:    f32,
	station_hp:     i32,
	over_hold_s:    f32,
	wave_every_s:   f32,
	rock_shapes:    [dr.ROCK_VARIANTS][8][2]f32, // per variant the 8 corners at radius 1 (an Array of Vector2s)
}

// Copied at install; constants_init fills the rock shapes first (dr.rock_points is a proc).
CONSTANTS := Data_Constants {
	ship_radius    = dr.SHIP_RADIUS,
	station_radius = dr.STATION_RADIUS,
	gate_radius    = dr.GATE_RADIUS,
	station_hp     = dr.STATION_HP,
	over_hold_s    = dr.OVER_HOLD_S,
	wave_every_s   = dr.WAVE_EVERY_S,
}

// The rock shapes the sim builds its bodies from (their convex hull, scaled by the rock's radius), at radius 1.
constants_init :: proc() {
	small := dr.ROCK_RADIUS[.Small]
	for variant in 0 ..< dr.ROCK_VARIANTS {
		for corner, k in dr.rock_points(variant, .Small) do CONSTANTS.rock_shapes[variant][k] = corner / small
	}
}
