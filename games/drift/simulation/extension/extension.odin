// drift's GDExtension (game/drift.gdextension -> .out/bin/libdrift.*): the drift sim run by unified:godot,
// plus the game's glue (the view contract, games/drift/SPEC.md "View contract"): 2D scene and MultiMesh views,
// typed view data, the HUD's session data (Unified.data.hud), the constants (Unified.constants), and how the InputMap
// and the aim become an Input. Built by `uni build drift`.
package drift_extension

import "core:math"
import "unified:dmath"
import "unified:eos"
import "unified:godot"
import "unified:physics"
import "unified:sim"

import g "../drift"

@(export, link_name = "drift_init")
drift_init :: proc "c" (
	gpa: godot.Get_Proc_Address,
	lib: godot.Class_Library,
	init: ^godot.Initialization,
) -> godot.Init_Result {
	// online play: EOS lobbies and P2P
	return godot.init(&g.GAME, GLUE, gpa, lib, init, eos.lobby({}), constants = constants)
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

Frame :: godot.Frame(g.Game, View, MultiView)

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

// Keys (unique within a kind): a ship its player's key (a zero key with `player` set: the same while they are in the
// session, so their ship's view survives a rejoin), the station 0, a gate its index.

GLUE := godot.Glue(g.Game, View, MultiView) {
	sample_input = sample_input,
	fill_frame   = fill_frame,
	data         = Data,
	is_2d        = true,
	view_scale   = 32, // pixels per metre: the scale the art and the level are drawn at (the host maps positions)
	event_key    = event_key,
	input_values = Input_Values,
}

// Station hits go to the station's view (they have no subject); the rest by their subject: a player's events to
// their ship (keyed by their player key), a rock's to its shooter's ship (no scene view has a rock's key).
event_key :: proc(event: g.Event, _: godot.Subject) -> (kind: View, key: u64, route: godot.Event_Route) {
	#partial switch _ in event {
	case g.Event_Station_Hit:
		return .Station, 0, .View
	}
	return
}

// ---- input (main thread, the one local player)

// What the arena's script sets every frame (Unified.input.aim).
Input_Values :: struct {
	aim: [2]f32, // a world-space direction from the mouse (relative to the local ship) or the right stick; zero: keep
}

// The movement, fire and boost from the InputMap, and the aim. A tap of fire or boost shorter than a frame still
// counts (action_down).
sample_input :: proc(input: ^g.Input) {
	move := godot.action_vector("move_left", "move_right", "move_up", "move_down") // +y is down, the plane's +y
	input.move_x, input.move_y = dmath.axis_i8(move.x), dmath.axis_i8(move.y)
	input.aim = dmath.dir2(godot.input_values(Input_Values).aim)
	input.buttons = godot.buttons(g.Buttons, {.Fire = "fire", .Boost = "boost"})
}

// ---- the frame (session thread): everything in metres (the host maps positions to pixels: Glue.view_scale)

HIT_FLASH_S :: 0.125 // a hit rock's flash fades over this
HIT_SQUASH :: 0.08 // a hit rock squashes by this much of its radius at the flash's height
BULLET_SCALE :: [3]f32{1.6, 0.6, 1} // a bullet's quad, stretched along its velocity
GEM_SPIN :: 2 // rad/s
GEM_PULSE :: 0.18 // a gem's squash and stretch, at GEM_PULSE_RATE rad/s
GEM_PULSE_RATE :: 6
GEM_FADE_S :: 2 // a gem fades out over its last seconds

