package main

import "unified:cli"

// `uni bench`'s physics row (this repo): unified:physics through its plug-in on a fixed pile apart from any game
// (tests/physics/bench), no target: what a Box3D or physics change compares (the upgrade-dependency skill).
Physics_Report :: struct {
	bodies:         int,
	step_us:        cli.Bench_Stat,
	save_us:        cli.Bench_Stat,
	restore_us:     cli.Bench_Stat,
	hash_deep_us:   cli.Bench_Stat, // the whole world (the ticks peers compare)
	hash_us:        cli.Bench_Stat, // the awake bodies (every other tick)
	rays:           int,
	rays_us:        cli.Bench_Stat,
	image_us:       cli.Bench_Stat, // a portable image of a slot (a late join's)
	load_us:        cli.Bench_Stat, // its load into another world
	characters:     int,
	characters_us:  cli.Bench_Stat, // that many character_updates in one tick
	snapshot_bytes: int,
	image_bytes:    int,
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
		"%-12s %d boxes in a pile: step %.0f us (p99 %.0f), save %.0f us (%d bytes), restore %.0f us, hash %.0f us (deep %.0f), %d rays %.0f us; image %.0f us (%d bytes), load %.0f us; %d characters %.0f us",
		"physics",
		report.bodies,
		report.step_us.mean,
		report.step_us.p99,
		report.save_us.mean,
		report.snapshot_bytes,
		report.restore_us.mean,
		report.hash_us.mean,
		report.hash_deep_us.mean,
		report.rays,
		report.rays_us.mean,
		report.image_us.mean,
		report.image_bytes,
		report.load_us.mean,
		report.characters,
		report.characters_us.mean,
	)
	return report^, true
}
