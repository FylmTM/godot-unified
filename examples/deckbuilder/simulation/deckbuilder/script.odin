// The scripted player for the headless modes and test sessions. What it does is a function of (seed, slot, tick); which
// card or enemy that names, the state it is given: it doesn't look at its hand, but names cards by where a run's
// starter decks are dealt in the card table (hero h's starters at h * STARTER_SIZE ..) and the enemies of a fight by
// their first places, with the handles that live there in that state (sim.item_at: a new run or fight deals the same
// places under new handles). So it steers by the state (the suite's script_reads_state): a client asked with its own
// prediction may name a handle the verified state no longer has, and the play is refused, as many of its plays are,
// which the refusal path wants anyway.
package deckbuilder

import "unified:sim"

SCRIPT_PLAY_EVERY :: 4 // ticks between a slot's plays
SCRIPT_END_TURN_EVERY :: 64 // ticks between a slot's end of turn (2 s)
SCRIPT_CHOOSE_EVERY :: 8 // ticks between a slot's vote, reward and rest
SCRIPT_START_EVERY :: 128 // ticks between slot 0's start of a run (at the camp)

// The slots alternate the classes, from the seed's.
scripted_profile :: proc(seed: u64, slot: int) -> Profile {
	return {hero_class = Hero_Class((u64(slot) + seed) % 2)}
}

// The slot's commands for a tick: a play every SCRIPT_PLAY_EVERY ticks (a starter of its own deck at an enemy and an
// ally), its turn ended every SCRIPT_END_TURN_EVERY, a vote, a reward and a rest every SCRIPT_CHOOSE_EVERY, and from
// slot 0 a new run every SCRIPT_START_EVERY. At most two a tick.
scripted_commands :: proc(
	seed: u64,
	slot: int,
	tick: u32,
	state: ^State,
	setup: Setup,
	out: ^sim.Command_Out(Command),
) {
	bits := sim.script_bits(seed, slot, tick, 1)
	if slot == 0 && tick % SCRIPT_START_EVERY == 9 do sim.send_command(out, Command_Start_Run{})
	phase := (tick + u32(slot) * 3) % SCRIPT_CHOOSE_EVERY
	starter :: proc(state: ^State, slot: int, pick: u32) -> sim.Handle(Card) {
		_, handle, _ := sim.item_at(&state.cards, slot * STARTER_SIZE + int(pick % STARTER_SIZE))
		return handle
	}
	if phase % SCRIPT_PLAY_EVERY == 0 {
		_, enemy, _ := sim.item_at(&state.enemies, int((bits >> 8) % 3))
		sim.send_command(out, Command_Play_Card {
			card  = starter(state, slot, bits),
			enemy = enemy,
			extra = starter(state, slot, bits >> 16),
			ally  = u8((bits >> 12) % PLAYERS) + 1,
		})
	}
	switch phase {
	case 1:
		sim.send_command(out, Command_Vote{lane = u8(bits % LANES)})
	case 3:
		sim.send_command(out, Command_Pick_Reward{offer = u8(bits % (OFFERS + 1)) if bits % 5 != 0 else SKIP})
	case 5:
		sim.send_command(out, Command_Rest{choice = Rest_Choice(bits % 2), card = starter(state, slot, bits >> 4)})
	case 7:
		if (tick + u32(slot) * 16) % SCRIPT_END_TURN_EVERY < SCRIPT_CHOOSE_EVERY do sim.send_command(out, Command_End_Turn{ready = true})
	}
}
