// The bot: a scripted player that reads the state, for the balance test (a copy of GAME with these as its
// scripted_input and scripted_commands). Not the game's own scripted player: a session samples another tick's state
// than an offline run, so their inputs would differ. It orbits the arena, flees the nearest enemies, collects nearby gems, dashes out of contact and picks
// level-up options round-robin (a command). It reads only the state it is given (the predicted state in a session),
// so it is a valid input source anywhere.
package survivor

import "unified:dmath"
import "unified:sim"

BOT_SIGHT :: 9.0 // m: enemies that push the bot away
BOT_GEM_SIGHT :: 8.0
BOT_ORBIT :: 14.0 // m: the radius the bot circles at when nothing is near

// The input of the bot in `slot` (zero when nobody holds it or they are dead), a sim.Game.scripted_input.
bot_input :: proc(seed: u64, slot: int, tick: u32, state: ^State) -> (input: Input) {
	character := sim.slot_data(&state.players, slot)
	if character == nil || !character.alive {
		return
	}
	pos := [2]f32{character.pos.x, character.pos.z}
	if state.phase == .Lobby {
		direction := slot * 2 % 8 // walk out of the start circle, each slot its own way
		input.move_x = dmath.axis_i8(dmath.DIR8[direction].x)
		input.move_z = dmath.axis_i8(dmath.DIR8[direction].y)
		return
	}
	// Flee: the sum of (pos - enemy) / d², for enemies in sight.
	flee: [2]f32
	nearest2: f32 = 1e9
	enemies := sim.iterate(&state.enemies)
	for enemy in sim.next(&enemies) {
		away := pos - enemy.pos
		distance2 := dmath.length_sq(away)
		if distance2 < BOT_SIGHT * BOT_SIGHT {
			weight := 1 / (distance2 + 0.25)
			flee.x += away.x * weight
			flee.y += away.y * weight
		}
		nearest2 = dmath.min(nearest2, distance2)
	}
	// Gems: head for the nearest one in sight.
	to_gem: [2]f32
	best: f32 = BOT_GEM_SIGHT * BOT_GEM_SIGHT
	gems := sim.iterate(&state.gems)
	for gem in sim.next(&gems) {
		toward := gem.pos - pos
		distance2 := dmath.length_sq(toward)
		if distance2 < best {
			best = distance2
			to_gem = dmath.normalize(toward)
		}
	}
	// Orbit the centre at BOT_ORBIT (tangent + radial correction); the pillars' faces slide it along.
	radius := dmath.length(pos)
	radial := dmath.normalize(pos)
	tangent := [2]f32{-radial.y, radial.x}
	if slot % 2 == 1 {
		tangent = -tangent
	}
	orbit := tangent + radial * ((BOT_ORBIT - radius) * 0.15)
	// Crates and barrels, at their grid spots (the state has no item positions; most barely move).
	for &item, i in state.items {
		if !item.alive {
			continue
		}
		spot := item_position(i)
		away := pos - [2]f32{spot.x, spot.z}
		distance2 := dmath.length_sq(away)
		if distance2 < 2.25 {
			orbit += away * (1.0 / (distance2 + 0.1))
		}
	}
	direction := orbit * 0.6 + flee * 2.5 + to_gem * 0.8
	direction = dmath.normalize(direction)
	input.move_x = i8(direction.x * 127)
	input.move_z = i8(direction.y * 127)
	// Dash out of contact range (the dash triggers on a press edge: press on even ticks only).
	if nearest2 < 1.6 * 1.6 && character.dash_cooldown == 0 && tick % 2 == 0 {
		input.buttons += {.Dash}
	}
	return
}

// The bot's commands (a sim.Game.scripted_commands): a level-up pick while one is pending, round-robin over the upgrades by
// level. In a session it sees a predicted state a few ticks old, so it may pick more than once for one level-up: the
// sim ignores a pick with nothing pending.
bot_commands :: proc(seed: u64, slot: int, tick: u32, state: ^State, out: ^sim.Command_Out(Cmd)) {
	character := sim.slot_data(&state.players, slot)
	if character != nil && character.alive && character.pending_levelups > 0 {
		sim.send_command(out, Cmd_Pick{Upgrade((character.level + i32(slot)) % 3)})
	}
}
