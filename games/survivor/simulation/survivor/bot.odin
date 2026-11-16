// A deterministic bot player for tuning and tests: orbits the arena, flees the nearest enemies,
// collects nearby gems, dashes out of contact, picks level-up options round-robin (a command). It reads
// only the state it is given (the predicted state in a session), so it is a valid input source anywhere.
package survivor

import "unified:dmath"
import "unified:sim"

BOT_SIGHT :: 9.0 // m: enemies that push the bot away
BOT_GEM_SIGHT :: 8.0
BOT_ORBIT :: 14.0 // m: the radius the bot circles at when nothing is near

// The input of the bot in `slot` (zero when nobody holds it or they are dead).
bot_input :: proc(state: ^State, slot: int, tick: u32) -> (input: Input) {
	character := sim.player_data(&state.players, sim.player_in_slot(&state.players, slot))
	if character == nil || !character.alive {
		return
	}
	pos := dmath.Vec2{character.pos.x, character.pos.z}
	if state.phase == .Lobby {
		direction := slot * 2 % 8 // walk out of the start circle, each slot its own way
		input.move_x = i8(dmath.DIR8_C[direction] * 127)
		input.move_z = i8(dmath.DIR8_S[direction] * 127)
		return
	}
	// Flee: the sum of (pos - enemy) / d², for enemies in sight.
	flee: dmath.Vec2
	nearest2: f32 = 1e9
	enemies := sim.iterate(&state.enemies)
	for enemy in sim.next(&enemies) {
		away := pos - enemy.pos
		distance2 := away.x * away.x + away.y * away.y
		if distance2 < BOT_SIGHT * BOT_SIGHT {
			weight := 1 / (distance2 + 0.25)
			flee.x += away.x * weight
			flee.y += away.y * weight
		}
		nearest2 = min(nearest2, distance2)
	}
	// Gems: head for the nearest one in sight.
	to_gem: dmath.Vec2
	best: f32 = BOT_GEM_SIGHT * BOT_GEM_SIGHT
	gems := sim.iterate(&state.gems)
	for gem in sim.next(&gems) {
		toward := gem.pos - pos
		distance2 := toward.x * toward.x + toward.y * toward.y
		if distance2 < best {
			best = distance2
			to_gem = dmath.normalize2(toward)
		}
	}
	// Orbit the centre at BOT_ORBIT (tangent + radial correction), away from walls and pillars.
	radius := dmath.length2(pos)
	radial := dmath.normalize2(pos)
	tangent := dmath.Vec2{-radial.y, radial.x}
	if slot % 2 == 1 {
		tangent = -tangent
	}
	orbit := tangent + radial * ((BOT_ORBIT - radius) * 0.15)
	for k in 0 ..< 8 {
		away := pos - dmath.Vec2{14 * dmath.DIR8_C[k], 14 * dmath.DIR8_S[k]}
		distance2 := away.x * away.x + away.y * away.y
		if distance2 < 9 {
			orbit += away * (1.5 / (distance2 + 0.25))
		}
	}
	// Crates and barrels, at their grid spots (the state has no item positions; most barely move).
	for &item, i in state.items {
		if !item.alive {
			continue
		}
		spot := item_position(i)
		away := pos - dmath.Vec2{spot.x, spot.z}
		distance2 := away.x * away.x + away.y * away.y
		if distance2 < 2.25 {
			orbit += away * (1.0 / (distance2 + 0.1))
		}
	}
	direction := orbit * 0.6 + flee * 2.5 + to_gem * 0.8
	direction = dmath.normalize2(direction)
	input.move_x = i8(direction.x * 127)
	input.move_z = i8(direction.y * 127)
	// Dash out of contact range (the dash triggers on a press edge: press on even ticks only).
	if nearest2 < 1.6 * 1.6 && character.dash_cooldown == 0 && tick % 2 == 0 {
		input.buttons += {.Dash}
	}
	return
}

// The bot's commands: a level-up pick while one is pending, round-robin over the upgrades by level. In a
// session it sees a predicted state a few ticks old, so it may pick more than once for one level-up: the
// sim ignores a pick with nothing pending.
bot_commands :: proc(state: ^State, slot: int, tick: u32, out: ^sim.Command_Out) {
	character := sim.player_data(&state.players, sim.player_in_slot(&state.players, slot))
	if character != nil && character.alive && character.pending_levelups > 0 {
		sim.send_command(out, Cmd_Pick{Upgrade((character.level + i32(slot)) % 3)})
	}
}

// One tick of bots in slots 0 ..< player_count (the bot in slot i is member i + 1, joining when its slot is
// free): their inputs and commands, as the tick's record. `out` is scratch (the caller deletes its list).
bot_tick :: proc(state: ^State, player_count: int, tick: u32, out: ^sim.Command_Out) -> (inputs: Inputs) {
	for slot in 0 ..< player_count {
		inputs.present += {slot}
		if sim.player_in_slot(&state.players, slot) == {} {
			sim.join(&inputs, slot, slot + 1)
		}
		inputs.input[slot] = bot_input(state, slot, tick)
		out.commands = Cmd
		out.slot = slot
		out.cap = sim.COMMANDS_PER_PLAYER
		clear(&out.list)
		bot_commands(state, slot, tick, out)
		for raw in out.list {
			sim.add_command(&inputs, raw)
		}
	}
	return
}
