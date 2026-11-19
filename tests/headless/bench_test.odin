// The `bench` mode's report (modes.bench_report): a row per standard benchmark (Game.benches), each on its own Setup, or
// one picked by `--name` with its numbers replaced by the options; and the benchmarks game_violation refuses.
package test_headless

import "../toy"
import "core:encoding/json"
import "core:strings"
import "core:testing"

import uheadless "unified:headless"
import "unified:headless/modes"
import "unified:sim"

@(private = "file")
Report :: struct {
	mode:    string,
	benches: []struct {
		name:       string,
		setup:      string,
		ticks:      int,
		window:     int,
		mismatches: int,
	},
}

@(private = "file")
BENCHES :: []sim.Bench {
	{what = "the toy", ticks = 90},
	{name = "longer_lives", what = "the toy, things living longer", setup = "life_bonus=5", ticks = 90, window = 4},
}

@(private = "file")
report_of :: proc(t: ^testing.T, line: string) -> (report: Report) {
	err := json.unmarshal_string(line, &report, allocator = context.temp_allocator)
	testing.expectf(t, err == nil, "the line reads as JSON: %v (%s)", err, line)
	return report
}

@(test)
bench_runs_every_standard_benchmark_without_options :: proc(t: ^testing.T) {
	game := toy.GAME
	game.benches = BENCHES
	testing.expect_value(t, sim.game_violation(&game), "")
	line, ok := modes.bench_report(&game, nil)
	testing.expect(t, ok, "every re-sim agreed")
	report := report_of(t, line)
	testing.expect_value(t, report.mode, "bench")
	if !testing.expect_value(t, len(report.benches), 2) do return
	testing.expect_value(t, report.benches[0].name, "")
	testing.expect_value(t, report.benches[0].window, uheadless.prediction_window(&game))
	testing.expect_value(t, report.benches[1].name, "longer_lives")
	testing.expect_value(t, report.benches[1].setup, "life_bonus=5")
	testing.expect_value(t, report.benches[1].window, 4)
	for bench in report.benches do testing.expect_value(t, bench.mismatches, 0)

	game.benches = nil
	none, none_ok := modes.bench_report(&game, nil)
	testing.expect(t, none_ok)
	testing.expect_value(t, len(report_of(t, none).benches), 0) // no standard benchmark: no row
}

@(test)
bench_runs_one_named_benchmark_with_options :: proc(t: ^testing.T) {
	game := toy.GAME
	game.benches = BENCHES
	line, ok := modes.bench_report(&game, {"--name", "longer_lives", "--ticks", "100"})
	testing.expect(t, ok)
	report := report_of(t, line)
	if !testing.expect_value(t, len(report.benches), 1) do return
	testing.expect_value(t, report.benches[0].name, "longer_lives")
	testing.expect_value(t, report.benches[0].setup, "life_bonus=5")
	testing.expect_value(t, report.benches[0].ticks, 100)
	testing.expect_value(t, report.benches[0].window, 4)
}

// A benchmark that couldn't run, or would run something else than it says, breaks a rule of the harness: every test
// of the game (sim.create panics) and every headless mode (modes.run) catch it, not only `uni bench`.
@(test)
game_violation_refuses_a_broken_benchmark :: proc(t: ^testing.T) {
	cases := []struct {
		bench: sim.Bench,
		names: string,
	} {
		{{what = "no ticks"}, "runs 0 ticks"},
		{{what = "too long", ticks = sim.BENCH_TICKS_MAX + 1}, "ticks"},
		{{what = "negative", ticks = 10, entities = -1}, "entities"},
		{{what = "past the ring", ticks = 10, window = sim.ring_size(toy.GAME.tick_hz)}, "rolls back"},
		{{name = "stale", what = "a renamed field", setup = "life=5", ticks = 10}, `benchmark "stale": its setup`},
		{{what = "a bad value", setup = "life_bonus=999", ticks = 10}, "the game's benchmark: its setup"},
	}
	for test_case in cases {
		game := toy.GAME
		benches := []sim.Bench{test_case.bench}
		game.benches = benches
		reason := sim.game_violation(&game)
		testing.expectf(t, strings.contains(reason, test_case.names), "%s: %q", test_case.bench.what, reason)
	}
	game := toy.GAME
	twice := []sim.Bench{{name = "a", ticks = 10}, {name = "a", ticks = 20}}
	game.benches = twice
	testing.expectf(t, strings.contains(sim.game_violation(&game), `two benchmarks named "a"`), "names are unique")
}
