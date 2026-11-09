// What the HUD shows (games/friendslop/SPEC.md), from the state alone: the run, and per slot what the player
// is doing. The extension turns it into the HUD Dictionary.
package friendslop

Hud_Player :: struct {
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
	players:    [MAX_PLAYERS]Hud_Player,
}

PHASE_NAMES := [Phase]string {
	.Hub      = "hub",
	.Run      = "run",
	.Finished = "finished",
}

hud :: proc(s: ^State, tick: u32) -> (h: Hud) {
	h.phase = s.phase
	h.tick = tick
	h.runs = s.runs
	h.best_s = f32(s.best_ticks) * DT
	h.checkpoint = s.checkpoint
	switch s.phase {
	case .Hub:
	case .Run:
		h.run_s = f32(tick - s.run_tick) * DT
	case .Finished:
		h.run_s = f32(s.finish_tick - s.run_tick) * DT
		h.reset_in_s = f32(FINISH_HOLD_TICKS - min(tick - s.finish_tick, FINISH_HOLD_TICKS)) * DT
	}
	for tr, i in s.triggers {
		if tr.active do h.triggers |= 1 << u32(i)
	}
	for &pl, p in s.players {
		h.players[p] = {
			present = pl.active,
			holding = pl.held_kind,
			held    = pl.held_by != 0,
			stunned = pl.stun > 0,
			fallen  = pl.respawn > 0,
			charge  = f32(pl.charge) / f32(THROW_CHARGE_TICKS),
		}
	}
	return
}
