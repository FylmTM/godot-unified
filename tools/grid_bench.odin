package main

import "unified:cli"

// `uni bench`'s grid row (this repo): sim.Grid apart from any game (tests/sim/bench), no target: a rebuild and a
// neighbour pass at a horde's scale, which a pass that rebuilds its grid pays once per re-simulated tick.
Grid_Report :: struct {
	cells: int,
	small: Grid_Row,
	large: Grid_Row,
}

Grid_Row :: struct {
	points:     int,
	rebuild_us: cli.Bench_Stat, // grid_begin, an add per point, grid_end
	near_us:    cli.Bench_Stat, // every point's grid_near, counting those within one cell
	neighbours: int,
}

grid_bench :: proc(work: string) -> (data: any, ok: bool) {
	binary := cli.ensure_headless(
		cli.Headless{"grid_bench", cli.join(cli.state.project.root, "tests", "sim", "bench"), false},
		.release,
	)
	report := new(Grid_Report)
	if !cli.run_report(binary, {}, cli.join(work, "grid"), 60, report) {
		return nil, false
	}
	for row in ([]Grid_Row{report.small, report.large}) {
		cli.log(
			"%-12s %d points on %d cells: rebuild %.1f us (p99 %.1f), neighbour pass %.0f us (p99 %.0f)",
			"grid" if row.points == report.small.points else "",
			row.points,
			report.cells,
			row.rebuild_us.mean,
			row.rebuild_us.p99,
			row.near_us.mean,
			row.near_us.p99,
		)
	}
	return report^, true
}
