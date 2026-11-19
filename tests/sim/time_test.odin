// Game time: Timers at their edges, a timer through a rollback, the Clock through a pause (time held, nothing fires
// twice or while paused, an expiry moved by exactly the pause), and the library's per-tick parts on a paused tick.
package test_sim

import "core:testing"

import "../toy"
import "unified:sim"

@(test)
timer_edges :: proc(t: ^testing.T) {
	never: sim.Timer
	testing.expect(t, sim.timer_done(5, never) && !sim.timer_running(5, never), "never started: done, not running")
	testing.expect_value(t, sim.timer_fraction(5, never), 1)
	tick := toy.Tick {
		number  = 10,
		time    = 10,
		tick_hz = 64,
	}
	timer: sim.Timer
	sim.timer_start(&tick, &timer, 0.0625) // 4 ticks
	testing.expect_value(t, timer, sim.Timer{10, 14})
	for time in u32(10) ..< 14 do testing.expect(t, sim.timer_running(time, timer) && !sim.timer_done(time, timer))
	testing.expect(t, sim.timer_done(14, timer) && !sim.timer_running(14, timer))
	testing.expect_value(t, sim.timer_fraction(10, timer), 0)
	testing.expect_value(t, sim.timer_fraction(12, timer), 0.5)
	testing.expect_value(t, sim.timer_fraction(99, timer), 1)
	testing.expect_value(t, sim.timer_remaining_s(12, timer, 64), 2.0 / 64)
	testing.expect_value(t, sim.timer_remaining_s(20, timer, 64), 0)
	fired := 0
	for time in u32(10) ..< 30 {
		tick.time = time
		fired += int(sim.timer_fired(&tick, timer))
		testing.expect(t, !sim.timer_fired(&tick, timer) || time == 14)
	}
	testing.expect_value(t, fired, 1)
	tick.time = 14
	tick.paused = true
	testing.expect(t, !sim.timer_fired(&tick, timer), "never on a paused tick")
	sim.timer_start_ticks(&tick, &timer, 7)
	testing.expect_value(t, timer, sim.Timer{14, 21})
	sim.timer_stop(&timer)
	testing.expect(t, timer == {})
}

// A game with a Clock that pauses itself over ticks 20..39 (set at 19, resumed at 39) and keeps a 16-tick timer that
// restarts every time it fires: the fire ticks, the clock and the per-tick library parts are checked.
Clocked_State :: struct {
	clock:      sim.Clock,
	cooldown:   sim.Timer,
	fires:      u32,
	ran:        u32, // ticks the systems ran
	last_fired: u32, // tick number of the last fire
	rolls:      [64]u32, // a keyed roll made on each tick, paused or not
	pressed:    [64]bool,
	players:    sim.Players(u32, sim.No_Profile, toy.Input, 1),
}

Clocked_Game :: sim.Game(
	Clocked_State,
	toy.Input,
	sim.No_World,
	toy.Event,
	sim.No_Commands,
	sim.No_Setup,
	sim.No_Profile,
	1,
)

CLOCKED := Clocked_Game {
	name = "clocked",
	version = "1",
	tick_hz = 64,
	tick = proc(t: ^sim.Tick(Clocked_Game)) {
		if t.number < 64 {
			t.state.rolls[t.number] = sim.roll_below(t, 1 << 30, toy.Roll.Thing_Life)
			players := sim.iterate_present(t)
			for _, player in sim.next(&players) do t.state.pressed[t.number] = .Spawn in sim.buttons(t, player).pressed
		}
		if t.number == 19 do sim.set_paused(t, true)
		if t.number == 39 do sim.set_paused(t, false)
		if t.paused do return
		t.state.ran += 1
		if sim.timer_fired(t, t.state.cooldown) {
			t.state.fires += 1
			t.state.last_fired = t.number
		}
		if sim.timer_done(t, t.state.cooldown) do sim.timer_start_ticks(t, &t.state.cooldown, 16)
	},
}

