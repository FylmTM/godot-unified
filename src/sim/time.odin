// Game time (src/sim/README.md, Game time): the Clock a State may hold, which the harness advances on every tick that
// isn't paused, and Timers on it, which have nothing to decrement.
package sim

import "base:runtime"

// Game time and the co-op pause, in the block. A State holds at most one, as a field of its own (found by its type,
// whatever its name): the harness advances `time` by one before every tick unless `paused`, and gives the tick
// `t.time` and `t.paused`. A State without one runs on the tick number (`t.time == t.number`, never paused).
Clock :: struct {
	time:   u32, // the ticks the game ran: game time
	paused: bool, // set_paused's: the clock stands still from the next tick
	_pad:   [3]u8,
}

// The State's Clock (its first field of type Clock), or nil when it holds none.
clock_of :: proc(state: ^$State) -> ^Clock {
	at := clock_offset(type_info_of(State))
	return nil if at < 0 else (^Clock)(uintptr(state) + uintptr(at))
}

// The byte offset of a State's Clock field (-1: none).
@(private)
clock_offset :: proc(state: ^runtime.Type_Info) -> int {
	info, is_struct := runtime.type_info_base(state).variant.(runtime.Type_Info_Struct)
	if !is_struct do return -1
	for i in 0 ..< int(info.field_count) {
		if info.types[i].id == Clock do return int(info.offsets[i])
	}
	return -1
}

// Pauses or resumes the game for everyone, from the next tick (this tick's `t.paused` stays what it was, so a game
// that returns early on `t.paused` runs no system twice at one game time). The State must hold a Clock. A command a
// game reads on a paused tick (the pause's own) arrives once, like every command: the co-op pause reads its command
// before it returns early.
set_paused :: proc(tick: ^Tick($G), paused: bool) {
	clock := clock_of(tick.state)
	assert(clock != nil, "sim.set_paused: the State holds no sim.Clock")
	clock.paused = paused
}

// The game time of a State at a tick: its Clock's, or the tick number for a State without one. What a view reads
// timers with (`sim.game_time(f.state, f.tick)`, as godot.Frame.time).
game_time :: proc(state: ^$State, tick: u32) -> u32 {
	if clock := clock_of(state); clock != nil do return clock.time
	return tick
}

// The harness's step of the clock, before `tick`: advances it unless paused and fills the tick's time and pause.
@(private)
clock_step :: proc(tick: ^Tick($G)) {
	tick.time = tick.number
	clock := clock_of(tick.state)
	if clock == nil do return
	tick.paused = clock.paused
	if !clock.paused do clock.time += 1
	tick.time = clock.time
}

// Why a State's clock can't run ("" when it can): two Clock fields.
@(private)
clock_violation :: proc(state: ^runtime.Type_Info) -> string {
	info, is_struct := runtime.type_info_base(state).variant.(runtime.Type_Info_Struct)
	if !is_struct do return ""
	clocks := 0
	for i in 0 ..< int(info.field_count) do clocks += int(info.types[i].id == Clock)
	return "the State holds more than one sim.Clock" if clocks > 1 else ""
}

// A countdown on game time: when it was started and the game time it reaches its end, so nothing decrements it, a
// rollback restores it with the block and a pause holds it. The zero value was never started: done, not running (a
// cooldown that never ran is ready). Every read has a form taking the tick and one taking a game time (views:
// godot.Frame.time; tests).
Timer :: struct {
	start, target: u32, // game time
}

// Starts (or restarts) a timer that ends `seconds` from now, rounded to the nearest tick (sim.ticks): it is running
// until then and done from then.
timer_start :: proc(tick: ^Tick($G), timer: ^Timer, seconds: f32) {
	timer^ = {tick.time, tick.time + ticks(seconds, tick.tick_hz)}
}

// Starts a timer that ends `count` ticks from now: for a time kept in ticks (data, an upgradable interval).
timer_start_ticks :: proc(tick: ^Tick($G), timer: ^Timer, count: u32) {
	timer^ = {tick.time, tick.time + count}
}

// Stops a timer: back to the zero value (done, not running, never fires).
timer_stop :: proc(timer: ^Timer) {
	timer^ = {}
}

// Whether a timer is running: started and not yet at its end.
timer_running :: proc {
	timer_running_tick,
	timer_running_at,
}

// Whether a timer is done: at or past its end, or never started.
timer_done :: proc {
	timer_done_tick,
	timer_done_at,
}

// Whether a timer ends on this tick: true on exactly one tick, never on a paused one (game time stood still). Read
// it every tick, or it is missed: a rule checked in a sliced or skipped system uses timer_done and timer_stop.
timer_fired :: proc(tick: ^Tick($G), timer: Timer) -> bool {
	return timer.target != 0 && tick.time == timer.target && !tick.paused
}

// How far a timer has run, 0 at its start to 1 at its end and after (1 for one never started or of no length).
timer_fraction :: proc {
	timer_fraction_tick,
	timer_fraction_at,
}

// The seconds a timer has left (0 once done).
timer_remaining_s :: proc {
	timer_remaining_s_tick,
	timer_remaining_s_at,
}

// timer_running at this tick's game time.
timer_running_tick :: proc(tick: ^Tick($G), timer: Timer) -> bool {
	return timer_running_at(tick.time, timer)
}

// timer_running at game time `time`.
timer_running_at :: proc(time: u32, timer: Timer) -> bool {
	return time < timer.target
}

// timer_done at this tick's game time.
timer_done_tick :: proc(tick: ^Tick($G), timer: Timer) -> bool {
	return timer_done_at(tick.time, timer)
}

// timer_done at game time `time`.
timer_done_at :: proc(time: u32, timer: Timer) -> bool {
	return time >= timer.target
}

// timer_fraction at this tick's game time.
timer_fraction_tick :: proc(tick: ^Tick($G), timer: Timer) -> f32 {
	return timer_fraction_at(tick.time, timer)
}

// timer_fraction at game time `time`.
timer_fraction_at :: proc(time: u32, timer: Timer) -> f32 {
	if time >= timer.target || timer.target <= timer.start do return 1
	if time <= timer.start do return 0
	return f32(time - timer.start) / f32(timer.target - timer.start)
}

// timer_remaining_s at this tick's game time.
timer_remaining_s_tick :: proc(tick: ^Tick($G), timer: Timer) -> f32 {
	return timer_remaining_s_at(tick.time, timer, tick.tick_hz)
}

// timer_remaining_s at game time `time`, for a game at `tick_hz`.
timer_remaining_s_at :: proc(time: u32, timer: Timer, tick_hz: int) -> f32 {
	return 0 if time >= timer.target else seconds(timer.target - time, tick_hz)
}
