// What the HUD shows (games/friendslop/SPEC.md), from the state alone: the run, and per player what they
// are doing. The extension turns it into the HUD Dictionary.
package friendslop

Hud_Player :: struct {
	player:  u8,
	present: bool,
	holding: Held_Kind,
	held:    bool, // someone holds this player
	stunned: bool,
	fallen:  bool,
	charge:  f32, // 0..1
}

Hud :: struct {
	phase:      Phase,
	tick:       u32,
	run_s:      f32, // the current run's time (Run), or the finished run's (Finished)
	best_s:     f32, // 0: none
	runs:       u32,
	checkpoint: i32,
	reset_in_s: f32, // Finished: seconds until everyone is back in the hub
	triggers:   u32, // bit i: trigger i is active
	players:    [PLAYERS]Hud_Player,
}

@(rodata)
PHASE_NAMES := [Phase]string {
	.Hub      = "hub",
	.Run      = "run",
	.Finished = "finished",
}

// The HUD data for a tick, derived from the state alone; the GDExtension pushes it to the HUD view every frame.
hud :: proc(state: ^State, tick: u32) -> (result: Hud) {
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
	for &character, player in state.players {
		result.players[player] = {
			player  = u8(player),
			present = character.active,
			holding = character.held_kind,
			held    = character.held_by != 0,
			stunned = character.stun > 0,
			fallen  = character.respawn > 0,
			charge  = f32(character.charge) / f32(THROW_CHARGE_TICKS),
		}
	}
	return
}
