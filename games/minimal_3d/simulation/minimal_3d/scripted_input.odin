package minimal_3d

import "unified:sim"

// The player in `slot` steers a random direction that changes every 16 ticks, the same for a seed,
// slot and tick whatever order they are asked in.
scripted_input :: proc(seed: u64, slot: int, tick: u32, state: ^State) -> Input {
	bits := sim.script_bits(seed, slot, tick, 16)
	return {dx = i8(i32(bits % 255) - 127), dy = i8(i32((bits >> 8) % 255) - 127)}
}

// The player in `slot` throws a ball every 32 ticks (each slot at its own tick), 3 to 6 metres per second up.
scripted_commands :: proc(seed: u64, slot: int, tick: u32, state: ^State, out: ^sim.Command_Out(Cmd)) {
	if (tick + u32(slot) * 8) % 32 != 0 do return
	sim.send_command(out, Cmd_Ball_Drop{speed = 3 + u8(tick / 32 % 4)})
}
