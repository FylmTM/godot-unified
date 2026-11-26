// The HUD's session data (Data_Hud, pushed every frame by fill_frame with godot.push_data): the run and per slot
// what its player is doing, derived from the state on the session thread. GDScript reads it as `Unified.data.hud`
// (class DataHud): `phase` is an EnumPhase value, `players` an Array[DataHudPlayer] by slot (zero for an empty slot);
// who holds a slot comes from the session. No best time: the HUD shows the player's own, kept across sessions
// (Settings.best_time), not the session's. View code, not simulation code: f32 for display only. Plain and
// padding-free (`_pad`).
package friendslop_extension

import "unified:sim"

import g "../friendslop"

Data :: union {
	Data_Hud,
}

Hud_Player :: struct {
	holding: g.Held_Kind, // an EnumHeldKind value
	held:    bool, // someone holds this player
	stunned: bool,
	fallen:  bool,
	charge:  f32, // 0..1
}

Data_Hud :: struct {
	phase:      g.Phase,
	_pad:       [3]u8,
	run_s:      f32, // the current run's time (Run), or the finished run's (Finished)
	checkpoint: i32,
	reset_in_s: f32, // Finished: seconds until everyone is back in the hub
	players:    [g.PLAYERS]Hud_Player,
}

hud_of :: proc(f: ^Frame) -> (hud: Data_Hud) {
	hud.phase = f.state.phase
	hud.checkpoint = f.state.checkpoint
	switch f.state.phase {
	case .Hub:
	case .Run:
		hud.run_s = sim.seconds(f.time - f.state.run_tick, g.TICK_HZ)
	case .Finished:
		hud.run_s = sim.seconds(f.state.finish_hold.start - f.state.run_tick, g.TICK_HZ)
		hud.reset_in_s = sim.timer_remaining_s(f.time, f.state.finish_hold, g.TICK_HZ)
	}
	for slot in 0 ..< g.PLAYERS {
		character := sim.slot_data(&f.state.players, slot)
		if character == nil do continue
		hud.players[slot] = {
			holding = character.held_kind,
			held    = character.held_by != {},
			stunned = sim.timer_running(f.time, character.stun),
			fallen  = sim.timer_running(f.time, character.respawn),
			charge  = f32(character.charge) / f32(g.THROW_CHARGE_TICKS),
		}
	}
	return
}
