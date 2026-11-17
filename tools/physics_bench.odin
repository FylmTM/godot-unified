package main

import "unified:cli"

// `uni bench`'s physics row (this repo): Box3D through unified:physics on a fixed scene apart from any game
// (tests/physics/bench), no target: what a Box3D upgrade compares (the upgrade-dependency skill).
Physics_Report :: struct {
	bodies:         int,
	step_us:        cli.Bench_Stat,
	save_us:        cli.Bench_Stat,
	restore_us:     cli.Bench_Stat,
	hash_deep_us:   cli.Bench_Stat,
	rays:           int,
	rays_us:        cli.Bench_Stat,
	snapshot_bytes: int,
}

physics_bench :: proc(work: string) -> (data: any, ok: bool) {
	binary := cli.ensure_headless(
		cli.Headless{"physics_bench", cli.join(cli.state.project.root, "tests", "physics", "bench"), true},
		.release,
	)
	report := new(Physics_Report)
	if !cli.run_report(binary, "", cli.join(work, "physics"), 120, report) {
		return nil, false
	}
	cli.log(
		"%-12s %d awake boxes: step %.0f us (p99 %.0f), save %.0f us (%d bytes), restore %.0f us, deep hash %.0f us, %d rays %.0f us",
		"physics",
		report.bodies,
		report.step_us.mean,
		report.step_us.p99,
		report.save_us.mean,
		report.snapshot_bytes,
		report.restore_us.mean,
		report.hash_deep_us.mean,
		report.rays,
		report.rays_us.mean,
	)
	return report^, true
}
