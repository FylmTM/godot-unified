// What a player saw (src/sim/README.md, Input): an Input's Seen, how many ticks the picture its player acted on lagged
// the tick the input is for, which the host stamps when it samples (scripted input: 0, scripted_player_input), and
// seen_rewind, the rewind a shot asks the world for (physics.world_cast_ray_closest_rewound).
package sim

import "base:intrinsics"
import "base:runtime"
import "core:fmt"

// How many ticks the picture a player acted on lagged the tick its input is for, as the stamping client knows it: the
// ticks from its newest prediction (the frame on its way to the screen, which interpolates up to it) to the input's
// tick, plus one; so it follows the input delay and any stall (netcode.client_seen). It is the input delay, not
// the measured render latency (when a frame actually showed): that one moves with every frame and below the tick rate
// grows with every tick a sample feeds, so the input bytes would change all the time and every peer would mispredict
// the player. The input delay changes only when the link does, and its error, a fraction of a tick, is what
// seen_rewind's half tick averages out. 0 is unknown: a script, a headless run, a client whose sim doesn't exist yet.
// An Input holds at most one, as a field of its own (found by its type, whatever its name, as the Clock is); the host
// fills it, never the game.
Seen :: distinct u8

// The Seen of an input for `tick` sampled when the client's newest predicted tick was `predicted` (the frame on its
// way to the screen): tick − predicted + 1, held to 1..255. For hosts (netcode.client_seen passes the client's).
seen_of :: proc "contextless" (tick, predicted: u32) -> Seen {
	if tick < predicted do return 1
	behind := tick - predicted
	return Seen(behind + 1 if behind < 254 else 255)
}

// A scripted player's input (Game.scripted_input; a zero Input without one) with its Seen 0, whatever the script wrote:
// a script saw no screen, so a session, an offline run and a Godot `--scripted` session play the same bytes. What every
// host calls instead of the game's script, with the session's Setup (Sim.setup).
scripted_player_input :: proc(
	game: ^$G,
	seed: u64,
	slot: int,
	tick: u32,
	state: ^$State,
	setup: $Setup,
) -> (
	input: part(G, GAME_INPUT),
) where intrinsics.type_is_specialization_of(G, Game) {
	if game.scripted_input != nil do input = game.scripted_input(seed, slot, tick, state, setup)
	seen_stamp(&input, 0)
	return
}

// Writes `seen` into the Input's Seen field; nothing for an Input without one. For hosts, when they sample.
seen_stamp :: proc(input: ^$Input, seen: Seen) {
	at := seen_offset(type_info_of(Input))
	if at >= 0 do (^Seen)(uintptr(input) + uintptr(at))^ = seen
}

// How far back, in seconds, the picture an input's player acted on was from this tick's state (the world after this
// tick's physics step): (seen − 0.5) ticks, the screen being half a tick behind its frame on average, within
// [0, max_s]; 0 for an unknown Seen. What a shot rewinds the world by (physics.world_cast_ray_closest_rewound): `max_s`
// is the game's cap, so a slow or lying client can't reach further back (a NaN or a negative cap: 0).
seen_rewind :: proc(t: ^Tick($G), seen: Seen, max_s: f32) -> f32 {
	if seen == 0 || !(max_s > 0) do return 0
	rewind := (f32(seen) - 0.5) * t.dt
	return rewind if rewind < max_s else max_s
}

// The byte offset of an Input's Seen field (-1: none).
@(private)
seen_offset :: proc(input: ^runtime.Type_Info) -> int {
	info, is_struct := runtime.type_info_base(input).variant.(runtime.Type_Info_Struct)
	if !is_struct do return -1
	for i in 0 ..< int(info.field_count) {
		if info.types[i].id == Seen do return int(info.offsets[i])
	}
	return -1
}

// Why an Input's Seen can't be stamped ("" when it can): two Seen fields, or one deeper than a field of the Input's
// own (in a nested struct or an array), which the host would never fill.
@(private)
seen_violation :: proc(input: ^runtime.Type_Info) -> string {
	info, is_struct := runtime.type_info_base(input).variant.(runtime.Type_Info_Struct)
	if !is_struct do return ""
	seens := 0
	for i in 0 ..< int(info.field_count) {
		if info.types[i].id == Seen {
			seens += 1
		} else if holds_type(info.types[i], Seen) {
			return fmt.tprintf(
				"the Input's field `%s` holds a sim.Seen inside it: the Seen must be a field of the Input itself",
				info.names[i],
			)
		}
	}
	return "the Input holds more than one sim.Seen" if seens > 1 else ""
}
