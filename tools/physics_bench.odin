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
	image_us:       cli.Bench_Stat, // a portable image of a past tick's slot (the world swapped out and back)
	image_live_us:  cli.Bench_Stat, // ... and of the live tick's (no swap: a snapshot of the tick the sim is at)
	load_us:        cli.Bench_Stat, // its load into another world
	characters:     int,
	characters_us:  cli.Bench_Stat, // that many character_updates in one tick
	snapshot_bytes: int,
	image_bytes:    int,
	// The capacity against the frame budget: a smaller pile's forward step and its rollback at the prediction cap
	// (restore, `cap` steps saving every 2nd tick, a deep hash), on 1 and 4 workers.
	rollback:       struct {
		bodies:    int,
		cap:       int,
		workers_1: Physics_Rollback,
		workers_4: Physics_Rollback,
	},
}

Physics_Rollback :: struct {
	step_us:                   cli.Bench_Stat,
	rollback_us:               cli.Bench_Stat,
	step_plus_rollback_p99_us: f64,
	within_target:             bool,
}

physics_bench :: proc(work: string) -> (data: any, ok: bool) {
	binary := cli.ensure_headless(
		cli.Headless{"physics_bench", cli.join(cli.state.project.root, "tests", "physics", "bench"), true},
		.release,
	)
	report := new(Physics_Report)
	if !cli.run_report(binary, {}, cli.join(work, "physics"), 120, report) {
		return nil, false
	}
	cli.log(
		"%-12s %d boxes in a pile: step %.0f us (p99 %.0f), save %.0f us (%d bytes), restore %.0f us, hash %.0f us (deep %.0f), %d rays %.0f us; image %.0f us (live %.0f us, %d bytes), load %.0f us; %d characters %.0f us",
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
		report.image_live_us.mean,
		report.image_bytes,
		report.load_us.mean,
		report.characters,
		report.characters_us.mean,
	)
	for &row in ([]^Physics_Rollback{&report.rollback.workers_1, &report.rollback.workers_4}) {
		row.within_target = row.step_plus_rollback_p99_us <= cli.BENCH_TARGET_US
	}
	one, four := report.rollback.workers_1, report.rollback.workers_4
	cli.log(
		"%-12s %d boxes: step + %d-tick rollback %.2f ms at p99 on 1 worker (target <= %.0f ms: %s; means %.0f + %.0f us), %.2f ms on 4 (%s; means %.0f + %.0f us)",
		"",
		report.rollback.bodies,
		report.rollback.cap,
		one.step_plus_rollback_p99_us / 1000,
		cli.BENCH_TARGET_US / 1000,
		one.within_target ? "yes" : "NO",
		one.step_us.mean,
		one.rollback_us.mean,
		four.step_plus_rollback_p99_us / 1000,
		four.within_target ? "yes" : "NO",
		four.step_us.mean,
		four.rollback_us.mean,
	)
	return report^, true
}
