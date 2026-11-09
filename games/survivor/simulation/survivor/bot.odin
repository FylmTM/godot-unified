// A deterministic bot player for tuning and tests: orbits the arena, flees the nearest enemies,
// collects nearby gems, dashes out of contact, picks level-up options round-robin. It reads only
// the state it is given (the predicted state in a session), so it is a valid input source anywhere.
package survivor

import "unified:dmath"
import "unified:sim"

BOT_SIGHT :: 9.0 // m: enemies that push the bot away
BOT_GEM_SIGHT :: 8.0
BOT_ORBIT :: 14.0 // m: the radius the bot circles at when nothing is near

bot_input :: proc(s: ^State, p: int, t: u32) -> (in_: Input) {
	pl := &s.players[p]
	if !pl.active || !pl.alive {
		return
	}
	if pl.pending_levelups > 0 {
		// Round-robin over fire rate, damage, speed by level; a new press for every pending level-up.
		press := u8((pl.level * 4 + pl.pending_levelups) % 63) + 1
		in_.choice = choice_encode(int((pl.level + i32(p)) % 3) + 1, press)
	}
	pos := dmath.Vec2{pl.pos.x, pl.pos.z}
	if s.phase == .Lobby {
		k := p * 2 % 8 // walk out of the start circle, each slot its own way
		in_.move_x = i8(dmath.DIR8_C[k] * 127)
		in_.move_z = i8(dmath.DIR8_S[k] * 127)
		return
	}
	// Flee: the sum of (pos - enemy) / d², for enemies in sight.
	flee: dmath.Vec2
	nearest2: f32 = 1e9
	for i in 0 ..< s.enemies.high_water {
		e := sim.at(&s.enemies, i) or_continue
		d := pos - e.pos
		d2 := d.x * d.x + d.y * d.y
		if d2 < BOT_SIGHT * BOT_SIGHT {
			w := 1 / (d2 + 0.25)
			flee.x += d.x * w
			flee.y += d.y * w
		}
		nearest2 = min(nearest2, d2)
	}
	// Gems: head for the nearest one in sight.
	gem: dmath.Vec2
	best: f32 = BOT_GEM_SIGHT * BOT_GEM_SIGHT
	for i in 0 ..< s.gems.high_water {
		g := sim.at(&s.gems, i) or_continue
		d := g.pos - pos
		d2 := d.x * d.x + d.y * d.y
		if d2 < best {
			best = d2
			gem = dmath.normalize2(d)
		}
	}
	// Orbit the centre at BOT_ORBIT (tangent + radial correction), away from walls and pillars.
	r := dmath.length2(pos)
	radial := dmath.normalize2(pos)
	tangent := dmath.Vec2{-radial.y, radial.x}
	if p % 2 == 1 {
		tangent = -tangent
	}
	orbit := tangent + radial * ((BOT_ORBIT - r) * 0.15)
	for k in 0 ..< 8 {
		d := pos - dmath.Vec2{14 * dmath.DIR8_C[k], 14 * dmath.DIR8_S[k]}
		d2 := d.x * d.x + d.y * d.y
		if d2 < 9 {
			orbit += d * (1.5 / (d2 + 0.25))
		}
	}
	// Crates and barrels, at their grid spots (the state has no item positions; most barely move).
	for &it, i in s.items {
		if !it.alive {
			continue
		}
		c := item_position(i)
		d := pos - dmath.Vec2{c.x, c.z}
		d2 := d.x * d.x + d.y * d.y
		if d2 < 2.25 {
			orbit += d * (1.0 / (d2 + 0.1))
		}
	}
	dir := orbit * 0.6 + flee * 2.5 + gem * 0.8
	dir = dmath.normalize2(dir)
	in_.move_x = i8(dir.x * 127)
	in_.move_z = i8(dir.y * 127)
	// Dash out of contact range (the dash triggers on a press edge: press on even ticks only).
	if nearest2 < 1.6 * 1.6 && pl.dash_cooldown == 0 && t % 2 == 0 {
		in_.buttons |= BUTTON_DASH
	}
	return
}
