// What the HUD shows (games/friendslop/SPEC.md), from the state alone: the run, and per player what they
// are doing. The extension pushes it as the game's session data (Unified.data.hud).
package friendslop

import "unified:sim"

// A slot's player (players[slot]; present false: the slot is empty).
Hud_Player :: struct {
	player:  sim.Player, // GDScript gets its key
	present: bool,
	holding: Held_Kind,
	held:    bool, // someone holds this player
	stunned: bool,
	fallen:  bool,
	_pad:    [3]u8,
	charge:  f32, // 0..1
}

// Plain and padding-free: the extension's session data type (class DataHud).
Data_Hud :: struct {
	phase:      Phase,
	_pad:       [3]u8,
	tick:       u32,
	run_s:      f32, // the current run's time (Run), or the finished run's (Finished)
	best_s:     f32, // 0: none
	runs:       u32,
	checkpoint: i32,
	reset_in_s: f32, // Finished: seconds until everyone is back in the hub
	triggers:   u32, // bit i: trigger i is active
	players:    [PLAYERS]Hud_Player,
}

// The HUD data for a tick, derived from the state alone; the GDExtension pushes it every frame.
hud :: proc(state: ^State, tick: u32) -> (result: Data_Hud) {
	result.phase = state.phase
	result.tick = tick
	result.runs = state.runs
	result.best_s = f32(state.best_ticks) * DT
	result.checkpoint = state.checkpoint
	switch state.phase {
	case .Hub:
	case .Run:
		result.run_s = f32(tick - state.run_tick) * DT
	case .Finished:
		result.run_s = f32(state.finish_tick - state.run_tick) * DT
		result.reset_in_s = f32(FINISH_HOLD_TICKS - min(tick - state.finish_tick, FINISH_HOLD_TICKS)) * DT
	}
	for trigger, i in state.triggers {
		if trigger.active do result.triggers |= 1 << u32(i)
	}
	for slot in 0 ..< PLAYERS {
		player := sim.player_in_slot(&state.players, slot)
		character := sim.player_data(&state.players, player)
		if character == nil do continue
		result.players[slot] = {
			player  = player,
			present = true,
			holding = character.held_kind,
			held    = character.held_by != {},
			stunned = character.stun > 0,
			fallen  = character.respawn > 0,
			charge  = f32(character.charge) / f32(THROW_CHARGE_TICKS),
		}
	}
	return
}
