// The bot: a player that reads the state, for the balance test (play_tuning_with_the_bot: a copy of g.GAME with these
// as its scripted_input and scripted_commands). Not the game's own scripted player (g.scripted_input): a session
// samples another tick's state than an offline run, so their inputs would differ. It orbits the arena, flees the
// nearest enemies, collects nearby gems, dashes out of contact and picks level-up options round-robin (a command). It
// reads only the state it is given and the level's item spots (bot_world), so it is a valid input source anywhere.
package test_survivor

import g "../survivor"
import "unified:dmath"
import "unified:sim"

BOT_SIGHT :: 9.0 // enemies within this push the bot away (m)
BOT_GEM_SIGHT :: 8.0 // the bot heads for the nearest gem within this (m)
BOT_ORBIT :: 14.0 // the radius the bot circles at when nothing is near (m)
BOT_ORBIT_PULL :: 0.15 // back towards the orbit: this much per metre off it
BOT_ITEM_REACH :: 1.5 // crates and barrels within this push the bot off (m)
BOT_DASH_REACH :: 1.6 // an enemy this close: dash away (m)
// Added to a distance squared before dividing by it (m²), so a push from something on top of the bot stays finite.
BOT_ENEMY_SOFTEN :: 0.25
BOT_ITEM_SOFTEN :: 0.1
// How much each urge counts in the direction the bot moves.
BOT_WEIGHT_ORBIT :: 0.6
BOT_WEIGHT_FLEE :: 2.5
BOT_WEIGHT_GEM :: 0.8

// The World whose item spots the bot steers around (the state has no item positions): the test's sim's.
@(thread_local)
bot_world: ^g.World

// The input of the bot in `slot` (zero when nobody holds it or they are dead), a sim.Game.scripted_input.
bot_input :: proc(seed: u64, slot: int, tick: u32, state: ^g.State) -> (input: g.Input) {
	character := sim.slot_data(&state.players, slot)
	if character == nil || !character.alive {
		return
	}
	pos := character.pos.xz
	if state.phase == .Lobby {
		direction := dmath.DIR8[slot * 2 % 8] // walk out of the start circle, each slot its own way
		input.move_x, input.move_z = dmath.axis_i8(direction.x), dmath.axis_i8(direction.y)
		return
	}
	// Flee: the sum of (pos - enemy) / d², for enemies in sight.
	flee: [2]f32
	nearest_sq: f32 = 1e9
	enemies := sim.iterate(&state.enemies)
	for enemy in sim.next(&enemies) {
		away := pos - enemy.pos
		distance_sq := dmath.length_sq(away)
		if distance_sq < BOT_SIGHT * BOT_SIGHT {
			flee += away * (1 / (distance_sq + BOT_ENEMY_SOFTEN))
		}
		nearest_sq = dmath.min(nearest_sq, distance_sq)
	}
	// Gems: head for the nearest one in sight.
	to_gem: [2]f32
	best_sq: f32 = BOT_GEM_SIGHT * BOT_GEM_SIGHT
	gems := sim.iterate(&state.gems)
	for gem in sim.next(&gems) {
		toward := gem.pos - pos
		distance_sq := dmath.length_sq(toward)
		if distance_sq < best_sq {
			best_sq = distance_sq
			to_gem = dmath.normalize(toward)
		}
	}
	// Orbit the centre at BOT_ORBIT (tangent + radial correction); the pillars' faces slide it along.
	radial := dmath.normalize(pos)
	tangent := [2]f32{-radial.y, radial.x}
	if slot % 2 == 1 {
		tangent = -tangent
	}
	orbit := tangent + radial * ((BOT_ORBIT - dmath.length(pos)) * BOT_ORBIT_PULL)
	// Crates and barrels, at their spots (most barely move).
	for &item, i in state.items[:bot_world.item_count] {
		if !item.alive {
			continue
		}
		away := pos - bot_world.items[i].pos.xz
		distance_sq := dmath.length_sq(away)
		if distance_sq < BOT_ITEM_REACH * BOT_ITEM_REACH {
			orbit += away * (1 / (distance_sq + BOT_ITEM_SOFTEN))
		}
	}
	direction := dmath.normalize(orbit * BOT_WEIGHT_ORBIT + flee * BOT_WEIGHT_FLEE + to_gem * BOT_WEIGHT_GEM)
	input.move_x, input.move_z = dmath.axis_i8(direction.x), dmath.axis_i8(direction.y)
	// Dash out of contact range (the dash triggers on a press edge: press on even ticks only).
	if nearest_sq < BOT_DASH_REACH * BOT_DASH_REACH && character.dash_cooldown == 0 && tick % 2 == 0 {
		input.buttons += {.Dash}
	}
	return
}

// The bot's commands (a sim.Game.scripted_commands): a level-up pick while one is pending, round-robin over the
// upgrades by level. In a session it sees a predicted state a few ticks old, so it may pick more than once for one
// level-up: the sim ignores a pick with nothing pending.
bot_commands :: proc(seed: u64, slot: int, tick: u32, state: ^g.State, out: ^sim.Command_Out(g.Cmd)) {
	character := sim.slot_data(&state.players, slot)
	if character != nil && character.alive && character.pending_levelups > 0 {
		sim.send_command(out, g.Cmd_Pick{g.Upgrade((character.level + i32(slot)) % len(g.Upgrade))})
	}
}
