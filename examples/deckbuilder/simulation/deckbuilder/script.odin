// The scripted player for the headless modes and test sessions: a pure function of (seed, slot, tick), so any tick can
// be asked for in any order and a Godot scripted session sends what the offline binary does. It can't look at its
// hand: it names cards by where a run's starter decks are dealt in the card table (hero h's starters at h *
// STARTER_SIZE ..), the enemies of a fight by their first places, and many of its plays are refused, which the
// refusal path wants anyway.
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
scripted_commands :: proc(seed: u64, slot: int, tick: u32, state: ^State, out: ^sim.Command_Out(Cmd)) {
	bits := sim.script_bits(seed, slot, tick, 1)
	if slot == 0 && tick % SCRIPT_START_EVERY == 9 do sim.send_command(out, Cmd_Start_Run{})
	phase := (tick + u32(slot) * 3) % SCRIPT_CHOOSE_EVERY
	if phase % SCRIPT_PLAY_EVERY == 0 {
		starter :: proc(slot: int, pick: u32) -> sim.Handle(Card) {
			return {index = u32(slot * STARTER_SIZE) + pick % STARTER_SIZE, generation = 1}
		}
		sim.send_command(out, Cmd_Play_Card {
			card = starter(slot, bits),
			enemy = {index = (bits >> 8) % 3, generation = 1},
			extra = starter(slot, bits >> 16),
			ally = u8((bits >> 12) % PLAYERS) + 1,
		})
	}
	switch phase {
	case 1:
		sim.send_command(out, Cmd_Vote{lane = u8(bits % LANES)})
	case 3:
		sim.send_command(out, Cmd_Pick_Reward{offer = u8(bits % (OFFERS + 1)) if bits % 5 != 0 else SKIP})
	case 5:
		sim.send_command(out, Cmd_Rest {
			choice = Rest_Choice(bits % 2),
			card = {index = u32(slot * STARTER_SIZE) + (bits >> 4) % STARTER_SIZE, generation = 1},
		})
	case 7:
		if (tick + u32(slot) * 16) % SCRIPT_END_TURN_EVERY < SCRIPT_CHOOSE_EVERY do sim.send_command(out, Cmd_End_Turn{ready = true})
	}
}
