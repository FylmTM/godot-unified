// The `bench` mode's report (modes.bench_report): a row per standard benchmark, each on its own Setup, or one picked by
// `--name` with its numbers replaced by the options.
package test_headless

import "../toy"
import "core:encoding/json"
import "core:testing"

import uheadless "unified:headless"
import "unified:headless/modes"

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
BENCHES :: []uheadless.Bench {
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
	line, ok := modes.bench_report(&game, BENCHES, nil)
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

	none, none_ok := modes.bench_report(&game, nil, nil)
	testing.expect(t, none_ok)
	testing.expect_value(t, len(report_of(t, none).benches), 0) // no standard benchmark: no row
}

@(test)
bench_runs_one_named_benchmark_with_options :: proc(t: ^testing.T) {
	game := toy.GAME
	line, ok := modes.bench_report(&game, BENCHES, {"--name", "longer_lives", "--ticks", "100"})
	testing.expect(t, ok)
	report := report_of(t, line)
	if !testing.expect_value(t, len(report.benches), 1) do return
	testing.expect_value(t, report.benches[0].name, "longer_lives")
	testing.expect_value(t, report.benches[0].setup, "life_bonus=5")
	testing.expect_value(t, report.benches[0].ticks, 100)
	testing.expect_value(t, report.benches[0].window, 4)
}
