// What a player saw (src/sim/README.md, Input): an Input's Seen, how many ticks the picture its player acted on lagged
// the tick the input is for, which the host stamps when it samples, and seen_rewind, the rewind a shot asks the world
// for (physics.world_cast_ray_closest_rewound).
package sim

import "base:runtime"
import "core:fmt"

// How many ticks the stamping client's screen lagged the tick its input is for: the tick minus the newest predicted
// tick of the frame on screen when the input was sampled, plus one (the screen interpolates up to that tick, so it
// shows about half a tick before it). 0 is unknown: a script, a headless run, a host that showed nothing yet. An Input
// holds at most one, as a field of its own (found by its type, whatever its name, as the Clock is); the host fills it,
// never the game. Whole ticks on purpose: it changes only when the delay does, so it doesn't make an input differ from
// the one before (a remote player's misprediction) every tick.
Seen :: distinct u8

// The Seen of an input sampled for `tick` while the screen showed the frame of tick `shown`: tick − shown + 1, held to
// 1..255. For hosts (a host that has shown no frame stamps nothing: 0).
seen_of :: proc "contextless" (tick, shown: u32) -> Seen {
	if tick < shown do return 1
	behind := tick - shown
	return Seen(behind + 1 if behind < 254 else 255)
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