clocked_inputs :: proc(tick: u32) -> sim.Inputs(Clocked_Game) {
	inputs := sim.Inputs(Clocked_Game) {
		present = {0},
	}
	if tick == 1 do inputs.joins[0] = 1
	// Spawn held from tick 25 (inside the pause) to tick 45 (after it): pressed once, on tick 25
	if tick >= 25 && tick <= 45 do inputs.input[0].buttons = {.Spawn}
	return inputs
}

@(test)
clock_holds_through_a_pause :: proc(t: ^testing.T) {
	simulation := sim.create(&CLOCKED, 9)
	defer sim.destroy(simulation)
	times: [101]u32
	for tick in u32(1) ..= 100 {
		inputs := clocked_inputs(tick)
		sim.step(simulation, &inputs)
		times[tick] = simulation.state.clock.time
		testing.expectf(
			t,
			sim.game_time(&simulation.state, tick) == simulation.state.clock.time,
			"game_time at tick %d",
			tick,
		)
	}
	// paused from tick 20 to 39: game time stands at 19 over those 20 ticks, then moves on
	testing.expect_value(t, times[19], 19)
	for tick in 20 ..= 39 do testing.expect_value(t, times[tick], 19)
	testing.expect_value(t, times[40], 20)
	testing.expect_value(t, times[100], 80)
	testing.expect_value(t, simulation.state.ran, 80)
	// the timer (started at game time 1, every 16 ticks) fired at game times 17, 33, 49, 65: the fire at game time 33
	// came at tick 53, 20 ticks (the pause) later than without it
	testing.expect_value(t, simulation.state.fires, 4)
	testing.expect_value(t, simulation.state.last_fired, 85)
	// keyed rolls name the tick number: they differ on consecutive paused ticks
	for tick in 21 ..= 39 do testing.expect(t, simulation.state.rolls[tick] != simulation.state.rolls[tick - 1])
	// a button pressed during the pause is pressed on that paused tick, and held through the resume it is not again
	for tick in 1 ..< 64 do testing.expectf(t, simulation.state.pressed[tick] == (tick == 25), "pressed at tick %d", tick)
	// a game without a Clock runs on the tick number
	testing.expect_value(t, sim.game_time(&Swarm_State{}, 77), u32(77))
}

// A timer survives a rollback: after every tick, a restore 8 ticks back and a re-simulation (across the timer's starts,
// its fires and the pause) hashes as the first run did, and the fires add up to the same.
@(test)
timer_survives_a_rollback :: proc(t: ^testing.T) {
	simulation := sim.create(&CLOCKED, 9)
	defer sim.destroy(simulation)
	sums: [101]u64
	for tick in u32(1) ..= 100 {
		inputs := clocked_inputs(tick)
		sim.step(simulation, &inputs)
		sums[tick] = sim.checksum(simulation)
		if tick <= 8 do continue
		testing.expect(t, sim.restore(simulation, tick - 8))
		for again in tick - 7 ..= tick {
			again_inputs := clocked_inputs(again)
			sim.step(simulation, &again_inputs)
			testing.expectf(t, sim.checksum(simulation) == sums[again], "tick %d re-simulated differently", again)
		}
	}
	testing.expect_value(t, simulation.state.fires, 4)
}

@(test)
two_clocks_are_refused :: proc(t: ^testing.T) {
	Two :: struct {
		a, b:    sim.Clock,
		players: sim.Players(u32, sim.No_Profile, toy.Input, 1),
	}
	Two_Game :: sim.Game(Two, toy.Input, sim.No_World, toy.Event, sim.No_Commands, sim.No_Setup, sim.No_Profile, 1)
	game := Two_Game {
		name = "two",
		version = "1",
		tick_hz = 64,
		tick = proc(t: ^sim.Tick(Two_Game)) {},
	}
	testing.expect_value(t, sim.game_violation(&game), "two: the State holds more than one sim.Clock")
}