fill_frame :: proc(f: ^Frame) {
	ships := sim.iterate_present(&f.state.players)
	for ship, player in sim.next(&ships) {
		godot.push_view(f, {
			kind   = .Ship,
			player = player,
			pos    = sim.position(physics.body_position_2d(f.world.phys, ship.body)),
			rot    = physics.quat_2d(physics.body_rotation_2d(f.world.phys, ship.body)),
		}, Ship_View{boost_ready = 1 - f32(ship.boost_cooldown) / f32(g.BOOST_COOLDOWN_TICKS), thrust = ship.thrust})
	}
	godot.push_view(f, {
		kind = .Station,
		pos  = sim.position(physics.body_position_2d(f.world.phys, f.state.station)),
		rot  = physics.quat_2d(physics.body_rotation_2d(f.world.phys, f.state.station)),
	}, Station_View{hp_frac = f32(f.state.station_hp) / g.STATION_HP})
	for gate_def, gate in f.world.gates[:f.world.gate_count] {
		godot.push_view(f, {
			key  = u64(gate),
			kind = .Gate,
			pos  = sim.position(gate_def.pos),
		}, Gate_View{charge = f32(f.state.gates[gate].charge) / f32(g.GATE_CHARGE_TICKS)})
	}
	// rocks: rotation from the body, scaled per axis by the radius (squashed for a moment when hit)
	rocks := sim.iterate(&f.state.rocks)
	for rock, handle in sim.next(&rocks) {
		radius := g.ROCK_STATS[rock.size].radius // the mesh is a radius-1 m rock
		flash: f32 = 0
		if rock.hit_tick > 0 && f.tick >= rock.hit_tick {
			flash = max(0, 1 - sim.seconds(f.tick - rock.hit_tick, g.TICK_HZ) / HIT_FLASH_S)
		}
		godot.push_multi_view(f, {
			key    = sim.handle_key(handle),
			kind   = MultiView(int(MultiView.Rock_0) + int(rock.variant)),
			pos    = sim.position(physics.body_position_2d(f.world.phys, rock.body)),
			rot    = physics.quat_2d(physics.body_rotation_2d(f.world.phys, rock.body)),
			scale  = {radius * (1 + HIT_SQUASH * flash), radius * (1 - HIT_SQUASH * flash), 1},
			custom = {f32(rock.size), flash, 0, 0},
		})
	}
	// bullets: turned to and stretched along their velocity (quat_2d normalises it), tinted with the owner's colour
	// (custom.x: the owner's slot, the view's colour index; -1 once the owner has left)
	bullets := sim.iterate(&f.state.bullets)
	for bullet, handle in sim.next(&bullets) {
		owner_slot := sim.player_slot(&f.state.players, bullet.owner)
		godot.push_multi_view(f, {
			key    = sim.handle_key(handle),
			kind   = .Bullet,
			pos    = sim.position(bullet.pos),
			rot    = physics.quat_2d(bullet.vel),
			scale  = BULLET_SCALE,
			custom = {f32(owner_slot), 0, 0, 0},
		})
	}
	// gems: spin, a squash-and-stretch pulse, fading before they expire
	life := sim.seconds(g.GEM_LIFE_TICKS, g.TICK_HZ)
	gems := sim.iterate(&f.state.gems)
	for gem, handle in sim.next(&gems) {
		age := sim.seconds(f.tick - gem.spawn_tick, g.TICK_HZ)
		pulse := math.sin(age * GEM_PULSE_RATE) * GEM_PULSE
		fade := clamp((life - age) / GEM_FADE_S, 0, 1)
		godot.push_multi_view(f, {
			key    = sim.handle_key(handle),
			kind   = .Gem,
			pos    = sim.position(gem.pos),
			rot    = godot.quat_angle2d(age * GEM_SPIN),
			scale  = {1 + pulse, 1 - pulse, 1},
			color  = {1, 0.85, 0.3, 0.25 + 0.75 * fade},
			custom = {age, 0, 0, 0},
		})
	}
	godot.push_data(f, hud_of(f.state, f.tick))
}

// ---- the session data: the HUD (Unified.data.hud)

Data :: union {
	Data_Hud,
}

// A slot's player (zero for an empty slot: who holds it, UnifiedSession.get_players).
Hud_Player :: struct {
	shots: u32,
	gems:  u32,
}

Data_Hud :: struct {
	players:     [g.PLAYERS]Hud_Player,
	phase:       g.Phase, // EnumPhase in GDScript
	_pad:        u8,
	wave:        u16,
	station_hp:  i32, // of Unified.constants.station_hp
	score:       u32,
	rocks:       u32,
	time_s:      f32, // match time (over: survived)
	next_wave_s: f32, // match: until the next wave
	reset_in_s:  f32, // over: until back to the lobby
}

hud_of :: proc(state: ^g.State, tick: u32) -> (hud: Data_Hud) {
	hud.phase = state.phase
	hud.wave = state.waves
	hud.station_hp = state.station_hp
	hud.score = state.score
	hud.rocks = u32(state.rocks.count)
	switch state.phase {
	case .Lobby:
	case .Match:
		hud.time_s = sim.seconds(tick - state.match_tick, g.TICK_HZ)
		hud.next_wave_s = state.next_wave_tick > tick ? sim.seconds(state.next_wave_tick - tick, g.TICK_HZ) : 0
	case .Over:
		hud.time_s = sim.seconds(state.over_tick - state.match_tick, g.TICK_HZ)
		end := state.over_tick + g.OVER_HOLD_TICKS
		hud.reset_in_s = end > tick ? sim.seconds(end - tick, g.TICK_HZ) : 0
	}
	for slot in 0 ..< g.PLAYERS {
		ship := sim.slot_data(&state.players, slot)
		if ship == nil do continue
		hud.players[slot] = {
			shots = ship.shots,
			gems  = ship.gems,
		}
	}
	return
}

// ---- the constants for the scripts (Unified.constants), from the sim's own definitions

// Sizes in metres (the views draw them at Unified.view_scale).
Data_Constants :: struct {
	ship_radius:    f32,
	station_radius: f32,
	gate_radius:    f32,
	station_hp:     i32, // full: the HUD's bar
	station_spin:   f32, // rad/s: the menu's station turns like the match's
	rock_shapes:    [g.ROCK_VARIANTS][8][2]f32, // per variant the 8 corners at radius 1 (an Array of Vector2s)
}

// godot.init calls it once. The rock shapes are the ones the sim builds its bodies from (their convex hull, scaled by
// the rock's radius), at radius 1.
constants :: proc() -> Data_Constants {
	constants := Data_Constants {
		ship_radius    = g.SHIP_RADIUS,
		station_radius = g.STATION_RADIUS,
		gate_radius    = g.GATE_RADIUS,
		station_hp     = g.STATION_HP,
		station_spin   = g.STATION_SPIN,
	}
	small := g.ROCK_STATS[.Small].radius
	for variant in 0 ..< g.ROCK_VARIANTS {
		for corner, k in g.rock_points(variant, .Small) do constants.rock_shapes[variant][k] = corner / small
	}
	return constants
}
