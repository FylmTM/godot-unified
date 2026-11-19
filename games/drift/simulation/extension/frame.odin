package extension

import "core:math"
import "unified:godot"
import "unified:physics"
import "unified:sim"

import g "../drift"

// ---- the view contract

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

// A rock kind per shape variant (Rock_0 + variant), then the rest.
#assert(int(MultiView.Bullet) - int(MultiView.Rock_0) == g.ROCK_VARIANTS)

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

// Station hits go to the station's view (they have no subject); the rest by their subject: a player's events to
// their ship (keyed by their player key), a rock's to its shooter's ship (no scene view has a rock's key).
event_key :: proc(event: g.Event, _: godot.Subject) -> (kind: View, key: u64, route: godot.Event_Route) {
	#partial switch _ in event {
	case g.Event_Station_Hit:
		return .Station, 0, .View
	}
	return
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
		godot.push_view(f, player, {
			kind = .Ship,
			pos  = sim.position_2d(physics.body_position_2d(f.world.phys, ship.body)),
			rot  = physics.quat_2d(physics.body_rotation_2d(f.world.phys, ship.body)),
			warp = physics.body_warp(f.world.phys, ship.body),
		}, Ship_View{boost_ready = sim.timer_fraction(f.time, ship.boost_cooldown), thrust = ship.thrust})
	}
	godot.push_view(f, {
		kind = .Station,
		pos  = sim.position_2d(physics.body_position_2d(f.world.phys, f.state.station)),
		rot  = physics.quat_2d(physics.body_rotation_2d(f.world.phys, f.state.station)),
	}, Station_View{hp_frac = f32(f.state.station_hp) / g.STATION_HP})
	for gate_def, gate in sim.slice(&f.world.gates) {
		godot.push_view(f, sim.entity(gate), {
			kind = .Gate,
			pos  = sim.position_2d(gate_def.pos),
		}, Gate_View{charge = 1 - sim.timer_fraction(f.time, f.state.gates[gate].charge)})
	}
	// rocks: rotation from the body, scaled per axis by the radius (squashed for a moment when hit)
	rocks := sim.iterate(&f.state.rocks)
	for rock, handle in sim.next(&rocks) {
		radius := g.ROCK_STATS[rock.size].radius // the mesh is a radius-1 m rock
		flash: f32 = 0
		if rock.hit_tick > 0 && f.time >= rock.hit_tick {
			flash = max(0, 1 - sim.seconds(f.time - rock.hit_tick, g.TICK_HZ) / HIT_FLASH_S)
		}
		godot.push_multi_view(f, {
			key    = sim.handle_key(handle),
			kind   = MultiView(int(MultiView.Rock_0) + int(rock.variant)),
			pos    = sim.position_2d(physics.body_position_2d(f.world.phys, rock.body)),
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
			pos    = sim.position_2d(bullet.pos),
			rot    = physics.quat_2d(bullet.vel),
			scale  = BULLET_SCALE,
			custom = {f32(owner_slot), 0, 0, 0},
		})
	}
	// gems: spin, a squash-and-stretch pulse, fading before they expire
	life := sim.seconds(g.GEM_LIFE_TICKS, g.TICK_HZ)
	gems := sim.iterate(&f.state.gems)
	for gem, handle in sim.next(&gems) {
		age := sim.seconds(f.time - gem.spawn_tick, g.TICK_HZ)
		pulse := math.sin(age * GEM_PULSE_RATE) * GEM_PULSE
		fade := clamp((life - age) / GEM_FADE_S, 0, 1)
		godot.push_multi_view(f, {
			key    = sim.handle_key(handle),
			kind   = .Gem,
			pos    = sim.position_2d(gem.pos),
			rot    = godot.quat_angle_2d(age * GEM_SPIN),
			scale  = {1 + pulse, 1 - pulse, 1},
			color  = {1, 0.85, 0.3, 0.25 + 0.75 * fade},
			custom = {age, 0, 0, 0},
		})
	}
	godot.push_data(f, hud_of(f))
}
