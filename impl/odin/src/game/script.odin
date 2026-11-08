// Scripted test inputs (GAME.md "Scripted inputs"): per player, a xorshift32 seeded
// seed·7919 + p + 1 and re-drawn every 24 ticks.
package game

SCRIPT_PERIOD :: 24

Script :: struct {
	rng:   u32,
	block: i64, // index of the 24-tick block `r` belongs to (-1: nothing drawn yet)
	r:     u32,
}

script_init :: proc(seed: u32, p: int) -> Script {
	x := seed * 7919 + u32(p) + 1
	return {rng = x == 0 ? 1 : x, block = -1}
}

// Input of this player for tick t (t >= 1). Ticks must be requested in non-decreasing block order.
// `pending` is the player's pending level-up count in the caller's current state.
script_input :: proc(sc: ^Script, t: u32, pending: i32) -> Input {
	block := i64(t - 1) / SCRIPT_PERIOD
	assert(block >= sc.block, "script ticks must not go backwards")
	for sc.block < block {
		sc.r = xorshift32(&sc.rng)
		sc.block += 1
	}
	r := sc.r
	in_: Input
	if r % 9 != 8 {
		k := r % 8
		in_.move_x = i8(RING_C[k] * 127)
		in_.move_z = i8(RING_S[k] * 127)
	}
	if r % 13 == 0 {
		in_.buttons |= BUTTON_DASH
	}
	if pending > 0 {
		in_.choice = u8(r % 3) + 1
	}
	return in_
}

// Scripted inputs for all slots of an offline run: active slots < players, the rest absent.
script_inputs :: proc(scripts: ^[MAX_PLAYERS]Script, s: ^State, t: u32, players: int) -> (out: Inputs) {
	for p in 0 ..< MAX_PLAYERS {
		if p < players {
			out[p] = script_input(&scripts[p], t, s.players[p].pending_levelups)
		} else {
			out[p] = ABSENT_INPUT
		}
	}
	return
}
